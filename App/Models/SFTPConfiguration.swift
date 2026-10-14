import Foundation

/// Authentication modes for SFTP connections.
public enum SFTPAuthMode: String, Codable, Sendable, CaseIterable, Equatable {
    case sshKey
    case password
    case sshAgent

    public var displayName: String {
        switch self {
        case .sshKey:
            return "SSH Key"
        case .password:
            return "Password"
        case .sshAgent:
            return "SSH Agent"
        }
    }
}

/// Configuration options for an SFTP remote connection.
public struct SFTPConfiguration: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var authMode: SFTPAuthMode
    public var keyPath: String?
    public var tunnel: SSHTunnelConfiguration?
    public var sshConfigHostAlias: String?

    public init(
        host: String,
        port: Int = 22,
        user: String,
        authMode: SFTPAuthMode = .sshKey,
        keyPath: String? = nil,
        tunnel: SSHTunnelConfiguration? = nil,
        sshConfigHostAlias: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.authMode = authMode
        self.keyPath = keyPath
        self.tunnel = tunnel
        self.sshConfigHostAlias = sshConfigHostAlias
    }

    /// Generates rclone backend options for this SFTP configuration.
    ///
    /// - Parameters:
    ///   - secret: Optional password or private key passphrase retrieved from Keychain.
    /// - Returns: Dictionary of backend options suitable for `RcloneFileSystemReference.configuration`.
    public func backendOptions(secret: String? = nil) -> [String: String] {
        var options: [String: String] = ["type": "sftp"]

        // If tunneled or if an external ssh command is requested:
        if let tunnel = tunnel, tunnel.isTunneled,
           let sshCmd = tunnel.buildSSHCommand(host: host, port: port, user: user, keyPath: keyPath) {
            options["ssh"] = sshCmd
            if let secret = secret, !secret.isEmpty {
                if authMode == .password {
                    options["pass"] = secret
                } else if authMode == .sshKey {
                    options["key_file_pass"] = secret
                }
            }
            return options
        }

        // Direct connection mode
        options["host"] = host
        options["user"] = user
        options["port"] = String(port)

        switch authMode {
        case .sshKey:
            if let keyPath = keyPath, !keyPath.isEmpty {
                options["key_file"] = SSHConfigParser.expandTilde(keyPath)
            }
            if let secret = secret, !secret.isEmpty {
                options["key_file_pass"] = secret
            }
        case .password:
            if let secret = secret, !secret.isEmpty {
                options["pass"] = secret
            }
        case .sshAgent:
            options["key_use_agent"] = "true"
        }

        return options
    }
}
