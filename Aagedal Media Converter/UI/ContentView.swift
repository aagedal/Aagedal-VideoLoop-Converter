// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVFoundation
import AppKit
import Carbon.HIToolbox

// Custom notification to trigger file importer from menu command
#if !os(iOS)
extension Notification.Name {
    static let showFileImporter = Notification.Name("showFileImporter")
}
#endif

struct ContentView: View {
    @State private var droppedFiles: [VideoItem] = []
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path {
        didSet {
            // Update the currentOutputFolder when outputFolder changes
            currentOutputFolder = URL(fileURLWithPath: outputFolder)
        }
    }
    @State private var currentOutputFolder: URL = AppConstants.defaultOutputDirectory {
        didSet {
            // Update the stored path when currentOutputFolder changes programmatically
            if currentOutputFolder.path != outputFolder {
                outputFolder = currentOutputFolder.path
            }
            refreshExpectedOutputURLs(for: selectedPreset)
        }
    }
    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var hasInitializedPreset = false
    @State private var hasUserChangedPreset = false
    @State private var dockProgressUpdater = DockProgressUpdater()
    @State private var progressTask: Task<Void, Never>?
    @AppStorage(AppConstants.customPreset1NameKey) private var customPreset1Name = AppConstants.defaultCustomPresetDisplayNames[0]
    @AppStorage(AppConstants.customPreset2NameKey) private var customPreset2Name = AppConstants.defaultCustomPresetDisplayNames[1]
    @AppStorage(AppConstants.customPreset3NameKey) private var customPreset3Name = AppConstants.defaultCustomPresetDisplayNames[2]
    @AppStorage(AppConstants.customPreset4NameKey) private var customPreset4Name = AppConstants.defaultCustomPresetDisplayNames[3]
    @AppStorage(AppConstants.customPreset5NameKey) private var customPreset5Name = AppConstants.defaultCustomPresetDisplayNames[4]
    @AppStorage(AppConstants.customPreset6NameKey) private var customPreset6Name = AppConstants.defaultCustomPresetDisplayNames[5]
    @AppStorage(AppConstants.customPreset7NameKey) private var customPreset7Name = AppConstants.defaultCustomPresetDisplayNames[6]
    @AppStorage(AppConstants.customPreset8NameKey) private var customPreset8Name = AppConstants.defaultCustomPresetDisplayNames[7]
    @AppStorage(AppConstants.customPreset9NameKey) private var customPreset9Name = AppConstants.defaultCustomPresetDisplayNames[8]
    @AppStorage(AppConstants.customPreset10NameKey) private var customPreset10Name = AppConstants.defaultCustomPresetDisplayNames[9]
    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted
    @AppStorage(AppConstants.watchFolderModeKey) private var watchFolderModeEnabled = false
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @StateObject private var watchFolderCoordinator = WatchFolderCoordinator()
    @State private var mergeClipsEnabled = false
    @State private var mergeClipsAvailable = false
    @State private var mergeClipsTooltip = "Add at least two compatible clips to enable merging."
    @State private var mergeCompatibilityTask: Task<Void, Never>? = nil
    
    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var showUpdateNotification = false
    @State private var updateNotificationTask: Task<Void, Never>?
    
