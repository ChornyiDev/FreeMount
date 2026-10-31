import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: AppPreferences
    @State private var viewModel: SettingsViewModel

    init(preferences: AppPreferences, supervisor: RcloneProcessSupervisor) {
        self.preferences = preferences
        _viewModel = State(initialValue: SettingsViewModel(supervisor: supervisor))
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            engineTab.tabItem { Label("Engine", systemImage: "cpu") }
            storageTab.tabItem { Label("Storage", systemImage: "externaldrive") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 430)
        .toggleStyle(.switch)
        .tint(Color(nsColor: .controlAccentColor))
        .task {
            while !Task.isCancelled {
                await viewModel.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section("System Integration") {
                Toggle("Launch FreeMount at login", isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.setLaunchAtLogin($0) }
                ))
                Toggle("Reveal newly connected drives in Finder", isOn: $preferences.revealMountedDrives)
            }
            Section("Finder Integration") {
                settingsNote(
                    icon: "sidebar.left",
                    color: .dsAccent,
                    text: "Cloud storage appears in Finder Locations through Apple File Provider."
                )
            }
            errorSection
        }
        .formStyle(.grouped)
    }

    private var engineTab: some View {
        Form {
            Section("rclone Daemon") {
                LabeledContent("Status") {
                    Label(
                        viewModel.daemonStatus.isRunning ? "Running" : "Stopped",
                        systemImage: viewModel.daemonStatus.isRunning ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(viewModel.daemonStatus.isRunning ? Color.dsGreen : Color.dsRed)
                }
                LabeledContent("Process ID", value: viewModel.daemonStatus.pid.map(String.init) ?? "—")
                LabeledContent("Uptime", value: viewModel.uptimeText)
                LabeledContent("Version", value: viewModel.daemonStatus.version ?? "—")
                LabeledContent("RC Address", value: "127.0.0.1:\(viewModel.daemonStatus.port)")
                LabeledContent("Binary") {
                    Text(resolvedRclonePath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button {
                        Task { await viewModel.restartDaemon() }
                    } label: {
                        if viewModel.isRestarting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Restart Daemon", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isRestarting)
                }
            }
            errorSection
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("File Provider Storage") {
                settingsNote(
                    icon: "externaldrive.badge.icloud",
                    color: .dsAccent,
                    text: "macOS manages downloaded files, eviction, and local disk usage for FreeMount drives."
                )
                LabeledContent("Location") {
                    Text("~/Library/CloudStorage")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Open CloudStorage in Finder", systemImage: "folder") {
                        viewModel.revealCloudStorage()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: DSSpacing.lg) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityLabel("FreeMount application icon")
            VStack(spacing: DSSpacing.xs) {
                Text("FreeMount").font(.title2.bold())
                Text("Version \(appVersion) (\(buildNumber))")
                    .foregroundStyle(Color.dsTextMuted)
            }
            Text("Native macOS cloud storage powered by Apple File Provider and rclone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.dsTextSecondary)

            UpdateSectionView(
                status: viewModel.updateStatus,
                currentVersion: appVersion,
                onCheck: {
                    Task { await viewModel.checkForUpdates(currentVersion: appVersion) }
                }
            )

            Text("rclone is distributed under the MIT License. Notices are included with the application.")
                .font(.caption)
                .foregroundStyle(Color.dsTextMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(DSSpacing.xl)
    }

    @ViewBuilder
    private var errorSection: some View {
        if let message = viewModel.errorMessage {
            Section {
                settingsNote(icon: "exclamationmark.triangle.fill", color: .dsRed, text: message)
            }
        }
    }

    private func settingsNote(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.sm) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.caption).foregroundStyle(Color.dsTextSecondary)
        }
    }

    private var resolvedRclonePath: String {
        (try? RcloneBinaryLocator.resolveBinaryPath()) ?? "Not found"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}
