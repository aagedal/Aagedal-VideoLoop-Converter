// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct UploadSettingsView: View {
    // MARK: - State

    @State private var rcloneStatus: RcloneInstallationStatus = .notInstalled
    @State private var rcloneVersion: String?
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0.0
    @State private var downloadError: String?

    @State private var isTesting = false
    @State private var testResult: TestResult?

    // Profiles
    @State private var profiles: [UploadProfile] = UploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadSelectedProfileIDKey) private var selectedProfileID = ""

    // Upload behavior
    @AppStorage(AppConstants.uploadDefaultEnabledKey) private var uploadDefaultEnabled = false
    @AppStorage(AppConstants.uploadRetryCountKey) private var retryCount = AppConstants.defaultUploadRetryCount

    // Transient credential entry state. Actual credentials live in the Keychain,
    // keyed by (server, username) for FTP/SFTP/SMB and by access-key for S3.
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var s3SecretKey = ""
    @State private var hasStoredS3SecretKey = false

    private enum Field: Hashable {
        case name, server, port, username, password, remotePath
        case sftpKeyFile
        case smbShare, smbDomain
        case s3Bucket, s3Region, s3Endpoint, s3AccessKey, s3SecretKey
    }
    @FocusState private var focusedField: Field?

    private enum TestResult {
        case success
        case failure(String)
    }

    // MARK: - Derived

    private var selectedProfileIndex: Int? {
        profiles.firstIndex { $0.id.uuidString == selectedProfileID }
    }

    private var selectedProfile: UploadProfile? {
        guard let index = selectedProfileIndex else { return nil }
        return profiles[index]
    }

    private var availableBackends: [UploadBackendType] {
        UploadBackendType.allCases.filter { $0.isImplemented }
    }

    var body: some View {
        Form {
            rcloneStatusSection
            profileSection
            uploadBehaviorSection
            testConnectionSection
        }
        .formStyle(.grouped)
        .task { await loadInitialState() }
        .onChange(of: selectedProfileID) { _, _ in
            refreshCredentialState()
            UploadManager.shared.refreshConfiguredStatus()
            testResult = nil
        }
    }

    // MARK: - rclone status

    private var rcloneStatusSection: some View {
        Section(header: Text("rclone Status")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: rcloneStatus.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(rcloneStatus.isAvailable ? .green : .red)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(rcloneStatus.displayText)
                            .font(.body)
                        if let version = rcloneVersion {
                            Text(version)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    if isDownloading {
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 100)
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Button(rcloneStatus.isAvailable ? "Update" : "Download") {
                            Task { await downloadRclone() }
                        }
                        .disabled(isDownloading)
                    }
                }

                if let error = downloadError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Text("rclone is used for uploading files to remote servers after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Profile

    @ViewBuilder
    private var profileSection: some View {
        Section(header: Text("Upload Profile")) {
            VStack(alignment: .leading, spacing: 10) {
                profilePicker

                if selectedProfile != nil {
                    Divider().padding(.vertical, 4)

                    LabeledContent("Name") {
                        TextField("Profile name", text: binding(\.name, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .name)
                    }

                    LabeledContent("Protocol") {
                        HStack {
                            Picker("Protocol", selection: backendBinding) {
                                ForEach(availableBackends, id: \.self) { backend in
                                    Text(backend.displayName).tag(backend)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            Spacer()
                        }
                    }

                    Divider().padding(.vertical, 4)

                    backendSpecificFields
                } else {
                    Text("No upload profiles yet. Click + to create one.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
            }
            .padding(8)
        }
    }

    private var profilePicker: some View {
        LabeledContent("Profile") {
            HStack {
                Picker("", selection: $selectedProfileID) {
                    if profiles.isEmpty {
                        Text("No profiles").tag("")
                    } else {
                        ForEach(profiles) { profile in
                            Text(profile.displayLabel).tag(profile.id.uuidString)
                        }
                    }
                }
                .labelsHidden()
                .disabled(profiles.isEmpty)

                Menu {
                    ForEach(availableBackends, id: \.self) { backend in
                        Button("New \(backend.displayName) Profile") {
                            addProfile(backend: backend)
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add profile")

                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(selectedProfile == nil)
                .help("Delete profile")
            }
        }
    }

    @ViewBuilder
    private var backendSpecificFields: some View {
        switch selectedProfile?.backend ?? .ftp {
        case .ftp:    ftpFields
        case .sftp:   sftpFields
        case .smb:    smbFields
        case .s3:     s3Fields
        case .gdrive: gdrivePlaceholder
        }
    }

    private var ftpFields: some View {
        Group {
            serverPortUserRow
            passwordField
            remotePathRow

            Toggle("Use FTPS (TLS encryption)", isOn: binding(\.useFTPS, default: false))
                .toggleStyle(SwitchToggleStyle())
        }
    }

    private var sftpFields: some View {
        Group {
            serverPortUserRow

            LabeledContent("Auth") {
                HStack {
                    Picker("", selection: binding(\.useKeyAuth, default: false)) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    Spacer()
                }
            }

            if selectedProfile?.useKeyAuth == true {
                LabeledContent("Key File") {
                    HStack {
                        TextField("", text: binding(\.keyFilePath, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .sftpKeyFile)
                        Button("Browse...") { selectSSHKeyFile() }
                    }
                }
            } else {
                passwordField
            }

            remotePathRow
        }
    }

    private var smbFields: some View {
        Group {
            serverPortUserRow

            LabeledContent("Share") {
                TextField("", text: binding(\.smbShare, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .smbShare)
            }

            LabeledContent("Domain") {
                TextField("", text: binding(\.smbDomain, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .smbDomain)
            }

            passwordField
            remotePathRow
        }
    }

    private var s3Fields: some View {
        Group {
            LabeledContent("Bucket") {
                TextField("", text: binding(\.bucket, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3Bucket)
            }

            LabeledContent("Region") {
                HStack {
                    Picker("", selection: binding(\.region, default: "us-east-1")) {
                        Text("us-east-1 (N. Virginia)").tag("us-east-1")
                        Text("us-east-2 (Ohio)").tag("us-east-2")
                        Text("us-west-1 (N. California)").tag("us-west-1")
                        Text("us-west-2 (Oregon)").tag("us-west-2")
                        Text("eu-west-1 (Ireland)").tag("eu-west-1")
                        Text("eu-west-2 (London)").tag("eu-west-2")
                        Text("eu-central-1 (Frankfurt)").tag("eu-central-1")
                        Text("eu-north-1 (Stockholm)").tag("eu-north-1")
                        Text("ap-northeast-1 (Tokyo)").tag("ap-northeast-1")
                        Text("ap-southeast-1 (Singapore)").tag("ap-southeast-1")
                        Text("ap-southeast-2 (Sydney)").tag("ap-southeast-2")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 240)
                    Spacer()
                }
            }

            LabeledContent("Endpoint") {
                TextField("Leave empty for AWS (or enter custom endpoint)", text: binding(\.endpoint, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3Endpoint)
            }

            Divider()

            LabeledContent("Access Key") {
                TextField("", text: binding(\.accessKeyID, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .s3AccessKey)
                    .onSubmit { focusedField = .s3SecretKey }
            }

            LabeledContent("Secret Key") {
                HStack {
                    SecureField(hasStoredS3SecretKey ? "••••••••" : "Secret Access Key", text: $s3SecretKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3SecretKey)
                        .onChange(of: s3SecretKey) { _, newValue in
                            if !newValue.isEmpty { saveS3SecretKey() }
                        }
                    if hasStoredS3SecretKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("Secret key saved in Keychain")
                    }
                }
            }

            Divider()

            LabeledContent("Path/Prefix") {
                TextField("", text: binding(\.remotePath, default: "/"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .remotePath)
            }

            let bucket = selectedProfile?.bucket ?? ""
            let path = selectedProfile?.remotePath ?? ""
            Text("Files will be uploaded to: s3://\(bucket.isEmpty ? "bucket" : bucket)/\(path.isEmpty ? "" : path + "/")<filename>")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var gdrivePlaceholder: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text("Google Drive support is not yet implemented.")
                .foregroundColor(.secondary)
            Text("Please use FTP, SFTP, SMB, or S3 for now.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: - Shared rows

    private var serverPortUserRow: some View {
        Group {
            LabeledContent("Server") {
                TextField("", text: binding(\.server, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .server)
                    .onSubmit { focusedField = .port }
            }

            LabeledContent("Port") {
                HStack {
                    TextField("", value: binding(\.port, default: AppConstants.defaultUploadPort), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .username }
                    Spacer()
                }
            }

            LabeledContent("Username") {
                TextField("", text: binding(\.username, default: ""))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
            }
        }
    }

    private var remotePathRow: some View {
        LabeledContent("Path") {
            TextField("", text: binding(\.remotePath, default: "/"))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .remotePath)
                .onSubmit { focusedField = nil }
        }
    }

    private var passwordField: some View {
        LabeledContent("Password") {
            HStack {
                SecureField(hasStoredPassword ? "••••••••" : "password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .onSubmit { focusedField = .remotePath }
                    .onChange(of: password) { _, newValue in
                        if !newValue.isEmpty { savePassword() }
                    }
                if hasStoredPassword {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .help("Password saved in Keychain")
                }
            }
        }
    }

    // MARK: - Upload behavior

    private var uploadBehaviorSection: some View {
        Section(header: Text("Upload Behavior")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable upload by default for new items", isOn: $uploadDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new items added to the queue will automatically upload after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                LabeledContent("Retry attempts") {
                    Stepper("\(retryCount)", value: $retryCount, in: 0...5)
                        .frame(width: 120)
                }

                Text("Number of times to retry a failed upload before giving up.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - Test connection

    private var testConnectionSection: some View {
        Section(header: Text("Test Connection")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting || !isConfigurationComplete)

                    if isTesting {
                        ProgressView().scaleEffect(0.7)
                    }

                    Spacer()

                    if let result = testResult {
                        switch result {
                        case .success:
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                Text("Connection successful").foregroundColor(.green)
                            }
                        case .failure(let error):
                            HStack {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                Text(error).foregroundColor(.red).lineLimit(2)
                            }
                        }
                    }
                }

                if !isConfigurationComplete, let hint = configurationHint {
                    Text(hint).font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var isConfigurationComplete: Bool {
        guard let profile = selectedProfile else { return false }
        switch profile.backend {
        case .ftp:
            return !profile.server.isEmpty && !profile.username.isEmpty && hasStoredPassword
        case .sftp:
            if profile.useKeyAuth {
                return !profile.server.isEmpty && !profile.username.isEmpty && !profile.keyFilePath.isEmpty
            }
            return !profile.server.isEmpty && !profile.username.isEmpty && hasStoredPassword
        case .smb:
            return !profile.server.isEmpty && !profile.username.isEmpty && !profile.smbShare.isEmpty && hasStoredPassword
        case .s3:
            return !profile.bucket.isEmpty && !profile.accessKeyID.isEmpty && hasStoredS3SecretKey
        case .gdrive:
            return false
        }
    }

    private var configurationHint: String? {
        guard let profile = selectedProfile else {
            return "Create a profile to configure uploads."
        }
        switch profile.backend {
        case .ftp:
            return "Enter server, username, and password to test the connection."
        case .sftp:
            return profile.useKeyAuth
                ? "Enter server, username, and select an SSH key file to test."
                : "Enter server, username, and password to test the connection."
        case .smb:
            return "Enter server, share name, username, and password to test."
        case .s3:
            return "Enter bucket name, access key, and secret key to test."
        case .gdrive:
            return "Google Drive is not yet implemented."
        }
    }

    // MARK: - Bindings

    /// Generic writable-keypath binding into the currently selected profile.
    /// Writes through to the profile store on every mutation.
    private func binding<Value>(_ keyPath: WritableKeyPath<UploadProfile, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: {
                guard let index = selectedProfileIndex else { return defaultValue }
                return profiles[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = selectedProfileIndex else { return }
                profiles[index][keyPath: keyPath] = newValue
                UploadProfileStore.saveProfiles(profiles)
                // Credentials are keyed by (server, username) / access key — refresh when those change.
                if keyPath == \UploadProfile.server || keyPath == \UploadProfile.username || keyPath == \UploadProfile.accessKeyID {
                    refreshCredentialState()
                }
                UploadManager.shared.refreshConfiguredStatus()
            }
        )
    }

    private var backendBinding: Binding<UploadBackendType> {
        Binding(
            get: { selectedProfile?.backend ?? .ftp },
            set: { newBackend in
                guard let index = selectedProfileIndex,
                      profiles[index].backend != newBackend else { return }
                changeBackend(of: index, to: newBackend)
            }
        )
    }

    // MARK: - Actions

    private func loadInitialState() async {
        rcloneStatus = RcloneUpdateService.shared.getInstallationStatus()
        rcloneVersion = await RcloneUpdateService.shared.getCurrentVersion()

        if profiles.isEmpty {
            // First-run: create a default FTP profile so the view always has something to show.
            let profile = UploadProfile.new(backend: .ftp)
            profiles = [profile]
            UploadProfileStore.saveProfiles(profiles)
            selectedProfileID = profile.id.uuidString
        } else if selectedProfileIndex == nil {
            selectedProfileID = profiles[0].id.uuidString
        }

        refreshCredentialState()
    }

    private func addProfile(backend: UploadBackendType) {
        var profile = UploadProfile.new(backend: backend)
        profile.name = uniqueProfileName(from: profile.name)
        profiles.append(profile)
        UploadProfileStore.saveProfiles(profiles)
        selectedProfileID = profile.id.uuidString
        refreshCredentialState()
    }

    private func deleteSelectedProfile() {
        guard let index = selectedProfileIndex else { return }
        profiles.remove(at: index)
        UploadProfileStore.saveProfiles(profiles)
        if let next = profiles.first {
            selectedProfileID = next.id.uuidString
        } else {
            selectedProfileID = ""
        }
        refreshCredentialState()
    }

    /// Changes the backend of a profile, keeping shared fields (server/username/remotePath)
    /// and resetting the fields that belong to the previous backend.
    private func changeBackend(of index: Int, to newBackend: UploadBackendType) {
        profiles[index].backend = newBackend
        profiles[index].port = newBackend.defaultPort > 0 ? newBackend.defaultPort : AppConstants.defaultUploadPort
        profiles[index].useFTPS = false
        profiles[index].useKeyAuth = false
        profiles[index].keyFilePath = ""
        profiles[index].smbShare = ""
        profiles[index].smbDomain = ""
        profiles[index].bucket = ""
        profiles[index].region = "us-east-1"
        profiles[index].endpoint = ""
        profiles[index].accessKeyID = ""
        UploadProfileStore.saveProfiles(profiles)
        refreshCredentialState()
        testResult = nil
    }

    private func uniqueProfileName(from baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "Upload Profile" : trimmed
        let existing = Set(profiles.map { $0.name })
        if !existing.contains(seed) { return seed }
        var index = 2
        var candidate = "\(seed) \(index)"
        while existing.contains(candidate) {
            index += 1
            candidate = "\(seed) \(index)"
        }
        return candidate
    }

    private func refreshCredentialState() {
        password = ""
        s3SecretKey = ""

        guard let profile = selectedProfile else {
            hasStoredPassword = false
            hasStoredS3SecretKey = false
            return
        }

        switch profile.backend {
        case .ftp, .sftp, .smb:
            if !profile.server.isEmpty, !profile.username.isEmpty {
                hasStoredPassword = KeychainCredentialManager.shared.hasCredential(
                    server: profile.server,
                    username: profile.username
                )
            } else {
                hasStoredPassword = false
            }
            hasStoredS3SecretKey = false
        case .s3:
            hasStoredPassword = false
            hasStoredS3SecretKey = !profile.accessKeyID.isEmpty
                && KeychainCredentialManager.shared.hasS3SecretKey(accessKeyID: profile.accessKeyID)
        case .gdrive:
            hasStoredPassword = false
            hasStoredS3SecretKey = false
        }
    }

    private func downloadRclone() async {
        isDownloading = true
        downloadProgress = 0.0
        downloadError = nil

        do {
            try await RcloneUpdateService.shared.downloadUpdate { progress in
                Task { @MainActor in
                    self.downloadProgress = progress
                }
            }
            rcloneStatus = RcloneUpdateService.shared.getInstallationStatus()
            rcloneVersion = await RcloneUpdateService.shared.getCurrentVersion()
        } catch {
            downloadError = error.localizedDescription
        }

        isDownloading = false
    }

    private func savePassword() {
        guard let profile = selectedProfile,
              !profile.server.isEmpty,
              !profile.username.isEmpty,
              !password.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveCredential(
                server: profile.server,
                username: profile.username,
                password: password
            )
            hasStoredPassword = true
            password = ""
        } catch {
            // Surfaced to the user implicitly by hasStoredPassword staying false.
        }
    }

    private func saveS3SecretKey() {
        guard let profile = selectedProfile,
              !profile.accessKeyID.isEmpty,
              !s3SecretKey.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveS3SecretKey(
                accessKeyID: profile.accessKeyID,
                secretKey: s3SecretKey
            )
            hasStoredS3SecretKey = true
            s3SecretKey = ""
        } catch {
            // Surfaced to the user implicitly.
        }
    }

    private func selectSSHKeyFile() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true

        if panel.runModal() == .OK, let url = panel.url {
            guard let index = selectedProfileIndex else { return }
            profiles[index].keyFilePath = url.path
            UploadProfileStore.saveProfiles(profiles)
        }
    }

    private func testConnection() async {
        isTesting = true
        testResult = nil

        do {
            let success = try await UploadManager.shared.testConnection()
            testResult = success ? .success : .failure("Connection test failed")
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }
}

#Preview {
    UploadSettingsView()
        .frame(width: 600, height: 700)
}
