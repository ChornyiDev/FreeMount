import XCTest
@testable import FreeMount

final class FileProviderDomainDescriptorTests: XCTestCase {
    func testGoogleDriveDescriptorUsesStableRemoteIdentifier() throws {
        let remoteID = UUID(uuidString: "A0D2DC15-8EF0-4D45-801C-12D0ED3A8914")!
        let remote = RemoteConfig(
            id: remoteID,
            name: "  Team Drive  ",
            provider: .googleDrive,
            bucketOrRootPath: ""
        )

        let descriptor = try FileProviderDomainDescriptor(remote: remote)

        XCTAssertEqual(descriptor.displayName, "Team Drive")
        XCTAssertEqual(
            descriptor.domainIdentifier,
            "com.freemount.google.a0d2dc15-8ef0-4d45-801c-12d0ed3a8914"
        )
    }

    func testNonGoogleRemoteIsRejected() {
        let remote = RemoteConfig(
            name: "S3",
            provider: .s3,
            bucketOrRootPath: "bucket"
        )

        XCTAssertThrowsError(try FileProviderDomainDescriptor(remote: remote)) { error in
            XCTAssertEqual(error as? FileProviderDomainError, .unsupportedProvider(.s3))
        }
    }

    func testLegacyDescriptorDefaultsToGoogleDriveProvider() throws {
        let remoteID = UUID(uuidString: "06D7188A-68BD-4B56-9246-36F6B8502CF8")!
        let data = try JSONSerialization.data(withJSONObject: [
            "remoteID": remoteID.uuidString,
            "displayName": "Legacy Drive"
        ])

        let descriptor = try JSONDecoder().decode(FileProviderDomainDescriptor.self, from: data)

        XCTAssertEqual(descriptor.provider, .googleDrive)
        XCTAssertEqual(descriptor.domainIdentifier, "com.freemount.google.06d7188a-68bd-4b56-9246-36f6b8502cf8")
    }

    func testProviderIDPreservesUnknownProviderDuringRoundTrip() throws {
        let provider = ProviderID(rawValue: "community.example-storage")

        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderID.self, from: encoded)

        XCTAssertEqual(decoded, provider)
    }

    func testProviderRegistryExposesOnlyImplementedProviders() {
        let providers = ProviderRegistry.shared.registeredProviders

        XCTAssertEqual(providers.map(\.id), [.googleDrive, .googleCloudStorage, .sftp, .webdav, .smb, .ftp])
        XCTAssertNotNil(ProviderRegistry.shared.provider(for: .googleDrive))
        XCTAssertNotNil(ProviderRegistry.shared.provider(for: .sftp))
        XCTAssertNotNil(ProviderRegistry.shared.provider(for: .webdav))
        XCTAssertNil(ProviderRegistry.shared.provider(for: .s3))
    }

    func testBlankDisplayNameIsRejected() {
        XCTAssertThrowsError(try FileProviderDomainDescriptor(remoteID: UUID(), displayName: " \n ")) { error in
            XCTAssertEqual(error as? FileProviderDomainError, .emptyDisplayName)
        }
    }

    func testRemotePathNormalizationRejectsTraversal() {
        XCTAssertEqual(try FileProviderPath.normalize("/Invoices/2026/"), "Invoices/2026")
        XCTAssertThrowsError(try FileProviderPath.normalize("Invoices/../secrets")) { error in
            XCTAssertEqual(error as? FileProviderPathError, .traversalAttempt("Invoices/../secrets"))
        }
    }

    @MainActor
    func testDomainStorePersistsOnlyDomainDescriptors() throws {
        let defaults = EphemeralUserDefaults()
        let store = FileProviderDomainStore(defaults: defaults)
        let remote = RemoteConfig(
            name: "Google Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "opaque-keychain-account"
        )
        let descriptor = try FileProviderConnectionDescriptor(remote: remote)

        try store.upsert(descriptor)

        XCTAssertEqual(try store.connection(forDomainIdentifier: descriptor.domain.domainIdentifier), descriptor)
        try store.remove(remoteID: descriptor.domain.remoteID)
        XCTAssertTrue(try store.all().isEmpty)
    }

    func testConnectionDescriptorDoesNotAllowMissingKeychainReference() {
        let remote = RemoteConfig(
            name: "Google Drive",
            provider: .googleDrive,
            bucketOrRootPath: ""
        )

        XCTAssertThrowsError(try FileProviderConnectionDescriptor(remote: remote)) { error in
            XCTAssertEqual(error as? FileProviderDomainError, .missingKeychainAccount)
        }
    }

    func testConnectionDescriptorPreservesSharedDriveSelection() throws {
        let remote = RemoteConfig(
            name: "Engineering",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "credential.engineering",
            googleDriveSharedDriveID: "shared-drive-123"
        )

        let descriptor = try FileProviderConnectionDescriptor(remote: remote)
        let decoded = try JSONDecoder().decode(
            FileProviderConnectionDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )

        XCTAssertEqual(decoded.googleDriveSharedDriveID, "shared-drive-123")
        XCTAssertEqual(
            GoogleDriveFileProviderBackend.connectionOptions(
                sharedDriveID: decoded.googleDriveSharedDriveID
            ),
            ["team_drive": "shared-drive-123"]
        )
    }
}
