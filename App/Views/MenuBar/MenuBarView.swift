import SwiftUI
import AppKit

/// Popover root rendered within macOS menu bar extra window.
struct MenuBarView: View {
    @Bindable var appState: AppState
    let supervisor: RcloneProcessSupervisor
    @Bindable var preferences: AppPreferences
    let keychain: KeychainService

    private func openConnectionManager(startAdding: Bool = false) {
        AppWindowPresenter.shared.showConnections(
            appState: appState,
            supervisor: supervisor,
            preferences: preferences,
            keychain: keychain,
            initialMode: startAdding ? .adding : .empty
        )
    }

    private func openSettings() {
        // MenuBarExtra owns a transient key window. Dismiss it before promoting
        // Settings, otherwise the popover can remain visually above Settings.
        NSApp.keyWindow?.orderOut(nil)
        AppWindowPresenter.shared.showSettings(
            preferences: preferences,
            supervisor: supervisor
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DSSpacing.lg)
                .padding(.top, DSSpacing.xl)
                .padding(.bottom, DSSpacing.md)

            Divider()
                .overlay(Color.dsBorderSubtle)
                .padding(.bottom, DSSpacing.sm)

            if appState.remotes.isEmpty {
                emptyState
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.sm)
            } else {
                remoteList
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.vertical, DSSpacing.sm)
            }

            if appState.isDaemonRunning {
                ThroughputWidget(stats: appState.currentStats)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.top, DSSpacing.sm)
            }

            if let lastError = appState.lastError {
                errorBanner(lastError)
                    .padding(.horizontal, DSSpacing.lg)
                    .padding(.top, DSSpacing.sm)
            }

            Divider()
                .overlay(Color.dsBorderSubtle)
                .padding(.top, DSSpacing.sm)

            footerActions
                .padding(.horizontal, DSSpacing.lg)
                .padding(.vertical, DSSpacing.md)
        }
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.dsAccent.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.dsAccent.opacity(0.20), lineWidth: 1)
                    }

                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.dsAccent)
                    .frame(width: 25, height: 25)
            }
            .frame(width: 36, height: 36)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("FreeMount")

            Text("FreeMount")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.dsTextPrimary)

            Spacer()


            Button(action: openSettings) {
                headerIconLabel("gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")

            Button {
                NSApp.terminate(nil)
            } label: {
                headerIconLabel("power")
            }
            .buttonStyle(.plain)
            .help("Quit FreeMount")
        }
    }

    private func headerIconLabel(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.dsTextSecondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
    }

    // MARK: - Remote List

    private var remoteList: some View {
        let shouldScroll = totalCount > Self.maxVisibleRemoteRows

        return VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Text("CLOUD STORAGE (\(totalCount))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.dsTextMuted)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Circle()
                        .fill(activeCount > 0 ? Color.dsGreen : Color.dsTextMuted)
                        .frame(width: 6, height: 6)
                    Text(totalCount == 0 ? "No connections" : "\(activeCount) of \(totalCount) active")
                        .font(.system(size: 10))
                        .foregroundStyle(activeCount > 0 ? Color.dsTextSecondary : Color.dsTextMuted)
                }
            }
            .padding(.bottom, 2)

            ScrollView(.vertical, showsIndicators: shouldScroll) {
                LazyVStack(spacing: Self.remoteRowSpacing) {
                    ForEach(appState.remotes) { remote in
                        RemoteRowView(
                            remote: remote,
                            status: appState.status(for: remote.id),
                            health: appState.health(for: remote.id),
                            onToggleMount: {
                                Task {
                                    await appState.toggleMount(
                                        remote,
                                        using: supervisor,
                                        preferences: preferences
                                    )
                                }
                            },
                            onRevealInFinder: {
                                Task { await appState.revealInFinder(remote) }
                            }
                        )
                    }
                }
                .padding(.vertical, Self.listShadowInset)
            }
            .frame(maxHeight: remoteListMaxHeight)
            .fixedSize(horizontal: false, vertical: !shouldScroll)
            .scrollClipDisabled()
        }
    }

    /// Maximum height the list grows to before it becomes scrollable.
    private var remoteListMaxHeight: CGFloat {
        let rows = min(totalCount, Self.maxVisibleRemoteRows)
        let rowHeight = CGFloat(rows) * RemoteRowView.height
        let spacing = CGFloat(max(rows - 1, 0)) * Self.remoteRowSpacing
        return rowHeight + spacing + (Self.listShadowInset * 2)
    }

    private var totalCount: Int { appState.remotes.count }

    private var activeCount: Int {
        appState.activeConnectionCount
    }

    private static let maxVisibleRemoteRows = 5
    /// Vertical gap between connection cards.
    private static let remoteRowSpacing: CGFloat = DSSpacing.sm
    /// Vertical breathing room inside the scroll content so card shadows are never clipped.
    private static let listShadowInset: CGFloat = 5

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "cloud.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(Color.dsAccent.opacity(0.7))
            Text("No cloud drives mounted yet.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.dsTextSecondary)
            Text("Tap Connect Storage to add your first cloud drive.")
                .font(.caption)
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
            Button("Connect First Storage") { openConnectionManager(startAdding: true) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.xl)
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: FreeMountError) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.dsRed)
                .font(.system(size: 12))
            Text(error.localizedDescription)
                .font(.system(size: 11))
                .foregroundStyle(Color.dsTextSecondary)
                .lineLimit(2)
            Spacer()
            Button(action: appState.clearError) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.dsTextMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(DSSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                .fill(Color.dsRed.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                        .strokeBorder(Color.dsRed.opacity(0.25), lineWidth: 1)
                )
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: DSSpacing.sm) {
            Button {
                openConnectionManager(startAdding: true)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                    Text("Connect Storage")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0x3b82f6), Color(hex: 0x0a84ff)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)

            Button {
                openConnectionManager()
            } label: {
                Text("Connections…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                    .padding(.horizontal, DSSpacing.md)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                                    .strokeBorder(Color.dsBorderMedium, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
    }

}
