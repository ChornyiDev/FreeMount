import Foundation

/// Non-secret identity for one Finder-visible cloud provider domain.
///
/// The identifier is stable for the lifetime of a remote and is safe to share
/// between the host app, the File Provider extension, and App Group storage.
public struct FileProviderDomainDescriptor: Codable, Sendable, Equatable, Identifiable {
    public static let identifierPrefix = "com.freemount.google"

    public let remoteID: UUID
    public let displayName: String
    public let provider: ProviderID

    public var id: String { domainIdentifier }

    public var domainIdentifier: String {
        if provider == .googleDrive {
            return "\(Self.identifierPrefix).\(remoteID.uuidString.lowercased())"
        }
        let safeProvider = provider.rawValue.replacingOccurrences(of: " ", with: "-")
        return "com.freemount.\(safeProvider).\(remoteID.uuidString.lowercased())"
    }

    public init(remote: RemoteConfig) throws {
        guard ProviderRegistry.shared.provider(for: remote.provider) != nil else {
            throw FileProviderDomainError.unsupportedProvider(remote.provider)
        }

        let normalizedName = remote.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw FileProviderDomainError.emptyDisplayName
        }

        remoteID = remote.id
        displayName = normalizedName
        provider = remote.provider
    }

    public init(remoteID: UUID, displayName: String, provider: ProviderID = .googleDrive) throws {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw FileProviderDomainError.emptyDisplayName
        }

        self.remoteID = remoteID
        self.displayName = normalizedName
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case remoteID
        case displayName
        case provider
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = try container.decode(UUID.self, forKey: .remoteID)
        displayName = try container.decode(String.self, forKey: .displayName)
        provider = try container.decodeIfPresent(ProviderID.self, forKey: .provider) ?? .googleDrive
    }
}

public enum FileProviderDomainError: LocalizedError, Sendable, Equatable {
    case unsupportedProvider(ProviderID)
    case emptyDisplayName
    case systemRegistrationFailed(String)
    case extensionNotEmbedded
    case missingKeychainAccount

    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "This FreeMount build does not include the \(provider.displayName) provider."
        case .emptyDisplayName:
            return "A File Provider connection needs a non-empty display name."
        case .systemRegistrationFailed(let reason):
            return "macOS could not register the File Provider domain: \(reason)"
        case .extensionNotEmbedded:
            return "This FreeMount build does not contain the File Provider extension. Use the signed app build."
        case .missingKeychainAccount:
            return "This Google Drive connection has no Keychain credential reference. Re-authorize it before using File Provider."
        }
    }
}

/// Non-secret connection data required by the File Provider extension.
///
/// `keychainAccountKey` is an opaque lookup key, not a credential. The token
/// remains in the shared Keychain access group and is never encoded here.
public struct FileProviderConnectionDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let domain: FileProviderDomainDescriptor
    public let rootPath: String
    public let keychainAccountKey: String
    public let googleDriveSharedDriveID: String?
    public let isReadOnly: Bool

    public var provider: ProviderID { domain.provider }

    public var id: String { domain.id }

    public init(remote: RemoteConfig) throws {
        domain = try FileProviderDomainDescriptor(remote: remote)
        if remote.provider == .googleCloudStorage {
            try GoogleCloudStorageSelection.validateBucket(remote.bucketOrRootPath)
            guard let selection = remote.googleCloudStorage, selection.bucket == remote.bucketOrRootPath else {
                throw GoogleCloudStorageError.invalidSelection
            }
        }
        rootPath = try remote.provider == .ftp
            ? FTPConfiguration.rootPath(remote.bucketOrRootPath)
            : FileProviderPath.normalize(remote.bucketOrRootPath)
        if remote.provider == .smb && rootPath.isEmpty { throw SMBConfigurationError.invalidShare }
        guard let accountKey = remote.keychainAccountKey,
              !accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FileProviderDomainError.missingKeychainAccount
        }
        keychainAccountKey = accountKey
        googleDriveSharedDriveID = remote.googleDriveSharedDriveID
        isReadOnly = remote.isReadOnly
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case rootPath
        case keychainAccountKey
        case googleDriveSharedDriveID
        case isReadOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(FileProviderDomainDescriptor.self, forKey: .domain)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        keychainAccountKey = try container.decode(String.self, forKey: .keychainAccountKey)
        googleDriveSharedDriveID = try container.decodeIfPresent(String.self, forKey: .googleDriveSharedDriveID)
        isReadOnly = try container.decode(Bool.self, forKey: .isReadOnly)
        if domain.provider == .googleCloudStorage {
            try GoogleCloudStorageSelection.validateBucket(rootPath)
        }
    }
}
