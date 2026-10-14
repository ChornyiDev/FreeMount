import Foundation

/// Result of a connection preflight verification.
public struct PreflightResult: Sendable, Equatable {
    public let isSuccess: Bool
    public let message: String

    public static func success(_ message: String) -> PreflightResult {
        PreflightResult(isSuccess: true, message: message)
    }

    public static func failure(_ message: String) -> PreflightResult {
        PreflightResult(isSuccess: false, message: message)
    }
}

/// Universal preflight verification service for network protocols (WebDAV, SFTP, SMB, FTP).
/// Verifies that in-memory credentials, server address, and port can successfully establish
/// a session through rclone without saving anything to the macOS Keychain or creating local mounts.
public actor ConnectionPreflightService {
    public static let shared = ConnectionPreflightService()

    private let challengeSession: URLSession

    public init(challengeSession: URLSession = RcloneTransportDelegate.makeSession()) {
        self.challengeSession = challengeSession
    }

    /// Performs an ephemeral verification against the remote server using the provided rclone backend options.
    ///
    /// - Parameters:
    ///   - client: The active RcloneClient instance.
    ///   - backendOptions: In-memory configuration dictionary (e.g. type, url, user, pass, host, port, etc.).
    ///   - remotePath: Optional remote subdirectory to verify.
    /// - Returns: PreflightResult with success message or human-readable failure reason.
    public func verify(
        client: RcloneClient,
        backendOptions: [String: String],
        remotePath: String = ""
    ) async -> PreflightResult {
        let startTime = ContinuousClock.now
        do {
            // Some servers allow anonymous PROPFIND but require Digest for GET.
            // Rclone's standard WebDAV backend supports Basic/Bearer, not Digest.
            // Inspect only the challenge: never send cloud or RPC credentials here.
            if backendOptions["type"] == "webdav",
               backendOptions["bearer_token"] == nil,
               let endpoint = backendOptions["url"],
               let url = URL(string: endpoint),
               url.user == nil, url.password == nil,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                var request = URLRequest(url: remotePath.isEmpty ? url : url.appendingPathComponent(remotePath))
                request.httpMethod = "HEAD"
                request.timeoutInterval = 10
                // HEAD may be unsupported or fail TLS policy handled by rclone;
                // only a confirmed Digest-only challenge blocks this verification.
                if let (_, response) = try? await challengeSession.data(for: request),
                   let http = response as? HTTPURLResponse,
                   http.statusCode == 401,
                   let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate")?.lowercased(),
                   challenge.contains("digest "), !challenge.contains("basic ") {
                    return .failure("This WebDAV server requires Digest authentication. This connection cannot be saved yet. Support will be added after it becomes available in an official rclone release and is integrated into FreeMount.")
                }
            }
            let fs = RcloneFileSystemReference.configuration(backendOptions)
            let options = RcloneListOptions(recurse: false)
            _ = try await client.list(fs: fs, path: remotePath, options: options)
            let elapsed = startTime.duration(to: .now)
            let millis = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            return .success("Connected successfully (\(max(1, millis))ms)")
        } catch {
            let message = Self.classify(error: error, backendOptions: backendOptions)
            return .failure(message)
        }
    }

    /// Classifies raw rclone errors into clean, human-readable explanations.
    public nonisolated static func classify(error: Error, backendOptions: [String: String]) -> String {
        let rawMessage: String
        if let fmError = error as? FreeMountError {
            switch fmError {
            case .rcloneError(_, let message):
                rawMessage = message
            case .networkTimeout(let op):
                rawMessage = "Network timeout: \(op)"
            default:
                rawMessage = error.localizedDescription
            }
        } else {
            rawMessage = error.localizedDescription
        }

        let lower = rawMessage.lowercased()

        if backendOptions["type"] == "ftp", lower.contains("530") || lower.contains("login incorrect") {
            return "FTP authentication failed. Verify the username and password, or select Anonymous if the server permits it."
        }
        if backendOptions["type"] == "smb" {
            if lower.contains("logon_failure") || lower.contains("wrong_password") || lower.contains("account_disabled") {
                return "SMB authentication failed. Verify the username, password, and domain."
            }
            if lower.contains("access_denied") {
                return "The SMB server denied access. Verify the account and shared folder permissions."
            }
            if lower.contains("bad_network_name") || lower.contains("object_path_not_found") {
                return "SMB shared folder or subfolder not found. Verify the share name and path."
            }
        }

        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("permission denied") || lower.contains("auth failed") || lower.contains("authentication failed") || lower.contains("bad credentials") {
            return "Authentication failed (401). Please verify your username and password or token."
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return "Access forbidden (403). The account lacks permission to access this remote directory."
        }
        if lower.contains("certificate") || lower.contains("x509") || lower.contains("self-signed") || lower.contains("unknown authority") {
            return "SSL/TLS certificate verification failed. If your server uses a self-signed certificate, enable 'Allow untrusted / self-signed SSL certificates'."
        }
        if lower.contains("404") || lower.contains("directory not found") || lower.contains("not found") {
            return "Remote path not found (404). Verify that the specified remote directory exists on the server."
        }
        if lower.contains("connection refused") {
            let port = backendOptions["port"] ?? ""
            let portSuffix = port.isEmpty ? "" : " on port \(port)"
            return "Connection refused\(portSuffix). Verify the server is running and the port is open."
        }
        if lower.contains("no such host") || lower.contains("nodename nor servname") || lower.contains("host not found") {
            return "Host not found. Verify the server hostname or domain spelling."
        }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("network unreachable") || lower.contains("no route to host") {
            return "Connection timed out. The server could not be reached. Check your network or firewall."
        }
        if lower.contains("proxy") || lower.contains("cloudflared") {
            return "Tunnel/Proxy connection failed: \(CredentialRedactor.redact(rawMessage))"
        }

        return CredentialRedactor.redact(rawMessage)
    }
}