    // Keyboard shortcut sheet states - using optional UUID directly for item-based sheet presentation
    // When non-nil, the corresponding sheet is presented. Set to nil to dismiss.
    @State private var trimSheetItemID: UUID?
    @State private var trimWithCropSheetItemID: UUID?
    @State private var timecodeSheetItemID: UUID?
    @State private var audioConfigSheetItemID: UUID?
    @State private var metadataSheetItemID: UUID?
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        AppConstants.supportedVideoTypes.compactMap { UTType($0) }
    }
    
    // Only allow starting conversion when at least one item is still waiting
    private var canStartConversion: Bool {
        droppedFiles.contains { $0.status == .waiting }
    }

    private var hasResettableItems: Bool {
        droppedFiles.contains { $0.status != .waiting }
    }

    private var fileListView: some View {
        VideoFileListView(
            droppedFiles: $droppedFiles,
            currentProgress: $overallProgress,
            onFileImport: { isFileImporterPresented = true },
            onDoubleClick: { isFileImporterPresented = true },
            onDelete: handleFileDeletion,
            onReset: handleFileReset,
            preset: selectedPreset,
            mergeClipsEnabled: mergeClipsEnabled,
            mergeClipsAvailable: mergeClipsAvailable,
            onOpenTrim: { id in
                // Verify the item exists before presenting the sheet
                guard droppedFiles.contains(where: { $0.id == id }) else { return }
                trimSheetItemID = id
            },
            onOpenTrimWithCrop: { id in
                guard droppedFiles.contains(where: { $0.id == id }) else { return }
                trimWithCropSheetItemID = id
            },
            onOpenTimecode: { id in
                guard droppedFiles.contains(where: { $0.id == id }) else { return }
                timecodeSheetItemID = id
            },
            onOpenAudioConfig: { id in
                guard droppedFiles.contains(where: { $0.id == id }) else { return }
                audioConfigSheetItemID = id
            },
            onOpenMetadata: { id in
                guard droppedFiles.contains(where: { $0.id == id }) else { return }
                metadataSheetItemID = id
            },
            onToggleDateTag: { index in
                droppedFiles[index].includeDateTag.toggle()
            },
            onPlayFullscreen: { id in
                if let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                    FullscreenPlayerWindowController.shared.openFullscreenPlayer(for: droppedFiles[index])
                }
            }
        )
    }

    private func handleFileDeletion(_ indexSet: IndexSet) {
        // Clean up cache for removed items
        for index in indexSet {
            if index < droppedFiles.count {
                let fileURL = droppedFiles[index].url
                Task {
                    await PreviewAssetGenerator.shared.cleanupAssets(for: fileURL)
                }
            }
        }
        droppedFiles.remove(atOffsets: indexSet)
    }

    private func handleFileReset(_ index: Int, optionKeyPressed: Bool = false) {
        if index < droppedFiles.count {
            droppedFiles[index].status = .waiting
            droppedFiles[index].progress = 0.0
            droppedFiles[index].eta = nil
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
            droppedFiles[index].outputFileSizeBytes = nil

            // Determine whether to clear settings based on preference and Option key
            let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
            let shouldClearSettings = optionKeyPressed ? !resetClearsSettings : resetClearsSettings

            // Reset configurations if needed
            if shouldClearSettings {
                droppedFiles[index].audioRoutingConfig = nil
                droppedFiles[index].cropConfig = nil
                droppedFiles[index].timecodeConfig = nil
                droppedFiles[index].trimStart = nil
                droppedFiles[index].trimEnd = nil
                droppedFiles[index].isMuted = false
            }
        }
    }

    var body: some View {
        VStack {
            fileListView
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: supportedVideoTypes,
                allowsMultipleSelection: true
            ) { result in
                handleFileSelection(result: result)
            }
            .task {
                await startProgressUpdates()
            }
            .toolbar {
                conversionToolbar
            }
            
            // Overall progress bar
            if isConverting {
                OverallProgressView(progress: overallProgress)
            }
        }
        .overlay(alignment: .bottom) {
            if showUpdateNotification {
                UpdateNotificationView(
                    latestVersion: updateChecker.latestVersion,
                    onDownload: {
                        updateChecker.openDownloadPage()
                        withAnimation {
                            showUpdateNotification = false
                        }
                    },
                    onDismiss: {
                        withAnimation {
                            showUpdateNotification = false
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 760)
        // Sheets for keyboard shortcuts - using item-based presentation to ensure content is always valid
        .sheet(isPresented: sheetBinding(for: $trimSheetItemID)) {
            if let id = trimSheetItemID,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                PreviewPlayerView(item: $droppedFiles[index])
            }
        }
        .sheet(isPresented: sheetBinding(for: $trimWithCropSheetItemID)) {
            if let id = trimWithCropSheetItemID,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                PreviewPlayerView(item: $droppedFiles[index], initialCropExpanded: true)
            }
        }
        .sheet(isPresented: sheetBinding(for: $timecodeSheetItemID)) {
            if let id = timecodeSheetItemID,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                TimecodeView(item: $droppedFiles[index])
            }
        }
        .sheet(isPresented: sheetBinding(for: $audioConfigSheetItemID)) {
            if let id = audioConfigSheetItemID,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                AudioRoutingView(item: $droppedFiles[index], preset: selectedPreset)
            }
        }
        .sheet(isPresented: sheetBinding(for: $metadataSheetItemID)) {
            if let id = metadataSheetItemID,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                VideoMetadataView(item: $droppedFiles[index])
            }
        }
        .background(
            GlobalKeyboardShortcutHandler(
                onToggleWatchFolder: { watchFolderModeEnabled.toggle() },
                onSelectOutputFolder: {
                    Task {
                        if let folder = await selectOutputFolder() {
                            currentOutputFolder = folder
                        }
                    }
                },
                onToggleMerge: {
                    if mergeClipsAvailable {
                        mergeClipsEnabled.toggle()
                    }
                },
                onResetAll: {
                    resetAllFiles()
                }
            )
        )
        .onAppear {
            if !hasInitializedPreset {
                selectedPreset = ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
                hasInitializedPreset = true
                hasUserChangedPreset = false
            }
            let storedFolderURL = URL(fileURLWithPath: outputFolder)
            if storedFolderURL.path != currentOutputFolder.path {
                currentOutputFolder = storedFolderURL
            } else {
                refreshExpectedOutputURLs(for: selectedPreset)
            }
            Task {
                isConverting = await ConversionManager.shared.isConvertingStatus()
            }
            scheduleMergeCompatibilityEvaluation()
            
            // Check for updates
            updateChecker.checkForUpdatesIfNeeded()
        }
        .onChange(of: updateChecker.updateAvailable) { _, available in
            if available {
                withAnimation {
                    showUpdateNotification = true
                }
                // Auto-dismiss after 10 seconds
                updateNotificationTask?.cancel()
                updateNotificationTask = Task {
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    withAnimation {
                        showUpdateNotification = false
                    }
                }
            }
        }
        .onChange(of: storedDefaultPresetRawValue) { _, newValue in
            selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
            hasUserChangedPreset = false
        }
        .onChange(of: outputFolder) { _, newValue in
            let updatedFolderURL = URL(fileURLWithPath: newValue)
            if updatedFolderURL.path != currentOutputFolder.path {
                currentOutputFolder = updatedFolderURL
            } else {
                refreshExpectedOutputURLs(for: selectedPreset)
            }
        }
        // Listen for menu command
        .onReceive(NotificationCenter.default.publisher(for: .showFileImporter)) { _ in
            isFileImporterPresented = true
        }
        .onChange(of: watchFolderModeEnabled) { _, newValue in
            handleWatchFolderToggle(newValue)
        }
        .onChange(of: droppedFiles) { _, _ in
            if mergeClipsEnabled {
                refreshExpectedOutputURLs(for: selectedPreset)
            }
            scheduleMergeCompatibilityEvaluation()
        }
        .onChange(of: mergeClipsEnabled) { _, _ in
            refreshExpectedOutputURLs(for: selectedPreset)
        }
        .onChange(of: isConverting) { _, _ in
            scheduleMergeCompatibilityEvaluation()
        }
        .onChange(of: droppedFiles.count) { oldCount, newCount in
            if watchFolderModeEnabled && newCount > oldCount {
                scheduleAutoEncode()
            }
        }
        // Listen for App Intent to enqueue file(s)
        .onReceive(NotificationCenter.default.publisher(for: .enqueueFileURL)) { notification in
            // Support both single URL and array of URLs
            let urls: [URL]
            if let singleURL = notification.object as? URL {
                urls = [singleURL]
            } else if let multipleURLs = notification.object as? [URL] {
                urls = multipleURLs
            } else {
                return
            }

            for url in urls {
                // Check for duplicates before creating placeholder
                guard !droppedFiles.contains(where: { $0.url == url }) else { continue }

                guard let placeholder = VideoFileUtils.makePlaceholderItem(
                    from: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset
                ) else {
                    print("Skipping unsupported file from AppIntent: \(url.lastPathComponent)")
                    continue
                }

                droppedFiles.append(placeholder)
                // Auto-mute if VideoLoop preset is selected and setting is enabled
                if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                    droppedFiles[droppedFiles.count - 1].isMuted = true
                }
                let placeholderID = placeholder.id

                // Load details asynchronously in background
                Task(priority: .utility) {
                    let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                    let durationSeconds = details.durationSeconds
                    let metadata = await VideoFileUtils.fetchMetadata(for: url)

                    await MainActor.run {
                        if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                            self.droppedFiles[index].apply(details: details)
                            self.droppedFiles[index].detailsLoaded = true
                            self.droppedFiles[index].metadata = metadata

                            let effectiveDuration = self.droppedFiles[index].durationSeconds
                            let durationForPrefetch = effectiveDuration > 0 ? effectiveDuration : durationSeconds
                            if durationForPrefetch > 0 {
                                VideoFileUtils.prefetchPreviewAssets(
                                    for: url,
                                    durationSeconds: durationForPrefetch
                                )
                            }
                        }
                    }
                }
            }
        }
        // Handle ConvertImmediatelyIntent
        .onReceive(NotificationCenter.default.publisher(for: .convertImmediately)) { notification in
            guard let info = notification.userInfo,
                  let folderURL = info["outputFolderURL"] as? URL else { return }

            // Support both single URL and array of URLs
            let fileURLs: [URL]
            if let singleURL = info["fileURL"] as? URL {
                fileURLs = [singleURL]
            } else if let multipleURLs = info["fileURLs"] as? [URL] {
                fileURLs = multipleURLs
            } else {
                return
            }

            Task {
                // Update output folder to match source directory
                await MainActor.run {
                    currentOutputFolder = folderURL
                    outputFolder = folderURL.path
                }

                for fileURL in fileURLs {
                    if var videoItem = await VideoFileUtils.createVideoItem(
                        from: fileURL,
                        outputFolder: folderURL.path,
                        preset: selectedPreset
                    ) {
                        await MainActor.run {
                            if !droppedFiles.contains(where: { $0.url == videoItem.url }) {
                                // Auto-mute if VideoLoop preset is selected and setting is enabled
                                if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                                    videoItem.isMuted = true
                                }
                                droppedFiles.append(videoItem)
                            }
                        }
                    }
                }
                await startConversion()
            }
        }
    }

    // Helper function for folder selection
    @MainActor
    private func selectOutputFolder() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        // Set the starting directory to the current output folder if it exists
        if FileManager.default.fileExists(atPath: currentOutputFolder.path) {
            panel.directoryURL = currentOutputFolder
        }
        
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        
        if response == .OK, let url = panel.url {
            // Ensure the directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        return nil
    }
    
    // Handle file selection from file picker
    private func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                // Check for duplicates before creating placeholder
                guard !droppedFiles.contains(where: { $0.url == url }) else {
                    continue
                }

                guard let placeholder = VideoFileUtils.makePlaceholderItem(
                    from: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset
                ) else {
                    print("Skipping unsupported file: \(url.lastPathComponent)")
                    continue
                }

                droppedFiles.append(placeholder)
                // Auto-mute if VideoLoop preset is selected and setting is enabled
                if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                    droppedFiles[droppedFiles.count - 1].isMuted = true
                }
                let placeholderID = placeholder.id

            // Load details asynchronously in background
            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                let durationSeconds = details.durationSeconds
                let metadata = await VideoFileUtils.fetchMetadata(for: url)

                await MainActor.run {
                    if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        self.droppedFiles[index].apply(details: details)
                        self.droppedFiles[index].detailsLoaded = true
                        self.droppedFiles[index].metadata = metadata

                        let effectiveDuration = self.droppedFiles[index].durationSeconds
                        let durationForPrefetch = effectiveDuration > 0 ? effectiveDuration : durationSeconds
                        if durationForPrefetch > 0 {
                            VideoFileUtils.prefetchPreviewAssets(
                                for: url,
                                durationSeconds: durationForPrefetch
                            )
                        }
                    }
                }
            }
            }
        case .failure(let error):
            print("Error selecting files: \(error.localizedDescription)")
        }
    }
    
    private func startProgressUpdates() async {
        progressTask?.cancel()
        progressTask = Task {
            for await progress in await ConversionManager.shared.progressUpdates() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    overallProgress = progress
                    dockProgressUpdater.updateProgress(progress)
                    // Automatically reset converting state when done
                    if progress >= 1.0 {
                        isConverting = false
                    }
                }
            }
        }
    }
    
    @MainActor
    private func startConversion() async {
        isConverting = true
        // Initialize dock progress with 0% to show it immediately
        dockProgressUpdater.updateProgress(0.0)

        await ConversionManager.shared.startConversion(
                droppedFiles: $droppedFiles,
                outputFolder: currentOutputFolder.path,
                preset: selectedPreset,
                mergeClipsEnabled: mergeClipsEnabled
            )
        watchFolderCoordinator.startConversion()
    }

    @MainActor
    private func cancelConversion() async {
        await ConversionManager.shared.cancelAllConversions()
        isConverting = false
        // Reset dock progress immediately on cancel
        dockProgressUpdater.reset()
        watchFolderCoordinator.cancelConversion()
    }
    
    private func refreshExpectedOutputURLs(for preset: ExportPreset) {
        for index in droppedFiles.indices where droppedFiles[index].status == .waiting {
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: preset)
        }
    }

    private func displayName(for preset: ExportPreset) -> String {
        guard let slot = preset.customSlotIndex else {
            return preset.displayName
        }
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = fallbackSuffixes.indices.contains(slot) ? fallbackSuffixes[slot] : "Custom Preset"
        let storedSuffix: String
        switch slot {
        case 0: storedSuffix = customPreset1Name
        case 1: storedSuffix = customPreset2Name
        case 2: storedSuffix = customPreset3Name
        case 3: storedSuffix = customPreset4Name
        case 4: storedSuffix = customPreset5Name
        case 5: storedSuffix = customPreset6Name
        case 6: storedSuffix = customPreset7Name
        case 7: storedSuffix = customPreset8Name
        case 8: storedSuffix = customPreset9Name
        case 9: storedSuffix = customPreset10Name
        default: storedSuffix = fallbackSuffix
        }
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, prefix: prefix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let remainder = trimmed[cutoff...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let remainder = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        return trimmed
    }

    /// Creates a Binding<Bool> from a Binding<UUID?> for sheet presentation.
    /// The sheet is presented when the UUID is non-nil, and dismissing sets it to nil.
    private func sheetBinding(for itemID: Binding<UUID?>) -> Binding<Bool> {
        Binding(
            get: { itemID.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    itemID.wrappedValue = nil
                }
            }
        )
    }

    private func expectedOutputURL(for item: VideoItem, preset: ExportPreset) -> URL? {
        if mergeClipsEnabled && mergeClipsAvailable, let mergedURL = mergedOutputURL(for: preset) {
            return mergedURL
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(item.url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: item.url)
        let outputFileName = sanitizedBaseName + preset.fileSuffix + "." + resolvedExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private func mergedOutputURL(for preset: ExportPreset) -> URL? {
        guard let referenceItem = droppedFiles.first(where: { $0.status == .waiting }) else {
            return nil
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(referenceItem.url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: referenceItem.url)
        let outputFileName = sanitizedBaseName + preset.fileSuffix + "_merge" + "." + resolvedExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private var toolbarPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                let oldValue = selectedPreset
                hasUserChangedPreset = true
                selectedPreset = newValue
                refreshExpectedOutputURLs(for: newValue)
                scheduleMergeCompatibilityEvaluation()

                // Auto-mute items when switching to VideoLoop preset if the setting is enabled
                if newValue == .videoLoop && videoLoopDefaultMuted {
                    for index in droppedFiles.indices where droppedFiles[index].status == .waiting {
                        droppedFiles[index].isMuted = true
                    }
                }
                // Auto-unmute items when switching away from a preset that forces mute
                else if oldValue == .videoLoop && newValue != .videoLoop {
                    for index in droppedFiles.indices where droppedFiles[index].status == .waiting {
                        droppedFiles[index].isMuted = false
                    }
                }
            }
        )
    }

    private var conversionToolbar: some ToolbarContent {
        ConversionToolbarView(
            isConverting: isConverting,
            canStartConversion: canStartConversion,
            hasFiles: !droppedFiles.isEmpty,
            watchFolderModeEnabled: $watchFolderModeEnabled,
            watchFolderPath: watchFolderPath,
            selectedPreset: toolbarPresetBinding,
            presets: ExportPreset.allCases,
            displayName: { displayName(for: $0) },
            mergeClipsEnabled: $mergeClipsEnabled,
            mergeClipsAvailable: mergeClipsAvailable,
            onToggleConversion: handleConversionToggle,
            onImport: { isFileImporterPresented = true },
            onResetAll: resetAllFiles,
            hasResettableItems: hasResettableItems,
            onClear: clearAllFiles
        )
    }
    
    // MARK: - Watch Folder Management
    
    @MainActor
    private func addFilesFromWatchFolder(_ urls: [URL]) async {
        for url in urls {
            // Check if file already exists in the list
            guard !droppedFiles.contains(where: { $0.url == url }) else {
                continue
            }

            guard let placeholder = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: selectedPreset
            ) else {
                print("Skipping unsupported file from watch folder: \(url.lastPathComponent)")
                continue
            }

            droppedFiles.append(placeholder)
            // Auto-mute if VideoLoop preset is selected and setting is enabled
            if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                droppedFiles[droppedFiles.count - 1].isMuted = true
            }
            let placeholderID = placeholder.id

            // Load details asynchronously in background
            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                let durationSeconds = details.durationSeconds
                let metadata = await VideoFileUtils.fetchMetadata(for: url)

                await MainActor.run {
                    if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        self.droppedFiles[index].apply(details: details)
                        self.droppedFiles[index].detailsLoaded = true
                        self.droppedFiles[index].metadata = metadata

                        let effectiveDuration = self.droppedFiles[index].durationSeconds
                        let durationForPrefetch = effectiveDuration > 0 ? effectiveDuration : durationSeconds
                        if durationForPrefetch > 0 {
                            VideoFileUtils.prefetchPreviewAssets(
                                for: url,
                                durationSeconds: durationForPrefetch
                            )
                        }
                    }
                }
            }
        }
    }
    
    private func scheduleAutoEncode() {
        Task { @MainActor in
            watchFolderCoordinator.scheduleAutoEncode {
                let shouldStart = await MainActor.run { !isConverting && canStartConversion }
                if shouldStart {
                    await evaluateMergeClipsState()
                    await startConversion()
                }
            }
        }
    }

    private func scheduleMergeCompatibilityEvaluation() {
        mergeCompatibilityTask?.cancel()
        mergeCompatibilityTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await evaluateMergeClipsState()
        }
    }

    @MainActor
    private func evaluateMergeClipsState() async {
        mergeCompatibilityTask = nil

        if isConverting {
            mergeClipsAvailable = false
            mergeClipsEnabled = false
            mergeClipsTooltip = "Cannot toggle merging while conversion is running."
            return
        }

        let result = await ConversionManager.shared.evaluateMergeCompatibility(for: droppedFiles, preset: selectedPreset)

        switch result {
        case .compatible:
            let waitingCount = droppedFiles.filter { $0.status == .waiting }.count
            mergeClipsAvailable = true
            mergeClipsTooltip = mergeClipsEnabled ? "Clips will be merged into a single export." : "Enable to merge \(waitingCount) compatible clips into one export."
        case .cancelled:
            return
        default:
            mergeClipsAvailable = false
            mergeClipsEnabled = false
            mergeClipsTooltip = result.tooltip
        }
    }

    @MainActor
    private func promptForWatchFolderSelection() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Watch Folder"
        panel.message = "Choose a folder to watch for new video files"
        if !watchFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: watchFolderPath)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func handleConversionToggle(optionKeyPressed: Bool) {
        Task { @MainActor in
            let currentlyConverting = await ConversionManager.shared.isConvertingStatus()
            isConverting = currentlyConverting

            if currentlyConverting {
                await cancelConversion()
                return
            }

            // If Option key is pressed, let user select output folder first
            if optionKeyPressed {
                if let folder = await selectOutputFolder() {
                    currentOutputFolder = folder
                }
                // Start conversion after folder selection (even if cancelled, use current folder)
                await startConversionWithValidation()
            } else {
                await startConversionWithValidation()
            }
        }
    }

    /// Validates output folder and starts conversion, prompting for folder if needed
    @MainActor
    private func startConversionWithValidation() async {
        // Check if "save next to original" is enabled - if so, skip validation
        let saveNextToOriginal = UserDefaults.standard.bool(forKey: AppConstants.saveNextToOriginalKey)

        if !saveNextToOriginal {
            // Validate the current output folder is writable
            let isWritable = isOutputFolderWritable(currentOutputFolder)

            if !isWritable {
                // Prompt user to select a valid folder
                if let folder = await selectOutputFolder() {
                    currentOutputFolder = folder
                } else {
                    // User cancelled, don't start conversion
                    return
                }

                // Verify the newly selected folder is writable
                if !isOutputFolderWritable(currentOutputFolder) {
                    return
                }
            }
        }

        await startConversion()
    }

    /// Checks if a folder exists and is writable
    private func isOutputFolderWritable(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        let path = folder.path

        // Check if folder exists, if not try to create it
        if !fileManager.fileExists(atPath: path) {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        // Check if writable
        return fileManager.isWritableFile(atPath: path)
    }

    @MainActor
    private func clearAllFiles() {
        guard !isConverting else { return }

        for file in droppedFiles {
            Task {
                await PreviewAssetGenerator.shared.cleanupAssets(for: file.url)
            }
        }

        droppedFiles.removeAll()
        overallProgress = 0.0
        dockProgressUpdater.reset()
    }

    private func resetAllFiles(optionKeyPressed: Bool = false) {
        guard !isConverting else { return }

        // Determine whether to clear settings based on preference and Option key
        let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
        let shouldClearSettings = optionKeyPressed ? !resetClearsSettings : resetClearsSettings

        var didReset = false
        for index in droppedFiles.indices where droppedFiles[index].status != .waiting {
            droppedFiles[index].status = .waiting
            droppedFiles[index].progress = 0.0
            droppedFiles[index].eta = nil
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
            droppedFiles[index].outputFileSizeBytes = nil

            // Reset configurations if needed
            if shouldClearSettings {
                droppedFiles[index].audioRoutingConfig = nil
                droppedFiles[index].cropConfig = nil
                droppedFiles[index].timecodeConfig = nil
                droppedFiles[index].trimStart = nil
                droppedFiles[index].trimEnd = nil
                droppedFiles[index].isMuted = false
            }

            didReset = true
        }

        if didReset {
            overallProgress = 0.0
            dockProgressUpdater.reset()
            scheduleMergeCompatibilityEvaluation()
        }
    }

    private func handleWatchFolderToggle(_ enabled: Bool) {
        Task { @MainActor in
            if enabled {
                let success = await watchFolderCoordinator.enableWatchMode(
                    currentPath: watchFolderPath,
                    promptForFolder: { await promptForWatchFolderSelection() },
                    updatePath: { newPath in
                        Task { @MainActor in
                            watchFolderPath = newPath
                        }
                    },
                    onNewFiles: { urls in await addFilesFromWatchFolder(urls) }
                )

                if !success {
                    watchFolderModeEnabled = false
                }
            } else {
                await watchFolderCoordinator.disableWatchMode()
            }
        }
    }
    

}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(minWidth: 800, minHeight: 400)
    }
}

