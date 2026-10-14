import Foundation

/// Non-secret SMB endpoint and NTLM account settings. The share root lives in RemoteConfig.
public struct SMBConfiguration: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var domain: String

    public init(host: String, port: Int = 445, user: String, domain: String = "WORKGROUP") {
        self.host = host
        self.port = port
        self.user = user
        self.domain = domain
    }

    public func backendOptions(obscuredPassword: String? = nil) throws -> [String: String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("\\"), !host.contains("@"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains(":") || host.filter({ $0 == ":" }).count > 1 else {
            throw SMBConfigurationError.invalidHost
        }
        guard (1...65535).contains(port) else { throw SMBConfigurationError.invalidPort }
        guard !user.isEmpty else { throw SMBConfigurationError.missingUser }
        let domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        var options = ["type": "smb", "host": host, "port": String(port), "user": user,
                       "domain": domain.isEmpty ? "WORKGROUP" : domain]
        if let obscuredPassword, !obscuredPassword.isEmpty { options["pass"] = obscuredPassword }
        return options
    }

    public static func rootPath(share: String, subdirectory: String = "") throws -> String {
        let share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !share.isEmpty, !share.contains("/"), !share.contains("\\"),
              share != ".", share != ".." else { throw SMBConfigurationError.invalidShare }
        guard !subdirectory.contains("\\") else { throw SMBConfigurationError.invalidSubdirectory }
        let path = try FileProviderPath.normalize(subdirectory.trimmingCharacters(in: .whitespacesAndNewlines))
        return path.isEmpty ? share : "\(share)/\(path)"
    }
}

public enum SMBConfigurationError: LocalizedError, Sendable, Equatable {
    case invalidHost, invalidPort, missingUser, invalidShare, invalidSubdirectory

    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "Enter a server hostname or IP address without a URL, port, or share path."
        case .invalidPort: return "Enter a port between 1 and 65535."
        case .missingUser: return "Enter a username, or guest for a server that permits guest access."
        case .invalidShare: return "Enter one shared folder name without a path, such as Documents."
        case .invalidSubdirectory: return "Use forward slashes in the optional subfolder path."
        }
    }
}
