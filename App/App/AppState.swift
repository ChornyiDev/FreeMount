import AppKit
import FileProvider
import Foundation
import Observation
import os.log

/// Coordinates state across the menu bar popover, preferences, and background tasks.
@Observable
@MainActor
public final class AppState {
    private static let log = Logger(subsystem: "com.freemount.app", category: "AppState")

    public var remotes: [RemoteConfig] = []
    public var mountStatuses: [UUID: MountStatus] = [:]
    public var connectionHealth: [UUID: ConnectionHealth] = [:]
    public var currentStats: TransferStats = .zero
    public var lastError: FreeMountError?
    public var isDaemonRunning: Bool = false

    private let remoteStore: RemoteConfigStore
    private let domainRegistry: FileProviderDomainRegistry?
    private var healthCheckIDs: [UUID: UUID] = [:]
    private let providerRegistry: ProviderRegistry
    private let customHealthChecker: (any GoogleDriveConnectionHealthChecking)?
    private let customGCSHealthChecker: GoogleCloudConnectionHealthChecker?

    public init(
        remotes: [RemoteConfig]? = nil,
        remoteStore: RemoteConfigStore? = nil,
        domainRegistry: FileProviderDomainRegistry? = nil,
        providerRegistry: ProviderRegistry = .shared,
        healthChecker: (any GoogleDriveConnectionHealthChecking)? = nil,
        gcsHealthChecker: GoogleCloudConnectionHealthChecker? = nil
    ) {
        let resolvedStore = remoteStore ?? RemoteConfigStore()
        self.remoteStore = resolvedStore
        self.domainRegistry = domainRegistry
        self.providerRegistry = providerRegistry
        self.customHealthChecker = healthChecker
        self.customGCSHealthChecker = gcsHealthChecker

        let loadedRemotes: [RemoteConfig]
        if let remotes {
            loadedRemotes = remotes
        } else if let remoteStore {
            loadedRemotes = remoteStore.load()
        } else {
            loadedRemotes = []
        }

        var seenKeys = Set<String>()
        var deduplicated: [RemoteConfig] = []
        for r in loadedRemotes.reversed() {
            let key = Self.connectionIdentityKey(for: r)
            if seenKeys.insert(key).inserted {
                deduplicated.insert(r, at: 0)
            }
        }
        self.remotes = deduplicated
        if remoteStore != nil && deduplicated.count != loadedRemotes.count {
            resolvedStore.save(deduplicated)
        }

        // Catalog entries publish configuration; only macOS reconciliation can
        // establish whether a domain is connected or disconnected.
        self.mountStatuses = Dictionary(uniqueKeysWithValues: deduplicated.map { ($0.id, .unmounted) })
        self.connectionHealth = Dictionary(uniqueKeysWithValues: deduplicated.map { ($0.id, .unknown) })
    }

    public func status(for remoteId: UUID) -> MountStatus {
        mountStatuses[remoteId] ?? .unmounted
    }

    public var activeConnectionCount: Int {
        remotes.count { remote in
            status(for: remote.id).isMounted && health(for: remote.id).isHealthy
        }
    }

    public func health(for remoteId: UUID) -> ConnectionHealth {
        connectionHealth[remoteId] ?? .unknown
    }

    @discardableResult
    public func addRemote(_ remote: RemoteConfig) -> RemoteConfig {
        let key = Self.connectionIdentityKey(for: remote)
        if let existingIndex = remotes.firstIndex(where: { Self.connectionIdentityKey(for: $0) == key }) {
            let existingRemote = remotes[existingIndex]
            let existingId = existingRemote.id
            var updated = remote
            updated.id = existingId
            do {
                if try domainRegistry?.isRegistered(remoteID: existingId) == true {
                    try domainRegistry?.ensureDescriptorStored(for: updated)
                }
            } catch {
                lastError = .invalidConfiguration(reason: error.localizedDescription)
                return existingRemote
            }
            remotes[existingIndex] = updated
            connectionHealth[existingId] = .unknown
            remoteStore.save(remotes)
            return updated
        } else {
            remotes.append(remote)
            mountStatuses[remote.id] = .unmounted
            connectionHealth[remote.id] = .unknown
        }
        remoteStore.save(remotes)
        return remote
    }

