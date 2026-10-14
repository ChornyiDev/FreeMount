import Foundation

/// Shared with the extension and unit tests. Cancellation is checked before
/// starting; a returned backend result establishes success and is published.
public enum FileProviderMutationCoordinator {
    public static func create(backend: any FileProviderBackend, path: String, isDirectory: Bool, contents: URL?) async throws -> FileProviderRemoteItem {
        try Task.checkCancellation()
        if isDirectory { return try await backend.createDirectoryItem(at: path) }
        if let contents { return try await backend.upload(stagedFile: contents, to: path, condition: .absent) }
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        return try await backend.upload(stagedFile: empty, to: path, condition: .absent)
    }

    public static func modify(backend: any FileProviderBackend, source: String, destination: String,
                              condition: FileProviderMutationCondition, contents: URL?) async throws -> FileProviderRemoteItem {
        try Task.checkCancellation()
        let moved = Array(source.utf8) != Array(destination.utf8)
        if let contents {
            if moved { return try await backend.replaceAndMove(stagedFile: contents, from: source, to: destination, condition: condition) }
            return try await backend.upload(stagedFile: contents, to: destination, condition: condition)
        }
        if moved { return try await backend.move(from: source, to: destination, condition: condition) }
        guard let current = try await backend.stat(at: source) else { throw FileProviderMutationError.versionConflict }
        try current.check(condition)
        return current
    }
}
