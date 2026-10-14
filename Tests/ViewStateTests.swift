import FileProvider
import XCTest
@testable import FreeMount

@MainActor
final class ViewStateTests: XCTestCase {
    func testAddingRemoteCreatesUnmountedStatus() {
        let state = AppState(remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        let remote = makeRemote()

        state.addRemote(remote)

        XCTAssertEqual(state.remotes, [remote])
        XCTAssertEqual(state.status(for: remote.id), .unmounted)
    }

    func testSharedDrivesWithSameNameRemainDistinctConnections() {
        let first = RemoteConfig(
            name: "Engineering",
            provider: .googleDrive,
            bucketOrRootPath: "",
            googleDriveSharedDriveID: "drive-one"
        )
        let second = RemoteConfig(
            name: "Engineering",
            provider: .googleDrive,
            bucketOrRootPath: "",
            googleDriveSharedDriveID: "drive-two"
        )
        let state = AppState(remotes: [first, second], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))

        XCTAssertEqual(state.remotes.count, 2)
        XCTAssertEqual(Set(state.remotes.compactMap(\.googleDriveSharedDriveID)), ["drive-one", "drive-two"])
    }

    func testRemoveRemoteCleansUpItsStatus() async {
        let state = AppState(remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        let remote = makeRemote()
        state.addRemote(remote)
        state.updateStatus(.failed(reason: "Offline"), for: remote.id)

        await state.removeRemoteAndCredentials(id: remote.id)

        XCTAssertTrue(state.remotes.isEmpty)
        XCTAssertEqual(state.status(for: remote.id), .unmounted)
    }

    func testRemoveRemoteWithKeychainDeletesCredentialWhenNotShared() async throws {
        let keychain = KeychainService(serviceName: "com.freemount.tests.viewstate.\(UUID())", storage: .legacy)
        let account = "credential.test.\(UUID().uuidString.lowercased())"
        let credential = RcloneRemoteCredential(
            remoteName: "Temp Drive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "temp-token"]
        )
        try await keychain.saveCredential(credential, account: account)

        var remote = makeRemote()
        remote.keychainAccountKey = account
        let state = AppState(remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        state.addRemote(remote)

        await state.removeRemoteAndCredentials(id: remote.id, keychain: keychain)

        XCTAssertTrue(state.remotes.isEmpty)
        do {
            _ = try await keychain.loadCredential(account: account)
            XCTFail("Expected credential to be deleted from Keychain")
        } catch let error as KeychainError {
            XCTAssertEqual(error, .itemNotFound(account: account))
        }
    }

    func testApplyingTelemetryUpdatesDaemonAndTransferState() {
        let state = AppState(remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        let stats = TransferStats(speed: 1_048_576, transfers: 2)

        state.applyTelemetry(RcloneTelemetrySnapshot(isDaemonRunning: true, stats: stats))

        XCTAssertTrue(state.isDaemonRunning)
        XCTAssertEqual(state.currentStats, stats)
    }

    func testActiveCountRequiresMountedAndHealthyConnection() async {
        let remote = RemoteConfig(
            name: "Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "credential.drive"
        )
        let checker = StubGoogleDriveHealthChecker(results: [remote.id: .authorizationRequired(reason: "Expired")])
        let state = AppState(remotes: [remote], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()), healthChecker: checker)
        state.updateStatus(.mounted(mountedAt: Date(), mountPoint: "/tmp/drive"), for: remote.id)

        XCTAssertEqual(state.activeConnectionCount, 0)
        _ = await state.refreshConnectionHealth(for: remote)
        XCTAssertEqual(state.health(for: remote.id), .authorizationRequired(reason: "Expired"))
        XCTAssertEqual(state.activeConnectionCount, 0)
    }

    func testHealthIsTrackedIndependentlyForMultipleAccounts() async {
        let first = googleDriveRemote(name: "Personal", account: "credential.personal")
        let second = googleDriveRemote(name: "Work", account: "credential.work")
        let checker = StubGoogleDriveHealthChecker(results: [
            first.id: .healthy(checkedAt: Date(timeIntervalSince1970: 1)),
            second.id: .authorizationRequired(reason: "Authorization expired")
        ])
        let state = AppState(remotes: [first, second], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()), healthChecker: checker)
        state.updateStatus(.mounted(mountedAt: Date(), mountPoint: "/personal"), for: first.id)
        state.updateStatus(.mounted(mountedAt: Date(), mountPoint: "/work"), for: second.id)

        _ = await state.refreshConnectionHealth(for: first)
        _ = await state.refreshConnectionHealth(for: second)

        XCTAssertTrue(state.health(for: first.id).isHealthy)
        XCTAssertEqual(state.health(for: second.id), .authorizationRequired(reason: "Authorization expired"))
        XCTAssertEqual(state.activeConnectionCount, 1)
    }

    func testUnsupportedProviderDoesNotStartLegacyMount() async {
        let state = AppState(remotes: [], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        let remote = makeRemote()

        await state.mount(remote, using: RcloneProcessSupervisor(), preferences: AppPreferences())

        guard case .failed(let reason) = state.status(for: remote.id) else {
            return XCTFail("Unsupported provider should fail before starting a mount")
        }
        XCTAssertTrue(reason.contains("Apple File Provider"))
        XCTAssertFalse(state.isDaemonRunning)
    }

    func testPreferencesPersistRevealInFinderSetting() {
        let defaults = EphemeralUserDefaults()
        let preferences = AppPreferences(defaults: defaults)
        preferences.revealMountedDrives = false

        let restored = AppPreferences(defaults: defaults)
        XCTAssertFalse(restored.revealMountedDrives)
    }

    func testRemoteStorePreservesIdentityAndOmitsLegacyOptions() throws {
        let defaults = EphemeralUserDefaults()
        let store = RemoteConfigStore(defaults: defaults)
        var remote = makeRemote()
        remote.keychainAccountKey = "credential.opaque-reference"
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([remote])) as? [[String: Any]])
        encoded[0]["vfsCacheMode"] = "full"
        encoded[0]["vfsCacheMaxSizeGB"] = 20
        encoded[0]["customOptions"] = ["password": "must-not-persist", "vfs-read-chunk-size": "32M"]
        defaults.set(try JSONSerialization.data(withJSONObject: encoded), forKey: "remoteConfigurations.v1")
        let restored = store.load()
        XCTAssertEqual(restored, [remote])
        store.save(restored)
        let saved = try XCTUnwrap(defaults.data(forKey: "remoteConfigurations.v1"))
        let json = try XCTUnwrap(String(data: saved, encoding: .utf8))
        XCTAssertFalse(json.contains("customOptions"))
        XCTAssertFalse(json.contains("vfsCache"))
        XCTAssertFalse(json.contains("must-not-persist"))
    }