    /// Commits the replacement before retiring a superseded GCS secret.
    /// Cleanup failure leaves the new connection usable and exposes a warning.
    @discardableResult
    public func addRemote(_ remote: RemoteConfig, keychain: KeychainService) async -> RemoteConfig {
        let previous = remotes.first { Self.connectionIdentityKey(for: $0) == Self.connectionIdentityKey(for: remote) }
        let saved = addRemote(remote)
        if remote.provider == .googleCloudStorage,
           let oldAccount = previous?.keychainAccountKey,
           oldAccount != saved.keychainAccountKey {
            await retireCredentialIfUnused(account: oldAccount, keychain: keychain)
        }
        return saved
    }

    private func retireCredentialIfUnused(account: String, keychain: KeychainService) async {
        guard !remotes.contains(where: { $0.keychainAccountKey == account }) else { return }
        do {
            guard !(try domainRegistry?.registeredConnections().contains(where: { $0.keychainAccountKey == account }) ?? false) else { return }
            try await keychain.deleteCredential(account: account)
        }
        catch {
            lastError = .keychainError(status: -1, message: "An unused connection credential could not be removed: \(error.localizedDescription)")
        }
    }

    /// Remove the system domain before retiring saved settings or credentials.
    public func removeRemoteAndCredentials(id: UUID, keychain: KeychainService? = nil) async {
        let account = remotes.first(where: { $0.id == id })?.keychainAccountKey
        do { try await domainRegistry?.removeDomain(remoteID: id) }
        catch {
            lastError = .invalidConfiguration(reason: "Could not remove the Finder domain: \(error.localizedDescription)")
            return
        }
        removeRemoteMetadata(id: id)
        if let account, let keychain {
            await retireCredentialIfUnused(account: account, keychain: keychain)
        }
    }

    private func removeRemoteMetadata(id: UUID) {
        remotes.removeAll { $0.id == id }
        mountStatuses.removeValue(forKey: id)
        connectionHealth.removeValue(forKey: id)
        remoteStore.save(remotes)
    }

    @discardableResult
    public func updateRemote(_ remote: RemoteConfig) -> Bool {
        guard let index = remotes.firstIndex(where: { $0.id == remote.id }) else { return false }
        let existing = remotes[index]
        if existing.provider == .googleCloudStorage {
            guard remote.provider == existing.provider,
                  remote.bucketOrRootPath == existing.bucketOrRootPath,
                  remote.googleCloudStorage == existing.googleCloudStorage else {
                lastError = .invalidConfiguration(reason: "A GCS connection cannot change its bucket. Create another connection.")
                return false
            }
        }
        do {
            if try domainRegistry?.isRegistered(remoteID: remote.id) == true {
                try domainRegistry?.ensureDescriptorStored(for: remote)
            }
        } catch {
            lastError = .invalidConfiguration(reason: error.localizedDescription)
            return false
        }
        remotes[index] = remote
        remoteStore.save(remotes)
        return true
    }

    /// Applies saved settings to an existing Finder domain without reconnecting it.
    public func saveRemoteSettings(_ remote: RemoteConfig) async throws {
        guard updateRemote(remote) else {
            throw lastError ?? FreeMountError.invalidConfiguration(reason: "The connection no longer exists.")
        }
        if let domainRegistry, try domainRegistry.isRegistered(remoteID: remote.id) {
            try await domainRegistry.refreshRegisteredDomain(for: remote)
        }
    }

    public func updateStatus(_ status: MountStatus, for remoteId: UUID) {
        mountStatuses[remoteId] = status
        // Keep connectionHealth consistent with mount status:
        // - failed/unmounted/unmounting → reset to .unknown (no longer verified)
        // - mounting → .checking (health probe is about to start)
        // - mounted → preserve existing health (set by validateAndRefreshConnection)
        switch status {
        case .failed, .unmounted, .unmounting:
            connectionHealth[remoteId] = .unknown
        case .mounting:
            connectionHealth[remoteId] = .checking
        case .mounted, .reconnecting:
            break
        }
    }

    public func clearError() {
        lastError = nil
    }

    private static func connectionIdentityKey(for remote: RemoteConfig) -> String {
        if remote.provider == .googleDrive, let sharedDriveID = remote.googleDriveSharedDriveID {
            return "\(remote.provider.rawValue):shared-drive:\(sharedDriveID)"
        }
        if remote.provider == .googleCloudStorage {
            return "gcs:bucket:\(remote.bucketOrRootPath)"
        }
        return "\(remote.provider.rawValue):name:\(remote.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public func applyTelemetry(_ snapshot: RcloneTelemetrySnapshot) {
        isDaemonRunning = snapshot.isDaemonRunning
        currentStats = snapshot.stats
    }

