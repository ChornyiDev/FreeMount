import Foundation

// MARK: - Core Version
public struct RcloneVersionResponse: Codable, Sendable, Equatable {
    public let version: String
    public let decomposed: [Int]?
    public let isGit: Bool?
    public let goVersion: String?
    public let goTags: String?
    public let linking: String?
    public let os: String?
    public let arch: String?
    public let isBeta: Bool?

    public init(
        version: String,
        decomposed: [Int]? = nil,
        isGit: Bool? = nil,
        goVersion: String? = nil,
        goTags: String? = nil,
        linking: String? = nil,
        os: String? = nil,
        arch: String? = nil,
        isBeta: Bool? = nil
    ) {
        self.version = version
        self.decomposed = decomposed
        self.isGit = isGit
        self.goVersion = goVersion
        self.goTags = goTags
        self.linking = linking
        self.os = os
        self.arch = arch
        self.isBeta = isBeta
    }
}

// MARK: - Core PID
public struct RclonePIDResponse: Codable, Sendable, Equatable {
    public let pid: Int

    public init(pid: Int) {
        self.pid = pid
    }
}

/// A remote name or an in-memory backend configuration accepted by rclone RC.
public enum RcloneFileSystemReference: Codable, Sendable, Equatable {
    case named(String)
    case configuration([String: String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .named(name)
        } else {
            self = .configuration(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .named(let name):
            try container.encode(name)
        case .configuration(let options):
            try container.encode(options)
        }
    }
}

// MARK: - File Provider Operations

/// Options for rclone's `operations/list` endpoint.
public struct RcloneListOptions: Codable, Sendable, Equatable {
    public let recurse: Bool
    public let noModTime: Bool
    public let showOrigIDs: Bool
    public let noMimeType: Bool
    public let dirsOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case recurse
        case noModTime
        case showOrigIDs
        case noMimeType
        case dirsOnly
    }

    public init(recurse: Bool = false, noModTime: Bool = false, showOrigIDs: Bool = true, noMimeType: Bool = false, dirsOnly: Bool? = nil) {
        self.recurse = recurse
        self.noModTime = noModTime
        self.showOrigIDs = showOrigIDs
        self.noMimeType = noMimeType
        self.dirsOnly = dirsOnly
    }

    public static let fileProviderDefault = RcloneListOptions()
}

public struct RcloneListRequest: Codable, Sendable, Equatable {
    public let fs: RcloneFileSystemReference
    public let remote: String
    public let options: RcloneListOptions

    enum CodingKeys: String, CodingKey {
        case fs
        case remote
        case options = "opt"
    }

    public init(fs: RcloneFileSystemReference, remote: String, options: RcloneListOptions) {
        self.fs = fs
        self.remote = remote
        self.options = options
    }
}

/// One `lsjson` item as returned by rclone's `operations/list` endpoint.
public struct RcloneListedItem: Codable, Sendable, Equatable {
    public let path: String
    public let name: String
    public let size: Int64
    public let mimeType: String?
    public let modTime: Date?
    public let isDir: Bool
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case name = "Name"
        case size = "Size"
        case mimeType = "MimeType"
        case modTime = "ModTime"
        case isDir = "IsDir"
        case id = "ID"
    }

    public init(
        path: String,
        name: String,
        size: Int64,
        mimeType: String? = nil,
        modTime: Date? = nil,
        isDir: Bool,
        id: String? = nil
    ) {
        self.path = path
        self.name = name
        self.size = size
        self.mimeType = mimeType
        self.modTime = modTime
        self.isDir = isDir
        self.id = id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = (try? container.decode(String.self, forKey: .path)) ?? ""
        self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
        self.size = (try? container.decode(Int64.self, forKey: .size)) ?? 0
        self.mimeType = try? container.decode(String.self, forKey: .mimeType)
        self.modTime = try? container.decode(Date.self, forKey: .modTime)
        self.isDir = (try? container.decode(Bool.self, forKey: .isDir)) ?? false
        self.id = try? container.decode(String.self, forKey: .id)
    }
}

public struct RcloneListResponse: Codable, Sendable, Equatable {
    public let items: [RcloneListedItem]

    enum CodingKeys: String, CodingKey {
        case items = "list"
    }

    public init(items: [RcloneListedItem]) {
        self.items = items
    }
}

public struct RcloneStatResponse: Codable, Sendable, Equatable {
    public let item: RcloneListedItem?

    public init(item: RcloneListedItem? = nil) {
        self.item = item
    }
}

public struct RcloneCopyFileRequest: Codable, Sendable, Equatable {
    public let sourceFS: RcloneFileSystemReference
    public let sourcePath: String
    public let destinationFS: RcloneFileSystemReference
    public let destinationPath: String

    enum CodingKeys: String, CodingKey {
        case sourceFS = "srcFs"
        case sourcePath = "srcRemote"
        case destinationFS = "dstFs"
        case destinationPath = "dstRemote"
    }

    public init(
        sourceFS: RcloneFileSystemReference,
        sourcePath: String,
        destinationFS: RcloneFileSystemReference,
        destinationPath: String
    ) {
        self.sourceFS = sourceFS
        self.sourcePath = sourcePath
        self.destinationFS = destinationFS
        self.destinationPath = destinationPath
    }
}

public struct RclonePathOperationRequest: Codable, Sendable, Equatable {
    public let fs: RcloneFileSystemReference
    public let remote: String

    public init(fs: RcloneFileSystemReference, remote: String) {
        self.fs = fs
        self.remote = remote
    }
}

// MARK: - Backend Commands

public struct RcloneBackendCommandRequest: Codable, Sendable, Equatable {
    public let command: String
    public let fs: RcloneFileSystemReference
    public let arguments: [String]
    public let options: [String: String]

    enum CodingKeys: String, CodingKey {
        case command
        case fs
        case arguments = "arg"
        case options = "opt"
    }

    public init(
        command: String,
        fs: RcloneFileSystemReference,
        arguments: [String] = [],
        options: [String: String] = [:]
    ) {
        self.command = command
        self.fs = fs
        self.arguments = arguments
        self.options = options
    }
}

public struct GoogleDriveSharedDrive: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String?
    public let name: String

    public init(id: String, kind: String? = nil, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

public struct GoogleDriveSharedDrivesResponse: Codable, Sendable, Equatable {
    public let result: [GoogleDriveSharedDrive]

    public init(result: [GoogleDriveSharedDrive] = []) {
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.result = try container.decodeIfPresent([GoogleDriveSharedDrive].self, forKey: .result) ?? []
    }
}

// MARK: - Generic RC Error Response
public struct RcloneRCErrorResponse: Codable, Sendable {
    public let error: String
    public let status: Int?

    public init(error: String, status: Int? = nil) {
        self.error = error
        self.status = status
    }
}

// MARK: - Empty / Success Response
public struct RcloneEmptyResponse: Codable, Sendable, Equatable {}

struct RcloneDirectoryCopyRequest: Codable, Sendable {
    let srcFs: RcloneFileSystemReference
    let dstFs: RcloneFileSystemReference
    let createEmptySrcDirs: Bool
}
