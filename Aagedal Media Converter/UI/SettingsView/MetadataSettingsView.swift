// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

struct MetadataSettingsView: View {
    @AppStorage(AppConstants.includeDateTagPreferenceKey) private var includeDateTagByDefault = false
    @AppStorage(AppConstants.preserveMetadataPreferenceKey) private var preserveMetadataByDefault = false
    @AppStorage(AppConstants.defaultTimecodeModeKey) private var defaultTimecodeModeRaw = AppConstants.defaultTimecodeModeRaw
    @AppStorage(AppConstants.defaultTimecodeValueKey) private var defaultTimecodeValue = AppConstants.defaultTimecodeValue
    @AppStorage(AppConstants.commentPrefixKey) private var commentPrefix = ""
    @AppStorage(AppConstants.commentSuffixKey) private var commentSuffix = ""
    @AppStorage(AppConstants.commentSeparatorKey) private var commentSeparator = AppConstants.defaultCommentSeparator
    @AppStorage(AppConstants.commentDateFormatKey) private var commentDateFormat = AppConstants.defaultCommentDateFormat
    @AppStorage(AppConstants.dateTagPrefixKey) private var dateTagPrefix = AppConstants.defaultDateTagPrefix
    @AppStorage(AppConstants.showCommentFieldKey) private var showCommentField = true
    @AppStorage(AppConstants.showDateTagButtonKey) private var showDateTagButton = true
    @AppStorage(AppConstants.c2paCheckEnabledKey) private var c2paCheckEnabled = AppConstants.defaultC2PACheckEnabled

    @State private var isValidTimecode: Bool = true
    @State private var showCommentInfoPopover = false
    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var focusedCommentField: CommentField?

    // ExifTool state
    @State private var exiftoolStatus: ExifToolInstallationStatus = .notInstalled
    @State private var exiftoolVersion: String?
    @State private var exiftoolCustomPath: String = ""
    @State private var isCheckingExifTool = false
    @State private var isDownloadingExifTool = false
    @State private var exiftoolDownloadProgress: Double = 0
    @State private var exiftoolError: String?

    private enum CommentField: Hashable {
        case prefix, suffix, datePrefix
    }