    public func refreshTelemetry(using supervisor: RcloneProcessSupervisor) async {
        let snapshot = await supervisor.telemetrySnapshot()
        applyTelemetry(snapshot)
    }

    public func restoreRemotesIfEmpty(from credentials: [KeychainCredentialRecord]) {
        guard remotes.isEmpty else { return }
        reconcileRemotes(from: credentials)
    }

    /// Synchronizes appState.remotes with real Keychain credentials.
    public func reconcileRemotes(from credentials: [KeychainCredentialRecord]) {
        for record in credentials {
            let provider = record.credential.provider
            let name = record.credential.remoteName

            let accountClean = record.account.replacingOccurrences(of: "credential.", with: "")
            let parsedID = UUID(uuidString: accountClean)
            if parsedID == nil {
                Self.log.warning("Keychain account key '\(accountClean, privacy: .public)' is not a UUID; matching by keychainAccountKey to prevent duplicates.")
            }
            let rootPath = provider == .googleDrive ? "/" : ""

            // Match priority:
            // 1. By keychainAccountKey — survives remote renames.
            // 2. By provider + name — catches legacy records without a stored key.
            if let existingIndex = remotes.firstIndex(where: { $0.keychainAccountKey == record.account })
                ?? remotes.firstIndex(where: {
                    provider != .googleCloudStorage &&
                    $0.provider == provider &&
                    $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
                    name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }) {
                remotes[existingIndex].keychainAccountKey = record.account
            } else {
                if provider == .googleCloudStorage { continue }
                // Only create a new entry when no existing remote matches.
                // Use the parsed UUID if available; otherwise generate a stable new UUID
                // (it is persisted on first write and matched via keychainAccountKey thereafter).
                let newID = parsedID ?? UUID()
                let config = RemoteConfig(
                    id: newID,
                    name: name,
                    provider: provider,
                    bucketOrRootPath: rootPath,
                    keychainAccountKey: record.account,
                    autoMountAtLaunch: false,
                    isReadOnly: false
                )
                remotes.append(config)
                mountStatuses[config.id] = .unmounted
                connectionHealth[config.id] = .unknown
            }
        }

        remoteStore.save(remotes)
        Self.log.info("reconcileRemotes completed. Total remotes: \(self.remotes.count)")
    }

