import XCTest
@testable import FreeMount

final class WebDAVFileProviderBackendTests: XCTestCase {

    // MARK: - Backend Options Tests

    func testNextcloudBackendOptions() {
        let config = WebDAVConfiguration(
            url: "https://cloud.example.com/remote.php/dav/files/alice/",
            vendor: .nextcloud,
            user: "alice",
            authMode: .password,
            insecureSkipVerify: false
        )

        let options = config.backendOptions(secret: "app-password-123")
        XCTAssertEqual(options["type"], "webdav")
        XCTAssertEqual(options["url"], "https://cloud.example.com/remote.php/dav/files/alice/")
        XCTAssertEqual(options["vendor"], "nextcloud")
        XCTAssertEqual(options["user"], "alice")
        XCTAssertEqual(options["pass"], "app-password-123")
        XCTAssertNil(options["insecure_skip_verify"])
        XCTAssertNil(options["bearer_token"])
    }

    func testGenericBackendOptionsWithInsecureTLS() {
        let config = WebDAVConfiguration(
            url: "https://nas.local:5006",
            vendor: .generic,
            user: "admin",
            authMode: .password,
            insecureSkipVerify: true
        )

        let options = config.backendOptions(secret: "nas-secret")
        XCTAssertEqual(options["type"], "webdav")
        XCTAssertEqual(options["url"], "https://nas.local:5006")
        XCTAssertEqual(options["vendor"], "other")
        XCTAssertEqual(options["user"], "admin")
        XCTAssertEqual(options["pass"], "nas-secret")
        XCTAssertEqual(options["insecure_skip_verify"], "true")
    }

    func testBearerTokenAuthentication() {
        let config = WebDAVConfiguration(
            url: "https://dav.box.com/dav",
            vendor: .generic,
            user: "left-over-password-user",
            authMode: .bearerToken,
            insecureSkipVerify: false
        )

        let options = config.backendOptions(secret: "oauth2-token-xyz")
        XCTAssertEqual(options["type"], "webdav")
        XCTAssertEqual(options["vendor"], "other")
        XCTAssertNil(options["user"])
        XCTAssertNil(options["pass"])
        XCTAssertEqual(options["bearer_token"], "oauth2-token-xyz")
    }

    // MARK: - Health Classification Tests

    func testHealthCheckerClassifyAuthFailure() {
        struct MockError: LocalizedError {
            var errorDescription: String? { "HTTP 401 Unauthorized" }
        }

        let health = WebDAVConnectionHealthChecker.classify(MockError())
        if case .authorizationRequired(let reason) = health {
            XCTAssertTrue(reason.contains("authentication failed"))
        } else {
            XCTFail("Expected authorizationRequired, got \(health)")
        }
    }

    func testHealthCheckerClassifyNetworkFailure() {
        struct MockError: LocalizedError {
            var errorDescription: String? { "connection refused to host 192.168.1.50:5005" }
        }

        let health = WebDAVConnectionHealthChecker.classify(MockError())
        if case .unavailable(let reason) = health {
            XCTAssertTrue(reason.contains("unreachable"))
        } else {
            XCTFail("Expected unavailable, got \(health)")
        }
    }

    // MARK: - Descriptor Tests

    func testRejectNonWebDAVDescriptor() throws {
        let gdriveRemote = RemoteConfig(
            name: "Google Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "test-acc"
        )
        let descriptor = try FileProviderConnectionDescriptor(remote: gdriveRemote)

        XCTAssertThrowsError(try GenericRcloneFileProviderBackend.webdav(connection: descriptor)) { error in
            XCTAssertEqual(error as? FileProviderDomainError, .unsupportedProvider(.googleDrive))
        }
    }

    func testDomainDescriptorRecognizesWebDAV() throws {
        let remote = RemoteConfig(
            id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            name: "Nextcloud",
            provider: .webdav,
            bucketOrRootPath: ""
        )
        let domain = try FileProviderDomainDescriptor(remote: remote)
        XCTAssertEqual(domain.provider, .webdav)
        XCTAssertEqual(domain.domainIdentifier, "com.freemount.webdav.22222222-3333-4444-5555-666666666666")
    }
}
