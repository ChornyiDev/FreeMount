import FileProvider
import XCTest
@testable import FreeMount

final class MockFileProviderManager: FileProviderManagerProtocol, @unchecked Sendable {
    var signaledDomains: [NSFileProviderDomain] = []
    var addedDomains: [NSFileProviderDomain] = []
    var removedDomains: [NSFileProviderDomain] = []
    var disconnectedDomains: [NSFileProviderDomain] = []
    var reconnectedDomains: [NSFileProviderDomain] = []
    var domainsToReturn: [NSFileProviderDomain] = []
    var visibleURLToReturn: URL?
    var visibleURLError: Error?
    var errorToThrow: Error?

    func add(_ domain: NSFileProviderDomain) async throws {
        if let errorToThrow { throw errorToThrow }
        addedDomains.append(domain)
    }

    func signalEnumerator(for domain: NSFileProviderDomain) async throws {
        if let errorToThrow { throw errorToThrow }
        signaledDomains.append(domain)
    }

    func remove(_ domain: NSFileProviderDomain) async throws {
        if let errorToThrow { throw errorToThrow }
        removedDomains.append(domain)
    }

    func disconnect(_ domain: NSFileProviderDomain, reason: String) async throws {
        if let errorToThrow { throw errorToThrow }
        disconnectedDomains.append(domain)
    }

    func reconnect(_ domain: NSFileProviderDomain) async throws {
        if let errorToThrow { throw errorToThrow }
        reconnectedDomains.append(domain)
    }

    func getDomains() async throws -> [NSFileProviderDomain] {
        if let errorToThrow { throw errorToThrow }
        return domainsToReturn
    }

    var resolvedErrors: [(error: Error, domain: NSFileProviderDomain)] = []

    func signalErrorResolved(_ error: Error, for domain: NSFileProviderDomain) async throws {
        if let errorToThrow { throw errorToThrow }
        resolvedErrors.append((error, domain))
    }

    func getUserVisibleURL(for domain: NSFileProviderDomain) async throws -> URL? {
        if let visibleURLError { throw visibleURLError }
        if let errorToThrow { throw errorToThrow }
        return visibleURLToReturn
    }
}

actor HealthyGoogleDriveChecker: GoogleDriveConnectionHealthChecking {
    func check(_ remote: RemoteConfig) async -> ConnectionHealth {
        .healthy(checkedAt: Date())
    }
}

final class FileProviderDomainRegistryTests: XCTestCase {
    private var defaults: EphemeralUserDefaults!
    private var store: FileProviderDomainStore!
    private var mockManager: MockFileProviderManager!

    override func setUp() {
        super.setUp()
        defaults = EphemeralUserDefaults()
        store = FileProviderDomainStore(defaults: defaults)
        mockManager = MockFileProviderManager()
    }

    override func tearDown() {
        defaults = nil
        store = nil
        mockManager = nil
        super.tearDown()
    }

