import Foundation

/// In-memory `UserDefaults` replacement for unit and integration tests.
///
/// Prevents creating or leaving orphaned `.plist` files in `~/Library/Preferences/`.
public final class EphemeralUserDefaults: UserDefaults {
    private let lock = NSLock()
    private var storage = [String: Any]()

    public init() {
        super.init(suiteName: nil)!
    }

    public override init?(suiteName suitename: String?) {
        super.init(suiteName: nil)!
    }

    public override func object(forKey defaultName: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[defaultName] = value
    }

    public override func removeObject(forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: defaultName)
    }

    public override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    public override func bool(forKey defaultName: String) -> Bool {
        if let num = object(forKey: defaultName) as? NSNumber {
            return num.boolValue
        }
        return object(forKey: defaultName) as? Bool ?? false
    }

    public override func integer(forKey defaultName: String) -> Int {
        if let num = object(forKey: defaultName) as? NSNumber {
            return num.intValue
        }
        return object(forKey: defaultName) as? Int ?? 0
    }

    public override func double(forKey defaultName: String) -> Double {
        if let num = object(forKey: defaultName) as? NSNumber {
            return num.doubleValue
        }
        return object(forKey: defaultName) as? Double ?? 0.0
    }

    public override func float(forKey defaultName: String) -> Float {
        if let num = object(forKey: defaultName) as? NSNumber {
            return num.floatValue
        }
        return object(forKey: defaultName) as? Float ?? 0.0
    }

    public override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    public override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    public override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public override func synchronize() -> Bool {
        return true
    }

    public override func removePersistentDomain(forName domainName: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }

    /// Automatically scans and removes any orphaned test preferences from ~/Library/Preferences.
    public static func cleanAllTestPreferences() {
        guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let prefsURL = libraryURL.appendingPathComponent("Preferences")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: prefsURL.path) else { return }
        let prefixes = [
            "FreeMountTests.",
            "FreeMountSnapshotTests.",
            "FileProviderDomainRegistryTests.",
            "FileProviderDomainStoreTests."
        ]
        for file in files {
            if prefixes.contains(where: { file.hasPrefix($0) }) && file.hasSuffix(".plist") {
                let fileURL = prefsURL.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
