import Foundation

/// Metadata discovery uses Google APIs; file operations remain on rclone RC.
public actor GoogleCloudDiscoveryService {
    public static let oauthScopes = [
        "https://www.googleapis.com/auth/devstorage.read_write",
        "https://www.googleapis.com/auth/cloudplatformprojects.readonly"
    ]
    private let session: URLSession
    private let oauthTokens: GoogleOAuthTokenService
    private let serviceAccountTokens: GoogleCloudServiceAccountTokenService
    public init(session: URLSession? = nil) {
        self.session = session ?? .shared
        self.oauthTokens = GoogleOAuthTokenService(session: session)
        self.serviceAccountTokens = GoogleCloudServiceAccountTokenService(session: session)
    }

    public func checkAuthorization(_ authorization: GoogleCloudAuthorization) async throws {
        _ = try await accessToken(authorization)
    }

    public func projects(authorization: GoogleCloudAuthorization) async throws -> [GoogleCloudProject] {
        var projects: [GoogleCloudProject] = []
        var token: String?
        var seenTokens = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "query", value: "state:ACTIVE"), URLQueryItem(name: "pageSize", value: "100")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page: ProjectsPage = try await get("https://cloudresourcemanager.googleapis.com/v3/projects:search", query: query, authorization: authorization, operation: "project discovery (resourcemanager.projects.get)")
            projects += page.projects ?? []
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let token, !seenTokens.insert(token).inserted { throw GoogleCloudStorageError.invalidResponse }
        } while token != nil
        return projects.filter { $0.state == nil || $0.state == "ACTIVE" }.sorted { $0.projectId < $1.projectId }
    }

    public func buckets(project: GoogleCloudProject, authorization: GoogleCloudAuthorization) async throws -> [GoogleCloudBucket] {
        var buckets: [GoogleCloudBucket] = []
        var token: String?
        var seenTokens = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "project", value: project.projectId), URLQueryItem(name: "projection", value: "noAcl"), URLQueryItem(name: "maxResults", value: "1000")]
            if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
            let page: BucketsPage = try await get("https://storage.googleapis.com/storage/v1/b", query: query, authorization: authorization, operation: "bucket discovery (storage.buckets.list)")
            buckets += page.items ?? []
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let token, !seenTokens.insert(token).inserted { throw GoogleCloudStorageError.invalidResponse }
        } while token != nil
        return buckets.filter { $0.projectNumber == project.number }.sorted { $0.name < $1.name }
    }

    /// Read-only IAM probe: no temporary object is written to the user's bucket.
    public func validate(selection: GoogleCloudStorageSelection, authorization: GoogleCloudAuthorization, readOnly: Bool) async throws {
        try GoogleCloudStorageSelection.validateBucket(selection.bucket)
        let base = "https://storage.googleapis.com/storage/v1/b/\(selection.bucket)"
        var query: [URLQueryItem] = []
        if let billing = selection.billingProject { query.append(URLQueryItem(name: "userProject", value: billing)) }
        if selection.selectionMode != .directBucket {
            do {
                let bucket: GoogleCloudBucket = try await get(base, query: query, authorization: authorization, operation: "bucket validation (storage.buckets.get)")
                guard bucket.name == selection.bucket, bucket.projectNumber == selection.projectNumber else { throw GoogleCloudStorageError.bucketMismatch }
                if bucket.billing?.requesterPays == true, selection.billingProject == nil {
                    throw GoogleCloudStorageError.missingPermissions(["a billing project for Requester Pays"])
                }
            } catch let error as GoogleCloudStorageError {
                guard case .serviceAccount = authorization,
                      case .apiFailure(status: 403, operation: _) = error else { throw error }
                // A replacement key can legitimately narrow access to object-only
                // bucket roles while retaining the immutable bucket binding.
            }
        }
        let required = readOnly ? ["storage.objects.list", "storage.objects.get"] : ["storage.objects.list", "storage.objects.get", "storage.objects.create", "storage.objects.delete"]
        query += required.map { URLQueryItem(name: "permissions", value: $0) }
        let result: PermissionsResponse = try await get(base + "/iam/testPermissions", query: query, authorization: authorization, operation: "bucket access validation")
        let missing = required.filter { !(result.permissions ?? []).contains($0) }
        guard missing.isEmpty else { throw GoogleCloudStorageError.missingPermissions(missing) }
    }

    /// Direct entry validates optional metadata without requiring discovery IAM roles.
    public func directSelection(bucket name: String, billingProject: String?, authorization: GoogleCloudAuthorization) async throws -> GoogleCloudStorageSelection {
        do {
            let metadata = try await bucket(named: name, billingProject: billingProject, authorization: authorization)
            guard metadata.name == name else { throw GoogleCloudStorageError.bucketMismatch }
            if metadata.billing?.requesterPays == true, billingProject == nil {
                throw GoogleCloudStorageError.missingPermissions(["a billing project for Requester Pays"])
            }
            return try GoogleCloudStorageSelection(projectID: metadata.projectNumber, projectNumber: metadata.projectNumber, bucket: name, billingProject: billingProject)
        } catch GoogleCloudStorageError.apiFailure(status: 403, operation: _) {
            // Object-only bucket roles omit storage.buckets.get. IAM and the actual
            // root listing still have to pass before the connection is saved.
            return try GoogleCloudStorageSelection(directBucket: name, billingProject: billingProject)
        }
    }

    public func bucket(named name: String, billingProject: String? = nil, authorization: GoogleCloudAuthorization) async throws -> GoogleCloudBucket {
        try GoogleCloudStorageSelection.validateBucket(name)
        let query = billingProject.map { [URLQueryItem(name: "userProject", value: $0)] } ?? []
        return try await get("https://storage.googleapis.com/storage/v1/b/\(name)", query: query, authorization: authorization, operation: "bucket validation (storage.buckets.get)")
    }

    /// Export the refreshed OAuth material to the existing Keychain-only save path.
    public func refreshedAuthorization(_ authorization: GoogleCloudAuthorization) async throws -> GoogleCloudAuthorization {
        switch authorization {
        case .googleAccount(let oauth): return .googleAccount(try await oauthTokens.authorization(for: oauth))
        case .serviceAccount: return authorization
        }
    }

    private func accessToken(_ authorization: GoogleCloudAuthorization) async throws -> String {
        switch authorization {
        case .googleAccount(let oauth):
            return try await oauthTokens.accessToken(for: oauth)
        case .serviceAccount(let key): return try await serviceAccountTokens.accessToken(for: key)
        }
    }

    private func get<T: Decodable>(_ endpoint: String, query: [URLQueryItem], authorization: GoogleCloudAuthorization, operation: String) async throws -> T {
        try Task.checkCancellation()
        var token = try await accessToken(authorization)
        var components = URLComponents(string: endpoint)!
        components.queryItems = query
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GoogleCloudStorageError.invalidResponse }
            if http.statusCode == 401, attempt == 0, case .googleAccount(let oauth) = authorization {
                token = try await oauthTokens.accessToken(for: oauth, rejectedAccessToken: token)
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
                for detail in envelope?.error.details ?? [] {
                    if detail.reason == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" { throw GoogleCloudStorageError.insufficientScope }
                    if detail.reason == "SERVICE_DISABLED" {
                        let service = detail.metadata?.service
                        let name = service == "cloudresourcemanager.googleapis.com" ? "Cloud Resource Manager API" : (service == "storage.googleapis.com" ? "Cloud Storage JSON API" : "the required Google Cloud API")
                        throw GoogleCloudStorageError.apiDisabled(name)
                    }
                }
                throw GoogleCloudStorageError.apiFailure(status: http.statusCode, operation: operation)
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw GoogleCloudStorageError.invalidResponse }
        }
        throw GoogleCloudStorageError.invalidResponse
    }

    private struct APIErrorEnvelope: Decodable {
        let error: APIError
        struct APIError: Decodable { let details: [Detail]? }
        struct Detail: Decodable {
            let reason: String?
            let metadata: Metadata?
        }
        struct Metadata: Decodable { let service: String? }
    }
    private struct ProjectsPage: Decodable { let projects: [GoogleCloudProject]?; let nextPageToken: String? }
    private struct BucketsPage: Decodable { let items: [GoogleCloudBucket]?; let nextPageToken: String? }
    private struct PermissionsResponse: Decodable { let permissions: [String]? }
}
