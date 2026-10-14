import SwiftUI

/// Root view for the Connection Manager window.
/// Uses `NavigationSplitView`: sidebar lists all remotes,
/// detail shows either the selected connection, the add-connection form,
/// or an empty placeholder.
struct ConnectionManagerWindow: View {
    enum DetailMode: Equatable {
        case empty
        case existing(RemoteConfig.ID)
        case adding
    }

    @Bindable var appState: AppState
    let supervisor: RcloneProcessSupervisor
    let preferences: AppPreferences
    let keychain: KeychainService

    @State private var credentialCleanupError: String?
    @State private var mode: DetailMode

    init(
        appState: AppState,
        supervisor: RcloneProcessSupervisor,
        preferences: AppPreferences,
        keychain: KeychainService,
        initialMode: DetailMode = .empty
    ) {
        self.appState = appState
        self.supervisor = supervisor
        self.preferences = preferences
        self.keychain = keychain
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        NavigationSplitView {
            ConnectionSidebarView(
                appState: appState,
                keychain: keychain,
                selectedRemoteID: selectionBinding,
                onAddConnection: { mode = .adding }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 250, max: 250)
        } detail: {
            detail
                .navigationSplitViewColumnWidth(min: 500, ideal: 500)
        }
        .onChange(of: appState.lastError) { _, error in
            if case .keychainError = error { credentialCleanupError = error?.localizedDescription }
        }
        .alert("Credential cleanup failed", isPresented: Binding(get: { credentialCleanupError != nil }, set: { if !$0 { credentialCleanupError = nil } })) {
            Button("OK") { credentialCleanupError = nil }
        } message: {
            Text(credentialCleanupError ?? "")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, idealWidth: 780, minHeight: 460, idealHeight: 560)
    }

    /// Bridges sidebar `List` selection to `DetailMode`.
    private var selectionBinding: Binding<RemoteConfig.ID?> {
        Binding(
            get: {
                if case .existing(let id) = mode { return id }
                return nil
            },
            set: { newValue in
                if let newValue {
                    mode = .existing(newValue)
                } else if mode != .adding {
                    mode = .empty
                }
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch mode {
        case .adding:
            AddConnectionView(
                keychain: keychain,
                supervisor: supervisor,
                existingNames: appState.remotes.map(\.name),
                onSave: { remote in
                    Task {
                        let saved = await appState.addRemote(remote, keychain: keychain)
                        mode = .existing(saved.id)
                        await appState.mount(saved, using: supervisor, preferences: preferences)
                    }
                },
                onCancel: { mode = .empty }
            )

        case .existing(let id):
            if let remote = appState.remotes.first(where: { $0.id == id }) {
                ConnectionDetailView(
                    remote: remote,
                    appState: appState,
                    supervisor: supervisor,
                    preferences: preferences,
                    keychain: keychain
                )
                .id(id) // force re-render when selection changes
            } else {
                emptyDetail
            }

        case .empty:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: DSSpacing.md) {
            Image(systemName: "externaldrive.badge.icloud")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color.dsAccent.opacity(0.6))
            Text("Select a connection")
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.dsTextSecondary)
            Text("Choose a cloud storage connection from the sidebar\nto view its status and settings.")
                .font(.callout)
                .foregroundStyle(Color.dsTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
