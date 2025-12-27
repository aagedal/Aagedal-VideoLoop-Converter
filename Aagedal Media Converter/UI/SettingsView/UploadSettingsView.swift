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

    // FTP Settings
    @AppStorage(AppConstants.uploadServerKey) private var server = ""
    @AppStorage(AppConstants.uploadPortKey) private var port = AppConstants.defaultUploadPort
    @AppStorage(AppConstants.uploadUsernameKey) private var username = ""
    @AppStorage(AppConstants.uploadRemotePathKey) private var remotePath = "/"
    @AppStorage(AppConstants.uploadUseFTPSKey) private var useFTPS = false
    @AppStorage(AppConstants.uploadDefaultEnabledKey) private var uploadDefaultEnabled = false
    @AppStorage(AppConstants.uploadRetryCountKey) private var retryCount = AppConstants.defaultUploadRetryCount

    @State private var password = ""
    @State private var hasStoredPassword = false

    // Focus state for Tab navigation
    private enum Field: Hashable {
        case server, port, username, password, remotePath
    }
    @FocusState private var focusedField: Field?

    private enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            rcloneStatusSection
            ftpServerSection
            uploadBehaviorSection
            testConnectionSection
        }
        .formStyle(.grouped)
        .task {
            await loadInitialState()
        }
    }

    // MARK: - Sections

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
                            Task {
                                await downloadRclone()
                            }
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

                Text("rclone is used for uploading files to FTP servers after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    private var ftpServerSection: some View {
        Section(header: Text("FTP Server")) {
            VStack(alignment: .leading, spacing: 12) {
                // Server hostname
                HStack {
                    Text("Server:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("ftp.example.com", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .server)
                        .onSubmit { focusedField = .port }
                }

                // Port
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("21", value: $port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .username }
                    Spacer()
                }

                // Username
                HStack {
                    Text("Username:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                }

                // Password
                HStack {
                    Text("Password:")
                        .frame(width: 80, alignment: .trailing)
                    SecureField(hasStoredPassword ? "••••••••" : "password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .password)
                        .onSubmit { focusedField = .remotePath }
                        .onChange(of: password) { _, newValue in
                            if !newValue.isEmpty {
                                savePassword()
                            }
                        }
                    if hasStoredPassword {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("Password saved in Keychain")
                    }
                }

                // Remote path
                HStack {
                    Text("Path:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("/uploads/videos", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .remotePath)
                        .onSubmit { focusedField = nil }
                }

                // FTPS toggle
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .trailing)
                    Toggle("Use FTPS (TLS encryption)", isOn: $useFTPS)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(8)
        }
    }

    private var uploadBehaviorSection: some View {
        Section(header: Text("Upload Behavior")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable upload by default for new items", isOn: $uploadDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new items added to the queue will automatically upload after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("Retry attempts:")
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

    private var testConnectionSection: some View {
        Section(header: Text("Test Connection")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Test Connection") {
                        Task {
                            await testConnection()
                        }
                    }
                    .disabled(isTesting || server.isEmpty || username.isEmpty || !hasStoredPassword)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    Spacer()

                    if let result = testResult {
                        switch result {
                        case .success:
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connection successful")
                                    .foregroundColor(.green)
                            }
                        case .failure(let error):
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .foregroundColor(.red)
                                    .lineLimit(2)
                            }
                        }
                    }
                }

                if server.isEmpty || username.isEmpty || !hasStoredPassword {
                    Text("Enter server, username, and password to test the connection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func loadInitialState() async {
        rcloneStatus = await RcloneUpdateService.shared.getInstallationStatus()
        rcloneVersion = await RcloneUpdateService.shared.getCurrentVersion()

        // Check if password exists in Keychain
        if !server.isEmpty && !username.isEmpty {
            hasStoredPassword = KeychainCredentialManager.shared.hasCredential(
                server: server,
                username: username
            )
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
            rcloneStatus = await RcloneUpdateService.shared.getInstallationStatus()
            rcloneVersion = await RcloneUpdateService.shared.getCurrentVersion()
        } catch {
            downloadError = error.localizedDescription
        }

        isDownloading = false
    }

    private func savePassword() {
        guard !server.isEmpty, !username.isEmpty, !password.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveCredential(
                server: server,
                username: username,
                password: password
            )
            hasStoredPassword = true
            password = "" // Clear after saving
        } catch {
            // Handle error silently - password field will show user hasn't saved
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
        .frame(width: 600, height: 500)
}
