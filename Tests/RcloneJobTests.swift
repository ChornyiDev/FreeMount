import XCTest
@testable import FreeMount

final class RcloneJobTests: XCTestCase {
    private let http = MockHTTPRouter()
    private func client() -> RcloneClient {
        let config = URLSessionConfiguration.ephemeral
        http.configure(config)
        return RcloneClient(port: 5572, urlSession: URLSession(configuration: config), credentialProvider: testRPCCredentialProvider)
    }
    private func reply(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }
    private func status(finished: Bool, success: Bool = true, instance: String = "test", error: String = "") throws -> String {
        struct Status: Encodable { let id = 4; let executeId: String; let finished: Bool; let success: Bool; let error: String }
        return String(decoding: try JSONEncoder().encode(Status(executeId: instance, finished: finished, success: success, error: error)), as: UTF8.self)
    }
    private func copy(_ client: RcloneClient) async throws {
        try await client.copyFile(sourceFS: .named("/tmp/source"), sourcePath: "file", destinationFS: .named("remote:"), destinationPath: "file")
    }
    override func tearDown() { http.handler = nil }

    func testPollTimeoutDoesNotResubmitAndTerminalSuccessWins() async throws {
        var submissions = 0
        var polls = 0
        http.handler = { request in
            switch request.url!.path {
            case "/operations/copyfile":
                submissions += 1
                return self.reply(request, "{\"jobid\":4,\"executeId\":\"test\"}")
            case "/job/status":
                polls += 1
                if polls == 1 { throw URLError(.timedOut) }
                return self.reply(request, try self.status(finished: true))
            case "/job/stopgroup": return self.reply(request, "{}")
            default: throw URLError(.unsupportedURL)
            }
        }
        try await copy(client())
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(polls, 2)
    }

    func testCancellationWaitsForStoppedJobBeforeRemovingStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstPoll = expectation(description: "Job is running")
        var stopping = false
        var signaled = false
        var stoppedPolls = 0
        http.handler = { request in
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            switch request.url!.path {
            case "/operations/copyfile": return self.reply(request, "{\"jobid\":4,\"executeId\":\"test\"}")
            case "/job/stopgroup": stopping = true; return self.reply(request, "{}")
            case "/job/status":
                if !signaled { signaled = true; firstPoll.fulfill() }
                if stopping { stoppedPolls += 1 }
                return self.reply(request, try self.status(finished: stoppedPolls >= 2, success: false, error: "context canceled"))
            default: throw URLError(.unsupportedURL)
            }
        }
        let client = client()
        let transfer = Task {
            try await RcloneTransferStaging.withCleanup(in: directory) { try await self.copy(client) }
        }
        await fulfillment(of: [firstPoll], timeout: 3)
        transfer.cancel()
        do { try await transfer.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(stopping)
        XCTAssertGreaterThanOrEqual(stoppedPolls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDaemonRestartCannotReportSuccessForReusedJobIDAndRetainsStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        http.handler = { request in
            if request.url!.path == "/operations/copyfile" { return self.reply(request, "{\"jobid\":4,\"executeId\":\"test\"}") }
            return self.reply(request, try self.status(finished: true, instance: "restarted"))
        }
        do {
            try await RcloneTransferStaging.withCleanup(in: directory) { try await self.copy(self.client()) }
            XCTFail("Reused job ID cannot establish success")
        } catch { XCTAssertTrue(error is RcloneJobError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLostSubmissionResponseRetainsStagingAndDoesNotResubmit() async throws {
        var submissions = 0
        http.handler = { _ in submissions += 1; throw URLError(.timedOut) }
        do { try await copy(client()); XCTFail("Expected unknown outcome") }
        catch { XCTAssertTrue(error is RcloneJobError) }
        XCTAssertEqual(submissions, 1)
    }

    func testJobFailureRedactsSecrets() async throws {
        http.handler = { request in
            if request.url!.path == "/operations/copyfile" { return self.reply(request, "{\"jobid\":4,\"executeId\":\"test\"}") }
            if request.url!.path == "/job/stopgroup" { return self.reply(request, "{}") }
            return self.reply(request, try self.status(finished: true, success: false, error: "{\"access_token\":\"very-secret\"}"))
        }
        do { try await copy(client()); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("very-secret")) }
    }
}
