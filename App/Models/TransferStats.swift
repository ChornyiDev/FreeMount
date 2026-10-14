import Foundation

/// Active single file transfer item reported by rclone
public struct ActiveTransfer: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let bytes: Int64
    public let percentage: Int?
    public let speed: Double?
    public let eta: Double?
    public let sourceFileSystem: String?
    public let destinationFileSystem: String?

    enum CodingKeys: String, CodingKey {
        case name, size, bytes, percentage, speed, eta
        case sourceFileSystem = "srcFs"
        case destinationFileSystem = "dstFs"
    }

    public init(
        name: String,
        size: Int64,
        bytes: Int64 = 0,
        percentage: Int? = nil,
        speed: Double? = nil,
        eta: Double? = nil,
        sourceFileSystem: String? = nil,
        destinationFileSystem: String? = nil
    ) {
        self.name = name
        self.size = size
        self.bytes = bytes
        self.percentage = percentage
        self.speed = speed
        self.eta = eta
        self.sourceFileSystem = sourceFileSystem
        self.destinationFileSystem = destinationFileSystem
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        percentage = try container.decodeIfPresent(Int.self, forKey: .percentage)
        speed = try container.decodeIfPresent(Double.self, forKey: .speed)
        eta = try container.decodeIfPresent(Double.self, forKey: .eta)
        sourceFileSystem = try container.decodeIfPresent(String.self, forKey: .sourceFileSystem)
        destinationFileSystem = try container.decodeIfPresent(String.self, forKey: .destinationFileSystem)
    }

    public var direction: TransferDirection? {
        guard let sourceFileSystem, let destinationFileSystem else { return nil }
        let sourceIsLocal = Self.isLocalFileSystem(sourceFileSystem)
        let destinationIsLocal = Self.isLocalFileSystem(destinationFileSystem)
        if !sourceIsLocal && destinationIsLocal { return .download }
        if sourceIsLocal && !destinationIsLocal { return .upload }
        return nil
    }

    private static func isLocalFileSystem(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("file://")
    }
}

public enum TransferDirection: Sendable, Equatable, Hashable {
    case download
    case upload
}

/// Aggregate performance and throughput statistics from rclone core/stats
public struct TransferStats: Codable, Sendable, Equatable {
    public let bytes: Int64
    public let checks: Int64
    public let deletes: Int64
    public let elapsedTime: Double
    public let errors: Int64
    public let fatalError: Bool
    public let retryError: Bool
    public let speed: Double
    public let totalBytes: Int64
    public let totalChecks: Int64
    public let totalTransfers: Int64
    public let transfers: Int64
    public let transferring: [ActiveTransfer]?
    public let batchTransfers: Int64?
    public let batchTotalTransfers: Int64?

    public init(
        bytes: Int64 = 0,
        checks: Int64 = 0,
        deletes: Int64 = 0,
        elapsedTime: Double = 0,
        errors: Int64 = 0,
        fatalError: Bool = false,
        retryError: Bool = false,
        speed: Double = 0,
        totalBytes: Int64 = 0,
        totalChecks: Int64 = 0,
        totalTransfers: Int64 = 0,
        transfers: Int64 = 0,
        transferring: [ActiveTransfer]? = nil,
        batchTransfers: Int64? = nil,
        batchTotalTransfers: Int64? = nil
    ) {
        self.bytes = bytes
        self.checks = checks
        self.deletes = deletes
        self.elapsedTime = elapsedTime
        self.errors = errors
        self.fatalError = fatalError
        self.retryError = retryError
        self.speed = speed
        self.totalBytes = totalBytes
        self.totalChecks = totalChecks
        self.totalTransfers = totalTransfers
        self.transfers = transfers
        self.transferring = transferring
        self.batchTransfers = batchTransfers
        self.batchTotalTransfers = batchTotalTransfers
    }

