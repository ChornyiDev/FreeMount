import Foundation
import os.log

public protocol GoogleDriveConnectionHealthChecking: Sendable {
    func check(_ remote: RemoteConfig) async -> ConnectionHealth
}

/// Verifies the exact Keychain-backed account represented by a remote.
public actor GoogleDriveConnectionHealthChecker: GoogleDriveConnectionHealthChecking {
    private let keychain: KeychainService

    public init(
        keychain: KeychainService = KeychainService()
    ) {
        self.keychain = keychain
    }

    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do {
            let backend = try GoogleDriveFileProviderBackend(
                remote: remote,
                keychain: keychain
            )
            _ = try await backend.listChildren()
            return .healthy(checkedAt: Date())
        } catch {
            return Self.classify(error)
        }
    }

    public nonisolated static func classify(_ error: Error) -> ConnectionHealth {
        let details = error.localizedDescription.lowercased()
        let isAuthorizationFailure = error is KeychainError ||
            details.contains("invalid_grant") ||
            details.contains("token expired") ||
            details.contains("refresh token") ||
            details.contains("not authenticated") ||
            details.contains("no credential") ||
            details.contains("keychain credential") ||
            details.contains("credential does not match")

        if isAuthorizationFailure {
            return .authorizationRequired(
                reason: "Google Drive authorization expired or was revoked. Re-authorize this connection."
            )
        }

        return .unavailable(
            reason: "Google Drive is temporarily unavailable. Cached files may remain accessible; FreeMount will retry automatically."
        )
    }
}

