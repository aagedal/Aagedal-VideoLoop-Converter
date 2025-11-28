// Aagedal Media Converter
// Copyright © 2025 Truls Aaged
// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.screenshotDirectoryKey) private var screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
    @AppStorage(AppConstants.previewCacheCleanupPolicyKey) private var previewCacheCleanupPolicyRaw = AppConstants.defaultPreviewCacheCleanupPolicyRaw
    @AppStorage(AppConstants.screenshot8BitFormatKey) private var screenshot8BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshot10BitFormatKey) private var screenshot10BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotHighBitFormatKey) private var screenshotHighBitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotAlphaHandlingKey) private var screenshotAlphaHandling = AppConstants.defaultScreenshotAlphaHandling

    @State private var isClearingPreviewCache = false
    @State private var previewCacheSizeBytes: Int64 = 0

    var body: some View {
        Form {
            outputFolderSection
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
        Section(header: Text("Output Folder")) {
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
