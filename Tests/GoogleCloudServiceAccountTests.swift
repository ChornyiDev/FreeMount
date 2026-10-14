import XCTest
import Security
@testable import FreeMount

final class GoogleCloudServiceAccountTests: XCTestCase {
    private let http = MockHTTPRouter()
    private struct KeyDocument: Encodable {
        var type = "service_account"
        var project_id = "test-project"
        var private_key_id = "test-key-id"
        var private_key: String
        var client_email = "test@test-project.iam.gserviceaccount.com"
        var token_uri = GoogleCloudServiceAccountKey.tokenEndpoint
    }

    private func generatedKey() throws -> (GoogleCloudServiceAccountKey, SecKey, KeyDocument) {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        let rsa = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let raw = try XCTUnwrap(SecKeyCopyExternalRepresentation(rsa, &error) as Data?)
        // Wrap PKCS#1 exported by Security in Google's PKCS#8 PrivateKeyInfo.
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let pkcs8 = der(tag: 0x30, content: Data([0x02, 0x01, 0x00]) + algorithm + der(tag: 0x04, content: raw))
        let document = KeyDocument(private_key: "-----BEGIN PRIVATE KEY-----\n\(pkcs8.base64EncodedString())\n-----END PRIVATE KEY-----\n")
        return (try GoogleCloudServiceAccountKey(data: JSONEncoder().encode(document)), rsa, document)
    }

    private func der(tag: UInt8, content: Data) -> Data {
        let length = content.count
        let prefix: [UInt8] = length < 128 ? [tag, UInt8(length)] : [tag, 0x82, UInt8(length >> 8), UInt8(length & 255)]
        return Data(prefix) + content
    }

