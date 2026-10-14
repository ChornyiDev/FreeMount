import Foundation

/// Represents the verification lifecycle of a network connection before saving.
public enum ConnectionVerificationState: Equatable, Sendable {
    case untested
    case testing
    case verified(message: String)
    case failed(message: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    public var verifiedMessage: String? {
        if case .verified(let message) = self { return message }
        return nil
    }
}
