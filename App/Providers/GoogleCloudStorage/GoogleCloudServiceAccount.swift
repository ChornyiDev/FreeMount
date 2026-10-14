import Foundation
import Security

public enum GoogleCloudAuthenticationMode: String, Codable, Sendable, CaseIterable {
    case googleAccount
    case serviceAccount
}

/// Non-secret identity metadata; imported key material belongs only in Keychain.
public struct GoogleCloudAuthenticationIdentity: Codable, Sendable, Equatable {
    public let mode: GoogleCloudAuthenticationMode
    public let email: String?
}

public enum GoogleCloudServiceAccountError: LocalizedError, Sendable, Equatable {
    case invalidJSON
    case invalidKey
    case unsupportedEndpoint
    case fileTooLarge
    case unreadableFile
    case tokenRejected(Int)
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "Choose a Google Service Account JSON key containing its project ID, email, key ID, and private key."
        case .invalidKey: return "The Service Account private key is invalid. Export a new JSON key from Google Cloud."
        case .unsupportedEndpoint: return "This key does not use the supported Google Cloud token endpoint."
        case .unreadableFile: return "The selected JSON key could not be read. Choose the file again."
        case .fileTooLarge: return "The selected file is too large to be a Service Account JSON key."
        case .tokenRejected(let status):
            if status == 429 { return "Google token quota was exceeded. Try again later." }
            if status >= 500 { return "Google authorization is temporarily unavailable. Try again later." }
            return "Google rejected the Service Account key (HTTP \(status)). Check that the key and account are active and your Mac's clock is correct."
        case .invalidTokenResponse: return "Google returned an invalid Service Account token response. Try replacing the key."
        }
    }
}

/// Validated key material. No source path or arbitrary JSON fields are retained.
public struct GoogleCloudServiceAccountKey: Sendable, Equatable {
    public static let maximumFileSize = 64 * 1024
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    public let projectID: String
    public let email: String
    private let payload: Payload

    public init(data: Data) throws {
        guard data.count <= Self.maximumFileSize else { throw GoogleCloudServiceAccountError.fileTooLarge }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.type == "service_account",
              !payload.project_id.isEmpty,
              payload.client_email.hasSuffix(".gserviceaccount.com"),
              payload.client_email.contains("@"),
              !payload.private_key_id.isEmpty else { throw GoogleCloudServiceAccountError.invalidJSON }
        guard payload.token_uri == Self.tokenEndpoint,
              payload.universe_domain == nil || payload.universe_domain == "googleapis.com" else {
            throw GoogleCloudServiceAccountError.unsupportedEndpoint
        }
        self.payload = payload
        projectID = payload.project_id
        email = payload.client_email
        _ = try signingKey()
    }

    public static func importFile(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else {
            throw GoogleCloudServiceAccountError.unreadableFile
        }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: maximumFileSize + 1) ?? Data() }
        catch { throw GoogleCloudServiceAccountError.unreadableFile }
        return try Self(data: data)
    }

    public func json() throws -> String {
        String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }

    /// RS256 uses Security.framework; no private key is imported into a keychain.
    func assertion(at date: Date, scopes: [String]) throws -> String {
        struct Header: Encodable { let alg = "RS256"; let typ = "JWT"; let kid: String }
        struct Claims: Encodable { let iss: String; let scope: String; let aud: String; let iat: Int; let exp: Int }
        let issued = Int(date.timeIntervalSince1970)
        let encoder = JSONEncoder()
        let header = try encoder.encode(Header(kid: payload.private_key_id)).base64URL
        let claims = try encoder.encode(Claims(iss: email, scope: scopes.joined(separator: " "), aud: Self.tokenEndpoint, iat: issued, exp: issued + 3600)).base64URL
        let input = "\(header).\(claims)"
        let key = try signingKey()
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data? else {
            throw GoogleCloudServiceAccountError.invalidKey
        }
        return "\(input).\(signature.base64URL)"
    }

    private func signingKey() throws -> SecKey {
        guard payload.private_key.hasPrefix("-----BEGIN PRIVATE KEY-----"),
              payload.private_key.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("-----END PRIVATE KEY-----") else {
            throw GoogleCloudServiceAccountError.invalidKey
        }
        var format = SecExternalFormat.formatUnknown
        var type = SecExternalItemType.itemTypePrivateKey
        var items: CFArray?
        let status = SecItemImport(Data(payload.private_key.utf8) as CFData, nil, &format, &type, [], nil, nil, &items)
        guard status == errSecSuccess, let keys = items as? [SecKey], keys.count == 1,
              SecKeyIsAlgorithmSupported(keys[0], .sign, .rsaSignatureMessagePKCS1v15SHA256) else {
            throw GoogleCloudServiceAccountError.invalidKey
        }
        return keys[0]
    }

    private struct Payload: Codable, Sendable, Equatable {
        let type: String
        let project_id: String
        let private_key_id: String
        let private_key: String
        let client_email: String
        let client_id: String?
        let token_uri: String
        let universe_domain: String?
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Ephemeral bearer tokens are refreshed on demand and never persisted.
public actor GoogleCloudServiceAccountTokenService {
    private let session: URLSession
    private var cachedKey: GoogleCloudServiceAccountKey?
    private var cachedToken: String?
    private var expiresAt = Date.distantPast

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func accessToken(for key: GoogleCloudServiceAccountKey) async throws -> String {
        try Task.checkCancellation()
        if cachedKey == key, let cachedToken, expiresAt.timeIntervalSinceNow > 60 { return cachedToken }
        let assertion = try key.assertion(at: Date(), scopes: GoogleCloudDiscoveryService.oauthScopes)
        var request = URLRequest(url: URL(string: GoogleCloudServiceAccountKey.tokenEndpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Base64url has no form-reserved characters; grant type is a fixed constant.
        request.httpBody = Data("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)".utf8)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GoogleCloudServiceAccountError.invalidTokenResponse }
        guard http.statusCode == 200 else { throw GoogleCloudServiceAccountError.tokenRejected(http.statusCode) }
        guard let token = try? JSONDecoder().decode(Token.self, from: data),
              !token.access_token.isEmpty, token.token_type.lowercased() == "bearer", token.expires_in > 0 else {
            throw GoogleCloudServiceAccountError.invalidTokenResponse
        }
        cachedKey = key
        cachedToken = token.access_token
        expiresAt = Date().addingTimeInterval(TimeInterval(token.expires_in))
        return token.access_token
    }

    private struct Token: Decodable { let access_token: String; let token_type: String; let expires_in: Int }
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

public enum GoogleCloudAuthorization: Sendable, Equatable {
    case googleAccount(GoogleDriveAuthorization)
    case serviceAccount(GoogleCloudServiceAccountKey)

    public var identity: GoogleCloudAuthenticationIdentity {
        switch self {
        case .googleAccount: return GoogleCloudAuthenticationIdentity(mode: .googleAccount, email: nil)
        case .serviceAccount(let key): return GoogleCloudAuthenticationIdentity(mode: .serviceAccount, email: key.email)
        }
    }

    public func credential(selection: GoogleCloudStorageSelection, remoteName: String) throws -> RcloneRemoteCredential {
        switch self {
        case .googleAccount(let authorization): return selection.credential(authorization: authorization, remoteName: remoteName)
        case .serviceAccount(let key):
            var options = selection.backendOptions
            options["service_account_credentials"] = try key.json()
            return RcloneRemoteCredential(remoteName: remoteName, provider: .googleCloudStorage, backendOptions: options)
        }
    }
}
