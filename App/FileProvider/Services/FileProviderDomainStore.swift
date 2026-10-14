import Foundation
import FileProvider
import os.log

/// Persists only File Provider domain identities in the shared App Group.
///
/// The extension uses this catalog to resolve a macOS domain identifier to a
/// FreeMount remote UUID. OAuth tokens and rclone backend options are excluded.
public final class FileProviderDomainStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FileProviderDomainStore")
    private static let storageKey = "fileProviderDomains.v1"

    public static var appGroupIdentifier: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.isEmpty,
           !configured.contains("$(") {
            return configured
        }
        if let bundle = Bundle(identifier: "com.freemount.app"),
           let configured = bundle.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
           !configured.isEmpty,
           !configured.contains("$(") {
            return configured
        }
        return "group.com.freemount.shared"
    }

    private let defaults: UserDefaults
    private let catalogURL: URL?
    private let usesIsolatedDefaults: Bool
    private let legacyCatalogURLs: [URL]
    private let permitsMigration: Bool
    private let legacyDefaults: UserDefaults?
    private static let catalogLock = NSRecursiveLock()
    private var lock: NSRecursiveLock { Self.catalogLock }

    /// Injected defaults provide isolated test storage; production has one file.
    public init(defaults: UserDefaults? = nil, catalogURL: URL? = nil, legacyCatalogURLs: [URL]? = nil, permitsMigration: Bool = Bundle.main.bundleURL.pathExtension != "appex") {
        self.permitsMigration = permitsMigration
        self.legacyDefaults = defaults == nil ? UserDefaults(suiteName: "group.com.freemount.shared") : nil
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        self.legacyCatalogURLs = legacyCatalogURLs ?? (defaults == nil ? ["group.com.freemount.shared"].compactMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)?.appendingPathComponent("fileProviderDomains.json")
        } : [])
        self.usesIsolatedDefaults = defaults != nil && catalogURL == nil
        self.catalogURL = catalogURL ?? (defaults == nil ? FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        )?.appendingPathComponent("fileProviderDomains.json") : nil)
    }

    public func all() throws -> [FileProviderConnectionDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return try decodedDomains()
    }

    public func connection(forDomainIdentifier identifier: String) throws -> FileProviderConnectionDescriptor? {
        try all().first { $0.domain.domainIdentifier == identifier }
    }

    public func connection(for remoteID: UUID) throws -> FileProviderConnectionDescriptor? {
        try all().first { $0.domain.remoteID == remoteID }
    }

    public func upsert(_ descriptor: FileProviderConnectionDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        var domains = try decodedDomains()
        domains.removeAll { $0.domain.remoteID == descriptor.domain.remoteID }
        domains.append(descriptor)
        try save(domains)
    }

    public func remove(remoteID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var domains = try decodedDomains()
        domains.removeAll { $0.domain.remoteID == remoteID }
        try save(domains)
    }

    private func decodedDomains() throws -> [FileProviderConnectionDescriptor] {
        if usesIsolatedDefaults {
            guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
            return try JSONDecoder().decode([FileProviderConnectionDescriptor].self, from: data)
        }
        guard let catalogURL else { throw FileProviderCatalogError.containerUnavailable }
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            // Valid empty catalogs are authoritative. Corruption is not absence.
            return try JSONDecoder().decode([FileProviderConnectionDescriptor].self, from: Data(contentsOf: catalogURL))
        }
        guard permitsMigration else { throw FileProviderCatalogError.containerUnavailable }
        // Only the host migrates before registering domains; extension reads
        // never publish a stale legacy snapshot over a new host catalog.
        // One-time migration: publish before retiring legacy preferences.
        let legacy: [FileProviderConnectionDescriptor]
        if let file = legacyCatalogURLs.first(where: { $0 != catalogURL && FileManager.default.fileExists(atPath: $0.path) }) {
            legacy = try JSONDecoder().decode([FileProviderConnectionDescriptor].self, from: Data(contentsOf: file))
        } else {
            legacy = try (defaults.data(forKey: Self.storageKey) ?? legacyDefaults?.data(forKey: Self.storageKey)).map {
                try JSONDecoder().decode([FileProviderConnectionDescriptor].self, from: $0)
            } ?? []
        }
        try save(legacy)
        defaults.removeObject(forKey: Self.storageKey)
        legacyDefaults?.removeObject(forKey: Self.storageKey)
        return legacy
    }

    private func save(_ domains: [FileProviderConnectionDescriptor]) throws {
        let data = try JSONEncoder().encode(domains)
        if usesIsolatedDefaults { defaults.set(data, forKey: Self.storageKey); return }
        guard let catalogURL else { throw FileProviderCatalogError.containerUnavailable }
        try data.write(to: catalogURL, options: .atomic)
    }

    public func recordKnownFolder(_ path: String, forDomain domainIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        guard !normalized.isEmpty else { return }
        let key = "fileProviderKnownFolders.v1.\(domainIdentifier)"
        var folders = Set(defaults.stringArray(forKey: key) ?? [])
        if !folders.contains(normalized) {
            folders.insert(normalized)
            defaults.set(Array(folders), forKey: key)
        }
    }

    public func removeKnownFolder(_ path: String, forDomain domainIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        let key = "fileProviderKnownFolders.v1.\(domainIdentifier)"
        var folders = Set(defaults.stringArray(forKey: key) ?? [])
        if folders.contains(normalized) {
            folders.remove(normalized)
            defaults.set(Array(folders), forKey: key)
        }
    }

    public func knownFolders(forDomain domainIdentifier: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let key = "fileProviderKnownFolders.v1.\(domainIdentifier)"
        return defaults.stringArray(forKey: key) ?? []
    }

    // MARK: - Pinned (Offline) Items Management

    public func recordPinned(_ path: String, forDomain domainIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        guard !normalized.isEmpty else { return }
        let key = "fileProviderPinnedPaths.v1.\(domainIdentifier)"
        var pinned = Set(defaults.stringArray(forKey: key) ?? [])
        if !pinned.contains(normalized) {
            pinned.insert(normalized)
            defaults.set(Array(pinned), forKey: key)
        }
    }

    public func removePinned(_ path: String, forDomain domainIdentifier: String) {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        let key = "fileProviderPinnedPaths.v1.\(domainIdentifier)"
        var pinned = Set(defaults.stringArray(forKey: key) ?? [])
        let toRemove = pinned.filter { $0 == normalized || $0.hasPrefix(normalized + "/") }
        if !toRemove.isEmpty {
            for item in toRemove {
                pinned.remove(item)
            }
            defaults.set(Array(pinned), forKey: key)
        }
    }

    public func pinnedPaths(forDomain domainIdentifier: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let key = "fileProviderPinnedPaths.v1.\(domainIdentifier)"
        return defaults.stringArray(forKey: key) ?? []
    }

    public func isPinned(_ path: String, forDomain domainIdentifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        let key = "fileProviderPinnedPaths.v1.\(domainIdentifier)"
        let pinned = Set(defaults.stringArray(forKey: key) ?? [])
        return pinned.contains(normalized)
    }

    public func isOrInheritsPinned(_ path: String, forDomain domainIdentifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let normalized = (try? FileProviderPath.normalize(path)) ?? path
        guard !normalized.isEmpty else { return false }
        let key = "fileProviderPinnedPaths.v1.\(domainIdentifier)"
        let pinned = Set(defaults.stringArray(forKey: key) ?? [])
        if pinned.contains(normalized) {
            return true
        }
        var current = (normalized as NSString).deletingLastPathComponent
        while !current.isEmpty && current != "/" && current != "." {
            if pinned.contains(current) {
                return true
            }
            let next = (current as NSString).deletingLastPathComponent
            if next == current { break }
            current = next
        }
        return false
    }
}

