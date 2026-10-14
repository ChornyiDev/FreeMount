import Foundation
import FileProvider

/// Long-lived enumerators use this proxy so settings and credential references
/// are resolved for every new operation, not only when the extension starts.
public actor FileProviderConnectionBackend: FileProviderBackend {
    public typealias Factory = @Sendable (FileProviderConnectionDescriptor) throws -> any FileProviderBackend
    private let domainIdentifier: String
    private let store: FileProviderDomainStore
    private let factory: Factory
    private var cached: (descriptor: FileProviderConnectionDescriptor, backend: any FileProviderBackend)?

    public init(domainIdentifier: String, store: FileProviderDomainStore, factory: @escaping Factory = { try ProviderRegistry.shared.makeBackend(for: $0) }) {
        self.domainIdentifier = domainIdentifier
        self.store = store
        self.factory = factory
    }

    private func resolve(writable: Bool = false) throws -> (FileProviderConnectionDescriptor, any FileProviderBackend) {
        guard let descriptor = try store.connection(forDomainIdentifier: domainIdentifier) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        if writable && descriptor.isReadOnly { throw CocoaError(.fileWriteNoPermission) }
        if cached?.descriptor != descriptor {
            cached = (descriptor, try factory(descriptor))
        }
        return (descriptor, cached!.backend)
    }

    private func applyingPolicy(_ item: FileProviderRemoteItem, connection: FileProviderConnectionDescriptor) -> FileProviderRemoteItem {
        FileProviderRemoteItem(id: item.id, parentPath: item.parentPath, path: item.path, filename: item.filename,
            contentSize: item.contentSize, contentType: item.contentType, modifiedAt: item.modifiedAt,
            isDirectory: item.isDirectory, remoteObjectID: item.remoteObjectID,
            isReadOnly: connection.isReadOnly || item.isReadOnly)
    }

    public func upload(stagedFile: URL, to path: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        let (connection, backend) = try resolve(writable: true)
        return applyingPolicy(try await backend.upload(stagedFile: stagedFile, to: path, condition: condition), connection: connection)
    }
    public func replaceAndMove(stagedFile: URL, from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        let (connection, backend) = try resolve(writable: true)
        return applyingPolicy(try await backend.replaceAndMove(stagedFile: stagedFile, from: sourcePath, to: destinationPath, condition: condition), connection: connection)
    }
    public func deleteItem(at path: String, condition: FileProviderMutationCondition, recursive: Bool) async throws {
        let (_, backend) = try resolve(writable: true)
        try await backend.deleteItem(at: path, condition: condition, recursive: recursive)
    }
    public func move(from sourcePath: String, to destinationPath: String, condition: FileProviderMutationCondition) async throws -> FileProviderRemoteItem {
        let (connection, backend) = try resolve(writable: true)
        return applyingPolicy(try await backend.move(from: sourcePath, to: destinationPath, condition: condition), connection: connection)
    }
    public func downloadItem(path: String, to stagingDirectory: URL, requestedVersion: Data?) async throws -> FileProviderDownloadedItem {
        let (connection, backend) = try resolve()
        let value = try await backend.downloadItem(path: path, to: stagingDirectory, requestedVersion: requestedVersion)
        return FileProviderDownloadedItem(url: value.url, item: applyingPolicy(value.item, connection: connection))
    }
    public func listChildren(at path: String) async throws -> [FileProviderRemoteItem] {
        let (connection, backend) = try resolve()
        return try await backend.listChildren(at: path).map { applyingPolicy($0, connection: connection) }
    }
    public func stat(at path: String) async throws -> FileProviderRemoteItem? {
        let (connection, backend) = try resolve()
        return try await backend.stat(at: path).map { applyingPolicy($0, connection: connection) }
    }

    public func createDirectoryItem(at path: String) async throws -> FileProviderRemoteItem {
        let (connection, backend) = try resolve(writable: true)
        return applyingPolicy(try await backend.createDirectoryItem(at: path), connection: connection)
    }
}
