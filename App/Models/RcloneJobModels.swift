import Foundation

struct RcloneAsyncRequest<Payload: Encodable & Sendable>: Encodable, Sendable {
    let payload: Payload
    let group: String
    enum CodingKeys: String, CodingKey { case asynchronous = "_async", group = "_group" }
    func encode(to encoder: Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(true, forKey: .asynchronous)
        try container.encode(group, forKey: .group)
    }
}
struct RcloneJobHandle: Decodable, Sendable {
    let jobid: Int
    let executeId: String
}
struct RcloneJobRequest: Encodable, Sendable { let jobid: Int }
struct RcloneJobGroupRequest: Encodable, Sendable { let group: String }
struct RcloneJobStatus: Decodable, Sendable {
    let id: Int
    let executeId: String
    let finished: Bool
    let success: Bool
    let error: String
}

/// The daemon may still be using staging or may have changed the remote object.
/// Callers must retain staging and avoid treating this as a completed operation.
public enum RcloneJobError: LocalizedError, Sendable, Equatable {
    case outcomeUnknown(group: String, reason: String)
    public var errorDescription: String? {
        switch self {
        case .outcomeUnknown(let group, let reason):
            return "The rclone operation outcome is unknown (\(group)): \(reason). Staging was retained. Check the destination before retrying."
        }
    }
}

/// Keeps upload input available until the daemon's terminal state is established.
public enum RcloneTransferStaging {
    public static func withCleanup<T: Sendable>(in directory: URL, operation: () async throws -> T) async throws -> T {
        var retain = false
        defer { if !retain { try? FileManager.default.removeItem(at: directory) } }
        do { return try await operation() }
        catch {
            retain = error is RcloneJobError
            throw error
        }
    }
}

