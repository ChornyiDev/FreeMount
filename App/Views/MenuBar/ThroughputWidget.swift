import SwiftUI

/// Compact live File Provider transfer summary.
struct ThroughputWidget: View {
    let stats: TransferStats

    private var isActive: Bool { stats.hasActiveTransfers }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            speedPill(
                icon: "arrow.down",
                value: formattedSpeed(stats.downloadSpeed),
                color: .dsCyan,
                active: stats.downloadSpeed > 0
            )

            speedPill(
                icon: "arrow.up",
                value: formattedSpeed(stats.uploadSpeed),
                color: .dsAccent,
                active: stats.uploadSpeed > 0
            )

            Spacer(minLength: 0)

            Text(stats.fileProgress ?? "Idle")
                .font(.system(size: 10, weight: isActive ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isActive ? Color.dsTextSecondary : Color.dsTextMuted)
                .monospacedDigit()
        }
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .fill(Color.dsCyan.opacity(isActive ? 0.06 : 0))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isActive ? Color.dsCyan.opacity(0.20) : Color.dsBorderSubtle,
                            lineWidth: 1
                        )
                )
        )
        .animation(DSAnimation.dissolve, value: isActive)
    }

    private func formattedSpeed(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .binary) + "/s"
    }

    private func speedPill(
        icon: String,
        value: String,
        color: Color,
        active: Bool
    ) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(active ? color : Color.dsTextMuted)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(active ? color : Color.dsTextMuted)
                .monospacedDigit()
        }
    }
}
