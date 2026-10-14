import Foundation
import FileProvider

/// Central error mapping translating backend, transport, and system errors
/// into Finder-understandable `NSFileProviderError` or `CocoaError` Codes.
public enum FreeMountFileProviderErrorMapping {

    public static func map(_ error: Error) -> Error {
        if let fpError = error as? NSFileProviderError {
            return fpError
        }
        if error is CancellationError {
            return CocoaError(.userCancelled)
        }
        if let inventory = error as? FileProviderInventoryError {
            return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: inventory.localizedDescription])
        }
        if let conflict = error as? FileProviderMutationError {
            return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: conflict.localizedDescription])
        }
        if let rpcError = error as? RcloneRPCAuthenticationError {
            return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: rpcError.localizedDescription])
        }
        if let jobError = error as? RcloneJobError {
            return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: jobError.localizedDescription])
        }
        if let cocoaError = error as? CocoaError {
            return cocoaError
        }
        if let freeMountError = error as? FreeMountError {
            switch freeMountError {
            case .keychainError, .invalidConfiguration:
                return NSFileProviderError(.notAuthenticated)
            case .rcloneError(let status, let message):
                let lower = message.lowercased()
                if lower.contains("invalid_grant") ||
                    lower.contains("token expired") ||
                    lower.contains("refresh token") ||
                    lower.contains("not authenticated") {
                    return NSFileProviderError(.notAuthenticated)
                }
                if status == 404 || lower.contains("not found") || lower.contains("directory not found") || lower.contains("object not found") {
                    return NSFileProviderError(.noSuchItem)
                }
                if status == 403 || lower.contains("permission") || lower.contains("forbidden") || lower.contains("access denied") {
                    return CocoaError(.fileWriteNoPermission)
                }
                return NSFileProviderError(.serverUnreachable)
            case .networkTimeout:
                return NSFileProviderError(.serverUnreachable)
            default:
                return NSFileProviderError(.cannotSynchronize)
            }
        }
        if let gcsError = error as? GoogleCloudStorageError {
            switch gcsError {
            case .sourceChanged: return NSFileProviderError(.cannotSynchronize)
            case .unsupportedObjectNames:
                return NSFileProviderError(.cannotSynchronize, userInfo: [NSLocalizedDescriptionKey: gcsError.localizedDescription])
            case .missingPermissions: return CocoaError(.fileWriteNoPermission)
            case .apiFailure(let status, _):
                if status == 401 { return NSFileProviderError(.notAuthenticated) }
                if status == 403 { return CocoaError(.fileWriteNoPermission) }
                if status == 404 { return NSFileProviderError(.noSuchItem) }
                return NSFileProviderError(.serverUnreachable)
            default: return NSFileProviderError(.cannotSynchronize)
            }
        }
        if let pathError = error as? FileProviderPathError {
            switch pathError {
            case .traversalAttempt:
                return NSFileProviderError(.noSuchItem)
            }
        }
        return NSFileProviderError(.serverUnreachable)
    }
}