    func testAppStateRestoresLegacyKeychainMetadataOnlyWhenEmpty() {
        let defaults = EphemeralUserDefaults()
        let store = RemoteConfigStore(defaults: defaults)
        let state = AppState(remoteStore: store)
        let credential = RcloneRemoteCredential(
            remoteName: "Recovered Drive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "secret-never-persisted"]
        )

        state.restoreRemotesIfEmpty(
            from: [KeychainCredentialRecord(account: "credential.legacy", credential: credential)]
        )

        XCTAssertEqual(state.remotes.count, 1)
        XCTAssertEqual(state.remotes[0].name, "Recovered Drive")
        XCTAssertEqual(state.remotes[0].keychainAccountKey, "credential.legacy")
        let encodedDefaults = defaults.data(forKey: "remoteConfigurations.v1")
        XCTAssertNotNil(encodedDefaults)
        XCTAssertFalse(String(data: encodedDefaults!, encoding: .utf8)!.contains("secret-never-persisted"))
    }

    func testAddConnectionUniqueNameGeneratesSequentialFinderStyleNames() {
        let existing = ["Google Drive", "Google Drive 2", "Marketing"]
        
        XCTAssertEqual(AddConnectionView.uniqueName(base: "Google Drive", existingNames: existing), "Google Drive 3")
        XCTAssertEqual(AddConnectionView.uniqueName(base: "Marketing", existingNames: existing), "Marketing 2")
        XCTAssertEqual(AddConnectionView.uniqueName(base: "New Drive", existingNames: existing), "New Drive")
        XCTAssertEqual(AddConnectionView.uniqueName(base: "google drive", existingNames: existing), "google drive 3")
    }

