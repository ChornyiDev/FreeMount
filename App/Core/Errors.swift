import Foundation

/// Unified error taxonomy for FreeMount
public enum FreeMountError: LocalizedError, Sendable, Equatable {
    case rcloneNotFound(searchedPaths: [String])
    case daemonNotRunning
    case rcloneError(statusCode: Int, message: String)
    case mountFailed(remoteName: String, path: String, reason: String)
    case unmountFailed(path: String, reason: String)
    case keychainError(status: Int32, message: String)
    case invalidConfiguration(reason: String)
    case networkTimeout(operation: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .rcloneNotFound(let paths):
            return "A compatible rclone executable was not found in: \(paths.joined(separator: ", ")). Install the FreeMount-managed runtime or bundle the official rclone build."
        case .daemonNotRunning:
            return "The rclone background daemon is not running."
        case .rcloneError(let code, let message):
            return "rclone RC error (\(code)): \(message)"
        case .mountFailed(let remote, let path, let reason):
            return "Failed to mount '\(remote)' to '\(path)': \(reason)"
        case .unmountFailed(let path, let reason):
            return "Failed to unmount '\(path)': \(reason)"
        case .keychainError(let status, let message):
            return "macOS Keychain error (\(status)): \(message)"
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason)"
        case .networkTimeout(let op):
            return "Network operation '\(op)' timed out."
        case .unexpectedResponse(let details):
            return "Unexpected response from daemon: \(details)"
        }
    }
}

/// Failures originating from the macOS Keychain.
public enum KeychainError: LocalizedError, Sendable, Equatable {
    case itemNotFound(account: String)
    case operationFailed(operation: String, status: Int32, message: String)
    case invalidPayload(account: String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound(let account):
            return "No credential was found for account '\(account)'."
        case .operationFailed(let operation, let status, let message):
            return "Keychain \(operation) failed (\(status)): \(message)"
        case .invalidPayload(let account):
            return "The stored credential for account '\(account)' is invalid."
        }
    }
}
