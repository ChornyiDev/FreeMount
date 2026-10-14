import Foundation

/// Complete registration for one storage provider available in this build.
public struct CloudProvider: Identifiable, Sendable {
    public typealias BackendFactory = @Sendable (FileProviderConnectionDescriptor) throws -> any FileProviderBackend
    public typealias HealthChecker = @Sendable (RemoteConfig) async -> ConnectionHealth

    public let id: ProviderID
    public let displayName: String
    public let iconAssetName: String?
    public let fallbackSystemIconName: String
    public let accentColorHex: UInt32
    private let backendFactory: BackendFactory
    private let healthChecker: HealthChecker?

    public init(
        id: ProviderID,
        displayName: String,
        iconAssetName: String?,
        fallbackSystemIconName: String,
        accentColorHex: UInt32,
        backendFactory: @escaping BackendFactory,
        healthChecker: HealthChecker? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.iconAssetName = iconAssetName
        self.fallbackSystemIconName = fallbackSystemIconName
        self.accentColorHex = accentColorHex
        self.backendFactory = backendFactory
        self.healthChecker = healthChecker
    }

    public func makeBackend(for connection: FileProviderConnectionDescriptor) throws -> any FileProviderBackend {
        try backendFactory(connection)
    }

    public func checkHealth(_ remote: RemoteConfig) async -> ConnectionHealth {
        guard let healthChecker else { return .unknown }
        return await healthChecker(remote)
    }
}
