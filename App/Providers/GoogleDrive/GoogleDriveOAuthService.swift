import AppKit
import CryptoKit
import Foundation
import Network

/// Performs a Google OAuth 2.0 desktop authorization-code flow with PKCE.
/// The browser callback is accepted only on a short-lived IPv4 loopback listener.
public final class GoogleDriveOAuthService: @unchecked Sendable {
    private let urlSession: URLSession
    private let browserOpener: @Sendable (URL) -> Bool
    private let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private let scope: String

    public init(
        urlSession: URLSession = .shared,
        scopes: [String] = ["https://www.googleapis.com/auth/drive"],
        browserOpener: @escaping @Sendable (URL) -> Bool = { url in NSWorkspace.shared.open(url) }
    ) {
        self.urlSession = urlSession
        self.scope = scopes.joined(separator: " ")
        self.browserOpener = browserOpener
    }

    public func authorize(client: GoogleDriveOAuthClient) async throws -> GoogleDriveAuthorization {
        let state = randomURLSafeString(byteCount: 32)
        let verifier = randomURLSafeString(byteCount: 48)
        let challenge = codeChallenge(for: verifier)
        let callback = try await receiveCallback(
            state: state,
            client: client,
            verifier: verifier,
            challenge: challenge
        )
        let token = try await exchange(code: callback.code, callbackURL: callback.redirectURL, client: client, verifier: verifier)
        return GoogleDriveAuthorization(tokenJSON: token.rcloneJSON, client: client)
    }