    func testStartupRespectsDisabledAutomaticConnection() async throws {
        let remote = googleDriveRemote(name: "Manual", account: "credential.manual")
        let manager = MockFileProviderManager()
        let registry = FileProviderDomainRegistry(store: FileProviderDomainStore(defaults: EphemeralUserDefaults()), manager: manager)
        let state = AppState(remotes: [remote], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()), domainRegistry: registry)

        await state.reconcileDomains()

        XCTAssertTrue(manager.addedDomains.isEmpty)
        XCTAssertEqual(state.status(for: remote.id), .unmounted)
        XCTAssertFalse(state.isDaemonRunning)
    }

    func testFailedStartupRegistrationNeverBecomesMounted() async {
        var remote = makeRemote()
        remote.provider = .googleDrive
        remote.autoMountAtLaunch = true
        // Missing credential prevents publication/registration before any cloud IO.
        let manager = MockFileProviderManager()
        let registry = FileProviderDomainRegistry(store: FileProviderDomainStore(defaults: EphemeralUserDefaults()), manager: manager)
        let state = AppState(remotes: [remote], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()), domainRegistry: registry)

        await state.reconcileDomains()

        guard case .failed = state.status(for: remote.id) else { return XCTFail("Registration failure must stay visible") }
        XCTAssertNotNil(state.lastError)
        XCTAssertFalse(state.health(for: remote.id).isHealthy)
    }

    func testCatalogPresenceDoesNotClaimSystemDomainIsMounted() throws {
        let remote = googleDriveRemote(name: "Cached", account: "credential.cached")
        let store = FileProviderDomainStore(defaults: EphemeralUserDefaults())
        try store.upsert(FileProviderConnectionDescriptor(remote: remote))
        let registry = FileProviderDomainRegistry(store: store, manager: MockFileProviderManager())
        let state = AppState(remotes: [remote], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()), domainRegistry: registry)

        XCTAssertEqual(state.status(for: remote.id), .unmounted)
        XCTAssertEqual(state.health(for: remote.id), .unknown)
    }

    func testFailedDomainRemovalPreservesSavedConnection() async throws {
        let remote = googleDriveRemote(name: "Keep", account: "credential.keep")
        let manager = MockFileProviderManager()
        manager.errorToThrow = FileProviderDomainError.systemRegistrationFailed("Removal denied")
        let catalog = FileProviderDomainStore(defaults: EphemeralUserDefaults())
        try catalog.upsert(FileProviderConnectionDescriptor(remote: remote))
        let registry = FileProviderDomainRegistry(store: catalog, manager: manager)
        let store = RemoteConfigStore(defaults: EphemeralUserDefaults())
        let state = AppState(remotes: [remote], remoteStore: store, domainRegistry: registry)
        store.save([remote])

        await state.removeRemoteAndCredentials(id: remote.id)

        XCTAssertEqual(state.remotes, [remote])
        XCTAssertEqual(store.load(), [remote])
        XCTAssertNotNil(state.lastError)
    }

    private func makeRemote() -> RemoteConfig {
        RemoteConfig(
            name: "Test Remote",
            provider: .s3,
            bucketOrRootPath: "test-bucket"
        )
    }

    private func googleDriveRemote(name: String, account: String) -> RemoteConfig {
        RemoteConfig(
            name: name,
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: account
        )
    }
}

private actor StubGoogleDriveHealthChecker: GoogleDriveConnectionHealthChecking {
    let results: [UUID: ConnectionHealth]

    init(results: [UUID: ConnectionHealth]) {
        self.results = results
    }

    func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        results[remote.id] ?? .unavailable(reason: "No result")
    }
}
