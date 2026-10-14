import SwiftUI
import UniformTypeIdentifiers

/// Dependent selectors are reset synchronously before each discovery request.
struct GoogleCloudConnectionForm<ProviderPicker: View>: View {
    let keychain: KeychainService
    let supervisor: RcloneProcessSupervisor
    let existingNames: [String]
    let onSave: (RemoteConfig) -> Void
    let onCancel: () -> Void
    let providerPicker: ProviderPicker
    @State private var authorization: GoogleCloudAuthorization?
    @State private var authenticationMode: GoogleCloudAuthenticationMode = .googleAccount
    @State private var showKeyImporter = false
    @State private var directEntry = false
    @State private var directBucketName = ""
    @State private var discoveryMessage: String?
    @State private var authorizationError: String?
    @State private var progressTitle = "Loading…"
    @State private var projects: [GoogleCloudProject] = []
    @State private var buckets: [GoogleCloudBucket] = []
    @State private var projectID: String?
    @State private var bucketName: String?
    @Binding var name: String
    @Binding var isCustomName: Bool
    @FocusState private var isNameFocused: Bool

    private func suggestName(_ value: String) {
        guard !isCustomName else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        name = AddConnectionView.uniqueName(base: trimmed, existingNames: existingNames)
    }
    @State private var billingProject = ""
    @State private var readOnly = false
    @State private var autoMount = false
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var requestID = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var discovery = GoogleCloudDiscoveryService()

