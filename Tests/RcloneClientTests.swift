import XCTest
@testable import FreeMount

final class RcloneClientTests: XCTestCase {
    private let http = MockHTTPRouter()

    func testOfficialRuntimeCompletedTransfersDecodeLocalCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = directory.appendingPathComponent("source")
        let destination = directory.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 7, count: 1024).write(to: source.appendingPathComponent("sample.bin"))
        let supervisor = RcloneProcessSupervisor(port: Int.random(in: 58000..<59000),
            customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)
        do {
            let client = try await supervisor.startDaemon()
            try await client.copyFile(sourceFS: .named(source.path), sourcePath: "sample.bin",
                destinationFS: .named(destination.path), destinationPath: "sample.bin")
            let transferred = try await client.getCompletedTransfers()
            let completed = try XCTUnwrap(transferred.first { !$0.checked && $0.name == "sample.bin" })
            XCTAssertEqual(completed.size, 1024)
            XCTAssertGreaterThanOrEqual(completed.bytes, 0)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("sample.bin")), Data(repeating: 7, count: 1024))
            XCTAssertTrue(completed.error.isEmpty)
            XCTAssertNotNil(completed.completionDate)
            XCTAssertTrue(completed.group.hasPrefix("freemount."))
            let snapshot = await supervisor.telemetrySnapshot()
            XCTAssertTrue(snapshot.hasTransferStats)
            XCTAssertEqual(snapshot.completedTransfers?.count, transferred.count)
            await supervisor.stopDaemon()
        } catch {
            await supervisor.stopDaemon()
            throw error
        }
    }

    func testSupervisorStartsReachableLocalDaemon() async throws {
        let port = 58_321
        let supervisor = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        do {
            let client = try await supervisor.startDaemon()
            let version = try await client.getVersion()
            XCTAssertFalse(version.version.isEmpty)
            await supervisor.stopDaemon()
        } catch {
            await supervisor.stopDaemon()
            throw error
        }
    }

    func testConcurrentStartDaemonCallsShareSingleStartup() async throws {
        let port = 58_324
        let supervisor = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        do {
            async let first = supervisor.startDaemon()
            async let second = supervisor.startDaemon()
            let (c1, c2) = try await (first, second)

            let v1 = try await c1.getVersion()
            let v2 = try await c2.getVersion()
            XCTAssertEqual(v1.version, v2.version)
            await supervisor.stopDaemon()
        } catch {
            await supervisor.stopDaemon()
            throw error
        }
    }

    func testSupervisorStopsDaemonCleanly() async throws {
        let port = 58_325
        let supervisor = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        _ = try await supervisor.startDaemon()
        let statusBefore = await supervisor.daemonStatus()
        XCTAssertTrue(statusBefore.isRunning)

        let clean = await supervisor.stopDaemon(timeout: 1.5)
        XCTAssertTrue(clean)

        let statusAfter = await supervisor.daemonStatus()
        XCTAssertFalse(statusAfter.isRunning)
    }

    func testSupervisorRestartsDaemonStartedByAnotherSupervisor() async throws {
        let port = 58_322
        let owner = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)
        let adopter = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        do {
            _ = try await owner.startDaemon()
            let originalStatus = await adopter.daemonStatus()
            let restartedStatus = try await adopter.restartDaemon()

            XCTAssertTrue(originalStatus.isRunning)
            XCTAssertTrue(restartedStatus.isRunning)
            XCTAssertNotNil(originalStatus.pid)
            XCTAssertNotNil(restartedStatus.pid)
            XCTAssertNotEqual(originalStatus.pid, restartedStatus.pid)
            await adopter.stopDaemon()
        } catch {
            await adopter.stopDaemon()
            await owner.stopDaemon()
            throw error
        }
    }

    func testSupervisorRecoversAdoptedDaemonAfterItStops() async throws {
        let port = 58_323
        let owner = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)
        let adopter = RcloneProcessSupervisor(port: port, customBinaryPath: try testRcloneRuntimePath(), credentialStore: .testShared)

        do {
            _ = try await owner.startDaemon()
            let adoptedHealthyDaemon = try await adopter.ensureDaemonRunning()
            XCTAssertFalse(adoptedHealthyDaemon)

            await owner.stopDaemon()
            try await Task.sleep(for: .milliseconds(300))

            let recoveredDaemon = try await adopter.ensureDaemonRunning()
            let recoveredStatus = await adopter.daemonStatus()
            XCTAssertTrue(recoveredDaemon)
            XCTAssertTrue(recoveredStatus.isRunning)
            await adopter.stopDaemon()
        } catch {
            await adopter.stopDaemon()
            await owner.stopDaemon()
            throw error
        }
    }

    var urlSession: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        http.configure(configuration)
        urlSession = URLSession(configuration: configuration)
    }

    override func tearDown() {
        http.handler = nil
        urlSession = nil
        super.tearDown()
    }

    func testGetVersionSuccess() async throws {
        let json = """
        {
            "version": "v1.66.0",
            "decomposed": [1, 66, 0],
            "isGit": false,
            "os": "darwin",
            "arch": "arm64"
        }
        """

        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/core/version")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json.data(using: .utf8)!)
        }

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
        let version = try await client.getVersion()

        XCTAssertEqual(version.version, "v1.66.0")
        XCTAssertEqual(version.os, "darwin")
        XCTAssertEqual(version.arch, "arm64")
    }

    func testGetStatsSuccess() async throws {
        let json = """
        {
            "bytes": 52428800,
            "speed": 5242880,
            "transfers": 2,
            "errors": 0,
            "fatalError": false,
            "retryError": false,
            "totalBytes": 104857600,
            "totalChecks": 10,
            "totalTransfers": 5,
            "checks": 10,
            "deletes": 0,
            "elapsedTime": 10.5,
            "transferring": [
                {
                    "name": "backup.zip",
                    "size": 52428800,
                    "bytes": 26214400,
                    "percentage": 50,
                    "speed": 2621440
                }
            ]
        }
        """

        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/core/stats")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json.data(using: .utf8)!)
        }

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
        let stats = try await client.getStats()

        XCTAssertEqual(stats.bytes, 52428800)
        XCTAssertEqual(stats.transfers, 2)
        XCTAssertEqual(stats.transferring?.count, 1)
        XCTAssertEqual(stats.transferring?.first?.name, "backup.zip")
        XCTAssertFalse(stats.formattedSpeed.isEmpty)
    }

    func testListGoogleDriveSharedDrivesUsesTypedBackendCommand() async throws {
        let json = """
        {
            "result": [
                {"id": "drive-z", "kind": "drive#teamDrive", "name": "Zulu"},
                {"id": "drive-a", "kind": "drive#teamDrive", "name": "Alpha"}
            ]
        }
        """

        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/backend/command")
            let body: Data
            if let directBody = request.httpBody {
                body = directBody
            } else {
                let stream = try XCTUnwrap(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            }
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(payload["command"] as? String, "drives")
            XCTAssertEqual(payload["arg"] as? [String], [])
            XCTAssertEqual(payload["opt"] as? [String: String], [:])
            let fs = try XCTUnwrap(payload["fs"] as? [String: String])
            XCTAssertEqual(fs["type"], "drive")
            XCTAssertEqual(fs["_root"], "")

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(json.utf8))
        }

        let credential = RcloneRemoteCredential(
            remoteName: "Google Drive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "secret-token"]
        )
        let drives = try await RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
            .listGoogleDriveSharedDrives(fs: credential.fileSystemReference(root: ""))

        XCTAssertEqual(drives.map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(drives.map(\.id), ["drive-a", "drive-z"])
    }

    func testListGoogleDriveSharedDrivesHandlesNullResultWithoutCrashing() async throws {
        let json = """
        {
            "result": null
        }
        """

        http.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data(json.utf8))
        }

        let credential = RcloneRemoteCredential(
            remoteName: "Google Drive",
            provider: .googleDrive,
            backendOptions: ["type": "drive", "token": "secret-token"]
        )
        let drives = try await RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
            .listGoogleDriveSharedDrives(fs: credential.fileSystemReference(root: ""))

        XCTAssertEqual(drives, [])
    }

    func testGetStatsAcceptsPartialActiveTransferAndInfersDownload() async throws {
        let json = """
        {
            "bytes": 1024,
            "checks": 0,
            "deletes": 0,
            "elapsedTime": 1,
            "errors": 0,
            "fatalError": false,
            "retryError": false,
            "speed": 512,
            "totalBytes": 4096,
            "totalChecks": 0,
            "transfers": 11,
            "totalTransfers": 50,
            "transferring": [{
                "name": "large.bin",
                "size": 4096,
                "srcFs": ":drive{opaque}:",
                "dstFs": "/tmp/file-provider-stage"
            }]
        }
        """

        http.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let stats = try await RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider).getStats()

        XCTAssertEqual(stats.transferring?.first?.bytes, 0)
        XCTAssertEqual(stats.transferring?.first?.direction, .download)
        XCTAssertEqual(stats.downloadSpeed, 512)
        XCTAssertEqual(stats.uploadSpeed, 0)
        XCTAssertEqual(stats.fileProgress, "11/50")
    }

    func testMixedDirectionsDoNotFabricateAggregateSpeedSplit() {
        let download = ActiveTransfer(
            name: "down", size: 0, sourceFileSystem: ":drive{}:", destinationFileSystem: "/tmp/down"
        )
        let upload = ActiveTransfer(
            name: "up", size: 0, sourceFileSystem: "/tmp/up", destinationFileSystem: ":drive{}:"
        )
        let stats = TransferStats(speed: 1024, totalTransfers: 2, transferring: [download, upload])

        XCTAssertEqual(stats.downloadSpeed, 0)
        XCTAssertEqual(stats.uploadSpeed, 0)
    }

    func testTransferBatchProgressUsesCurrentActiveSeries() {
        var tracker = TransferBatchProgressTracker()
        let active = ActiveTransfer(
            name: "download", size: 1,
            sourceFileSystem: ":drive{}:", destinationFileSystem: "/tmp/download"
        )

        let first = tracker.apply(to: TransferStats(totalTransfers: 918, transfers: 917, transferring: [active]))
        let later = tracker.apply(to: TransferStats(totalTransfers: 967, transfers: 929, transferring: [active]))
        _ = tracker.apply(to: TransferStats(totalTransfers: 967, transfers: 967, transferring: []))
        let nextBatch = tracker.apply(to: TransferStats(totalTransfers: 968, transfers: 967, transferring: [active]))

        XCTAssertEqual(first.fileProgress, "0/1")
        XCTAssertEqual(later.fileProgress, "12/50")
        XCTAssertEqual(nextBatch.fileProgress, "0/1")
    }

    func testQuitUsesCoreQuitEndpoint() async throws {
        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/core/quit")
            XCTAssertEqual(request.httpMethod, "POST")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
        try await client.quit()
    }

    func testNoopAndIsReachableUsesRcNoopEndpoint() async throws {
        var called = false
        http.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == nil {
                return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(request.url?.path, "/rc/noop")
            XCTAssertEqual(request.httpMethod, "POST")
            called = true
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
        try await client.noop()
        XCTAssertTrue(called)

        let isReachable = await client.isReachable()
        XCTAssertTrue(isReachable)
    }

    func testRcloneErrorHandling() async {
        let errorJson = """
        {
            "error": "directory not empty",
            "status": 500
        }
        """

        http.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, errorJson.data(using: .utf8)!)
        }

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)

        do {
            _ = try await client.getVersion()
            XCTFail("Expected call to throw rclone error")
        } catch let error as FreeMountError {
            if case .rcloneError(let code, let msg) = error {
                XCTAssertEqual(code, 500)
                XCTAssertEqual(msg, "directory not empty")
            } else {
                XCTFail("Wrong FreeMountError variant: \(error)")
            }
        } catch {
            XCTFail("Unexpected error thrown: \(error)")
        }
    }

    func testListDecodesGoogleDriveMetadataAndSendsInMemoryFilesystem() async throws {
        http.handler = { request in
            XCTAssertEqual(request.url?.path, "/operations/list")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let json = """
            {
              "list": [
                {
                  "Path": "Projects/Brief.pdf",
                  "Name": "Brief.pdf",
                  "Size": 42,
                  "MimeType": "application/pdf",
                  "ModTime": "2026-09-18T16:30:00Z",
                  "IsDir": false,
                  "ID": "google-file-id"
                },
                {
                  "Path": "Projects/Precise.txt",
                  "Name": "Precise.txt",
                  "Size": 7,
                  "MimeType": "text/plain",
                  "ModTime": "2026-09-18T16:30:00.123456789+03:00",
                  "IsDir": false,
                  "ID": "google-precise-id"
                }
              ]
            }
            """
            return (response, Data(json.utf8))
        }

        let encodedRequest = try JSONEncoder().encode(
            RcloneListRequest(
                fs: .configuration(["type": "drive", "token": "redacted"]),
                remote: "Projects",
                options: .fileProviderDefault
            )
        )
        let encodedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedRequest) as? [String: Any])
        XCTAssertEqual(encodedPayload["remote"] as? String, "Projects")
        XCTAssertEqual(encodedPayload["fs"] as? [String: String], ["type": "drive", "token": "redacted"])

        let client = RcloneClient(port: 5572, urlSession: urlSession, credentialProvider: testRPCCredentialProvider)
        let items = try await client.list(
            fs: .configuration(["type": "drive", "token": "redacted"]),
            path: "Projects"
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "google-file-id")
        XCTAssertEqual(items[0].path, "Projects/Brief.pdf")
        XCTAssertEqual(
            items[0].modTime,
            try Date.ISO8601FormatStyle().parse("2026-09-18T16:30:00Z")
        )
        XCTAssertEqual(items[1].id, "google-precise-id")
        XCTAssertEqual(
            items[1].modTime,
            try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                .parse("2026-09-18T16:30:00.123456789+03:00")
        )
    }

    func testBinaryLocatorFallsBackToManagedArtifactWhenCustomPathMissing() throws {
        final class ArtifactFileManager: FileManager, @unchecked Sendable {
            override func fileExists(atPath path: String) -> Bool { path == RcloneBinaryLocator.managedRuntimePath }
            override func isExecutableFile(atPath path: String) -> Bool { fileExists(atPath: path) }
        }
        let resolved = try RcloneBinaryLocator.resolveBinaryPath(customPath: "/nonexistent/path/to/rclone", fileManager: ArtifactFileManager())
        XCTAssertEqual(resolved, RcloneBinaryLocator.managedRuntimePath)
    }
}
