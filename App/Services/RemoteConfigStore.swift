import Foundation
import os.log

/// Persists only non-secret remote metadata. Provider credentials remain in Keychain.
@MainActor
public final class RemoteConfigStore {
    private static let log = Logger(subsystem: "com.freemount.app", category: "RemoteConfigStore")
    private static let storageKey = "remoteConfigurations.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = FreeMountDefaults.shared) {
        self.defaults = defaults
    }

    public func load() -> [RemoteConfig] {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return []
        }
        do {
            let remotes = try JSONDecoder().decode([RemoteConfig].self, from: data)
            return remotes
        } catch {
            Self.log.error("Failed to decode remote configurations: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    public func save(_ remotes: [RemoteConfig]) {
        do {
            let data = try JSONEncoder().encode(remotes)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            Self.log.error("Failed to encode remote configurations: \(error.localizedDescription, privacy: .public)")
        }
    }

}