    @MainActor
    func testSavingSettingsPublishesPolicyAndRefreshesFinder() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let appState = AppState(remoteStore: RemoteConfigStore(defaults: defaults), domainRegistry: registry)
        var remote = RemoteConfig(name: "Old", provider: .googleDrive, bucketOrRootPath: "", keychainAccountKey: "key")
        appState.addRemote(remote)
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        try store.upsert(connection)
        mockManager.domainsToReturn = [NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(connection.id), displayName: "Old")]
        remote.name = "New"
        remote.isReadOnly = true
        try await appState.saveRemoteSettings(remote)
        XCTAssertEqual(try store.connection(forDomainIdentifier: connection.id)?.isReadOnly, true)
        XCTAssertEqual(mockManager.addedDomains.last?.displayName, "New")
        XCTAssertEqual(mockManager.signaledDomains.count, 1)
        mockManager.errorToThrow = CocoaError(.fileWriteUnknown)
        remote.isReadOnly = false
        do {
            try await appState.saveRemoteSettings(remote)
            XCTFail("Finder refresh failure must reach the UI")
        } catch {
            XCTAssertEqual(try store.connection(forDomainIdentifier: connection.id)?.isReadOnly, false)
        }
    }

    @MainActor
    func testRegisterGoogleDriveDomainSuccess() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Work Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.123"
        )

        let descriptor = try await registry.registerDomain(for: remote)

        XCTAssertEqual(descriptor.displayName, "Work Drive")
        XCTAssertEqual(mockManager.addedDomains.count, 1)
        XCTAssertEqual(mockManager.addedDomains.first?.displayName, "Work Drive")
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))
        XCTAssertEqual(try registry.registeredConnections().count, 1)
        XCTAssertEqual(try registry.connection(for: remote.id)?.domain.displayName, "Work Drive")
    }

    @MainActor
    func testRemoveGoogleDriveDomainSuccess() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Personal Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.456"
        )

        try await registry.registerDomain(for: remote)
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))

        try await registry.removeDomain(for: remote)

        XCTAssertEqual(mockManager.removedDomains.count, 1)
        XCTAssertEqual(mockManager.removedDomains.first?.displayName, "Personal Drive")
        XCTAssertFalse(try registry.isRegistered(remoteID: remote.id))
        XCTAssertTrue(try registry.registeredConnections().isEmpty)
    }

    @MainActor
    func testRegisterRefreshesMetadataForExistingConnectedDomain() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Updated Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.updated"
        )
        let descriptor = try FileProviderDomainDescriptor(remote: remote)
        mockManager.domainsToReturn = [
            NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(descriptor.domainIdentifier),
                displayName: "Old Drive Name"
            )
        ]

        _ = try await registry.registerDomain(for: remote)

        XCTAssertEqual(mockManager.addedDomains.count, 1)
        XCTAssertEqual(mockManager.addedDomains.first?.displayName, "Updated Drive")
    }

    @MainActor
    func testRegistrationFailurePropagatesSystemError() async {
        mockManager.errorToThrow = NSError(domain: "NSFileProviderErrorDomain", code: -1001, userInfo: [
            NSLocalizedDescriptionKey: "Registration failed"
        ])
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Failing Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.fail"
        )

        do {
            _ = try await registry.registerDomain(for: remote)
            XCTFail("Expected registration error to be thrown")
        } catch {
            XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))
        }
    }

    @MainActor
    func testUserVisiblePathResolution() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Docs Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.789"
        )

        // Case 1: Manager returns specific URL
        let expectedURL = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/FreeMount-DocsDrive")
        mockManager.visibleURLToReturn = expectedURL
        let pathWithManagerURL = try await registry.userVisiblePath(for: remote)
        XCTAssertEqual(pathWithManagerURL, expectedURL.path)

        var renamed = remote
        renamed.name = "Renamed Drive"
        let renamedPath = try await registry.userVisiblePath(for: renamed)
        XCTAssertEqual(renamedPath, expectedURL.path)

        // A missing system URL must not invent a path from the connection name.
        mockManager.visibleURLToReturn = nil
        let missingPath = try await registry.userVisiblePath(for: remote)
        XCTAssertNil(missingPath)
        let renamedMissingPath = try await registry.userVisiblePath(for: renamed)
        XCTAssertNil(renamedMissingPath)
    }

    @MainActor
    func testAppStateMountsAndRegistersGoogleDrive() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remoteStore = RemoteConfigStore(defaults: defaults)
        let appState = AppState(
            remoteStore: remoteStore,
            domainRegistry: registry,
            healthChecker: HealthyGoogleDriveChecker()
        )
        let remote = RemoteConfig(
            name: "Google Drive Cloud",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.gd"
        )
        appState.addRemote(remote)

        let preferences = AppPreferences()
        let supervisor = RcloneProcessSupervisor(port: 58_326, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        mockManager.visibleURLError = CocoaError(.fileReadUnknown)

        await appState.mount(remote, using: supervisor, preferences: preferences)

        XCTAssertTrue(appState.status(for: remote.id).isMounted)
        XCTAssertNil(appState.status(for: remote.id).mountedPath)
        XCTAssertTrue(appState.lastError?.localizedDescription.contains("Finder location") == true)
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))
        XCTAssertEqual(mockManager.addedDomains.count, 1)

        mockManager.visibleURLError = nil
        await appState.revealInFinder(remote)
        XCTAssertTrue(appState.lastError?.localizedDescription.contains("macOS has not provided") == true)
        XCTAssertTrue(appState.status(for: remote.id).isMounted)

        // Unmounting should disconnect rather than destroying domain, preserving offline files and bookmarks
        await appState.unmount(remote)

        XCTAssertFalse(appState.status(for: remote.id).isMounted)
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))
        XCTAssertEqual(mockManager.disconnectedDomains.count, 1)
        XCTAssertEqual(mockManager.removedDomains.count, 0)
        await supervisor.stopDaemon()
    }

    @MainActor
    func testDisconnectGoogleDriveDomainPreservesRegistrationAndDisconnects() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remote = RemoteConfig(
            name: "Offline Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.offline"
        )

        try await registry.registerDomain(for: remote)
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))

        try await registry.disconnectDomain(for: remote)
        XCTAssertTrue(try registry.isRegistered(remoteID: remote.id))
        XCTAssertEqual(mockManager.disconnectedDomains.count, 1)
        XCTAssertEqual(mockManager.disconnectedDomains.first?.displayName, "Offline Drive")
        XCTAssertEqual(mockManager.addedDomains.last?.isHidden, true)
    }

    @MainActor
    func testAppStateDoesNotInferMountedFromPublishedCatalog() throws {
        let remote = RemoteConfig(
            name: "Saved Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.account.saved"
        )
        let descriptor = try FileProviderConnectionDescriptor(remote: remote)
        try store.upsert(descriptor)

        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let remoteStore = RemoteConfigStore(defaults: defaults)
        remoteStore.save([remote])

        let appState = AppState(remoteStore: remoteStore, domainRegistry: registry)

        XCTAssertFalse(appState.status(for: remote.id).isMounted)
    }

    @MainActor
    func testValidateAndRefreshConnectionSignalsErrorResolvedAndRefreshesDomain() async throws {
        let registry = FileProviderDomainRegistry(store: store, manager: mockManager)
        let appState = AppState(
            remoteStore: RemoteConfigStore(defaults: defaults),
            domainRegistry: registry,
            healthChecker: HealthyGoogleDriveChecker()
        )
        let remote = RemoteConfig(
            name: "Work Drive",
            provider: .googleDrive,
            bucketOrRootPath: "",
            keychainAccountKey: "keychain.work"
        )
        appState.addRemote(remote)
        let connection = try FileProviderConnectionDescriptor(remote: remote)
        try store.upsert(connection)
        mockManager.domainsToReturn = [
            NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(connection.id),
                displayName: "Work Drive"
            )
        ]

        let health = await appState.validateAndRefreshConnection(remote)

        XCTAssertTrue(health.isHealthy)
        XCTAssertFalse(mockManager.resolvedErrors.isEmpty)
        let resolvedNotAuth = mockManager.resolvedErrors.contains { item in
            (item.error as? NSFileProviderError)?.code == .notAuthenticated
        }
        XCTAssertTrue(resolvedNotAuth, "Must signal NSFileProviderError.notAuthenticated is resolved")
        XCTAssertEqual(mockManager.signaledDomains.count, 2, "Must signal both refreshRegisteredDomain and signalEnumerator")
    }
}
