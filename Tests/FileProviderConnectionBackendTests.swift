import XCTest
import FileProvider
@testable import FreeMount

private struct ReferenceBackend: FileProviderPathPrimitives {
    let reference: String
    func listChildren(at path: String) async throws -> [FileProviderRemoteItem] {
        [FileProviderRemoteItem(id: reference, parentPath: "", path: "file", filename: "file", contentSize: 1, isDirectory: false, remoteObjectID: reference)]
    }
    func stat(at path: String) async throws -> FileProviderRemoteItem? { try await listChildren(at: path).first }
    func download(path: String, to stagingDirectory: URL) async throws -> URL { stagingDirectory }
    func upload(stagedFile: URL, to path: String) async throws {}
    func createDirectory(at path: String) async throws {}
    func deleteFile(at path: String) async throws {}
    func deleteDirectory(at path: String, recursive: Bool) async throws {}
    func move(from sourcePath: String, to destinationPath: String) async throws {}
}

final class FileProviderConnectionBackendTests: XCTestCase {
    func testExistingProxyRefreshesPolicyAndCredentialReference() async throws {
        let store = FileProviderDomainStore(defaults: EphemeralUserDefaults())
        var remote = RemoteConfig(name: "Drive", provider: .googleDrive, bucketOrRootPath: "", keychainAccountKey: "old")
        let initial = try FileProviderConnectionDescriptor(remote: remote)
        try store.upsert(initial)
        let proxy = FileProviderConnectionBackend(domainIdentifier: initial.id, store: store) {
            ReferenceBackend(reference: $0.keychainAccountKey)
        }
        let first = try await proxy.listChildren(at: "")
        XCTAssertEqual(first.first?.remoteObjectID, "old")
        remote.isReadOnly = true
        remote.keychainAccountKey = "new"
        try store.upsert(try FileProviderConnectionDescriptor(remote: remote))
        let second = try await proxy.listChildren(at: "")
        XCTAssertEqual(second.first?.remoteObjectID, "new")
        XCTAssertEqual(second.first?.isReadOnly, true)
        do {
            try await proxy.deleteItem(at: "file", condition: .contentVersion(try XCTUnwrap(second.first).contentVersion), recursive: false)
            XCTFail("Read-only must reject mutation before calling the backend")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        remote.isReadOnly = false
        try store.upsert(try FileProviderConnectionDescriptor(remote: remote))
        let third = try await proxy.listChildren(at: "")
        XCTAssertEqual(third.first?.isReadOnly, false)
        try await proxy.deleteItem(at: "file", condition: .contentVersion(try XCTUnwrap(third.first).contentVersion), recursive: false)
    }

    func testPolicyChangeAppearsInEnumerationChangesWithoutChangingContentVersion() {
        let remoteItem = FileProviderRemoteItem(id: "file", parentPath: "", path: "file", filename: "file", contentSize: 1, isDirectory: false)
        let writable = FreeMountFileProviderItem(item: remoteItem)
        let readOnly = FreeMountFileProviderItem(item: remoteItem, isReadOnly: true)
        XCTAssertEqual(writable.itemVersion.contentVersion, readOnly.itemVersion.contentVersion)
        XCTAssertNotEqual(writable.itemVersion.metadataVersion, readOnly.itemVersion.metadataVersion)
        let snapshots = FileProviderEnumerationSnapshotStore(key: "policy", defaults: EphemeralUserDefaults())
        snapshots.bootstrap([writable])
        XCTAssertEqual(snapshots.changes(from: snapshots.currentAnchor, to: [readOnly]).updated.count, 1)
        XCTAssertFalse(readOnly.capabilities.contains(.allowsWriting))
        XCTAssertNotEqual(FreeMountFileProviderItem.root(displayName: "Drive").itemVersion.metadataVersion,
                          FreeMountFileProviderItem.root(displayName: "Drive", isReadOnly: true).itemVersion.metadataVersion)
    }
}
