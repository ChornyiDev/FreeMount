import Foundation

public struct ProviderRegistry: Sendable {
    public static let shared = ProviderRegistry(providers: [
        GoogleDriveProvider.registration,
        GoogleCloudStorageProvider.registration,
        SFTPProvider.registration,
        WebDAVProvider.registration,
        SMBProvider.registration,
        FTPProvider.registration
    ])

    public let registeredProviders: [CloudProvider]
    private let providersByID: [ProviderID: CloudProvider]

    public init(providers: [CloudProvider]) {
        precondition(Set(providers.map(\.id)).count == providers.count, "Provider IDs must be unique.")
        self.registeredProviders = providers
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
    }

    public func provider(for id: ProviderID) -> CloudProvider? {
        providersByID[id]
    }

    public func makeBackend(for connection: FileProviderConnectionDescriptor) throws -> any FileProviderBackend {
        guard let provider = provider(for: connection.provider) else {
            throw FileProviderDomainError.unsupportedProvider(connection.provider)
        }
        return try provider.makeBackend(for: connection)
    }

    public func checkHealth(for remote: RemoteConfig) async -> ConnectionHealth {
        guard let provider = provider(for: remote.provider) else { return .unknown }
        return await provider.checkHealth(remote)
    }
}
