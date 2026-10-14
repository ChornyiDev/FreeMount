import Foundation

/// Locates the `rclone` executable on the host system
public struct RcloneBinaryLocator: Sendable {

    /// User-scoped runtime installed by FreeMount during development or update.
    public static var managedRuntimePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FreeMount/bin/rclone")
            .path
    }

    /// Resolves the absolute path to the rclone binary
    /// - Parameters:
    ///   - customPath: An optional explicit path set by the user in Settings
    ///   - fileManager: The file manager instance to verify file existence
    /// - Returns: The verified executable path
    /// - Throws: `FreeMountError.rcloneNotFound` with searched paths list if missing
    public static func resolveBinaryPath(
        customPath: String? = nil,
        fileManager: FileManager = .default
    ) throws -> String {
        var pathsToTry: [String] = []

        // 1. Custom configured user path
        if let customPath = customPath, !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (customPath as NSString).expandingTildeInPath
            if isExecutable(at: expanded, fileManager: fileManager) {
                return expanded
            }
            pathsToTry.append(expanded)
        }

        // 2. Signed helper matching this process architecture.
        #if arch(arm64)
        let bundledArchitecture = "arm64"
        #elseif arch(x86_64)
        let bundledArchitecture = "amd64"
        #else
        let bundledArchitecture = "unsupported"
        #endif
        let bundledRclone = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/Helpers/rclone-\(bundledArchitecture)")
        if isExecutable(at: bundledRclone, fileManager: fileManager) {
            return bundledRclone
        }
        pathsToTry.append(bundledRclone)

        // Development installation uses the same conditional helper artifact.
        if isExecutable(at: managedRuntimePath, fileManager: fileManager) { return managedRuntimePath }
        pathsToTry.append(managedRuntimePath)

        throw FreeMountError.rcloneNotFound(searchedPaths: pathsToTry)
    }

    private static func isExecutable(at path: String, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: path) else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
