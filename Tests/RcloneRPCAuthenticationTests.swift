import XCTest
import Security
@testable import FreeMount

let testRPCCredentialProvider: @Sendable () async throws -> RcloneRPCredentials = {
    try RcloneRPCredentials(password: String(repeating: "a", count: 64))
}

final class MemoryRPCPersistence: RcloneRPCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    let failure: RcloneRPCAuthenticationError?
    init(data: Data? = nil, failure: RcloneRPCAuthenticationError? = nil) { self.data = data; self.failure = failure }
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }; return data
    }
    func insert(_ data: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard self.data == nil else { return false }
        self.data = data; return true
    }
}

extension RcloneRPCredentialStore {
    static let testShared = RcloneRPCredentialStore(persistence: MemoryRPCPersistence())
}

final class RcloneRPCAuthenticationTests: XCTestCase {
    private let http = MockHTTPRouter()
    override func tearDown() { http.handler = nil }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; http.configure(config)
        return URLSession(configuration: config)
    }
    func testMissingCredentialFailsWithoutInitialization() async throws {
        let store = RcloneRPCredentialStore(persistence: MemoryRPCPersistence())
        do { _ = try await store.load(); XCTFail("Expected host initialization") }
        catch { XCTAssertEqual(error as? RcloneRPCAuthenticationError, .missingCredential) }
    }
    func testIndependentStoresAndConcurrentInitializationShareOneSecret() async throws {
        let persistence = MemoryRPCPersistence()
        let stores = (0..<20).map { _ in RcloneRPCredentialStore(persistence: persistence) }
        let credentials = try await withThrowingTaskGroup(of: RcloneRPCredentials.self) { group in
            for store in stores { group.addTask { try await store.loadOrCreate() } }
            var values: [RcloneRPCredentials] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(credentials.count, 20)
        XCTAssertTrue(credentials.allSatisfy { $0 == credentials[0] })
        let reloaded = try await RcloneRPCredentialStore(persistence: persistence).load()
        XCTAssertEqual(reloaded, credentials[0])
    }
    func testInvalidOrDeniedKeychainIsNeverOverwritten() async throws {
        for persistence in [MemoryRPCPersistence(data: Data("{\"password\":\"weak\"}".utf8)), MemoryRPCPersistence(failure: .keychain(errSecInteractionNotAllowed))] {
            let store = RcloneRPCredentialStore(persistence: persistence)
            do { _ = try await store.loadOrCreate(); XCTFail("Must fail closed") }
            catch { XCTAssertTrue(error is RcloneRPCAuthenticationError) }
        }
    }
    func testLaunchKeepsSecretsOutOfArgumentsAndDisablesInheritedOptions() async throws {
        let credential = try await testRPCCredentialProvider()
        let arguments = RcloneDaemonLaunch.arguments(port: 5572)
        XCTAssertFalse(arguments.contains { $0.contains("no-auth") || $0.contains(String(repeating: "a", count: 64)) })
        let environment = RcloneDaemonLaunch.environment(inherited: ["RCLONE_RC_NO_AUTH": "true", "RCLONE_RC_WEB_GUI": "true", "RCLONE_LOG_LEVEL": "DEBUG", "PATH": "/test"])
        XCTAssertNil(environment["RCLONE_RC_NO_AUTH"])
        XCTAssertNil(environment["RCLONE_RC_WEB_GUI"])
        XCTAssertNil(environment["RCLONE_LOG_LEVEL"])
        XCTAssertEqual(environment["PATH"], "/test")
        XCTAssertNil(environment["RCLONE_RC_PASS"])
        let pipe = try RcloneDaemonLaunch.authenticationInput(credentials: credential)
        let input = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(input, credential.htpasswdData)
        XCTAssertTrue(String(decoding: input, as: UTF8.self).hasPrefix("freemount:{SHA}"))
        XCTAssertFalse(String(decoding: input, as: UTF8.self).contains(String(repeating: "a", count: 64)))
        XCTAssertFalse(String(reflecting: credential).contains(String(repeating: "a", count: 64)))
    }
    func testAuthenticatedRequestsUseHeaderAndSanitizeRejection() async throws {
        let credential = try await testRPCCredentialProvider()
        http.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), credential.authorizationHeader)
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data(credential.authorizationHeader.utf8))
        }
        let client = RcloneClient(port: 5572, urlSession: session(), credentialProvider: testRPCCredentialProvider)
        do { try await client.noop(); XCTFail("Expected rejected credential") }
        catch { XCTAssertEqual(error as? RcloneRPCAuthenticationError, .authenticationRejected) }
    }
    func testLegacyNoAuthServerIsNeverAdopted() async throws {
        http.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
        let client = RcloneClient(port: 5572, urlSession: session(), credentialProvider: testRPCCredentialProvider)
        do { _ = try await client.authenticatedEndpointIsReachable(); XCTFail("Unsafe endpoint") }
        catch { XCTAssertEqual(error as? RcloneRPCAuthenticationError, .unprotectedEndpoint) }
    }
    func testRemoteEndpointRejectedBeforeCredentialOrNetwork() async throws {
        let client = RcloneClient(baseURL: URL(string: "http://example.com:5572")!, urlSession: session(), credentialProvider: { XCTFail("Do not read secret"); throw RcloneRPCAuthenticationError.missingCredential })
        do { try await client.noop(); XCTFail("Non-local endpoint") }
        catch { XCTAssertEqual(error as? RcloneRPCAuthenticationError, .nonLoopbackEndpoint) }
    }
    func testBasicAuthorizationAndEnvironmentPasswordAreRedacted() {
        let redacted = CredentialRedactor.redact("Authorization=Basic abc123 RCLONE_RC_PASS=secret123 \"Authorization\":\"Basic other456\"")
        XCTAssertFalse(redacted.contains("abc123")); XCTAssertFalse(redacted.contains("secret123")); XCTAssertFalse(redacted.contains("other456"))
    }
    func testRealDaemonRejectsAnonymousAndWrongCredentials() async throws {
        let store = RcloneRPCredentialStore(persistence: MemoryRPCPersistence())
        let port = 58_327
        let supervisor = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: store)
        do {
            let client = try await supervisor.startDaemon()
            let session = RcloneTransportDelegate.makeSession()
            for endpoint in ["rc/noop", "core/stats", "core/quit", "operations/deletefile"] {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(endpoint)")!)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, endpoint)
            }
            let wrong = RcloneClient(port: port, credentialProvider: testRPCCredentialProvider)
            do { try await wrong.noop(); XCTFail("Incorrect secret must be rejected") }
            catch { XCTAssertEqual(error as? RcloneRPCAuthenticationError, .authenticationRejected) }
            try await client.noop()
            let restarted = try await supervisor.restartDaemon()
            XCTAssertTrue(restarted.isRunning)
            await supervisor.stopDaemon()
        } catch {
            await supervisor.stopDaemon()
            throw error
        }
    }

}
