import Foundation

/// Stable identifier persisted with every provider connection.
///
/// A raw-value type keeps the provider boundary open for contributors without
/// requiring a central exhaustive enum to know every future integration.
public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    ExpressibleByStringLiteral {
    public let rawValue: String

    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        self.init(rawValue: value)
    }

    public static let googleCloudStorage: Self = "google cloud storage"
    public static let sftp: Self = "sftp"
    public static let s3: Self = "s3"
    public static let googleDrive: Self = "drive"
    public static let webdav: Self = "webdav"
    public static let ftp: Self = "ftp"
    public static let smb: Self = "smb"
    public static let b2: Self = "b2"

    public var displayName: String {
        ProviderRegistry.shared.provider(for: self)?.displayName ?? rawValue
    }

}
