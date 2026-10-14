import XCTest

/// Only explicitly selected or repository-built artifacts; never installed daemons.
func testRcloneRuntimePath() throws -> String {
    #if arch(arm64)
    let architecture = "arm64"
    #else
    let architecture = "amd64"
    #endif
    let path = ProcessInfo.processInfo.environment["FREEMOUNT_TEST_RCLONE"]
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/rclone-artifacts/v1.75.1/rclone-" + architecture).path
    guard FileManager.default.isExecutableFile(atPath: path) else {
        throw XCTSkip("Build the official helper or set FREEMOUNT_TEST_RCLONE for disposable daemon tests")
    }
    return path
}
