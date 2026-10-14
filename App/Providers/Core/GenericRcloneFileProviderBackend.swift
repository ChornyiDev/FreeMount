import Foundation
import os.log

/// Base rclone-backed File Provider implementation.
///
/// Handles standard rclone JSON-RPC communication, scratch staging in App Group
/// containers with UUID isolation, automatic cleanup, and translation between
/// rclone listed items and FileProviderRemoteItem.
public actor GenericRcloneFileProviderBackend: FileProviderPathPrimitives {
    public typealias FileSystemReferenceProvider = @Sendable () async throws -> RcloneFileSystemReference
    public typealias ItemMapper = @Sendable (RcloneListedItem, _ normalizedPath: String) throws -> FileProviderRemoteItem

    private let fsProvider: FileSystemReferenceProvider
    private let isReadOnly: Bool
    private let injectedClient: RcloneClient?
    private let injectedStagingContainer: URL?
    private let itemMapper: ItemMapper?

    public init(
        fsProvider: @escaping FileSystemReferenceProvider,
        isReadOnly: Bool = false,
        client: RcloneClient? = nil,
        stagingContainer: URL? = nil,
        itemMapper: ItemMapper? = nil
    ) {
        self.fsProvider = fsProvider
        self.isReadOnly = isReadOnly
        self.injectedClient = client
        self.injectedStagingContainer = stagingContainer
        self.itemMapper = itemMapper
    }

    public func client() async throws -> RcloneClient {
        if let injectedClient { return injectedClient }
        return try await RcloneClient.readyClient()
    }

    public func fileSystemReference() async throws -> RcloneFileSystemReference {
        try await fsProvider()
    }

    // MARK: - FileProviderPathPrimitives

    public func download(path: String, to stagingDirectory: URL) async throws -> URL {
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        let directory = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = String(normalized.split(separator: "/").last!)
        let rc = try await client()
        let fs = try await fileSystemReference()
        do {
            try await rc.copyFile(
                sourceFS: fs,
                sourcePath: normalized,
                destinationFS: .named(directory.path),
                destinationPath: filename
            )
            return directory.appendingPathComponent(filename)
        } catch {
            if !(error is RcloneJobError) {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }

    public func upload(stagedFile: URL, to path: String) async throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        let container: URL
        if let injectedStagingContainer {
            container = injectedStagingContainer
        } else if let appGroup = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FileProviderDomainStore.appGroupIdentifier) {
            container = appGroup
        } else {
            throw FreeMountError.invalidConfiguration(reason: "File Provider App Group container is unavailable.")
        }
        let uploadDir = container.appendingPathComponent("Uploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        try await RcloneTransferStaging.withCleanup(in: uploadDir) {
            let sharedFile = uploadDir.appendingPathComponent(stagedFile.lastPathComponent)
            try FileManager.default.copyItem(at: stagedFile, to: sharedFile)
            let rc = try await self.client()
            let fs = try await self.fileSystemReference()
            try await rc.copyFile(
                sourceFS: .named(uploadDir.path),
                sourcePath: sharedFile.lastPathComponent,
                destinationFS: fs,
                destinationPath: normalized
            )
        }
    }

    public func createDirectory(at path: String) async throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else { throw FileProviderPathError.traversalAttempt(path) }
        let rc = try await client()
        let fs = try await fileSystemReference()
        try await rc.makeDirectory(fs: fs, path: normalized)
    }

    public func deleteFile(at path: String) async throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else { throw FileProviderPathError.traversalAttempt(path) }
        let rc = try await client()
        let fs = try await fileSystemReference()
        try await rc.deleteFile(fs: fs, path: normalized)
    }

    public func deleteDirectory(at path: String, recursive: Bool = false) async throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else { throw FileProviderPathError.traversalAttempt(path) }
        let rc = try await client()
        let fs = try await fileSystemReference()
        if recursive {
            try await rc.purgeDirectory(fs: fs, path: normalized)
        } else {
            try await rc.removeDirectory(fs: fs, path: normalized)
        }
    }

    public func move(from sourcePath: String, to destinationPath: String) async throws {
        guard !isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let normalizedSource = try FileProviderPath.normalize(sourcePath)
        let normalizedDest = try FileProviderPath.normalize(destinationPath)
        guard !normalizedSource.isEmpty, !normalizedDest.isEmpty else {
            throw FileProviderPathError.traversalAttempt("\(sourcePath) -> \(destinationPath)")
        }
        let rc = try await client()
        let fs = try await fileSystemReference()
        try await rc.moveFile(
            sourceFS: fs,
            sourcePath: normalizedSource,
            destinationFS: fs,
            destinationPath: normalizedDest
        )
    }

    public func stat(at path: String) async throws -> FileProviderRemoteItem? {
        let normalized = try FileProviderPath.normalize(path)
        guard !normalized.isEmpty else { return nil }
        let rc = try await client()
        let fs = try await fileSystemReference()
        do {
            guard let item = try await rc.stat(fs: fs, path: normalized) else { return nil }
            return try mapItem(item, fallbackPath: normalized)
        } catch let FreeMountError.rcloneError(code, message) where code == 404 ||
            message.lowercased().contains("object not found") ||
            message.lowercased().contains("directory not found") {
            return nil
        }
    }

    public func listChildren(at path: String = "") async throws -> [FileProviderRemoteItem] {
        let normalized = try FileProviderPath.normalize(path)
        let rc = try await client()
        let fs = try await fileSystemReference()
        let items = try await rc.list(fs: fs, path: normalized)
        return try items.map { try self.mapItem($0, fallbackPath: normalized) }
    }

    public func mapItem(_ item: RcloneListedItem, fallbackPath: String) throws -> FileProviderRemoteItem {
        if let customMapper = itemMapper {
            return try customMapper(item, fallbackPath)
        }
        let itemPath = try FileProviderPath.normalize(item.path.isEmpty ? fallbackPath : item.path)
        return FileProviderRemoteItem(
            id: (item.id != nil && !item.id!.isEmpty) ? item.id! : "path:\(itemPath)",
            parentPath: FileProviderPath.parent(of: itemPath),
            path: itemPath,
            filename: itemPath.split(separator: "/").last.map(String.init) ?? item.name,
            contentSize: max(0, item.size),
            contentType: item.mimeType,
            modifiedAt: item.isDir ? nil : item.modTime,
            isDirectory: item.isDir,
            remoteObjectID: item.id,
            isReadOnly: isReadOnly
        )
    }
}