    /// Formatted human readable transfer speed (e.g. 12.4 MB/s)
    public var formattedSpeed: String {
        ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .binary) + "/s"
    }

    /// Formatted transferred bytes count (e.g. 1.25 GB)
    public var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }

    public var hasActiveTransfers: Bool {
        !(transferring ?? []).isEmpty
    }

    public var downloadSpeed: Double {
        directionalSpeed(for: .download)
    }

    public var uploadSpeed: Double {
        directionalSpeed(for: .upload)
    }

    public var fileProgress: String? {
        let completed = batchTransfers ?? transfers
        let total = batchTotalTransfers ?? totalTransfers
        guard hasActiveTransfers, total > 0 else { return nil }
        return "\(min(completed, total))/\(total)"
    }

    private func directionalSpeed(for direction: TransferDirection) -> Double {
        let active = transferring ?? []
        let matching = active.filter { $0.direction == direction }
        guard !matching.isEmpty else { return 0 }

        let reported = matching.compactMap(\.speed)
        if !reported.isEmpty {
            return reported.reduce(0, +)
        }

        let knownDirections = Set(active.compactMap(\.direction))
        return knownDirections.count == 1 ? speed : 0
    }

    /// Zero state statistics
    public static let zero = TransferStats()

    func withBatchProgress(completed: Int64, total: Int64) -> TransferStats {
        TransferStats(
            bytes: bytes,
            checks: checks,
            deletes: deletes,
            elapsedTime: elapsedTime,
            errors: errors,
            fatalError: fatalError,
            retryError: retryError,
            speed: speed,
            totalBytes: totalBytes,
            totalChecks: totalChecks,
            totalTransfers: totalTransfers,
            transfers: transfers,
            transferring: transferring,
            batchTransfers: completed,
            batchTotalTransfers: total
        )
    }
}

struct TransferBatchProgressTracker: Sendable {
    private var completedBaseline: Int64?

    mutating func apply(to stats: TransferStats) -> TransferStats {
        guard stats.hasActiveTransfers else {
            completedBaseline = nil
            return stats
        }
        if completedBaseline == nil {
            completedBaseline = stats.transfers
        }
        let baseline = completedBaseline ?? stats.transfers
        let completed = max(0, stats.transfers - baseline)
        let total = max(completed, stats.totalTransfers - baseline)
        return stats.withBatchProgress(completed: completed, total: total)
    }
}

/// A single daemon health and transfer-statistics observation for the UI.
public struct RcloneTelemetrySnapshot: Sendable, Equatable {
    public let isDaemonRunning: Bool
    public let stats: TransferStats
    public let hasTransferStats: Bool
    public let completedTransfers: [CompletedTransfer]?

    public init(isDaemonRunning: Bool, stats: TransferStats = .zero, hasTransferStats: Bool = true, completedTransfers: [CompletedTransfer]? = nil) {
        self.isDaemonRunning = isDaemonRunning
        self.stats = stats
        self.hasTransferStats = hasTransferStats
        self.completedTransfers = completedTransfers
    }
}

public struct RcloneDaemonStatus: Sendable, Equatable {
    public let isRunning: Bool
    public let pid: Int?
    public let startedAt: Date?
    public let version: String?
    public let port: Int

    public init(isRunning: Bool, pid: Int? = nil, startedAt: Date? = nil, version: String? = nil, port: Int = 5572) {
        self.isRunning = isRunning
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.port = port
    }
}

/// Standard rclone's bounded completed-transfer window; never persisted by the host.
public struct CompletedTransfer: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let size: Int64
    public let bytes: Int64
    public let checked: Bool
    public let what: String
    public let startedAt: String
    public let completedAt: String
    public let group: String
    public let error: String
    public let sourceFileSystem: String?
    public let destinationFileSystem: String?

    enum CodingKeys: String, CodingKey {
        case name, size, bytes, checked, what, group, error
        case startedAt = "started_at", completedAt = "completed_at"
        case sourceFileSystem = "srcFs", destinationFileSystem = "dstFs"
    }
    public var id: String { "\(group)|\(name)|\(startedAt)|\(completedAt)" }
    public var completionDate: Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: completedAt) ?? ISO8601DateFormatter().date(from: completedAt)
    }
    public var direction: TransferDirection? {
        ActiveTransfer(name: name, size: size, sourceFileSystem: sourceFileSystem,
            destinationFileSystem: destinationFileSystem).direction
    }
}

struct CompletedTransfersResponse: Decodable, Sendable {
    let transferred: [CompletedTransfer]
}
