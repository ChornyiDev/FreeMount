import Foundation

/// In-memory refresh for Google API metadata requests; secrets are persisted only
/// by the caller's existing Keychain save/replace flow.
public actor GoogleOAuthTokenService {
    private struct Key: Hashable {
        let tokenJSON: String
        let clientID: String
        let clientSecret: String?
        init(_ authorization: GoogleDriveAuthorization) {
            tokenJSON = authorization.tokenJSON
            clientID = authorization.client.clientID
            clientSecret = authorization.client.clientSecret
        }
    }
    private struct StoredToken: Codable, Sendable {
        var access_token: String
        var refresh_token: String?
        var expiry: String?
        var token_type: String?
        var scope: String?
    }
    private struct RefreshResponse: Decodable, Sendable {
        let access_token: String
        let expires_in: Int
        let token_type: String
        let refresh_token: String?
        let scope: String?
    }
    private struct ErrorResponse: Decodable { let error: String? }
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cache: [Key: GoogleDriveAuthorization] = [:]
    private var refreshing: [Key: Task<GoogleDriveAuthorization, Error>] = [:]

    public init(session: URLSession? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        self.now = now
    }

    public func authorization(for original: GoogleDriveAuthorization, rejectedAccessToken: String? = nil) async throws -> GoogleDriveAuthorization {
        try Task.checkCancellation()
        let key = Key(original)
        if let pending = refreshing[key] {
            let result = try await pending.value
            try Task.checkCancellation()
            return result
        }
        let current = cache[key] ?? original
        let token = try Self.decode(current)
        let rejected = rejectedAccessToken == token.access_token
        if !rejected, Self.isUsable(token, at: now()) { return current }
        guard let refresh = token.refresh_token, !refresh.isEmpty else { throw GoogleDriveOAuthError.missingRefreshToken }
        // A caller's cancellation must not cancel a refresh shared by another
        // request. Each caller checks cancellation after the shared result.
        let task = Task { [session, now] in
            try await Self.exchange(token: token, refresh: refresh, client: current.client, session: session, now: now)
        }
        refreshing[key] = task
        do {
            let result = try await task.value
            cache[key] = result
            refreshing[key] = nil
            try Task.checkCancellation()
            return result
        } catch {
            refreshing[key] = nil
            throw error
        }
    }

    public func accessToken(for authorization: GoogleDriveAuthorization, rejectedAccessToken: String? = nil) async throws -> String {
        let current = try await self.authorization(for: authorization, rejectedAccessToken: rejectedAccessToken)
        return try Self.decode(current).access_token
    }

    private static func decode(_ authorization: GoogleDriveAuthorization) throws -> StoredToken {
        guard let token = try? JSONDecoder().decode(StoredToken.self, from: Data(authorization.tokenJSON.utf8)), !token.access_token.isEmpty else {
            throw GoogleDriveOAuthError.tokenResponseInvalid
        }
        return token
    }
    private static func isUsable(_ token: StoredToken, at date: Date) -> Bool {
        // Legacy tokens without expiry can be tried once; a 401 forces refresh.
        guard let expiry = token.expiry else { return true }
        let parsed = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(expiry))
            ?? (try? Date.ISO8601FormatStyle().parse(expiry))
        guard let parsed else { return false }
        return parsed.timeIntervalSince(date) > 60
    }

    private static func exchange(token: StoredToken, refresh: String, client: GoogleDriveOAuthClient, session: URLSession, now: @Sendable () -> Date) async throws -> GoogleDriveAuthorization {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let parameters = [("grant_type", "refresh_token"), ("client_id", client.clientID), ("refresh_token", refresh)]
            + (client.clientSecret.map { [("client_secret", $0)] } ?? [])
        request.httpBody = Data(OAuthFormEncoder.encode(parameters.map { URLQueryItem(name: $0.0, value: $0.1) }).utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleDriveOAuthError.tokenResponseInvalid }
        guard http.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
            if code == "invalid_grant" { throw GoogleDriveOAuthError.authorizationRefreshRequired }
            // Never echo server error bodies or arbitrary reason strings containing secrets.
            let reason = ["invalid_client", "unauthorized_client", "temporarily_unavailable"].contains(code ?? "") ? code : nil
            throw GoogleDriveOAuthError.tokenExchangeFailed(statusCode: http.statusCode, reason: reason)
        }
        guard let response = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !response.access_token.isEmpty, response.expires_in > 0,
              response.token_type.lowercased() == "bearer",
              response.refresh_token == nil || response.refresh_token?.isEmpty == false else { throw GoogleDriveOAuthError.tokenResponseInvalid }
        var updated = token
        updated.access_token = response.access_token
        updated.refresh_token = response.refresh_token ?? token.refresh_token
        updated.scope = response.scope ?? token.scope
        updated.token_type = response.token_type
        updated.expiry = now().addingTimeInterval(TimeInterval(response.expires_in)).formatted(.iso8601)
        let json = String(decoding: try JSONEncoder().encode(updated), as: UTF8.self)
        return GoogleDriveAuthorization(tokenJSON: json, client: client)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
