import SwiftUI

struct RemoteRowView: View {
    /// Fixed row height — lets the menu bar list size itself without scrolling
    /// until the visible-row cap is reached.
    static let height: CGFloat = 60

    let remote: RemoteConfig
    let status: MountStatus
    let health: ConnectionHealth
    let onToggleMount: () -> Void
    let onRevealInFinder: () -> Void

    // MARK: - Computed

    private var presentation: ConnectionStatusPresentation {
        ConnectionStatusPresentation(status: status, health: health, provider: remote.provider)
    }
    private var statusColor: Color { presentation.color }
    private var statusLabel: String { presentation.label }

    // MARK: - Body

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            // Provider icon badge
            ProviderIcon(providerID: remote.provider, size: 36, cornerRadius: 9)

            // Name + status
            VStack(alignment: .leading, spacing: 3) {
                Text(remote.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                    .lineLimit(1)
                DSStatusChip(label: statusLabel, color: statusColor)
                    .help(health.reason ?? status.displayText)
            }

            Spacer(minLength: 4)

            // Action buttons
            HStack(spacing: 2) {
                iconButton("folder", help: "Reveal in Finder", action: onRevealInFinder)

                iconButton(
                    status.isMounted ? "eject.fill" : "play.fill",
                    help: status.isMounted ? "Disconnect" : "Connect",
                    action: onToggleMount,
                    disabled: status.isTransitioning || ProviderRegistry.shared.provider(for: remote.provider) == nil
                )
            }
        }
        .padding(.horizontal, DSSpacing.sm + 2)
        .padding(.vertical, DSSpacing.sm - 2)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.primary.opacity(0.04),
                                    Color.primary.opacity(0.01)
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                        .strokeBorder(
                            Color.dsBorderMedium,
                            lineWidth: 1
                        )
                )
        )
        .shadow(
            color: Color.black.opacity(0.16),
            radius: 5, x: 0, y: 2
        )
        .contextMenu {
            Button(action: onRevealInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Button(action: onToggleMount) {
                Label(
                    status.isMounted ? "Disconnect" : "Connect",
                    systemImage: status.isMounted ? "eject" : "play"
                )
            }
            .disabled(status.isTransitioning || ProviderRegistry.shared.provider(for: remote.provider) == nil)
        }
    }

    // MARK: - Helper

    private func iconButton(
        _ icon: String,
        help: String,
        action: @escaping () -> Void,
        tint: Color = Color.dsTextSecondary,
        disabled: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? Color.dsTextMuted : tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(disabled ? 0 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .disabled(disabled)
    }
}

/// Shared display of registration and independently checked provider health.
struct ConnectionStatusPresentation {
    let status: MountStatus
    let health: ConnectionHealth
    let provider: ProviderID

    var label: String {
        if status.isMounted { return health.statusLabel }
        switch status {
        case .mounted: return "Active"
        case .mounting: return "Connecting…"
        case .unmounting: return "Disconnecting…"
        case .reconnecting(let attempt, _): return "Retry \(attempt)"
        case .failed: return "Error"
        case .unmounted: return ProviderRegistry.shared.provider(for: provider) == nil ? "Unavailable" : "Offline"
        }
    }

    var color: Color {
        switch status {
        case .mounted:
            switch health {
            case .healthy: return .dsGreen
            case .checking, .unknown: return .dsAmber
            case .authorizationRequired: return .dsRed
            case .unavailable: return .dsTextMuted
            case .issue(let diagnostic): return diagnostic.kind.isTemporary ? .dsAmber : .dsRed
            }
        case .mounting, .unmounting, .reconnecting: return .dsAmber
        case .failed: return .dsRed
        case .unmounted: return .dsTextMuted
        }
    }
}