/// Saves directory snapshots across extension restarts so a signaled enumerator
/// can report remote additions, edits, and deletions since macOS's last anchor.
final class FileProviderEnumerationSnapshotStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.freemount.app", category: "FileProviderEnumerationSnapshotStore")
    private struct Snapshot: Codable {
        let revision: String
        let versions: [String: String]
    }

    private static let lock = NSRecursiveLock()
    private let key: String
    private let defaults: UserDefaults

    init(key: String, defaults: UserDefaults? = nil) {
        self.key = "fileProviderSnapshot.v1.\(key)"
        self.defaults = defaults ?? UserDefaults(suiteName: FileProviderDomainStore.appGroupIdentifier) ?? .standard
    }

    var currentAnchor: NSFileProviderSyncAnchor {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let latest = snapshots().last?.revision ?? "initial"
        return NSFileProviderSyncAnchor(Data(latest.utf8))
    }

    func bootstrap(_ items: [FreeMountFileProviderItem]) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard snapshots().isEmpty else { return }
        save([Snapshot(revision: UUID().uuidString, versions: versions(of: items))])
    }

    func updateAnchor(with items: [FreeMountFileProviderItem]) -> NSFileProviderSyncAnchor {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var history = snapshots()
        let next = versions(of: items)
        if history.isEmpty {
            let newRev = UUID().uuidString
            save([Snapshot(revision: newRev, versions: next)])
            return NSFileProviderSyncAnchor(Data(newRev.utf8))
        }
        if history.last?.versions != next {
            let newRev = UUID().uuidString
            history.append(Snapshot(revision: newRev, versions: next))
            save(Array(history.suffix(10)))
            return NSFileProviderSyncAnchor(Data(newRev.utf8))
        }
        let currentRev = history.last?.revision ?? "initial"
        return NSFileProviderSyncAnchor(Data(currentRev.utf8))
    }

    func record(item: FreeMountFileProviderItem) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var history = snapshots()
        var current = history.last?.versions ?? [:]
        current[item.itemIdentifier.rawValue] = "\(item.itemVersion.contentVersion.base64EncodedString()):\(item.itemVersion.metadataVersion.base64EncodedString())"
        history.append(Snapshot(revision: UUID().uuidString, versions: current))
        save(Array(history.suffix(10)))
    }

    func recordDeleted(identifier: NSFileProviderItemIdentifier) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var history = snapshots()
        var current = history.last?.versions ?? [:]
        current.removeValue(forKey: identifier.rawValue)
        history.append(Snapshot(revision: UUID().uuidString, versions: current))
        save(Array(history.suffix(10)))
    }

    func changes(
        from anchor: NSFileProviderSyncAnchor,
        to items: [FreeMountFileProviderItem]
    ) -> (updated: [FreeMountFileProviderItem], deleted: [NSFileProviderItemIdentifier], anchor: NSFileProviderSyncAnchor) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var history = snapshots()
        let oldRevision = String(data: anchor.rawValue, encoding: .utf8)
        let old = history.first { $0.revision == oldRevision }?.versions ?? history.last?.versions ?? [:]
        let next = versions(of: items)
        if history.isEmpty || history.last?.versions != next {
            history.append(Snapshot(revision: UUID().uuidString, versions: next))
            save(Array(history.suffix(10)))
        }
        let updated = items.filter { old[$0.itemIdentifier.rawValue] != next[$0.itemIdentifier.rawValue] }
        let deleted = old.keys.filter { next[$0] == nil }.map { NSFileProviderItemIdentifier($0) }
        let revision = history.last?.revision ?? "initial"
        return (updated, deleted, NSFileProviderSyncAnchor(Data(revision.utf8)))
    }

    private func versions(of items: [FreeMountFileProviderItem]) -> [String: String] {
        var result: [String: String] = [:]
        for item in items {
            let identifier = item.itemIdentifier.rawValue
            if result[identifier] != nil {
                Self.log.fault("Ignoring duplicate File Provider identifier: \(identifier, privacy: .public)")
                continue
            }
            let tag = "\(item.itemVersion.contentVersion.base64EncodedString()):\(item.itemVersion.metadataVersion.base64EncodedString())"
            result[identifier] = tag
        }
        return result
    }

    private func snapshots() -> [Snapshot] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Snapshot].self, from: data)) ?? []
    }

    private func save(_ snapshots: [Snapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: key)
    }
}

public enum FileProviderCatalogError: LocalizedError, Sendable {
    case containerUnavailable
    public var errorDescription: String? { "FreeMount's shared connection catalog is unavailable." }
}
