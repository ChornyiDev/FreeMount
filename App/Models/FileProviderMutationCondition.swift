import Foundation

/// The base content token comes from Finder, never a refreshed local cache.
public enum FileProviderMutationCondition: Sendable, Equatable {
    case absent
    case contentVersion(Data)
}

public enum FileProviderMutationError: LocalizedError, Sendable, Equatable {
    case versionConflict
    public var errorDescription: String? {
        switch self {
        case .versionConflict: return "The cloud item changed or the destination already exists. A metadata preflight check rejected this operation. Refresh Finder and resolve the conflicting versions."
        }
    }
}

public struct FileProviderDownloadedItem: Sendable {
    public let url: URL
    public let item: FileProviderRemoteItem
}

extension FileProviderRemoteItem {
    var contentVersion: Data {
        FreeMountFileProviderItem.makeVersion(path: path, size: contentSize, modifiedAt: modifiedAt, remoteObjectID: remoteObjectID).contentVersion
    }
    func check(_ condition: FileProviderMutationCondition) throws {
        guard case .contentVersion(let expected) = condition, expected == contentVersion else { throw FileProviderMutationError.versionConflict }
    }
}
