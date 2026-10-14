import Foundation

public struct GoogleCloudProject: Codable, Sendable, Identifiable, Equatable {
    public let name: String
    public let projectId: String
    public let displayName: String?
    public let state: String?
    public var id: String { projectId }
    public var number: String { String(name.split(separator: "/").last ?? "") }
}

public struct GoogleCloudBucket: Codable, Sendable, Identifiable, Equatable {
    public let name: String
    public let projectNumber: String
    public let billing: Billing?
    public var id: String { name }
    public struct Billing: Codable, Sendable, Equatable {
        public let requesterPays: Bool?
    }
}

public enum GoogleCloudBucketSelectionMode: String, Codable, Sendable {
    case directBucket
}

public struct GoogleCloudStorageSelection: Codable, Sendable, Equatable {
    public let projectID: String
    public let projectNumber: String
    public let bucket: String
    public let billingProject: String?
    public let selectionMode: GoogleCloudBucketSelectionMode?

    public init(projectID: String, projectNumber: String, bucket: String, billingProject: String? = nil) throws {
        try Self.validateBucket(bucket)
        guard !projectID.isEmpty, !projectNumber.isEmpty else {
            throw GoogleCloudStorageError.invalidSelection
        }
        self.selectionMode = nil
        self.projectID = projectID
        self.projectNumber = projectNumber
        self.bucket = bucket
        self.billingProject = billingProject?.isEmpty == true ? nil : billingProject
    }

    /// A bucket-scoped principal may lack permission to discover project metadata.
    public init(directBucket bucket: String, billingProject: String? = nil) throws {
        try Self.validateBucket(bucket)
        self.projectID = ""
        self.projectNumber = ""
        self.bucket = bucket
        self.billingProject = billingProject?.isEmpty == true ? nil : billingProject
        self.selectionMode = .directBucket
    }

    public static func validateBucket(_ bucket: String) throws {
        let valid = bucket.range(of: "^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$", options: .regularExpression) != nil
        guard valid, !bucket.contains(".."), bucket.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.count <= 63 }) else {
            throw GoogleCloudStorageError.invalidSelection
        }
    }

    public func credential(authorization: GoogleDriveAuthorization, remoteName: String) -> RcloneRemoteCredential {
        var options = authorization.credential(remoteName: remoteName).backendOptions
        options.merge(backendOptions) { _, selected in selected }
        return RcloneRemoteCredential(remoteName: remoteName, provider: .googleCloudStorage, backendOptions: options)
    }
    var backendOptions: [String: String] {
        var options: [String: String] = [:]
        options["type"] = ProviderID.googleCloudStorage.rawValue
        if !projectNumber.isEmpty { options["project_number"] = projectNumber }
        options["directory_markers"] = "true"
        options["no_check_bucket"] = "true"
        options["bucket_policy_only"] = "true"
        options["bucket_acl"] = ""
        options["object_acl"] = ""
        if let billingProject { options["user_project"] = billingProject }
        return options
    }

}

public enum GoogleCloudStorageError: LocalizedError, Sendable, Equatable {
    case invalidSelection
    case invalidResponse
    case apiDisabled(String)
    case insufficientScope
    case apiFailure(status: Int, operation: String)
    case missingPermissions([String])
    case bucketMismatch
    case unsupportedObjectNames(String)
    case sourceChanged

    public var errorDescription: String? {
        switch self {
        case .invalidSelection: return "Select one project and one valid bucket for this connection."
        case .apiDisabled(let service): return "Enable \(service) in the Google Cloud project used for API requests, then retry sign-in."
        case .insufficientScope: return "Google did not grant the required scopes. Add devstorage.read_write and cloudplatformprojects.readonly to the OAuth consent configuration, then sign in again and approve both permissions."
        case .invalidResponse: return "Google Cloud returned an invalid response. Retry discovery or authorize again."
        case .unsupportedObjectNames(let reason): return "Some bucket object names are unsupported in Finder. \(reason) Use Google Cloud Console to inspect those objects."
        case .sourceChanged: return "The source folder changed during the move. Review the source and destination before retrying."
        case .bucketMismatch: return "The bucket does not belong to the selected project. Reload the bucket list."
        case .missingPermissions(let permissions): return "This bucket needs IAM permissions: \(permissions.joined(separator: ", "))."
        case .apiFailure(let status, let operation):
            switch status {
            case 401: return "Google Cloud authorization expired. Authorize again."
            case 403: return "Google Cloud denied \(operation). Check IAM permissions and that Cloud Resource Manager and Cloud Storage APIs are enabled in the project used for API requests."
            case 404: return "The selected Google Cloud resource no longer exists or is inaccessible."
            case 429: return "Google Cloud quota was exceeded. Retry later."
            default: return "Google Cloud \(operation) failed (HTTP \(status)). Retry after checking your connection."
            }
        }
    }
}
