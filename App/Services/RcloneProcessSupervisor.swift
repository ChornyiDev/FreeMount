import Foundation
import os.log

/// Supervises the background lifecycle of the `rclone rcd` process
public actor RcloneProcessSupervisor {
    private static let log = Logger(subsystem: "com.freemount.app", category: "RcloneProcessSupervisor")

    public let port: Int
    public let customBinaryPath: String?
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var startupTask: Task<RcloneClient, Error>?
    public let client: RcloneClient
    private let credentialStore: RcloneRPCredentialStore

    public private(set) var isRunning: Bool = false
    public private(set) var daemonPID: Int32?
    public private(set) var startedAt: Date?
    private var lastReachabilityFailure: String?
    private var transferBatchTracker = TransferBatchProgressTracker()

    public init(port: Int = 5572, customBinaryPath: String? = nil, credentialStore: RcloneRPCredentialStore = .shared) {
        self.port = port
        self.customBinaryPath = customBinaryPath
        self.credentialStore = credentialStore
        self.client = RcloneClient(port: port, credentialProvider: { try await credentialStore.load() })
    }

    /// Spawns the rclone daemon process and awaits connectivity
    /// - Returns: Initialized and connected `RcloneClient`
    @discardableResult
    public func startDaemon() async throws -> RcloneClient {
        if let existingTask = startupTask {
            return try await existingTask.value
        }

        let task = Task { [self] () -> RcloneClient in
            try await self.spawnAndAwaitDaemon()
        }
        self.startupTask = task
        defer { self.startupTask = nil }

        return try await task.value
    }

    private func spawnAndAwaitDaemon() async throws -> RcloneClient {
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            throw FreeMountError.daemonNotRunning
        }
        _ = try await credentialStore.loadOrCreate()
        if try await client.authenticatedEndpointIsReachable() {
            self.isRunning = true
            return client
        }

        // 1. Resolve executable
        let binaryPath = try RcloneBinaryLocator.resolveBinaryPath(customPath: customBinaryPath)

        // 2. Prepare process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = RcloneDaemonLaunch.arguments(port: port)
        proc.environment = RcloneDaemonLaunch.environment()
        proc.standardInput = try RcloneDaemonLaunch.authenticationInput(credentials: await credentialStore.load())

        let outPipe = Pipe()
        let errPipe = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Self.log.notice("[rclone] \(text, privacy: .public)")
            }
        }
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.outputPipe = outPipe
        self.errorPipe = errPipe
        self.process = proc

        // Termination handler
        proc.terminationHandler = { [weak self] terminatedProc in
            Task { [weak self] in
                await self?.handleTermination(status: terminatedProc.terminationStatus)
            }
        }

        // 3. Launch
        do {
            try proc.run()
            self.daemonPID = proc.processIdentifier
            self.startedAt = Date()
            self.isRunning = true
        } catch {
            cleanupPipes()
            self.isRunning = false
            self.daemonPID = nil
            self.startedAt = nil
            throw FreeMountError.mountFailed(
                remoteName: "rclone-rcd",
                path: "127.0.0.1:\(port)",
                reason: "Failed to launch process: \(error.localizedDescription)"
            )
        }

        // 4. Await readiness with retries (up to 3 seconds)
        let ready = await pollUntilReachable(maxAttempts: 15, delayMilliseconds: 200)
        guard ready else {
            await stopDaemon()
            let detail = lastReachabilityFailure ?? "rclone RC did not become reachable within 3 seconds."
            throw FreeMountError.mountFailed(
                remoteName: "rclone-rcd",
                path: "127.0.0.1:\(port)",
                reason: detail
            )
        }

        return client
    }

    /// Ensures the RC endpoint is available and reports whether a new process was started.
    public func ensureDaemonRunning() async throws -> Bool {
        if await client.isReachable() {
            isRunning = true
            return false
        }

        _ = try await startDaemon()
        return true
    }

    /// Gracefully stops the rclone daemon with a timeout before escalating to SIGKILL.
    /// - Parameter timeout: Maximum time in seconds to wait for graceful termination.
    /// - Returns: `true` if the daemon stopped gracefully or was not running, `false` if it had to be force-killed.
    @discardableResult
    public func stopDaemon(timeout: TimeInterval = 1.0) async -> Bool {
        startupTask?.cancel()
        startupTask = nil

        guard let proc = process, proc.isRunning else {
            self.isRunning = false
            self.daemonPID = nil
            self.startedAt = nil
            self.process = nil
            return true
        }

        let pid = proc.processIdentifier
        proc.terminate()

        // Wait up to timeout for clean termination without escaping actor isolation
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }

        var cleanExit = true
        if proc.isRunning {
            cleanExit = false
            kill(pid, SIGKILL)
        }

        self.cleanupPipes()
        self.isRunning = false
        self.daemonPID = nil
        self.startedAt = nil
        self.process = nil
        return cleanExit
    }

    public func daemonStatus() async -> RcloneDaemonStatus {
        guard await client.isReachable() else {
            isRunning = false
            daemonPID = nil
            startedAt = nil
            return RcloneDaemonStatus(isRunning: false, port: port)
        }
        isRunning = true
        let version = try? await client.getVersion().version
        let pid = try? await client.getPid()
        if let pid { daemonPID = Int32(pid) }
        return RcloneDaemonStatus(
            isRunning: true,
            pid: pid ?? daemonPID.map(Int.init),
            startedAt: startedAt,
            version: version,
            port: port
        )
    }

    public func restartDaemon() async throws -> RcloneDaemonStatus {
        if let process, process.isRunning {
            await stopDaemon()
        } else if await client.isReachable() {
            try await client.quit()
            _ = await pollUntilUnreachable(maxAttempts: 20, delayMilliseconds: 100)
            isRunning = false
            daemonPID = nil
            startedAt = nil
        }

        try await Task.sleep(for: .milliseconds(150))
        _ = try await startDaemon()
        return await daemonStatus()
    }

    /// Reads one safe UI telemetry sample without surfacing polling failures as user alerts.
    public func telemetrySnapshot() async -> RcloneTelemetrySnapshot {
        guard isRunning else {
            return RcloneTelemetrySnapshot(isDaemonRunning: false, hasTransferStats: false)
        }

        do {
            let rawStats = try await client.getStats()
            let stats = transferBatchTracker.apply(to: rawStats)
            let completed: [CompletedTransfer]?
            do { completed = try await client.getCompletedTransfers() }
            catch { completed = nil }
            return RcloneTelemetrySnapshot(isDaemonRunning: true, stats: stats, completedTransfers: completed)
        } catch {
            // A stats request can fail transiently; confirm daemon reachability before
            // declaring it offline and clearing its published process state.
            let reachable = await client.isReachable()
            if !reachable {
                isRunning = false
                daemonPID = nil
            }
            return RcloneTelemetrySnapshot(isDaemonRunning: reachable, hasTransferStats: false)
        }
    }

    private func cleanupPipes() {
        if let out = outputPipe {
            out.fileHandleForReading.readabilityHandler = nil
            try? out.fileHandleForReading.close()
            outputPipe = nil
        }
        if let err = errorPipe {
            err.fileHandleForReading.readabilityHandler = nil
            try? err.fileHandleForReading.close()
            errorPipe = nil
        }
    }

    private func handleTermination(status: Int32) {
        self.cleanupPipes()
        self.isRunning = false
        self.daemonPID = nil
        self.startedAt = nil
        self.process = nil
    }

    private func pollUntilReachable(maxAttempts: Int, delayMilliseconds: UInt64) async -> Bool {
        for _ in 0..<maxAttempts {
            do {
                if try await client.authenticatedEndpointIsReachable() { return true }
            } catch {
                lastReachabilityFailure = error.localizedDescription
            }
            try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        }
        return false
    }

    private func pollUntilUnreachable(maxAttempts: Int, delayMilliseconds: UInt64) async -> Bool {
        for _ in 0..<maxAttempts {
            if !(await client.isReachable()) {
                return true
            }
            try? await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
        }
        return false
    }
}
