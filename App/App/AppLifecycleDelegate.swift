import AppKit
import FileProvider
import os.log

/// Coordinates process recovery and bounded graceful shutdown with AppKit.
@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.freemount.app", category: "AppLifecycleDelegate")
    private static weak var _instance: AppLifecycleDelegate?

    static var shared: AppLifecycleDelegate? {
        get {
            _instance ?? (NSApplication.shared.delegate as? AppLifecycleDelegate)
        }
        set {
            _instance = newValue
        }
    }

    var supervisor: RcloneProcessSupervisor?
    var appState: AppState?
    var keychain: KeychainService?
    var domainRegistry: FileProviderDomainRegistry?
    private var terminationTask: Task<Void, Never>?
    private var remoteRefreshTask: Task<Void, Never>?
    private var daemonRecoveryTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var hasStarted = false

    override init() {
        super.init()
        Self._instance = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.log.info("applicationDidFinishLaunching triggered")
        performStartup()
    }

    func performStartup() {
        guard !hasStarted, let supervisor, let appState, let keychain else {
            Self.log.info("performStartup deferred (missing dependencies or already started)")
            return
        }
        hasStarted = true
        Self.log.info("Performing FreeMount startup sequence")

        Task {
            if appState.remotes.isEmpty {
                do {
                    let credentials = try await keychain.listCredentials()
                    Self.log.info("Startup found \(credentials.count) credentials in Keychain")
                    appState.restoreRemotesIfEmpty(from: credentials)
                } catch {
                    Self.log.error("Startup failed to list keychain credentials: \(error.localizedDescription, privacy: .public)")
                    appState.lastError = .keychainError(status: -1, message: "Could not restore saved credentials: \(error.localizedDescription)")
                }
            }

            Self.log.info("Startup reconciling domains for \(appState.remotes.count) remotes")
            await appState.reconcileDomains(using: supervisor)
            Self.log.info("Startup reconciliation finished. Daemon running: \(appState.isDaemonRunning)")
            if let domainRegistry = self.domainRegistry {
                self.remoteRefreshTask = Task {
                    var refreshCycle = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled else { break }
                        refreshCycle += 1
                        for remote in appState.remotes where appState.status(for: remote.id).isMounted {
                            do {
                                try await domainRegistry.signalEnumerator(for: remote)
                            } catch {
                                Self.log.error("Failed to refresh Finder for \(remote.name): \(error.localizedDescription)")
                            }
                            if refreshCycle.isMultiple(of: 4) {
                                let health = await appState.refreshConnectionHealth(for: remote)
                                if health.isHealthy {
                                    try? await domainRegistry.signalErrorResolved(NSFileProviderError(.notAuthenticated), for: remote)
                                    try? await domainRegistry.signalErrorResolved(NSFileProviderError(.serverUnreachable), for: remote)
                                }
                            }
                        }
                    }
                }
            }

            self.startDaemonRecoveryLoop(
                supervisor: supervisor,
                appState: appState,
                domainRegistry: self.domainRegistry
            )
            self.startTelemetryLoop(supervisor: supervisor, appState: appState)
        }
    }

    private func startTelemetryLoop(supervisor: RcloneProcessSupervisor, appState: AppState) {
        telemetryTask?.cancel()
        telemetryTask = Task {
            while !Task.isCancelled {
                await appState.refreshTelemetry(using: supervisor)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startDaemonRecoveryLoop(
        supervisor: RcloneProcessSupervisor,
        appState: AppState,
        domainRegistry: FileProviderDomainRegistry?
    ) {
        daemonRecoveryTask?.cancel()
        daemonRecoveryTask = Task {
            var retryDelay: Duration = .seconds(5)

            while !Task.isCancelled {
                try? await Task.sleep(for: retryDelay)
                guard !Task.isCancelled else { break }

                let activeRemotes = appState.remotes.filter { remote in
                    let status = appState.status(for: remote.id)
                    if status.isMounted { return true }
                    if case .failed = status {
                        return remote.autoMountAtLaunch && ProviderRegistry.shared.provider(for: remote.provider) != nil
                    }
                    return false
                }
                guard !activeRemotes.isEmpty else {
                    retryDelay = .seconds(5)
                    continue
                }

                do {
                    let recovered = try await supervisor.ensureDaemonRunning()
                    appState.isDaemonRunning = true
                    retryDelay = .seconds(5)

                    let needsRegistration = activeRemotes.contains { remote in
                        if case .failed = appState.status(for: remote.id) { return remote.autoMountAtLaunch }
                        return false
                    }
                    if recovered || needsRegistration, let domainRegistry {
                        Self.log.notice("Reconciling File Provider domains after runtime readiness")
                        await appState.reconcileDomains()
                        for remote in activeRemotes where appState.status(for: remote.id).isMounted {
                            do {
                                try await domainRegistry.signalEnumerator(for: remote)
                            } catch {
                                Self.log.error("Failed to refresh Finder after daemon recovery for \(remote.name): \(error.localizedDescription)")
                            }
                        }
                    }
                } catch {
                    appState.isDaemonRunning = false
                    Self.log.error("Rclone daemon recovery failed: \(error.localizedDescription)")
                    retryDelay = min(retryDelay * 2, .seconds(60))
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        remoteRefreshTask?.cancel()
        daemonRecoveryTask?.cancel()
        telemetryTask?.cancel()
        guard let supervisor else { return .terminateNow }
        if terminationTask != nil { return .terminateLater }

        terminationTask = Task { [weak self] in
            let clean = await supervisor.stopDaemon(timeout: 1.5)
            if !clean {
                NSLog("rclone daemon did not terminate cleanly within timeout; escalated to SIGKILL.")
            }
            sender.reply(toApplicationShouldTerminate: true)
            self?.terminationTask = nil
        }
        return .terminateLater
    }
}
