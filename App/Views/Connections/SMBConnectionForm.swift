import SwiftUI

/// SMB uses the same section, verification and save pattern as SFTP/WebDAV.
struct SMBConnectionForm<ProviderPicker: View>: View {
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
    @State private var port = "445"
    @State private var share = ""
    @State private var availableShares: [String] = []
    @State private var discoveringShares = false
    @State private var discoveryMessage: String?
    @State private var subdirectory = ""
    @State private var guestAccess = false
    @State private var user = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var autoMount = false
    @State private var readOnly = false
    @State private var busy = false
    @State private var verificationState: ConnectionVerificationState = .untested
    @State private var verificationRevision = UUID()
    @State private var errorMessage: String?

    private var configuration: SMBConfiguration {
        SMBConfiguration(host: host, port: Int(port) ?? 0,
            user: guestAccess ? "guest" : user, domain: guestAccess ? "WORKGROUP" : domain)
    }

    private var rootPath: String? {
        try? SMBConfiguration.rootPath(share: share, subdirectory: subdirectory)
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
                            progressMessage: "Connecting to server and testing the selected shared folder…",
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
        .onChange(of: guestAccess) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
        .onChange(of: host) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
        .onChange(of: port) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
        .onChange(of: share) { _, _ in invalidateVerification() }
        .onChange(of: subdirectory) { _, _ in invalidateVerification() }
        .onChange(of: user) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
        .onChange(of: password) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
        .onChange(of: domain) { _, _ in
            availableShares = []
            discoveryMessage = nil
            invalidateVerification()
        }
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
                        TextField("445", text: $port).textFieldStyle(.roundedBorder)
                    }.frame(width: 70)
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Shared Folder")
                    TextField("e.g. Documents or Shared", text: $share)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    HStack {
                        Button(action: discoverShares) {
                            Label("Load Shared Folders", systemImage: "arrow.clockwise")
                        }
                        .disabled(!canDiscoverShares || discoveringShares)
                        if discoveringShares { ProgressView().controlSize(.small) }
                    }
                    if !availableShares.isEmpty {
                        Picker("Available folders", selection: $share) {
                            Text("Select a shared folder…").tag("")
                            if !share.isEmpty && !availableShares.contains(share) {
                                Text(share).tag(share)
                            }
                            ForEach(availableShares, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if let discoveryMessage {
                        Text(discoveryMessage).font(.caption).foregroundStyle(Color.dsTextMuted)
                    }
                    Text("Load folders using the server address and account below, or enter a known share name.")
                        .font(.caption).foregroundStyle(Color.dsTextMuted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    fieldLabel("Subfolder (optional)")
                    TextField("e.g. Projects/Family (blank for the share root)", text: $subdirectory)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                }
                if !share.isEmpty {
                    if let validationMessage {
                        Text(validationMessage).font(.caption).foregroundStyle(Color.dsAmber)
                    }
                }
            }.disabled(busy)
        }
    }

    private var authenticationSection: some View {
        ConnectionFormSection(title: "2. AUTHENTICATION") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Picker("Method", selection: $guestAccess) {
                    Text("Guest").tag(true)
                    Text("Username & Password").tag(false)
                }
                .pickerStyle(.segmented)
                if guestAccess {
                    Text("Connect as a guest without a username or password.")
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
                    VStack(alignment: .leading, spacing: 4) {
                        fieldLabel("Domain (optional)")
                        TextField("WORKGROUP", text: $domain)
                            .textFieldStyle(.roundedBorder).autocorrectionDisabled()
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
            _ = try SMBConfiguration.rootPath(share: share, subdirectory: subdirectory)
            return nil
        } catch { return error.localizedDescription }
    }

    private func invalidateVerification() {
        verificationRevision = UUID()
        verificationState = .untested
        errorMessage = nil
    }

    private func discoverShares() {
        guard canDiscoverShares, !busy, !discoveringShares else { return }
        let config = configuration
        let secret = guestAccess ? "" : password
        let revision = verificationRevision
        discoveringShares = true
        discoveryMessage = nil
        Task { @MainActor in
            defer { discoveringShares = false }
            do {
                let client = try await supervisor.startDaemon()
                let obscured = secret.isEmpty ? nil : try await client.obscure(password: secret)
                let options = try config.backendOptions(obscuredPassword: obscured)
                let items = try await client.list(fs: .configuration(options), path: "",
                    options: RcloneListOptions(dirsOnly: true))
                guard verificationRevision == revision else { return }
                availableShares = items.filter { $0.isDir }.map { $0.name }.sorted()
                discoveryMessage = availableShares.isEmpty
                    ? "The server returned no shared folders for this account. You can enter a known share name manually."
                    : "Select a shared folder, then test the connection."
            } catch {
                guard verificationRevision == revision else { return }
                discoveryMessage = ConnectionPreflightService.classify(error: error,
                    backendOptions: ["type": "smb", "port": String(config.port)])
            }
        }
    }

    private func testConnection() {
        guard canTest, !busy, !verificationState.isTesting, let root = rootPath else { return }
        let config = configuration
        let secret = guestAccess ? "" : password
        let revision = verificationRevision
        verificationState = .testing
        errorMessage = nil
        Task { @MainActor in
            do {
                let client = try await supervisor.startDaemon()
                let obscured = secret.isEmpty ? nil : try await client.obscure(password: secret)
                let options = try config.backendOptions(obscuredPassword: obscured)
                // Test the same share/subfolder root that the File Provider will use.
                var rootedOptions = options
                rootedOptions["_root"] = root
                let result = await ConnectionPreflightService.shared.verify(client: client, backendOptions: rootedOptions)
                guard verificationRevision == revision else { return }
                verificationState = result.isSuccess ? .verified(message: result.message) : .failed(message: result.message)
            } catch {
                guard verificationRevision == revision else { return }
                verificationState = .failed(message: ConnectionPreflightService.classify(error: error, backendOptions: ["type": "smb", "port": String(config.port)]))
            }
        }
    }

    private func save() {
        guard canSave, !busy, let root = rootPath else { return }
        let config = configuration
        let secret = guestAccess ? "" : password
        let remoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "smb.\(UUID().uuidString.lowercased())"
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let client = try await supervisor.startDaemon()
                let obscured = secret.isEmpty ? nil : try await client.obscure(password: secret)
                let options = try config.backendOptions(obscuredPassword: obscured)
                try await keychain.saveCredential(RcloneRemoteCredential(remoteName: remoteName, provider: .smb,
                    backendOptions: options), account: account)
                let remote = RemoteConfig(name: remoteName, provider: .smb, bucketOrRootPath: root,
                    keychainAccountKey: account, smbConfiguration: config,
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
