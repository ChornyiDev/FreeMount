import Foundation

/// Non-secret setup values for a Google OAuth desktop client.
public struct GoogleDriveOAuthClient: Sendable, Equatable {
    public let clientID: String
    /// Desktop OAuth treats this as a public-client value; it is still never exposed in UI.
    public let clientSecret: String?

    public init(clientID: String, clientSecret: String? = nil) throws {
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw GoogleDriveOAuthError.invalidClientID
        }
        self.clientID = trimmedID
        let trimmedSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = trimmedSecret?.isEmpty == true ? nil : trimmedSecret
    }
}

/// Supplies the application-owned OAuth client identifier without exposing it in UI.
/// Release and development builds receive the values through build settings / Info.plist
/// or explicit process environment variables. No credentials are hardcoded in source code.
public enum GoogleDriveOAuthConfiguration {
    public static let clientIDEnvironmentKey = "FREEMOUNT_GOOGLE_CLIENT_ID"
    public static let clientSecretEnvironmentKey = "FREEMOUNT_GOOGLE_CLIENT_SECRET"
    private static let clientIDInfoPlistKey = "FreeMountGoogleOAuthClientID"
    private static let clientSecretInfoPlistKey = "FreeMountGoogleOAuthClientSecret"
    public static let defaultClientID: String? = nil
    public static let defaultClientSecret: String? = nil

    public static func loadClient() throws -> GoogleDriveOAuthClient {
        let environmentValue = ProcessInfo.processInfo.environment[clientIDEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBundleValue = (Bundle.main.object(forInfoDictionaryKey: clientIDInfoPlistKey) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleValue = (rawBundleValue?.hasPrefix("$(") == true || rawBundleValue?.isEmpty == true) ? nil : rawBundleValue

        guard let clientID = (environmentValue?.isEmpty == false ? environmentValue : nil) ?? bundleValue ?? defaultClientID, !clientID.isEmpty else {
            throw GoogleDriveOAuthError.clientNotConfigured
        }

        let envSecret = ProcessInfo.processInfo.environment[clientSecretEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBundleSecret = (Bundle.main.object(forInfoDictionaryKey: clientSecretInfoPlistKey) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleSecret = (rawBundleSecret?.hasPrefix("$(") == true || rawBundleSecret?.isEmpty == true) ? nil : rawBundleSecret
        let clientSecret = (envSecret?.isEmpty == false ? envSecret : nil) ?? bundleSecret ?? defaultClientSecret

        return try GoogleDriveOAuthClient(
            clientID: clientID,
            clientSecret: clientSecret
        )
    }
}

/// OAuth material suitable for rclone's `drive` backend. It is never persisted outside Keychain.
public struct GoogleDriveAuthorization: Sendable, Equatable {
    public let tokenJSON: String
    public let client: GoogleDriveOAuthClient

    public func credential(remoteName: String) -> RcloneRemoteCredential {
        var options = [
            "type": ProviderID.googleDrive.rawValue,
            "client_id": client.clientID,
            "token": tokenJSON
        ]
        if let clientSecret = client.clientSecret {
            options["client_secret"] = clientSecret
        }
        return RcloneRemoteCredential(
            remoteName: remoteName,
            provider: .googleDrive,
            backendOptions: options
        )
    }
}

public enum GoogleDriveOAuthError: LocalizedError, Sendable, Equatable {
    case invalidClientID
    case clientNotConfigured
    case authorizationDenied
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case callbackListenerFailed
    case tokenExchangeFailed(statusCode: Int, reason: String?)
    case tokenResponseInvalid
    case missingRefreshToken
    case authorizationRefreshRequired

    public var errorDescription: String? {
        switch self {
        case .invalidClientID:
            return "Enter a Google OAuth desktop client ID."
        case .clientNotConfigured:
            return "Google Drive authorization is not configured in this FreeMount build."
        case .authorizationDenied:
            return "Google authorization was cancelled or denied."
        case .invalidCallback:
            return "Google returned an invalid authorization callback."
        case .stateMismatch:
            return "Google authorization state validation failed. Please try again."
        case .missingAuthorizationCode:
            return "Google did not return an authorization code."
        case .callbackListenerFailed:
            return "FreeMount could not start its local OAuth callback listener."
        case .tokenExchangeFailed(let statusCode, let reason):
            if let reason, !reason.isEmpty {
                return "Google token exchange failed (HTTP \(statusCode): \(reason))."
            }
            return "Google token exchange failed (HTTP \(statusCode))."
        case .tokenResponseInvalid:
            return "Google returned an invalid token response."
        case .authorizationRefreshRequired:
            return "Google authorization can no longer be refreshed. Authorize again to restore access."
        case .missingRefreshToken:
            return "Google did not provide a refresh token. Remove FreeMount access in Google Account settings and authorize again."
        }
    }
}
