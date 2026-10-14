import Foundation

/// A recovery-oriented issue; RC and upstream HTTP statuses are separate facts.
public struct ConnectionDiagnostic: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case authorization, permissions, resourceMissing, quota, billing, apiDisabled
        case network, serviceUnavailable, localRuntime, credentialStorage, configuration, unknown
        public var statusLabel: String {
            switch self {
            case .authorization: return "Authorization required"
            case .permissions: return "Access denied"
            case .resourceMissing: return "Bucket unavailable"
            case .quota: return "Rate limited"
            case .billing: return "Billing issue"
            case .apiDisabled: return "API disabled"
            case .network: return "Connection unavailable"
            case .serviceUnavailable: return "Service unavailable"
            case .localRuntime: return "Local connection issue"
            case .credentialStorage: return "Keychain unavailable"
            case .configuration: return "Configuration issue"
            case .unknown: return "Connection issue"
            }
        }
        public var isTemporary: Bool { [.quota, .network, .serviceUnavailable].contains(self) }
    }
    public let kind: Kind
    public let summary: String
    public let recovery: String
    public let technicalReason: String
    public let rcStatus: Int?
    public let upstreamStatus: Int?
    public let upstreamReason: String?

    public var explanation: String { summary + " " + recovery }
    init(kind: Kind, summary: String, recovery: String, technicalReason: String, rcStatus: Int? = nil, upstreamStatus: Int? = nil, upstreamReason: String? = nil) {
        self.kind = kind; self.summary = CredentialRedactor.redact(summary); self.recovery = CredentialRedactor.redact(recovery)
        self.technicalReason = String(CredentialRedactor.redact(technicalReason).prefix(2048))
        self.rcStatus = rcStatus; self.upstreamStatus = upstreamStatus; self.upstreamReason = upstreamReason.map { String(CredentialRedactor.redact($0).prefix(128)) }
    }
}
