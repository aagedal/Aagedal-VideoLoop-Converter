// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct YTDLPSettingsView: View {
    @State private var ytdlpVersion: String?
    @State private var ffmpegVersion: String?
    @State private var ffprobeVersion: String?
    @State private var isCheckingVersions = false
    @State private var ytdlpCustomPath: String = ""
    @State private var ffmpegCustomPath: String = ""
    @State private var ffprobeCustomPath: String = ""
    @State private var ytdlpStatus: YTDLPStatus = .checking
    @State private var installationStatus: YTDLPInstallationStatus = .notInstalled
    @State private var isDownloading = false
    @State private var downloadError: String?

    @AppStorage(AppConstants.autoEncodeAfterDownloadKey) private var autoEncodeAfterDownload = false
    @AppStorage(AppConstants.autoUploadAfterDownloadKey) private var autoUploadAfterDownload = false

    var body: some View {
        Form {
            ytdlpSection
            downloadAutomationSection
            ffmpegSection
            aboutSection
        }
        .formStyle(.grouped)
        .task {
            loadSettings()
            await refreshVersions()
        }
    }

    // MARK: - yt-dlp Status

    private enum YTDLPStatus {
        case checking
        case configured
        case notAvailable
    }

    // MARK: - yt-dlp Section

    private var ytdlpSection: some View {
        Section(header: Text("yt-dlp (Video Downloads)")) {
            VStack(alignment: .leading, spacing: 12) {
                // Status
                HStack {
                    switch ytdlpStatus {
                    case .checking:
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    case .configured:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(installationStatus.displayText)
                            .font(.headline)
                    case .notAvailable:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("yt-dlp not installed")
                            .font(.headline)
                    }

                    Spacer()

                    if let version = ytdlpVersion {
                        Text("v\(version)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if isCheckingVersions {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                // Download/Update buttons
                if !isDownloading {
                    HStack {
                        if ytdlpStatus == .notAvailable {
                            Button {
                                downloadYTDLP()
                            } label: {
                                Label("Download yt-dlp", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        } else if ytdlpStatus == .configured && !installationStatus.isCustomPath {
                            Button {
                                checkAndUpdateYTDLP()
                            } label: {
                                Label("Check for Updates", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Downloading...")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = downloadError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                // Custom path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom yt-dlp path (optional):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Leave empty to auto-download", text: $ytdlpCustomPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse...") {
                            selectBinary(for: .ytdlp)
                        }

                        if !ytdlpCustomPath.isEmpty {
                            Button(role: .destructive) {
                                ytdlpCustomPath = ""
                                saveYTDLPPath()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onChange(of: ytdlpCustomPath) { _, _ in
                    saveYTDLPPath()
                }

                // Alternative install info (Homebrew)
                if ytdlpStatus == .notAvailable {
                    Divider()

                    DisclosureGroup("Alternative: Install via Homebrew") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("brew install yt-dlp")
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("brew install yt-dlp", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }

                            Text("After installing, set custom path to: /opt/homebrew/bin/yt-dlp")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Link("Don't have Homebrew? Install it first", destination: URL(string: "https://brew.sh")!)
                                .font(.caption)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Download Actions

    private func downloadYTDLP() {
        isDownloading = true
        downloadError = nil
        Task {
            do {
                try await YTDLPUpdateService.shared.downloadUpdate()
                await refreshVersions()
            } catch {
                await MainActor.run {
                    downloadError = error.localizedDescription
                }
            }
            await MainActor.run {
                isDownloading = false
            }
        }
    }

    private func checkAndUpdateYTDLP() {
        isDownloading = true
        downloadError = nil
        Task {
            do {
                let hasUpdate = await YTDLPUpdateService.shared.checkForUpdates()
                if hasUpdate {
                    try await YTDLPUpdateService.shared.downloadUpdate()
                } else {
                    await MainActor.run {
                        downloadError = "Already up to date"
                    }
                    // Clear the message after a delay
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run {
                        if downloadError == "Already up to date" {
                            downloadError = nil
                        }
                    }
                }
                await refreshVersions()
            } catch {
                await MainActor.run {
                    downloadError = error.localizedDescription
                }
            }
            await MainActor.run {
                isDownloading = false
            }
        }
    }

    // MARK: - Download Automation Section

    private var downloadAutomationSection: some View {
        Section(header: Text("Download Automation")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Auto-encode after download", isOn: $autoEncodeAfterDownload)
                    .toggleStyle(SwitchToggleStyle())

                Text("When enabled, new downloads will automatically start encoding after the download completes.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                Toggle("Auto-upload after download", isOn: $autoUploadAfterDownload)
                    .toggleStyle(SwitchToggleStyle())
                    .disabled(!UploadManager.shared.isConfigured)

                Text("When enabled, new downloads will be uploaded after encoding completes. Requires upload to be configured in Settings > Upload.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !UploadManager.shared.isConfigured {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Upload not configured")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - FFmpeg Section

    private var ffmpegSection: some View {
        Section(header: Text("FFmpeg / FFprobe (Conversion)")) {
            VStack(alignment: .leading, spacing: 12) {
                // FFmpeg status
                HStack {
                    if BinaryPathResolver.isUsingCustomFFmpeg {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                        Text("FFmpeg: Custom")
                    } else if BinaryPathResolver.ffmpegPath != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("FFmpeg: Bundled")
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("FFmpeg: Not found")
                    }

                    Spacer()

                    if let version = ffmpegVersion {
                        Text(version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                // FFprobe status
                HStack {
                    if BinaryPathResolver.isUsingCustomFFprobe {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                        Text("FFprobe: Custom")
                    } else if BinaryPathResolver.ffprobePath != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("FFprobe: Bundled")
                    } else {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("FFprobe: Not found")
                    }

                    Spacer()

                    if let version = ffprobeVersion {
                        Text(version)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                // Custom FFmpeg path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom FFmpeg path (optional):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Leave empty to use bundled version", text: $ffmpegCustomPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse...") {
                            selectBinary(for: .ffmpeg)
                        }

                        if !ffmpegCustomPath.isEmpty {
                            Button(role: .destructive) {
                                ffmpegCustomPath = ""
                                saveFFmpegPath()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onChange(of: ffmpegCustomPath) { _, _ in
                    saveFFmpegPath()
                }

                // Custom FFprobe path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom FFprobe path (optional):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Leave empty to use bundled version", text: $ffprobeCustomPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse...") {
                            selectBinary(for: .ffprobe)
                        }

                        if !ffprobeCustomPath.isEmpty {
                            Button(role: .destructive) {
                                ffprobeCustomPath = ""
                                saveFFprobePath()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onChange(of: ffprobeCustomPath) { _, _ in
                    saveFFprobePath()
                }

                Divider()

                Button("Refresh Versions") {
                    Task { await refreshVersions() }
                }
                .disabled(isCheckingVersions)
            }
            .padding(8)
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        Section(header: Text("About")) {
            VStack(alignment: .leading, spacing: 8) {
                Text("The app includes bundled ffmpeg and ffprobe binaries. You can optionally use custom versions (e.g., from Homebrew) if you need specific features or codecs.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("yt-dlp enables downloading videos from YouTube and other sites. It can be auto-downloaded from GitHub or installed via Homebrew. Downloaded videos are automatically queued for conversion.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Link("FFmpeg", destination: URL(string: "https://ffmpeg.org")!)
                    Spacer()
                    Link("yt-dlp", destination: URL(string: "https://github.com/yt-dlp/yt-dlp")!)
                    Spacer()
                    Link("Homebrew", destination: URL(string: "https://brew.sh")!)
                }
                .font(.callout)
            }
            .padding(8)
        }
    }

    // MARK: - Binary Type

    private enum BinaryType {
        case ytdlp, ffmpeg, ffprobe

        var title: String {
            switch self {
            case .ytdlp: return "Select yt-dlp binary"
            case .ffmpeg: return "Select ffmpeg binary"
            case .ffprobe: return "Select ffprobe binary"
            }
        }

        var message: String {
            switch self {
            case .ytdlp: return "Select yt-dlp from /opt/homebrew/bin/ (Apple Silicon) or /usr/local/bin/ (Intel)"
            case .ffmpeg: return "Select ffmpeg binary"
            case .ffprobe: return "Select ffprobe binary"
            }
        }

        var defaultDirectory: URL? {
            // For yt-dlp, prefer /opt/homebrew/bin where the symlink is
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
                return URL(fileURLWithPath: "/opt/homebrew/bin")
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin") {
                return URL(fileURLWithPath: "/usr/local/bin")
            }
            return nil
        }
    }

    // MARK: - Actions

    private func loadSettings() {
        ytdlpCustomPath = YTDLPUpdateService.shared.getCustomPath() ?? ""
        ffmpegCustomPath = UserDefaults.standard.string(forKey: AppConstants.customFFmpegPathKey) ?? ""
        ffprobeCustomPath = UserDefaults.standard.string(forKey: AppConstants.customFFprobePathKey) ?? ""
    }

    private func saveYTDLPPath() {
        Task {
            if ytdlpCustomPath.isEmpty {
                await YTDLPUpdateService.shared.clearCustomPath()
            } else {
                await YTDLPUpdateService.shared.saveCustomPath(ytdlpCustomPath)
            }
            await refreshVersions()
        }
    }

    private func saveFFmpegPath() {
        BinaryPathResolver.saveCustomFFmpegPath(ffmpegCustomPath.isEmpty ? nil : ffmpegCustomPath)
        Task { await refreshVersions() }
    }

    private func saveFFprobePath() {
        BinaryPathResolver.saveCustomFFprobePath(ffprobeCustomPath.isEmpty ? nil : ffprobeCustomPath)
        Task { await refreshVersions() }
    }

    private func selectBinary(for type: BinaryType) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = type.title
        panel.message = type.message
        panel.prompt = "Select"
        panel.allowedContentTypes = [.unixExecutable, .exe, .item]
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = false
        panel.resolvesAliases = false  // Keep symlinks as-is, don't resolve to actual path

        if let defaultDir = type.defaultDirectory {
            panel.directoryURL = defaultDir
        }

        if panel.runModal() == .OK, let url = panel.url {
            switch type {
            case .ytdlp:
                ytdlpCustomPath = url.path
            case .ffmpeg:
                ffmpegCustomPath = url.path
            case .ffprobe:
                ffprobeCustomPath = url.path
            }
        }
    }

    private func refreshVersions() async {
        await MainActor.run {
            isCheckingVersions = true
            ytdlpStatus = .checking
        }

        // Check yt-dlp status and installation status
        let resolvedPath = await YTDLPUpdateService.shared.resolveYTDLPPath()
        let status: YTDLPStatus = resolvedPath != nil ? .configured : .notAvailable
        let instStatus = await YTDLPUpdateService.shared.getInstallationStatus()

        async let ytdlpVer = YTDLPUpdateService.shared.getCurrentVersion()
        async let ffmpegVer = BinaryPathResolver.getFFmpegVersion()
        async let ffprobeVer = BinaryPathResolver.getFFprobeVersion()

        let (yt, ff, fp) = await (ytdlpVer, ffmpegVer, ffprobeVer)

        await MainActor.run {
            ytdlpVersion = yt
            ffmpegVersion = ff
            ffprobeVersion = fp
            ytdlpStatus = status
            installationStatus = instStatus
            isCheckingVersions = false
        }
    }
}

#Preview {
    YTDLPSettingsView()
}