// MARK: - Global Keyboard Shortcut Handler

private struct GlobalKeyboardShortcutHandler: NSViewRepresentable {
    var onToggleWatchFolder: () -> Void
    var onSelectOutputFolder: () -> Void
    var onToggleMerge: () -> Void
    var onResetAll: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleWatchFolder: onToggleWatchFolder,
            onSelectOutputFolder: onSelectOutputFolder,
            onToggleMerge: onToggleMerge,
            onResetAll: onResetAll
        )
    }
    
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onToggleWatchFolder = onToggleWatchFolder
        context.coordinator.onSelectOutputFolder = onSelectOutputFolder
        context.coordinator.onToggleMerge = onToggleMerge
        context.coordinator.onResetAll = onResetAll
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }
    
    final class Coordinator {
        var onToggleWatchFolder: () -> Void
        var onSelectOutputFolder: () -> Void
        var onToggleMerge: () -> Void
        var onResetAll: () -> Void
        private var monitor: Any?
        
        init(
            onToggleWatchFolder: @escaping () -> Void,
            onSelectOutputFolder: @escaping () -> Void,
            onToggleMerge: @escaping () -> Void,
            onResetAll: @escaping () -> Void
        ) {
            self.onToggleWatchFolder = onToggleWatchFolder
            self.onSelectOutputFolder = onSelectOutputFolder
            self.onToggleMerge = onToggleMerge
            self.onResetAll = onResetAll
        }
        
        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                
                let hasCommand = event.modifierFlags.contains(.command)
                let hasOption = event.modifierFlags.contains(.option)
                let hasShift = event.modifierFlags.contains(.shift)
                let hasControl = event.modifierFlags.contains(.control)
                
                // Option+W: Toggle Watch Folder
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_W {
                    self.onToggleWatchFolder()
                    return nil
                }
                
                // Option+F: Select Output Folder
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_F {
                    self.onSelectOutputFolder()
                    return nil
                }
                
                // Option+M: Toggle Merge
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_M {
                    self.onToggleMerge()
                    return nil
                }
                
                // Cmd+Shift+R: Reset All
                if hasCommand && hasShift && !hasOption && !hasControl && event.keyCode == kVK_ANSI_R {
                    self.onResetAll()
                    return nil
                }
                
                return event
            }
        }
        
        func teardown() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