    private func decodeURL64(_ string: String) throws -> Data {
        var value = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: value))
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        http.configure(config)
        return URLSession(configuration: config)
    }

    private func reply(_ request: URLRequest, _ json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func tokenReply(_ request: URLRequest, expires: Int = 3600) -> (HTTPURLResponse, Data) {
        reply(request, "{\"access_token\":\"service-token\",\"token_type\":\"Bearer\",\"expires_in\":\(expires)}")
    }

    override func tearDown() { http.handler = nil }

    func testRS256AssertionHasExpectedClaimsAndValidSignature() throws {
        let (key, rsa, _) = try generatedKey()
        let assertion = try key.assertion(at: Date(timeIntervalSince1970: 1_700_000_000), scopes: ["scope-a", "scope-b"])
        let parts = assertion.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        struct Header: Decodable { let alg: String; let typ: String; let kid: String }
        struct Claims: Decodable { let iss: String; let aud: String; let scope: String; let iat: Int; let exp: Int; let sub: String? }
        let header = try JSONDecoder().decode(Header.self, from: decodeURL64(parts[0]))
        XCTAssertEqual(header.alg, "RS256")
        XCTAssertEqual(header.typ, "JWT")
        XCTAssertEqual(header.kid, "test-key-id")
        let claims = try JSONDecoder().decode(Claims.self, from: decodeURL64(parts[1]))
        XCTAssertEqual(claims.iss, key.email)
        XCTAssertEqual(claims.aud, GoogleCloudServiceAccountKey.tokenEndpoint)
        XCTAssertEqual(claims.scope, "scope-a scope-b")
        XCTAssertEqual(claims.exp - claims.iat, 3600)
        XCTAssertNil(claims.sub)
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(rsa))
        var error: Unmanaged<CFError>?
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(parts[0]).\(parts[1])".utf8) as CFData, try decodeURL64(parts[2]) as CFData, &error))
    }

    func testImportRejectsInvalidDocumentsAndForeignEndpoints() throws {
        XCTAssertThrowsError(try GoogleCloudServiceAccountKey(data: Data("{}".utf8)))
        XCTAssertThrowsError(try GoogleCloudServiceAccountKey(data: Data(repeating: 0, count: GoogleCloudServiceAccountKey.maximumFileSize + 1)))
        let (_, _, document) = try generatedKey()
        var invalid = document
        invalid.token_uri = "https://example.com/steal-key"
        XCTAssertThrowsError(try GoogleCloudServiceAccountKey(data: JSONEncoder().encode(invalid))) { error in
            XCTAssertEqual(error as? GoogleCloudServiceAccountError, .unsupportedEndpoint)
        }
        invalid = document
        invalid.type = "authorized_user"
        XCTAssertThrowsError(try GoogleCloudServiceAccountKey(data: JSONEncoder().encode(invalid)))
        invalid = document
        invalid.private_key = "-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----"
        XCTAssertThrowsError(try GoogleCloudServiceAccountKey(data: JSONEncoder().encode(invalid))) { error in
            XCTAssertEqual(error as? GoogleCloudServiceAccountError, .invalidKey)
        }
    }

    func testTokenExchangeUsesFixedEndpointAndCachesBearerToken() async throws {
        let (key, _, _) = try generatedKey()
        var requests = 0
        http.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, GoogleCloudServiceAccountKey.tokenEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return self.tokenReply(request)
        }
        let service = GoogleCloudServiceAccountTokenService(session: session())
        let first = try await service.accessToken(for: key)
        let second = try await service.accessToken(for: key)
        XCTAssertEqual(first, "service-token")
        XCTAssertEqual(first, second)
        XCTAssertEqual(requests, 1)
    }

    func testExpiringTokenIsRefreshed() async throws {
        let (key, _, _) = try generatedKey()
        var requests = 0
        http.handler = { request in
            requests += 1
            return self.tokenReply(request, expires: 1)
        }
        let service = GoogleCloudServiceAccountTokenService(session: session())
        _ = try await service.accessToken(for: key)
        _ = try await service.accessToken(for: key)
        XCTAssertEqual(requests, 2)
    }

    func testRevokedKeyErrorDoesNotExposeServerEchoOfSecret() async throws {
        let (key, _, _) = try generatedKey()
        http.handler = { self.reply($0, "{\"error_description\":\"sensitive-server-echo\"}", status: 400) }
        do {
            _ = try await GoogleCloudServiceAccountTokenService(session: session()).accessToken(for: key)
            XCTFail("Expected revoked key rejection")
        } catch {
            XCTAssertEqual(error as? GoogleCloudServiceAccountError, .tokenRejected(400))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-server-echo"))
        }
    }

    func testDirectBucketWorksWithoutDiscoveryOrBucketMetadataPermissions() async throws {
        let (key, _, _) = try generatedKey()
        let authorization = GoogleCloudAuthorization.serviceAccount(key)
        var paths: [String] = []
        http.handler = { request in
            if request.url?.absoluteString == GoogleCloudServiceAccountKey.tokenEndpoint { return self.tokenReply(request) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer service-token")
            paths.append(request.url!.path)
            if request.url!.path.hasSuffix("/testPermissions") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains { $0.value == "storage.objects.create" })
                return self.reply(request, "{\"permissions\":[\"storage.objects.list\",\"storage.objects.get\",\"storage.objects.create\",\"storage.objects.delete\"]}")
            }
            return self.reply(request, "{}", status: 403)
        }
        let discovery = GoogleCloudDiscoveryService(session: session())
        let selection = try await discovery.directSelection(bucket: "private-bucket", billingProject: nil, authorization: authorization)
        XCTAssertEqual(selection.selectionMode, .directBucket)
        XCTAssertEqual(selection.projectNumber, "")
        try await discovery.validate(selection: selection, authorization: authorization, readOnly: false)
        XCTAssertEqual(paths, ["/storage/v1/b/private-bucket", "/storage/v1/b/private-bucket/iam/testPermissions"])
    }

    func testDirectBucketRejectsMissingWritePermission() async throws {
        let (key, _, _) = try generatedKey()
        http.handler = { request in
            if request.url?.absoluteString == GoogleCloudServiceAccountKey.tokenEndpoint { return self.tokenReply(request) }
            return self.reply(request, "{\"permissions\":[\"storage.objects.list\",\"storage.objects.get\"]}")
        }
        let selection = try GoogleCloudStorageSelection(directBucket: "private-bucket")
        let discovery = GoogleCloudDiscoveryService(session: session())
        try await discovery.validate(selection: selection, authorization: .serviceAccount(key), readOnly: true)
        do {
            try await discovery.validate(selection: selection, authorization: .serviceAccount(key), readOnly: false)
            XCTFail("Expected missing write permissions")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .missingPermissions(["storage.objects.create", "storage.objects.delete"])) }
    }

    func testMetadata404IsNotTreatedAsObjectOnlyAccess() async throws {
        let (key, _, _) = try generatedKey()
        http.handler = { request in
            if request.url?.absoluteString == GoogleCloudServiceAccountKey.tokenEndpoint { return self.tokenReply(request) }
            return self.reply(request, "{}", status: 404)
        }
        do {
            _ = try await GoogleCloudDiscoveryService(session: session()).directSelection(bucket: "private-bucket", billingProject: nil, authorization: .serviceAccount(key))
            XCTFail("Expected missing bucket")
        } catch { XCTAssertEqual(error as? GoogleCloudStorageError, .apiFailure(status: 404, operation: "bucket validation (storage.buckets.get)")) }
    }

    func testCredentialContainsInlineKeyButPersistedRemoteContainsOnlyIdentity() throws {
        let (key, _, document) = try generatedKey()
        let authorization = GoogleCloudAuthorization.serviceAccount(key)
        let selection = try GoogleCloudStorageSelection(directBucket: "private-bucket")
        let credential = try authorization.credential(selection: selection, remoteName: "Private bucket")
        XCTAssertNil(credential.backendOptions["token"])
        XCTAssertNil(credential.backendOptions["client_secret"])
        XCTAssertNil(credential.backendOptions["service_account_file"])
        XCTAssertNil(credential.backendOptions["project_number"])
        XCTAssertEqual(credential.backendOptions["bucket_policy_only"], "true")
        let imported = try GoogleCloudServiceAccountKey(data: Data(try XCTUnwrap(credential.backendOptions["service_account_credentials"]).utf8))
        XCTAssertEqual(imported, key)
        let remote = RemoteConfig(name: "Private bucket", provider: .googleCloudStorage, bucketOrRootPath: selection.bucket, keychainAccountKey: "test-key", googleCloudStorage: selection, googleCloudAuthentication: authorization.identity)
        let data = try JSONEncoder().encode(remote)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private_key"))
        XCTAssertFalse(json.contains(document.private_key))
        XCTAssertEqual(try JSONDecoder().decode(RemoteConfig.self, from: data), remote)
        XCTAssertEqual(try FileProviderConnectionDescriptor(remote: remote).rootPath, "private-bucket")
    }

    func testKeychainRoundTripUsesIsolatedService() async throws {
        let (key, _, _) = try generatedKey()
        let credential = try GoogleCloudAuthorization.serviceAccount(key).credential(selection: GoogleCloudStorageSelection(directBucket: "private-bucket"), remoteName: "Test")
        let keychain = KeychainService(serviceName: "com.freemount.tests.service-account.\(UUID().uuidString)", storage: .legacy)
        let account = "test"
        try await keychain.saveCredential(credential, account: account)
        do {
            let loaded = try await keychain.loadCredential(account: account)
            XCTAssertEqual(loaded, credential)
            let replacement = RcloneRemoteCredential(remoteName: "Replacement", provider: credential.provider, backendOptions: credential.backendOptions)
            try await keychain.replaceCredential(replacement, account: account)
            let updated = try await keychain.loadCredential(account: account)
            XCTAssertEqual(updated, replacement)
        } catch {
            try await keychain.deleteCredential(account: account)
            throw error
        }
        try await keychain.deleteCredential(account: account)
    }

    func testReplacementKeyCanNarrowMetadataAccessForKnownBucket() async throws {
        let (key, _, _) = try generatedKey()
        http.handler = { request in
            if request.url?.absoluteString == GoogleCloudServiceAccountKey.tokenEndpoint { return self.tokenReply(request) }
            if request.url!.path.hasSuffix("/testPermissions") {
                return self.reply(request, "{\"permissions\":[\"storage.objects.list\",\"storage.objects.get\"]}")
            }
            return self.reply(request, "{}", status: 403)
        }
        let selection = try GoogleCloudStorageSelection(projectID: "test-project", projectNumber: "123", bucket: "private-bucket")
        try await GoogleCloudDiscoveryService(session: session()).validate(selection: selection, authorization: .serviceAccount(key), readOnly: true)
    }

    func testRcloneErrorsAreRedactedBeforeTheyReachUI() async throws {
        let (key, _, _) = try generatedKey()
        struct ServerError: Encodable { let error: String }
        let encoded = try JSONEncoder().encode(ServerError(error: "Failed inline credential: " + key.json()))
        http.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, encoded)
        }
        let client = RcloneClient(port: 5572, urlSession: session(), credentialProvider: testRPCCredentialProvider)
        do {
            _ = try await client.list(fs: .configuration(["type": "google cloud storage", "_root": "private-bucket"]), path: "")
            XCTFail("Expected RC error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("END PRIVATE KEY"))
            XCTAssertTrue(error.localizedDescription.contains("redacted"))
        }
    }

    func testPrivateKeysAreRedactedFromActivityErrors() {
        let pem = "-----BEGIN PRIVATE KEY-----\nsecret-key-body\n-----END PRIVATE KEY-----"
        let escaped = "{\"private_key\":\"-----BEGIN PRIVATE KEY-----\\nsecret-key-body\\n-----END PRIVATE KEY-----\\n\"}"
        for value in [pem, escaped, "{\"private_key\":\"non-pem-secret\"}"] {
            let sanitized = CredentialRedactor.redact(value)
            XCTAssertFalse(sanitized.contains("secret-key-body"))
            XCTAssertFalse(sanitized.contains("non-pem-secret"))
        }
    }
}
