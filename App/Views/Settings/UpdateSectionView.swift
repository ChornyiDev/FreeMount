import SwiftUI
import AppKit

struct UpdateSectionView: View {
    let status: UpdateCheckStatus
    let currentVersion: String
    let onCheck: () -> Void

    @State private var showingRecloneSheet = false
    @State private var copiedCommand = false

    var body: some View {
        VStack(spacing: DSSpacing.sm) {
            renderContent()
        }
        .sheet(isPresented: $showingRecloneSheet) {
            recloneSheetView
        }
    }

    @ViewBuilder
    private func renderContent() -> some View {
        switch status {
        case .idle:
            Button(action: onCheck) {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .checking:
            HStack(spacing: DSSpacing.xs) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextMuted)
            }

        case .upToDate:
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.dsGreen)
                Text("FreeMount is up to date")
                    .font(.caption)
                    .foregroundStyle(Color.dsTextSecondary)
                Button("Check again", action: onCheck)
                    .buttonStyle(.link)
                    .font(.caption)
            }

        case .updateAvailable(let latest, _, let release):
            updateAvailableView(latest: latest, release: release)

        case .failed(let message):
            failedView(message: message)
        }
    }

    private func updateAvailableView(latest: String, release: GitHubReleaseInfo) -> some View {
        VStack(spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(Color.dsAccent)
                Text("New version available: \(latest)")
                    .font(.callout.bold())
            }

            if let body = release.body, !body.isEmpty {
                let preview = String(body.prefix(140)) + (body.count > 140 ? "…" : "")
                Text(preview)
                    .font(.caption2)
                    .foregroundStyle(Color.dsTextMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, DSSpacing.md)
            }

            HStack(spacing: DSSpacing.sm) {
                Button(action: handleUpdateTrigger) {
                    Label("Update Now", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if let url = release.htmlUrl {
                    Link("View Release", destination: url)
                        .font(.caption)
                }
            }
        }
        .padding(DSSpacing.sm)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.dsRed)
                Text("Could not check for updates")
                    .font(.caption)
                    .foregroundStyle(Color.dsRed)
            }
            Text(message)
                .font(.caption2)
                .foregroundStyle(Color.dsTextMuted)
            Button("Retry", action: onCheck)
                .buttonStyle(.link)
                .font(.caption)
        }
    }

    private func handleUpdateTrigger() {
        if let repoPath = UpdateWorkflowManager.resolveRepositoryPath() {
            UpdateWorkflowManager.executeUpdateInTerminal(at: repoPath)
        } else {
            showingRecloneSheet = true
        }
    }

    private var recloneSheetView: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(Color.dsAccent)

            Text("Local Source Directory Not Found")
                .font(.headline)

            Text("The original FreeMount source folder has been moved or removed. To update, re-clone the repository and run the install script:")
                .font(.caption)
                .foregroundStyle(Color.dsTextSecondary)
                .multilineTextAlignment(.center)

            HStack {
                Text(UpdateWorkflowManager.cloneCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(DSSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.1))
                    .cornerRadius(6)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(UpdateWorkflowManager.cloneCommand, forType: .string)
                    copiedCommand = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedCommand = false
                    }
                } label: {
                    Label(copiedCommand ? "Copied" : "Copy", systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }

            HStack {
                Spacer()
                Button("Done") {
                    showingRecloneSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.xl)
        .frame(width: 480)
    }
}
