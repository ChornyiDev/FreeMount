import Foundation

/// rclone serializes Google errors into text. Recognize only documented SDK/OAuth
/// envelopes; the local RC HTTP status never becomes an upstream Google status.
enum GoogleCloudHealthDiagnostic {
    static func classify(_ error: Error, mode: GoogleCloudAuthenticationMode?) -> ConnectionDiagnostic {
        var rcStatus: Int?
        var upstreamStatus: Int?
        var upstreamReason: String?
        let details = CredentialRedactor.redact(error.localizedDescription)
        func issue(_ kind: ConnectionDiagnostic.Kind, _ summary: String, _ recovery: String) -> ConnectionDiagnostic {
            .init(kind: kind, summary: summary, recovery: recovery, technicalReason: details,
                  rcStatus: rcStatus, upstreamStatus: upstreamStatus, upstreamReason: upstreamReason)
        }
        let authorize = mode == .serviceAccount || error is GoogleCloudServiceAccountError
            ? "Replace the Service Account key for this connection; verify the account and key are active and your Mac's clock is correct."
            : "Use Re-authorize for this connection and approve the requested Google permissions."
        if error is RcloneRPCAuthenticationError {
            return issue(.localRuntime, "FreeMount could not authenticate its local storage engine.", "Reopen FreeMount and check its local daemon/Keychain setup. Changing Google authorization will not repair local RPC authentication.")
        }
        if let keychain = error as? KeychainError {
            switch keychain {
            case .itemNotFound, .invalidPayload: return issue(.authorization, "The stored cloud credential is missing or invalid.", authorize)
            case .operationFailed: return issue(.credentialStorage, "macOS Keychain could not provide the credential.", "Unlock Keychain and verify FreeMount's shared credential access, then retry. Keep the existing cloud credential.")
            }
        }
        if let serviceAccount = error as? GoogleCloudServiceAccountError {
            switch serviceAccount {
            case .tokenRejected(let status): upstreamStatus = status
            case .invalidTokenResponse: return issue(.serviceUnavailable, "Google returned an invalid token response.", "Retry later before replacing a working key.")
            default: return issue(.authorization, "The Service Account key cannot be used.", authorize)
            }
        }
        if let oauth = error as? GoogleDriveOAuthError {
            switch oauth {
            case .tokenExchangeFailed(let status, let reason): upstreamStatus = status; upstreamReason = reason
            case .authorizationRefreshRequired, .missingRefreshToken: return issue(.authorization, "Google authorization can no longer be refreshed.", authorize)
            default: return issue(.configuration, "Google authorization is not configured correctly.", "Check the desktop OAuth client configuration, then authorize again.")
            }
        }
        if let gcs = error as? GoogleCloudStorageError {
            switch gcs {
            case .apiFailure(let status, _): upstreamStatus = status
            case .missingPermissions: return issue(.permissions, "Google denied the required bucket permissions.", "Grant the connected principal the missing permissions shown in Technical details on this bucket, then retry.")
            case .apiDisabled: return issue(.apiDisabled, "A required Google Cloud API is disabled.", gcs.localizedDescription)
            case .insufficientScope: return issue(.authorization, "Google did not grant the required OAuth scopes.", gcs.localizedDescription)
            case .invalidSelection, .bucketMismatch: return issue(.configuration, "The bucket selection is invalid.", "Check the selected project and bucket. Create another connection to select a different bucket.")
            default: return issue(.unknown, "Google Cloud Storage could not complete the check.", "Review Technical details, resolve the reported issue and retry. Cached files remain registered in Finder.")
            }
        }
        if let freeMount = error as? FreeMountError {
            switch freeMount {
            case .rcloneError(let status, let message):
                rcStatus = status
                if let code = capture(#"googleapi: (?:Error ([0-9]{3}):|got HTTP response code ([0-9]{3}) with body:)"#, message) { upstreamStatus = Int(code) }
                if upstreamStatus != nil { upstreamReason = googleReason(message) }
                if let code = capture(#"oauth2: cannot fetch token: ([0-9]{3})\b"#, message) {
                    upstreamStatus = Int(code)
                    if let response = message.range(of: "Response:") {
                        struct OAuthFailure: Decodable { let error: String? }
                        upstreamReason = (try? JSONDecoder().decode(OAuthFailure.self, from: Data(message[response.upperBound...].utf8)))?.error
                    }
                }
                if let code = capture(#"oauth2: \"(invalid_grant|invalid_client|unauthorized_client)\""#, message) { upstreamReason = code; upstreamStatus = 400 }
                if upstreamStatus == nil {
                    if capture(#"(?:^|:\s*)(directory|bucket) not found\.?$"#, message) != nil {
                        return issue(.resourceMissing, "The selected bucket was not found or is not visible to this account.", "Verify the bucket exists and the account can access it. Create a new connection if a different bucket is required.")
                    }
                    if status == 401 { return issue(.localRuntime, "The local storage engine rejected the request.", "Reopen FreeMount and verify local RPC authorization, then retry.") }
                    if capture(#"(?i)\b(network is unreachable|no such host|connection refused|i/o timeout|TLS handshake timeout)\b"#, message) != nil {
                        return issue(.network, "The storage engine could not reach Google Cloud.", "Check your network, DNS and proxy settings, then retry. Cached files remain available.")
                    }
                    return issue(.unknown, "The storage engine could not verify this bucket.", "Review Technical details and retry. Do not replace Google credentials unless the reported error concerns authorization.")
                }
            case .networkTimeout: return issue(.network, "The connection check could not reach the storage engine.", "Check your connection and that FreeMount is running, then retry.")
            case .rcloneNotFound, .daemonNotRunning: return issue(.localRuntime, "FreeMount's storage engine is unavailable.", "Reopen FreeMount with its bundled rclone helper, then retry.")
            case .keychainError: return issue(.credentialStorage, "macOS Keychain could not provide the credential.", "Unlock Keychain and verify shared credential access, then retry.")
            case .invalidConfiguration: return issue(.configuration, "The connection configuration is invalid.", "Review Technical details and correct the connection or app configuration.")
            default: return issue(.unknown, "FreeMount could not verify the connection.", "Review Technical details and retry.")
            }
        }
        if error is URLError {
            return issue(.network, "The connection check could not reach the service.", "Check your network connection, then retry.")
        }
        let reason = upstreamReason?.lowercased() ?? ""
        if ["userprojectmissing", "userprojectinvalid", "userprojectaccessdenied", "userprojectaccountproblem", "accountdisabled", "billingdisabled", "billingnotenabled"].contains(reason) {
            return issue(.billing, "Google reported a billing or Requester Pays project issue.", "Check the connection's billing project, its billing status and your permission to use it in Google Cloud Console, then retry.")
        }
        if ["service_disabled", "accessnotconfigured", "servicedisabled"].contains(reason) {
            return issue(.apiDisabled, "The Cloud Storage API is disabled for the request project.", "Enable Cloud Storage JSON API in the project used for API requests, then retry.")
        }
        if ["access_token_scope_insufficient", "insufficientscope"].contains(reason) {
            return issue(.authorization, "Google did not grant the required OAuth scopes.", authorize)
        }
        if ["invalid_client", "unauthorized_client"].contains(reason) {
            return issue(.configuration, "Google rejected the OAuth client configuration.", "Check the configured desktop OAuth client; for a Service Account, verify the key and account in Google Cloud Console.")
        }
        if reason == "invalid_grant" || upstreamStatus == 401 { return issue(.authorization, "Google rejected the cloud authorization.", authorize) }
        if ["ratelimitexceeded", "userratelimitexceeded", "quotaexceeded", "dailylimitexceeded"].contains(reason) || upstreamStatus == 429 {
            return issue(.quota, "Google rate or quota limits were reached.", "Wait before retrying; inspect project quotas if the error persists. Re-authorization will not increase quota.")
        }
        switch upstreamStatus {
        case 400 where error is GoogleCloudServiceAccountError: return issue(.authorization, "Google rejected the Service Account key.", authorize)
        case 403: return issue(.permissions, "Google denied access to this bucket.", "Check the connected principal's bucket IAM permissions and any access policies, then retry.")
        case 404: return issue(.resourceMissing, "The selected bucket was not found or is not visible to this account.", "Verify the bucket exists and the account can access it. Create a new connection if a different bucket is required.")
        case 408: return issue(.network, "The Google Cloud request timed out.", "Check your connection and retry later.")
        case .some(500...599): return issue(.serviceUnavailable, "Google Cloud is temporarily unavailable.", "Retry later; keep the current authorization and registered Finder connection.")
        default: return issue(.unknown, "Google Cloud Storage could not verify this connection.", "Review Technical details and retry. Cached files remain registered in Finder.")
        }
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }
    private static func googleReason(_ text: String) -> String? {
        capture(#"\"reason\"\s*:\s*\"([A-Za-z_][A-Za-z0-9_]*)\""#, text)
            ?? capture(#"(?m)(?:,\s*|Reason:\s*)([A-Za-z_][A-Za-z0-9_]*)(?:\s*$|, Message:)"#, text)

    }
}

public struct GoogleCloudConnectionHealthChecker: Sendable {
    public typealias Probe = @Sendable (RemoteConfig) async throws -> Void
    private let probe: Probe
    public init(probe: @escaping Probe = { remote in
        let descriptor = try FileProviderConnectionDescriptor(remote: remote)
        let backend = try ProviderRegistry.shared.makeBackend(for: descriptor)
        _ = try await backend.listChildren()
    }) { self.probe = probe }
    public func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        do { try await probe(remote); return .healthy(checkedAt: Date()) }
        catch is CancellationError { return .unknown }
        catch { return .issue(GoogleCloudHealthDiagnostic.classify(error, mode: remote.googleCloudAuthentication?.mode)) }
    }
}
