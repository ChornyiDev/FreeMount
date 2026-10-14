import XCTest
@testable import FreeMount

final class GoogleCloudHealthDiagnosticTests: XCTestCase {
    private func classify(_ status: Int, _ reason: String = "forbidden") -> ConnectionDiagnostic {
        GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: "listing failed: googleapi: Error \(status): failed, \(reason)"), mode: .googleAccount)
    }
    func testUpstreamStatusRemainsSeparateFromRCAndGetsTargetedRecovery() {
        for (code, kind) in [(401, ConnectionDiagnostic.Kind.authorization), (403, .permissions), (404, .resourceMissing), (429, .quota), (503, .serviceUnavailable)] {
            let issue = classify(code)
            XCTAssertEqual(issue.kind, kind)
            XCTAssertEqual(issue.rcStatus, 500); XCTAssertEqual(issue.upstreamStatus, code)
            XCTAssertFalse(issue.recovery.isEmpty)
            XCTAssertNotEqual(ConnectionHealth.issue(issue).statusLabel, "Offline")
        }
    }
    func testUnrelated401NumbersNeverRequireGoogleReauthorization() {
        for message in ["bucket-401 failed", "request 1401 failed", "googleapi: Error 4010: not a status", "RC status 401 occurred in user filename"] {
            let diagnostic = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: message), mode: .googleAccount)
            XCTAssertEqual(diagnostic.kind, .unknown)
            XCTAssertNil(diagnostic.upstreamStatus)
            XCTAssertEqual(diagnostic.technicalReason, "rclone RC error (500): " + message)
        }
    }
    func testLocalAuthenticationAndRC403DoNotMasqueradeAsGoogleErrors() {
        for error: Error in [RcloneRPCAuthenticationError.authenticationRejected, FreeMountError.rcloneError(statusCode: 401, message: "denied")] {
            let issue = GoogleCloudHealthDiagnostic.classify(error, mode: .googleAccount)
            XCTAssertEqual(issue.kind, .localRuntime); XCTAssertNil(issue.upstreamStatus)
            XCTAssertTrue(issue.recovery.contains("FreeMount"))
        }
        let rcOnly = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 403, message: "denied"), mode: .googleAccount)
        XCTAssertEqual(rcOnly.kind, .unknown); XCTAssertNil(rcOnly.upstreamStatus)
    }
    func testSpecificBillingQuotaAndAPIFailuresOverrideGenericDenial() {
        for reason in ["userProjectMissing", "UserProjectAccessDenied", "UserProjectAccountProblem", "accountDisabled", "userProjectInvalid"] {
            let issue = classify(403, reason)
            XCTAssertEqual(issue.kind, .billing); XCTAssertTrue(issue.recovery.contains("billing project"))
        }
        XCTAssertEqual(classify(403, "rateLimitExceeded").kind, .quota)
        XCTAssertEqual(classify(403, "accessNotConfigured").kind, .apiDisabled)
        let details = "googleapi: Error 403: disabled\nDetails:\n[{\"reason\":\"SERVICE_DISABLED\"}]\n, forbidden"
        let issue = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: details), mode: .googleAccount)
        XCTAssertEqual(issue.kind, .apiDisabled)
    }
    func testRevokedOAuthAndInvalidKeysGetModeAppropriateRecovery() {
        let message = "failed to refresh: oauth2: cannot fetch token: 400 Bad Request\nResponse: {\"error\":\"invalid_grant\"}"
        let oauth = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: message), mode: .googleAccount)
        XCTAssertEqual(oauth.kind, .authorization); XCTAssertEqual(oauth.upstreamStatus, 400)
        XCTAssertTrue(oauth.recovery.contains("Re-authorize"))
        let key = GoogleCloudHealthDiagnostic.classify(GoogleCloudServiceAccountError.invalidKey, mode: .serviceAccount)
        XCTAssertEqual(key.kind, .authorization); XCTAssertTrue(key.recovery.contains("Replace"))
        XCTAssertEqual(GoogleCloudHealthDiagnostic.classify(GoogleCloudServiceAccountError.tokenRejected(429), mode: .serviceAccount).kind, .quota)
        XCTAssertEqual(GoogleCloudHealthDiagnostic.classify(GoogleCloudServiceAccountError.tokenRejected(503), mode: .serviceAccount).kind, .serviceUnavailable)
    }
    func testKeychainDenialDoesNotAskUserToDiscardCredential() {
        let denied = GoogleCloudHealthDiagnostic.classify(KeychainError.operationFailed(operation: "load", status: -25308, message: "locked"), mode: .serviceAccount)
        XCTAssertEqual(denied.kind, .credentialStorage)
        XCTAssertTrue(denied.recovery.contains("Keep")); XCTAssertFalse(denied.recovery.contains("Replace"))
        let absent = GoogleCloudHealthDiagnostic.classify(KeychainError.itemNotFound(account: "fixture"), mode: .serviceAccount)
        XCTAssertEqual(absent.kind, .authorization)
    }
    func testOfflineAndMissingBucketAfterRcloneStatusLoss() {
        XCTAssertEqual(GoogleCloudHealthDiagnostic.classify(URLError(.notConnectedToInternet), mode: nil).kind, .network)
        let offline = FreeMountError.rcloneError(statusCode: 500, message: "listing failed: dial tcp: network is unreachable")
        XCTAssertEqual(GoogleCloudHealthDiagnostic.classify(offline, mode: nil).kind, .network)
        let missing = FreeMountError.rcloneError(statusCode: 500, message: "error in ListJSON: directory not found")
        let issue = GoogleCloudHealthDiagnostic.classify(missing, mode: nil)
        XCTAssertEqual(issue.kind, .resourceMissing); XCTAssertNil(issue.upstreamStatus)
    }
    func testTechnicalDetailsAreRedactedBeforeRetentionAndBounded() {
        let secret = "googleapi: Error 403: denied access_token=private-token refresh_token=refresh-secret Authorization: Bearer bearer-secret private_key=\"-----BEGIN PRIVATE KEY-----\\nkeybytes\\n-----END PRIVATE KEY-----\", forbidden"
        let issue = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: secret), mode: nil)
        for value in ["private-token", "refresh-secret", "bearer-secret", "keybytes"] { XCTAssertFalse(issue.technicalReason.contains(value)) }
        XCTAssertTrue(issue.technicalReason.contains("<redacted>"))
        let long = GoogleCloudHealthDiagnostic.classify(FreeMountError.unexpectedResponse(String(repeating: "x", count: 10000)), mode: nil)
        XCTAssertLessThanOrEqual(long.technicalReason.count, 2048)
    }
    func testEncodedInlineCredentialIsNeverExposedByTechnicalDetails() throws {
        struct Credential: Encodable { let access_token: String; let refresh_token: String }
        struct Wrapper: Encodable { let token: String; let service_account_credentials: String }
        let inner = String(decoding: try JSONEncoder().encode(Credential(access_token: "nested-access-secret", refresh_token: "nested-refresh-secret")), as: UTF8.self)
        let encoded = String(decoding: try JSONEncoder().encode(Wrapper(token: inner, service_account_credentials: "nested-account-secret")), as: UTF8.self)
        let issue = GoogleCloudHealthDiagnostic.classify(FreeMountError.rcloneError(statusCode: 500, message: encoded), mode: nil)
        for value in ["nested-access-secret", "nested-refresh-secret", "nested-account-secret"] { XCTAssertFalse(issue.technicalReason.contains(value)) }
    }
    @MainActor
    func testHealthRefreshKeepsDomainMountedAndRecoversWithoutReplacingCredential() async throws {
        let remote = RemoteConfig(name: "Test", provider: .googleCloudStorage, bucketOrRootPath: "test-bucket", keychainAccountKey: "fixture", googleCloudStorage: try .init(directBucket: "test-bucket"))
        let probe = HealthProbe()
        let state = AppState(remotes: [remote], remoteStore: .init(defaults: EphemeralUserDefaults()), gcsHealthChecker: .init(probe: { _ in try await probe.check() }))
        state.updateStatus(.mounted(mountedAt: Date(), mountPoint: "/fixture"), for: remote.id)
        let failed = await state.refreshConnectionHealth(for: remote)
        guard case .issue(let diagnostic) = failed else { return XCTFail("Expected diagnostic") }
        XCTAssertEqual(diagnostic.kind, .permissions); XCTAssertTrue(state.status(for: remote.id).isMounted)
        await probe.recover()
        let healthy = await state.refreshConnectionHealth(for: remote)
        XCTAssertTrue(healthy.isHealthy); XCTAssertTrue(state.status(for: remote.id).isMounted)
        XCTAssertEqual(state.remotes.first?.keychainAccountKey, "fixture")
    }
    @MainActor
    func testOlderFailureCannotOverwriteNewerSuccessfulHealthCheck() async throws {
        let remote = RemoteConfig(name: "Test", provider: .googleCloudStorage, bucketOrRootPath: "test-bucket", keychainAccountKey: "fixture", googleCloudStorage: try .init(directBucket: "test-bucket"))
        let probe = OrderedProbe()
        let state = AppState(remotes: [remote], remoteStore: .init(defaults: EphemeralUserDefaults()), gcsHealthChecker: .init(probe: { _ in try await probe.wait() }))
        let older = Task { await state.refreshConnectionHealth(for: remote) }
        await probe.waitForCount(1)
        let newer = Task { await state.refreshConnectionHealth(for: remote) }
        await probe.waitForCount(2)
        await probe.finish(1)
        let success = await newer.value; XCTAssertTrue(success.isHealthy)
        await probe.finish(0, error: .rcloneError(statusCode: 500, message: "googleapi: Error 401: expired"))
        let obsolete = await older.value; XCTAssertEqual(obsolete, .unknown)
        XCTAssertTrue(state.health(for: remote.id).isHealthy)
    }
    private actor OrderedProbe {
        var waiters: [CheckedContinuation<Void, Error>] = []
        func wait() async throws { try await withCheckedThrowingContinuation { waiters.append($0) } }
        func waitForCount(_ count: Int) async {
            for _ in 0..<1000 {
                if waiters.count >= count { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("Health probe did not start")
        }
        func finish(_ index: Int, error: FreeMountError? = nil) {
            guard waiters.indices.contains(index) else { return }
            if let error { waiters[index].resume(throwing: error) } else { waiters[index].resume() }
        }
    }
    private actor HealthProbe {
        var failed = true
        func recover() { failed = false }
        func check() throws {
            if failed { throw FreeMountError.rcloneError(statusCode: 500, message: "googleapi: Error 403: denied, forbidden") }
        }
    }
}
