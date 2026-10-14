import XCTest
import FileProvider
@testable import FreeMount

private actor InventoryBackend: FileProviderPathPrimitives {
    var items: [FileProviderRemoteItem]
    var failedList: String?
    var failedStat: String?
    var cancelRead = false
    init(items: [FileProviderRemoteItem]) { self.items = items }
    func fail(list: String? = nil, stat: String? = nil) { failedList = list; failedStat = stat }
    func setCancellation() { cancelRead = true }
    func listChildren(at path: String) async throws -> [FileProviderRemoteItem] {
        if cancelRead { throw CancellationError() }
        if path == failedList { throw FreeMountError.networkTimeout(operation: "fixture listing") }
        return items.filter { $0.parentPath == path }
    }
    func stat(at path: String) async throws -> FileProviderRemoteItem? {
        if path == failedStat { throw FreeMountError.networkTimeout(operation: "fixture stat") }
        return items.first { $0.path == path }
    }
    func download(path: String, to stagingDirectory: URL) async throws -> URL { stagingDirectory }
    func upload(stagedFile: URL, to path: String) async throws { throw CocoaError(.featureUnsupported) }
    func createDirectory(at path: String) async throws { throw CocoaError(.featureUnsupported) }
    func deleteFile(at path: String) async throws { throw CocoaError(.featureUnsupported) }
    func deleteDirectory(at path: String, recursive: Bool) async throws { throw CocoaError(.featureUnsupported) }
    func move(from sourcePath: String, to destinationPath: String) async throws { throw CocoaError(.featureUnsupported) }
}

final class FileProviderWorkingSetTests: XCTestCase {
    private func item(_ path: String, folder: Bool = false) -> FileProviderRemoteItem {
        .init(id: path, parentPath: FileProviderPath.parent(of: path), path: path, filename: String(path.split(separator: "/").last!), contentSize: 1, isDirectory: folder)
    }

    func testRootNestedAndPinnedStatFailuresPreservePreviousAnchorAndInventory() async throws {
        for failure in ["root", "nested", "stat"] {
            let old = item("folder/a.txt")
            let snapshots = FileProviderEnumerationSnapshotStore(key: UUID().uuidString, defaults: EphemeralUserDefaults())
            snapshots.bootstrap([FreeMountFileProviderItem(item: old)])
            let anchor = snapshots.currentAnchor
            let backend = InventoryBackend(items: [item("folder", folder: true), old])
            if failure == "root" { await backend.fail(list: "") }
            if failure == "nested" { await backend.fail(list: "folder") }
            if failure == "stat" { await backend.fail(stat: "absent/deep.txt") }
            do {
                let values = try await FileProviderWorkingSetCollector(backend: backend).collect(pinnedPaths: failure == "stat" ? ["absent/deep.txt"] : ["folder"], provider: .googleDrive)
                _ = snapshots.changes(from: anchor, to: values.map { FreeMountFileProviderItem(item: $0) })
                XCTFail("Failed reads cannot publish inventory")
            } catch { XCTAssertTrue(error is FreeMountError) }
            XCTAssertEqual(snapshots.currentAnchor, anchor)
            let unchanged = snapshots.changes(from: anchor, to: [FreeMountFileProviderItem(item: old)])
            XCTAssertTrue(unchanged.deleted.isEmpty)
            XCTAssertTrue(unchanged.updated.isEmpty)
        }
    }

    func testSuccessfulAbsencePublishesDeletionAndRecoveryPublishesUpdates() async throws {
        let old = item("gone.txt")
        let snapshots = FileProviderEnumerationSnapshotStore(key: UUID().uuidString, defaults: EphemeralUserDefaults())
        snapshots.bootstrap([FreeMountFileProviderItem(item: old)])
        let backend = InventoryBackend(items: [item("new.txt")])
        let values = try await FileProviderWorkingSetCollector(backend: backend).collect(pinnedPaths: ["gone.txt"], provider: .googleDrive)
        let changes = snapshots.changes(from: snapshots.currentAnchor, to: values.map { FreeMountFileProviderItem(item: $0) })
        XCTAssertEqual(changes.deleted.map(\.rawValue), ["p:gone.txt"])
        XCTAssertEqual(changes.updated.map(\.filename), ["new.txt"])
    }

    func testPinnedHierarchyBeyondOldDepthLimitIsCompleteAndDeduplicated() async throws {
        var items = [item("folder", folder: true)]
        var path = "folder"
        for _ in 0..<12 { path += "/child"; items.append(item(path, folder: true)) }
        items.append(item(path + "/file.txt"))
        let values = try await FileProviderWorkingSetCollector(backend: InventoryBackend(items: items)).collect(pinnedPaths: ["folder", "folder/child"], provider: .googleCloudStorage)
        XCTAssertEqual(Set(values.map(\.path)), Set(items.map(\.path)))
        XCTAssertEqual(values.count, items.count)
    }

    func testInventoryBudgetThrowsInsteadOfPublishingTruncatedTree() async throws {
        let backend = InventoryBackend(items: [item("folder", folder: true), item("folder/a"), item("folder/b")])
        do {
            _ = try await FileProviderWorkingSetCollector(backend: backend, itemLimit: 2).collect(pinnedPaths: ["folder"], provider: .googleDrive)
            XCTFail("A partial inventory cannot be returned")
        } catch { XCTAssertTrue(error is FileProviderInventoryError) }
    }

    func testSharedTreeReaderCompletesDeepOfflineInventoryAndRejectsDirectoryBudget() async throws {
        var items = [item("folder", folder: true)]
        var path = "folder"
        for _ in 0..<12 { path += "/child"; items.append(item(path, folder: true)) }
        items.append(item(path + "/file.txt"))
        let backend = InventoryBackend(items: items)
        let inventory = try await FileProviderTreeReader.read(at: ["folder"]) { try await backend.listChildren(at: $0) }
        XCTAssertEqual(inventory.filter { !$0.isDirectory }.map(\.path), [path + "/file.txt"])
        do {
            _ = try await FileProviderTreeReader.read(at: ["folder"], directoryLimit: 10) { try await backend.listChildren(at: $0) }
            XCTFail("Cannot silently stop at a directory budget")
        } catch { XCTAssertTrue(error is FileProviderInventoryError) }
        await backend.fail(list: path)
        do {
            _ = try await FileProviderTreeReader.read(at: ["folder"]) { try await backend.listChildren(at: $0) }
            XCTFail("Nested failure cannot return a partial offline inventory")
        } catch { XCTAssertTrue(error is FreeMountError) }
    }

    func testCancellationCannotReturnPartialInventory() async throws {
        let backend = InventoryBackend(items: [item("folder", folder: true)])
        await backend.setCancellation()
        do { _ = try await FileProviderWorkingSetCollector(backend: backend).collect(pinnedPaths: ["folder"], provider: .googleDrive); XCTFail("Cancelled inventory") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
