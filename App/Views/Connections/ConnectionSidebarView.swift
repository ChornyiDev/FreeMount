import SwiftUI

/// Left panel of the Connection Manager: a `List` of all remotes
/// with status indicators and toolbar actions (add / remove).
struct ConnectionSidebarView: View {
    @Bindable var appState: AppState
    let keychain: KeychainService
    @Binding var selectedRemoteID: RemoteConfig.ID?
    let onAddConnection: () -> Void

    @State private var remoteToDelete: RemoteConfig?

    var body: some View {
        List(selection: $selectedRemoteID) {
            if appState.remotes.isEmpty {
                emptyState
            } else {
                ForEach(appState.remotes) { remote in
                    sidebarRow(remote)
                        .tag(remote.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Connections")
        .navigationSubtitle("\(appState.remotes.count) configured")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    onAddConnection()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add connection")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let id = selectedRemoteID,
                          let remote = appState.remotes.first(where: { $0.id == id }) else { return }
                    remoteToDelete = remote
                } label: {
                    Image(systemName: "minus")
                }
                .help("Remove selected connection")
                .disabled(selectedRemoteID == nil)
            }
        }
        .confirmationDialog(
            "Delete \"\(remoteToDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { remoteToDelete != nil },
                set: { if !$0 { remoteToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let remote = remoteToDelete else { return }
                Task {
                    await appState.removeRemoteAndCredentials(id: remote.id, keychain: keychain)
                    if selectedRemoteID == remote.id, !appState.remotes.contains(where: { $0.id == remote.id }) {
                        selectedRemoteID = nil
                    }
                    remoteToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { remoteToDelete = nil }
        } message: {
            Text("This will disconnect and permanently remove the connection. Your files in the cloud are not affected.")
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func sidebarRow(_ remote: RemoteConfig) -> some View {
        let status = appState.status(for: remote.id)
        let health = appState.health(for: remote.id)

        HStack(spacing: DSSpacing.sm) {
            // Provider icon badge
            ProviderIcon(providerID: remote.provider, size: 32, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(remote.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.dsTextPrimary)
                    .lineLimit(1)
                Text(remote.provider.displayName)
                    .font(.caption2)
                    .foregroundStyle(Color.dsTextMuted)
            }

            Spacer(minLength: 4)

            // Status dot
            DSPulseDot(
                color: ConnectionStatusPresentation(status: status, health: health, provider: remote.provider).color,
                animate: status.isTransitioning || health == .checking
            )
            .frame(width: 14, height: 14)
            .help(health.reason ?? health.statusLabel)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "cloud.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Color.dsAccent.opacity(0.7))
            Text("No Connections")
                .font(.headline)
                .foregroundStyle(Color.dsTextSecondary)
            Text("Click + to add your first cloud storage connection.")
                .font(.caption)
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DSSpacing.xl)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

}
