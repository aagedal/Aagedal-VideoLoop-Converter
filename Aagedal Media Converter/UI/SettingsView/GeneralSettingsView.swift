// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.saveNextToOriginalKey) private var saveNextToOriginal = AppConstants.defaultSaveNextToOriginal
    @AppStorage(AppConstants.saveNextToOriginalSubfolderKey) private var saveNextToOriginalSubfolder = AppConstants.defaultSaveNextToOriginalSubfolder
    @AppStorage(AppConstants.saveNextToOriginalSubfolderModeKey) private var saveNextToOriginalSubfolderMode = AppConstants.defaultSaveNextToOriginalSubfolderMode
    @AppStorage(AppConstants.saveNextToOriginalSubfolderNameKey) private var saveNextToOriginalSubfolderName = AppConstants.defaultSaveNextToOriginalSubfolderName
    @AppStorage(AppConstants.enableFileNameProcessingKey) private var enableFileNameProcessing = true
    @AppStorage(AppConstants.fileNameReplaceSpacesKey) private var fileNameReplaceSpaces = AppConstants.defaultFileNameReplaceSpaces
    @AppStorage(AppConstants.fileNameReplaceScandinavianCharsKey) private var fileNameReplaceScandinavianChars = AppConstants.defaultFileNameReplaceScandinavianChars
    @AppStorage(AppConstants.fileNameRemoveSpecialCharsKey) private var fileNameRemoveSpecialChars = AppConstants.defaultFileNameRemoveSpecialChars
    @AppStorage(AppConstants.fileNameIncludePresetSuffixKey) private var fileNameIncludePresetSuffix = AppConstants.defaultFileNameIncludePresetSuffix
    @AppStorage(AppConstants.screenshotDirectoryKey) private var screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
    @AppStorage(AppConstants.previewCacheCleanupPolicyKey) private var previewCacheCleanupPolicyRaw = AppConstants.defaultPreviewCacheCleanupPolicyRaw
    @AppStorage(AppConstants.screenshot8BitFormatKey) private var screenshot8BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshot10BitFormatKey) private var screenshot10BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotHighBitFormatKey) private var screenshotHighBitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotAlphaHandlingKey) private var screenshotAlphaHandling = AppConstants.defaultScreenshotAlphaHandling
    @AppStorage(AppConstants.resetClearsSettingsKey) private var resetClearsSettings = AppConstants.defaultResetClearsSettings
    @AppStorage(AppConstants.queueViewModeKey) private var queueViewMode = AppConstants.defaultQueueViewMode
    @AppStorage(AppConstants.playSoundOnSuccessKey) private var playSoundOnSuccess = AppConstants.defaultPlaySoundOnSuccess
    @AppStorage(AppConstants.playSoundOnErrorKey) private var playSoundOnError = AppConstants.defaultPlaySoundOnError
    @AppStorage(AppConstants.preferredTimecodeDisplayModeKey) private var preferredTimecodeDisplayMode = AppConstants.defaultPreferredTimecodeDisplayMode

    @State private var isClearingPreviewCache = false
    @State private var previewCacheSizeBytes: Int64 = 0

    var body: some View {
        Form {
            outputFolderSection
            fileNameSection
            queueDisplaySection
            timecodeDisplaySection
            soundSection
            resetBehaviorSection
            screenshotSection
            previewCacheSection
            linksSection
        }
        .formStyle(.grouped)
        .onChange(of: previewCacheCleanupPolicyRaw) { _, newValue in
            let policy = PreviewCacheCleanupPolicy(rawValue: newValue) ?? .purgeOnLaunch
            Task {
                await PreviewAssetGenerator.shared.applyCleanupPolicy(policy)
                await refreshPreviewCacheSize()
            }
        }
        .task { await refreshPreviewCacheSize() }
        .onChange(of: isClearingPreviewCache) { _, isClearing in
            guard !isClearing else { return }
            Task { await refreshPreviewCacheSize() }
        }
    }

    private var outputFolderSection: some View {
        Section(header: Text("Output Location")) {
            VStack(alignment: .leading, spacing: 12) {
                
                HStack {
                    Toggle("Save encoded files next to original", isOn: $saveNextToOriginal)
                        .toggleStyle(SwitchToggleStyle())
                }
                
                Divider()
                    .padding(.vertical, 4)

                if saveNextToOriginal {
                    // Subfolder options when saving next to original
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Place in subfolder", isOn: $saveNextToOriginalSubfolder)
                                .toggleStyle(SwitchToggleStyle())
                                //.padding(.leading, 16)
                        }

                        Divider()
                            .padding(.vertical, 4)

                        if saveNextToOriginalSubfolder {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Picker("Subfolder name:", selection: $saveNextToOriginalSubfolderMode) {
                                        Text("Custom name").tag("custom")
                                        Text("Use preset suffix").tag("presetSuffix")
                                    }
                                    .pickerStyle(.segmented)
                                    .padding(.top, 16)
                                    
                                }
                                
                                if saveNextToOriginalSubfolderMode == "custom" {
                                    HStack {
                                        Text("Folder name:")
                                        TextField("", text: $saveNextToOriginalSubfolderName)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    .padding(.top, 10)
                                } else {
                                    Text("Folder will be named using the preset suffix (e.g., \"loop\", \"tv\", \"prores\")")
                                        .font(.callout)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Text("Encoded files will be saved in the same folder as the source file.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    // Default output folder UI
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Default Output Folder:")
                            .font(.headline)

                        HStack {
                            Text(outputFolder)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .help(outputFolder)

                            Button(action: {
                                let url = URL(fileURLWithPath: outputFolder)
                                guard FileManager.default.fileExists(atPath: url.path) else {
                                    outputFolder = AppConstants.defaultOutputDirectory.path
                                    NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultOutputDirectory])
                                    return
                                }

                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }) {
                                Image(systemName: "arrow.right.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Show in Finder")

                            Button(action: { selectNewOutputFolder() }) {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .help("Change default output folder")
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var fileNameSection: some View {
        Section(header: Text("File Names")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable filename processing", isOn: $enableFileNameProcessing)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, spaces and special characters in filenames are sanitized")

                if enableFileNameProcessing {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Replace spaces with underscores", isOn: $fileNameReplaceSpaces)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                        Toggle("Convert Scandinavian characters (æ, ø, å)", isOn: $fileNameReplaceScandinavianChars)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                        Toggle("Remove special characters", isOn: $fileNameRemoveSpecialChars)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                Toggle("Include preset suffix in filename", isOn: $fileNameIncludePresetSuffix)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, preset suffixes like '_loop' or '_tv' are added to output filenames")
                Text("When disabled, output filenames will not include preset-specific suffixes.")
                    .font(Font.caption.italic())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var queueDisplaySection: some View {
        Section(header: Text("Queue Display")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use compact list view", isOn: Binding(
                    get: { queueViewMode == "compact" },
                    set: { queueViewMode = $0 ? "compact" : "standard" }
                ))
                    .toggleStyle(SwitchToggleStyle())
                    .help("Show a condensed view with smaller thumbnails and inline action buttons")
                Text("Compact mode hides comment fields, file sizes, and duration to show more items at once. Action buttons appear in a row under each filename.")
                    .font(Font.caption.italic())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var timecodeDisplaySection: some View {
        Section(header: Text("Timecode Display")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default timecode mode:")
                    Picker("", selection: $preferredTimecodeDisplayMode) {
                        ForEach(TimecodeDisplayMode.allCases, id: \.rawValue) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 250)
                }
                Text("Sets the initial timecode display mode when opening the trim view or fullscreen player. You can toggle modes during playback by pressing T.")
                    .font(Font.caption.italic())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var soundSection: some View {
        Section(header: Text("Sounds")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Play sound when encoding completes", isOn: $playSoundOnSuccess)
                    .toggleStyle(SwitchToggleStyle())
                
                Divider()
                    .padding(.vertical, 4)
                
                Toggle("Play sound when an error occurs", isOn: $playSoundOnError)
                    .toggleStyle(SwitchToggleStyle())
            }
            .padding(8)
        }
    }

    private var resetBehaviorSection: some View {
        Section(header: Text("Reset Behavior")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Reset also clears trim, crop, and audio routing", isOn: $resetClearsSettings)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Controls what the Reset button does by default")
                Text(resetClearsSettings
                    ? "When enabled, resetting an item will clear all settings (trim points, crop, audio routing, timecode). Hold Option to only reset the encoding status."
                    : "When disabled, resetting only changes the item back to waiting status, preserving trim, crop, and audio routing settings. Hold Option to also clear all settings.")
                    .font(Font.caption.italic())
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var screenshotSection: some View {
        Section(header: Text("Screenshots")) {
            VStack(alignment: .leading, spacing: 12) {
                // Folder selection
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Screenshot Folder:")
                        .font(.headline)

                    HStack {
                        Text(screenshotDirectoryPath)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(screenshotDirectoryPath)

                        Button(action: {
                            let url = URL(fileURLWithPath: screenshotDirectoryPath)
                            guard FileManager.default.fileExists(atPath: url.path) else {
                                screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")

                        Button(action: { selectScreenshotDirectory() }) {
                            Image(systemName: "camera.on.rectangle")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Change screenshot folder")

                        Button(action: { screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path }) {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Reset to Downloads")
                    }
                }

                Divider()

                // Format settings
                VStack(alignment: .leading, spacing: 8) {
                    Text("Screenshot Formats:")
                        .font(.headline)

                    Text("Select the image format for screenshots based on source bit depth.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("8-bit sources:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $screenshot8BitFormat) {
                            ForEach(ScreenshotFormat.allCases) { format in
                                Text(format.displayName).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }
                    
                    Divider()
                        .padding(.vertical, 4)

                    HStack {
                        Text("10-bit sources:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $screenshot10BitFormat) {
                            ForEach(ScreenshotFormat.allCases) { format in
                                Text(format.displayName).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack {
                        Text(">10-bit sources:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $screenshotHighBitFormat) {
                            ForEach(ScreenshotFormat.allCases) { format in
                                Text(format.displayName).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    Text("Alpha Channel Handling:")
                        .font(.headline)

                    Text("Choose how to handle screenshots with alpha transparency.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Alpha handling:")
                            .frame(width: 120, alignment: .trailing)
                        Picker("", selection: $screenshotAlphaHandling) {
                            ForEach(ScreenshotAlphaHandling.allCases) { handling in
                                Text(handling.displayName).tag(handling.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 300)
                    }
                }
            }
            .padding(8)
        }
    }

    private var previewCacheSection: some View {
        Section(header: Text("Preview Cache")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Cleanup policy", selection: $previewCacheCleanupPolicyRaw) {
                    ForEach(PreviewCacheCleanupPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text(previewCacheCleanupPolicy.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Spacer()
                    Text(previewCacheSizeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button {
                        NSWorkspace.shared.open(AppConstants.previewCacheDirectory)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    Button {
                        isClearingPreviewCache = true
                        Task {
                            await PreviewAssetGenerator.shared.cleanupAllCache()
                            await refreshPreviewCacheSize()
                            await MainActor.run { isClearingPreviewCache = false }
                        }
                    } label: {
                        Label("Clear cache now", systemImage: "trash")
                    }
                    .disabled(isClearingPreviewCache)

                    if isClearingPreviewCache {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }.padding(.top, 8)
            }
            .padding(8)
        }
    }

    private var linksSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Source code and author website", systemImage: "questionmark.circle")
                    .font(.headline)
                HStack {
                    Link("GitHub Repository", destination: URL(string: "https://github.com/aagedal/Aagedal-Media-Converter/tree/main")!)
                    Spacer()
                    Link("Developer Website", destination: URL(string: "https://aagedal.me/about")!)
                }
                .padding(8)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private var previewCacheCleanupPolicy: PreviewCacheCleanupPolicy {
        PreviewCacheCleanupPolicy(rawValue: previewCacheCleanupPolicyRaw) ?? .purgeOnLaunch
    }
    
    private var previewCacheSizeDescription: String {
        guard previewCacheSizeBytes > 0 else { return "Cache is empty" }
        return Self.byteCountFormatter.string(fromByteCount: previewCacheSizeBytes)
    }
    
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.includesUnit = true
        formatter.includesActualByteCount = false
        return formatter
    }()

    private func refreshPreviewCacheSize() async {
        let size = await PreviewAssetGenerator.shared.cacheDirectorySizeInBytes()
        await MainActor.run { previewCacheSizeBytes = size }
    }

    private func selectNewOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        
        if panel.runModal() == .OK, let url = panel.url {
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outputFolder = url.path
        }
    }

    private func selectScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: screenshotDirectoryPath)

        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            screenshotDirectoryPath = url.path
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }
    }

}

#Preview {
    GeneralSettingsView()
}
