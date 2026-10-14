import FileProvider
import Foundation
import os.log

/// Protocol abstracting system NSFileProviderManager operations for unit testability.
public protocol FileProviderManagerProtocol: Sendable {
    func add(_ domain: NSFileProviderDomain) async throws
    func remove(_ domain: NSFileProviderDomain) async throws
    func disconnect(_ domain: NSFileProviderDomain, reason: String) async throws
    func reconnect(_ domain: NSFileProviderDomain) async throws
    func getDomains() async throws -> [NSFileProviderDomain]
    func getUserVisibleURL(for domain: NSFileProviderDomain) async throws -> URL?
    func signalEnumerator(for domain: NSFileProviderDomain) async throws
    func signalErrorResolved(_ error: Error, for domain: NSFileProviderDomain) async throws
}

public extension FileProviderManagerProtocol {
    func disconnect(_ domain: NSFileProviderDomain, reason: String) async throws {}
    func reconnect(_ domain: NSFileProviderDomain) async throws {}
    func signalEnumerator(for domain: NSFileProviderDomain) async throws {}
    func signalErrorResolved(_ error: Error, for domain: NSFileProviderDomain) async throws {}
}

/// Default production implementation calling NSFileProviderManager.
public final class SystemFileProviderManager: FileProviderManagerProtocol {
    public init() {}

    public func add(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: FileProviderDomainError.systemRegistrationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func remove(_ domain: NSFileProviderDomain) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    continuation.resume(throwing: FileProviderDomainError.systemRegistrationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func disconnect(_ domain: NSFileProviderDomain, reason: String) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FileProviderDomainError.systemRegistrationFailed("Failed to obtain NSFileProviderManager for domain \(domain.identifier.rawValue)")
        }
        try await manager.disconnect(reason: reason, options: [])
    }

