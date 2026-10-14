import XCTest
@testable import FreeMount

final class KeychainServiceTests: XCTestCase {
    func testCredentialRoundTripOverwriteAndDeletion() async throws {
        let serviceName = "com.freemount.tests.\(UUID().uuidString)"
        let account = "credential-\(UUID().uuidString)"
        let keychain = KeychainService(serviceName: serviceName, storage: .legacy)

        let original = RcloneRemoteCredential(
            remoteName: "gdrive",
            provider: .googleDrive,
            backendOptions: [
                "type": "drive",
                "token": "{\"refresh_token\":\"test-only\"}"
            ]
        )
        try await keychain.saveCredential(original, account: account)
        let loadedOriginal = try await keychain.loadCredential(account: account)
        XCTAssertEqual(loadedOriginal, original)

        let updated = RcloneRemoteCredential(
            remoteName: "gdrive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "{\"refresh_token\":\"rotated\"}"]
        )
        try await keychain.saveCredential(updated, account: account)
        let loadedUpdated = try await keychain.loadCredential(account: account)
        XCTAssertEqual(loadedUpdated, updated)

        try await keychain.deleteCredential(account: account)
        do {
            _ = try await keychain.loadCredential(account: account)
            XCTFail("Expected deleted credential to be unavailable")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .itemNotFound(account: account))
        }
    }

    func testCredentialBuildsInMemoryRcloneReference() {
        let credential = RcloneRemoteCredential(
            remoteName: "gdrive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "test-token"]
        )

        guard case .configuration(let options) = credential.fileSystemReference(root: "/FreeMount Tests/") else {
            return XCTFail("Expected an in-memory rclone configuration")
        }
        XCTAssertNil(options["_name"])
        XCTAssertEqual(options["_root"], "FreeMount Tests")
        XCTAssertEqual(options["type"], "drive")
        XCTAssertEqual(options["token"], "test-token")
    }

    func testCredentialBuildsSharedWithMeReferenceWithoutPersistingAnotherRemote() {
        let credential = RcloneRemoteCredential(
            remoteName: "gdrive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "test-token"]
        )

        guard case .configuration(let options) = credential.fileSystemReference(
            root: "",
            additionalOptions: ["shared_with_me": "true"]
        ) else {
            return XCTFail("Expected an in-memory rclone configuration")
        }
        XCTAssertEqual(options["_root"], "")
        XCTAssertEqual(options["shared_with_me"], "true")
        XCTAssertEqual(options["token"], "test-token")
    }

    func testListCredentialsReturnsOnlyServiceScopedRecords() async throws {
        let serviceName = "com.freemount.tests.\(UUID().uuidString)"
        let firstAccount = "credential-\(UUID().uuidString)"
        let secondAccount = "credential-\(UUID().uuidString)"
        let keychain = KeychainService(serviceName: serviceName, storage: .legacy)
        let credential = RcloneRemoteCredential(
            remoteName: "listed-drive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "test-only"]
        )
        defer {
            Task {
                try? await keychain.deleteCredential(account: firstAccount)
                try? await keychain.deleteCredential(account: secondAccount)
            }
        }

        try await keychain.saveCredential(credential, account: firstAccount)
        try await keychain.saveCredential(credential, account: secondAccount)
        let records = try await keychain.listCredentials()

        XCTAssertEqual(Set(records.map(\.account)), Set([firstAccount, secondAccount]))
        XCTAssertTrue(records.allSatisfy { $0.credential == credential })
        try await keychain.deleteCredential(account: firstAccount)
        try await keychain.deleteCredential(account: secondAccount)
    }

    func testGoogleDriveAuthorizationBuildsKeychainOnlyRcloneCredential() throws {
        let client = try GoogleDriveOAuthClient(
            clientID: "desktop-client.apps.googleusercontent.com",
            clientSecret: "test-only-client-secret"
        )
        let authorization = GoogleDriveAuthorization(
            tokenJSON: "{\"refresh_token\":\"test-only\"}",
            client: client
        )

        let credential = authorization.credential(remoteName: "personal-drive")
        XCTAssertEqual(credential.provider, .googleDrive)
        XCTAssertEqual(credential.backendOptions["type"], "drive")
        XCTAssertEqual(credential.backendOptions["client_id"], client.clientID)
        XCTAssertEqual(credential.backendOptions["client_secret"], "test-only-client-secret")
        XCTAssertEqual(credential.backendOptions["token"], authorization.tokenJSON)
    }

    func testGoogleDriveOAuthClientRejectsBlankID() {
        XCTAssertThrowsError(try GoogleDriveOAuthClient(clientID: "   ")) { error in
            XCTAssertEqual(error as? GoogleDriveOAuthError, .invalidClientID)
        }
    }

    func testOAuthFormEncoderEscapesReservedOAuthValues() {
        let encoded = OAuthFormEncoder.encode([
            URLQueryItem(name: "code", value: "4/0A+test="),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1:9000/oauth2/callback")
        ])

        XCTAssertEqual(
            encoded,
            "code=4%2F0A%2Btest%3D&redirect_uri=http%3A%2F%2F127.0.0.1%3A9000%2Foauth2%2Fcallback"
        )
    }
    func testUnsignedMigrationFailurePreservesLegacySecret() async throws {
        let service = "com.freemount.tests.migration.\(UUID())"
        let legacy = KeychainService(serviceName: service, storage: .legacy)
        let modern = KeychainService(serviceName: service)
        let credential = RcloneRemoteCredential(remoteName: "fixture", provider: .googleDrive, backendOptions: ["type": "drive", "token": "fixture-only"])
        try await legacy.saveCredential(credential, account: "fixture")
        do {
            let migrated = try await modern.loadCredential(account: "fixture")
            XCTAssertEqual(migrated, credential)
            try await modern.deleteCredential(account: "fixture")
        } catch {
            let retained = try await legacy.loadCredential(account: "fixture")
            XCTAssertEqual(retained, credential)
            try await legacy.deleteCredential(account: "fixture")
        }
    }
}
