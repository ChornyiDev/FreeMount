import SwiftUI
import UniformTypeIdentifiers

/// Form for creating and configuring an SFTP connection with SSH config import,
/// key auto-discovery, and zero-trust tunnel presets.
struct SFTPConnectionForm<ProviderPicker: View>: View {
    let keychain: KeychainService
    let supervisor: RcloneProcessSupervisor
    let existingNames: [String]
    let onSave: (RemoteConfig) -> Void
    let onCancel: () -> Void
    let providerPicker: ProviderPicker

    @Binding var name: String
    @Binding var isCustomName: Bool
    @FocusState private var isNameFocused: Bool

    // SFTP Core Settings
    @State private var host = ""
    @State private var portString = "22"
    @State private var user = ""
    @State private var remotePath = ""
    @State private var authMode: SFTPAuthMode = .sshKey
    @State private var selectedKeyPath: String = ""
    @State private var secret = "" // Password or key passphrase

    // SSH Config Import
    @State private var sshConfigHosts: [SSHHostEntry] = []
    @State private var selectedConfigHostAlias: String = ""

    // SSH Key Discovery
    @State private var discoveredKeys: [SSHPrivateKeyInfo] = []
    @State private var showCustomKeyPicker = false

    // SSH Tunneling & Proxy
    @State private var tunnelType: SSHTunnelType = .direct
    @State private var cloudflareCommand = SSHTunnelConfiguration.defaultCloudflareCommand
    @State private var jumpHost = ""
    @State private var customProxyCommand = ""

    // Options
    @State private var readOnly = false
    @State private var autoMount = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var verificationState: ConnectionVerificationState = .untested