    public func reconnect(_ domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw FileProviderDomainError.systemRegistrationFailed("Failed to obtain NSFileProviderManager for domain \(domain.identifier.rawValue)")
        }
        try await manager.reconnect()
    }

    public func getDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: FileProviderDomainError.systemRegistrationFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: domains)
                }
            }
        }
    }

    public func getUserVisibleURL(for domain: NSFileProviderDomain) async throws -> URL? {
        guard let manager = NSFileProviderManager(for: domain) else {
            return nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }

    public func signalEnumerator(for domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            return
        }
        let domainIdentifier = domain.identifier.rawValue
        let defaults = UserDefaults(suiteName: FileProviderDomainStore.appGroupIdentifier)
        let prefix = "fileProviderSnapshot.v1.\(domainIdentifier)."
        let snapshotFolders = defaults?.dictionaryRepresentation().keys.compactMap { key -> NSFileProviderItemIdentifier? in
            guard key.hasPrefix(prefix) else { return nil }
            let raw = String(key.dropFirst(prefix.count))
            return raw.hasPrefix("p:") ? NSFileProviderItemIdentifier(raw) : nil
        } ?? []
        let store = FileProviderDomainStore()
        let known = store.knownFolders(forDomain: domainIdentifier).map {
            NSFileProviderItemIdentifier.remoteItem(path: $0)
        }
        let allFolders = Array(Set(snapshotFolders + known))
        var criticalError: Error?
        for identifier in [NSFileProviderItemIdentifier.workingSet, .rootContainer] + allFolders {
            let error: Error? = await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: identifier) { error in
                    continuation.resume(returning: error)
                }
            }
            if let error {
                NSLog("[SystemFileProviderManager] Failed to signal enumerator for domain '%@', item '%@': %@",
                      domainIdentifier, identifier.rawValue, error.localizedDescription)
                if (identifier == .workingSet || identifier == .rootContainer) && criticalError == nil {
                    criticalError = error
                }
            }
        }
        if let criticalError {
            throw criticalError
        }
    }

    public func signalErrorResolved(_ error: Error, for domain: NSFileProviderDomain) async throws {
        guard let manager = NSFileProviderManager(for: domain) else {
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.signalErrorResolved(error as NSError) { err in
                if let err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Registers and removes Finder-visible replicated domains from the host app.
///
/// This type contains no credentials. The extension resolves the descriptor's
/// remote ID to its Keychain account only after production signing grants both
/// targets the shared Keychain access group.
@MainActor
public final class FileProviderDomainRegistry {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FileProviderDomainRegistry")
    private let store: FileProviderDomainStore
    private let manager: any FileProviderManagerProtocol

    public init(
        store: FileProviderDomainStore = FileProviderDomainStore(),
        manager: any FileProviderManagerProtocol = SystemFileProviderManager()
    ) {
        self.store = store
        self.manager = manager
    }

    public func systemDomains() async throws -> [NSFileProviderDomain] {
        try await manager.getDomains()
    }

    public func isRegistered(remoteID: UUID) throws -> Bool {
        try store.connection(for: remoteID) != nil
    }

    public func connection(for remoteID: UUID) throws -> FileProviderConnectionDescriptor? {
        try store.connection(for: remoteID)
    }

    public func registeredConnections() throws -> [FileProviderConnectionDescriptor] {
        try store.all()
    }

    /// Ensures the connection descriptor is persisted in the shared domain store.
    public func ensureDescriptorStored(for remote: RemoteConfig) throws {
        guard ProviderRegistry.shared.provider(for: remote.provider) != nil,
              let connection = try? FileProviderConnectionDescriptor(remote: remote) else {
            return
        }
        try store.upsert(connection)
    }

    /// Publishes access policy immediately; disconnected domains stay disconnected.
    public func refreshRegisteredDomain(for remote: RemoteConfig) async throws {
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        try store.upsert(connection)
        let domains = try await manager.getDomains()
        guard let existing = domains.first(where: { $0.identifier.rawValue == connection.id }),
              !existing.isDisconnected else { return }
        let updated = NSFileProviderDomain(identifier: existing.identifier, displayName: connection.domain.displayName)
        updated.isHidden = existing.isHidden
        try await manager.add(updated)
        try? await manager.signalErrorResolved(NSFileProviderError(.notAuthenticated), for: updated)
        try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable), for: updated)
        try await manager.signalEnumerator(for: updated)
    }

    @discardableResult
    public func registerDomain(
        for remote: RemoteConfig
    ) async throws -> FileProviderDomainDescriptor {
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        let descriptor = connection.domain
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )

        // 1. Ensure descriptor is written to shared container BEFORE system registration
        try store.upsert(connection)

        // Existing domain/cache identities survive errors; never remove/recreate
        // a registered domain as an implicit reconnect fallback.
        let existing = try await manager.getDomains()
        if let existingDomain = existing.first(where: { $0.identifier == domain.identifier }) {
            if existingDomain.isDisconnected { try await manager.reconnect(existingDomain) }
            domain.isHidden = false
            try await manager.add(domain)
        } else {
            domain.isHidden = false
            try await manager.add(domain)
        }
        return descriptor
    }

    public func disconnectDomain(
        for remote: RemoteConfig
    ) async throws {
        let descriptor = try FileProviderDomainDescriptor(remote: remote)
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )

        try await manager.disconnect(domain, reason: "Disk unmounted in FreeMount")

        // Hide domain from Finder sidebar (Locations) while keeping offline cache and bookmarks intact
        domain.isHidden = true
        try await manager.add(domain)

        Self.log.info("Disconnected and hid domain '\(descriptor.displayName)' (\(descriptor.domainIdentifier))")
    }

    public func removeDomain(
        for remote: RemoteConfig
    ) async throws {
        let descriptor = try FileProviderDomainDescriptor(remote: remote)
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )

        try await manager.remove(domain)
        try store.remove(remoteID: descriptor.remoteID)
        Self.log.info("Removed domain '\(descriptor.displayName)' (\(descriptor.domainIdentifier))")
    }

    public func removeDomain(
        remoteID: UUID
    ) async throws {
        guard let connection = try store.connection(for: remoteID) else { return }
        let descriptor = connection.domain
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )

        try await manager.remove(domain)
        try store.remove(remoteID: descriptor.remoteID)
        Self.log.info("Removed domain by remoteID '\(descriptor.displayName)' (\(descriptor.domainIdentifier))")
    }

    public func removeSystemDomain(_ domain: NSFileProviderDomain) async throws {
        try await manager.remove(domain)
        Self.log.info("Removed system domain \(domain.identifier.rawValue)")
    }

    public func signalEnumerator(for remote: RemoteConfig) async throws {
        guard let descriptor = try? FileProviderDomainDescriptor(remote: remote) else { return }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )
        try await manager.signalEnumerator(for: domain)
        Self.log.info("Signaled enumerator for domain \(descriptor.domainIdentifier)")
    }

    public func signalErrorResolved(_ error: Error, for remote: RemoteConfig) async throws {
        guard let descriptor = try? FileProviderDomainDescriptor(remote: remote) else { return }
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )
        try await manager.signalErrorResolved(error, for: domain)
        Self.log.info("Signaled error resolved for domain \(descriptor.domainIdentifier)")
    }

    public func signalErrorResolved(_ error: Error, for domain: NSFileProviderDomain) async throws {
        try await manager.signalErrorResolved(error, for: domain)
        Self.log.info("Signaled error resolved for domain \(domain.identifier.rawValue)")
    }

    /// Only macOS knows a domain's actual location, including collision suffixes.
    public func userVisiblePath(for remote: RemoteConfig) async throws -> String? {
        let descriptor = try FileProviderDomainDescriptor(remote: remote)
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
            displayName: descriptor.displayName
        )
        return try await manager.getUserVisibleURL(for: domain)?.path
    }
}
