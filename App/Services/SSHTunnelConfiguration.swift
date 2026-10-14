import Foundation

/// Types of SSH tunneling and proxy modes supported.
public enum SSHTunnelType: String, Codable, Sendable, CaseIterable, Equatable {
    case direct
    case cloudflare
    case jumpHost
    case customProxyCommand

    public var displayName: String {
        switch self {
        case .direct:
            return "Direct Connection"
        case .cloudflare:
            return "Cloudflare Zero Trust Tunnel"
        case .jumpHost:
            return "Jump Host / Bastion"
        case .customProxyCommand:
            return "Custom ProxyCommand"
        }
    }
}

/// Represents tunnel and proxy configuration for an SSH / SFTP connection.
public struct SSHTunnelConfiguration: Codable, Sendable, Equatable {
    public static let defaultCloudflareCommand = "cloudflared access ssh --hostname %h"

    public var type: SSHTunnelType
    public var customCommand: String?
    public var jumpHost: String?

    public init(
        type: SSHTunnelType = .direct,
        customCommand: String? = nil,
        jumpHost: String? = nil
    ) {
        self.type = type
        self.customCommand = customCommand
        self.jumpHost = jumpHost
    }

    /// Whether this configuration uses any tunnel or proxy mechanism.
    public var isTunneled: Bool {
        type != .direct
    }

    /// Builds the OpenSSH command string to pass to rclone's `ssh` backend option.
    ///
    /// - Parameters:
    ///   - host: Target server hostname or IP.
    ///   - port: Target server port (default 22).
    ///   - user: Username on target server.
    ///   - keyPath: Optional local path to the private key.
    /// - Returns: Complete `ssh` command string for rclone, or `nil` if direct connection should be used.
    public func buildSSHCommand(
        host: String,
        port: Int = 22,
        user: String,
        keyPath: String? = nil
    ) -> String? {
        guard isTunneled else { return nil }

        var parts: [String] = ["ssh", "-o", "StrictHostKeyChecking=accept-new"]

        switch type {
        case .direct:
            return nil

        case .cloudflare:
            let cmd = customCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
            let proxyCmd = (cmd != nil && !cmd!.isEmpty) ? cmd! : Self.defaultCloudflareCommand
            parts.append("-o")
            parts.append("\"ProxyCommand=\(proxyCmd)\"")

        case .jumpHost:
            if let jump = jumpHost?.trimmingCharacters(in: .whitespacesAndNewlines), !jump.isEmpty {
                parts.append("-J")
                parts.append(jump)
            }

        case .customProxyCommand:
            if let cmd = customCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                parts.append("-o")
                parts.append("\"ProxyCommand=\(cmd)\"")
            }
        }

        if let key = keyPath?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            parts.append("-i")
            parts.append(SSHConfigParser.expandTilde(key))
        }

        if port != 22 {
            parts.append("-p")
            parts.append(String(port))
        }

        let target = user.isEmpty ? host : "\(user)@\(host)"
        parts.append(target)

        return parts.joined(separator: " ")
    }
}
