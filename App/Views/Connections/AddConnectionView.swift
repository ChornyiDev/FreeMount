import SwiftUI

/// Single-column "add connection" form embedded in the Connection Manager
/// detail pane. Provider picker on top, form below, actions in the footer.
struct AddConnectionView: View {
    let keychain: KeychainService
    let supervisor: RcloneProcessSupervisor
    let onSave: (RemoteConfig) -> Void
    let onCancel: () -> Void

    @State private var provider: ProviderID = .googleDrive
    @State private var name: String
    @State private var isCustomName = false
    @State private var autoMount = false
    @State private var isReadOnly = false
    @State private var isAuthorizing = false
    @State private var authorizationError: String?
    @State private var pendingAuthorization: GoogleDriveAuthorization?
    @State private var sharedDrives: [GoogleDriveSharedDrive] = []
    @State private var selectedSharedDriveID: String?
    private let existingNames: [String]

    static func uniqueName(base: String, existingNames: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "Connection" : trimmed
        let lowerExisting = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard lowerExisting.contains(normalized.lowercased()) else {
            return normalized
        }
        var counter = 2
        while lowerExisting.contains("\(normalized) \(counter)".lowercased()) {
            counter += 1
        }
        return "\(normalized) \(counter)"
    }

    private var isDuplicateName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        return existingNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(trimmed)
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isDuplicateName else { return false }
        return true
    }

    init(
        keychain: KeychainService,
        supervisor: RcloneProcessSupervisor,
        existingNames: [String] = [],
        onSave: @escaping (RemoteConfig) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.keychain = keychain
        self.supervisor = supervisor
        self.existingNames = existingNames
        _name = State(initialValue: Self.uniqueName(base: "Google Drive", existingNames: existingNames))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    @FocusState private var isNameFocused: Bool

    private func isDefaultGeneratedName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ProviderRegistry.shared.registeredProviders {
            let base = p.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == base { return true }
            if trimmed.hasPrefix(base) {
                let suffix = trimmed.dropFirst(base.count).trimmingCharacters(in: .whitespaces)
                if suffix.isEmpty || Int(suffix) != nil {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if provider == .googleCloudStorage {
                GoogleCloudConnectionForm(keychain: keychain, supervisor: supervisor, existingNames: existingNames, onSave: onSave, onCancel: onCancel, providerPicker: providerPicker, name: $name, isCustomName: $isCustomName)
            } else if provider == .sftp {
                SFTPConnectionForm(keychain: keychain, supervisor: supervisor, existingNames: existingNames, onSave: onSave, onCancel: onCancel, providerPicker: providerPicker, name: $name, isCustomName: $isCustomName)
            } else if provider == .ftp {
                FTPConnectionForm(keychain: keychain, supervisor: supervisor, existingNames: existingNames, onSave: onSave, onCancel: onCancel, providerPicker: providerPicker, name: $name, isCustomName: $isCustomName)
            } else if provider == .smb {
                SMBConnectionForm(keychain: keychain, supervisor: supervisor, existingNames: existingNames, onSave: onSave, onCancel: onCancel, providerPicker: providerPicker, name: $name, isCustomName: $isCustomName)
            } else if provider == .webdav {
                WebDAVConnectionForm(keychain: keychain, supervisor: supervisor, existingNames: existingNames, onSave: onSave, onCancel: onCancel, providerPicker: providerPicker, name: $name, isCustomName: $isCustomName)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DSSpacing.xl) {
                        providerPicker
                        form
                    }
                    .padding(DSSpacing.xl)
                }
                Divider().overlay(Color.dsBorderSubtle)
                footerBar
            }
        }
        .navigationTitle("New Connection")
        .onChange(of: provider) { _, newProvider in
            pendingAuthorization = nil
            authorizationError = nil
            if !isCustomName || isDefaultGeneratedName(name) {
                isCustomName = false
                name = Self.uniqueName(base: newProvider.displayName, existingNames: existingNames)
            }
        }
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            Text("PROVIDER")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.dsTextMuted)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DSSpacing.sm) {
                    ForEach(ProviderRegistry.shared.registeredProviders) { candidate in
                        providerCard(candidate)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 1)
            }
        }
    }

    private func providerCard(_ candidate: CloudProvider) -> some View {
        let isSelected = candidate.id == provider

        return Button {
            // Replace the form immediately; animating this transaction crossfades
            // the outgoing and incoming ScrollViews and their footers.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { provider = candidate.id }
        } label: {
            VStack(spacing: 6) {
                ProviderIcon(providerID: candidate.id, size: 40, cornerRadius: 9)

                Text(candidate.id == .googleCloudStorage ? "Google Cloud\nStorage" : candidate.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dsTextPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 26)
            }
            .frame(width: 96)
            .padding(.vertical, DSSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                    .fill(isSelected ? Color.dsAccent.opacity(0.12) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: DSRadius.md, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.dsAccent.opacity(0.50) : Color.dsBorderSubtle,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(DSAnimation.snap, value: isSelected)
    }

    // MARK: - Form

    private var form: some View {
        VStack(spacing: DSSpacing.lg) {
            formSection(title: "CONNECTION") {
                TextField("Connection Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onChange(of: name) { _, _ in
                        if isNameFocused {
                            isCustomName = true
                        }
                    }

                if isDuplicateName {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsAmber)
                        Text("A connection named \"\(name)\" already exists. Please choose a unique name.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsAmber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 2)
                    .transition(.opacity)
                }

            }

            formSection(title: "1. AUTHORIZATION") {
                ConnectionAuthorizationStateView(isAuthorized: pendingAuthorization != nil, busy: isAuthorizing) {
                    authorizeAndDiscover()
                }

                if let authorizationError {
                    HStack(spacing: DSSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsRed)
                        Text(authorizationError)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DSSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                            .fill(Color.dsRed.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                    .strokeBorder(Color.dsRed.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            formSection(title: "2. CONFIGURATION") {
                if pendingAuthorization != nil {
                        Picker("Drive", selection: $selectedSharedDriveID) {
                            Text("My Drive").tag(String?.none)
                            ForEach(sharedDrives) { drive in
                                Text(drive.name).tag(Optional(drive.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedSharedDriveID) { _, driveID in
                            applySelectedDrive(driveID)
                        }

                        Text(sharedDrives.isEmpty
                            ? "No Shared Drives are available to this account."
                            : "Choose one Google resource for this Finder connection.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dsTextMuted)
                } else {
                    Text("Authorize your Google account to choose a Drive.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }

            formSection(title: "3. OPTIONS") {
                Toggle("Connect automatically at launch", isOn: $autoMount)
                    .font(.system(size: 12))
                Toggle("Read-only access", isOn: $isReadOnly)
                    .font(.system(size: 12))
            }
        }
    }

    // MARK: - Section Builder

    private func formSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ConnectionFormSection(title: title, content: content)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        ConnectionFormFooter(title: actionTitle, busy: isAuthorizing, enabled: isValid && !isAuthorizing && pendingAuthorization != nil, onCancel: onCancel) {
            saveAuthorizedConnection()
        }
    }

    // MARK: - Actions

    private var actionTitle: String {
        if isAuthorizing { return "Authorizing…" }
        return "Save & Connect"
    }

    private func authorizeAndDiscover() {
        authorizationError = nil
        isAuthorizing = true

        Task { @MainActor in
            do {
                let client = try GoogleDriveOAuthConfiguration.loadClient()
                let authorization = try await GoogleDriveOAuthService().authorize(client: client)
                let rcClient = try await supervisor.startDaemon()
                let credential = authorization.credential(remoteName: "Google Drive")
                let drives = try await rcClient.listGoogleDriveSharedDrives(
                    fs: credential.fileSystemReference(root: "")
                )
                pendingAuthorization = authorization
                sharedDrives = drives
                selectedSharedDriveID = nil
                isAuthorizing = false
            } catch {
                withAnimation(DSAnimation.gentle) {
                    authorizationError = error.localizedDescription
                    isAuthorizing = false
                }
            }
        }
    }

    private func applySelectedDrive(_ driveID: String?) {
        guard let driveID,
              let drive = sharedDrives.first(where: { $0.id == driveID }) else {
            name = Self.uniqueName(base: "Google Drive", existingNames: existingNames)
            isReadOnly = false
            return
        }
        name = Self.uniqueName(base: drive.name, existingNames: existingNames)
        isReadOnly = true
    }

    private func saveAuthorizedConnection() {
        guard let authorization = pendingAuthorization else { return }
        authorizationError = nil
        isAuthorizing = true
        let remoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = "/"

        Task { @MainActor in
            do {
                let account = "credential.\(UUID().uuidString.lowercased())"
                let credential = authorization.credential(remoteName: remoteName)
                let client = try await supervisor.startDaemon()
                _ = try await client.list(fs: credential.fileSystemReference(root: root, additionalOptions: GoogleDriveFileProviderBackend.connectionOptions(sharedDriveID: selectedSharedDriveID)), path: "")
                try await keychain.saveCredential(credential, account: account)
                let config = RemoteConfig(
                    name: remoteName,
                    provider: .googleDrive,
                    bucketOrRootPath: root,
                    keychainAccountKey: account,
                    googleDriveSharedDriveID: selectedSharedDriveID,
                    autoMountAtLaunch: autoMount,
                    isReadOnly: isReadOnly
                )
                isAuthorizing = false
                onSave(config)
            } catch {
                withAnimation(DSAnimation.gentle) {
                    authorizationError = error.localizedDescription
                    isAuthorizing = false
                }
            }
        }
    }

}
