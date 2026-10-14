import SwiftUI

/// Form for creating and configuring a WebDAV connection with URL, Nextcloud/ownCloud optimizations,
/// and TLS verification controls.
struct WebDAVConnectionForm<ProviderPicker: View>: View {
    let keychain: KeychainService
    let supervisor: RcloneProcessSupervisor
    let existingNames: [String]
    let onSave: (RemoteConfig) -> Void
    let onCancel: () -> Void
    let providerPicker: ProviderPicker

    @Binding var name: String
    @Binding var isCustomName: Bool
    @FocusState private var isNameFocused: Bool

    // WebDAV Core Settings
    @State private var urlString = ""
    @State private var isNextcloud = false
    @State private var isCustomNextcloudToggle = false
    @State private var user = ""
    @State private var authMode: WebDAVAuthMode = .password
    @State private var secret = "" // Password, app token, or bearer token
    @State private var remotePath = ""
    @State private var insecureSkipVerify = false

    // Options
    @State private var readOnly = false
    @State private var autoMount = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var verificationState: ConnectionVerificationState = .untested
    @State private var verificationRevision = UUID()

    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !existingNames.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private var validURL: Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let scheme = parsed.scheme else { return false }
        return (scheme == "http" || scheme == "https" || scheme == "webdav" || scheme == "webdavs") && parsed.host != nil
    }

    private var canTest: Bool {
        guard validURL else { return false }
        if authMode == .password {
            return !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
    }

    // MARK: - Form Sections

    private var form: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            connectionNameSection
            serverDetailsSection
            authenticationSection
            securitySection
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

    private var serverDetailsSection: some View {
        ConnectionFormSection(title: "1. SERVER") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL").font(.caption).foregroundStyle(Color.dsTextMuted)
                    HStack(spacing: DSSpacing.sm) {
                        TextField("Server URL", text: $urlString, prompt: Text(verbatim: "e.g. https://dav.example.com or https://192.168.1.100:5006"))
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .disabled(busy)
                            .onChange(of: urlString) { _, newURL in
                                invalidateVerification()
                                handleURLChanged(newURL)
                            }

                        if isNextcloud && !user.isEmpty {
                            Button("Add Path") {
                                appendNextcloudPath()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                            .help("Appends /remote.php/dav/files/\(user)/ to the server URL")
                        }
                    }

                    if !validURL && !urlString.isEmpty {
                        Text("Enter a valid http:// or https:// WebDAV URL")
                            .font(.caption)
                            .foregroundStyle(Color.dsRed)
                    }
                }

                Toggle(isOn: $isNextcloud) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nextcloud / ownCloud server")
                            .font(.body)
                        Text("Enables OC-Checksum file hashing and timestamp preservation.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextMuted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .disabled(busy)
                .onChange(of: isNextcloud) { _, _ in
                    invalidateVerification()
                    isCustomNextcloudToggle = true
                    updateSuggestedName(from: urlString)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Remote Path").font(.caption).foregroundStyle(Color.dsTextMuted)
                    TextField("e.g. Documents or Projects (blank for root)", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .onChange(of: remotePath) { _, _ in
                            invalidateVerification()
                        }
                }
            }
        }
    }

    private var authenticationSection: some View {
        ConnectionFormSection(title: "2. AUTHENTICATION") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Picker("Method", selection: $authMode) {
                    ForEach(WebDAVAuthMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                .onChange(of: authMode) { _, _ in
                    invalidateVerification()
                }

                if authMode == .password {
                    HStack(spacing: DSSpacing.md) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Username").font(.caption).foregroundStyle(Color.dsTextMuted)
                            TextField("Username", text: $user)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                                .disabled(busy)
                                .onChange(of: user) { _, _ in
                                    invalidateVerification()
                                    updateSuggestedName(from: urlString)
                                }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password / App Token").font(.caption).foregroundStyle(Color.dsTextMuted)
                            SecureField("Password or token", text: $secret)
                                .textFieldStyle(.roundedBorder)
                                .disabled(busy)
                                .onChange(of: secret) { _, _ in
                                    invalidateVerification()
                                }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bearer Token").font(.caption).foregroundStyle(Color.dsTextMuted)
                        SecureField("Enter API or OAuth bearer token", text: $secret)
                            .textFieldStyle(.roundedBorder)
                            .disabled(busy)
                            .onChange(of: secret) { _, _ in
                                invalidateVerification()
                            }
                    }
                }
            }
        }
    }

    private var securitySection: some View {
        ConnectionFormSection(title: "3. SECURITY & TLS") {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Toggle(isOn: $insecureSkipVerify) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow untrusted / self-signed SSL certificates")
                            .font(.body)
                        Text("Enable for local servers or NAS using self-signed TLS.")
                            .font(.caption)
                            .foregroundStyle(Color.dsTextMuted)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .disabled(busy)
                .onChange(of: insecureSkipVerify) { _, _ in
                    invalidateVerification()
                }
            }
        }
    }

    private var testConnectionSection: some View {
        ConnectionTestSection(verificationState: verificationState, canTest: canTest,
                              busy: busy, progressMessage: "Connecting to server and testing WebDAV endpoint…", onTest: testConnection)
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

    // MARK: - Helpers

    private func invalidateVerification() {
        verificationRevision = UUID()
        if verificationState != .untested {
            verificationState = .untested
        }
    }

    private func handleURLChanged(_ newURL: String) {
        if !isCustomNextcloudToggle {
            let lower = newURL.lowercased()
            isNextcloud = lower.contains("nextcloud") || lower.contains("owncloud") || lower.contains("remote.php")
        }
        updateSuggestedName(from: newURL)
    }

    private func updateSuggestedName(from url: String) {
        guard !isCustomName else { return }
        if let host = URL(string: url)?.host, !host.isEmpty {
            name = isNextcloud ? "Nextcloud (\(host))" : host
        } else if isNextcloud {
            name = "Nextcloud"
        } else {
            name = "WebDAV"
        }
    }

    private func appendNextcloudPath() {
        let cleanURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: cleanURL) else { return }
        let cleanUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        components.path = "/remote.php/dav/files/\(cleanUser)/"
        if let newURL = components.string {
            urlString = newURL
        }
    }

    private func testConnection() {
        guard canTest else { return }
        verificationState = .testing
        errorMessage = nil
        let revision = verificationRevision

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendor: WebDAVVendor = isNextcloud ? .nextcloud : .generic

        let config = WebDAVConfiguration(
            url: trimmedURL,
            vendor: vendor,
            user: trimmedUser,
            authMode: authMode,
            insecureSkipVerify: insecureSkipVerify
        )

        Task {
            let client = supervisor.client
            let effectiveSecret: String?
            do {
                if config.authMode == .password && !trimmedSecret.isEmpty {
                    effectiveSecret = try await client.obscure(password: trimmedSecret)
                } else {
                    effectiveSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                }
            } catch {
                await MainActor.run {
                    guard verificationRevision == revision else { return }
                    verificationState = .failed(message: "Could not prepare the password: \(error.localizedDescription)")
                }
                return
            }
            let backendOpts = config.backendOptions(secret: effectiveSecret)

            let result = await ConnectionPreflightService.shared.verify(
                client: client,
                backendOptions: backendOpts,
                remotePath: trimmedPath
            )
            await MainActor.run {
                guard verificationRevision == revision else { return }
                if result.isSuccess {
                    verificationState = .verified(message: result.message)
                } else {
                    verificationState = .failed(message: result.message)
                }
            }
        }
    }

    private func save() {
        guard canSave, !busy else { return }
        busy = true
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)

        let vendor: WebDAVVendor = isNextcloud ? .nextcloud : .generic

        let config = WebDAVConfiguration(
            url: trimmedURL,
            vendor: vendor,
            user: trimmedUser,
            authMode: authMode,
            insecureSkipVerify: insecureSkipVerify
        )

        let accountKey = "webdav.\(UUID().uuidString.lowercased())"

        Task {
            do {
                let client = supervisor.client
                let effectiveSecret: String?
                if config.authMode == .password && !trimmedSecret.isEmpty {
                    effectiveSecret = try await client.obscure(password: trimmedSecret)
                } else {
                    effectiveSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
                }

                let backendOpts = config.backendOptions(secret: effectiveSecret)
                let credential = RcloneRemoteCredential(
                    remoteName: trimmedName,
                    provider: .webdav,
                    backendOptions: backendOpts
                )
                try await keychain.saveCredential(credential, account: accountKey)

                let remote = RemoteConfig(
                    id: UUID(),
                    name: trimmedName,
                    provider: .webdav,
                    bucketOrRootPath: trimmedPath,
                    keychainAccountKey: accountKey,
                    webdavConfiguration: config,
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
