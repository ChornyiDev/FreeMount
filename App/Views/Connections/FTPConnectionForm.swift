import SwiftUI

/// FTP uses the same section, verification and save pattern as SFTP/WebDAV.
struct FTPConnectionForm<ProviderPicker: View>: View {
    let keychain: KeychainService
    let supervisor: RcloneProcessSupervisor
    let existingNames: [String]
    let onSave: (RemoteConfig) -> Void
    let onCancel: () -> Void
    let providerPicker: ProviderPicker
    @Binding var name: String
    @Binding var isCustomName: Bool
    @FocusState private var isNameFocused: Bool

    @State private var host = ""
    @State private var port = "21"
    @State private var security: FTPSecurity = .plain
    @State private var noCheckCertificate = false
    @State private var subdirectory = ""
    @State private var anonymousAccess = false
    @State private var user = ""
    @State private var password = ""
    @State private var autoMount = false
    @State private var readOnly = false
    @State private var busy = false
    @State private var verificationState: ConnectionVerificationState = .untested
    @State private var verificationRevision = UUID()
    @State private var errorMessage: String?

    private var configuration: FTPConfiguration {
        FTPConfiguration(host: host, port: Int(port) ?? 0,
            user: anonymousAccess ? "anonymous" : user, security: security, noCheckCertificate: noCheckCertificate)
    }

    private var rootPath: String? {
        try? FTPConfiguration.rootPath(subdirectory)
    }

    private var canTest: Bool {
        rootPath != nil && canDiscoverShares
    }

    private var canDiscoverShares: Bool {
        (try? configuration.backendOptions()) != nil
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !isDuplicateName && canTest && verificationState.isVerified
    }