    private enum TimecodeDefaultMode: String, CaseIterable, Identifiable {
        case preserveSource = "preserveSource"
        case manual = "manual"
        case disabled = "disabled"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .preserveSource: return "Preserve Source"
            case .manual: return "Manual Override"
            case .disabled: return "Disable"
            }
        }
    }

    private var selectedMode: TimecodeDefaultMode {
        TimecodeDefaultMode(rawValue: defaultTimecodeModeRaw) ?? .preserveSource
    }

    var body: some View {
        Form {
            metadataPreservationSection
            commentSection
            queueRowDisplaySection
            timecodeDefaultsSection
            exiftoolSection
        }
        .formStyle(.grouped)
        .onAppear {
            isValidTimecode = validateTimecode(defaultTimecodeValue)
        }
        .task {
            loadExifToolSettings()
            await refreshExifToolStatus()
        }
    }

    private var queueRowDisplaySection: some View {
        Section(header: Text("Queue Row Display")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Control which metadata controls are shown on each video row in the queue.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle(isOn: $showCommentField) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show comment field")
                            .font(.subheadline.weight(.medium))
                        Text("Display the comment text field for adding metadata comments to each file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())

                Toggle(isOn: $showDateTagButton) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Show date tag button")
                            .font(.subheadline.weight(.medium))
                        Text("Display the button to toggle the \"Date generated\" tag for each file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
            }
            .padding(8)
        }
    }

    private var metadataPreservationSection: some View {
        Section(header: Text("Metadata Preservation")) {
            VStack(alignment: .leading, spacing: 12) {
                // Preserve metadata toggle
                Toggle(isOn: $preserveMetadataByDefault) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Preserve all original metadata")
                            .font(.subheadline.weight(.medium))
                        Text("Keep title, timecode, and encoder tags from the source file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .help("When enabled, the original file's metadata is kept intact during conversion")
                
                Text("By default, metadata such as title, timecode, and encoder tags are stripped to keep output files clean. Color-related metadata (including HDR) is always preserved for accurate viewing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Date tag toggle
                Toggle(isOn: $includeDateTagByDefault) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Include date tag on new files")
                            .font(.subheadline.weight(.medium))
                        Text("Auto-generate timestamp in comment field (e.g., \"Date generated: 20250116\")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(preserveMetadataByDefault)
                .help("Controls whether newly added files include the \"Date generated\" metadata tag by default")
                
                if preserveMetadataByDefault {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text("Date tag is unavailable when preserving original metadata")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("The date tag precedes any custom comment you enter on the video card.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        }
    }
    
    private var commentSection: some View {
        Section(header: Text("Comment Formatting")) {
            VStack(alignment: .leading) {
                Text("Configure optional prefix/suffix for metadata comments and how the date tag is formatted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack{
                    LabeledContent("Prefix") {
                        TextField("", text: $commentPrefix)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedCommentField, equals: .prefix)
                            .onSubmit { focusedCommentField = .suffix }
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                HStack{
                    LabeledContent("Suffix") {
                        TextField("", text: $commentSuffix)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedCommentField, equals: .suffix)
                            .onSubmit { focusedCommentField = .datePrefix }
                    }
                }

                Divider()
                    .padding(.vertical, 4)
                
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Avoid special characters like em dashes (\u{2014}) in prefix, suffix, or comments. They may cause metadata to not be written correctly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Divider()
                    .padding(.vertical, 4)

                HStack {
                    LabeledContent("Separator") {
                        Picker("", selection: $commentSeparator) {
                            Text("Pipe ( | )").tag(" | ")
                            Text("Dash ( - )").tag(" - ")
                            Text("Colon ( : )").tag(": ")
                            Text("Comma ( , )").tag(", ")
                            Text("Space").tag(" ")
                            Text("None").tag("")
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                
                Divider()
                    .padding(.vertical, 4)
                
                HStack {
                    LabeledContent("Date format") {
                        Picker("", selection: $commentDateFormat) {
                            Text("YYYYMMDD (\(formattedDateExample("yyyyMMdd")))").tag("yyyyMMdd")
                            Text("YYYY-MM-DD (\(formattedDateExample("yyyy-MM-dd")))").tag("yyyy-MM-dd")
                            Text("DD/MM/YYYY (\(formattedDateExample("dd/MM/yyyy")))").tag("dd/MM/yyyy")
                            Text("MM/DD/YYYY (\(formattedDateExample("MM/dd/yyyy")))").tag("MM/dd/yyyy")
                            Text("DD.MM.YYYY (\(formattedDateExample("dd.MM.yyyy")))").tag("dd.MM.yyyy")
                            Text("YYYY.MM.DD (\(formattedDateExample("yyyy.MM.dd")))").tag("yyyy.MM.dd")
                            Text("MMM DD, YYYY (\(formattedDateExample("MMM dd, yyyy")))").tag("MMM dd, yyyy")
                            Text("DD MMM YYYY (\(formattedDateExample("dd MMM yyyy")))").tag("dd MMM yyyy")
                        }
                        .pickerStyle(.menu)
                    }
                }
                
                
                Divider()
                    .padding(.vertical, 4)


                HStack {
                    LabeledContent("Date prefix") {
                        TextField("", text: $dateTagPrefix)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedCommentField, equals: .datePrefix)
                            .onSubmit { focusedCommentField = .prefix }
                    }
                }


                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            showCommentInfoPopover.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showCommentInfoPopover, arrowEdge: .trailing) {
                            CommentPreviewPopover(
                                prefix: commentPrefix,
                                suffix: commentSuffix,
                                separator: commentSeparator,
                                dateFormat: commentDateFormat,
                                dateTagPrefix: dateTagPrefix,
                                includeDateTag: includeDateTagByDefault
                            )
                        }

                        Text("Preview (sample comment):")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()
                    }

                    Text(buildCommentPreview(sampleComment: "My comment"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(NSColor.textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
            }
            .padding(8)
        }
    }
    
    private func formattedDateExample(_ format: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = format
        return dateFormatter.string(from: Date())
    }
    
    private func buildCommentPreview(sampleComment: String) -> String {
        var parts: [String] = []
        
        if includeDateTagByDefault {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = commentDateFormat
            let datePrefix = dateTagPrefix.isEmpty ? AppConstants.defaultDateTagPrefix : dateTagPrefix
            parts.append("\(datePrefix): \(dateFormatter.string(from: Date()))")
        }
        
        if !commentPrefix.isEmpty {
            parts.append(commentPrefix)
        }
        
        parts.append(sampleComment)
        
        if !commentSuffix.isEmpty {
            parts.append(commentSuffix)
        }
        
        return parts.joined(separator: commentSeparator)
    }

    private var timecodeDefaultsSection: some View {
        Section(header: Text("Timecode Defaults")) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Default timecode mode for new files:")
                    .font(.subheadline.weight(.medium))

                Picker(selection: $defaultTimecodeModeRaw, label: Text("Default Mode")) {
                    ForEach(TimecodeDefaultMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Mode-specific content
                switch selectedMode {
                case .preserveSource:
                    Text("The timecode from the source file will be copied to the output.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .manual:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter a default start timecode for output files.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Timecode Value:")
                            .font(.subheadline.weight(.medium))

                        HStack(spacing: 8) {
                            Button(action: { adjustFrames(by: -10) }) {
                                Image(systemName: "minus.rectangle.fill")
                                Text("10")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Subtract 10 frames")

                            Button(action: { adjustFrames(by: -1) }) {
                                Image(systemName: "minus.circle.fill")
                                Text("1")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Subtract 1 frame")

                            TextField("00:00:00:00", text: $defaultTimecodeValue)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .frame(minWidth: 120, maxWidth: 160)
                                .focused($isTextFieldFocused)
                                .onChange(of: defaultTimecodeValue) { _, newValue in
                                    let sanitized = sanitizeTimecode(newValue)
                                    if sanitized != newValue {
                                        defaultTimecodeValue = sanitized
                                    }
                                    isValidTimecode = validateTimecode(sanitized)
                                }
                                .onChange(of: isTextFieldFocused) { _, isFocused in
                                    if !isFocused {
                                        autoCorrectTimecode()
                                    }
                                }
                                .onSubmit {
                                    autoCorrectTimecode()
                                }

                            Button(action: { adjustFrames(by: 1) }) {
                                Image(systemName: "plus.circle.fill")
                                Text("1")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Add 1 frame")

                            Button(action: { adjustFrames(by: 10) }) {
                                Image(systemName: "plus.rectangle.fill")
                                Text("10")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Add 10 frames")
                        }

                        if !isValidTimecode {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text(validationErrorMessage())
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("Format: HH:MM:SS:FF (00-23 hours, 00-29 frames @ 30fps) or HH:MM:SS;FF for drop-frame")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                case .disabled:
                    Text("No timecode will be written to output files by default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        }
    }

    // MARK: - ExifTool Section

    private var exiftoolSection: some View {
        Section(header: Text("ExifTool (Extended Metadata)")) {
            VStack(alignment: .leading, spacing: 12) {
                // Status
                HStack {
                    if isCheckingExifTool {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Checking...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    } else if exiftoolStatus.isAvailable {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(exiftoolStatus.displayText)
                            .font(.headline)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("ExifTool not installed")
                            .font(.headline)
                    }

                    Spacer()

                    if let version = exiftoolVersion {
                        Text("v\(version)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                // Download/Update buttons
                if !isDownloadingExifTool {
                    HStack {
                        if !exiftoolStatus.isAvailable {
                            Button {
                                downloadExifTool()
                            } label: {
                                Label("Download ExifTool", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                        } else if case .downloaded = exiftoolStatus {
                            Button {
                                checkAndUpdateExifTool()
                            } label: {
                                Label("Check for Updates", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                } else {
                    HStack {
                        ProgressView(value: exiftoolDownloadProgress)
                            .frame(width: 100)
                        Text("Downloading... \(Int(exiftoolDownloadProgress * 100))%")
                            .foregroundColor(.secondary)
                    }
                }

                if let error = exiftoolError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(error == "Already up to date" ? .secondary : .red)
                }

                Divider()

                // Custom path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom ExifTool path (optional):")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        TextField("Leave empty to auto-download or use system", text: $exiftoolCustomPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        Button("Browse...") {
                            selectExifToolBinary()
                        }

                        if !exiftoolCustomPath.isEmpty {
                            Button(role: .destructive) {
                                exiftoolCustomPath = ""
                                saveExifToolPath()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onChange(of: exiftoolCustomPath) { _, _ in
                    saveExifToolPath()
                }

                // Homebrew alternative
                if !exiftoolStatus.isAvailable {
                    Divider()

                    DisclosureGroup("Alternative: Install via Homebrew") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("brew install exiftool")
                                    .font(.system(.body, design: .monospaced))
                                    .padding(8)
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .cornerRadius(6)

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("brew install exiftool", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }

                            Text("ExifTool will be detected automatically from Homebrew paths.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .foregroundColor(.secondary)
                }

                Divider()

                // C2PA Settings
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $c2paCheckEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Check for C2PA metadata")
                                .font(.subheadline.weight(.medium))
                            Text("Automatically detect Content Authenticity (C2PA) credentials in imported files")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle())
                    .disabled(!exiftoolStatus.isAvailable)

                    if !exiftoolStatus.isAvailable {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text("Install ExifTool to enable C2PA metadata detection")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                // About ExifTool
                VStack(alignment: .leading, spacing: 4) {
                    Text("ExifTool reads extended metadata that FFprobe doesn't support, such as C2PA content credentials, XMP data, and EXIF tags.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link("Learn more about ExifTool", destination: URL(string: "https://exiftool.org")!)
                        .font(.caption)
                }
            }
            .padding(8)
        }
    }

    // MARK: - ExifTool Actions

    private func loadExifToolSettings() {
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.exiftoolCustomPathKey) {
            exiftoolCustomPath = customPath
        }
    }

    private func saveExifToolPath() {
        Task {
            await ExifToolUpdateService.shared.saveCustomPath(exiftoolCustomPath.isEmpty ? nil : exiftoolCustomPath)
            await refreshExifToolStatus()
        }
    }

    private func refreshExifToolStatus() async {
        await MainActor.run {
            isCheckingExifTool = true
        }

        let status = await ExifToolUpdateService.shared.getInstallationStatus()
        let version = await ExifToolUpdateService.shared.getCurrentVersion()

        await MainActor.run {
            exiftoolStatus = status
            exiftoolVersion = version
            isCheckingExifTool = false
        }
    }

    private func downloadExifTool() {
        isDownloadingExifTool = true
        exiftoolDownloadProgress = 0
        exiftoolError = nil

        Task {
            do {
                try await ExifToolUpdateService.shared.downloadUpdate { progress in
                    Task { @MainActor in
                        exiftoolDownloadProgress = progress
                    }
                }
                await refreshExifToolStatus()
            } catch {
                await MainActor.run {
                    exiftoolError = error.localizedDescription
                }
            }
            await MainActor.run {
                isDownloadingExifTool = false
            }
        }
    }

    private func checkAndUpdateExifTool() {
        isDownloadingExifTool = true
        exiftoolDownloadProgress = 0
        exiftoolError = nil

        Task {
            do {
                let (hasUpdate, _, latestVersion) = try await ExifToolUpdateService.shared.checkForUpdates()
                if hasUpdate {
                    try await ExifToolUpdateService.shared.downloadUpdate { progress in
                        Task { @MainActor in
                            exiftoolDownloadProgress = progress
                        }
                    }
                } else {
                    await MainActor.run {
                        exiftoolError = "Already up to date (v\(latestVersion))"
                    }
                    // Clear the message after a delay
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run {
                        if exiftoolError?.starts(with: "Already up to date") == true {
                            exiftoolError = nil
                        }
                    }
                }
                await refreshExifToolStatus()
            } catch {
                await MainActor.run {
                    exiftoolError = error.localizedDescription
                }
            }
            await MainActor.run {
                isDownloadingExifTool = false
            }
        }
    }

    private func selectExifToolBinary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.title = "Select ExifTool binary"
        panel.message = "Select exiftool from /opt/homebrew/bin/ (Apple Silicon) or /usr/local/bin/ (Intel)"
        panel.prompt = "Select"
        panel.allowedContentTypes = [.unixExecutable, .exe, .item]
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = false
        panel.resolvesAliases = false

        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") {
            panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin") {
            panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        }

        if panel.runModal() == .OK, let url = panel.url {
            exiftoolCustomPath = url.path
        }
    }

    // MARK: - Timecode Validation & Sanitization

    private func sanitizeTimecode(_ input: String) -> String {
        // Only allow digits, colons, and semicolons
        let allowed = CharacterSet(charactersIn: "0123456789:;")
        let filtered = input.filter { char in
            char.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        // Limit length to 11 characters (HH:MM:SS:FF or HH:MM:SS;FF)
        let truncated = String(filtered.prefix(11))

        return truncated
    }

    private func validateTimecode(_ input: String) -> Bool {
        // Valid formats: HH:MM:SS:FF or HH:MM:SS;FF
        let pattern = "^\\d{2}:\\d{2}:\\d{2}[:;]\\d{2}$"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.firstMatch(in: input, range: range)

        if matches == nil {
            return false
        }

        // Additional validation: hours, minutes, seconds, frames should be in valid ranges
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return false
        }

        // Hours: 0-23 (24-hour format)
        guard hours < 24 else { return false }

        // Minutes: 0-59
        guard minutes < 60 else { return false }

        // Seconds: 0-59
        guard seconds < 60 else { return false }

        // Frames: 0-29 (default to 30fps for settings)
        guard frames < 30 else { return false }

        return true
    }

    private func validationErrorMessage() -> String {
        let components = defaultTimecodeValue.split(whereSeparator: { $0 == ":" || $0 == ";" })

        if components.count != 4 {
            return "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF"
        }

        guard let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF"
        }

        if hours >= 24 {
            return "Hours must be 00-23"
        }

        if minutes >= 60 {
            return "Minutes must be 00-59"
        }

        if seconds >= 60 {
            return "Seconds must be 00-59"
        }

        if frames >= 30 {
            return "Frames must be 00-29 (30fps default)"
        }

        return "Invalid timecode format"
    }

    private func autoCorrectTimecode() {
        let components = defaultTimecodeValue.split(whereSeparator: { $0 == ":" || $0 == ";" })

        // If format is completely wrong, reset to default
        guard components.count == 4 else {
            defaultTimecodeValue = "00:00:00:00"
            isValidTimecode = true
            return
        }

        // Parse components
        guard let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            defaultTimecodeValue = "00:00:00:00"
            isValidTimecode = true
            return
        }

        // Clamp each component to valid range
        let clampedHours = min(hours, 23)
        let clampedMinutes = min(minutes, 59)
        let clampedSeconds = min(seconds, 59)
        let clampedFrames = min(frames, 29) // Default to 30fps

        // Preserve the separator (: or ;)
        let separator = defaultTimecodeValue.contains(";") ? ";" : ":"

        // Build corrected timecode
        let corrected = String(format: "%02d:%02d:%02d%@%02d",
                              clampedHours,
                              clampedMinutes,
                              clampedSeconds,
                              separator,
                              clampedFrames)

        defaultTimecodeValue = corrected
        isValidTimecode = true
    }

    private func adjustFrames(by delta: Int) {
        let components = defaultTimecodeValue.split(whereSeparator: { $0 == ":" || $0 == ";" })

        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return
        }

        let maxFrames = 30 // Default to 30fps

        // Convert everything to total frames
        var totalFrames = hours * 3600 * maxFrames
        totalFrames += minutes * 60 * maxFrames
        totalFrames += seconds * maxFrames
        totalFrames += frames

        // Add delta
        totalFrames += delta

        // Ensure non-negative
        totalFrames = max(0, totalFrames)

        // Convert back to timecode components
        var newFrames = totalFrames % maxFrames
        totalFrames /= maxFrames

        var newSeconds = totalFrames % 60
        totalFrames /= 60

        var newMinutes = totalFrames % 60
        totalFrames /= 60

        var newHours = totalFrames % 24

        // Clamp to 23:59:59:FF
        if newHours >= 24 {
            newHours = 23
            newMinutes = 59
            newSeconds = 59
            newFrames = maxFrames - 1
        }

        // Preserve the separator (: or ;)
        let separator = defaultTimecodeValue.contains(";") ? ";" : ":"

        // Build new timecode
        defaultTimecodeValue = String(format: "%02d:%02d:%02d%@%02d",
                                newHours,
                                newMinutes,
                                newSeconds,
                                separator,
                                newFrames)

        isValidTimecode = true
    }
}

// MARK: - Comment Preview Popover

private struct CommentPreviewPopover: View {
    let prefix: String
    let suffix: String
    let separator: String
    let dateFormat: String
    let dateTagPrefix: String
    let includeDateTag: Bool
    
    private var separatorDisplayName: String {
        switch separator {
        case " | ": return "Pipe ( | )"
        case " - ": return "Dash ( - )"
        case ": ": return "Colon ( : )"
        case ", ": return "Comma ( , )"
        case " ": return "Space"
        case "": return "None"
        default: return "\"\(separator)\""
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Metadata Comment")
                .font(.headline)
            
            Text("The metadata comment is embedded in the exported file and can be viewed in video players or file inspectors. It's composed of:")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(alignment: .leading, spacing: 6) {
                commentComponentRow(label: "Date tag", value: includeDateTag ? "Enabled" : "Disabled", color: includeDateTag ? .green : .secondary)
                commentComponentRow(label: "Prefix", value: prefix.isEmpty ? "(none)" : "\"\(prefix)\"", color: prefix.isEmpty ? .secondary : .primary)
                commentComponentRow(label: "Your comment", value: "Per-file comment", color: .primary)
                commentComponentRow(label: "Suffix", value: suffix.isEmpty ? "(none)" : "\"\(suffix)\"", color: suffix.isEmpty ? .secondary : .primary)
                commentComponentRow(label: "Separator", value: separatorDisplayName, color: .primary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Full comment preview:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(buildFullPreview())
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(NSColor.textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .padding()
        .frame(width: 320)
    }
    
    private func commentComponentRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundColor(color)
        }
    }
    
    private func buildFullPreview() -> String {
        var parts: [String] = []
        
        if includeDateTag {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = dateFormat
            let effectiveDatePrefix = dateTagPrefix.isEmpty ? AppConstants.defaultDateTagPrefix : dateTagPrefix
            parts.append("\(effectiveDatePrefix): \(dateFormatter.string(from: Date()))")
        }
        
        if !prefix.isEmpty {
            parts.append(prefix)
        }
        
        parts.append("Sample comment text")
        
        if !suffix.isEmpty {
            parts.append(suffix)
        }
        
        return parts.joined(separator: separator)
    }
}

#Preview {
    MetadataSettingsView()
}
