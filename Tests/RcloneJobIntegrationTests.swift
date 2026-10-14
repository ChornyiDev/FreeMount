import XCTest
@testable import FreeMount

/// Opt-in local HTTP transfer: no cloud accounts, production daemon or Keychain.
final class RcloneJobIntegrationTests: XCTestCase {
    private func runtime() throws -> URL {
        guard ProcessInfo.processInfo.environment["FREEMOUNT_RCLONE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set FREEMOUNT_RCLONE_INTEGRATION=1 for throttled local transfer checks")
        }
        let path = try testRcloneRuntimePath()
        return URL(fileURLWithPath: path)
    }

    /// Process.waitUntilExit can block a cooperative executor after the child
    /// exits. Observe OS liveness with bounded asynchronous waits instead.
    private func stop(_ process: Process) async {
        let pid = process.processIdentifier
        guard pid > 0, kill(pid, 0) == 0 else { return }
        if process.isRunning { process.terminate() }
        for _ in 0..<50 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Disposable integration process did not terminate")
    }

    func testThrottledTransferExceedsHTTPDeadlineAndCancellationStopsJob() async throws {
        let binary = try runtime()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let data = Data(repeating: 0x57, count: 2 * 1024 * 1024)
        try data.write(to: source.appendingPathComponent("file.bin"))
        let http = Process()
        let daemon = Process()
        let basePort = Int.random(in: 59000..<61000)
        let sink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer {
            try? sink.close()
            try? FileManager.default.removeItem(at: directory)
        }
        do {
        http.executableURL = binary
        http.arguments = ["serve", "http", source.path, "--addr", "127.0.0.1:\(basePort)", "--config", "/dev/null"]
        http.standardOutput = sink; http.standardError = sink
        try http.run()
        daemon.executableURL = binary
        daemon.arguments = ["rcd", "--rc-addr", "127.0.0.1:\(basePort + 1)", "--config", "/dev/null", "--rc-htpasswd=/dev/stdin", "--bwlimit", "96k"]
        let credential = try RcloneRPCredentials.generate()
        daemon.environment = RcloneDaemonLaunch.environment()
        daemon.standardInput = try RcloneDaemonLaunch.authenticationInput(credentials: credential)
        daemon.standardOutput = sink; daemon.standardError = sink
        try daemon.run()
        let client = RcloneClient(port: basePort + 1, credentialProvider: { credential })
        var ready = false
        for _ in 0..<40 {
            if await client.isReachable() { ready = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(ready)
        guard ready else { throw URLError(.cannotConnectToHost) }
        try await Task.sleep(for: .milliseconds(200))
        let sourceFS = RcloneFileSystemReference.configuration(["type": "http", "url": "http://127.0.0.1:\(basePort)/"])
        let start = ContinuousClock.now
        try await client.copyFile(sourceFS: sourceFS, sourcePath: "file.bin", destinationFS: .named(destination.path), destinationPath: "complete.bin")
        XCTAssertGreaterThan(start.duration(to: .now), .seconds(15))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("complete.bin")), data)
        let cancelled = Task {
            try await client.copyFile(sourceFS: sourceFS, sourcePath: "file.bin", destinationFS: .named(destination.path), destinationPath: "cancelled.bin")
        }
        try await Task.sleep(for: .seconds(1))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        struct JobList: Decodable { let jobids: [Int] }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(basePort + 1)/job/list")!)
        request.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        let (response, _) = try await URLSession.shared.data(for: request)
        let jobs = try JSONDecoder().decode(JobList.self, from: response)
        struct Status: Decodable { let finished: Bool }
        struct JobRequest: Encodable { let jobid: Int }
        for id in jobs.jobids {
            var statusRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(basePort + 1)/job/status")!)
            statusRequest.setValue(credential.authorizationHeader, forHTTPHeaderField: "Authorization")
            statusRequest.httpMethod = "POST"
            statusRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            statusRequest.httpBody = try JSONEncoder().encode(JobRequest(jobid: id))
            let (body, _) = try await URLSession.shared.data(for: statusRequest)
            XCTAssertTrue(try JSONDecoder().decode(Status.self, from: body).finished)
        }
        } catch {
            await stop(daemon)
            await stop(http)
            throw error
        }
        await stop(daemon)
        await stop(http)

    }
}
