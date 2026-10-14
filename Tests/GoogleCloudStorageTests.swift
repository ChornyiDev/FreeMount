import XCTest
@testable import FreeMount

final class GoogleCloudStorageTests: XCTestCase {
    private let http = MockHTTPRouter()
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        http.configure(config)
        return URLSession(configuration: config)
    }
    private func authorization() throws -> GoogleDriveAuthorization {
        GoogleDriveAuthorization(tokenJSON: "{\"access_token\":\"test-token\",\"refresh_token\":\"test-refresh\"}", client: try GoogleDriveOAuthClient(clientID: "test-client"))
    }
    private func selection() throws -> GoogleCloudStorageSelection {
        try GoogleCloudStorageSelection(projectID: "test-project", projectNumber: "123", bucket: "test-bucket")
    }
    private func remote(readOnly: Bool = false) throws -> RemoteConfig {
        RemoteConfig(name: "Test", provider: .googleCloudStorage, bucketOrRootPath: "test-bucket", keychainAccountKey: "test-key", googleCloudStorage: try selection(), isReadOnly: readOnly)
    }
    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }
    override func tearDown() { http.handler = nil }

    func testSelectionRejectsAccountRootAndPaths() {
        for value in ["", "/", "bucket/folder", "../other-bucket", "gs://bucket", "Uppercase", "a", "abc\0"] {
            XCTAssertThrowsError(try GoogleCloudStorageSelection.validateBucket(value), value)
        }
    }
    func testDescriptorRequiresMatchingBucket() throws {
        var config = try remote()
        config.bucketOrRootPath = "other-bucket"
        XCTAssertThrowsError(try FileProviderConnectionDescriptor(remote: config))
        config.bucketOrRootPath = ""
        XCTAssertThrowsError(try FileProviderConnectionDescriptor(remote: config))
    }
    func testCredentialUsesOnlyGCSAndMemoryOptions() throws {
        let value = try selection().credential(authorization: authorization(), remoteName: "Test")
        XCTAssertEqual(value.provider, .googleCloudStorage)
        XCTAssertEqual(value.backendOptions["type"], "google cloud storage")
        XCTAssertEqual(value.backendOptions["directory_markers"], "true")
        XCTAssertEqual(value.backendOptions["no_check_bucket"], "true")
        XCTAssertEqual(value.backendOptions["bucket_policy_only"], "true")
        XCTAssertNil(value.backendOptions["service_account_file"])
        let encoded = try JSONEncoder().encode(remote())
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("test-refresh"))
    }
    func testPathsCannotEscapeBucketOrMutateRoot() {
        for value in ["../other", "folder/../../other", "/other-bucket", "", "folder\0"] {
            XCTAssertThrowsError(try GoogleCloudStorageFileProviderBackend.normalizedPath(value, allowRoot: false))
        }
    }
    func testProjectsPaginationAndActiveFiltering() async throws {
        http.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "pageToken" }) {
                return self.reply(request, "{\"projects\":[{\"name\":\"projects/456\",\"projectId\":\"second\",\"state\":\"DELETE_REQUESTED\"}]}")
            }
            return self.reply(request, "{\"projects\":[{\"name\":\"projects/123\",\"projectId\":\"test-project\",\"displayName\":\"Test\",\"state\":\"ACTIVE\"}],\"nextPageToken\":\"next\"}")
        }
        let result = try await GoogleCloudDiscoveryService(session: session()).projects(authorization: .googleAccount(authorization()))
        XCTAssertEqual(result.map(\.id), ["test-project"])
    }
    func testBucketsAreFilteredByProjectAndPaginated() async throws {
        let project = try JSONDecoder().decode(GoogleCloudProject.self, from: Data("{\"name\":\"projects/123\",\"projectId\":\"test-project\"}".utf8))
        http.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "project" }?.value, "test-project")
            if query.contains(where: { $0.name == "pageToken" }) {
                return self.reply(request, "{\"items\":[{\"name\":\"wrong-project\",\"projectNumber\":\"456\"}]}")
            }
            return self.reply(request, "{\"items\":[{\"name\":\"test-bucket\",\"projectNumber\":\"123\"}],\"nextPageToken\":\"next\"}")
        }
        let buckets = try await GoogleCloudDiscoveryService(session: session()).buckets(project: project, authorization: .googleAccount(authorization()))
        XCTAssertEqual(buckets.map(\.name), ["test-bucket"])
    }
    func testDiscovery403IsActionable() async throws {
        http.handler = { self.reply($0, "{}", status: 403) }
        do {
            _ = try await GoogleCloudDiscoveryService(session: session()).projects(authorization: .googleAccount(authorization()))
            XCTFail("Expected IAM failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("IAM")) }
    }
    func testDisabledResourceManagerShowsExactAPI() async throws {
        http.handler = { request in
            self.reply(request, "{\"error\":{\"details\":[{\"reason\":\"SERVICE_DISABLED\",\"metadata\":{\"service\":\"cloudresourcemanager.googleapis.com\"}}]}}", status: 403)
        }
        do {
            _ = try await GoogleCloudDiscoveryService(session: session()).projects(authorization: .googleAccount(authorization()))
            XCTFail("Expected disabled API")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .apiDisabled("Cloud Resource Manager API")) }
    }
    func testMissingScopeDoesNotSuggestIAMChanges() async throws {
        http.handler = { request in
            self.reply(request, "{\"error\":{\"details\":[{\"reason\":\"ACCESS_TOKEN_SCOPE_INSUFFICIENT\"}]}}", status: 403)
        }
        do {
            _ = try await GoogleCloudDiscoveryService(session: session()).projects(authorization: .googleAccount(authorization()))
            XCTFail("Expected scope failure")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .insufficientScope) }
    }

    func testReadWriteValidationRejectsMissingDeletePermission() async throws {
        http.handler = { request in
            if request.url!.path.hasSuffix("testPermissions") {
                return self.reply(request, "{\"permissions\":[\"storage.objects.list\",\"storage.objects.get\",\"storage.objects.create\"]}")
            }
            return self.reply(request, "{\"name\":\"test-bucket\",\"projectNumber\":\"123\"}")
        }
        do {
            try await GoogleCloudDiscoveryService(session: session()).validate(selection: selection(), authorization: .googleAccount(authorization()), readOnly: false)
            XCTFail("Expected missing delete permission")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .missingPermissions(["storage.objects.delete"])) }
        try await GoogleCloudDiscoveryService(session: session()).validate(selection: selection(), authorization: .googleAccount(authorization()), readOnly: true)
    }
    func testBucketOwnershipCheckedBeforeRegistration() async throws {
        http.handler = { self.reply($0, "{\"name\":\"test-bucket\",\"projectNumber\":\"456\"}") }
        do {
            try await GoogleCloudDiscoveryService(session: session()).validate(selection: selection(), authorization: .googleAccount(authorization()), readOnly: false)
            XCTFail("Expected project mismatch")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .bucketMismatch) }
    }
    func testReadOnlyBackendRejectsMutationBeforeNetwork() async throws {
        let descriptor = try FileProviderConnectionDescriptor(remote: remote(readOnly: true))
        let backend = try GoogleCloudStorageFileProviderBackend(connection: descriptor)
        do { try await backend.createDirectory(at: "folder"); XCTFail("Expected read-only failure") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
    }
    func testEveryListIsRootedInSelectedBucket() async throws {
        let descriptor = try FileProviderConnectionDescriptor(remote: remote())
        let credential = try selection().credential(authorization: authorization(), remoteName: "Test")
        http.handler = { request in
            let stream = request.httpBodyStream!
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
            let payload = try JSONDecoder().decode(RcloneListRequest.self, from: data)
            XCTAssertEqual(payload.fs, credential.fileSystemReference(root: "test-bucket", additionalOptions: ["directory_markers": "true", "decompress": "false", "no_check_bucket": "true", "bucket_policy_only": "true", "bucket_acl": "", "object_acl": ""]))
            return self.reply(request, "{\"list\":[]}")
        }
        let client = RcloneClient(port: 5572, urlSession: session(), credentialProvider: testRPCCredentialProvider)
        let backend = try GoogleCloudStorageFileProviderBackend(connection: descriptor, client: client, credential: credential)
        _ = try await backend.listChildren(at: "folder")
    }
    func testFailedDirectoryCopyNeverDeletesSource() async throws {
        let descriptor = try FileProviderConnectionDescriptor(remote: remote())
        let credential = try selection().credential(authorization: authorization(), remoteName: "Test")
        let rc = MoveRC(); rc.directory("source"); rc.file("source/file.txt", size: 10)
        rc.failOnce = "/operations/copyfile:source/file.txt"
        http.handler = rc.handle
        let journalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let backend = try GoogleCloudStorageFileProviderBackend(connection: descriptor, client: RcloneClient(port: 5572, urlSession: session(), credentialProvider: testRPCCredentialProvider), credential: credential)
        do { try await backend.move(from: "source", to: "destination"); XCTFail("Expected copy failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("injected failure")) }
        XCTAssertTrue(rc.deletes.isEmpty); XCTAssertNotNil(rc.items["source/file.txt"])
    }

    @MainActor
    func testReaddingBucketKeepsDomainIdentityAndCachedMount() throws {
        let original = try remote()
        let defaults = EphemeralUserDefaults()
        let domainStore = FileProviderDomainStore(defaults: defaults)
        try domainStore.upsert(try FileProviderConnectionDescriptor(remote: original))
        let registry = FileProviderDomainRegistry(store: domainStore, manager: MockFileProviderManager())
        let state = AppState(remotes: [original], remoteStore: RemoteConfigStore(defaults: defaults), domainRegistry: registry)
        state.updateStatus(.mounted(mountedAt: Date(), mountPoint: "/test"), for: original.id)
        var replacement = try remote()
        replacement.keychainAccountKey = "replacement-key"
        replacement.name = "Renamed bucket connection"
        let saved = state.addRemote(replacement)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(state.remotes.count, 1)
        XCTAssertEqual(state.remotes.first?.keychainAccountKey, "replacement-key")
        XCTAssertTrue(state.status(for: original.id).isMounted)
        XCTAssertEqual(try registry.connection(for: original.id)?.keychainAccountKey, "replacement-key")
    }

    @MainActor
    func testUpdateCannotRebindBucket() throws {
        let config = try remote()
        let state = AppState(remotes: [config], remoteStore: RemoteConfigStore(defaults: EphemeralUserDefaults()))
        var changed = config; changed.bucketOrRootPath = "another-bucket"
        state.updateRemote(changed)
        XCTAssertEqual(state.remotes.first?.bucketOrRootPath, "test-bucket")
        XCTAssertNotNil(state.lastError)
    }
}
