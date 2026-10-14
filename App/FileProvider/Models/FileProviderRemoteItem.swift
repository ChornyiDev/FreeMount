import Foundation

/// Provider-neutral file metadata used by the File Provider extension bridge.
public struct FileProviderRemoteItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let parentPath: String
    public let path: String
    public let filename: String
    public let contentSize: Int64
    public let contentType: String?
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public let remoteObjectID: String?
    public let isReadOnly: Bool

    public init(
        id: String,
        parentPath: String,
        path: String,
        filename: String,
        contentSize: Int64,
        contentType: String? = nil,
        modifiedAt: Date? = nil,
        isDirectory: Bool,
        remoteObjectID: String? = nil,
        isReadOnly: Bool = false
    ) {
        self.id = id
        self.parentPath = parentPath
        self.path = path
        self.filename = filename
        self.contentSize = contentSize
        self.contentType = contentType
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
        self.remoteObjectID = remoteObjectID
        self.isReadOnly = isReadOnly
    }
}

public enum FileProviderPathError: LocalizedError, Sendable, Equatable {
    case traversalAttempt(String)

    public var errorDescription: String? {
        switch self {
        case .traversalAttempt(let path):
            return "The remote path '\(path)' is not valid."
        }
    }
}

public enum FileProviderPath {
    /// Canonicalizes a remote-relative path and rejects attempts to leave My Drive.
    public static func normalize(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(".") && !components.contains("..") else {
            throw FileProviderPathError.traversalAttempt(path)
        }
        return components.joined(separator: "/")
    }

    /// Provider-specific validation is applied before shared extension mutations.
    public static func validated(_ path: String, for provider: ProviderID) throws -> String {
        if provider == .googleCloudStorage { return try GoogleCloudPathPolicy.validate(path) }
        return try normalize(path)
    }

    public static func parent(of path: String) -> String {
        guard let separator = path.lastIndex(of: "/") else { return "" }
        return String(path[..<separator])
    }
}