    /// Reconciles registered File Provider domains on startup and updates remote status.
    public func reconcileDomains(
        using supervisor: RcloneProcessSupervisor? = nil
    ) async {
        Self.log.info("reconcileDomains started. Remotes count: \(self.remotes.count)")
        guard let domainRegistry else {
            Self.log.error("reconcileDomains aborted: domainRegistry is nil")
            return
        }

        let activeProviderRemotes = remotes.filter { ProviderRegistry.shared.provider(for: $0.provider) != nil }

        // 2. Fetch current system domains
        let systemDomains: [NSFileProviderDomain]
        do {
            systemDomains = try await domainRegistry.systemDomains()
            Self.log.info("systemDomains count: \(systemDomains.count), identifiers: \(systemDomains.map(\.identifier.rawValue))")
        } catch {
            Self.log.error("systemDomains failed: \(error.localizedDescription)")
            lastError = .invalidConfiguration(reason: "Could not read Finder domains: \(error.localizedDescription)")
            return
        }

        let startupRemotes = activeProviderRemotes.filter { remote in
            guard let descriptor = try? FileProviderDomainDescriptor(remote: remote) else { return remote.autoMountAtLaunch }
            return remote.autoMountAtLaunch || systemDomains.contains {
                $0.identifier.rawValue == descriptor.domainIdentifier && !$0.isDisconnected
            }
        }
        var daemonFailure: String?
        if !startupRemotes.isEmpty, let supervisor {
            do {
                _ = try await supervisor.startDaemon()
                isDaemonRunning = true
            } catch {
                isDaemonRunning = false
                daemonFailure = error.localizedDescription
                lastError = .invalidConfiguration(reason: "Could not start the cloud runtime: \(error.localizedDescription)")
            }
        }

        // Retain registered domains and their offline files. Branding updates use
        // the existing identifier rather than removing and recreating a domain.
        // 4. Reconcile active remotes
        for remote in activeProviderRemotes {
            let identifier: String
            do { identifier = try FileProviderDomainDescriptor(remote: remote).domainIdentifier }
            catch {
                updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
                lastError = .invalidConfiguration(reason: error.localizedDescription)
                continue
            }
            let existingDomain = systemDomains.first { $0.identifier.rawValue == identifier }
            guard remote.autoMountAtLaunch || existingDomain?.isDisconnected == false else {
                updateStatus(.unmounted, for: remote.id)
                continue
            }
            if let daemonFailure {
                if existingDomain?.isDisconnected == false {
                    let visiblePath = await resolveFinderPath(for: remote)
                    updateStatus(.mounted(mountedAt: Date(), mountPoint: visiblePath), for: remote.id)
                    connectionHealth[remote.id] = .unavailable(reason: daemonFailure)
                } else {
                    updateStatus(.failed(reason: daemonFailure), for: remote.id)
                }
                continue
            }
            Self.log.info("Registering or refreshing provider domain metadata for '\(remote.name)' (id: \(remote.id.uuidString))")
            do {
                _ = try await domainRegistry.registerDomain(for: remote)
            } catch {
                Self.log.error("Failed to register or refresh domain: \(error.localizedDescription)")
                let failure = FreeMountError.invalidConfiguration(reason: "Could not register Finder domain: \(error.localizedDescription)")
                updateStatus(.failed(reason: failure.localizedDescription), for: remote.id)
                lastError = failure
                continue
            }

            let visiblePath = await resolveFinderPath(for: remote)
            updateStatus(.mounted(mountedAt: Date(), mountPoint: visiblePath), for: remote.id)
            let health = await refreshConnectionHealth(for: remote)
            if health.isHealthy {
                do {
                    try? await domainRegistry.signalErrorResolved(NSFileProviderError(.notAuthenticated), for: remote)
                    try? await domainRegistry.signalErrorResolved(NSFileProviderError(.serverUnreachable), for: remote)
                    try await domainRegistry.signalEnumerator(for: remote)
                }
                catch { lastError = .invalidConfiguration(reason: error.localizedDescription) }
            }
            Self.log.info("Reconciled '\(remote.name)' with health \(health.statusLabel)")
        }

    }

    /// Verifies real provider access without changing File Provider registration.
    @discardableResult
    public func refreshConnectionHealth(for remote: RemoteConfig) async -> ConnectionHealth {
        guard let checkedRemote = remotes.first(where: { $0.id == remote.id }),
              ProviderRegistry.shared.provider(for: checkedRemote.provider) != nil else { return .unknown }
        let checkID = UUID()
        healthCheckIDs[remote.id] = checkID
        defer { if healthCheckIDs[remote.id] == checkID { healthCheckIDs.removeValue(forKey: remote.id) } }
        connectionHealth[remote.id] = .checking
        let result: ConnectionHealth
        if let gcs = customGCSHealthChecker, checkedRemote.provider == .googleCloudStorage {
            result = await gcs.check(checkedRemote)
        } else if let custom = customHealthChecker, checkedRemote.provider == .googleDrive {
            result = await custom.check(checkedRemote)
        } else {
            result = await providerRegistry.checkHealth(for: checkedRemote)
        }
        // A slower periodic check must not overwrite a newer manual check or
        // report a revoked old credential after replacement.
        guard healthCheckIDs[remote.id] == checkID else { return .unknown }
        guard let current = remotes.first(where: { $0.id == remote.id }) else { return .unknown }
        guard current == checkedRemote else { connectionHealth[remote.id] = .unknown; return .unknown }
        connectionHealth[remote.id] = result
        if let reason = result.reason {
            Self.log.error("Health check failed for \(checkedRemote.name, privacy: .public): \(reason, privacy: .public)")
        }
        return result
    }

    /// Validates a newly authorized credential and refreshes Finder on success.
    @discardableResult
    public func validateAndRefreshConnection(_ remote: RemoteConfig) async -> ConnectionHealth {
        let result = await refreshConnectionHealth(for: remote)
        if result.isHealthy, let domainRegistry {
            do {
                try? await domainRegistry.signalErrorResolved(NSFileProviderError(.notAuthenticated), for: remote)
                try? await domainRegistry.signalErrorResolved(NSFileProviderError(.serverUnreachable), for: remote)
                try? await domainRegistry.refreshRegisteredDomain(for: remote)
                try await domainRegistry.signalEnumerator(for: remote)
            }
            catch { lastError = .invalidConfiguration(reason: error.localizedDescription) }
        }
        return result
    }