/// rclone-backed My Drive operations used by the future File Provider extension.
///
/// This actor receives only a remote configuration. It loads the corresponding
/// credential directly from Keychain and passes it to rclone as an in-memory
/// filesystem reference, never as a named `rclone.conf` remote.
public actor GoogleDriveFileProviderBackend: FileProviderPathPrimitives {
    private static let log = Logger(subsystem: "com.freemount.app", category: "GoogleDriveFileProviderBackend")
    static let sharedWithMePath = ".freemount-shared-with-me"
    static let sharedWithMeDisplayName = "Shared with me"
    private let remote: RemoteConfig
    private let keychain: KeychainService
    private let primaryBackend: GenericRcloneFileProviderBackend
    private let sharedBackend: GenericRcloneFileProviderBackend

    public init(
        remote: RemoteConfig,
        keychain: KeychainService = KeychainService()
    ) throws {
        guard remote.provider == .googleDrive else {
            throw FileProviderDomainError.unsupportedProvider(remote.provider)
        }
        self.remote = remote
        self.keychain = keychain

        let accountKey = remote.keychainAccountKey
        let root = remote.bucketOrRootPath
        let sharedDriveOptions = Self.connectionOptions(sharedDriveID: remote.googleDriveSharedDriveID)
        let remoteName = remote.name
        let isReadOnly = remote.isReadOnly

        self.primaryBackend = GenericRcloneFileProviderBackend(
            fsProvider: {
                guard let account = accountKey else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "No Keychain credential is linked to '\(remoteName)'."
                    )
                }
                let credential = try await keychain.loadCredential(account: account)
                guard credential.provider == .googleDrive else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential is not a Google Drive credential."
                    )
                }
                return credential.fileSystemReference(root: root, additionalOptions: sharedDriveOptions)
            },
            isReadOnly: isReadOnly
        )

        self.sharedBackend = GenericRcloneFileProviderBackend(
            fsProvider: {
                guard let account = accountKey else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "No Keychain credential is linked to '\(remoteName)'."
                    )
                }
                let credential = try await keychain.loadCredential(account: account)
                guard credential.provider == .googleDrive else {
                    throw FreeMountError.invalidConfiguration(
                        reason: "The linked Keychain credential is not a Google Drive credential."
                    )
                }
                return credential.fileSystemReference(root: "", additionalOptions: ["shared_with_me": "true"])
            },
            isReadOnly: true
        )
    }

    public init(
        connection: FileProviderConnectionDescriptor,
        keychain: KeychainService = KeychainService()
    ) throws {
        let remote = RemoteConfig(
            id: connection.domain.remoteID,
            name: connection.domain.displayName,
            provider: connection.provider,
            bucketOrRootPath: connection.rootPath,
            keychainAccountKey: connection.keychainAccountKey,
            googleDriveSharedDriveID: connection.googleDriveSharedDriveID,
            isReadOnly: connection.isReadOnly
        )
        try self.init(remote: remote, keychain: keychain)
    }

    /// Lists direct children of a My Drive path.
    public func listChildren(at path: String = "") async throws -> [FileProviderRemoteItem] {
        let normalizedPath = try FileProviderPath.normalize(path)
        let isShared = remote.googleDriveSharedDriveID == nil && Self.isSharedWithMePath(normalizedPath)
        let backendPath = isShared ? Self.sharedRelativePath(normalizedPath) : normalizedPath
        let backend = isShared ? sharedBackend : primaryBackend
        let items = try await backend.listChildren(at: backendPath)

        var remoteItems = try items.map { item in
            let itemPath = try FileProviderPath.normalize(item.path)
            let visiblePath = isShared ? Self.sharedPath(for: itemPath) : itemPath
            return FileProviderRemoteItem(
                id: stableIdentifier(for: item, path: visiblePath, isShared: isShared),
                parentPath: FileProviderPath.parent(of: visiblePath),
                path: visiblePath,
                filename: item.filename,
                contentSize: item.contentSize,
                contentType: item.contentType,
                modifiedAt: item.modifiedAt,
                isDirectory: item.isDirectory,
                remoteObjectID: item.remoteObjectID,
                isReadOnly: isShared
            )
        }
        if normalizedPath.isEmpty, remote.googleDriveSharedDriveID == nil {
            remoteItems.append(Self.sharedWithMeRootItem)
        }
        return Self.deduplicatedByPath(remoteItems)
    }

    /// Retrieves metadata for a single item at the specified remote path.
    public func stat(at path: String) async throws -> FileProviderRemoteItem? {
        let normalizedPath = try FileProviderPath.normalize(path)
        guard !normalizedPath.isEmpty else {
            return nil
        }
        if normalizedPath == Self.sharedWithMePath, remote.googleDriveSharedDriveID == nil {
            return Self.sharedWithMeRootItem
        }
        if Self.isSharedWithMePath(normalizedPath), remote.googleDriveSharedDriveID != nil {
            return nil
        }
        let isShared = remote.googleDriveSharedDriveID == nil && Self.isSharedWithMePath(normalizedPath)
        let backendPath = isShared ? Self.sharedRelativePath(normalizedPath) : normalizedPath
        let backend = isShared ? sharedBackend : primaryBackend
        guard let item = try await backend.stat(at: backendPath) else {
            return nil
        }
        let itemPath = try FileProviderPath.normalize(item.path.isEmpty ? backendPath : item.path)
        let visiblePath = isShared ? Self.sharedPath(for: itemPath) : itemPath
        return FileProviderRemoteItem(
            id: stableIdentifier(for: item, path: visiblePath, isShared: isShared),
            parentPath: FileProviderPath.parent(of: visiblePath),
            path: visiblePath,
            filename: item.filename.isEmpty ? URL(fileURLWithPath: itemPath).lastPathComponent : item.filename,
            contentSize: item.contentSize,
            contentType: item.contentType,
            modifiedAt: item.modifiedAt,
            isDirectory: item.isDirectory,
            remoteObjectID: item.remoteObjectID,
            isReadOnly: isShared
        )
    }

    /// Copies a remote file into an isolated subdirectory within the system-provided staging directory.
    func download(path: String, to stagingDirectory: URL) async throws -> URL {
        let normalizedPath = try FileProviderPath.normalize(path)
        let isShared = remote.googleDriveSharedDriveID == nil && Self.isSharedWithMePath(normalizedPath)
        if isShared {
            let backendPath = Self.sharedRelativePath(normalizedPath)
            return try await sharedBackend.download(path: backendPath, to: stagingDirectory)
        } else {
            return try await primaryBackend.download(path: normalizedPath, to: stagingDirectory)
        }
    }

    /// Uploads a staged file to My Drive at the requested remote-relative path.
    func upload(stagedFile: URL, to path: String) async throws {
        let normalizedPath = try FileProviderPath.normalize(path)
        try Self.requireWritable(normalizedPath)
        guard !normalizedPath.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        try await primaryBackend.upload(stagedFile: stagedFile, to: normalizedPath)
    }

    /// Creates a new directory at the specified remote path.
    func createDirectory(at path: String) async throws {
        let normalizedPath = try FileProviderPath.normalize(path)
        try Self.requireWritable(normalizedPath)
        guard !normalizedPath.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        try await primaryBackend.createDirectory(at: normalizedPath)
    }

    /// Deletes a single file at the specified remote path.
    func deleteFile(at path: String) async throws {
        let normalizedPath = try FileProviderPath.normalize(path)
        try Self.requireWritable(normalizedPath)
        guard !normalizedPath.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        try await primaryBackend.deleteFile(at: normalizedPath)
    }

    /// Deletes a directory at the specified remote path, optionally recursively.
    func deleteDirectory(at path: String, recursive: Bool = false) async throws {
        let normalizedPath = try FileProviderPath.normalize(path)
        try Self.requireWritable(normalizedPath)
        guard !normalizedPath.isEmpty else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        try await primaryBackend.deleteDirectory(at: normalizedPath, recursive: recursive)
    }

    /// Moves or renames a remote file or folder.
    func move(from sourcePath: String, to destinationPath: String) async throws {
        let normalizedSource = try FileProviderPath.normalize(sourcePath)
        let normalizedDest = try FileProviderPath.normalize(destinationPath)
        try Self.requireWritable(normalizedSource)
        try Self.requireWritable(normalizedDest)
        guard !normalizedSource.isEmpty, !normalizedDest.isEmpty else {
            throw FileProviderPathError.traversalAttempt("\(sourcePath) -> \(destinationPath)")
        }
        try await primaryBackend.move(from: normalizedSource, to: normalizedDest)
    }

    private func fileSystemReference() async throws -> RcloneFileSystemReference {
        try await fileSystemReference(
            root: remote.bucketOrRootPath,
            additionalOptions: Self.connectionOptions(sharedDriveID: remote.googleDriveSharedDriveID)
        )
    }

    static func connectionOptions(sharedDriveID: String?) -> [String: String] {
        guard let sharedDriveID else { return [:] }
        return ["team_drive": sharedDriveID]
    }

    private func sharedWithMeFileSystemReference() async throws -> RcloneFileSystemReference {
        try await fileSystemReference(root: "", additionalOptions: ["shared_with_me": "true"])
    }

    private func fileSystemReference(
        root: String,
        additionalOptions: [String: String]
    ) async throws -> RcloneFileSystemReference {
        guard let account = remote.keychainAccountKey else {
            throw FreeMountError.invalidConfiguration(
                reason: "No Keychain credential is linked to '\(remote.name)'."
            )
        }

        let credential = try await keychain.loadCredential(account: account)
        // The opaque Keychain account key is the credential identity. The user-facing
        // connection name may change independently and must not invalidate OAuth.
        guard credential.provider == .googleDrive else {
            throw FreeMountError.invalidConfiguration(
                reason: "The linked Keychain credential is not a Google Drive credential."
            )
        }
        return credential.fileSystemReference(root: root, additionalOptions: additionalOptions)
    }

    private func stableIdentifier(for item: FileProviderRemoteItem, path: String, isShared: Bool) -> String {
        if let remoteObjectID = item.remoteObjectID, !remoteObjectID.isEmpty {
            return isShared ? "shared:\(remoteObjectID)" : remoteObjectID
        }
        return "path:\(path)"
    }

    static var sharedWithMeRootItem: FileProviderRemoteItem {
        FileProviderRemoteItem(
            id: "virtual:shared-with-me",
            parentPath: "",
            path: sharedWithMePath,
            filename: sharedWithMeDisplayName,
            contentSize: 0,
            isDirectory: true,
            remoteObjectID: "virtual:shared-with-me",
            isReadOnly: true
        )
    }

    static func isSharedWithMePath(_ path: String) -> Bool {
        path == sharedWithMePath || path.hasPrefix(sharedWithMePath + "/")
    }

    static func sharedRelativePath(_ path: String) -> String {
        guard path != sharedWithMePath else { return "" }
        return String(path.dropFirst(sharedWithMePath.count + 1))
    }

    static func sharedPath(for relativePath: String) -> String {
        relativePath.isEmpty ? sharedWithMePath : sharedWithMePath + "/" + relativePath
    }

    static func requireWritable(_ path: String) throws {
        guard !isSharedWithMePath(path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// File Provider requires every item identifier and filename within a parent
    /// to be unique. Google Drive permits siblings with identical names, while
    /// the current rclone path API cannot address those siblings unambiguously.
    /// Keep one deterministic representative until object-ID based operations
    /// replace path-based addressing.
    static func deduplicatedByPath(_ items: [FileProviderRemoteItem]) -> [FileProviderRemoteItem] {
        let grouped = Dictionary(grouping: items, by: \.path)
        let duplicates = grouped.filter { $0.value.count > 1 }
        for (path, candidates) in duplicates {
            let objectIDs = candidates.compactMap(\.remoteObjectID).sorted().joined(separator: ",")
            log.error(
                "Google Drive returned \(candidates.count) objects for path '\(path, privacy: .public)'; exposing one deterministic item. Object IDs: \(objectIDs, privacy: .private(mask: .hash))"
            )
        }

        return grouped.values.compactMap { candidates in
            candidates.min { lhs, rhs in
                let lhsKey = lhs.remoteObjectID ?? lhs.id
                let rhsKey = rhs.remoteObjectID ?? rhs.id
                return lhsKey < rhsKey
            }
        }
        .sorted { lhs, rhs in
            if lhs.filename.localizedStandardCompare(rhs.filename) == .orderedSame {
                return lhs.path < rhs.path
            }
            return lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }
}