    private func receiveCallback(
        state: String,
        client: GoogleDriveOAuthClient,
        verifier: String,
        challenge: String
    ) async throws -> OAuthCallback {
        let listener = try makeListener()
        defer { listener.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let completion = OAuthCallbackCompletion(continuation: continuation)

            listener.stateUpdateHandler = { stateUpdate in
                switch stateUpdate {
                case .ready:
                    guard let port = listener.port else {
                        completion.finish(.failure(GoogleDriveOAuthError.callbackListenerFailed))
                        return
                    }
                    let redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2/callback")!
                    let authorizationURL = self.makeAuthorizationURL(
                        clientID: client.clientID,
                        redirectURL: redirectURL,
                        state: state,
                        challenge: challenge
                    )
                    guard self.browserOpener(authorizationURL) else {
                        completion.finish(.failure(GoogleDriveOAuthError.authorizationDenied))
                        return
                    }
                case .failed:
                    completion.finish(.failure(GoogleDriveOAuthError.callbackListenerFailed))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                guard let port = listener.port else {
                    completion.finish(.failure(GoogleDriveOAuthError.callbackListenerFailed))
                    return
                }
                let redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2/callback")!
                self.readCallback(connection, redirectURL: redirectURL) { result in
                    switch result {
                    case .success(let callback):
                        self.writeBrowserResponse(to: connection, title: "Authorization received", message: "Return to FreeMount while it completes the secure token exchange.")
                        guard callback.state == state else {
                            completion.finish(.failure(GoogleDriveOAuthError.stateMismatch))
                            return
                        }
                        guard callback.error == nil else {
                            completion.finish(.failure(GoogleDriveOAuthError.authorizationDenied))
                            return
                        }
                        guard callback.code != nil else {
                            completion.finish(.failure(GoogleDriveOAuthError.missingAuthorizationCode))
                            return
                        }
                        completion.finish(.success(callback))
                    case .failure(let error):
                        self.writeBrowserResponse(to: connection, title: "Authorization failed", message: "Return to FreeMount and try again.")
                        completion.finish(.failure(error))
                    }
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func makeListener() throws -> NWListener {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return try NWListener(using: parameters, on: .any)
        } catch {
            throw GoogleDriveOAuthError.callbackListenerFailed
        }
    }

    private func makeAuthorizationURL(clientID: String, redirectURL: URL, state: String, challenge: String) -> URL {
        var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components.url!
    }

    private func exchange(code: String?, callbackURL: URL, client: GoogleDriveOAuthClient, verifier: String) async throws -> GoogleTokenResponse {
        guard let code else { throw GoogleDriveOAuthError.missingAuthorizationCode }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        var items = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: client.clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: verifier)
        ]
        if let clientSecret = client.clientSecret {
            items.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        request.httpBody = OAuthFormEncoder.encode(items).data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw FreeMountError.networkTimeout(operation: "Google Drive token exchange")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveOAuthError.tokenResponseInvalid
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorResponse = try? JSONDecoder().decode(GoogleTokenErrorResponse.self, from: data)
            throw GoogleDriveOAuthError.tokenExchangeFailed(
                statusCode: httpResponse.statusCode,
                reason: errorResponse?.error
            )
        }
        guard let token = try? JSONDecoder().decode(GoogleTokenResponse.self, from: data) else {
            throw GoogleDriveOAuthError.tokenResponseInvalid
        }
        guard token.refreshToken != nil else { throw GoogleDriveOAuthError.missingRefreshToken }
        return token
    }

    private func readCallback(
        _ connection: NWConnection,
        redirectURL: URL,
        completion: @escaping @Sendable (Result<OAuthCallback, Error>) -> Void
    ) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
            guard error == nil, let data, let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n", maxSplits: 1).first,
                  let path = requestLine.split(separator: " ").dropFirst().first,
                  let url = URL(string: "http://127.0.0.1\(path)"),
                  url.path == "/oauth2/callback",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                completion(.failure(GoogleDriveOAuthError.invalidCallback))
                return
            }
            let queryItems = components.queryItems ?? []
            let state = queryItems.first(where: { $0.name == "state" })?.value
            let code = queryItems.first(where: { $0.name == "code" })?.value
            let authorizationError = queryItems.first(where: { $0.name == "error" })?.value
            guard let state else {
                completion(.failure(GoogleDriveOAuthError.invalidCallback))
                return
            }
            completion(.success(OAuthCallback(code: code, error: authorizationError, state: state, redirectURL: redirectURL)))
        }
    }

    private func writeBrowserResponse(to connection: NWConnection, title: String, message: String) {
        let body = "<html><head><meta charset=\"utf-8\"></head><body><h2>\(title)</h2><p>\(message)</p></body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct OAuthCallback: Sendable {
    let code: String?
    let error: String?
    let state: String
    let redirectURL: URL
}

private final class OAuthCallbackCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFinished = false
    private let continuation: CheckedContinuation<OAuthCallback, Error>

    init(continuation: CheckedContinuation<OAuthCallback, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<OAuthCallback, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished else { return }
        hasFinished = true
        continuation.resume(with: result)
    }
}

private struct GoogleTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int?
    let refreshToken: String?
    let scope: String?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
    }

    var rcloneJSON: String {
        var values: [String: String] = ["access_token": accessToken]
        if let refreshToken { values["refresh_token"] = refreshToken }
        if let scope { values["scope"] = scope }
        if let tokenType { values["token_type"] = tokenType }
        if let expiresIn {
            values["expiry"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(expiresIn)))
        }
        let data = (try? JSONEncoder().encode(values)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct GoogleTokenErrorResponse: Decodable, Sendable {
    let error: String?
}

/// Correct encoder for an OAuth `application/x-www-form-urlencoded` body.
/// `URLComponents` encodes a URL query, which has subtly different rules.
enum OAuthFormEncoder {
    static func encode(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let value = item.value ?? ""
            return "\(encodeComponent(item.name))=\(encodeComponent(value))"
        }
            .joined(separator: "&")
    }

    private static func encodeComponent(_ value: String) -> String {
        value.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                return String(UnicodeScalar(byte))
            case 0x20:
                return "+"
            default:
                return String(format: "%%%02X", byte)
            }
        }
        .joined()
    }
}