    /// Mounts a remote configuration.
    /// Registered providers use Apple File Provider exclusively.
    public func mount(
        _ remote: RemoteConfig,
        using supervisor: RcloneProcessSupervisor,
        preferences: AppPreferences
    ) async {
        updateStatus(.mounting, for: remote.id)
        lastError = nil

        guard ProviderRegistry.shared.provider(for: remote.provider) != nil else {
            let error = FreeMountError.invalidConfiguration(
                reason: "\(remote.provider.displayName) is unavailable until its Apple File Provider integration is implemented."
            )
            updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
            lastError = error
            return
        }

        guard let domainRegistry else {
            let error = FreeMountError.invalidConfiguration(
                reason: "Apple File Provider domain registry is not configured."
            )
            updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
            lastError = error
            return
        }

        do {
            _ = try await supervisor.startDaemon()
            isDaemonRunning = true

            _ = try await domainRegistry.registerDomain(for: remote)
            let visiblePath = await resolveFinderPath(for: remote)
            updateStatus(.mounted(mountedAt: Date(), mountPoint: visiblePath), for: remote.id)
            let health = await validateAndRefreshConnection(remote)
            guard health.isHealthy else { return }
            if preferences.revealMountedDrives { await revealInFinder(remote) }
        } catch let error as FreeMountError {
            updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
            lastError = error
        } catch {
            let typedError = FreeMountError.invalidConfiguration(
                reason: "Could not connect '\(remote.name)': \(error.localizedDescription)"
            )
            updateStatus(.failed(reason: typedError.localizedDescription), for: remote.id)
            lastError = typedError
        }
    }

    /// Toggles the mount status of a remote.
    public func toggleMount(
        _ remote: RemoteConfig,
        using supervisor: RcloneProcessSupervisor,
        preferences: AppPreferences
    ) async {
        if status(for: remote.id).isMounted {
            await unmount(remote)
        } else {
            await mount(remote, using: supervisor, preferences: preferences)
        }
    }

    /// Resolve again when requested: a saved or previously observed path can be stale.
    public func revealInFinder(_ remote: RemoteConfig) async {
        lastError = nil
        guard let path = await resolveFinderPath(for: remote) else {
            if lastError == nil {
                lastError = .invalidConfiguration(reason: "macOS has not provided this connection's Finder location yet. Retry after it becomes available.")
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func resolveFinderPath(for remote: RemoteConfig) async -> String? {
        guard let domainRegistry else {
            lastError = .invalidConfiguration(reason: "Apple File Provider domain registry is not configured.")
            return nil
        }
        do { return try await domainRegistry.userVisiblePath(for: remote) }
        catch {
            lastError = .invalidConfiguration(reason: "Could not resolve the Finder location: \(error.localizedDescription)")
            return nil
        }
    }

    /// Performs an unmount while exposing a responsive intermediate state.
    public func unmount(_ remote: RemoteConfig) async {
        updateStatus(.unmounting, for: remote.id)
        lastError = nil

        if ProviderRegistry.shared.provider(for: remote.provider) != nil, let domainRegistry {
            do {
                guard try domainRegistry.isRegistered(remoteID: remote.id) else {
                    throw FreeMountError.invalidConfiguration(reason: "No Finder domain is registered for '\(remote.name)'.")
                }
                try await domainRegistry.disconnectDomain(for: remote)
                updateStatus(.unmounted, for: remote.id)
                connectionHealth[remote.id] = .unknown
                return
            } catch let error as FreeMountError {
                updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
                lastError = error
                return
            } catch {
                let typedError = FreeMountError.invalidConfiguration(
                    reason: "Could not disconnect '\(remote.name)': \(error.localizedDescription)"
                )
                updateStatus(.failed(reason: typedError.localizedDescription), for: remote.id)
                lastError = typedError
                return
            }
        }

        let error = FreeMountError.invalidConfiguration(
            reason: "No Apple File Provider domain is registered for '\(remote.name)'."
        )
        updateStatus(.failed(reason: error.localizedDescription), for: remote.id)
        lastError = error
    }
}
