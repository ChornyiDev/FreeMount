import Foundation

/// Finder paths must round-trip byte-for-byte; never repair an object name.
public enum GoogleCloudPathPolicy {
    public static func validate(_ path: String, allowRoot: Bool = true) throws -> String {
        if path.isEmpty, allowRoot { return path }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              Array(path.utf8) == Array(try FileProviderPath.normalize(path).utf8) else {
            throw GoogleCloudStorageError.unsupportedObjectNames("The object path cannot be represented without changing its name.")
        }
        return path
    }
    static func finderKey(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    static func partition(_ items: [RcloneListedItem], parent: String) -> (supported: [RcloneListedItem], omitted: Int) {
        let groups = Dictionary(grouping: items, by: { finderKey($0.path) })
        let supported = items.filter {
            (try? validate($0.path, allowRoot: false)) != nil &&
            Array(FileProviderPath.parent(of: $0.path).utf8) == Array(parent.utf8) &&
            groups[finderKey($0.path)]?.count == 1
        }
        return (supported, items.count - supported.count)
    }
}
