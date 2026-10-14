import Foundation

/// Provider-neutral filesystem operations consumed by the shared Apple File
/// Provider extension.
public protocol FileProviderBackend: Sendable {
    func replaceAndMove(stagedFile: URL, from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem
    func upload(stagedFile: URL, to path: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem
    func deleteItem(at path: String, condition: FileProviderMutationCondition, recursive: Bool) async throws
    func move(from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem
    func downloadItem(path: String, to stagingDirectory: URL, requestedVersion: Data?) async throws -> FileProviderDownloadedItem
    func listChildren(at path: String) async throws -> [FileProviderRemoteItem]
    func stat(at path: String) async throws -> FileProviderRemoteItem?
    func createDirectoryItem(at path: String) async throws -> FileProviderRemoteItem
}

public extension FileProviderBackend {
    func replaceAndMove(stagedFile: URL, from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        guard let source = try await stat(at: sourcePath) else { throw FileProviderMutationError.versionConflict }
        try source.check(condition)
        let result = try await upload(stagedFile: stagedFile, to: destinationPath, condition: .absent)
        try await deleteItem(at: sourcePath, condition: condition, recursive: false)
        return result
    }
    func listChildren() async throws -> [FileProviderRemoteItem] {
        try await listChildren(at: "")
    }
}

/// Providers share best-effort metadata preflight, never atomic cloud conditions.
/// These path primitives are deliberately unavailable through the public backend.
protocol FileProviderPathPrimitives: FileProviderBackend {
    func download(path: String, to stagingDirectory: URL) async throws -> URL
    func upload(stagedFile: URL, to path: String) async throws
    func createDirectory(at path: String) async throws
    func deleteFile(at path: String) async throws
    func deleteDirectory(at path: String, recursive: Bool) async throws
    func move(from sourcePath: String, to destinationPath: String) async throws
}

extension FileProviderPathPrimitives {
    public func createDirectoryItem(at path: String) async throws -> FileProviderRemoteItem {
        guard try await stat(at: path) == nil else { throw FileProviderMutationError.versionConflict }
        try await createDirectory(at: path)
        // Observe a confirmed mutation from an uncancelled task. Late caller
        // cancellation must not turn successful legacy-provider writes into a
        // cancelled metadata read before the extension receives their result.
        let observed = try await Task.detached { try await self.stat(at: path) }.value
        guard let result = observed else { throw FileProviderMutationError.versionConflict }
        return result
    }
    /// Metadata checks reject observed stale bases; external writes can still race.
    public func upload(stagedFile: URL, to path: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        let current = try await stat(at: path)
        switch condition {
        case .absent: guard current == nil else { throw FileProviderMutationError.versionConflict }
        case .contentVersion: guard let current else { throw FileProviderMutationError.versionConflict }; try current.check(condition)
        }
        try await upload(stagedFile: stagedFile, to: path)
        let observed = try await Task.detached { try await self.stat(at: path) }.value
        guard let result = observed else { throw FileProviderMutationError.versionConflict }
        return result
    }
    public func deleteItem(at path: String, condition: FileProviderMutationCondition, recursive: Bool) async throws {
        guard let current = try await stat(at: path) else { return }
        try current.check(condition)
        if current.isDirectory { try await deleteDirectory(at: path, recursive: recursive) }
        else { try await deleteFile(at: path) }
    }
    public func move(from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        guard let current = try await stat(at: sourcePath) else { throw FileProviderMutationError.versionConflict }
        try current.check(condition)
        guard try await stat(at: destinationPath) == nil else { throw FileProviderMutationError.versionConflict }
        try await move(from: sourcePath, to: destinationPath)
        let observed = try await Task.detached { try await self.stat(at: destinationPath) }.value
        guard let result = observed else { throw FileProviderMutationError.versionConflict }
        return result
    }
    public func downloadItem(path: String, to stagingDirectory: URL, requestedVersion: Data?) async throws -> FileProviderDownloadedItem {
        guard let before = try await stat(at: path) else { throw FileProviderMutationError.versionConflict }
        if let requestedVersion { try before.check(.contentVersion(requestedVersion)) }
        let url = try await download(path: path, to: stagingDirectory)
        guard let after = try await stat(at: path), before.contentVersion == after.contentVersion else {
            try? FileManager.default.removeItem(at: url)
            throw FileProviderMutationError.versionConflict
        }
        return FileProviderDownloadedItem(url: url, item: before)
    }
}
