import AppKit
import Foundation

/// Manages resolution and execution of the source-based update workflow.
public enum UpdateWorkflowManager {
    public static let defaultRepoPathKey = "FreeMountSourceRepositoryPath"
    public static let cloneCommand = "git clone https://github.com/ChornyiDev/FreeMount.git && cd FreeMount && ./scripts/install-from-source.sh"

    /// Discovers if the repository folder exists at the saved path or default home directory.
    public static func resolveRepositoryPath() -> String? {
        if let saved = UserDefaults.standard.string(forKey: defaultRepoPathKey),
           FileManager.default.fileExists(atPath: saved + "/scripts/install-from-source.sh") {
            return saved
        }

        let homeCandidate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("FreeMount", isDirectory: true).path
        if FileManager.default.fileExists(atPath: homeCandidate + "/scripts/install-from-source.sh") {
            return homeCandidate
        }

        return nil
    }

    /// Stores the active repository path in preferences.
    public static func recordRepositoryPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: defaultRepoPathKey)
    }

    /// Executes the update command in macOS Terminal using AppleScript.
    /// This ensures that the user can see build progress and provide credentials if needed.
    public static func executeUpdateInTerminal(at repoPath: String) {
        let escapedPath = repoPath.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "cd \\"\(escapedPath)\\" && git pull && ./scripts/install-from-source.sh"
        end tell
        """
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
    }
}

