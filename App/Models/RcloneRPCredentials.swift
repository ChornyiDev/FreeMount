import Foundation
import Security
import CryptoKit

public enum RcloneRPCAuthenticationError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential
    case invalidCredential
    case keychain(OSStatus)
    case missingAccessGroup
    case randomGeneration(OSStatus)
    case unprotectedEndpoint
    case authenticationRejected
    case nonLoopbackEndpoint

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "The local rclone credential is unavailable. Open FreeMount to initialize it."
        case .invalidCredential: return "The local rclone credential is invalid. It was not replaced automatically."
        case .keychain(let status): return "Could not access the protected local rclone credential (Keychain status \(status))."
        case .missingAccessGroup: return "The shared Keychain access group is missing from this build."
        case .randomGeneration(let status): return "Could not generate the local rclone credential (status \(status))."
        case .unprotectedEndpoint: return "The local rclone endpoint does not require authentication. Stop the old daemon or restart macOS, then reopen FreeMount."
        case .authenticationRejected: return "The local rclone endpoint rejected FreeMount's credential."
        case .nonLoopbackEndpoint: return "Local rclone credentials can only be sent to the configured 127.0.0.1 HTTP endpoint."
        }
    }
}

/// Opaque installation credential; string/debug output must never expose it.
public struct RcloneRPCredentials: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    private let password: String
    public init(password: String) throws {
        guard password.utf8.count == 64, password.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RcloneRPCAuthenticationError.invalidCredential
        }
        self.password = password
    }
    static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw RcloneRPCAuthenticationError.randomGeneration(status) }
        return try Self(password: bytes.map { String(format: "%02x", $0) }.joined())
    }
    var authorizationHeader: String { "Basic " + Data("freemount:\(password)".utf8).base64EncodedString() }
    /// Apache SHA verifier of a 256-bit random password, never the password itself.
    /// SHA1 is used only for rclone htpasswd compatibility, not user passwords.
    var htpasswdData: Data {
        let verifier = Data(Insecure.SHA1.hash(data: Data(password.utf8))).base64EncodedString()
        return Data("freemount:{SHA}\(verifier)\n".utf8)
    }
    func validated() throws -> Self { try Self(password: password) }
    public var description: String { "RcloneRPCredentials(<redacted>)" }
    public var debugDescription: String { description }
}
