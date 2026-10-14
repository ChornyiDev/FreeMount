import Foundation
import FileProvider
import UniformTypeIdentifiers

// MARK: - NSFileProviderItemIdentifier Mapping

public extension NSFileProviderItemIdentifier {
    /// Identifier for the domain root container
    static let domainRoot = NSFileProviderItemIdentifier.rootContainer

    /// Creates an item identifier encoding the normalized remote-relative path
    static func remoteItem(path: String) -> NSFileProviderItemIdentifier {
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        guard !normalized.isEmpty else {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier("p:\(normalized)")
    }

    /// Extracts the remote-relative path from a remote item identifier, or `""` for root
    var remoteRelativePath: String? {
        if self == .rootContainer {
            return ""
        }
        if rawValue.hasPrefix("p:") {
            return String(rawValue.dropFirst(2))
        }
        return nil
    }

    /// Whether this identifier represents the root container
    var isDomainRoot: Bool {
        self == .rootContainer
    }
}

// MARK: - FreeMountFileProviderItem

/// Full representation of a File Provider item for Google Drive My Drive.
public final class FreeMountFileProviderItem: NSObject, NSFileProviderItem, NSFileProviderItemDecorating, @unchecked Sendable {

    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let capabilities: NSFileProviderItemCapabilities
    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let itemVersion: NSFileProviderItemVersion
    public let isDirectory: Bool
    public let remotePath: String
    public let remoteObjectID: String?
    public let isPinned: Bool

    public static let pinnedDecoration = NSFileProviderItemDecorationIdentifier("com.freemount.decoration.pinned")
    public static let pinnedFolderDecoration = NSFileProviderItemDecorationIdentifier("com.freemount.decoration.pinnedFolder")

    public var decorations: [NSFileProviderItemDecorationIdentifier]? {
        if isPinned {
            return isDirectory
                ? [Self.pinnedFolderDecoration, Self.pinnedDecoration]
                : [Self.pinnedDecoration]
        }
        return nil
    }

    public var userInfo: [AnyHashable: Any]? {
        return ["isPinned": isPinned ? 1 : 0]
    }

    public var contentPolicy: NSFileProviderContentPolicy {
        return isPinned ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }

    public init(
        itemIdentifier: NSFileProviderItemIdentifier,
        parentItemIdentifier: NSFileProviderItemIdentifier,
        filename: String,
        contentType: UTType,
        capabilities: NSFileProviderItemCapabilities,
        documentSize: NSNumber? = nil,
        contentModificationDate: Date? = nil,
        itemVersion: NSFileProviderItemVersion,
        isDirectory: Bool,
        remotePath: String,
        remoteObjectID: String? = nil,
        isPinned: Bool = false
    ) {
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.contentType = contentType
        self.capabilities = capabilities
        self.documentSize = documentSize
        self.contentModificationDate = contentModificationDate
        self.itemVersion = itemVersion
        self.isDirectory = isDirectory
        self.remotePath = remotePath
        self.remoteObjectID = remoteObjectID
        self.isPinned = isPinned
        super.init()
    }

    /// Constructs the root container item
    public static func root(
        displayName: String,
        isReadOnly: Bool = false
    ) -> FreeMountFileProviderItem {
        let caps: NSFileProviderItemCapabilities = isReadOnly
            ? [.allowsReading, .allowsContentEnumerating]
            : [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems]

        let versionData = Data("root.v1".utf8)
        let metadata = Data("root.v2:\(displayName):\(isReadOnly ? "ro1" : "ro0")".utf8)
        let version = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: metadata)

        return FreeMountFileProviderItem(
            itemIdentifier: .rootContainer,
            parentItemIdentifier: .rootContainer,
            filename: displayName,
            contentType: .folder,
            capabilities: caps,
            documentSize: nil,
            contentModificationDate: nil,
            itemVersion: version,
            isDirectory: true,
            remotePath: "",
            remoteObjectID: "root"
        )
    }

    /// Constructs a File Provider item from backend remote item metadata
    public convenience init(
        item: FileProviderRemoteItem,
        isReadOnly: Bool = false,
        isPinned: Bool = false
    ) {
        let identifier = NSFileProviderItemIdentifier.remoteItem(path: item.path)
        let parentIdentifier: NSFileProviderItemIdentifier = item.parentPath.isEmpty
            ? .rootContainer
            : .remoteItem(path: item.parentPath)

        let resolvedType = Self.resolveContentType(
            filename: item.filename,
            mimeType: item.contentType,
            isDirectory: item.isDirectory
        )

        let caps: NSFileProviderItemCapabilities
        if isReadOnly || item.isReadOnly {
            caps = item.isDirectory
                ? [.allowsReading, .allowsContentEnumerating, .allowsEvicting]
                : [.allowsReading, .allowsEvicting]
        } else {
            caps = item.isDirectory
                ? [.allowsReading, .allowsWriting, .allowsContentEnumerating, .allowsAddingSubItems, .allowsRenaming, .allowsDeleting, .allowsReparenting, .allowsEvicting]
                : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting, .allowsEvicting]
        }

        let version = Self.makeVersion(
            path: item.path,
            size: item.contentSize,
            modifiedAt: item.modifiedAt,
            remoteObjectID: item.remoteObjectID,
            isPinned: isPinned,
            isReadOnly: isReadOnly || item.isReadOnly
        )

        self.init(
            itemIdentifier: identifier,
            parentItemIdentifier: parentIdentifier,
            filename: item.filename,
            contentType: resolvedType,
            capabilities: caps,
            documentSize: item.isDirectory ? nil : NSNumber(value: item.contentSize),
            contentModificationDate: item.modifiedAt,
            itemVersion: version,
            isDirectory: item.isDirectory,
            remotePath: item.path,
            remoteObjectID: item.remoteObjectID,
            isPinned: isPinned
        )
    }

    // MARK: - Private Helpers

    public static func resolveContentType(
        filename: String,
        mimeType: String?,
        isDirectory: Bool
    ) -> UTType {
        if isDirectory {
            return .folder
        }
        if let mime = mimeType, !mime.isEmpty, let utType = UTType(mimeType: mime) {
            return utType
        }
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return utType
        }
        return .data
    }

    public static func makeVersion(
        path: String,
        size: Int64,
        modifiedAt: Date?,
        remoteObjectID: String?,
        isPinned: Bool = false,
        isReadOnly: Bool = false
    ) -> NSFileProviderItemVersion {
        let idPart = remoteObjectID ?? "none"
        let datePart = modifiedAt?.timeIntervalSince1970 ?? 0
        let contentTag = "\(path):\(size):\(datePart):\(idPart)"
        let metaTag = "\(contentTag):\(isPinned ? "pin1" : "pin0"):\(isReadOnly ? "ro1" : "ro0")"
        return NSFileProviderItemVersion(
            contentVersion: Data(contentTag.utf8),
            metadataVersion: Data(metaTag.utf8)
        )
    }
}
