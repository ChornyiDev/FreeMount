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
        guard case .contentVersion(let expectedData) = condition else {
            throw FileProviderMutationError.versionConflict
        }
        if expectedData == contentVersion {
            return
        }

        // Handle cloud metadata divergence:
        // When a file is created empty (size 0) and immediately populated with content,
        // remote storage (e.g. Google Drive/GCS) assigns a new server-side modification date
        // and remote object ID upon creation. If Finder's expected base version was size 0
        // on the exact same path, and the remote file is also currently size 0, allow the update
        // rather than rejecting with a false conflict.
        let expectedStr = String(data: expectedData, encoding: .utf8) ?? ""
        let expectedParts = expectedStr.split(separator: ":", omittingEmptySubsequences: false)
        if expectedParts.count >= 2 {
            let expectedPath = String(expectedParts[0])
            let expectedSize = Int64(expectedParts[1]) ?? -1
            if expectedPath == path && expectedSize == 0 && contentSize == 0 {
                return
            }
            // If the remote storage has a stable remoteObjectID (e.g. Drive file ID)
            // matching the expected token, permit update when sizes match.
            if expectedParts.count >= 4,
               let remoteID = remoteObjectID,
               !remoteID.isEmpty && remoteID != "none" {
                let expectedID = String(expectedParts[3])
                if expectedID == remoteID && expectedPath == path && expectedSize == contentSize {
                    return
                }
            }
        }

        throw FileProviderMutationError.versionConflict
    }
}
