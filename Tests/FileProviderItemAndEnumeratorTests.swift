import XCTest
import FileProvider
import UniformTypeIdentifiers
@testable import FreeMount

final class FileProviderItemAndEnumeratorTests: XCTestCase {
    private let http = MockHTTPRouter()
    func testInvalidGrantMapsToNotAuthenticated() {
        let error = FreeMountError.rcloneError(
            statusCode: 500,
            message: "couldn't fetch token: invalid_grant: token expired"
        )

        let mapped = FreeMountFileProviderErrorMapping.map(error)

        XCTAssertEqual((mapped as? NSFileProviderError)?.code, .notAuthenticated)
    }

    func testGoogleDriveHealthClassifierSeparatesAuthorizationAndAvailability() {
        let authorization = GoogleDriveConnectionHealthChecker.classify(
            FreeMountError.rcloneError(statusCode: 500, message: "invalid_grant")
        )
        let unavailable = GoogleDriveConnectionHealthChecker.classify(
            FreeMountError.networkTimeout(operation: "operations/list")
        )

        guard case .authorizationRequired = authorization else {
            return XCTFail("Expected an authorization failure")
        }
        guard case .unavailable = unavailable else {
            return XCTFail("Expected an availability failure")
        }
    }


    func testRemoteChangeSnapshotFindsAddedModifiedAndDeletedItems() {
        let defaults = EphemeralUserDefaults()
        let store = FileProviderEnumerationSnapshotStore(key: "test.root", defaults: defaults)
        func item(_ name: String, size: Int64) -> FreeMountFileProviderItem {
            FreeMountFileProviderItem(item: FileProviderRemoteItem(
                id: name, parentPath: "", path: name, filename: name,
                contentSize: size, modifiedAt: Date(timeIntervalSince1970: 1000),
                isDirectory: false, remoteObjectID: name
            ))
        }

        store.bootstrap([item("old.txt", size: 1), item("edited.txt", size: 1)])
        let oldAnchor = store.currentAnchor
        let changes = store.changes(from: oldAnchor, to: [item("edited.txt", size: 2), item("new.txt", size: 1)])
        XCTAssertEqual(Set(changes.updated.map(\.filename)), ["edited.txt", "new.txt"])
        XCTAssertEqual(changes.deleted.map(\.rawValue), ["p:old.txt"])
        XCTAssertNotEqual(changes.anchor.rawValue, oldAnchor.rawValue)
        XCTAssertTrue(store.changes(from: changes.anchor, to: [item("edited.txt", size: 2), item("new.txt", size: 1)]).updated.isEmpty)
    }

    func testRemoteChangeSnapshotDoesNotCrashOnDuplicateIdentifiers() {
        let defaults = EphemeralUserDefaults()
        let store = FileProviderEnumerationSnapshotStore(key: "test.duplicates", defaults: defaults)
        func item(id: String, size: Int64) -> FreeMountFileProviderItem {
            FreeMountFileProviderItem(item: FileProviderRemoteItem(
                id: id, parentPath: "", path: "duplicate.txt", filename: "duplicate.txt",
                contentSize: size, modifiedAt: Date(timeIntervalSince1970: 1000),
                isDirectory: false, remoteObjectID: id
            ))
        }

        store.bootstrap([item(id: "drive-b", size: 2), item(id: "drive-a", size: 1)])

        XCTAssertFalse(store.currentAnchor.rawValue.isEmpty)
    }