    private var project: GoogleCloudProject? { projects.first { $0.id == projectID } }
    private var bucket: GoogleCloudBucket? { buckets.first { $0.name == bucketName } }
    private var validName: Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && !existingNames.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }
    private var canSave: Bool {
        guard authorization != nil, validName else { return false }
        if directEntry {
            return (try? GoogleCloudStorageSelection.validateBucket(directBucketName.trimmingCharacters(in: .whitespacesAndNewlines))) != nil
        }
        return project != nil && bucket != nil &&
            (bucket?.billing?.requesterPays != true || !billingProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            ConnectionFormFooter(title: busy ? "Working…" : "Save & Connect", busy: busy, enabled: !busy && canSave, onCancel: onCancel) { save() }
        }
        .fileImporter(isPresented: $showKeyImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url): importKey(url)
            case .failure: authorizationError = GoogleCloudServiceAccountError.unreadableFile.localizedDescription
            }
        }
        .onDisappear {
            operation?.cancel()
            requestID = UUID()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
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
                    Text("Choose a unique connection name.").font(.caption).foregroundStyle(Color.dsAmber)
                }
            }
            ConnectionFormSection(title: "1. AUTHORIZATION") {
                Picker("Authentication", selection: $authenticationMode) {
                    Text("Google Account").tag(GoogleCloudAuthenticationMode.googleAccount)
                    Text("Service Account").tag(GoogleCloudAuthenticationMode.serviceAccount)
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                .onChange(of: authenticationMode) { _, _ in resetAuthorization() }
                ConnectionAuthorizationStateView(
                    isAuthorized: authorization != nil,
                    busy: busy,
                    authorizedTitle: authenticationMode == .serviceAccount ? "Service Account Authorized" : "Google Account Authorized",
                    detail: authorization?.identity.email ?? "Ready to configure this connection",
                    actionTitle: authenticationMode == .serviceAccount ? "Replace key" : "Switch",
                    prompt: authenticationMode == .serviceAccount ? "Import a Google Service Account JSON key to configure this connection." : "Sign in with Google to configure this connection.",
                    signInTitle: authenticationMode == .serviceAccount ? "Import JSON key…" : "Sign in with Google"
                ) {
                    if authenticationMode == .serviceAccount { showKeyImporter = true }
                    else { authorize() }
                }
                if let authorizationError {
                    Text(authorizationError).font(.system(size: 11)).foregroundStyle(Color.dsRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ConnectionFormSection(title: "2. CONFIGURATION") { configuration }
            ConnectionFormSection(title: "3. OPTIONS") {
                Toggle("Connect automatically at launch", isOn: $autoMount).font(.system(size: 12)).disabled(busy)
                Toggle("Read-only access", isOn: $readOnly).font(.system(size: 12)).disabled(busy)
            }
            if busy { ProgressView(progressTitle).controlSize(.small) }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(Color.dsRed).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var configuration: some View {
        if authorization != nil {
            if authenticationMode == .serviceAccount {
                Toggle("Enter bucket manually", isOn: $directEntry)
                    .font(.system(size: 12)).disabled(busy)
                    .onChange(of: directEntry) { _, _ in errorMessage = nil }
            }
            if let discoveryMessage {
                Text(discoveryMessage).font(.caption).foregroundStyle(Color.dsAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if directEntry { directBucketFields }
            else { discoveredBucketFields }
            Text("The selected bucket is fixed for this connection. Google IAM controls the account's permissions.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(authenticationMode == .serviceAccount ? "Import a Service Account key to choose a bucket." : "Authorize your Google account to choose a project and bucket.")
                .font(.system(size: 11)).foregroundStyle(Color.dsTextSecondary)
        }
    }

    @ViewBuilder
    private var directBucketFields: some View {
        TextField("Bucket name", text: $directBucketName).textFieldStyle(.roundedBorder).disabled(busy)
            .onChange(of: directBucketName) { _, value in
                suggestName(value)
            }
        TextField("Requester Pays billing project ID (optional)", text: $billingProject)
            .textFieldStyle(.roundedBorder).disabled(busy)
        Text("Save & Connect verifies access to this bucket. Project and bucket listing permissions are not required.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var discoveredBucketFields: some View {
        Picker("Project", selection: $projectID) {
            Text("Select a project").tag(String?.none)
            ForEach(projects) { project in
                Text("\(project.displayName ?? project.projectId) (\(project.projectId))").tag(Optional(project.id))
            }
        }
        .pickerStyle(.menu).disabled(busy)
        .onChange(of: projectID) { _, _ in loadBuckets() }
        Picker("Bucket", selection: $bucketName) {
            Text("Select a bucket").tag(String?.none)
            ForEach(buckets) { Text($0.name).tag(Optional($0.name)) }
        }
        .pickerStyle(.menu).disabled(busy || project == nil)
        .onChange(of: bucketName) { _, selected in
            billingProject = ""
            if let selected { suggestName(selected) }
        }
        if projectID != nil && buckets.isEmpty && !busy && discoveryMessage == nil {
            Text("No buckets are available in this project.").font(.caption).foregroundStyle(.secondary)
        }
        if projects.isEmpty && !busy && discoveryMessage == nil {
            Text("No accessible projects were found. The account needs resourcemanager.projects.get.").font(.caption).foregroundStyle(.secondary)
        }
        if project != nil {
            Button("Reload buckets") { loadBuckets() }.disabled(busy)
        }
        if bucket?.billing?.requesterPays == true {
            TextField("Requester Pays billing project ID", text: $billingProject).textFieldStyle(.roundedBorder).disabled(busy)
            Text("This bucket bills requests to the billing project you select.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func authorize() {
        resetAuthorization()
        let request = requestID
        busy = true
        progressTitle = "Authorizing…"
        operation = Task { @MainActor in
            do {
                let client = try GoogleDriveOAuthConfiguration.loadClient()
                let result = try await GoogleDriveOAuthService(scopes: GoogleCloudDiscoveryService.oauthScopes).authorize(client: client)
                await discoverProjects(using: .googleAccount(result), request: request)
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                authorizationError = error.localizedDescription; busy = false
            }
        }
    }

    private func resetAuthorization() {
        operation?.cancel()
        requestID = UUID()
        authorization = nil
        projects = []; buckets = []; projectID = nil; bucketName = nil
        directEntry = false; directBucketName = ""; billingProject = ""
        errorMessage = nil; authorizationError = nil; discoveryMessage = nil; busy = false
    }

    private func importKey(_ url: URL) {
        resetAuthorization()
        let request = requestID
        busy = true; progressTitle = "Checking key…"
        operation = Task { @MainActor in
            do {
                let key = try GoogleCloudServiceAccountKey.importFile(url)
                let result = GoogleCloudAuthorization.serviceAccount(key)
                try await discovery.checkAuthorization(result)
                guard requestID == request, !Task.isCancelled else { return }
                await discoverProjects(using: result, request: request)
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                authorizationError = error.localizedDescription; busy = false
            }
        }
    }

    @MainActor
    private func discoverProjects(using result: GoogleCloudAuthorization, request: UUID) async {
        guard requestID == request, !Task.isCancelled else { return }
        authorization = result
        progressTitle = "Loading projects…"
        do {
            let discovered = try await discovery.projects(authorization: result)
            guard requestID == request, !Task.isCancelled else { return }
            projects = discovered; busy = false
            if case .serviceAccount(let key) = result {
                projectID = discovered.first { $0.projectId == key.projectID }?.id
                if discovered.isEmpty { directEntry = true }
            }
        } catch {
            guard requestID == request, !Task.isCancelled else { return }
            discoveryMessage = error.localizedDescription; busy = false
            if result.identity.mode == .serviceAccount { directEntry = true }
        }
    }

    private func loadBuckets() {
        operation?.cancel()
        let request = UUID()
        requestID = request
        buckets = []; bucketName = nil; billingProject = ""; errorMessage = nil
        guard let project, let authorization else { busy = false; return }
        busy = true; progressTitle = "Loading buckets…"
        discoveryMessage = nil
        operation = Task { @MainActor in
            do {
                let discovered = try await discovery.buckets(project: project, authorization: authorization)
                guard requestID == request, !Task.isCancelled else { return }
                buckets = discovered; busy = false
                if discovered.isEmpty && authenticationMode == .serviceAccount { directEntry = true }
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                discoveryMessage = error.localizedDescription; busy = false
                if authenticationMode == .serviceAccount { directEntry = true }
            }
        }
    }

    private func save() {
        guard canSave, let authorization else { return }
        let remoteName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedReadOnly = readOnly
        let selectedAutoMount = autoMount
        let billing = billingProject.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil; busy = true; progressTitle = "Validating connection…"
        let selectedProject = project
        let selectedBucket = bucket
        let manualBucket = directEntry ? directBucketName.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let request = UUID(); requestID = request
        operation = Task { @MainActor in
            do {
                let selection: GoogleCloudStorageSelection
                if let manualBucket {
                    selection = try await discovery.directSelection(bucket: manualBucket, billingProject: billing.isEmpty ? nil : billing, authorization: authorization)
                } else {
                    guard let project = selectedProject, let bucket = selectedBucket else { throw GoogleCloudStorageError.invalidSelection }
                    selection = try GoogleCloudStorageSelection(projectID: project.projectId, projectNumber: project.number, bucket: bucket.name, billingProject: billing.isEmpty ? nil : billing)
                }
                try await discovery.validate(selection: selection, authorization: authorization, readOnly: selectedReadOnly)
                let currentAuthorization = try await discovery.refreshedAuthorization(authorization)
                let credential = try currentAuthorization.credential(selection: selection, remoteName: remoteName)
                let account = "credential.\(UUID().uuidString.lowercased())"
                let remote = RemoteConfig(name: remoteName, provider: .googleCloudStorage, bucketOrRootPath: selection.bucket, keychainAccountKey: account, googleCloudStorage: selection, googleCloudAuthentication: authorization.identity, autoMountAtLaunch: selectedAutoMount, isReadOnly: selectedReadOnly)
                let connection = try FileProviderConnectionDescriptor(remote: remote)
                let client = try await supervisor.startDaemon()
                let backend = try GoogleCloudStorageFileProviderBackend(connection: connection, client: client, credential: credential)
                _ = try await backend.listChildren()
                guard requestID == request, !Task.isCancelled else { return }
                try await keychain.saveCredential(credential, account: account)
                if requestID != request || Task.isCancelled {
                    try await keychain.deleteCredential(account: account)
                    return
                }
                busy = false
                onSave(remote)
            } catch {
                guard requestID == request, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription; busy = false
            }
        }
    }
}
