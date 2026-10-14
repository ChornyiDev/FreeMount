import Foundation

public enum FTPSecurity: String, Codable, Sendable, CaseIterable {
    case plain, explicitTLS, implicitTLS
    public var displayName: String {
        switch self {
        case .plain: return "FTP"
        case .explicitTLS: return "FTPS Explicit"
        case .implicitTLS: return "FTPS Implicit"
        }
    }
    public var defaultPort: Int { self == .implicitTLS ? 990 : 21 }
}

/// Non-secret FTP endpoint and security settings; passwords belong to Keychain.
public struct FTPConfiguration: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var security: FTPSecurity
    public var noCheckCertificate: Bool

    public init(host: String, port: Int = 21, user: String, security: FTPSecurity = .plain,
                noCheckCertificate: Bool = false) {
        self.host = host
        self.port = port
        self.user = user
        self.security = security
        self.noCheckCertificate = noCheckCertificate
    }

    public func backendOptions(obscuredPassword: String? = nil) throws -> [String: String] {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("/"), !host.contains("\\"), !host.contains("@"),
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains(":") || host.filter({ $0 == ":" }).count > 1 else {
            throw FreeMountError.invalidConfiguration(reason: "Enter a server hostname or IP without a URL, port, or path.")
        }
        guard (1...65535).contains(port), !user.isEmpty else {
            throw FreeMountError.invalidConfiguration(reason: "Enter a valid port and username, or choose Anonymous.")
        }
        var options = ["type": "ftp", "host": host, "port": String(port), "user": user,
            "tls": String(security == .implicitTLS), "explicit_tls": String(security == .explicitTLS),
            "no_check_certificate": String(security != .plain && noCheckCertificate)]
        if let obscuredPassword, !obscuredPassword.isEmpty { options["pass"] = obscuredPassword }
        return options
    }

    public static func rootPath(_ input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = try FileProviderPath.normalize(input)
        return input.hasPrefix("/") ? "/" + normalized : normalized
    }
}
