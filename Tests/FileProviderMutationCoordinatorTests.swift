import XCTest
@testable import FreeMount

private struct TerminalJobBackend: FileProviderPathPrimitives {
    let client: RcloneClient
    let result: FileProviderRemoteItem
    private func mutate() async throws -> FileProviderRemoteItem {
        try await client.copyFile(sourceFS: .named("/tmp/fixture"), sourcePath: "a", destinationFS: .named("fixture:"), destinationPath: "a")
        return result
    }
    func upload(stagedFile: URL, to path: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem { try await mutate() }
    func move(from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem { try await mutate() }
    func listChildren(at path: String) async throws -> [FileProviderRemoteItem] { [result] }
    func stat(at path: String) async throws -> FileProviderRemoteItem? { result }
    func download(path: String, to stagingDirectory: URL) async throws -> URL { stagingDirectory }
    func upload(stagedFile: URL, to path: String) async throws { _ = try await mutate() }
    func createDirectory(at path: String) async throws { _ = try await mutate() }
    func deleteFile(at path: String) async throws { _ = try await mutate() }
    func deleteDirectory(at path: String, recursive: Bool) async throws { _ = try await mutate() }
    func move(from sourcePath: String, to destinationPath: String) async throws { _ = try await mutate() }
}

private actor LegacyCancellationBackend: FileProviderPathPrimitives {
    let started: XCTestExpectation
    let result: FileProviderRemoteItem
    private var continuation: CheckedContinuation<Void, Never>?
    private var complete = false
    init(started: XCTestExpectation, result: FileProviderRemoteItem) { self.started = started; self.result = result }
    func finish() { continuation?.resume(); continuation = nil }
    func listChildren(at path: String) async throws -> [FileProviderRemoteItem] { [] }
    func stat(at path: String) async throws -> FileProviderRemoteItem? {
        try Task.checkCancellation()
        return complete ? result : nil
    }
    func download(path: String, to stagingDirectory: URL) async throws -> URL { stagingDirectory }
    func upload(stagedFile: URL, to path: String) async throws {
        await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
        // Models a confirmed successful RC job racing caller cancellation.
        complete = true
    }
    func createDirectory(at path: String) async throws { try await upload(stagedFile: URL(fileURLWithPath: "/tmp/fixture"), to: path) }
    func deleteFile(at path: String) async throws { throw CocoaError(.featureUnsupported) }
    func deleteDirectory(at path: String, recursive: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw CocoaError(.featureUnsupported) }
}

final class FileProviderMutationCoordinatorTests: XCTestCase {
    private let http = MockHTTPRouter()
    override func tearDown() { http.handler = nil }

    func testLegacyPostWriteMetadataLookupIsUncancelledForFileAndFolderCreation() async throws {
        for folder in [false, true] {
            let started = expectation(description: "Mutation started")
            let result = FileProviderRemoteItem(id: "a", parentPath: "", path: "a", filename: "a", contentSize: 10, isDirectory: folder)
            let backend = LegacyCancellationBackend(started: started, result: result)
            let task = Task { try await FileProviderMutationCoordinator.create(backend: backend, path: "a", isDirectory: folder, contents: URL(fileURLWithPath: "/tmp/fixture")) }
            await fulfillment(of: [started], timeout: 3)
            task.cancel()
            await backend.finish()
            let produced = try await task.value
            XCTAssertEqual(produced, result)
        }
    }

    func testConfirmedCreateReplacementAndMoveReturnSuccessWhenCancellationRaces() async throws {
        for operation in ["create", "replace", "move"] {
            let running = expectation(description: "Job running")
            var stopping = false
            var signaled = false
            http.handler = { request in
                let json: String
                switch request.url!.path {
                case "/operations/copyfile": json = "{\"jobid\":4,\"executeId\":\"fixture\"}"
                case "/job/stopgroup": stopping = true; json = "{}"
                case "/job/status":
                    if !signaled { signaled = true; running.fulfill() }
                    json = "{\"id\":4,\"executeId\":\"fixture\",\"finished\":\(stopping),\"success\":\(stopping),\"error\":\"\"}"
                default: throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
            }
            let config = URLSessionConfiguration.ephemeral; http.configure(config)
            let result = FileProviderRemoteItem(id: "a", parentPath: "", path: "a", filename: "a", contentSize: 10, isDirectory: false, remoteObjectID: "fixture-id")
            let backend = TerminalJobBackend(client: RcloneClient(port: 5572, urlSession: URLSession(configuration: config), credentialProvider: testRPCCredentialProvider), result: result)
            let task = Task {
                if operation == "create" { return try await FileProviderMutationCoordinator.create(backend: backend, path: "a", isDirectory: false, contents: URL(fileURLWithPath: "/tmp/fixture")) }
                return try await FileProviderMutationCoordinator.modify(backend: backend, source: "a", destination: operation == "move" ? "b" : "a", condition: .contentVersion(result.contentVersion), contents: operation == "move" ? nil : URL(fileURLWithPath: "/tmp/fixture"))
            }
            await fulfillment(of: [running], timeout: 3)
            task.cancel()
            let produced = try await task.value
            XCTAssertEqual(produced, result)
            XCTAssertTrue(stopping)
        }
    }
}
