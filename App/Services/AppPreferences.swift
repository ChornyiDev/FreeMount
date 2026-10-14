import Foundation
import Observation

/// Non-secret, persistent user preferences used by the SwiftUI presentation layer.
@Observable
@MainActor
public final class AppPreferences {
    private enum Key {
        static let revealMountedDrives = "revealMountedDrives"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public var revealMountedDrives: Bool {
        didSet { defaults.set(revealMountedDrives, forKey: Key.revealMountedDrives) }
    }

    public init(defaults: UserDefaults = FreeMountDefaults.shared) {
        self.defaults = defaults
        revealMountedDrives = defaults.object(forKey: Key.revealMountedDrives) as? Bool ?? true
    }
}
