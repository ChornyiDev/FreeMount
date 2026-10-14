import Foundation

public enum FileProviderInventoryError: LocalizedError, Sendable {
    case inventoryLimitExceeded
    case invalidChildPath

    public var errorDescription: String? {
        switch self {
        case .inventoryLimitExceeded: return "The remote inventory exceeds the supported size and cannot be read completely."
        case .invalidChildPath: return "The storage engine returned an invalid inventory child path."
        }
    }
}

/// An inventory is returned only after every required read succeeds. Callers
/// must not update snapshots or publish deletions before this method returns.
public struct FileProviderWorkingSetCollector: Sendable {
    private let backend: any FileProviderBackend
    private let itemLimit: Int
    private let directoryLimit: Int

    public init(backend: any FileProviderBackend, itemLimit: Int = 100_000, directoryLimit: Int = 10_000) {
        self.backend = backend
        self.itemLimit = itemLimit
        self.directoryLimit = directoryLimit
    }

    public func collect(pinnedPaths: [String], provider: ProviderID) async throws -> [FileProviderRemoteItem] {
        try Task.checkCancellation()
        var items: [String: FileProviderRemoteItem] = [:]
        var folders: [String] = []
        let roots = try await backend.listChildren(at: "")
        for item in roots {
            guard !item.path.isEmpty, FileProviderPath.parent(of: item.path).isEmpty else { throw FileProviderInventoryError.invalidChildPath }
            items[item.path] = item
        }
        for pinned in pinnedPaths {
            try Task.checkCancellation()
            let path = try FileProviderPath.validated(pinned, for: provider)
            if path.isEmpty { folders.append(""); continue }
            let value: FileProviderRemoteItem?
            if let known = items[path] { value = known }
            else { value = try await backend.stat(at: path) }
            // A successful nil stat establishes absence; a failed stat throws.
            if let value {
                items[value.path] = value
                if value.isDirectory { folders.append(value.path) }
            }
        }
        let descendants = try await FileProviderTreeReader.read(at: folders, itemLimit: itemLimit, directoryLimit: directoryLimit) { path in
            path.isEmpty ? roots : try await backend.listChildren(at: path)
        }
        for child in descendants { items[child.path] = child }
        try Task.checkCancellation()
        guard items.count <= itemLimit else { throw FileProviderInventoryError.inventoryLimitExceeded }
        return items.values.sorted { $0.path < $1.path }
    }
}

/// Complete bounded traversal shared by inventory, offline actions and GCS moves.
/// The caller supplies provider-specific listing validation; no errors are hidden.
enum FileProviderTreeReader {
    static func read(at roots: [String], itemLimit: Int = 100_000, directoryLimit: Int = 10_000,
                     list: (String) async throws -> [FileProviderRemoteItem]) async throws -> [FileProviderRemoteItem] {
        var folders = roots
        var visited = Set<String>()
        var items: [String: FileProviderRemoteItem] = [:]
        var index = 0
        while index < folders.count {
            try Task.checkCancellation()
            let path = folders[index]
            index += 1
            guard visited.insert(path).inserted else { continue }
            guard visited.count <= directoryLimit else { throw FileProviderInventoryError.inventoryLimitExceeded }
            for child in try await list(path) {
                try Task.checkCancellation()
                guard !child.path.isEmpty, Array(FileProviderPath.parent(of: child.path).utf8) == Array(path.utf8) else {
                    throw FileProviderInventoryError.invalidChildPath
                }
                // Repeated pinned roots are allowed; repeated children in a
                // single listing cannot silently overwrite different objects.
                if let old = items[child.path], old != child { throw FileProviderInventoryError.invalidChildPath }
                items[child.path] = child
                if child.isDirectory { folders.append(child.path) }
                guard items.count <= itemLimit else { throw FileProviderInventoryError.inventoryLimitExceeded }
            }
        }
        try Task.checkCancellation()
        return items.values.sorted { $0.path < $1.path }
    }
}
