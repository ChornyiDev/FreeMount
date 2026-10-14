import XCTest
@testable import FreeMount

private final class OAuthTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private final class OAuthTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
    var value: Int { lock.withLock { count } }
}

final class GoogleOAuthTokenServiceTests: XCTestCase {
    private let http = MockHTTPRouter()
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; http.configure(config)
        return URLSession(configuration: config)
    }
    private func authorization(expiry: Date? = nil, refresh: String? = "refresh", access: String = "old", client: String = "client") throws -> GoogleDriveAuthorization {
        struct Token: Encodable { let access_token: String; let refresh_token: String?; let expiry: String?; let scope = "original-scope" }
        let value = Token(access_token: access, refresh_token: refresh, expiry: expiry?.formatted(.iso8601))
        return GoogleDriveAuthorization(tokenJSON: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), client: try GoogleDriveOAuthClient(clientID: client, clientSecret: "secret+&="))
    }
    private func reply(_ request: URLRequest, _ body: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
    private func body(_ request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return String(decoding: data, as: UTF8.self)
    }
    override func tearDown() { http.handler = nil }

    func testExpiredTokenRefreshIsEncodedAndExportPreservesRefreshTokenAndScope() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        let original = try authorization(expiry: clock.now().addingTimeInterval(-1), refresh: "refresh+&= /?")
        http.handler = { request in
            _ = count.next()
            XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
            XCTAssertEqual(request.httpMethod, "POST")
            let encoded = self.body(request)
            // Decode form spaces before percent decoding, preserving literal %2B.
            let formQuery = encoded.replacingOccurrences(of: "+", with: "%20")
            let parameters = Dictionary(uniqueKeysWithValues: URLComponents(string: "?" + formQuery)!.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertTrue(encoded.contains("refresh_token=refresh%2B%26%3D+%2F%3F"))
            XCTAssertEqual(parameters["grant_type"], "refresh_token")
            XCTAssertEqual(parameters["refresh_token"], "refresh+&= /?")
            XCTAssertEqual(parameters["client_secret"], "secret+&=")
            return self.reply(request, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
        }
        let refreshed = try await service.authorization(for: original)
        struct Token: Decodable { let access_token: String; let refresh_token: String; let scope: String; let expiry: String }
        let token = try JSONDecoder().decode(Token.self, from: Data(refreshed.tokenJSON.utf8))
        XCTAssertEqual(token.access_token, "fresh")
        XCTAssertEqual(token.refresh_token, "refresh+&= /?")
        XCTAssertEqual(token.scope, "original-scope")
        let cached = try await service.accessToken(for: original)
        XCTAssertEqual(cached, "fresh")
        XCTAssertEqual(count.value, 1)
        XCTAssertGreaterThan(try Date.ISO8601FormatStyle().parse(token.expiry).timeIntervalSince(clock.now()), 3500)
    }

    func testConcurrentRequestsShareOneRefreshAndFreshRejectionDoesNotReuseOriginal() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        let original = try authorization(expiry: clock.now().addingTimeInterval(-1))
        http.handler = { request in
            let n = count.next(); Thread.sleep(forTimeInterval: 0.05)
            return self.reply(request, "{\"access_token\":\"fresh-\(n)\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
        }
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await service.accessToken(for: original) } }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(Set(values), ["fresh-1"])
        XCTAssertEqual(count.value, 1)
        let afterOldRejection = try await service.accessToken(for: original, rejectedAccessToken: "old")
        XCTAssertEqual(afterOldRejection, "fresh-1")
        XCTAssertEqual(count.value, 1)
        let afterFreshRejection = try await service.accessToken(for: original, rejectedAccessToken: "fresh-1")
        XCTAssertEqual(afterFreshRejection, "fresh-2")
        XCTAssertEqual(count.value, 2)
    }

    func testExpiryMarginAndRotatedRefreshToken() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        let original = try authorization(expiry: clock.now().addingTimeInterval(61))
        http.handler = { request in
            let n = count.next()
            if n == 2 { XCTAssertTrue(self.body(request).contains("refresh_token=rotated")) }
            return self.reply(request, "{\"access_token\":\"fresh-\(n)\",\"expires_in\":3600,\"token_type\":\"Bearer\",\"refresh_token\":\"rotated\"}")
        }
        let initial = try await service.accessToken(for: original)
        XCTAssertEqual(initial, "old")
        clock.advance(1)
        let first = try await service.accessToken(for: original)
        XCTAssertEqual(first, "fresh-1")
        clock.advance(3540)
        let second = try await service.accessToken(for: original)
        XCTAssertEqual(second, "fresh-2")
    }

    func testRevokedRefreshTokenAsksForAuthorizationWithoutLeakingResponse() async throws {
        let clock = OAuthTestClock()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        http.handler = { self.reply($0, "{\"error\":\"invalid_grant\",\"error_description\":\"super-secret\"}", status: 400) }
        do { _ = try await service.accessToken(for: authorization(expiry: clock.now())); XCTFail("Expected revocation") }
        catch {
            XCTAssertEqual(error as? GoogleDriveOAuthError, .authorizationRefreshRequired)
            XCTAssertFalse(error.localizedDescription.contains("super-secret"))
        }
    }

    func testAccountsWithSameBearerUseTheirOwnClientAndRefreshMaterial() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        http.handler = { request in
            let n = count.next()
            XCTAssertTrue(self.body(request).contains("client_id=client\(n)"))
            return self.reply(request, "{\"access_token\":\"fresh-\(n)\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
        }
        let first = try await service.accessToken(for: authorization(expiry: clock.now(), client: "client1"))
        let second = try await service.accessToken(for: authorization(expiry: clock.now(), client: "client2"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(count.value, 2)
    }

    func testDiscoveryRetries401OnceAndExportsFreshMaterial() async throws {
        let count = OAuthTestCounter(); let refreshCount = OAuthTestCounter()
        http.handler = { request in
            if request.url?.host == "oauth2.googleapis.com" {
                _ = refreshCount.next()
                return self.reply(request, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
            }
            let n = count.next()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), n == 1 ? "Bearer old" : "Bearer fresh")
            return self.reply(request, n == 1 ? "{}" : "{\"projects\":[]}", status: n == 1 ? 401 : 200)
        }
        let discovery = GoogleCloudDiscoveryService(session: session())
        let original = try authorization()
        _ = try await discovery.projects(authorization: .googleAccount(original))
        let current = try await discovery.refreshedAuthorization(.googleAccount(original))
        let credential = try current.credential(selection: GoogleCloudStorageSelection(directBucket: "test-bucket"), remoteName: "Bucket")
        struct ExportedToken: Decodable { let access_token: String; let refresh_token: String }
        let exported = try JSONDecoder().decode(ExportedToken.self, from: Data(credential.backendOptions["token"]!.utf8))
        XCTAssertEqual(exported.access_token, "fresh")
        XCTAssertEqual(exported.refresh_token, "refresh")
        XCTAssertEqual(count.value, 2)
        XCTAssertEqual(refreshCount.value, 1)
    }

    func testRepeated401StopsAnd403DoesNotRefresh() async throws {
        for status in [401, 403] {
            let requests = OAuthTestCounter(); let refreshes = OAuthTestCounter()
            http.handler = { request in
                if request.url?.host == "oauth2.googleapis.com" {
                    _ = refreshes.next()
                    return self.reply(request, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
                }
                _ = requests.next(); return self.reply(request, "{}", status: status)
            }
            let discovery = GoogleCloudDiscoveryService(session: session())
            do { _ = try await discovery.projects(authorization: .googleAccount(authorization())); XCTFail("Expected API failure") }
            catch { guard case .apiFailure(let code, _) = error as? GoogleCloudStorageError else { return XCTFail("\(error)") }; XCTAssertEqual(code, status) }
            XCTAssertEqual(requests.value, status == 401 ? 2 : 1)
            XCTAssertEqual(refreshes.value, status == 401 ? 1 : 0)
        }
    }
    func testCancelledWaiterDoesNotCancelSharedRefresh() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        let original = try authorization(expiry: clock.now())
        let started = expectation(description: "Refresh in flight")
        http.handler = { request in
            _ = count.next(); started.fulfill(); Thread.sleep(forTimeInterval: 0.2)
            return self.reply(request, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
        }
        let cancelled = Task { try await service.accessToken(for: original) }
        let other = Task { try await service.accessToken(for: original) }
        await fulfillment(of: [started], timeout: 3)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected caller cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let token = try await other.value
        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(count.value, 1)
    }

    func testInvalidRefreshResponseIsNotCachedAndMissingRefreshDoesNotSendRequest() async throws {
        let clock = OAuthTestClock(); let count = OAuthTestCounter()
        let service = GoogleOAuthTokenService(session: session(), now: { clock.now() })
        http.handler = { request in
            if count.next() == 1 { return self.reply(request, "{\"access_token\":\"\",\"expires_in\":3600,\"token_type\":\"Bearer\"}") }
            return self.reply(request, "{\"access_token\":\"fresh\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")
        }
        let original = try authorization(expiry: clock.now())
        do { _ = try await service.accessToken(for: original); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? GoogleDriveOAuthError, .tokenResponseInvalid) }
        let token = try await service.accessToken(for: original)
        XCTAssertEqual(token, "fresh")
        do { _ = try await service.accessToken(for: authorization(expiry: clock.now(), refresh: nil)); XCTFail("Expected missing refresh") }
        catch { XCTAssertEqual(error as? GoogleDriveOAuthError, .missingRefreshToken) }
        XCTAssertEqual(count.value, 2)
    }

    func testGoogleDriveOAuthConfigurationThrowsWhenUnconfigured() {
        // Without environment variables set, loadClient throws clientNotConfigured
        XCTAssertThrowsError(try GoogleDriveOAuthConfiguration.loadClient()) { error in
            XCTAssertEqual(error as? GoogleDriveOAuthError, .clientNotConfigured)
        }
    }
}

