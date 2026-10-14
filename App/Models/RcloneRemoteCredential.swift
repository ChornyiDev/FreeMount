import Foundation

/// Secret rclone backend options retained only as a Keychain payload.
public struct RcloneRemoteCredential: Codable, Sendable, Equatable {
    public let remoteName: String
    public let provider: ProviderID
    public let backendOptions: [String: String]

    public init(remoteName: String, provider: ProviderID, backendOptions: [String: String]) {
        self.remoteName = remoteName
        self.provider = provider
        self.backendOptions = backendOptions
    }

    public func fileSystemReference(
        root: String,
        additionalOptions: [String: String] = [:]
    ) -> RcloneFileSystemReference {
        var options = backendOptions
        for (key, value) in additionalOptions {
            options[key] = value
        }
        // `_name` denotes a named entry in rclone.conf. Omitting it keeps this
        // a fully in-memory remote described by the `type` backend option.
        options["_root"] = provider == .ftp ? root : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return .configuration(options)
    }
}
