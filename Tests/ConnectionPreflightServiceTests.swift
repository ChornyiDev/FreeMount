import XCTest
@testable import FreeMount

final class ConnectionPreflightServiceTests: XCTestCase {

    func testDigestOnlyChallengeRejectsAnonymousListingWithoutSendingSecrets() async {
        let http = MockHTTPRouter()
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let session = URLSession(configuration: configuration)
        http.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil,
                headerFields: ["WWW-Authenticate": "Digest realm=\"WebDAV\", qop=\"auth\""])!, Data())
        }
        let client = RcloneClient(port: 5572, urlSession: session, credentialProvider: testRPCCredentialProvider)
        let result = await ConnectionPreflightService(challengeSession: session).verify(client: client,
            backendOptions: ["type": "webdav", "url": "https://dav.example.com/", "pass": "secret"])
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.message.contains("Digest authentication"))
        XCTAssertTrue(result.message.contains("cannot be saved yet"))
        XCTAssertTrue(result.message.contains("official rclone release"))
        let state = ConnectionVerificationState.failed(message: result.message)
        XCTAssertFalse(state.isVerified)
    }

    func testBasicChallengeContinuesThroughAuthenticatedRcloneListing() async {
        let http = MockHTTPRouter()
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        let session = URLSession(configuration: configuration)
        http.handler = { request in
            if request.httpMethod == "HEAD" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil,
                    headerFields: ["WWW-Authenticate": "Basic realm=\"WebDAV\""])!, Data())
            }
            XCTAssertEqual(request.url?.path, "/operations/list")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: nil)!, Data("{\"list\":[]}".utf8))
        }
        let client = RcloneClient(port: 5572, urlSession: session, credentialProvider: testRPCCredentialProvider)
        let result = await ConnectionPreflightService(challengeSession: session).verify(client: client,
            backendOptions: ["type": "webdav", "url": "https://dav.example.com/"])
        XCTAssertTrue(result.isSuccess)
    }

    // MARK: - State Transitions

    func testVerificationStateTransitions() {
        let untested = ConnectionVerificationState.untested
        XCTAssertFalse(untested.isVerified)
        XCTAssertFalse(untested.isTesting)
        XCTAssertNil(untested.verifiedMessage)
        XCTAssertNil(untested.failureMessage)

        let testing = ConnectionVerificationState.testing
        XCTAssertFalse(testing.isVerified)
        XCTAssertTrue(testing.isTesting)
        XCTAssertNil(testing.verifiedMessage)
        XCTAssertNil(testing.failureMessage)

        let verified = ConnectionVerificationState.verified(message: "Connected (12ms)")
        XCTAssertTrue(verified.isVerified)
        XCTAssertFalse(verified.isTesting)
        XCTAssertEqual(verified.verifiedMessage, "Connected (12ms)")
        XCTAssertNil(verified.failureMessage)

        let failed = ConnectionVerificationState.failed(message: "Auth failed")
        XCTAssertFalse(failed.isVerified)
        XCTAssertFalse(failed.isTesting)
        XCTAssertNil(failed.verifiedMessage)
        XCTAssertEqual(failed.failureMessage, "Auth failed")
    }

    // MARK: - Error Classification Tests

    func testClassifyAuthenticationFailure() {
        let error = FreeMountError.rcloneError(statusCode: 401, message: "failed to make client: 401 Unauthorized")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "webdav"])
        XCTAssertTrue(message.contains("Authentication failed (401)"))
    }

    func testClassifyForbiddenAccess() {
        let error = FreeMountError.rcloneError(statusCode: 403, message: "403 Forbidden: access denied")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "webdav"])
        XCTAssertTrue(message.contains("Access forbidden (403)"))
    }

    func testClassifySSLCertificateFailure() {
        let error = FreeMountError.rcloneError(statusCode: 500, message: "x509: certificate signed by unknown authority")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "webdav"])
        XCTAssertTrue(message.contains("SSL/TLS certificate verification failed"))
        XCTAssertTrue(message.contains("Allow untrusted"))
    }

    func testClassifyNotFoundDirectory() {
        let error = FreeMountError.rcloneError(statusCode: 404, message: "directory not found: /documents")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "webdav"])
        XCTAssertTrue(message.contains("Remote path not found (404)"))
    }

    func testClassifyConnectionRefusedWithPort() {
        let error = FreeMountError.rcloneError(statusCode: 500, message: "dial tcp 192.168.1.50:22: connect: connection refused")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "sftp", "port": "22"])
        XCTAssertTrue(message.contains("Connection refused on port 22"))
    }

    func testClassifyHostNotFound() {
        let error = FreeMountError.rcloneError(statusCode: 500, message: "dial tcp: lookup nonexistinghost.example.com: no such host")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "webdav"])
        XCTAssertTrue(message.contains("Host not found"))
    }

    func testClassifyTimeout() {
        let error = FreeMountError.networkTimeout(operation: "operations/list")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "sftp"])
        XCTAssertTrue(message.contains("Connection timed out"))
    }
}
