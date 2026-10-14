import Foundation

/// Asynchronous typed JSON-RPC/REST client for rclone Remote Control (RC) daemon
public actor RcloneClient {

    public let baseURL: URL
    private let urlSession: URLSession
    private let jsonDecoder: JSONDecoder
    private let jsonEncoder: JSONEncoder
    private let credentialProvider: @Sendable () async throws -> RcloneRPCredentials

    public init(baseURL: URL, urlSession: URLSession = RcloneTransportDelegate.makeSession(), credentialProvider: @escaping @Sendable () async throws -> RcloneRPCredentials = { try await RcloneRPCredentialStore.loadSharedCredential() }) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.credentialProvider = credentialProvider

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys

        let iso8601WithFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let iso8601 = Date.ISO8601FormatStyle()

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = try? iso8601WithFractional.parse(dateStr) { return date }
            if let date = try? iso8601.parse(dateStr) { return date }
            return Date()
        }
        self.jsonDecoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = encoder
    }

    /// Convenience initializer for localhost port
    public init(port: Int, urlSession: URLSession = RcloneTransportDelegate.makeSession(), credentialProvider: @escaping @Sendable () async throws -> RcloneRPCredentials = { try await RcloneRPCredentialStore.loadSharedCredential() }) {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        self.init(baseURL: url, urlSession: urlSession, credentialProvider: credentialProvider)
    }

    /// Providers wait for the host-owned daemon; they never launch a process.
    public static func readyClient(port: Int = 5572) async throws -> RcloneClient {
        let client = RcloneClient(port: port)
        for attempt in 0..<15 {
            try Task.checkCancellation()
            if try await client.authenticatedEndpointIsReachable() { return client }
            if attempt < 14 { try await Task.sleep(for: .milliseconds(200)) }
        }
        throw FreeMountError.daemonNotRunning
    }

    // MARK: - Core Methods

    /// Retrieves rclone daemon version and OS capabilities
    public func getVersion() async throws -> RcloneVersionResponse {
        try await post(endpoint: "core/version", payload: Optional<String>.none)
    }

    /// Obscures a plaintext password using rclone's core/obscure endpoint.
    public func obscure(password: String) async throws -> String {
        struct ObscureResponse: Decodable {
            let obscured: String
        }
        let response: ObscureResponse = try await post(endpoint: "core/obscure", payload: ["clear": password])
        return response.obscured
    }

    public func getCompletedTransfers() async throws -> [CompletedTransfer] {
        let response: CompletedTransfersResponse = try await post(endpoint: "core/transferred", payload: Optional<String>.none)
        return response.transferred
    }

    /// Retrieves the rclone process ID
    public func getPid() async throws -> Int {
        let response: RclonePIDResponse = try await post(endpoint: "core/pid", payload: Optional<String>.none)
        return response.pid
    }

    /// Retrieves live bandwidth, transfer rates, and progress stats
    public func getStats() async throws -> TransferStats {
        try await post(endpoint: "core/stats", payload: Optional<String>.none)
    }

    /// Requests an orderly rclone shutdown so active mount backends can detach.
    public func quit() async throws {
        let _: RcloneEmptyResponse = try await post(
            endpoint: "core/quit",
            payload: Optional<String>.none
        )
    }

    /// Sends lightweight no-op ping to check daemon reachability and authentication.
    public func noop() async throws {
        let _: RcloneEmptyResponse = try await post(
            endpoint: "rc/noop",
            payload: Optional<String>.none
        )
    }

    /// Checks daemon connectivity (ping) via lightweight rc/noop endpoint.
    public func isReachable() async -> Bool {
        do {
            return try await authenticatedEndpointIsReachable()
        } catch {
            return false
        }
    }

    /// Never adopt a legacy no-auth endpoint, even if it accepts our header.
    func authenticatedEndpointIsReachable() async throws -> Bool {
        try validateLoopbackEndpoint()
        var request = URLRequest(url: baseURL.appendingPathComponent("rc/noop"))
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 2
        let response: URLResponse
        do { (_, response) = try await urlSession.data(for: request) }
        catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost || error.code == .timedOut { return false }
        guard (response as? HTTPURLResponse)?.statusCode == 401 else { throw RcloneRPCAuthenticationError.unprotectedEndpoint }
        try await noop()
        return true
    }

    private func validateLoopbackEndpoint() throws {
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1", baseURL.port != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/" else { throw RcloneRPCAuthenticationError.nonLoopbackEndpoint }
    }

    // MARK: - File Provider Operations

    /// Lists one directory through rclone without exposing a named rclone.conf remote.
    public func list(
        fs: RcloneFileSystemReference,
        path: String,
        options: RcloneListOptions = .fileProviderDefault
    ) async throws -> [RcloneListedItem] {
        let response: RcloneListResponse = try await post(
            endpoint: "operations/list",
            payload: RcloneListRequest(fs: fs, remote: path, options: options)
        )
        return response.items
    }

    /// Retrieves file or directory metadata for one remote item.
    public func stat(
        fs: RcloneFileSystemReference,
        path: String
    ) async throws -> RcloneListedItem? {
        let response: RcloneStatResponse = try await post(
            endpoint: "operations/stat",
            payload: RclonePathOperationRequest(fs: fs, remote: path)
        )
        return response.item
    }

    /// Copies one file between an in-memory backend and a local staging directory.
    public func copyFile(
        sourceFS: RcloneFileSystemReference,
        sourcePath: String,
        destinationFS: RcloneFileSystemReference,
        destinationPath: String
    ) async throws {
        try await runJob(
            endpoint: "operations/copyfile",
            payload: RcloneCopyFileRequest(
                sourceFS: sourceFS,
                sourcePath: sourcePath,
                destinationFS: destinationFS,
                destinationPath: destinationPath
            )
        )
    }

    /// Moves a file between or within filesystems.
    public func moveFile(
        sourceFS: RcloneFileSystemReference,
        sourcePath: String,
        destinationFS: RcloneFileSystemReference,
        destinationPath: String
    ) async throws {
        try await runJob(
            endpoint: "operations/movefile",
            payload: RcloneCopyFileRequest(
                sourceFS: sourceFS,
                sourcePath: sourcePath,
                destinationFS: destinationFS,
                destinationPath: destinationPath
            )
        )
    }

    /// Copies a complete directory, including empty directory markers, before cleanup.
    public func copyDirectory(sourceFS: RcloneFileSystemReference, destinationFS: RcloneFileSystemReference) async throws {
        try await runJob(endpoint: "sync/copy", payload: RcloneDirectoryCopyRequest(srcFs: sourceFS, dstFs: destinationFS, createEmptySrcDirs: true))
    }

    /// Creates a directory in an in-memory backend.
    public func makeDirectory(fs: RcloneFileSystemReference, path: String) async throws {
        try await runJob(
            endpoint: "operations/mkdir",
            payload: RclonePathOperationRequest(fs: fs, remote: path)
        )
    }

    /// Deletes exactly one remote file. Directory removal uses `removeDirectory`.
    public func deleteFile(fs: RcloneFileSystemReference, path: String) async throws {
        try await runJob(
            endpoint: "operations/deletefile",
            payload: RclonePathOperationRequest(fs: fs, remote: path)
        )
    }

    /// Removes an empty remote directory.
    public func removeDirectory(fs: RcloneFileSystemReference, path: String) async throws {
        try await runJob(
            endpoint: "operations/rmdir",
            payload: RclonePathOperationRequest(fs: fs, remote: path)
        )
    }

    /// Recursively deletes a remote directory and all of its contents.
    public func purgeDirectory(fs: RcloneFileSystemReference, path: String) async throws {
        try await runJob(
            endpoint: "operations/purge",
            payload: RclonePathOperationRequest(fs: fs, remote: path)
        )
    }

    /// Lists Shared Drives visible to one in-memory Google Drive credential.
    public func listGoogleDriveSharedDrives(
        fs: RcloneFileSystemReference
    ) async throws -> [GoogleDriveSharedDrive] {
        let response: GoogleDriveSharedDrivesResponse = try await post(
            endpoint: "backend/command",
            payload: RcloneBackendCommandRequest(command: "drives", fs: fs)
        )
        return response.result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Asynchronous mutation jobs

    /// No overall transfer deadline: each HTTP control request remains bounded.
    private func runJob<Payload: Encodable & Sendable>(endpoint: String, payload: Payload) async throws {
        _ = try await runJobStatus(endpoint: endpoint, payload: payload)
    }
    private func runJobStatus<Payload: Encodable & Sendable>(endpoint: String, payload: Payload) async throws -> RcloneJobStatus {
        try Task.checkCancellation()
        let group = "freemount.\(UUID().uuidString.lowercased())"
        // Submission must resolve even if the caller cancels, so its job ID is
        // available for explicit shutdown. Never resubmit an uncertain mutation.
        let submission = Task { () throws -> RcloneJobHandle in
            try await self.post(endpoint: endpoint, payload: RcloneAsyncRequest(payload: payload, group: group))
        }
        let handle: RcloneJobHandle
        do { handle = try await submission.value }
        catch {
            // An HTTP error response is a rejected submission; transport or
            // decode failures may have lost an accepted job's response.
            if error is RcloneRPCAuthenticationError { throw error }
            if case FreeMountError.rcloneError = error { throw error }
            throw RcloneJobError.outcomeUnknown(group: group, reason: CredentialRedactor.redact(error.localizedDescription))
        }
        let terminal: RcloneJobStatus
        do {
            terminal = try await waitForCompletion(handle: handle, group: group)
        } catch {
            if error is RcloneJobError { throw error }
            let confirmed = await Task.detached { [self] in
                await self.stopAndConfirm(handle: handle, group: group)
            }.value
            guard let confirmed else {
                throw RcloneJobError.outcomeUnknown(group: group, reason: "Could not confirm job termination after \(CredentialRedactor.redact(error.localizedDescription))")
            }
            terminal = confirmed
        }
        // A completion racing with cancellation remains a successful job.
        if terminal.success { return terminal }
        if Task.isCancelled { throw CancellationError() }
        throw FreeMountError.rcloneError(statusCode: 500, message: CredentialRedactor.redact(terminal.error))
    }

    private func waitForCompletion(handle: RcloneJobHandle, group: String) async throws -> RcloneJobStatus {
        while true {
            try Task.checkCancellation()
            let status: RcloneJobStatus = try await post(endpoint: "job/status", payload: RcloneJobRequest(jobid: handle.jobid))
            guard status.id == handle.jobid, status.executeId == handle.executeId else {
                throw RcloneJobError.outcomeUnknown(group: group, reason: "The daemon restarted or returned another job identity")
            }
            if status.finished { return status }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func stopAndConfirm(handle: RcloneJobHandle, group: String) async -> RcloneJobStatus? {
        // Unique groups avoid stopping a reused numeric ID after daemon restart.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        do {
            let _: RcloneEmptyResponse = try await post(endpoint: "job/stopgroup", payload: RcloneJobGroupRequest(group: group))
        } catch {
            // A failed stop response cannot establish completion; status can.
        }
        while clock.now < deadline {
            do {
                let status: RcloneJobStatus = try await post(endpoint: "job/status", payload: RcloneJobRequest(jobid: handle.jobid))
                guard status.id == handle.jobid, status.executeId == handle.executeId else { return nil }
                if status.finished { return status }
            } catch {
                // Retry only observation, never the mutation itself.
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    // MARK: - Generic Transport

    private func post<Req: Encodable, Res: Decodable>(
        endpoint: String,
        payload: Req?
    ) async throws -> Res {
        try validateLoopbackEndpoint()
        let credentials = try await credentialProvider().validated()
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw FreeMountError.invalidConfiguration(reason: "Invalid endpoint URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        if let payload = payload {
            do {
                request.httpBody = try jsonEncoder.encode(payload)
            } catch {
                throw FreeMountError.invalidConfiguration(reason: "Failed to encode request payload: \(error.localizedDescription)")
            }
        } else {
            // rclone RC expects valid JSON even for parameterless endpoints such as
            // `core/version`; an empty POST body is rejected as JSON EOF.
            request.httpBody = Data("{}".utf8)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw FreeMountError.networkTimeout(operation: "\(endpoint) [\(error.localizedDescription)]")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FreeMountError.unexpectedResponse("Expected HTTPURLResponse, received \(response)")
        }

        if httpResponse.statusCode == 401 { throw RcloneRPCAuthenticationError.authenticationRejected }
        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to parse structured rclone error JSON
            if let rcError = try? jsonDecoder.decode(RcloneRCErrorResponse.self, from: data) {
                throw FreeMountError.rcloneError(statusCode: httpResponse.statusCode, message: CredentialRedactor.redact(rcError.error))
            }
            let rawString = String(data: data, encoding: .utf8) ?? "Unknown HTTP \(httpResponse.statusCode)"
            throw FreeMountError.rcloneError(statusCode: httpResponse.statusCode, message: CredentialRedactor.redact(rawString))
        }

        // Allow empty body responses
        if Res.self == RcloneEmptyResponse.self && data.isEmpty {
            if let empty = RcloneEmptyResponse() as? Res {
                return empty
            }
        }

        do {
            return try jsonDecoder.decode(Res.self, from: data)
        } catch {
            throw FreeMountError.unexpectedResponse("Failed to decode \(Res.self): \(error.localizedDescription)")
        }
    }
}
