import Foundation

/// Explicit preference domain used by both raw SPM development executables and
/// the eventual signed application bundle.
public enum FreeMountDefaults {
    public static let suiteName = "com.freemount.app"
    public static let shared = UserDefaults(suiteName: suiteName) ?? .standard
}
