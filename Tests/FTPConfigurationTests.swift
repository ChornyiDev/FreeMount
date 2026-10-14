import XCTest
@testable import FreeMount

final class FTPConfigurationTests: XCTestCase {
    func testTLSModesAreExclusiveAndPortsMatch() throws {
        for mode in FTPSecurity.allCases {
            let options = try FTPConfiguration(host: " ftp.local ", port: mode.defaultPort,
                user: " alice ", security: mode).backendOptions(obscuredPassword: "obscured-fixture")
            XCTAssertEqual(options["host"], "ftp.local")
            XCTAssertEqual(options["user"], "alice")
            XCTAssertEqual(options["tls"], String(mode == .implicitTLS))
            XCTAssertEqual(options["explicit_tls"], String(mode == .explicitTLS))
            XCTAssertEqual(options["no_check_certificate"], "false")
            XCTAssertEqual(options["port"], mode == .implicitTLS ? "990" : "21")
        }
        let plain = try FTPConfiguration(host: "ftp.local", user: "anonymous", noCheckCertificate: true).backendOptions()
        XCTAssertEqual(plain["no_check_certificate"], "false")
        XCTAssertNil(plain["pass"])
        let tls = try FTPConfiguration(host: "ftp.local", user: "alice", security: .explicitTLS,
            noCheckCertificate: true).backendOptions()
        XCTAssertEqual(tls["no_check_certificate"], "true")
    }

    func testInvalidEndpointAndTraversalRejected() throws {
        for host in ["", "ftp://server", "server/path", "server:21", "user@server", "server name"] {
            XCTAssertThrowsError(try FTPConfiguration(host: host, user: "alice").backendOptions())
        }
        XCTAssertThrowsError(try FTPConfiguration(host: "server", port: 0, user: "alice").backendOptions())
        XCTAssertThrowsError(try FTPConfiguration(host: "server", user: "").backendOptions())
        XCTAssertThrowsError(try FTPConfiguration.rootPath("folder/../secret"))
    }

    func testHomeRelativeAndAbsoluteRootsSurviveDescriptorAndCredential() throws {
        for (input, expected) in [("", ""), ("folder/sub", "folder/sub"), ("/", "/"), ("/srv/files/", "/srv/files")] {
            XCTAssertEqual(try FTPConfiguration.rootPath(input), expected)
            let remote = RemoteConfig(name: "FTP fixture", provider: .ftp, bucketOrRootPath: input,
                keychainAccountKey: "fixture", ftpConfiguration: FTPConfiguration(host: "localhost", user: "anonymous"))
            let decoded = try JSONDecoder().decode(RemoteConfig.self, from: JSONEncoder().encode(remote))
            XCTAssertEqual(remote, decoded)
            XCTAssertEqual(try FileProviderConnectionDescriptor(remote: decoded).rootPath, expected)
            let credential = RcloneRemoteCredential(remoteName: "FTP fixture", provider: .ftp,
                backendOptions: ["type": "ftp"])
            XCTAssertEqual(credential.fileSystemReference(root: expected), .configuration(["type": "ftp", "_root": expected]))
        }
    }

    func testFTPLoginFailureUsesProtocolMessage() {
        let error = FreeMountError.rcloneError(statusCode: 500, message: "530 Login incorrect")
        XCTAssertTrue(ConnectionPreflightService.classify(error: error, backendOptions: ["type": "ftp"]).contains("FTP authentication failed"))
    }
    func testBackendLoadsOnlyMatchingCredentialAndPreservesAbsoluteRoot() async throws {
        let keychain = KeychainService(serviceName: "FTPTest.\(UUID())", storage: .legacy)
        let account = "fixture"
        let config = FTPConfiguration(host: "nas.local", user: "alice")
        let options = try config.backendOptions(obscuredPassword: "obscured")
        try await keychain.saveCredential(RcloneRemoteCredential(remoteName: "FTP", provider: .ftp, backendOptions: options), account: account)
        let remote = RemoteConfig(name: "FTP", provider: .ftp, bucketOrRootPath: "/srv/photos", keychainAccountKey: account)
        let backend = try GenericRcloneFileProviderBackend.ftp(connection: FileProviderConnectionDescriptor(remote: remote), keychain: keychain)
        let reference = try await backend.fileSystemReference()
        if case .configuration(let loaded) = reference {
            XCTAssertEqual(loaded["_root"], "/srv/photos")
            XCTAssertEqual(loaded["pass"], "obscured")
        } else { XCTFail("Expected in-memory backend") }
        try await keychain.replaceCredential(RcloneRemoteCredential(remoteName: "Other", provider: .webdav, backendOptions: ["type": "webdav"]), account: account)
        do {
            _ = try await backend.fileSystemReference()
            XCTFail("Wrong provider credential must be rejected")
        } catch {
            XCTAssertTrue(error is FreeMountError)
        }
        try await keychain.deleteCredential(account: account)
    }

    func testFTPReadOnlyRejectsWriteWithoutNetwork() async throws {
        let remote = RemoteConfig(name: "FTP", provider: .ftp, bucketOrRootPath: "", keychainAccountKey: "missing", isReadOnly: true)
        let backend = try GenericRcloneFileProviderBackend.ftp(connection: FileProviderConnectionDescriptor(remote: remote))
        do {
            try await backend.createDirectory(at: "folder")
            XCTFail("Read-only should fail before credential or network access")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
    }


}
