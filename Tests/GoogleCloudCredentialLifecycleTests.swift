import XCTest
import Security
@testable import FreeMount

final class GoogleCloudCredentialLifecycleTests: XCTestCase {
    private func remote(bucket: String = "test-bucket", account: String) throws -> RemoteConfig {
        RemoteConfig(name: "Bucket", provider: .googleCloudStorage, bucketOrRootPath: bucket,
                     keychainAccountKey: account,
                     googleCloudStorage: try GoogleCloudStorageSelection(directBucket: bucket))
    }
    private func credential() -> RcloneRemoteCredential {
        RcloneRemoteCredential(remoteName: "Bucket", provider: .googleCloudStorage,
                               backendOptions: ["type": "google cloud storage", "token": "disposable-test-token"])
    }

    @MainActor
    func testReplacementThenRemovalLeavesNoCredentials() async throws {
        let keychain = KeychainService(serviceName: "com.freemount.tests.lifecycle.\(UUID())", storage: .legacy)
        let defaults = EphemeralUserDefaults()
        let domains = FileProviderDomainStore(defaults: defaults)
        let registry = FileProviderDomainRegistry(store: domains, manager: MockFileProviderManager())
        let state = AppState(remoteStore: RemoteConfigStore(defaults: defaults), domainRegistry: registry)
        try await keychain.saveCredential(credential(), account: "old")
        try await keychain.saveCredential(credential(), account: "new")
        do {
            let original = state.addRemote(try remote(account: "old"))
            try domains.upsert(try FileProviderConnectionDescriptor(remote: original))
            let replacement = await state.addRemote(try remote(account: "new"), keychain: keychain)
            XCTAssertEqual(replacement.id, original.id)
            let inventory = try await keychain.listCredentials()
            XCTAssertEqual(inventory.map(\.account), ["new"])
            XCTAssertEqual(try registry.connection(for: original.id)?.keychainAccountKey, "new")
            await state.removeRemoteAndCredentials(id: replacement.id, keychain: keychain)
            let remaining = try await keychain.listCredentials()
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertTrue(state.remotes.isEmpty)
            XCTAssertTrue(try domains.all().isEmpty)
        } catch {
            try await keychain.deleteCredential(account: "old")
            try await keychain.deleteCredential(account: "new")
            throw error
        }
    }

    @MainActor
    func testReplacementPreservesCredentialsReferencedByRemoteOrDomain() async throws {
        for domainOnly in [false, true] {
            let keychain = KeychainService(serviceName: "com.freemount.tests.lifecycle.\(UUID())", storage: .legacy)
            let defaults = EphemeralUserDefaults()
            let domains = FileProviderDomainStore(defaults: defaults)
            let registry = FileProviderDomainRegistry(store: domains, manager: MockFileProviderManager())
            let state = AppState(remoteStore: RemoteConfigStore(defaults: defaults), domainRegistry: registry)
            try await keychain.saveCredential(credential(), account: "old")
            try await keychain.saveCredential(credential(), account: "new")
            do {
                state.addRemote(try remote(account: "old"))
                let shared = try remote(bucket: "other-bucket", account: "old")
                if domainOnly { try domains.upsert(try FileProviderConnectionDescriptor(remote: shared)) }
                else { state.addRemote(shared) }
                _ = await state.addRemote(try remote(account: "new"), keychain: keychain)
                let inventory = try await keychain.listCredentials()
                XCTAssertEqual(Set(inventory.map(\.account)), ["old", "new"])
            } catch {
                try await keychain.deleteCredential(account: "old")
                try await keychain.deleteCredential(account: "new")
                throw error
            }
            try await keychain.deleteCredential(account: "old")
            try await keychain.deleteCredential(account: "new")
        }
    }

    @MainActor
    func testFailedDomainRemovalPreservesItsCredential() async throws {
        let keychain = KeychainService(serviceName: "com.freemount.tests.lifecycle.\(UUID())", storage: .legacy)
        let defaults = EphemeralUserDefaults()
        let domains = FileProviderDomainStore(defaults: defaults)
        let manager = MockFileProviderManager()
        let registry = FileProviderDomainRegistry(store: domains, manager: manager)
        let state = AppState(remoteStore: RemoteConfigStore(defaults: defaults), domainRegistry: registry)
        let config = try remote(account: "keep")
        try await keychain.saveCredential(credential(), account: "keep")
        do {
            state.addRemote(config)
            try domains.upsert(try FileProviderConnectionDescriptor(remote: config))
            manager.errorToThrow = CocoaError(.fileWriteUnknown)
            await state.removeRemoteAndCredentials(id: config.id, keychain: keychain)
            XCTAssertNotNil(state.lastError)
            XCTAssertNotNil(try domains.connection(for: config.id))
            let retained = try await keychain.loadCredential(account: "keep")
            XCTAssertEqual(retained, credential())
        } catch {
            try await keychain.deleteCredential(account: "keep")
            throw error
        }
        try await keychain.deleteCredential(account: "keep")
    }

    @MainActor
    func testReconciliationCannotRebindGCSByName() throws {
        let current = try remote(account: "new")
        let state = AppState(remotes: [current], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        state.reconcileRemotes(from: [KeychainCredentialRecord(account: "old", credential: credential())])
        XCTAssertEqual(state.remotes.first?.keychainAccountKey, "new")
        XCTAssertEqual(state.remotes.count, 1)
    }

    func testDeleteCannotHideFailureInEitherKeychainStore() {
        XCTAssertThrowsError(try KeychainService.validateDeletionStatuses(modern: errSecInteractionNotAllowed, legacy: errSecItemNotFound))
        XCTAssertThrowsError(try KeychainService.validateDeletionStatuses(modern: errSecItemNotFound, legacy: errSecInteractionNotAllowed))
        XCTAssertThrowsError(try KeychainService.validateDeletionStatuses(modern: errSecMissingEntitlement, legacy: errSecSuccess))
        XCTAssertNoThrow(try KeychainService.validateDeletionStatuses(modern: errSecItemNotFound, legacy: errSecItemNotFound))
    }
}
