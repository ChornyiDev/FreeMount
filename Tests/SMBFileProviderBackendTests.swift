import XCTest
@testable import FreeMount

final class SMBFileProviderBackendTests: XCTestCase {
    func testShareDiscoveryRequestsDirectoriesWithoutChangingDefaultListings() throws {
        let discovery = try JSONEncoder().encode(RcloneListOptions(dirsOnly: true))
        let decoded = try JSONDecoder().decode(RcloneListOptions.self, from: discovery)
        XCTAssertEqual(decoded.dirsOnly, true)
        let defaultListing = try JSONEncoder().encode(RcloneListOptions())
        XCTAssertFalse(String(decoding: defaultListing, as: UTF8.self).contains("dirsOnly"))
    }

    func testAccountOptionsAndGuestDoNotInventAuthentication() throws {
        let config = SMBConfiguration(host: " nas.local ", port: 1445, user: " alice ", domain: " FAMILY ")
        let options = try config.backendOptions(obscuredPassword: "obscured-fixture")
        XCTAssertEqual(options, ["type": "smb", "host": "nas.local", "port": "1445", "user": "alice",
                                 "domain": "FAMILY", "pass": "obscured-fixture"])
        let guest = try SMBConfiguration(host: "127.0.0.1", user: "guest", domain: "").backendOptions()
        XCTAssertEqual(guest["domain"], "WORKGROUP")
        XCTAssertNil(guest["pass"])
    }

    func testRejectsInvalidEndpointAndMissingAccount() {
        for host in ["", "smb://nas.local", "nas.local/share", "nas.local:445", "user@nas.local", "nas local"] {
            XCTAssertThrowsError(try SMBConfiguration(host: host, user: "alice").backendOptions())
        }
        for port in [0, -1, 65536] {
            XCTAssertThrowsError(try SMBConfiguration(host: "nas.local", port: port, user: "alice").backendOptions())
        }
        XCTAssertThrowsError(try SMBConfiguration(host: "nas.local", user: " ").backendOptions())
    }

    func testShareRootCannotEscapeAndKeepsExactNames() throws {
        XCTAssertEqual(try SMBConfiguration.rootPath(share: "Family Photos", subdirectory: "/2026/October/"), "Family Photos/2026/October")
        XCTAssertEqual(try SMBConfiguration.rootPath(share: "Documents"), "Documents")
        for share in ["", ".", "..", "Docs/Family", "Docs\\Family"] {
            XCTAssertThrowsError(try SMBConfiguration.rootPath(share: share))
        }
        for path in ["../other", "a/./b", "a\\b"] {
            XCTAssertThrowsError(try SMBConfiguration.rootPath(share: "Documents", subdirectory: path))
        }
    }

    func testPersistenceKeepsShareAndIdentityWithoutPassword() throws {
        let config = SMBConfiguration(host: "nas.local", user: "alice")
        let remote = RemoteConfig(name: "Family SMB", provider: .smb, bucketOrRootPath: "Family/Photos",
                                  keychainAccountKey: "fixture-account", smbConfiguration: config, isReadOnly: true)
        let data = try JSONEncoder().encode(remote)
        let decoded = try JSONDecoder().decode(RemoteConfig.self, from: data)
        XCTAssertEqual(decoded, remote)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        let descriptor = try FileProviderConnectionDescriptor(remote: decoded)
        XCTAssertEqual(descriptor.rootPath, "Family/Photos")
        XCTAssertTrue(descriptor.id.hasPrefix("com.freemount.smb."))
        XCTAssertTrue(descriptor.isReadOnly)
        var invalid = remote
        invalid.bucketOrRootPath = ""
        XCTAssertThrowsError(try FileProviderConnectionDescriptor(remote: invalid))
    }

    func testBackendLoadsOnlyMatchingCredentialAndUsesShareRoot() async throws {
        let keychain = KeychainService(serviceName: "SMBTest.\(UUID())", storage: .legacy)
        let account = "fixture"
        let config = SMBConfiguration(host: "nas.local", user: "alice")
        let options = try config.backendOptions(obscuredPassword: "obscured")
        try await keychain.saveCredential(RcloneRemoteCredential(remoteName: "SMB", provider: .smb, backendOptions: options), account: account)
        let remote = RemoteConfig(name: "SMB", provider: .smb, bucketOrRootPath: "Family/Photos", keychainAccountKey: account)
        let backend = try GenericRcloneFileProviderBackend.smb(connection: FileProviderConnectionDescriptor(remote: remote), keychain: keychain)
        let reference = try await backend.fileSystemReference()
        if case .configuration(let loaded) = reference {
            XCTAssertEqual(loaded["_root"], "Family/Photos")
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

    func testSMBReadOnlyRejectsWriteWithoutNetwork() async throws {
        let remote = RemoteConfig(name: "SMB", provider: .smb, bucketOrRootPath: "Family", keychainAccountKey: "missing", isReadOnly: true)
        let backend = try GenericRcloneFileProviderBackend.smb(connection: FileProviderConnectionDescriptor(remote: remote))
        do {
            try await backend.createDirectory(at: "folder")
            XCTFail("Read-only should fail before credential or network access")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission)
        }
    }

    func testSMBNTLMFailuresHaveUsefulMessages() {
        let error = FreeMountError.rcloneError(statusCode: 500, message: "response error: STATUS_LOGON_FAILURE")
        let message = ConnectionPreflightService.classify(error: error, backendOptions: ["type": "smb"])
        XCTAssertTrue(message.contains("username"))
        if case .authorizationRequired = SMBConnectionHealthChecker.classify(error) {} else { XCTFail("Expected authentication failure") }
    }
}
