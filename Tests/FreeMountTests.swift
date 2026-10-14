import XCTest
@testable import FreeMount

final class FreeMountTests: XCTestCase {
    override func setUp() {
        super.setUp()
        EphemeralUserDefaults.cleanAllTestPreferences()
    }

    func testRemoteConfigEncodingAndDecoding() throws {
        let config = RemoteConfig(
            name: "Production GCS",
            provider: .googleCloudStorage,
            bucketOrRootPath: "my-cloud-bucket",
            googleDriveSharedDriveID: "shared-drive-id",
            autoMountAtLaunch: true,
            isReadOnly: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RemoteConfig.self, from: data)

        XCTAssertEqual(decoded.id, config.id)
        XCTAssertEqual(decoded.name, "Production GCS")
        XCTAssertEqual(decoded.provider, .googleCloudStorage)
        XCTAssertEqual(decoded.googleDriveSharedDriveID, "shared-drive-id")
        XCTAssertTrue(decoded.autoMountAtLaunch)
    }

    func testLegacyRemoteConfigDecodesAsMyDrive() throws {
        let original = RemoteConfig(
            name: "Legacy Drive",
            provider: .googleDrive,
            bucketOrRootPath: "/"
        )
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "googleDriveSharedDriveID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RemoteConfig.self, from: legacyData)

        XCTAssertNil(decoded.googleDriveSharedDriveID)
        XCTAssertEqual(decoded.name, "Legacy Drive")
    }

    func testMountStatusStates() {
        let unmounted = MountStatus.unmounted
        XCTAssertFalse(unmounted.isMounted)
        XCTAssertFalse(unmounted.isTransitioning)

        let mounting = MountStatus.mounting
        XCTAssertTrue(mounting.isTransitioning)

        let mounted = MountStatus.mounted(mountedAt: Date(), mountPoint: "/Users/test/Library/CloudStorage/FreeMount-Drive")
        XCTAssertTrue(mounted.isMounted)
        XCTAssertFalse(mounted.isTransitioning)
    }

    func testLegacyMountPathIsIgnoredWithoutChangingConnectionIdentity() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","name":"Legacy Drive","provider":"drive",
        "bucketOrRootPath":"/","localMountPoint":"/tmp/stale-location",
        "keychainAccountKey":"existing-credential","autoMountAtLaunch":true,"isReadOnly":true}
        """.utf8)
        let remote = try JSONDecoder().decode(RemoteConfig.self, from: data)
        XCTAssertEqual(remote.id, id)
        XCTAssertEqual(remote.keychainAccountKey, "existing-credential")
        XCTAssertTrue(remote.autoMountAtLaunch)
        XCTAssertTrue(remote.isReadOnly)
        let saved = String(decoding: try JSONEncoder().encode(remote), as: UTF8.self)
        XCTAssertFalse(saved.contains("localMountPoint"))
        XCTAssertFalse(saved.contains("stale-location"))
    }

    func testTransferStatsFormatting() {
        let stats = TransferStats(
            bytes: 1_073_741_824, // 1 GB
            speed: 10_485_760 // 10 MB/s
        )

        XCTAssertFalse(stats.formattedSpeed.isEmpty)
        XCTAssertFalse(stats.formattedBytes.isEmpty)
        XCTAssertTrue(stats.formattedSpeed.contains("/s"))
    }

    @MainActor
    func testAppStateManagement() async {
        let appState = AppState(remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        XCTAssertTrue(appState.remotes.isEmpty)
        XCTAssertFalse(appState.isDaemonRunning)

        let remote = RemoteConfig(
            name: "SFTP Server",
            provider: .sftp,
            bucketOrRootPath: "/home/user"
        )

        appState.addRemote(remote)
        XCTAssertEqual(appState.remotes.count, 1)
        XCTAssertEqual(appState.status(for: remote.id), .unmounted)

        appState.updateStatus(.mounting, for: remote.id)
        XCTAssertEqual(appState.status(for: remote.id), .mounting)

        await appState.removeRemoteAndCredentials(id: remote.id)
        XCTAssertTrue(appState.remotes.isEmpty)
        XCTAssertEqual(appState.status(for: remote.id), .unmounted)
    }

    func testErrorDescriptions() {
        let error = FreeMountError.rcloneNotFound(searchedPaths: ["/opt/homebrew/bin/rclone"])
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("compatible rclone"))
    }
}
