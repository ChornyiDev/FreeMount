import XCTest
@testable import FreeMount

final class GoogleCloudStandardRCTests: XCTestCase {
    private let http = MockHTTPRouter()
    private func backend(_ rc: MoveRC, directory: URL, id: UUID = UUID()) throws -> GoogleCloudStorageFileProviderBackend {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        http.handler = rc.handle
        let config = URLSessionConfiguration.ephemeral; http.configure(config)
        let remote = RemoteConfig(id: id, name: "Standard", provider: .googleCloudStorage,
            bucketOrRootPath: "test-bucket", keychainAccountKey: "fixture",
            googleCloudStorage: try GoogleCloudStorageSelection(projectID: "test-project", projectNumber: "123", bucket: "test-bucket"))
        return try .init(connection: FileProviderConnectionDescriptor(remote: remote),
            client: RcloneClient(port: 5572, urlSession: URLSession(configuration: config), credentialProvider: testRPCCredentialProvider),
            credential: .init(remoteName: "Standard", provider: .googleCloudStorage, backendOptions: ["type": "google cloud storage"]),
            stagingContainer: directory)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testOrdinaryCreateUploadDownloadAndDeleteUseStandardJobs() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); let backend = try backend(rc, directory: directory)
        let folder = try await backend.createDirectoryItem(at: "folder")
        XCTAssertTrue(folder.isDirectory)
        let input = directory.appendingPathComponent("input.txt"); try Data("content".utf8).write(to: input)
        let item = try await backend.upload(stagedFile: input, to: "folder/file.txt", condition: .absent)
        XCTAssertEqual(item.contentSize, 7)
        let downloaded = try await backend.downloadItem(path: item.path, to: directory, requestedVersion: item.contentVersion)
        XCTAssertEqual(try Data(contentsOf: downloaded.url).count, 7)
        try await backend.deleteItem(at: item.path, condition: .contentVersion(item.contentVersion), recursive: false)
        XCTAssertNil(rc.items[item.path])
        try await backend.deleteItem(at: "folder", condition: .contentVersion(folder.contentVersion), recursive: false)
        XCTAssertNil(rc.items["folder"])
    }
    func testObservedStaleMetadataRejectsBeforeMutation() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.file("source", size: 2)
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "source")
        let before = try XCTUnwrap(observed)
        rc.file("source", size: 3)
        do { _ = try await backend.move(from: "source", to: "target", condition: .contentVersion(before.contentVersion)); XCTFail("Expected stale preflight") }
        catch { XCTAssertEqual(error as? FileProviderMutationError, .versionConflict) }
        XCTAssertTrue(rc.deletes.isEmpty)
        XCTAssertNil(rc.items["target"])
    }
    func testFileRenameIncludingCaseUsesOrdinaryMovefile() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.file("report.txt", size: 3)
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "report.txt")
        let before = try XCTUnwrap(observed)
        let renamed = try await backend.move(from: "report.txt", to: "Report.txt", condition: .contentVersion(before.contentVersion))
        XCTAssertEqual(renamed.path, "Report.txt"); XCTAssertNil(rc.items["report.txt"])
    }
    func testDirectoryMoveCopiesWholeInventoryIncludingEmptyFolders() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.seed()
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "source")
        let before = try XCTUnwrap(observed)
        _ = try await backend.move(from: "source", to: "target", condition: .contentVersion(before.contentVersion))
        XCTAssertNotNil(rc.items["target/empty"]); XCTAssertNotNil(rc.items["target/a.txt"])
        XCTAssertNil(rc.items["source"]); XCTAssertEqual(rc.deletes.sorted(), ["source/a.txt", "source/b.txt"])
    }
    func testEmptyRootDirectoryMoveKeepsDestinationMarker() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.directory("source")
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "source")
        let before = try XCTUnwrap(observed)
        let moved = try await backend.move(from: "source", to: "target", condition: .contentVersion(before.contentVersion))
        XCTAssertTrue(moved.isDirectory); XCTAssertNotNil(rc.items["target"]); XCTAssertNil(rc.items["source"])
    }
    func testFailedCopyPreservesSourceAndPartialDestination() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.seed(); rc.failOnce = "/operations/copyfile:source/b.txt"
        let backend = try backend(rc, directory: directory)
        do { try await backend.move(from: "source", to: "target"); XCTFail("Expected failure") } catch {}
        XCTAssertTrue(rc.deletes.isEmpty); XCTAssertNotNil(rc.items["source/a.txt"])
        XCTAssertNotNil(rc.items["target/a.txt"])
        do { try await backend.move(from: "source", to: "target"); XCTFail("Partial target must not be adopted") } catch {}
        XCTAssertTrue(rc.deletes.isEmpty)
    }
    func testCombinedContentRenameRetainsSourceOnDeleteFailure() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.file("source", size: 3); rc.failOnce = "/operations/deletefile:source"
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "source")
        let before = try XCTUnwrap(observed)
        let input = directory.appendingPathComponent("input"); try Data("new".utf8).write(to: input)
        do { _ = try await backend.replaceAndMove(stagedFile: input, from: "source", to: "target", condition: .contentVersion(before.contentVersion)); XCTFail("Expected delete failure") } catch {}
        XCTAssertNotNil(rc.items["source"]); XCTAssertNotNil(rc.items["target"])
    }
    func testEquivalentFolderRenameFailsBeforeMutation() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.directory("source")
        let backend = try backend(rc, directory: directory)
        let observed = try await backend.stat(at: "source")
        let before = try XCTUnwrap(observed)
        do { _ = try await backend.move(from: "source", to: "Source", condition: .contentVersion(before.contentVersion)); XCTFail("Unsupported folder rename") }
        catch { XCTAssertTrue(error is GoogleCloudStorageError) }
        XCTAssertTrue(rc.jobs.isEmpty); XCTAssertNotNil(rc.items["source"])
    }
    func testUnknownUploadRetainsSharedStaging() async throws {
        let directory = temporary(); defer { try? FileManager.default.removeItem(at: directory) }
        let rc = MoveRC(); rc.unknownOnce = "/operations/copyfile:input"
        let backend = try backend(rc, directory: directory)
        let input = directory.appendingPathComponent("input"); try Data("new".utf8).write(to: input)
        do { _ = try await backend.upload(stagedFile: input, to: "target", condition: .absent); XCTFail("Expected unknown outcome") }
        catch { XCTAssertTrue(error is RcloneJobError) }
        let staging = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Uploads"), includingPropertiesForKeys: nil)
        XCTAssertEqual(staging.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging[0].appendingPathComponent("input").path))
    }
}
