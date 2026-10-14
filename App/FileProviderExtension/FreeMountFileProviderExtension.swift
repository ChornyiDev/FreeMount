import FileProvider
import Foundation
import os.log
import UniformTypeIdentifiers

/// Entry point for the embedded replicated File Provider extension.
///
/// The host application registers domains; macOS creates one instance of this
/// class for each domain. Backend operations are resolved through the shared
/// provider registry using the App Group domain configuration.
@objc(FreeMountFileProviderExtension)
final class FreeMountFileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderCustomAction {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FreeMountFileProviderExtension")

    private let domain: NSFileProviderDomain
    private let store: FileProviderDomainStore
    private let itemCache: NSCache<NSString, FreeMountFileProviderItem>
    private let connectionBackend: FileProviderConnectionBackend
    private var cachedConnection: FileProviderConnectionDescriptor?
    private let lock = NSLock()

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let store = FileProviderDomainStore()
        self.store = store
        self.connectionBackend = FileProviderConnectionBackend(domainIdentifier: domain.identifier.rawValue, store: store)
        self.itemCache = NSCache<NSString, FreeMountFileProviderItem>()
        super.init()
        Self.log.info("Initialized extension for domain: \(domain.identifier.rawValue, privacy: .public)")
    }

    func invalidate() {
        itemCache.removeAllObjects()
    }

    func makeProviderItem(
        for remoteItem: FileProviderRemoteItem,
        isReadOnly: Bool
    ) -> FreeMountFileProviderItem {
        let isPinned = store.isOrInheritsPinned(remoteItem.path, forDomain: domain.identifier.rawValue)
        return FreeMountFileProviderItem(
            item: remoteItem,
            isReadOnly: isReadOnly,
            isPinned: isPinned
        )
    }

    // MARK: - Backend Resolution

    func resolveBackend() throws -> (backend: any FileProviderBackend, connection: FileProviderConnectionDescriptor) {
        lock.lock()
        defer { lock.unlock() }

        guard let connection = try store.connection(forDomainIdentifier: domain.identifier.rawValue) else {
            Self.log.error("Failed to find connection for domain identifier: \(self.domain.identifier.rawValue, privacy: .public)")
            throw NSFileProviderError(.notAuthenticated)
        }

        if cachedConnection != connection {
            cachedConnection = connection
            itemCache.removeAllObjects()
        }
        return (connectionBackend, connection)
    }

    // MARK: - NSFileProviderReplicatedExtension Item Retrieval

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        do { _ = try resolveBackend() }
        catch {
            completionHandler(nil, Self.mapError(error))
            return progress
        }

        if identifier == .rootContainer {
            let connection: FileProviderConnectionDescriptor
            do { connection = try resolveBackend().connection }
            catch { completionHandler(nil, Self.mapError(error)); return progress }
            let rootItem = FreeMountFileProviderItem.root(
                displayName: connection.domain.displayName,
                isReadOnly: connection.isReadOnly
            )
            progress.completedUnitCount = 1
            completionHandler(rootItem, nil)
            return progress
        }

        if let cached = itemCache.object(forKey: identifier.rawValue as NSString) {
            let currentPinned = identifier.remoteRelativePath.map {
                store.isOrInheritsPinned($0, forDomain: domain.identifier.rawValue)
            } ?? false
            if cached.isPinned == currentPinned {
                progress.completedUnitCount = 1
                completionHandler(cached, nil)
                return progress
            }
        }

        guard let relativePath = identifier.remoteRelativePath else {
            progress.completedUnitCount = 1
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let task = Task {
            do {
                let (backend, connection) = try self.resolveBackend()
                if let remoteItem = try await backend.stat(at: relativePath) {
                    let providerItem = self.makeProviderItem(
                        for: remoteItem,
                        isReadOnly: connection.isReadOnly
                    )
                    self.itemCache.setObject(providerItem, forKey: identifier.rawValue as NSString)
                    progress.completedUnitCount = 1
                    completionHandler(providerItem, nil)
                } else {
                    progress.completedUnitCount = 1
                    completionHandler(nil, NSFileProviderError(.noSuchItem))
                }
            } catch {
                progress.completedUnitCount = 1
                completionHandler(nil, Self.mapError(error))
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }
        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        Self.log.info("Requesting enumerator for container: \(containerItemIdentifier.rawValue, privacy: .public)")

        if containerItemIdentifier == .workingSet {
            let (backend, connection) = try resolveBackend()
            return FreeMountWorkingSetEnumerator(
                domainIdentifier: domain.identifier.rawValue,
                backend: backend,
                itemCache: itemCache
            )
        }

        guard containerItemIdentifier == .rootContainer || containerItemIdentifier.remoteRelativePath != nil else {
            throw NSFileProviderError(.noSuchItem)
        }

        let (backend, connection) = try resolveBackend()
        return FreeMountFileProviderEnumerator(
            domainIdentifier: domain.identifier.rawValue,
            containerIdentifier: containerItemIdentifier,
            backend: backend,
            itemCache: itemCache
        )
    }

    // MARK: - Staging & Content Fetching (Stage 2)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard let relativePath = itemIdentifier.remoteRelativePath, !relativePath.isEmpty else {
            let progress = Progress(totalUnitCount: 1)
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        let cachedItem = itemCache.object(forKey: itemIdentifier.rawValue as NSString)
        let estimatedUnits = cachedItem?.documentSize?.int64Value ?? 100
        let progress = Progress(totalUnitCount: max(1, estimatedUnits))

        let downloadTask = Task {
            do {
                try Task.checkCancellation()

                let (backend, connection) = try self.resolveBackend()

                let manager = NSFileProviderManager(for: self.domain)
                let tempDir = try (manager?.temporaryDirectoryURL() ?? FileManager.default.temporaryDirectory)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

                try Task.checkCancellation()

                let downloaded = try await backend.downloadItem(path: relativePath, to: tempDir, requestedVersion: requestedVersion?.contentVersion)
                try Task.checkCancellation()
                let downloadedURL = downloaded.url
                let providerItem = self.makeProviderItem(for: downloaded.item, isReadOnly: connection.isReadOnly)
                self.itemCache.setObject(providerItem, forKey: itemIdentifier.rawValue as NSString)

                progress.completedUnitCount = progress.totalUnitCount
                completionHandler(downloadedURL, providerItem, nil)
            } catch is CancellationError {
                completionHandler(nil, nil, CocoaError(.userCancelled))
            } catch {
                if (error as? CocoaError)?.code == .userCancelled {
                    completionHandler(nil, nil, CocoaError(.userCancelled))
                } else {
                    Self.log.error("Content download failed: \(CredentialRedactor.redact(error.localizedDescription), privacy: .public)")
                    completionHandler(nil, nil, Self.mapError(error))
                }
            }
        }

        progress.cancellationHandler = {
            downloadTask.cancel()
        }

        return progress
    }

    // MARK: - Mutation Operations (Stage 3)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let parentPath = itemTemplate.parentItemIdentifier.remoteRelativePath ?? ""
        let rawPath = parentPath.isEmpty ? itemTemplate.filename : "\(parentPath)/\(itemTemplate.filename)"
        let displayPath = (try? FileProviderPath.normalize(rawPath)) ?? rawPath
        let isDirectory = itemTemplate.contentType == .folder || itemTemplate.contentType?.conforms(to: .folder) == true

        let task = Task {
            do {
                try Task.checkCancellation()

                let (backend, connection) = try self.resolveBackend()
                guard !connection.isReadOnly else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                let parentPath = itemTemplate.parentItemIdentifier.remoteRelativePath ?? ""
                let filename = itemTemplate.filename
                let rawPath = parentPath.isEmpty ? filename : "\(parentPath)/\(filename)"
                let targetPath = try FileProviderPath.validated(rawPath, for: connection.provider)
                guard !targetPath.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let isDirectory = itemTemplate.contentType == .folder || itemTemplate.contentType?.conforms(to: .folder) == true

                try Task.checkCancellation()

                let remoteItem = try await FileProviderMutationCoordinator.create(
                    backend: backend, path: targetPath, isDirectory: isDirectory, contents: url
                )
                if isDirectory { self.store.recordKnownFolder(targetPath, forDomain: self.domain.identifier.rawValue) }

                let createdItem = self.makeProviderItem(for: remoteItem, isReadOnly: connection.isReadOnly)
                self.itemCache.setObject(createdItem, forKey: createdItem.itemIdentifier.rawValue as NSString)
                let parentStore = FileProviderEnumerationSnapshotStore(key: "\(self.domain.identifier.rawValue).\(itemTemplate.parentItemIdentifier.rawValue)")
                parentStore.record(item: createdItem)
                progress.completedUnitCount = 100
                completionHandler(createdItem, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
            } catch {
                if (error as? CocoaError)?.code == .userCancelled {
                    completionHandler(nil, [], false, CocoaError(.userCancelled))
                } else {
                    completionHandler(nil, [], false, Self.mapError(error))
                }
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let currentPath = item.itemIdentifier.remoteRelativePath ?? item.filename
        let newParentPath = item.parentItemIdentifier.remoteRelativePath ?? ""
        let rawTargetPath = newParentPath.isEmpty ? item.filename : "\(newParentPath)/\(item.filename)"
        let targetPath = (try? FileProviderPath.normalize(rawTargetPath)) ?? rawTargetPath
        let task = Task {
            do {
                try Task.checkCancellation()

                let (backend, connection) = try self.resolveBackend()
                guard !connection.isReadOnly else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                guard let currentPath = item.itemIdentifier.remoteRelativePath, !currentPath.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let normalizedCurrent = try FileProviderPath.validated(currentPath, for: connection.provider)

                let newParentPath = item.parentItemIdentifier.remoteRelativePath ?? ""
                let newFilename = item.filename
                let rawNewPath = newParentPath.isEmpty ? newFilename : "\(newParentPath)/\(newFilename)"
                let normalizedTarget = try FileProviderPath.validated(rawNewPath, for: connection.provider)

                guard !normalizedTarget.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }

                try Task.checkCancellation()

                let isRenamedOrMoved = Array(normalizedCurrent.utf8) != Array(normalizedTarget.utf8)
                let remoteItem = try await FileProviderMutationCoordinator.modify(
                    backend: backend, source: normalizedCurrent, destination: normalizedTarget,
                    condition: .contentVersion(version.contentVersion), contents: newContents
                )
                // Publish confirmed success even when cancellation arrived late.
                if isRenamedOrMoved { self.itemCache.removeObject(forKey: item.itemIdentifier.rawValue as NSString) }

                let modifiedItem = self.makeProviderItem(for: remoteItem, isReadOnly: connection.isReadOnly)
                self.itemCache.setObject(modifiedItem, forKey: modifiedItem.itemIdentifier.rawValue as NSString)
                let parentPath = FileProviderPath.parent(of: normalizedTarget)
                let parentIdentifier = parentPath.isEmpty ? NSFileProviderItemIdentifier.rootContainer : NSFileProviderItemIdentifier.remoteItem(path: parentPath)
                let parentStore = FileProviderEnumerationSnapshotStore(key: "\(self.domain.identifier.rawValue).\(parentIdentifier.rawValue)")
                parentStore.record(item: modifiedItem)
                progress.completedUnitCount = 100
                completionHandler(modifiedItem, [], false, nil)
            } catch is CancellationError {
                completionHandler(nil, [], false, CocoaError(.userCancelled))
            } catch {
                if (error as? CocoaError)?.code == .userCancelled {
                    completionHandler(nil, [], false, CocoaError(.userCancelled))
                } else {
                    completionHandler(nil, [], false, Self.mapError(error))
                }
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let displayPath = identifier.remoteRelativePath ?? identifier.rawValue

        let task = Task {
            do {
                try Task.checkCancellation()

                let (backend, connection) = try self.resolveBackend()
                guard !connection.isReadOnly else {
                    throw CocoaError(.fileWriteNoPermission)
                }

                guard let path = identifier.remoteRelativePath, !path.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let normalizedPath = try FileProviderPath.validated(path, for: connection.provider)
                guard !normalizedPath.isEmpty else {
                    throw NSFileProviderError(.noSuchItem)
                }

                try Task.checkCancellation()

                let cachedItem = self.itemCache.object(forKey: identifier.rawValue as NSString)
                let isDirectory = cachedItem?.isDirectory
                let isRecursive = options.contains(.recursive)

                try await backend.deleteItem(at: normalizedPath, condition: .contentVersion(version.contentVersion), recursive: isRecursive)

                self.itemCache.removeObject(forKey: identifier.rawValue as NSString)
                let parentPath = FileProviderPath.parent(of: normalizedPath)
                let parentIdentifier = parentPath.isEmpty ? NSFileProviderItemIdentifier.rootContainer : NSFileProviderItemIdentifier.remoteItem(path: parentPath)
                let parentStore = FileProviderEnumerationSnapshotStore(key: "\(self.domain.identifier.rawValue).\(parentIdentifier.rawValue)")
                parentStore.recordDeleted(identifier: identifier)
                if isDirectory == true {
                    self.store.removeKnownFolder(normalizedPath, forDomain: self.domain.identifier.rawValue)
                }
                progress.completedUnitCount = 100
                completionHandler(nil)
            } catch is CancellationError {
                completionHandler(CocoaError(.userCancelled))
            } catch {
                if (error as? CocoaError)?.code == .userCancelled {
                    completionHandler(CocoaError(.userCancelled))
                } else {
                    completionHandler(Self.mapError(error))
                }
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }

        return progress
    }

    // MARK: - Error Mapping

    public static func mapError(_ error: Error) -> Error {
        FreeMountFileProviderErrorMapping.map(error)
    }
}

// MARK: - Enumerator Implementation

public final class FreeMountFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FreeMountFileProviderEnumerator")

    private let containerIdentifier: NSFileProviderItemIdentifier
    private let domainIdentifier: String
    private let backend: any FileProviderBackend
    private let itemCache: NSCache<NSString, FreeMountFileProviderItem>
    private let changeStore: FileProviderEnumerationSnapshotStore

    public init(
        domainIdentifier: String,
        containerIdentifier: NSFileProviderItemIdentifier,
        backend: any FileProviderBackend,
        itemCache: NSCache<NSString, FreeMountFileProviderItem>
    ) {
        self.domainIdentifier = domainIdentifier
        self.containerIdentifier = containerIdentifier
        self.backend = backend
        self.itemCache = itemCache
        self.changeStore = FileProviderEnumerationSnapshotStore(key: "\(domainIdentifier).\(containerIdentifier.rawValue)")
        super.init()
    }

    public func invalidate() {
        // No persistent handle to release
    }

    public func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let path = containerIdentifier.remoteRelativePath ?? ""
        Self.log.info("Enumerating items for path: '\(path, privacy: .public)'")

        Task {
            do {
                let children = try await backend.listChildren(at: path)
                Self.log.info("Found \(children.count) remote children for path: '\(path, privacy: .public)'")
                let store = FileProviderDomainStore()
                for child in children where child.isDirectory {
                    store.recordKnownFolder(child.path, forDomain: self.domainIdentifier)
                }
                let items: [FreeMountFileProviderItem] = children.map { remoteItem in
                    let isPinned = store.isOrInheritsPinned(remoteItem.path, forDomain: self.domainIdentifier)
                    let providerItem = FreeMountFileProviderItem(
                        item: remoteItem,
                        isReadOnly: false,
                        isPinned: isPinned
                    )
                    itemCache.setObject(providerItem, forKey: providerItem.itemIdentifier.rawValue as NSString)
                    return providerItem
                }

                observer.didEnumerate(items)
                self.changeStore.bootstrap(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                Self.log.error("Failed to enumerate items: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(FreeMountFileProviderExtension.mapError(error))
            }
        }
    }

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        let path = containerIdentifier.remoteRelativePath ?? ""
        Task {
            do {
                let children = try await backend.listChildren(at: path)
                let store = FileProviderDomainStore()
                for child in children where child.isDirectory {
                    store.recordKnownFolder(child.path, forDomain: self.domainIdentifier)
                }
                let items = children.map { remoteItem in
                    let isPinned = store.isOrInheritsPinned(remoteItem.path, forDomain: self.domainIdentifier)
                    return FreeMountFileProviderItem(item: remoteItem, isReadOnly: false, isPinned: isPinned)
                }
                let changes = changeStore.changes(from: syncAnchor, to: items)
                for item in changes.updated {
                    itemCache.setObject(item, forKey: item.itemIdentifier.rawValue as NSString)
                }
                for identifier in changes.deleted {
                    itemCache.removeObject(forKey: identifier.rawValue as NSString)
                }
                observer.didUpdate(changes.updated)
                observer.didDeleteItems(withIdentifiers: changes.deleted)
                observer.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(FreeMountFileProviderExtension.mapError(error))
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let path = containerIdentifier.remoteRelativePath ?? ""
        Task {
            do {
                let children = try await backend.listChildren(at: path)
                let store = FileProviderDomainStore()
                let items = children.map { remoteItem in
                    let isPinned = store.isOrInheritsPinned(remoteItem.path, forDomain: self.domainIdentifier)
                    return FreeMountFileProviderItem(item: remoteItem, isReadOnly: false, isPinned: isPinned)
                }
                let anchor = changeStore.updateAnchor(with: items)
                completionHandler(anchor)
            } catch {
                completionHandler(changeStore.currentAnchor)
            }
        }
    }
}

// MARK: - Working Set Enumerator

public final class FreeMountWorkingSetEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.freemount.app", category: "WorkingSetEnumerator")

    private let domainIdentifier: String
    private let backend: any FileProviderBackend
    private let itemCache: NSCache<NSString, FreeMountFileProviderItem>
    private let changeStore: FileProviderEnumerationSnapshotStore
    private var isInvalidated = false
    private let lock = NSLock()

    public init(
        domainIdentifier: String,
        backend: any FileProviderBackend,
        itemCache: NSCache<NSString, FreeMountFileProviderItem>
    ) {
        self.domainIdentifier = domainIdentifier
        self.backend = backend
        self.itemCache = itemCache
        self.changeStore = FileProviderEnumerationSnapshotStore(key: "\(domainIdentifier).\(NSFileProviderItemIdentifier.workingSet.rawValue)")
        super.init()
    }

    public func invalidate() {
        lock.withLock {
            isInvalidated = true
        }
    }

    public func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        Self.log.info("Enumerating working set items for domain: \(self.domainIdentifier, privacy: .public)")

        Task {
            do {
                let items = try await fetchWorkingSetItems()
                Self.log.info("Found \(items.count) items in working set")
                for item in items {
                    itemCache.setObject(item, forKey: item.itemIdentifier.rawValue as NSString)
                }
                observer.didEnumerate(items)
                self.changeStore.bootstrap(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                Self.log.error("Failed to enumerate working set items: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(FreeMountFileProviderExtension.mapError(error))
            }
        }
    }

    public func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        Self.log.info("Enumerating working set changes for domain: \(self.domainIdentifier, privacy: .public)")

        Task {
            do {
                let items = try await fetchWorkingSetItems()
                let changes = changeStore.changes(from: syncAnchor, to: items)
                for item in changes.updated {
                    itemCache.setObject(item, forKey: item.itemIdentifier.rawValue as NSString)
                }
                for identifier in changes.deleted {
                    itemCache.removeObject(forKey: identifier.rawValue as NSString)
                }
                observer.didUpdate(changes.updated)
                observer.didDeleteItems(withIdentifiers: changes.deleted)
                observer.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
            } catch {
                Self.log.error("Failed to enumerate working set changes: \(error.localizedDescription, privacy: .public)")
                observer.finishEnumeratingWithError(FreeMountFileProviderExtension.mapError(error))
            }
        }
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        Task {
            do {
                let items = try await fetchWorkingSetItems()
                let anchor = changeStore.updateAnchor(with: items)
                completionHandler(anchor)
            } catch {
                completionHandler(changeStore.currentAnchor)
            }
        }
    }

    private func fetchWorkingSetItems() async throws -> [FreeMountFileProviderItem] {
        let store = FileProviderDomainStore()
        guard let provider = try store.connection(forDomainIdentifier: domainIdentifier)?.provider else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let remoteItems = try await FileProviderWorkingSetCollector(backend: backend).collect(
            pinnedPaths: store.pinnedPaths(forDomain: domainIdentifier), provider: provider
        )
        try Task.checkCancellation()
        guard !lock.withLock({ isInvalidated }) else { throw CancellationError() }
        return remoteItems.map { child in
            if child.isDirectory { store.recordKnownFolder(child.path, forDomain: domainIdentifier) }
            return FreeMountFileProviderItem(item: child, isReadOnly: false,
                isPinned: store.isOrInheritsPinned(child.path, forDomain: domainIdentifier))
        }
    }

}

// MARK: - NSFileProviderCustomAction

extension FreeMountFileProviderExtension {
    static let makeAvailableOfflineAction = NSFileProviderExtensionActionIdentifier("com.freemount.action.makeAvailableOffline")
    static let removeOfflineCopyAction = NSFileProviderExtensionActionIdentifier("com.freemount.action.removeOfflineCopy")

    public func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let domainId = domain.identifier.rawValue
        let task = Task {
            do {
                guard let manager = NSFileProviderManager(for: self.domain) else {
                    throw NSFileProviderError(.providerNotFound)
                }
                let (backend, _) = try self.resolveBackend()

                switch actionIdentifier {
                case Self.makeAvailableOfflineAction:
                    Self.log.info("Performing makeAvailableOffline for \(itemIdentifiers.count) items")
                    var downloadIdentifiers: [NSFileProviderItemIdentifier] = []
                    for identifier in itemIdentifiers {
                        guard let relativePath = identifier.remoteRelativePath else { continue }
                        self.store.recordPinned(relativePath, forDomain: domainId)

                        if let item = try await backend.stat(at: relativePath), item.isDirectory {
                            self.store.recordKnownFolder(relativePath, forDomain: domainId)
                            downloadIdentifiers.append(contentsOf: try await self.collectDownloadIdentifiers(
                                at: relativePath,
                                backend: backend
                            ))
                        } else {
                            downloadIdentifiers.append(identifier)
                        }

                        self.itemCache.removeObject(forKey: identifier.rawValue as NSString)
                    }

                    progress.totalUnitCount = Int64(downloadIdentifiers.count)
                    progress.completedUnitCount = 0

                    for identifier in downloadIdentifiers {
                        try Task.checkCancellation()
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            manager.requestDownloadForItem(withIdentifier: identifier, requestedRange: nil) { error in
                                if let error { continuation.resume(throwing: error) }
                                else { continuation.resume() }
                            }
                        }
                        self.itemCache.removeObject(forKey: identifier.rawValue as NSString)
                        progress.completedUnitCount += 1
                    }

                    try? await manager.signalEnumerator(for: .workingSet)
                    for identifier in itemIdentifiers {
                        try? await manager.signalEnumerator(for: identifier)
                        if let path = identifier.remoteRelativePath {
                            let parent = FileProviderPath.parent(of: path)
                            let parentId: NSFileProviderItemIdentifier = parent.isEmpty ? .rootContainer : .remoteItem(path: parent)
                            try? await manager.signalEnumerator(for: parentId)
                        }
                    }
                    completionHandler(nil)

                case Self.removeOfflineCopyAction:
                    Self.log.info("Performing removeOfflineCopy for \(itemIdentifiers.count) items")
                    for identifier in itemIdentifiers {
                        guard let relativePath = identifier.remoteRelativePath else { continue }
                        self.store.removePinned(relativePath, forDomain: domainId)
                        self.itemCache.removeObject(forKey: identifier.rawValue as NSString)
                    }

                    // First, notify macOS that items are no longer pinned (updates contentPolicy to .downloadLazily and capabilities to .allowsEvicting)
                    try? await manager.signalEnumerator(for: .workingSet)
                    for identifier in itemIdentifiers {
                        try? await manager.signalEnumerator(for: identifier)
                        if let path = identifier.remoteRelativePath {
                            let parent = FileProviderPath.parent(of: path)
                            let parentId: NSFileProviderItemIdentifier = parent.isEmpty ? .rootContainer : .remoteItem(path: parent)
                            try? await manager.signalEnumerator(for: parentId)
                        }
                    }

                    // Brief pause to allow FPFS to ingest updated item metadata
                    try? await Task.sleep(for: .milliseconds(150))

                    for identifier in itemIdentifiers {
                        guard let relativePath = identifier.remoteRelativePath else { continue }
                        if let item = try await backend.stat(at: relativePath), item.isDirectory {
                            try await self.evictDescendants(at: relativePath, backend: backend, manager: manager)
                        } else {
                            try await self.evictItem(identifier, manager: manager)
                        }
                        progress.completedUnitCount += 1
                    }

                    // Signal again so Finder reflects final cloud state
                    try? await manager.signalEnumerator(for: .workingSet)
                    for identifier in itemIdentifiers {
                        try? await manager.signalEnumerator(for: identifier)
                    }
                    completionHandler(nil)

                default:
                    Self.log.warning("Unsupported action identifier: \(actionIdentifier.rawValue, privacy: .public)")
                    completionHandler(CocoaError(.featureUnsupported))
                }
            } catch {
                Self.log.error("Error executing custom action: \(error.localizedDescription, privacy: .public)")
                completionHandler(FreeMountFileProviderExtension.mapError(error))
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }
        return progress
    }

    private func collectDownloadIdentifiers(at folderPath: String, backend: any FileProviderBackend) async throws -> [NSFileProviderItemIdentifier] {
        let children = try await FileProviderTreeReader.read(at: [folderPath]) { try await backend.listChildren(at: $0) }
        for child in children where child.isDirectory {
            store.recordKnownFolder(child.path, forDomain: domain.identifier.rawValue)
        }
        return children.filter { !$0.isDirectory }.map { .remoteItem(path: $0.path) }
    }

    private func evictItem(_ identifier: NSFileProviderItemIdentifier, manager: NSFileProviderManager) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        itemCache.removeObject(forKey: identifier.rawValue as NSString)
    }

    private func evictDescendants(at folderPath: String, backend: any FileProviderBackend, manager: NSFileProviderManager) async throws {
        let identifiers = try await collectDownloadIdentifiers(at: folderPath, backend: backend)
        for identifier in identifiers { try await evictItem(identifier, manager: manager) }
    }
}
