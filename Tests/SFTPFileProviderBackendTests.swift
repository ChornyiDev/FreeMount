import XCTest
@testable import FreeMount

final class SFTPFileProviderBackendTests: XCTestCase {

    // MARK: - SFTPConfiguration Tests

    func testDirectBackendOptionsWithKeyFile() {
        let config = SFTPConfiguration(
            host: "192.168.1.50",
            port: 2222,
            user: "root",
            authMode: .sshKey,
            keyPath: "~/.ssh/id_ed25519"
        )

        let options = config.backendOptions(secret: "mypassphrase")
        XCTAssertEqual(options["type"], "sftp")
        XCTAssertEqual(options["host"], "192.168.1.50")
        XCTAssertEqual(options["port"], "2222")
        XCTAssertEqual(options["user"], "root")
        XCTAssertTrue(options["key_file"]?.hasSuffix("/.ssh/id_ed25519") ?? false)
        XCTAssertEqual(options["key_file_pass"], "mypassphrase")
        XCTAssertNil(options["pass"])
        XCTAssertNil(options["ssh"])
    }

    func testDirectBackendOptionsWithPassword() {
        let config = SFTPConfiguration(
            host: "ftp.example.com",
            port: 22,
            user: "demo",
            authMode: .password
        )

        let options = config.backendOptions(secret: "secretPassword123")
        XCTAssertEqual(options["type"], "sftp")
        XCTAssertEqual(options["host"], "ftp.example.com")
        XCTAssertEqual(options["port"], "22")
        XCTAssertEqual(options["user"], "demo")
        XCTAssertEqual(options["pass"], "secretPassword123")
        XCTAssertNil(options["key_file"])
    }

    func testTunneledBackendOptionsWithCloudflare() {
        let tunnel = SSHTunnelConfiguration(type: .cloudflare)
        let config = SFTPConfiguration(
            host: "sshnew.chornyi.win",
            port: 22,
            user: "root",
            authMode: .sshKey,
            keyPath: "~/.ssh/id_ed25519",
            tunnel: tunnel
        )

        let options = config.backendOptions()
        XCTAssertEqual(options["type"], "sftp")
        XCTAssertNotNil(options["ssh"])
        XCTAssertTrue(options["ssh"]!.contains("-o \"ProxyCommand=cloudflared access ssh --hostname %h\""))
        XCTAssertTrue(options["ssh"]!.contains("root@sshnew.chornyi.win"))
        XCTAssertNil(options["host"]) // When using ssh, rclone expects all parameters inside the ssh command
    }

    // MARK: - SFTPConnectionHealthChecker Tests

    func testHealthCheckerClassifyAuthFailure() {
        let authErr = NSError(domain: "SFTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permission denied (publickey)"])
        let health = SFTPConnectionHealthChecker.classify(authErr)
        if case .authorizationRequired(let reason) = health {
            XCTAssertTrue(reason.contains("SFTP authentication failed"))
        } else {
            XCTFail("Expected authorizationRequired, got \(health)")
        }
    }

    func testHealthCheckerClassifyNetworkFailure() {
        let netErr = NSError(domain: "NSPOSIXErrorDomain", code: 61, userInfo: [NSLocalizedDescriptionKey: "Connection refused"])
        let health = SFTPConnectionHealthChecker.classify(netErr)
        if case .unavailable(let reason) = health {
            XCTAssertTrue(reason.contains("unreachable"))
        } else {
            XCTFail("Expected unavailable, got \(health)")
        }
    }

    // MARK: - SFTPFileProviderBackend Descriptor Tests

    func testRejectNonSFTPDescriptor() throws {
        let gdriveRemote = RemoteConfig(
            name: "Google Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "test-acc"
        )
        let descriptor = try FileProviderConnectionDescriptor(remote: gdriveRemote)

        XCTAssertThrowsError(try GenericRcloneFileProviderBackend.sftp(connection: descriptor)) { error in
            XCTAssertEqual(error as? FileProviderDomainError, .unsupportedProvider(.googleDrive))
        }
    }

    func testDomainDescriptorRecognizesSFTP() throws {
        let remote = RemoteConfig(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "My Server",
            provider: .sftp,
            bucketOrRootPath: "/var/www"
        )
        let domain = try FileProviderDomainDescriptor(remote: remote)
        XCTAssertEqual(domain.provider, .sftp)
        XCTAssertEqual(domain.domainIdentifier, "com.freemount.sftp.11111111-2222-3333-4444-555555555555")
    }
}