    private var isDuplicateName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return existingNames.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    providerPicker
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        connectionNameSection
                        serverSection
                        authenticationSection
                        ConnectionTestSection(title: "3. TEST CONNECTION",
                            verificationState: verificationState, canTest: canTest, busy: busy,
                            progressMessage: "Connecting to server and testing the selected remote folder…",
                            onTest: testConnection)
                        optionsSection
                        if let errorMessage {
                            Text(errorMessage).font(.caption).foregroundStyle(Color.dsRed)
                        }
                    }
                }
                .padding(DSSpacing.xl)
            }
            Divider().overlay(Color.dsBorderSubtle)
            ConnectionFormFooter(title: busy ? "Saving…" : "Save & Connect", busy: busy,
                enabled: !busy && canSave, onCancel: onCancel, onAction: save)
        }
        .onChange(of: anonymousAccess) { _, _ in
            invalidateVerification()
        }
        .onChange(of: host) { _, _ in
            invalidateVerification()
        }
        .onChange(of: port) { _, _ in
            invalidateVerification()
        }
        .onChange(of: subdirectory) { _, _ in invalidateVerification() }
        .onChange(of: user) { _, _ in
            invalidateVerification()
        }
        .onChange(of: password) { _, _ in
            invalidateVerification()
        }
        .onChange(of: security) { old, new in
            if port == String(old.defaultPort) { port = String(new.defaultPort) }
            invalidateVerification()
        }
        .onChange(of: noCheckCertificate) { _, _ in invalidateVerification() }
    }

    private var connectionNameSection: some View {
        ConnectionFormSection(title: "CONNECTION") {
            TextField("Connection Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .disabled(busy)
                .onChange(of: name) { _, _ in
                    if isNameFocused { isCustomName = true }
                }
            if isDuplicateName {
                Text("A connection with this name already exists. Please choose a unique name.")
                    .font(.caption).foregroundStyle(Color.dsAmber)
            }
        }
    }

    private var serverSection: some View {
        ConnectionFormSection(title: "1. SERVER") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                HStack(spacing: DSSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Host / IP")
                        TextField("e.g. server.local or 192.168.1.100", text: $host)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Port")
                        TextField("21", text: $port).textFieldStyle(.roundedBorder)
                    }.frame(width: 70)
                }
                Picker("Protocol", selection: $security) {
                    ForEach(FTPSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Remote folder (optional)")
                    TextField("Blank for home; / for server root", text: $subdirectory)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                if security == .plain {
                    Text("FTP sends credentials and files without encryption.")
                        .font(.caption).foregroundStyle(Color.dsAmber)
                } else {
                    Toggle("Allow untrusted / self-signed SSL certificates", isOn: $noCheckCertificate)
                }
                if !host.isEmpty, let validationMessage {
                    Text(validationMessage).font(.caption).foregroundStyle(Color.dsAmber)
                }
            }.disabled(busy)
        }
    }

    private var authenticationSection: some View {
        ConnectionFormSection(title: "2. AUTHENTICATION") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Picker("Method", selection: $anonymousAccess) {
                    Text("Anonymous").tag(true)
                    Text("Username & Password").tag(false)
                }
                .pickerStyle(.segmented)
                if anonymousAccess {
                    Text("Connect using the anonymous account. Some servers require an email address as the password; use Username & Password for those servers.")
                        .font(.caption).foregroundStyle(Color.dsTextMuted)
                } else {
                    HStack(spacing: DSSpacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            fieldLabel("Username")
                            TextField("Username", text: $user)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            fieldLabel("Password")
                            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }.disabled(busy)
        }
    }

    private var optionsSection: some View {
        ConnectionFormSection(title: "4. OPTIONS") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Toggle("Connect automatically on app launch", isOn: $autoMount)
                Toggle("Mount read-only", isOn: $readOnly)
            }.disabled(busy)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(Color.dsTextMuted)
    }

    private var validationMessage: String? {
        do {
            _ = try configuration.backendOptions()
            _ = try FTPConfiguration.rootPath(subdirectory)
            return nil
        } catch { return error.localizedDescription }
    }

    private func invalidateVerification() {
        verificationRevision = UUID()
        verificationState = .untested
        errorMessage = nil
    }

    private func testConnection() {
        guard canTest, !busy, !verificationState.isTesting, let root = rootPath else { return }
        let config = configuration
        let secret = anonymousAccess ? "anonymous" : password
        let revision = verificationRevision
        verificationState = .testing
        errorMessage = nil
        Task { @MainActor in
            do {
                let client = try await supervisor.startDaemon()
                let obscured = secret.isEmpty ? nil : try await client.obscure(password: secret)
                let options = try config.backendOptions(obscuredPassword: obscured)
                // Test the same remote folder root that the File Provider will use.
                var rootedOptions = options
                rootedOptions["_root"] = root
                let result = await ConnectionPreflightService.shared.verify(client: client, backendOptions: rootedOptions)
                guard verificationRevision == revision else { return }
                verificationState = result.isSuccess ? .verified(message: result.message) : .failed(message: result.message)
            } catch {
                guard verificationRevision == revision else { return }
                verificationState = .failed(message: ConnectionPreflightService.classify(error: error, backendOptions: ["type": "ftp", "port": String(config.port)]))
            }
        }
    }

    private func save() {
        guard canSave, !busy, let root = rootPath else { return }
        let config = configuration
        let secret = anonymousAccess ? "anonymous" : password
        let remoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "ftp.\(UUID().uuidString.lowercased())"
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let client = try await supervisor.startDaemon()
                let obscured = secret.isEmpty ? nil : try await client.obscure(password: secret)
                let options = try config.backendOptions(obscuredPassword: obscured)
                try await keychain.saveCredential(RcloneRemoteCredential(remoteName: remoteName, provider: .ftp,
                    backendOptions: options), account: account)
                let remote = RemoteConfig(name: remoteName, provider: .ftp, bucketOrRootPath: root,
                    keychainAccountKey: account, ftpConfiguration: config,
                    autoMountAtLaunch: autoMount, isReadOnly: readOnly)
                busy = false
                onSave(remote)
            } catch {
                busy = false
                errorMessage = CredentialRedactor.redact(error.localizedDescription)
            }
        }
    }
}
