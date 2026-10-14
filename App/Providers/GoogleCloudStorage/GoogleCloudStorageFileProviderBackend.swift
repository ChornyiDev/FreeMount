import Foundation
import UniformTypeIdentifiers

/// One immutable bucket per backend. Object paths never select another bucket.
public actor GoogleCloudStorageFileProviderBackend: FileProviderPathPrimitives {
    private let connection: FileProviderConnectionDescriptor
    private let keychain: KeychainService
    private let injectedClient: RcloneClient?
    private let injectedStagingContainer: URL?
    private let injectedCredential: RcloneRemoteCredential?
    private let genericBackend: GenericRcloneFileProviderBackend

    public init(connection: FileProviderConnectionDescriptor, keychain: KeychainService = KeychainService(), client: RcloneClient? = nil, credential: RcloneRemoteCredential? = nil, stagingContainer: URL? = nil) throws {
        guard connection.provider == .googleCloudStorage else { throw FileProviderDomainError.unsupportedProvider(connection.provider) }
        try GoogleCloudStorageSelection.validateBucket(connection.rootPath)
        self.connection = connection
        self.keychain = keychain
        self.injectedClient = client
        self.injectedCredential = credential
        self.injectedStagingContainer = stagingContainer

        let accountKey = connection.keychainAccountKey
        let rootPath = connection.rootPath
        self.genericBackend = GenericRcloneFileProviderBackend(
            fsProvider: {
                let resolved: RcloneRemoteCredential
                if let credential { resolved = credential }
                else { resolved = try await keychain.loadCredential(account: accountKey) }
                guard resolved.provider == .googleCloudStorage,
                      resolved.backendOptions["type"] == ProviderID.googleCloudStorage.rawValue else {
                    throw FreeMountError.invalidConfiguration(reason: "The linked credential does not match this GCS connection.")
                }
                return resolved.fileSystemReference(root: rootPath, additionalOptions: ["directory_markers": "true", "decompress": "false", "no_check_bucket": "true", "bucket_policy_only": "true", "bucket_acl": "", "object_acl": ""])
            },
            isReadOnly: connection.isReadOnly,
            client: client,
            stagingContainer: stagingContainer
        )
    }

    func fileSystemReference(root: String? = nil) async throws -> RcloneFileSystemReference {
        let credential: RcloneRemoteCredential
        if let injectedCredential { credential = injectedCredential }
        else { credential = try await keychain.loadCredential(account: connection.keychainAccountKey) }
        guard credential.provider == .googleCloudStorage,
              credential.backendOptions["type"] == ProviderID.googleCloudStorage.rawValue else {
            throw FreeMountError.invalidConfiguration(reason: "The linked credential does not match this GCS connection.")
        }
        return credential.fileSystemReference(root: root ?? connection.rootPath, additionalOptions: ["directory_markers": "true", "decompress": "false", "no_check_bucket": "true", "bucket_policy_only": "true", "bucket_acl": "", "object_acl": ""])
    }

    private func client() async throws -> RcloneClient {
        if let injectedClient { return injectedClient }
        return try await RcloneClient.readyClient()
    }

    public func listChildren(at path: String) async throws -> [FileProviderRemoteItem] {
        let result = try await listing(at: path)
        return result.items
    }

    private func listing(at path: String) async throws -> (items: [FileProviderRemoteItem], omitted: Int) {
        let path = try Self.normalizedPath(path)
        try await ensureUnambiguous(path)
        let raw = try await client().list(fs: fileSystemReference(), path: path)
        let result = GoogleCloudPathPolicy.partition(raw, parent: path)
        let items = try result.supported.map { try item($0, fallbackPath: path) }
        return (items, result.omitted)
    }

    /// A stale Finder item or a newly created name must not select one of several
    /// remote entries that share a Finder name (file/prefix, case or Unicode).
    private func ensureUnambiguous(_ path: String) async throws {
        guard !path.isEmpty else { return }
        var parent = ""
        for component in path.split(separator: "/") {
            let target = parent.isEmpty ? String(component) : parent + "/" + component
            let raw: [RcloneListedItem]
            do { raw = try await client().list(fs: fileSystemReference(), path: parent) }
            catch let FreeMountError.rcloneError(code, message) where code == 404 || message.lowercased().contains("directory not found") {
                return // Missing parents may be created by an upload/mkdir.
            }
            let matches = raw.filter { GoogleCloudPathPolicy.finderKey($0.path) == GoogleCloudPathPolicy.finderKey(target) }
            guard matches.count <= 1, matches.first.map({ Array($0.path.utf8) == Array(target.utf8) }) ?? true else {
                throw GoogleCloudStorageError.unsupportedObjectNames("The requested name is ambiguous or differs from the exact remote name.")
            }
            parent = target
        }
    }

    public func stat(at path: String) async throws -> FileProviderRemoteItem? {
        let path = try Self.normalizedPath(path)
        guard !path.isEmpty else { return nil }
        try await ensureUnambiguous(path)
        do {
            guard let value = try await client().stat(fs: fileSystemReference(), path: path) else { return nil }
            let mapped = try item(value, fallbackPath: path)
            guard Array(mapped.path.utf8) == Array(path.utf8) else { throw GoogleCloudStorageError.unsupportedObjectNames("Metadata returned a different object path.") }
            return mapped
        } catch let FreeMountError.rcloneError(code, message) where code == 404 || message.lowercased().contains("object not found") || message.lowercased().contains("directory not found") {
            return nil
        }
    }

    private func item(_ value: RcloneListedItem, fallbackPath: String) throws -> FileProviderRemoteItem {
        let path = try Self.normalizedPath(value.path.isEmpty ? fallbackPath : value.path)
        return FileProviderRemoteItem(id: "path:\(path)", parentPath: FileProviderPath.parent(of: path), path: path, filename: path.split(separator: "/").last.map(String.init) ?? value.name, contentSize: max(0, value.size), contentType: value.mimeType, modifiedAt: value.isDir ? nil : value.modTime, isDirectory: value.isDir, remoteObjectID: value.id, isReadOnly: connection.isReadOnly)
    }

    func download(path: String, to stagingDirectory: URL) async throws -> URL {
        let path = try Self.normalizedPath(path, allowRoot: false)
        try await ensureUnambiguous(path)
        return try await genericBackend.download(path: path, to: stagingDirectory)
    }

    func upload(stagedFile: URL, to path: String) async throws {
        let path = try writablePath(path)
        try await ensureUnambiguous(path)
        try await genericBackend.upload(stagedFile: stagedFile, to: path)
    }

    func createDirectory(at path: String) async throws {
        let path = try writablePath(path)
        try await ensureUnambiguous(path)
        try await genericBackend.createDirectory(at: path)
    }

    func deleteFile(at path: String) async throws {
        let path = try writablePath(path)
        try await ensureUnambiguous(path)
        try await genericBackend.deleteFile(at: path)
    }

    func deleteDirectory(at path: String, recursive: Bool) async throws {
        let path = try writablePath(path)
        let snapshot = try await directorySnapshot(at: path)
        guard recursive || snapshot.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        for item in snapshot where !item.isDirectory {
            try Task.checkCancellation()
            guard try await stat(at: item.path) == item else { throw FileProviderMutationError.versionConflict }
            try await deleteFile(at: item.path)
        }
        for item in snapshot.filter(\.isDirectory).sorted(by: { $0.path.count > $1.path.count }) {
            try await removeEmptyDirectory(at: item.path)
        }
        try await removeEmptyDirectory(at: path)
    }

    private func removeEmptyDirectory(at path: String) async throws {
        let path = try writablePath(path)
        try await ensureUnambiguous(path)
        guard try await client().list(fs: fileSystemReference(), path: path).isEmpty else {
            throw GoogleCloudStorageError.unsupportedObjectNames("The folder contains remaining objects.")
        }
        try await client().removeDirectory(fs: fileSystemReference(), path: path)
    }

    // Equivalent file names can be moved directly by ordinary GCS movefile.
    // Folder variants are declined before mutation rather than adding two-leg recovery.
    public func move(from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        let source = try writablePath(sourcePath)
        let destination = try writablePath(destinationPath)
        guard let current = try await stat(at: source) else { throw FileProviderMutationError.versionConflict }
        try current.check(condition)
        if Array(source.utf8) == Array(destination.utf8) { return current }
        guard !destination.hasPrefix(source + "/") else { throw FileProviderPathError.traversalAttempt(destination) }
        let equivalent = GoogleCloudPathPolicy.finderKey(source) == GoogleCloudPathPolicy.finderKey(destination)
        if equivalent && current.isDirectory {
            throw GoogleCloudStorageError.unsupportedObjectNames("Case/Unicode-equivalent folder renames are unavailable. Rename to a distinct name first.")
        }
        if !equivalent { try await ensureUnambiguous(destination) }
        guard try await rawStat(at: destination) == nil else { throw FileProviderMutationError.versionConflict }
        try await move(from: source, to: destination)
        let observed = try await Task.detached { try await self.stat(at: destination) }.value
        guard let observed else { throw FileProviderMutationError.versionConflict }
        return observed
    }

    func move(from sourcePath: String, to destinationPath: String) async throws {
        let source = try writablePath(sourcePath)
        let destination = try writablePath(destinationPath)
        guard let current = try await stat(at: source) else { throw CocoaError(.fileNoSuchFile) }
        guard try await rawStat(at: destination) == nil else { throw CocoaError(.fileWriteFileExists) }
        if current.isDirectory {
            let snapshot = try await directorySnapshot(at: source)
            let rc = try await client()
            try await rc.makeDirectory(fs: fileSystemReference(), path: destination)
            try await rc.copyDirectory(sourceFS: fileSystemReference(root: connection.rootPath + "/" + source),
                destinationFS: fileSystemReference(root: connection.rootPath + "/" + destination))
            // No source cleanup after a failed/unknown copy. Successful copies
            // are observed before source removal; metadata checks are not atomic.
            try Task.checkCancellation()
            let copied = try await directorySnapshot(at: destination)
            guard let destinationRoot = try await stat(at: destination), destinationRoot.isDirectory else { throw GoogleCloudStorageError.sourceChanged }
            let expected = snapshot.map { String($0.path.dropFirst(source.count)) + ":\($0.isDirectory):\($0.contentSize)" }.sorted()
            let actual = copied.map { String($0.path.dropFirst(destination.count)) + ":\($0.isDirectory):\($0.contentSize)" }.sorted()
            guard actual == expected, try await directorySnapshot(at: source) == snapshot else { throw GoogleCloudStorageError.sourceChanged }
            try Task.checkCancellation()
            try await deleteDirectory(at: source, recursive: true)
        } else {
            try await client().moveFile(sourceFS: fileSystemReference(), sourcePath: source,
                destinationFS: fileSystemReference(), destinationPath: destination)
        }
    }

    private func rawStat(at path: String) async throws -> FileProviderRemoteItem? {
        do {
            return try await client().stat(fs: fileSystemReference(), path: path).map { try item($0, fallbackPath: path) }
        } catch let FreeMountError.rcloneError(code, message) where code == 404 || message.lowercased().contains("object not found") || message.lowercased().contains("directory not found") {
            return nil
        }
    }

    private func directorySnapshot(at path: String) async throws -> [FileProviderRemoteItem] {
        try await FileProviderTreeReader.read(at: [path]) { folder in
            let result = try await self.listing(at: folder)
            guard result.omitted == 0 else { throw GoogleCloudStorageError.unsupportedObjectNames("Folder operations cannot include hidden or ambiguous object names.") }
            return result.items
        }.sorted { $0.path < $1.path }
    }

    static func normalizedPath(_ path: String, allowRoot: Bool = true) throws -> String {
        try GoogleCloudPathPolicy.validate(path, allowRoot: allowRoot)
    }

    private func writablePath(_ path: String) throws -> String {
        guard !connection.isReadOnly else { throw CocoaError(.fileWriteNoPermission) }
        let path = try Self.normalizedPath(path, allowRoot: false)
        return path
    }
}

public enum GoogleCloudStorageProvider {
    public static let registration = CloudProvider(
        id: .googleCloudStorage,
        displayName: "Google Cloud Storage",
        iconAssetName: "GoogleCloud",
        fallbackSystemIconName: "cloud.fill",
        accentColorHex: 0x4285F4,
        backendFactory: { try GoogleCloudStorageFileProviderBackend(connection: $0) },
        healthChecker: { remote in await GoogleCloudConnectionHealthChecker().check(remote) }
    )
}