    func testGoogleDrivePathDeduplicationIsDeterministic() {
        func item(id: String, path: String) -> FileProviderRemoteItem {
            FileProviderRemoteItem(
                id: id, parentPath: "", path: path, filename: path,
                contentSize: 1, isDirectory: false, remoteObjectID: id
            )
        }
        let duplicateB = item(id: "drive-b", path: "duplicate.txt")
        let unique = item(id: "drive-c", path: "unique.txt")
        let duplicateA = item(id: "drive-a", path: "duplicate.txt")

        let first = GoogleDriveFileProviderBackend.deduplicatedByPath([duplicateB, unique, duplicateA])
        let second = GoogleDriveFileProviderBackend.deduplicatedByPath([duplicateA, duplicateB, unique])

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first.first(where: { $0.path == "duplicate.txt" })?.remoteObjectID, "drive-a")
    }

    func testSharedWithMeVirtualRootIsReadOnly() {
        let remoteItem = GoogleDriveFileProviderBackend.sharedWithMeRootItem
        let item = FreeMountFileProviderItem(item: remoteItem)

        XCTAssertEqual(remoteItem.filename, "Shared with me")
        XCTAssertEqual(remoteItem.path, GoogleDriveFileProviderBackend.sharedWithMePath)
        XCTAssertTrue(remoteItem.isReadOnly)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsAddingSubItems))
        XCTAssertFalse(item.capabilities.contains(.allowsRenaming))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
    }

    func testSharedWithMePathRoutingPreservesHierarchy() throws {
        let root = GoogleDriveFileProviderBackend.sharedWithMePath
        let nested = root + "/Team/Report.pdf"

        XCTAssertTrue(GoogleDriveFileProviderBackend.isSharedWithMePath(root))
        XCTAssertTrue(GoogleDriveFileProviderBackend.isSharedWithMePath(nested))
        XCTAssertFalse(GoogleDriveFileProviderBackend.isSharedWithMePath("Documents/Report.pdf"))
        XCTAssertEqual(GoogleDriveFileProviderBackend.sharedRelativePath(root), "")
        XCTAssertEqual(GoogleDriveFileProviderBackend.sharedRelativePath(nested), "Team/Report.pdf")
        XCTAssertEqual(
            GoogleDriveFileProviderBackend.sharedPath(for: "Team/Report.pdf"),
            nested
        )
        XCTAssertThrowsError(try GoogleDriveFileProviderBackend.requireWritable(nested))
        XCTAssertNoThrow(try GoogleDriveFileProviderBackend.requireWritable("Documents/Report.pdf"))
    }

    // MARK: - Identifier Mapping Tests

    func testRootIdentifierMapping() {
        let root = NSFileProviderItemIdentifier.rootContainer
        XCTAssertEqual(root.remoteRelativePath, "")
        XCTAssertTrue(root.isDomainRoot)

        let mappedRoot = NSFileProviderItemIdentifier.remoteItem(path: "")
        XCTAssertEqual(mappedRoot, .rootContainer)
        XCTAssertEqual(mappedRoot.remoteRelativePath, "")
    }

    func testRemoteItemIdentifierMapping() {
        let singleFile = NSFileProviderItemIdentifier.remoteItem(path: "photo.jpg")
        XCTAssertEqual(singleFile.remoteRelativePath, "photo.jpg")
        XCTAssertFalse(singleFile.isDomainRoot)

        let nestedFile = NSFileProviderItemIdentifier.remoteItem(path: "Documents/Work/notes.txt")
        XCTAssertEqual(nestedFile.remoteRelativePath, "Documents/Work/notes.txt")

        let leadingTrailingSlash = NSFileProviderItemIdentifier.remoteItem(path: "/Documents/Reports/")
        XCTAssertEqual(leadingTrailingSlash.remoteRelativePath, "Documents/Reports")
    }

    // MARK: - Root Item Tests

    func testRootItemProperties() {
        let root = FreeMountFileProviderItem.root(displayName: "Google Drive (Work)", isReadOnly: false)

        XCTAssertEqual(root.itemIdentifier, .rootContainer)
        XCTAssertEqual(root.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(root.filename, "Google Drive (Work)")
        XCTAssertEqual(root.contentType, .folder)
        XCTAssertTrue(root.isDirectory)
        XCTAssertEqual(root.remotePath, "")
        XCTAssertNil(root.documentSize)
        XCTAssertTrue(root.capabilities.contains(.allowsReading))
        XCTAssertTrue(root.capabilities.contains(.allowsWriting))
        XCTAssertTrue(root.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(root.capabilities.contains(.allowsAddingSubItems))
    }

    func testReadOnlyRootItemCapabilities() {
        let root = FreeMountFileProviderItem.root(displayName: "Google Drive (Archive)", isReadOnly: true)

        XCTAssertTrue(root.capabilities.contains(.allowsReading))
        XCTAssertTrue(root.capabilities.contains(.allowsContentEnumerating))
        XCTAssertFalse(root.capabilities.contains(.allowsWriting))
        XCTAssertFalse(root.capabilities.contains(.allowsAddingSubItems))
    }

    // MARK: - Remote Item Mapping Tests

    func testFileItemMappingWithMimeType() {
        let modified = Date(timeIntervalSince1970: 1710000000)
        let remoteItem = FileProviderRemoteItem(
            id: "drive-id-123",
            parentPath: "",
            path: "sample.pdf",
            filename: "sample.pdf",
            contentSize: 1048576,
            contentType: "application/pdf",
            modifiedAt: modified,
            isDirectory: false,
            remoteObjectID: "drive-id-123"
        )

        let item = FreeMountFileProviderItem(item: remoteItem, isReadOnly: false)

        XCTAssertEqual(item.itemIdentifier, NSFileProviderItemIdentifier.remoteItem(path: "sample.pdf"))
        XCTAssertEqual(item.parentItemIdentifier, .rootContainer)
        XCTAssertEqual(item.filename, "sample.pdf")
        XCTAssertEqual(item.contentType, .pdf)
        XCTAssertFalse(item.isDirectory)
        XCTAssertEqual(item.documentSize, NSNumber(value: 1048576))
        XCTAssertEqual(item.contentModificationDate, modified)
        XCTAssertEqual(item.remoteObjectID, "drive-id-123")
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
        XCTAssertTrue(item.capabilities.contains(.allowsRenaming))
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
    }

    func testNestedDirectoryMapping() {
        let remoteItem = FileProviderRemoteItem(
            id: "folder-id-456",
            parentPath: "Documents",
            path: "Documents/Work",
            filename: "Work",
            contentSize: 0,
            contentType: nil,
            modifiedAt: nil,
            isDirectory: true,
            remoteObjectID: "folder-id-456"
        )

        let item = FreeMountFileProviderItem(item: remoteItem, isReadOnly: false)

        XCTAssertEqual(item.itemIdentifier, NSFileProviderItemIdentifier.remoteItem(path: "Documents/Work"))
        XCTAssertEqual(item.parentItemIdentifier, NSFileProviderItemIdentifier.remoteItem(path: "Documents"))
        XCTAssertEqual(item.filename, "Work")
        XCTAssertEqual(item.contentType, .folder)
        XCTAssertTrue(item.isDirectory)
        XCTAssertNil(item.documentSize)
        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
        XCTAssertTrue(item.capabilities.contains(.allowsContentEnumerating))
        XCTAssertTrue(item.capabilities.contains(.allowsAddingSubItems))
        XCTAssertTrue(item.capabilities.contains(.allowsDeleting))
    }

    func testReadOnlyFileCapabilities() {
        let remoteItem = FileProviderRemoteItem(
            id: "drive-id-789",
            parentPath: "",
            path: "read-only.txt",
            filename: "read-only.txt",
            contentSize: 512,
            contentType: "text/plain",
            modifiedAt: nil,
            isDirectory: false,
            remoteObjectID: "drive-id-789"
        )

        let item = FreeMountFileProviderItem(item: remoteItem, isReadOnly: true)

        XCTAssertTrue(item.capabilities.contains(.allowsReading))
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(item.capabilities.contains(.allowsRenaming))
    }

    func testVersionTagIsDeterministic() {
        let modified = Date(timeIntervalSince1970: 1710000000)
        let v1 = FreeMountFileProviderItem.makeVersion(
            path: "notes.md",
            size: 2048,
            modifiedAt: modified,
            remoteObjectID: "object-abc"
        )
        let v2 = FreeMountFileProviderItem.makeVersion(
            path: "notes.md",
            size: 2048,
            modifiedAt: modified,
            remoteObjectID: "object-abc"
        )
        let v3 = FreeMountFileProviderItem.makeVersion(
            path: "notes.md",
            size: 2049,
            modifiedAt: modified,
            remoteObjectID: "object-abc"
        )

        XCTAssertEqual(v1.contentVersion, v2.contentVersion)
        XCTAssertNotEqual(v1.contentVersion, v3.contentVersion)
    }

    // MARK: - RcloneClient Stat Endpoint Test

    func testRcloneClientStatDecodesItem() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let urlSession = URLSession(configuration: configuration)
        let client = RcloneClient(baseURL: URL(string: "http://127.0.0.1:5572")!, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)

        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/operations/stat")
            let responseJSON = """
            {
                "item": {
                    "Path": "Docs/report.pdf",
                    "Name": "report.pdf",
                    "Size": 12345,
                    "MimeType": "application/pdf",
                    "ModTime": "2026-09-18T12:00:00Z",
                    "IsDir": false,
                    "ID": "google-drive-item-999"
                }
            }
            """
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(responseJSON.utf8))
        }

        let statItem = try await client.stat(fs: .named("remote:"), path: "Docs/report.pdf")
        let unwrapped = try XCTUnwrap(statItem)
        XCTAssertEqual(unwrapped.path, "Docs/report.pdf")
        XCTAssertEqual(unwrapped.name, "report.pdf")
        XCTAssertEqual(unwrapped.size, 12345)
        XCTAssertEqual(unwrapped.mimeType, "application/pdf")
        XCTAssertFalse(unwrapped.isDir)
        XCTAssertEqual(unwrapped.id, "google-drive-item-999")
    }

    // MARK: - RcloneClient CopyFile Endpoint Test (Stage 2)

    func testRcloneClientCopyFileSendsExpectedPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let urlSession = URLSession(configuration: configuration)
        let client = RcloneClient(baseURL: URL(string: "http://127.0.0.1:5572")!, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)

        var requestedEndpoint: String?
        var requestedMethod: String?

        http.handler = { request in
            if request.url?.path == "/job/status" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":1,\"executeId\":\"test\",\"finished\":true,\"success\":true,\"error\":\"\"}".utf8))
            }
            requestedEndpoint = request.url?.path
            requestedMethod = request.httpMethod
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"jobid\":1,\"executeId\":\"test\"}".utf8))
        }

        let copyRequest = RcloneCopyFileRequest(
            sourceFS: .named("remote:"),
            sourcePath: "Reports/2026.xlsx",
            destinationFS: .named("/tmp/staging"),
            destinationPath: "2026.xlsx"
        )
        let encoded = try JSONEncoder().encode(copyRequest)
        let decoded = try JSONDecoder().decode(RcloneCopyFileRequest.self, from: encoded)
        XCTAssertEqual(decoded.sourceFS, .named("remote:"))
        XCTAssertEqual(decoded.sourcePath, "Reports/2026.xlsx")
        XCTAssertEqual(decoded.destinationFS, .named("/tmp/staging"))
        XCTAssertEqual(decoded.destinationPath, "2026.xlsx")

        try await client.copyFile(
            sourceFS: .named("remote:"),
            sourcePath: "Reports/2026.xlsx",
            destinationFS: .named("/tmp/staging"),
            destinationPath: "2026.xlsx"
        )

        XCTAssertEqual(requestedEndpoint, "/operations/copyfile")
        XCTAssertEqual(requestedMethod, "POST")
    }

    // MARK: - Backend Connection Init & Download Validation (Stage 2)

    func testBackendConnectionInitializer() throws {
        let remote = RemoteConfig(
            name: "Test Drive",
            provider: .googleDrive,
            bucketOrRootPath: "Folder",
            keychainAccountKey: "keychain-test-key",
            isReadOnly: true
        )
        let connection = try FileProviderConnectionDescriptor(remote: remote)

        let backend = try GoogleDriveFileProviderBackend(connection: connection)
        XCTAssertNotNil(backend)
    }

    func testDownloadRejectsPathTraversal() async throws {
        let remote = RemoteConfig(
            name: "Test Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain-test-key"
        )
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        let backend = try GoogleDriveFileProviderBackend(connection: connection)
        let tempDir = FileManager.default.temporaryDirectory

        do {
            _ = try await backend.download(path: "../secrets.txt", to: tempDir)
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../secrets.txt"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Error Mapping Validation

    func testCancellationAndErrorMapping() {
        let cancelError = CancellationError()
        let mappedCancellation = FreeMountFileProviderErrorMapping.map(cancelError)
        XCTAssertEqual((mappedCancellation as? CocoaError)?.code, .userCancelled)

        let userCancelled = CocoaError(.userCancelled)
        let mappedUserCancelled = FreeMountFileProviderErrorMapping.map(userCancelled)
        XCTAssertEqual((mappedUserCancelled as? CocoaError)?.code, .userCancelled)

        let notFoundError = FreeMountError.rcloneError(statusCode: 404, message: "object not found")
        let mappedNotFound = FreeMountFileProviderErrorMapping.map(notFoundError)
        XCTAssertEqual((mappedNotFound as? NSFileProviderError)?.code, .noSuchItem)

        let serverError = FreeMountError.rcloneError(statusCode: 500, message: "internal server error")
        let mappedServer = FreeMountFileProviderErrorMapping.map(serverError)
        XCTAssertEqual((mappedServer as? NSFileProviderError)?.code, .serverUnreachable)

        let authError = FreeMountError.keychainError(status: -25300, message: "Item not found")
        let mappedAuth = FreeMountFileProviderErrorMapping.map(authError)
        XCTAssertEqual((mappedAuth as? NSFileProviderError)?.code, .notAuthenticated)

        let traversal = FileProviderPathError.traversalAttempt("../bad")
        let mappedTraversal = FreeMountFileProviderErrorMapping.map(traversal)
        XCTAssertEqual((mappedTraversal as? NSFileProviderError)?.code, .noSuchItem)

        let permissionError = CocoaError(.fileWriteNoPermission)
        let mappedPermission = FreeMountFileProviderErrorMapping.map(permissionError)
        XCTAssertEqual((mappedPermission as? CocoaError)?.code, .fileWriteNoPermission)

        let forbiddenRcloneError = FreeMountError.rcloneError(statusCode: 403, message: "insufficient permissions for file")
        let mappedForbidden = FreeMountFileProviderErrorMapping.map(forbiddenRcloneError)
        XCTAssertEqual((mappedForbidden as? CocoaError)?.code, .fileWriteNoPermission)
    }

    // MARK: - Stage 3 Mutations Validation

    func testRcloneClientMoveFileSendsExpectedPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let urlSession = URLSession(configuration: configuration)
        let client = RcloneClient(baseURL: URL(string: "http://127.0.0.1:5572")!, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)

        var requestedEndpoint: String?
        var requestedMethod: String?

        http.handler = { request in
            if request.url?.path == "/job/status" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":1,\"executeId\":\"test\",\"finished\":true,\"success\":true,\"error\":\"\"}".utf8))
            }
            requestedEndpoint = request.url?.path
            requestedMethod = request.httpMethod
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"jobid\":1,\"executeId\":\"test\"}".utf8))
        }

        try await client.moveFile(
            sourceFS: .named("remote:"),
            sourcePath: "old.txt",
            destinationFS: .named("remote:"),
            destinationPath: "new.txt"
        )

        XCTAssertEqual(requestedEndpoint, "/operations/movefile")
        XCTAssertEqual(requestedMethod, "POST")
    }

    func testRcloneClientPurgeDirectorySendsExpectedPayload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let urlSession = URLSession(configuration: configuration)
        let client = RcloneClient(baseURL: URL(string: "http://127.0.0.1:5572")!, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)

        var requestedEndpoint: String?
        var requestedMethod: String?

        http.handler = { request in
            if request.url?.path == "/job/status" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("{\"id\":1,\"executeId\":\"test\",\"finished\":true,\"success\":true,\"error\":\"\"}".utf8))
            }
            requestedEndpoint = request.url?.path
            requestedMethod = request.httpMethod
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"jobid\":1,\"executeId\":\"test\"}".utf8))
        }

        try await client.purgeDirectory(fs: .named("remote:"), path: "OldFolder")
        XCTAssertEqual(requestedEndpoint, "/operations/purge")
        XCTAssertEqual(requestedMethod, "POST")
    }

    func testBackendMutationMethodsRejectPathTraversal() async throws {
        let remote = RemoteConfig(
            name: "Test Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain-test-key"
        )
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        let backend = try GoogleDriveFileProviderBackend(connection: connection)

        // createDirectory
        do {
            try await backend.createDirectory(at: "../escape")
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../escape"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // deleteFile
        do {
            try await backend.deleteFile(at: "/../../etc/passwd")
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("/../../etc/passwd"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // Empty directory deletion
        do {
            try await backend.deleteDirectory(at: "../", recursive: false)
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // deleteDirectory
        do {
            try await backend.deleteDirectory(at: "../danger", recursive: true)
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../danger"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // move
        do {
            try await backend.move(from: "../src", to: "valid/dst")
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../src"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            try await backend.move(from: "valid/src", to: "../dst")
            XCTFail("Expected traversal error")
        } catch let error as FileProviderPathError {
            XCTAssertEqual(error, .traversalAttempt("../dst"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPinnedOfflineTrackingAndInheritance() {
        let store = FileProviderDomainStore()
        let domainId = "test-pinned-domain"

        // Initial state
        XCTAssertFalse(store.isPinned("docs", forDomain: domainId))
        XCTAssertFalse(store.isOrInheritsPinned("docs/file.txt", forDomain: domainId))

        // Record pinned folder
        store.recordPinned("docs", forDomain: domainId)
        XCTAssertTrue(store.isPinned("docs", forDomain: domainId))
        XCTAssertTrue(store.isOrInheritsPinned("docs", forDomain: domainId))
        XCTAssertTrue(store.isOrInheritsPinned("docs/sub/report.pdf", forDomain: domainId))
        XCTAssertFalse(store.isPinned("other/file.txt", forDomain: domainId))
        XCTAssertFalse(store.isOrInheritsPinned("other/file.txt", forDomain: domainId))

        // Remove pinned folder
        store.removePinned("docs", forDomain: domainId)
        XCTAssertFalse(store.isPinned("docs", forDomain: domainId))
        XCTAssertFalse(store.isOrInheritsPinned("docs/sub/report.pdf", forDomain: domainId))
    }

    func testItemDecorationReturnsPinBadgeWhenPinned() {
        let remote = FileProviderRemoteItem(
            id: "docs/spec.pdf",
            parentPath: "docs",
            path: "docs/spec.pdf",
            filename: "spec.pdf",
            contentSize: 1024,
            contentType: "application/pdf",
            modifiedAt: Date(),
            isDirectory: false,
            remoteObjectID: "123"
        )

        let unpinnedItem = FreeMountFileProviderItem(item: remote, isReadOnly: false, isPinned: false)
        XCTAssertNil(unpinnedItem.decorations)

        let pinnedItem = FreeMountFileProviderItem(item: remote, isReadOnly: false, isPinned: true)
        XCTAssertNotNil(pinnedItem.decorations)
        XCTAssertEqual(pinnedItem.decorations?.count, 1)
        XCTAssertEqual(pinnedItem.decorations?.first?.rawValue, "com.freemount.decoration.pinned")
    }
}

