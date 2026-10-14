import XCTest
@testable import FreeMount

final class GoogleCloudPathPolicyTests: XCTestCase {
    private let http = MockHTTPRouter()
    private func item(_ path: String, directory: Bool = false) -> RcloneListedItem {
        .init(path: path, name: path, size: 0, isDir: directory, id: "fixture-id")
    }
    func testInvalidPathsNeverBecomeAnotherObject() {
        for path in ["/file", "file/", "folder//file", "folder/./file", "folder/../file", "file\0"] {
            XCTAssertThrowsError(try GoogleCloudPathPolicy.validate(path), path)
            XCTAssertThrowsError(try FileProviderPath.validated(path, for: .googleCloudStorage), path)
        }
        XCTAssertEqual(try FileProviderPath.validated("/folder//file/", for: .googleDrive), "folder/file")
    }
    func testUnicodeBytesArePreservedWhenUnambiguous() throws {
        for path in ["café", "cafe\u{301}", "Фото/літо.jpg"] {
            XCTAssertEqual(Array(try GoogleCloudPathPolicy.validate(path).utf8), Array(path.utf8))
        }
    }
    func testCollisionGroupsAreEntirelyHidden() {
        let raw = [item("same"), item("same", directory: true), item("Photo"), item("photo"), item("café"), item("cafe\u{301}"), item("good")]
        let result = GoogleCloudPathPolicy.partition(raw, parent: "")
        XCTAssertEqual(result.supported.map(\.path), ["good"])
        XCTAssertEqual(result.omitted, 6)
    }
    func testMalformedNeighborDoesNotHideCanonicalObject() {
        let result = GoogleCloudPathPolicy.partition([item("folder/file"), item("folder//file"), item("folder/./file")], parent: "folder")
        XCTAssertEqual(result.supported.map(\.path), ["folder/file"])
        XCTAssertEqual(result.omitted, 2)
    }
    override func tearDown() { http.handler = nil }
    private struct ListPayload: Decodable { let remote: String }
    private func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    private func backend() throws -> GoogleCloudStorageFileProviderBackend {
        let selection = try GoogleCloudStorageSelection(projectID: "test-project", projectNumber: "123", bucket: "test-bucket")
        let remote = RemoteConfig(name: "Test", provider: .googleCloudStorage, bucketOrRootPath: "test-bucket", keychainAccountKey: "test-key", googleCloudStorage: selection)
        let authorization = GoogleDriveAuthorization(tokenJSON: "{\"access_token\":\"test\"}", client: try GoogleDriveOAuthClient(clientID: "test"))
        let config = URLSessionConfiguration.ephemeral; http.configure(config)
        return try .init(connection: FileProviderConnectionDescriptor(remote: remote), client: RcloneClient(port: 5572, urlSession: URLSession(configuration: config), credentialProvider: testRPCCredentialProvider), credential: selection.credential(authorization: authorization, remoteName: "Test"))
    }
    func testListingOmitsUnsupportedNamesButKeepsHealthySiblings() async throws {
        http.handler = { request in
            let result = RcloneListResponse(items: [self.item("good"), self.item("bad//name"), self.item("same"), self.item("same", directory: true)])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(result))
        }
        let result = try await backend().listChildren(at: "")
        XCTAssertEqual(result.map(\.path), ["good"])
    }
    func testStaleAmbiguousItemIsRejectedBeforeStatOrDelete() async throws {
        http.handler = { request in
            XCTAssertEqual(request.url!.path, "/operations/list")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(RcloneListResponse(items: [self.item("same"), self.item("same", directory: true)])))
        }
        let backend = try backend()
        do { _ = try await backend.stat(at: "same"); XCTFail("Expected ambiguity") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        do { try await backend.deleteFile(at: "same"); XCTFail("Expected ambiguity") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
    }
    func testRecursiveDeletionAndMoveRejectHiddenDescendantsBeforeMutation() async throws {
        http.handler = { request in
            let payload = try JSONDecoder().decode(ListPayload.self, from: self.body(request))
            let response: Data
            if request.url!.path == "/operations/list" {
                let items = payload.remote.isEmpty ? [self.item("source", directory: true)] : [self.item("source/good"), self.item("source//hidden")]
                response = try JSONEncoder().encode(RcloneListResponse(items: items))
            } else {
                XCTAssertEqual(request.url!.path, "/operations/stat", "Mutation must never start")
                response = Data((payload.remote == "source" ? "{\"item\":{\"Path\":\"source\",\"Name\":\"source\",\"Size\":0,\"IsDir\":true,\"ID\":\"fixture-id\"}}" : "{\"item\":null}").utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, response)
        }
        let backend = try backend()
        do { try await backend.deleteDirectory(at: "source", recursive: true); XCTFail("Expected hidden descendant rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        do { try await backend.move(from: "source", to: "destination"); XCTFail("Expected hidden descendant rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
    }
    func testMalformedMutationPathsRejectBeforeNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        http.handler = { _ in XCTFail("Invalid paths must not reach rclone"); throw URLError(.badURL) }
        let backend = try backend()
        do { try await backend.createDirectory(at: "a//b"); XCTFail("Expected rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        do { try await backend.deleteFile(at: "a/./b"); XCTFail("Expected rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        do { try await backend.upload(stagedFile: directory, to: "a//b"); XCTFail("Expected rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        do { try await backend.move(from: "a//b", to: "good"); XCTFail("Expected rejection") } catch { XCTAssertTrue(error is GoogleCloudStorageError) }
    }
    func testRecursiveDeletionUsesOnlyEnumeratedFilesAndEmptyFolders() async throws {
        let rc = MoveRC(); rc.directory("source"); rc.file("source/good", size: 0)
        http.handler = rc.handle
        try await backend().deleteDirectory(at: "source", recursive: true)
        XCTAssertEqual(rc.deletes, ["source/good"]); XCTAssertNil(rc.items["source"])
    }

}
