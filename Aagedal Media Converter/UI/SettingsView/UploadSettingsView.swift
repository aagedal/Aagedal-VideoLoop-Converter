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

    // Backend selection
    @AppStorage(AppConstants.uploadBackendTypeKey) private var selectedBackend = "ftp"
    @State private var ftpProfiles: [FTPUploadProfile] = FTPUploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadFTPSelectedProfileIDKey) private var selectedFTPProfileID = ""
    @State private var sftpProfiles: [SFTPUploadProfile] = SFTPUploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadSFTPSelectedProfileIDKey) private var selectedSFTPProfileID = ""
    @State private var smbProfiles: [SMBUploadProfile] = SMBUploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadSMBSelectedProfileIDKey) private var selectedSMBProfileID = ""
    @State private var s3Profiles: [S3UploadProfile] = S3UploadProfileStore.loadProfiles()
    @AppStorage(AppConstants.uploadS3SelectedProfileIDKey) private var selectedS3ProfileID = ""

    // Common Settings
    @AppStorage(AppConstants.uploadServerKey) private var server = ""
    @AppStorage(AppConstants.uploadPortKey) private var port = AppConstants.defaultUploadPort
    @AppStorage(AppConstants.uploadUsernameKey) private var username = ""
    @AppStorage(AppConstants.uploadRemotePathKey) private var remotePath = "/"
    @AppStorage(AppConstants.uploadUseFTPSKey) private var useFTPS = false
    @AppStorage(AppConstants.uploadDefaultEnabledKey) private var uploadDefaultEnabled = false
    @AppStorage(AppConstants.uploadRetryCountKey) private var retryCount = AppConstants.defaultUploadRetryCount

    // SFTP-specific
    @AppStorage(AppConstants.uploadSFTPKeyFileKey) private var sftpKeyFilePath = ""
    @State private var useSFTPKeyAuth = false

    // SMB-specific
    @AppStorage(AppConstants.uploadSMBShareKey) private var smbShare = ""
    @AppStorage(AppConstants.uploadSMBDomainKey) private var smbDomain = ""

    // S3-specific
    @AppStorage(AppConstants.uploadS3BucketKey) private var s3Bucket = ""
    @AppStorage(AppConstants.uploadS3RegionKey) private var s3Region = "us-east-1"
    @AppStorage(AppConstants.uploadS3EndpointKey) private var s3Endpoint = ""
    @AppStorage(AppConstants.uploadS3AccessKeyKey) private var s3AccessKeyID = ""

    // Password states
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var s3SecretKey = ""
    @State private var hasStoredS3SecretKey = false

    // Focus state for Tab navigation
    private enum Field: Hashable {
        case server, port, username, password, remotePath
        case smbShare, smbDomain
        case s3Bucket, s3Region, s3Endpoint, s3AccessKey, s3SecretKey
        case sftpKeyFile
    }
    @FocusState private var focusedField: Field?

    private enum TestResult {
        case success
        case failure(String)
    }

    private var currentBackendType: UploadBackendType {
        UploadBackendType(rawValue: selectedBackend) ?? .ftp
    }

    private var selectedFTPProfileIndex: Int? {
        ftpProfiles.firstIndex { $0.id.uuidString == selectedFTPProfileID }
    }

    private var selectedFTPProfile: FTPUploadProfile? {
        guard let index = selectedFTPProfileIndex else { return nil }
        return ftpProfiles[index]
    }

    private var selectedSFTPProfileIndex: Int? {
        sftpProfiles.firstIndex { $0.id.uuidString == selectedSFTPProfileID }
    }

    private var selectedSFTPProfile: SFTPUploadProfile? {
        guard let index = selectedSFTPProfileIndex else { return nil }
        return sftpProfiles[index]
    }

    private var selectedSMBProfileIndex: Int? {
        smbProfiles.firstIndex { $0.id.uuidString == selectedSMBProfileID }
    }

    private var selectedSMBProfile: SMBUploadProfile? {
        guard let index = selectedSMBProfileIndex else { return nil }
        return smbProfiles[index]
    }

    private var selectedS3ProfileIndex: Int? {
        s3Profiles.firstIndex { $0.id.uuidString == selectedS3ProfileID }
    }

    private var selectedS3Profile: S3UploadProfile? {
        guard let index = selectedS3ProfileIndex else { return nil }
        return s3Profiles[index]
    }

    var body: some View {
        formContent
            .formStyle(.grouped)
            .task {
                await loadInitialState()
            }
        .onChange(of: selectedBackend) { _, newValue in
            handleBackendChange(newValue)
        }
        .onChange(of: profileSelectionToken) { _, _ in
            switch currentBackendType {
            case .ftp:
                applySelectedFTPProfile()
            case .sftp:
                applySelectedSFTPProfile()
            case .smb:
                applySelectedSMBProfile()
            case .s3:
                applySelectedS3Profile()
            case .gdrive:
                break
            }
        }
        .onChange(of: profileFieldsToken) { _, _ in
            updateSelectedProfileFromFields()
            refreshPasswordState()
            refreshS3SecretState()
        }
    }

    private var formContent: some View {
        Form {
            rcloneStatusSection
            backendSelectorSection
            backendSettingsSection
            uploadBehaviorSection
            testConnectionSection
        }
    }

    @ViewBuilder
    private var backendSettingsSection: some View {
        switch currentBackendType {
        case .ftp:
            ftpServerSection
        case .sftp:
            sftpServerSection
        case .smb:
            smbServerSection
        case .s3:
            s3Section
        case .gdrive:
            gdriveSection
        }
    }

    private var profileSelectionToken: String {
        [
            currentBackendType.rawValue,
            selectedFTPProfileID,
            selectedSFTPProfileID,
            selectedSMBProfileID,
            selectedS3ProfileID
        ].joined(separator: "|")
    }

    private var profileFieldsToken: String {
        [
            server,
            "\(port)",
            username,
            remotePath,
            useFTPS ? "1" : "0",
            sftpKeyFilePath,
            useSFTPKeyAuth ? "1" : "0",
            smbShare,
            smbDomain,
            s3Bucket,
            s3Region,
            s3Endpoint,
            s3AccessKeyID
        ].joined(separator: "|")
    }

    // MARK: - Backend Selector

    private var backendSelectorSection: some View {
        Section(header: Text("Upload Backend")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Backend", selection: $selectedBackend) {
                    Text("FTP").tag("ftp")
                    Text("SFTP").tag("sftp")
                    Text("SMB").tag("smb")
                    Text("S3").tag("s3")
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(backendDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    private var backendDescription: String {
        switch currentBackendType {
        case .ftp:
            return "Upload to FTP servers with optional TLS encryption."
        case .sftp:
            return "Upload via SSH/SFTP with password or SSH key authentication."
        case .smb:
            return "Upload to Windows network shares (SMB/CIFS)."
        case .s3:
            return "Upload to Amazon S3 or S3-compatible storage services."
        case .gdrive:
            return "Upload to Google Drive (not yet implemented)."
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

                Text("rclone is used for uploading files to remote servers after conversion.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    private var ftpServerSection: some View {
        Section(header: Text("FTP Server")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Profile:")
                        .frame(width: 80, alignment: .trailing)
                    Picker("Profile", selection: $selectedFTPProfileID) {
                        if ftpProfiles.isEmpty {
                            Text("No profiles").tag("")
                        } else {
                            ForEach(ftpProfiles) { profile in
                                Text(profile.name.isEmpty ? "Untitled FTP" : profile.name)
                                    .tag(profile.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        addFTPProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add profile")
                    Button {
                        deleteSelectedFTPProfile()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(ftpProfiles.count <= 1)
                    .help("Delete profile")
                }

                HStack {
                    Text("Name:")
                        .frame(width: 80, alignment: .trailing)
                    TextField(
                        "FTP Profile",
                        text: Binding(
                            get: { selectedFTPProfile?.name ?? "" },
                            set: { updateSelectedFTPProfileName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Divider().padding(.vertical, 4)

                Text("Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Server hostname
                HStack {
                    Text("Server:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .server)
                        .onSubmit { focusedField = .port }
                }

                // Port
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", value: $port, format: .number)
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
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                }

                // Password
                passwordField

                // Remote path
                HStack {
                    Text("Path:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $remotePath)
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

    private var sftpServerSection: some View {
        Section(header: Text("SFTP Server")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Profile:")
                        .frame(width: 80, alignment: .trailing)
                    Picker("Profile", selection: $selectedSFTPProfileID) {
                        if sftpProfiles.isEmpty {
                            Text("No profiles").tag("")
                        } else {
                            ForEach(sftpProfiles) { profile in
                                Text(profile.name.isEmpty ? "Untitled SFTP" : profile.name)
                                    .tag(profile.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        addSFTPProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add profile")
                    Button {
                        deleteSelectedSFTPProfile()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(sftpProfiles.count <= 1)
                    .help("Delete profile")
                }

                HStack {
                    Text("Name:")
                        .frame(width: 80, alignment: .trailing)
                    TextField(
                        "SFTP Profile",
                        text: Binding(
                            get: { selectedSFTPProfile?.name ?? "" },
                            set: { updateSelectedSFTPProfileName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Divider().padding(.vertical, 4)

                Text("Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Server hostname
                HStack {
                    Text("Server:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .server)
                        .onSubmit { focusedField = .port }
                }

                // Port
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", value: $port, format: .number)
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
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = useSFTPKeyAuth ? .sftpKeyFile : .password }
                }

                // Auth method toggle
                HStack {
                    Text("Auth:")
                        .frame(width: 80, alignment: .trailing)
                    Picker("Authentication", selection: $useSFTPKeyAuth) {
                        Text("Password").tag(false)
                        Text("SSH Key").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    Spacer()
                }

                // Password or SSH key based on auth method
                if useSFTPKeyAuth {
                    // SSH Key file picker
                    HStack {
                        Text("Key File:")
                            .frame(width: 80, alignment: .trailing)
                        TextField("", text: $sftpKeyFilePath)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .sftpKeyFile)
                        Button("Browse...") {
                            selectSSHKeyFile()
                        }
                    }
                } else {
                    // Password
                    passwordField
                }

                // Remote path
                HStack {
                    Text("Path:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .remotePath)
                        .onSubmit { focusedField = nil }
                }
            }
            .padding(8)
        }
    }

    private var smbServerSection: some View {
        Section(header: Text("SMB Server (Windows Share)")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Profile:")
                        .frame(width: 80, alignment: .trailing)
                    Picker("Profile", selection: $selectedSMBProfileID) {
                        if smbProfiles.isEmpty {
                            Text("No profiles").tag("")
                        } else {
                            ForEach(smbProfiles) { profile in
                                Text(profile.name.isEmpty ? "Untitled SMB" : profile.name)
                                    .tag(profile.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        addSMBProfile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add profile")
                    Button {
                        deleteSelectedSMBProfile()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(smbProfiles.count <= 1)
                    .help("Delete profile")
                }

                HStack {
                    Text("Name:")
                        .frame(width: 80, alignment: .trailing)
                    TextField(
                        "SMB Profile",
                        text: Binding(
                            get: { selectedSMBProfile?.name ?? "" },
                            set: { updateSelectedSMBProfileName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Divider().padding(.vertical, 4)

                Text("Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Server hostname
                HStack {
                    Text("Server:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .server)
                        .onSubmit { focusedField = .port }
                }

                // Port
                HStack {
                    Text("Port:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", value: $port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .focused($focusedField, equals: .port)
                        .onSubmit { focusedField = .smbShare }
                    Spacer()
                }

                // Share name
                HStack {
                    Text("Share:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $smbShare)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .smbShare)
                        .onSubmit { focusedField = .username }
                }

                // Domain (optional)
                HStack {
                    Text("Domain:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $smbDomain)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .smbDomain)
                        .onSubmit { focusedField = .username }
                }

                // Username
                HStack {
                    Text("Username:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .username)
                        .onSubmit { focusedField = .password }
                }

                // Password
                passwordField

                // Remote path (within share)
                HStack {
                    Text("Path:")
                        .frame(width: 80, alignment: .trailing)
                    TextField("", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .remotePath)
                        .onSubmit { focusedField = nil }
                }
            }
            .padding(8)
        }
    }

    private var s3Section: some View {
        Section(header: Text("Amazon S3 / S3-Compatible Storage")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Profile")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Text("Profile:")
                        .frame(width: 100, alignment: .trailing)
                    Picker("Profile", selection: $selectedS3ProfileID) {
                        if s3Profiles.isEmpty {
                            Text("No profiles").tag("")
                        } else {
                            ForEach(s3Profiles) { profile in
                                Text(profile.name.isEmpty ? "Untitled S3" : profile.name)
                                    .tag(profile.id.uuidString)
                            }
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button {
                        addS3Profile()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add profile")
                    Button {
                        deleteSelectedS3Profile()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(s3Profiles.count <= 1)
                    .help("Delete profile")
                }

                HStack {
                    Text("Name:")
                        .frame(width: 100, alignment: .trailing)
                    TextField(
                        "S3 Profile",
                        text: Binding(
                            get: { selectedS3Profile?.name ?? "" },
                            set: { updateSelectedS3ProfileName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Divider().padding(.vertical, 4)

                Text("Settings")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Bucket name
                HStack {
                    Text("Bucket:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $s3Bucket)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3Bucket)
                        .onSubmit { focusedField = .s3Region }
                }

                // Region
                HStack {
                    Text("Region:")
                        .frame(width: 100, alignment: .trailing)
                    Picker("", selection: $s3Region) {
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
                    .frame(width: 200)
                    Spacer()
                }

                // Custom endpoint (optional, for S3-compatible)
                HStack {
                    Text("Endpoint:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("Leave empty for AWS (or enter custom endpoint)", text: $s3Endpoint)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3Endpoint)
                }

                Divider()

                // Access Key ID
                HStack {
                    Text("Access Key:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $s3AccessKeyID)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3AccessKey)
                        .onSubmit { focusedField = .s3SecretKey }
                }

                // Secret Access Key
                HStack {
                    Text("Secret Key:")
                        .frame(width: 100, alignment: .trailing)
                    SecureField(hasStoredS3SecretKey ? "••••••••" : "Secret Access Key", text: $s3SecretKey)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .s3SecretKey)
                        .onChange(of: s3SecretKey) { _, newValue in
                            if !newValue.isEmpty {
                                saveS3SecretKey()
                            }
                        }
                    if hasStoredS3SecretKey {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .help("Secret key saved in Keychain")
                    }
                }

                Divider()

                // Remote path (prefix/folder in bucket)
                HStack {
                    Text("Path/Prefix:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .remotePath)
                }

                Text("Files will be uploaded to: s3://\(s3Bucket.isEmpty ? "bucket" : s3Bucket)/\(remotePath.isEmpty ? "" : remotePath + "/")<filename>")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    private var gdriveSection: some View {
        Section(header: Text("Google Drive")) {
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
    }

    private var passwordField: some View {
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
                    .disabled(isTesting || !isConfigurationComplete)

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

                if !isConfigurationComplete {
                    Text(configurationHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var isConfigurationComplete: Bool {
        switch currentBackendType {
        case .ftp, .sftp:
            if currentBackendType == .sftp && useSFTPKeyAuth {
                return !server.isEmpty && !username.isEmpty && !sftpKeyFilePath.isEmpty
            }
            return !server.isEmpty && !username.isEmpty && hasStoredPassword
        case .smb:
            return !server.isEmpty && !username.isEmpty && !smbShare.isEmpty && hasStoredPassword
        case .s3:
            return !s3Bucket.isEmpty && !s3AccessKeyID.isEmpty && hasStoredS3SecretKey
        case .gdrive:
            return false
        }
    }

    private var configurationHint: String {
        switch currentBackendType {
        case .ftp:
            return "Enter server, username, and password to test the connection."
        case .sftp:
            if useSFTPKeyAuth {
                return "Enter server, username, and select an SSH key file to test."
            }
            return "Enter server, username, and password to test the connection."
        case .smb:
            return "Enter server, share name, username, and password to test."
        case .s3:
            return "Enter bucket name, access key, and secret key to test."
        case .gdrive:
            return "Google Drive is not yet implemented."
        }
    }

    // MARK: - Actions

    private func loadInitialState() async {
        rcloneStatus = RcloneUpdateService.shared.getInstallationStatus()
        rcloneVersion = await RcloneUpdateService.shared.getCurrentVersion()

        // Profiles are loaded eagerly via @State initializers.
        // Just ensure selection and backend state are consistent.
        ensureSelectedFTPProfile()
        ensureSelectedSFTPProfile()
        ensureSelectedSMBProfile()
        ensureSelectedS3Profile()

        switch currentBackendType {
        case .ftp:
            ensureFTPProfilesForFTPBackend(seedFromCurrent: true)
            applySelectedFTPProfile()
        case .sftp:
            ensureSFTPProfilesForBackend(seedFromCurrent: true)
            applySelectedSFTPProfile()
        case .smb:
            ensureSMBProfilesForBackend(seedFromCurrent: true)
            applySelectedSMBProfile()
        case .s3:
            ensureS3ProfilesForBackend(seedFromCurrent: true)
            applySelectedS3Profile()
        case .gdrive:
            refreshPasswordState()
        }

        refreshS3SecretState()
    }

    private func handleBackendChange(_ newValue: String) {
        guard let backend = UploadBackendType(rawValue: newValue) else { return }

        switch backend {
        case .ftp:
            let shouldSeed = !(server.isEmpty && username.isEmpty)
            ensureFTPProfilesForFTPBackend(seedFromCurrent: shouldSeed)
            applySelectedFTPProfile()
        case .sftp:
            let shouldSeed = !(server.isEmpty && username.isEmpty)
            ensureSFTPProfilesForBackend(seedFromCurrent: shouldSeed)
            applySelectedSFTPProfile()
        case .smb:
            let shouldSeed = !(server.isEmpty && username.isEmpty)
            ensureSMBProfilesForBackend(seedFromCurrent: shouldSeed)
            applySelectedSMBProfile()
        case .s3:
            let shouldSeed = !s3Bucket.isEmpty || !s3AccessKeyID.isEmpty
            ensureS3ProfilesForBackend(seedFromCurrent: shouldSeed)
            applySelectedS3Profile()
        case .gdrive:
            port = backend.defaultPort
        }

        testResult = nil
    }

    private func updateSelectedProfileFromFields() {
        switch currentBackendType {
        case .ftp:
            updateSelectedFTPProfileFromFields()
        case .sftp:
            updateSelectedSFTPProfileFromFields()
        case .smb:
            updateSelectedSMBProfileFromFields()
        case .s3:
            updateSelectedS3ProfileFromFields()
        case .gdrive:
            break
        }
    }

    private func refreshS3SecretState() {
        guard !s3AccessKeyID.isEmpty else {
            hasStoredS3SecretKey = false
            return
        }
        hasStoredS3SecretKey = KeychainCredentialManager.shared.hasS3SecretKey(accessKeyID: s3AccessKeyID)
    }

    private func loadFTPProfiles() {
        ftpProfiles = FTPUploadProfileStore.loadProfiles()
        ensureSelectedFTPProfile()
    }

    private func loadSFTPProfiles() {
        sftpProfiles = SFTPUploadProfileStore.loadProfiles()
        ensureSelectedSFTPProfile()
    }

    private func loadSMBProfiles() {
        smbProfiles = SMBUploadProfileStore.loadProfiles()
        ensureSelectedSMBProfile()
    }

    private func loadS3Profiles() {
        s3Profiles = S3UploadProfileStore.loadProfiles()
        ensureSelectedS3Profile()
    }

    private func ensureSelectedFTPProfile() {
        guard !ftpProfiles.isEmpty else { return }
        if selectedFTPProfileIndex == nil {
            selectedFTPProfileID = ftpProfiles[0].id.uuidString
        }
    }

    private func ensureFTPProfilesForFTPBackend(seedFromCurrent: Bool) {
        guard ftpProfiles.isEmpty else {
            ensureSelectedFTPProfile()
            return
        }

        let profileName = seedFromCurrent ? defaultFTPProfileName() : "New FTP Profile"
        let profile = FTPUploadProfile(
            name: profileName,
            server: seedFromCurrent ? server : "",
            port: seedFromCurrent ? resolvedFTPPort() : AppConstants.defaultUploadPort,
            username: seedFromCurrent ? username : "",
            remotePath: seedFromCurrent ? remotePath : "/",
            useFTPS: seedFromCurrent ? useFTPS : false
        )
        ftpProfiles = [profile]
        FTPUploadProfileStore.saveProfiles(ftpProfiles)
        selectedFTPProfileID = profile.id.uuidString
    }

    private func defaultFTPProfileName() -> String {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedServer.isEmpty ? "Default FTP" : trimmedServer
    }

    private func resolvedFTPPort() -> Int {
        port > 0 ? port : AppConstants.defaultUploadPort
    }

    private func applySelectedFTPProfile() {
        guard let profile = selectedFTPProfile else { return }
        server = profile.server
        port = profile.port > 0 ? profile.port : AppConstants.defaultUploadPort
        username = profile.username
        remotePath = profile.remotePath
        useFTPS = profile.useFTPS
        password = ""
        refreshPasswordState()
    }

    private func updateSelectedFTPProfileFromFields() {
        guard currentBackendType == .ftp,
              let index = selectedFTPProfileIndex else { return }
        ftpProfiles[index].server = server
        ftpProfiles[index].port = resolvedFTPPort()
        ftpProfiles[index].username = username
        ftpProfiles[index].remotePath = remotePath
        ftpProfiles[index].useFTPS = useFTPS
        FTPUploadProfileStore.saveProfiles(ftpProfiles)
    }

    private func updateSelectedFTPProfileName(_ newValue: String) {
        guard let index = selectedFTPProfileIndex else { return }
        ftpProfiles[index].name = newValue
        FTPUploadProfileStore.saveProfiles(ftpProfiles)
    }

    private func addFTPProfile() {
        let baseName = server.isEmpty ? "New FTP Profile" : server
        let name = uniqueFTPProfileName(from: baseName)
        let profile = FTPUploadProfile(
            name: name,
            server: server,
            port: resolvedFTPPort(),
            username: username,
            remotePath: remotePath,
            useFTPS: useFTPS
        )
        ftpProfiles.append(profile)
        FTPUploadProfileStore.saveProfiles(ftpProfiles)
        selectedFTPProfileID = profile.id.uuidString
        applySelectedFTPProfile()
    }

    private func deleteSelectedFTPProfile() {
        guard let index = selectedFTPProfileIndex else { return }
        ftpProfiles.remove(at: index)
        if ftpProfiles.isEmpty {
            let profile = FTPUploadProfile(name: "New FTP Profile")
            ftpProfiles = [profile]
            selectedFTPProfileID = profile.id.uuidString
        } else {
            let nextIndex = min(index, ftpProfiles.count - 1)
            selectedFTPProfileID = ftpProfiles[nextIndex].id.uuidString
        }
        FTPUploadProfileStore.saveProfiles(ftpProfiles)
        if currentBackendType == .ftp {
            applySelectedFTPProfile()
        }
    }

    private func uniqueFTPProfileName(from baseName: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? "FTP Profile" : trimmed
        let existingNames = Set(ftpProfiles.map { $0.name })
        if !existingNames.contains(seed) {
            return seed
        }
        var index = 2
        var candidate = "\(seed) \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(seed) \(index)"
        }
        return candidate
    }

    private func ensureSelectedSFTPProfile() {
        guard !sftpProfiles.isEmpty else { return }
        if selectedSFTPProfileIndex == nil {
            selectedSFTPProfileID = sftpProfiles[0].id.uuidString
        }
    }

    private func ensureSelectedSMBProfile() {
        guard !smbProfiles.isEmpty else { return }
        if selectedSMBProfileIndex == nil {
            selectedSMBProfileID = smbProfiles[0].id.uuidString
        }
    }

    private func ensureSelectedS3Profile() {
        guard !s3Profiles.isEmpty else { return }
        if selectedS3ProfileIndex == nil {
            selectedS3ProfileID = s3Profiles[0].id.uuidString
        }
    }

    private func ensureSFTPProfilesForBackend(seedFromCurrent: Bool) {
        guard sftpProfiles.isEmpty else {
            ensureSelectedSFTPProfile()
            return
        }

        let profileName = seedFromCurrent ? defaultSFTPProfileName() : "New SFTP Profile"
        let profile = SFTPUploadProfile(
            name: profileName,
            server: seedFromCurrent ? server : "",
            port: seedFromCurrent ? resolvedSFTPPort() : AppConstants.defaultSFTPPort,
            username: seedFromCurrent ? username : "",
            remotePath: seedFromCurrent ? remotePath : "/",
            useKeyAuth: seedFromCurrent ? useSFTPKeyAuth : false,
            keyFilePath: seedFromCurrent ? sftpKeyFilePath : ""
        )
        sftpProfiles = [profile]
        SFTPUploadProfileStore.saveProfiles(sftpProfiles)
        selectedSFTPProfileID = profile.id.uuidString
    }

    private func ensureSMBProfilesForBackend(seedFromCurrent: Bool) {
        guard smbProfiles.isEmpty else {
            ensureSelectedSMBProfile()
            return
        }

        let profileName = seedFromCurrent ? defaultSMBProfileName() : "New SMB Profile"
        let profile = SMBUploadProfile(
            name: profileName,
            server: seedFromCurrent ? server : "",
            port: seedFromCurrent ? resolvedSMBPort() : AppConstants.defaultSMBPort,
            username: seedFromCurrent ? username : "",
            remotePath: seedFromCurrent ? remotePath : "/",
            smbShare: seedFromCurrent ? smbShare : "",
            smbDomain: seedFromCurrent ? smbDomain : ""
        )
        smbProfiles = [profile]
        SMBUploadProfileStore.saveProfiles(smbProfiles)
        selectedSMBProfileID = profile.id.uuidString
    }

    private func ensureS3ProfilesForBackend(seedFromCurrent: Bool) {
        guard s3Profiles.isEmpty else {
            ensureSelectedS3Profile()
            return
        }

        let profileName = seedFromCurrent ? defaultS3ProfileName() : "New S3 Profile"
        let profile = S3UploadProfile(
            name: profileName,
            bucket: seedFromCurrent ? s3Bucket : "",
            region: seedFromCurrent ? s3Region : "us-east-1",
            endpoint: seedFromCurrent ? s3Endpoint : "",
            accessKeyID: seedFromCurrent ? s3AccessKeyID : "",
            remotePath: seedFromCurrent ? remotePath : "/"
        )
        s3Profiles = [profile]
        S3UploadProfileStore.saveProfiles(s3Profiles)
        selectedS3ProfileID = profile.id.uuidString
    }

    private func defaultSFTPProfileName() -> String {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedServer.isEmpty ? "Default SFTP" : trimmedServer
    }

    private func defaultSMBProfileName() -> String {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedServer.isEmpty ? "Default SMB" : trimmedServer
    }

    private func defaultS3ProfileName() -> String {
        let trimmedBucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBucket.isEmpty ? "Default S3" : trimmedBucket
    }

    private func resolvedSFTPPort() -> Int {
        port > 0 ? port : AppConstants.defaultSFTPPort
    }

    private func resolvedSMBPort() -> Int {
        port > 0 ? port : AppConstants.defaultSMBPort
    }

    private func applySelectedSFTPProfile() {
        guard let profile = selectedSFTPProfile else { return }
        server = profile.server
        port = profile.port > 0 ? profile.port : AppConstants.defaultSFTPPort
        username = profile.username
        remotePath = profile.remotePath
        useSFTPKeyAuth = profile.useKeyAuth
        sftpKeyFilePath = profile.keyFilePath
        password = ""
        refreshPasswordState()
    }

    private func applySelectedSMBProfile() {
        guard let profile = selectedSMBProfile else { return }
        server = profile.server
        port = profile.port > 0 ? profile.port : AppConstants.defaultSMBPort
        username = profile.username
        remotePath = profile.remotePath
        smbShare = profile.smbShare
        smbDomain = profile.smbDomain
        password = ""
        refreshPasswordState()
    }

    private func applySelectedS3Profile() {
        guard let profile = selectedS3Profile else { return }
        s3Bucket = profile.bucket
        s3Region = profile.region
        s3Endpoint = profile.endpoint
        s3AccessKeyID = profile.accessKeyID
        remotePath = profile.remotePath
        s3SecretKey = ""
        refreshS3SecretState()
    }

    private func updateSelectedSFTPProfileFromFields() {
        guard currentBackendType == .sftp,
              let index = selectedSFTPProfileIndex else { return }
        sftpProfiles[index].server = server
        sftpProfiles[index].port = resolvedSFTPPort()
        sftpProfiles[index].username = username
        sftpProfiles[index].remotePath = remotePath
        sftpProfiles[index].useKeyAuth = useSFTPKeyAuth
        sftpProfiles[index].keyFilePath = sftpKeyFilePath
        SFTPUploadProfileStore.saveProfiles(sftpProfiles)
    }

    private func updateSelectedSMBProfileFromFields() {
        guard currentBackendType == .smb,
              let index = selectedSMBProfileIndex else { return }
        smbProfiles[index].server = server
        smbProfiles[index].port = resolvedSMBPort()
        smbProfiles[index].username = username
        smbProfiles[index].remotePath = remotePath
        smbProfiles[index].smbShare = smbShare
        smbProfiles[index].smbDomain = smbDomain
        SMBUploadProfileStore.saveProfiles(smbProfiles)
    }

    private func updateSelectedS3ProfileFromFields() {
        guard currentBackendType == .s3,
              let index = selectedS3ProfileIndex else { return }
        s3Profiles[index].bucket = s3Bucket
        s3Profiles[index].region = s3Region
        s3Profiles[index].endpoint = s3Endpoint
        s3Profiles[index].accessKeyID = s3AccessKeyID
        s3Profiles[index].remotePath = remotePath
        S3UploadProfileStore.saveProfiles(s3Profiles)
    }

    private func updateSelectedSFTPProfileName(_ newValue: String) {
        guard let index = selectedSFTPProfileIndex else { return }
        sftpProfiles[index].name = newValue
        SFTPUploadProfileStore.saveProfiles(sftpProfiles)
    }

    private func updateSelectedSMBProfileName(_ newValue: String) {
        guard let index = selectedSMBProfileIndex else { return }
        smbProfiles[index].name = newValue
        SMBUploadProfileStore.saveProfiles(smbProfiles)
    }

    private func updateSelectedS3ProfileName(_ newValue: String) {
        guard let index = selectedS3ProfileIndex else { return }
        s3Profiles[index].name = newValue
        S3UploadProfileStore.saveProfiles(s3Profiles)
    }

    private func addSFTPProfile() {
        let baseName = server.isEmpty ? "New SFTP Profile" : server
        let name = uniqueProfileName(from: baseName, existing: sftpProfiles.map { $0.name }, fallback: "SFTP Profile")
        let profile = SFTPUploadProfile(
            name: name,
            server: server,
            port: resolvedSFTPPort(),
            username: username,
            remotePath: remotePath,
            useKeyAuth: useSFTPKeyAuth,
            keyFilePath: sftpKeyFilePath
        )
        sftpProfiles.append(profile)
        SFTPUploadProfileStore.saveProfiles(sftpProfiles)
        selectedSFTPProfileID = profile.id.uuidString
        applySelectedSFTPProfile()
    }

    private func addSMBProfile() {
        let baseName = server.isEmpty ? "New SMB Profile" : server
        let name = uniqueProfileName(from: baseName, existing: smbProfiles.map { $0.name }, fallback: "SMB Profile")
        let profile = SMBUploadProfile(
            name: name,
            server: server,
            port: resolvedSMBPort(),
            username: username,
            remotePath: remotePath,
            smbShare: smbShare,
            smbDomain: smbDomain
        )
        smbProfiles.append(profile)
        SMBUploadProfileStore.saveProfiles(smbProfiles)
        selectedSMBProfileID = profile.id.uuidString
        applySelectedSMBProfile()
    }

    private func addS3Profile() {
        let baseName = s3Bucket.isEmpty ? "New S3 Profile" : s3Bucket
        let name = uniqueProfileName(from: baseName, existing: s3Profiles.map { $0.name }, fallback: "S3 Profile")
        let profile = S3UploadProfile(
            name: name,
            bucket: s3Bucket,
            region: s3Region,
            endpoint: s3Endpoint,
            accessKeyID: s3AccessKeyID,
            remotePath: remotePath
        )
        s3Profiles.append(profile)
        S3UploadProfileStore.saveProfiles(s3Profiles)
        selectedS3ProfileID = profile.id.uuidString
        applySelectedS3Profile()
    }

    private func deleteSelectedSFTPProfile() {
        guard let index = selectedSFTPProfileIndex else { return }
        sftpProfiles.remove(at: index)
        if sftpProfiles.isEmpty {
            let profile = SFTPUploadProfile(name: "New SFTP Profile")
            sftpProfiles = [profile]
            selectedSFTPProfileID = profile.id.uuidString
        } else {
            let nextIndex = min(index, sftpProfiles.count - 1)
            selectedSFTPProfileID = sftpProfiles[nextIndex].id.uuidString
        }
        SFTPUploadProfileStore.saveProfiles(sftpProfiles)
        if currentBackendType == .sftp {
            applySelectedSFTPProfile()
        }
    }

    private func deleteSelectedSMBProfile() {
        guard let index = selectedSMBProfileIndex else { return }
        smbProfiles.remove(at: index)
        if smbProfiles.isEmpty {
            let profile = SMBUploadProfile(name: "New SMB Profile")
            smbProfiles = [profile]
            selectedSMBProfileID = profile.id.uuidString
        } else {
            let nextIndex = min(index, smbProfiles.count - 1)
            selectedSMBProfileID = smbProfiles[nextIndex].id.uuidString
        }
        SMBUploadProfileStore.saveProfiles(smbProfiles)
        if currentBackendType == .smb {
            applySelectedSMBProfile()
        }
    }

    private func deleteSelectedS3Profile() {
        guard let index = selectedS3ProfileIndex else { return }
        s3Profiles.remove(at: index)
        if s3Profiles.isEmpty {
            let profile = S3UploadProfile(name: "New S3 Profile")
            s3Profiles = [profile]
            selectedS3ProfileID = profile.id.uuidString
        } else {
            let nextIndex = min(index, s3Profiles.count - 1)
            selectedS3ProfileID = s3Profiles[nextIndex].id.uuidString
        }
        S3UploadProfileStore.saveProfiles(s3Profiles)
        if currentBackendType == .s3 {
            applySelectedS3Profile()
        }
    }

    private func uniqueProfileName(from baseName: String, existing: [String], fallback: String) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = trimmed.isEmpty ? fallback : trimmed
        let existingNames = Set(existing)
        if !existingNames.contains(seed) {
            return seed
        }
        var index = 2
        var candidate = "\(seed) \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(seed) \(index)"
        }
        return candidate
    }

    private func refreshPasswordState() {
        guard !server.isEmpty, !username.isEmpty else {
            hasStoredPassword = false
            return
        }
        hasStoredPassword = KeychainCredentialManager.shared.hasCredential(
            server: server,
            username: username
        )
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

    private func saveS3SecretKey() {
        guard !s3AccessKeyID.isEmpty, !s3SecretKey.isEmpty else { return }

        do {
            try KeychainCredentialManager.shared.saveS3SecretKey(
                accessKeyID: s3AccessKeyID,
                secretKey: s3SecretKey
            )
            hasStoredS3SecretKey = true
            s3SecretKey = "" // Clear after saving
        } catch {
            // Handle error silently
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
            sftpKeyFilePath = url.path
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
