import XCTest
@testable import FreeMount

final class GenericRcloneFileProviderBackendTests: XCTestCase {
    private let http = MockHTTPRouter()

    private func makeBackend(
        _ rc: MoveRC,
        directory: URL,
        isReadOnly: Bool = false
    ) throws -> GenericRcloneFileProviderBackend {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        http.handler = rc.handle
        let config = URLSessionConfiguration.ephemeral
        http.configure(config)

        let client = RcloneClient(
            port: 5572,
            urlSession: URLSession(configuration: config),
            credentialProvider: testRPCCredentialProvider
        )

        return GenericRcloneFileProviderBackend(
            fsProvider: {
                .configuration(["type": "drive", "remote": "test-remote"])
            },
            isReadOnly: isReadOnly,
            client: client,
            stagingContainer: directory
        )
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testUploadDownloadAndStat() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC()
        let backend = try makeBackend(rc, directory: directory)

        let testFile = directory.appendingPathComponent("sample.txt")
        try Data("hello world".utf8).write(to: testFile)

        let uploaded = try await backend.upload(stagedFile: testFile, to: "docs/sample.txt", condition: .absent)
        XCTAssertEqual(uploaded.path, "docs/sample.txt")
        XCTAssertEqual(uploaded.contentSize, 11)

        let statItem = try await backend.stat(at: "docs/sample.txt")
        XCTAssertNotNil(statItem)
        XCTAssertEqual(statItem?.path, "docs/sample.txt")

        let downloaded = try await backend.downloadItem(path: "docs/sample.txt", to: directory, requestedVersion: nil)
        let downloadedData = try Data(contentsOf: downloaded.url)
        XCTAssertEqual(downloadedData.count, 11)
    }

    func testDirectoryCreationAndDeletion() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC()
        let backend = try makeBackend(rc, directory: directory)

        let folder = try await backend.createDirectoryItem(at: "archive")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertEqual(folder.path, "archive")

        try await backend.deleteItem(at: "archive", condition: .contentVersion(folder.contentVersion), recursive: false)
        XCTAssertNil(rc.items["archive"])
    }

    func testReadOnlyBackendRejectsMutations() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC()
        let backend = try makeBackend(rc, directory: directory, isReadOnly: true)

        let testFile = directory.appendingPathComponent("sample.txt")
        try Data("test".utf8).write(to: testFile)

        do {
            _ = try await backend.upload(stagedFile: testFile, to: "sample.txt", condition: .absent)
            XCTFail("Expected read only rejection")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
    }
}
