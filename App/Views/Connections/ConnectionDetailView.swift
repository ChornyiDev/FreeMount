import SwiftUI
import UniformTypeIdentifiers

/// Right panel of the Connection Manager: single scrollable page with
/// connection status, quick actions and editable settings. Save/Delete live
/// in a footer bar, mirroring the add-connection layout.
struct ConnectionDetailView: View {
    let remote: RemoteConfig
    @Bindable var appState: AppState
    let supervisor: RcloneProcessSupervisor
    let preferences: AppPreferences
    let keychain: KeychainService

    @State private var editedName: String = ""
    @State private var editedAutoMount: Bool = false
    @State private var editedReadOnly: Bool = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isReauthorizing = false
    @State private var reauthorizeError: String?
    @State private var showKeyImporter = false
    @State private var showDeleteConfirmation = false

    private var status: MountStatus { appState.status(for: remote.id) }
    private var health: ConnectionHealth { appState.health(for: remote.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: DSSpacing.xl) {
                    heroCard
                    settingsSection
                    if let saveError {
                        Text(saveError).font(.caption).foregroundStyle(Color.dsRed)
                    }
                }
                .padding(DSSpacing.xl)
            }

            Divider().overlay(Color.dsBorderSubtle)

            footerBar
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do { reauthorize(serviceAccountKey: try GoogleCloudServiceAccountKey.importFile(url)) }
                catch { reauthorizeError = error.localizedDescription }
            case .failure: reauthorizeError = GoogleCloudServiceAccountError.unreadableFile.localizedDescription
            }
        }
        .onAppear { loadEditable() }
        .onChange(of: remote.id) { loadEditable() }
        .confirmationDialog(
            "Delete \"\(remote.name)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await appState.removeRemoteAndCredentials(id: remote.id, keychain: keychain)
                    if appState.remotes.contains(where: { $0.id == remote.id }) {
                        saveError = appState.lastError?.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disconnect and permanently remove the connection. Your files in the cloud are not affected.")
        }
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: DSSpacing.lg) {
            HStack(spacing: DSSpacing.lg) {
                ProviderIcon(providerID: remote.provider, size: 64, cornerRadius: DSRadius.md)

                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text(remote.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Color.dsTextPrimary)
                    Text(remote.provider.displayName)
                        .font(.subheadline)
                        .foregroundStyle(Color.dsTextSecondary)

                    DSStatusChip(label: statusLabel, color: statusColor)
                        .padding(.top, 2)

                    if case .failed(let reason) = status {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(Color.dsRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if status.isMounted, case .issue(let diagnostic) = health {
                        VStack(alignment: .leading, spacing: DSSpacing.xs) {
                            Text(diagnostic.summary).foregroundStyle(statusColor)
                            Text(diagnostic.recovery).foregroundStyle(Color.dsTextSecondary)
                            DisclosureGroup("Technical details") {
                                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                                    if let code = diagnostic.rcStatus { Text("Local RC HTTP: \(code)") }
                                    if let code = diagnostic.upstreamStatus { Text("Google HTTP: \(code)") }
                                    if let reason = diagnostic.upstreamReason { Text("Google reason: \(reason)") }
                                    Text(diagnostic.technicalReason)
                                }
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button("Check again") {
                                Task { await appState.validateAndRefreshConnection(remote) }
                            }
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    } else if status.isMounted, let reason = health.reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()
            }

            HStack(spacing: DSSpacing.sm) {
                actionButton(
                    title: status.isMounted ? "Disconnect" : "Connect",
                    icon: status.isMounted ? "eject.fill" : "play.fill",
                    color: status.isMounted ? Color.dsAmber : Color.dsGreen,
                    disabled: status.isTransitioning || ProviderRegistry.shared.provider(for: remote.provider) == nil
                ) {
                    Task {
                        await appState.toggleMount(remote, using: supervisor, preferences: preferences)
                    }
                }

                actionButton(
                    title: "Show in Finder",
                    icon: "folder.fill",
                    color: Color.dsAccent,
                    disabled: !status.isMounted
                ) {
                    Task { await appState.revealInFinder(remote) }
                }
            }
        }
        .padding(DSSpacing.lg)
        .dsGlassCard(cornerRadius: DSRadius.lg)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(spacing: DSSpacing.lg) {
            formSection(title: "CONNECTION") {
                TextField("Connection Name", text: $editedName)
                    .textFieldStyle(.roundedBorder)

                if isRenamed {
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                        Text("Name changes in Finder will take effect the next time this drive is mounted.")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.dsAmber)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Toggle("Connect automatically at launch", isOn: $editedAutoMount)
                    .font(.system(size: 12))
                Toggle("Read-only access", isOn: $editedReadOnly)
                    .font(.system(size: 12))
            }

            if remote.provider == .googleDrive || remote.provider == .googleCloudStorage {
                formSection(title: remote.provider == .googleDrive ? "GOOGLE DRIVE" : "GOOGLE CLOUD STORAGE") {
                    LabeledContent("Resource") {
                        Text(remote.provider == .googleCloudStorage ? remote.bucketOrRootPath : (remote.googleDriveSharedDriveID == nil ? "My Drive" : "Shared Drive"))
                            .font(.caption)
                            .foregroundStyle(Color.dsTextSecondary)
                    }

                    LabeledContent("Account") {
                        Text(remote.googleCloudAuthentication?.email ?? remote.keychainAccountKey ?? "—")
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.dsTextMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let reauthorizeError {
                        Text(reauthorizeError)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.dsRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack {
                        Spacer()
                        Button {
                            if remote.googleCloudAuthentication?.mode == .serviceAccount { showKeyImporter = true }
                            else { reauthorize() }
                        } label: {
                            if isReauthorizing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(remote.googleCloudAuthentication?.mode == .serviceAccount ? "Replace key…" : "Re-authorize…")
                            }
                        }
                        .disabled(isReauthorizing)
                    }
                }
            } else if remote.provider == .sftp {
                formSection(title: "SFTP SERVER") {
                    if let sftp = remote.sftpConfiguration {
                        LabeledContent("Server") {
                            Text("\(sftp.host):\(sftp.port)")
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.dsTextSecondary)
                        }

                        LabeledContent("User") {
                            Text(sftp.user)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.dsTextSecondary)
                        }

                        LabeledContent("Auth Method") {
                            Text(sftp.authMode.displayName)
                                .font(.caption)
                                .foregroundStyle(Color.dsTextSecondary)
                        }

                        if sftp.authMode == .sshKey, let key = sftp.keyPath, !key.isEmpty {
                            LabeledContent("Key") {
                                Text(URL(fileURLWithPath: key).lastPathComponent)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.dsTextMuted)
                            }
                        }

                        if let tunnel = sftp.tunnel, tunnel.isTunneled {
                            LabeledContent("Tunnel") {
                                Text(tunnel.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(Color.dsAccent)
                            }
                        }
                    }

                    LabeledContent("Remote Path") {
                        Text(remote.bucketOrRootPath.isEmpty ? "Default (User Home)" : remote.bucketOrRootPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
            } else if remote.provider == .ftp {
                formSection(title: "FTP SERVER") {
                    if let ftp = remote.ftpConfiguration {
                        LabeledContent("Server", value: "\(ftp.host):\(ftp.port)")
                        LabeledContent("Protocol", value: ftp.security.displayName)
                        LabeledContent("User", value: ftp.user)
                        if ftp.security != .plain && ftp.noCheckCertificate {
                            Text("TLS certificate verification is disabled.")
                                .font(.caption).foregroundStyle(Color.dsAmber)
                        }
                    }
                    LabeledContent("Remote folder", value: remote.bucketOrRootPath.isEmpty ? "Home" : remote.bucketOrRootPath)
                }
            } else if remote.provider == .smb {
                formSection(title: "SMB SERVER") {
                    if let smb = remote.smbConfiguration {
                        LabeledContent("Server") {
                            Text("\(smb.host):\(smb.port)").font(.caption.monospaced())
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        LabeledContent("User") {
                            Text(smb.user).font(.caption.monospaced()).foregroundStyle(Color.dsTextSecondary)
                        }
                        LabeledContent("Domain") {
                            Text(smb.domain.isEmpty ? "WORKGROUP" : smb.domain)
                                .font(.caption).foregroundStyle(Color.dsTextSecondary)
                        }
                    }
                    LabeledContent("Shared Folder / Path") {
                        Text(remote.bucketOrRootPath).font(.caption.monospaced())
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
            } else if remote.provider == .webdav {
                formSection(title: "WEBDAV SERVER") {
                    if let webdav = remote.webdavConfiguration {
                        LabeledContent("Server URL") {
                            Text(webdav.url)
                                .font(.caption.monospaced())
                                .foregroundStyle(Color.dsTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if !webdav.user.isEmpty {
                            LabeledContent("User") {
                                Text(webdav.user)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Color.dsTextSecondary)
                            }
                        }

                        LabeledContent("Auth Method") {
                            Text(webdav.authMode.displayName)
                                .font(.caption)
                                .foregroundStyle(Color.dsTextSecondary)
                        }

                        if webdav.insecureSkipVerify {
                            LabeledContent("TLS Verification") {
                                Text("Self-signed allowed")
                                    .font(.caption)
                                    .foregroundStyle(Color.dsAmber)
                            }
                        }
                    }

                    LabeledContent("Remote Path") {
                        Text(remote.bucketOrRootPath.isEmpty ? "Root (/)" : remote.bucketOrRootPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(Color.dsTextSecondary)
                    }
                }
            }
        }
    }

    private func formSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ConnectionFormSection(title: title, content: content)
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: DSSpacing.sm) {
            Button {
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Delete")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.dsRed)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                        .fill(Color.dsRed.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                                .strokeBorder(Color.dsRed.opacity(0.25), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                saveChanges()
            } label: {
                HStack(spacing: 5) {
                    if isSaving {
                        ProgressView().controlSize(.mini).tint(.white)
                    }
                    Text("Save Changes")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DSSpacing.md)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DSRadius.sm, style: .continuous)
                        .fill((hasChanges || saveError != nil) && !isSaving ? Color.dsAccent : Color.dsTextMuted.opacity(0.4))
                )
            }
            .buttonStyle(.plain)
            .disabled(isSaving || (!hasChanges && saveError == nil))
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
    }

    // MARK: - Actions

    private func loadEditable() {
        editedName      = remote.name
        editedAutoMount = remote.autoMountAtLaunch
        editedReadOnly  = remote.isReadOnly
    }

    private var hasChanges: Bool {
        editedName != remote.name ||
        editedAutoMount != remote.autoMountAtLaunch ||
        editedReadOnly != remote.isReadOnly
    }

    private var isRenamed: Bool {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != remote.name
    }

    private func saveChanges() {
        isSaving = true
        var updated = remote
        updated.name              = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.autoMountAtLaunch = editedAutoMount
        updated.isReadOnly        = editedReadOnly
        saveError = nil
        Task { @MainActor in
            do { try await appState.saveRemoteSettings(updated) }
            catch { saveError = "Could not finish applying settings to Finder: \(error.localizedDescription)" }
            withAnimation(DSAnimation.snap) { isSaving = false }
        }
    }

    private func reauthorize(serviceAccountKey: GoogleCloudServiceAccountKey? = nil) {
        reauthorizeError = nil
        isReauthorizing = true
        Task { @MainActor in
            do {
                let credential: RcloneRemoteCredential
                var identity: GoogleCloudAuthenticationIdentity?
                if remote.provider == .googleCloudStorage {
                    guard let selection = remote.googleCloudStorage else { throw GoogleCloudStorageError.invalidSelection }
                    let authorization: GoogleCloudAuthorization
                    if let serviceAccountKey { authorization = .serviceAccount(serviceAccountKey) }
                    else {
                        let client = try GoogleDriveOAuthConfiguration.loadClient()
                        authorization = .googleAccount(try await GoogleDriveOAuthService(scopes: GoogleCloudDiscoveryService.oauthScopes).authorize(client: client))
                    }
                    let discovery = GoogleCloudDiscoveryService()
                    try await discovery.checkAuthorization(authorization)
                    try await discovery.validate(selection: selection, authorization: authorization, readOnly: remote.isReadOnly)
                    let currentAuthorization = try await discovery.refreshedAuthorization(authorization)
                    credential = try currentAuthorization.credential(selection: selection, remoteName: remote.name)
                    identity = authorization.identity
                    let connection = try FileProviderConnectionDescriptor(remote: remote)
                    let client = try await supervisor.startDaemon()
                    let backend = try GoogleCloudStorageFileProviderBackend(connection: connection, client: client, credential: credential)
                    _ = try await backend.listChildren()
                } else {
                    let client = try GoogleDriveOAuthConfiguration.loadClient()
                    let authorization = try await GoogleDriveOAuthService().authorize(client: client)
                    credential = authorization.credential(remoteName: remote.name)
                }
                let account = remote.keychainAccountKey ?? "credential.\(UUID().uuidString.lowercased())"
                if remote.keychainAccountKey != nil {
                    do { try await keychain.replaceCredential(credential, account: account) }
                    catch KeychainError.itemNotFound {
                        try await keychain.saveCredential(credential, account: account)
                    }
                } else { try await keychain.saveCredential(credential, account: account) }
                var updated = remote
                updated.keychainAccountKey = account
                if let identity { updated.googleCloudAuthentication = identity }
                appState.updateRemote(updated)
                let health = await appState.validateAndRefreshConnection(updated)
                if let reason = health.reason {
                    reauthorizeError = reason
                }
                isReauthorizing = false
            } catch {
                withAnimation(DSAnimation.gentle) {
                    reauthorizeError = error.localizedDescription
                    isReauthorizing = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func actionButton(
        title: String,
        icon: String,
        color: Color,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DSSpacing.xs) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.dsTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DSSpacing.md)
            .dsGlassCard(cornerRadius: DSRadius.sm)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private var presentation: ConnectionStatusPresentation {
        ConnectionStatusPresentation(status: status, health: health, provider: remote.provider)
    }
    private var statusLabel: String { presentation.label }
    private var statusColor: Color { presentation.color }
}