    private var parsedPort: Int {
        Int(portString.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 22
    }

    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !existingNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var canTest: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else { return false }
        guard parsedPort > 0 && parsedPort <= 65535 else { return false }

        if authMode == .sshKey {
            return !selectedKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var canSave: Bool {
        validName && verificationState.isVerified
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    providerPicker
                    form
                }
                .padding(DSSpacing.xl)
            }
            Divider().overlay(Color.dsBorderSubtle)
            ConnectionFormFooter(
                title: busy ? "Saving…" : "Save & Connect",
                busy: busy,
                enabled: !busy && canSave,
                onCancel: onCancel
            ) {
                save()
            }
        }
        .fileImporter(isPresented: $showCustomKeyPicker, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                selectedKeyPath = url.path
            case .failure(let error):
                errorMessage = "Failed to select key file: \(error.localizedDescription)"
            }
        }
        .onAppear {
            loadSSHEnvironment()
        }
    }

    // MARK: - Form Sections

    private var form: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            connectionNameSection

            if !sshConfigHosts.isEmpty {
                sshConfigImportSection
            }

            serverDetailsSection
            authenticationSection
            tunnelSection
            testConnectionSection
            optionsSection

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.dsRed)
                    .padding(.horizontal, 2)
            }
        }
    }

    private var connectionNameSection: some View {
        ConnectionFormSection(title: "CONNECTION") {
            TextField("Connection Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .disabled(busy)
                .onChange(of: name) { _, _ in
                    if isNameFocused {
                        isCustomName = true
                    }
                }

            if !name.isEmpty && !validName {
                Text("A connection with this name already exists. Please choose a unique name.")
                    .font(.caption)
                    .foregroundStyle(Color.dsAmber)
            }
        }
    }

    private var sshConfigImportSection: some View {
        ConnectionFormSection(title: "QUICK IMPORT") {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Picker("From ~/.ssh/config", selection: $selectedConfigHostAlias) {
                    Text("Select a configured host…").tag("")
                    Divider()
                    ForEach(sshConfigHosts) { entry in
                        Text("\(entry.alias) (\(entry.effectiveHostName))").tag(entry.alias)
                    }
                }
                .disabled(busy)
                .onChange(of: selectedConfigHostAlias) { _, newAlias in
                    applySSHHost(newAlias)
                }

                Text("Auto-populates host, user, port, key, and tunnel from your OpenSSH configuration.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dsTextMuted)
            }
        }
    }

    private var serverDetailsSection: some View {
        ConnectionFormSection(title: "1. SERVER") {
            VStack(spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host / IP").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("e.g. server.example.com or 192.168.1.1", text: $host)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                            .onChange(of: host) { _, _ in invalidateVerification() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Port").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("22", text: $portString)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .disabled(busy)
                            .onChange(of: portString) { _, _ in invalidateVerification() }
                    }
                }

                HStack(spacing: DSSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Username").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("e.g. root or ubuntu", text: $user)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                            .onChange(of: user) { _, _ in invalidateVerification() }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote Path").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("e.g. /var/www (blank for home)", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                            .onChange(of: remotePath) { _, _ in invalidateVerification() }
                    }
                }
            }
        }
    }

    private var authenticationSection: some View {
        ConnectionFormSection(title: "2. AUTHENTICATION") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Picker("Method", selection: $authMode) {
                    ForEach(SFTPAuthMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                .onChange(of: authMode) { _, _ in invalidateVerification() }

                switch authMode {
                case .sshKey:
                    sshKeyPickerRow
                    SecureField("Key Passphrase (optional)", text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: secret) { _, _ in invalidateVerification() }

                case .password:
                    SecureField("SSH Password", text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: secret) { _, _ in invalidateVerification() }

                case .sshAgent:
                    Text("Uses active SSH Agent socket ($SSH_AUTH_SOCK) for authentication.")
                        .font(.caption)
                        .foregroundStyle(Color.dsTextMuted)
                }
            }
        }
    }

    private var sshKeyPickerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Private Key").font(.caption).foregroundStyle(Color.dsTextMuted)
            HStack(spacing: DSSpacing.sm) {
                if !discoveredKeys.isEmpty {
                    Picker("Key", selection: $selectedKeyPath) {
                        if !discoveredKeys.contains(where: { $0.path == selectedKeyPath }) && !selectedKeyPath.isEmpty {
                            Text(URL(fileURLWithPath: selectedKeyPath).lastPathComponent).tag(selectedKeyPath)
                        }
                        ForEach(discoveredKeys) { key in
                            Text(key.displayName).tag(key.path)
                        }
                    }
                    .labelsHidden()
                    .disabled(busy)
                    .onChange(of: selectedKeyPath) { _, _ in invalidateVerification() }
                } else {
                    TextField("Private Key Path", text: $selectedKeyPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: selectedKeyPath) { _, _ in invalidateVerification() }
                }

                Button {
                    showCustomKeyPicker = true
                } label: {
                    Image(systemName: "folder")
                        .help("Choose Key File…")
                }
                .buttonStyle(.bordered)
                .disabled(busy)
            }
        }
    }

    private var tunnelSection: some View {
        ConnectionFormSection(title: "3. SSH TUNNEL & PROXY") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Picker("Mode", selection: $tunnelType) {
                    ForEach(SSHTunnelType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .disabled(busy)
                .onChange(of: tunnelType) { _, _ in invalidateVerification() }

                switch tunnelType {
                case .direct:
                    EmptyView()

                case .cloudflare:
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundStyle(Color.dsAccent)
                            Text("Connects through Cloudflare Zero Trust Tunnel (no open ports needed).")
                                .font(.caption)
                                .foregroundStyle(Color.dsTextSecondary)
                        }
                        TextField("Command", text: $cloudflareCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(busy)
                            .onChange(of: cloudflareCommand) { _, _ in invalidateVerification() }
                    }

                case .jumpHost:
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("Jump Server (ProxyJump)").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("e.g. user@bastion.example.com:22", text: $jumpHost)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                            .onChange(of: jumpHost) { _, _ in invalidateVerification() }
                    }

                case .customProxyCommand:
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        Text("Custom ProxyCommand").font(.caption).foregroundStyle(Color.dsTextMuted)
                        TextField("e.g. ncat --proxy-type socks5 127.0.0.1:9050 %h %p", text: $customProxyCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(busy)
                            .onChange(of: customProxyCommand) { _, _ in invalidateVerification() }
                    }
                }
            }
        }
    }

    private var testConnectionSection: some View {
        ConnectionTestSection(verificationState: verificationState, canTest: canTest,
                              busy: busy, progressMessage: "Connecting to server and testing SFTP access…", onTest: testConnection)
    }

    private var optionsSection: some View {
        ConnectionFormSection(title: "5. OPTIONS") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Toggle("Connect automatically on app launch", isOn: $autoMount)
                    .disabled(busy)
                Toggle("Mount read-only", isOn: $readOnly)
                    .disabled(busy)
            }
        }
    }

    // MARK: - Actions & Helpers

    private func loadSSHEnvironment() {
        sshConfigHosts = SSHConfigParser.loadStandardConfig()
        discoveredKeys = SSHKeyDiscoveryService.discoverKeys()

        if selectedKeyPath.isEmpty, let firstKey = discoveredKeys.first {
            selectedKeyPath = firstKey.path
        }
    }

    private func applySSHHost(_ alias: String) {
        guard let entry = sshConfigHosts.first(where: { $0.alias == alias }) else { return }

        if !isCustomName {
            name = AddConnectionView.uniqueName(base: entry.alias, existingNames: existingNames)
        }
        host = entry.effectiveHostName
        if let u = entry.user, !u.isEmpty { user = u }
        if let p = entry.port { portString = String(p) }
        if let key = entry.identityFile, !key.isEmpty {
            selectedKeyPath = key
            authMode = .sshKey
        }

        if let proxy = entry.proxyCommand, !proxy.isEmpty {
            if proxy.contains("cloudflared") {
                tunnelType = .cloudflare
                cloudflareCommand = proxy
            } else {
                tunnelType = .customProxyCommand
                customProxyCommand = proxy
            }
        } else if let jump = entry.proxyJump, !jump.isEmpty {
            tunnelType = .jumpHost
            jumpHost = jump
        } else {
            tunnelType = .direct
        }
        invalidateVerification()
    }

    private func invalidateVerification() {
        if verificationState != .untested {
            verificationState = .untested
        }
    }

    private func testConnection() {
        guard canTest else { return }
        verificationState = .testing
        errorMessage = nil

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        var tunnelConfig: SSHTunnelConfiguration?
        if tunnelType != .direct {
            tunnelConfig = SSHTunnelConfiguration(
                type: tunnelType,
                customCommand: tunnelType == .cloudflare ? cloudflareCommand : (tunnelType == .customProxyCommand ? customProxyCommand : nil),
                jumpHost: tunnelType == .jumpHost ? jumpHost : nil
            )
        }

        let sftpConfig = SFTPConfiguration(
            host: trimmedHost,
            port: parsedPort,
            user: trimmedUser,
            authMode: authMode,
            keyPath: authMode == .sshKey ? selectedKeyPath : nil,
            tunnel: tunnelConfig,
            sshConfigHostAlias: selectedConfigHostAlias.isEmpty ? nil : selectedConfigHostAlias
        )
        Task {
            let client = supervisor.client
            let effectiveSecret: String?
            do {
                if (authMode == .password || authMode == .sshKey) && !trimmedSecret.isEmpty {
                    effectiveSecret = try await client.obscure(password: trimmedSecret)
                } else {
                    effectiveSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                }
            } catch {
                await MainActor.run {
                    verificationState = .failed(message: "Could not prepare the password: \(error.localizedDescription)")
                }
                return
            }
            let backendOpts = sftpConfig.backendOptions(secret: effectiveSecret)

            let result = await ConnectionPreflightService.shared.verify(
                client: client,
                backendOptions: backendOpts,
                remotePath: trimmedPath
            )
            await MainActor.run {
                if result.isSuccess {
                    verificationState = .verified(message: result.message)
                } else {
                    verificationState = .failed(message: result.message)
                }
            }
        }
    }

    private func save() {
        busy = true
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)

        var tunnelConfig: SSHTunnelConfiguration?
        if tunnelType != .direct {
            tunnelConfig = SSHTunnelConfiguration(
                type: tunnelType,
                customCommand: tunnelType == .cloudflare ? cloudflareCommand : (tunnelType == .customProxyCommand ? customProxyCommand : nil),
                jumpHost: tunnelType == .jumpHost ? jumpHost : nil
            )
        }

        let sftpConfig = SFTPConfiguration(
            host: trimmedHost,
            port: parsedPort,
            user: trimmedUser,
            authMode: authMode,
            keyPath: authMode == .sshKey ? selectedKeyPath : nil,
            tunnel: tunnelConfig,
            sshConfigHostAlias: selectedConfigHostAlias.isEmpty ? nil : selectedConfigHostAlias
        )

        let accountKey = "sftp.\(UUID().uuidString.lowercased())"

        Task {
            do {
                let client = supervisor.client
                let effectiveSecret: String?
                if (authMode == .password || authMode == .sshKey) && !trimmedSecret.isEmpty {
                    effectiveSecret = try await client.obscure(password: trimmedSecret)
                } else {
                    effectiveSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                }
                let backendOpts = sftpConfig.backendOptions(secret: effectiveSecret)
                let credential = RcloneRemoteCredential(
                    remoteName: trimmedName,
                    provider: .sftp,
                    backendOptions: backendOpts
                )
                try await keychain.saveCredential(credential, account: accountKey)

                let remote = RemoteConfig(
                    id: UUID(),
                    name: trimmedName,
                    provider: .sftp,
                    bucketOrRootPath: trimmedPath,
                    keychainAccountKey: accountKey,
                    sftpConfiguration: sftpConfig,
                    autoMountAtLaunch: autoMount,
                    isReadOnly: readOnly
                )

                await MainActor.run {
                    busy = false
                    onSave(remote)
                }
            } catch {
                await MainActor.run {
                    busy = false
                    errorMessage = "Failed to save credentials: \(error.localizedDescription)"
                }
            }
        }
    }
}
