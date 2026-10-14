import Foundation

/// Supported WebDAV vendor presets.
public enum WebDAVVendor: String, Codable, Sendable, CaseIterable, Equatable {
    case generic = "other"
    case nextcloud = "nextcloud"
    case owncloud = "owncloud"

    /// Rclone backend `vendor` parameter value.
    public var rcloneVendor: String {
        switch self {
        case .nextcloud:
            return "nextcloud"
        case .owncloud:
            return "owncloud"
        case .generic:
            return "other"
        }
    }
}

/// Authentication mode for WebDAV connections.
public enum WebDAVAuthMode: String, Codable, Sendable, CaseIterable, Equatable {
    case password
    case bearerToken

    public var displayName: String {
        switch self {
        case .password:
            return "Password"
        case .bearerToken:
            return "Bearer Token"
        }
    }
}

/// Configuration options for a WebDAV remote connection.
public struct WebDAVConfiguration: Codable, Sendable, Equatable {
    public var url: String
    public var vendor: WebDAVVendor
    public var user: String
    public var authMode: WebDAVAuthMode
    public var insecureSkipVerify: Bool

    public init(
        url: String,
        vendor: WebDAVVendor = .generic,
        user: String = "",
        authMode: WebDAVAuthMode = .password,
        insecureSkipVerify: Bool = false
    ) {
        self.url = url
        self.vendor = vendor
        self.user = user
        self.authMode = authMode
        self.insecureSkipVerify = insecureSkipVerify
    }

    /// Generates rclone backend options for this WebDAV configuration.
    ///
    /// - Parameters:
    ///   - secret: Optional password, app password, or bearer token retrieved from Keychain.
    /// - Returns: Dictionary of backend options suitable for `RcloneFileSystemReference.configuration`.
    public func backendOptions(secret: String? = nil) -> [String: String] {
        var options: [String: String] = [
            "type": "webdav",
            "url": url.trimmingCharacters(in: .whitespacesAndNewlines),
            "vendor": vendor.rcloneVendor
        ]

        // Rclone prioritizes user/pass over bearer_token. Hidden password-mode
        // fields must not override the selected Bearer authentication mode.
        if authMode == .password && !user.isEmpty {
            options["user"] = user.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if insecureSkipVerify {
            options["insecure_skip_verify"] = "true"
        }

        if let secret = secret, !secret.isEmpty {
            switch authMode {
            case .password:
                options["pass"] = secret
            case .bearerToken:
                options["bearer_token"] = secret
            }
        }

        return options
    }
}
