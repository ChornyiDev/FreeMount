import Foundation

/// Active runtime status of a mounted filesystem
public enum MountStatus: Codable, Sendable, Equatable {
    case unmounted
    case mounting
    case mounted(mountedAt: Date, mountPoint: String?)
    case unmounting
    case reconnecting(attempt: Int, message: String)
    case failed(reason: String)

    public var isMounted: Bool {
        if case .mounted = self { return true }
        return false
    }

    public var mountedPath: String? {
        if case .mounted(_, let mountPoint) = self { return mountPoint }
        return nil
    }

    public var isTransitioning: Bool {
        switch self {
        case .mounting, .unmounting, .reconnecting:
            return true
        default:
            return false
        }
    }

    public var displayText: String {
        switch self {
        case .unmounted:
            return "Unmounted"
        case .mounting:
            return "Mounting..."
        case .mounted(_, let path):
            return path.map { "Mounted at \($0)" } ?? "Mounted"
        case .unmounting:
            return "Unmounting..."
        case .reconnecting(let attempt, _):
            return "Reconnecting (attempt \(attempt))..."
        case .failed(let reason):
            return "Error: \(reason)"
        }
    }


}

/// Latest verified health of the cloud service behind a registered domain.
/// This is intentionally separate from `MountStatus`: a File Provider domain
/// can remain mounted for offline access while its remote is unavailable.
public enum ConnectionHealth: Sendable, Equatable {
    case unknown
    case checking
    case healthy(checkedAt: Date)
    case authorizationRequired(reason: String)
    case unavailable(reason: String)
    case issue(ConnectionDiagnostic)

    public var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var statusLabel: String {
        switch self {
        case .unknown: return "Registered"
        case .checking: return "Checking…"
        case .healthy: return "Active"
        case .authorizationRequired: return "Authorization required"
        case .unavailable: return "Offline"
        case .issue(let diagnostic): return diagnostic.kind.statusLabel
        }
    }

    public var reason: String? {
        switch self {
        case .authorizationRequired(let reason), .unavailable(let reason): return reason
        case .issue(let diagnostic): return diagnostic.explanation
        case .unknown, .checking, .healthy: return nil
        }
    }
}
