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

    // Preset visibility (built-in presets)
    @AppStorage(AppConstants.videoLoopVisibleKey) private var videoLoopVisible = true
    @AppStorage(AppConstants.videoLoopWithSoundVisibleKey) private var videoLoopWithSoundVisible = true
    @AppStorage(AppConstants.animatedStillVisibleKey) private var animatedStillVisible = true
    @AppStorage(AppConstants.h264VisibleKey) private var h264Visible = true
    @AppStorage(AppConstants.h265VisibleKey) private var h265Visible = true
    @AppStorage(AppConstants.av1VisibleKey) private var av1Visible = true
    @AppStorage(AppConstants.tvHEVCVisibleKey) private var tvHEVCVisible = true
    @AppStorage(AppConstants.tvAVCIntraVisibleKey) private var tvAVCIntraVisible = true
    @AppStorage(AppConstants.proresVisibleKey) private var proresVisible = true
    @AppStorage(AppConstants.proxyVisibleKey) private var proxyVisible = true
    @AppStorage(AppConstants.streamCopyVisibleKey) private var streamCopyVisible = true
    @AppStorage(AppConstants.audioWAVVisibleKey) private var audioWAVVisible = true
    @AppStorage(AppConstants.audioAACVisibleKey) private var audioAACVisible = true

    // Custom preset activation
    @AppStorage(AppConstants.customPreset1ActiveKey) private var customPreset1Active = false
    @AppStorage(AppConstants.customPreset2ActiveKey) private var customPreset2Active = false
    @AppStorage(AppConstants.customPreset3ActiveKey) private var customPreset3Active = false
    @AppStorage(AppConstants.customPreset4ActiveKey) private var customPreset4Active = false
    @AppStorage(AppConstants.customPreset5ActiveKey) private var customPreset5Active = false
    @AppStorage(AppConstants.customPreset6ActiveKey) private var customPreset6Active = false
    @AppStorage(AppConstants.customPreset7ActiveKey) private var customPreset7Active = false
    @AppStorage(AppConstants.customPreset8ActiveKey) private var customPreset8Active = false
    @AppStorage(AppConstants.customPreset9ActiveKey) private var customPreset9Active = false
    @AppStorage(AppConstants.customPreset10ActiveKey) private var customPreset10Active = false

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
    @State private var metadataSheetItemIDs: [UUID]?
    
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

    /// Presets that are currently visible in the picker, computed from @AppStorage values
    /// This ensures SwiftUI reactively updates the picker when visibility settings change
    private var visiblePresets: [ExportPreset] {
        ExportPreset.allCases.filter { preset in
            switch preset {
            case .videoLoop: return videoLoopVisible
            case .videoLoopWithSound: return videoLoopWithSoundVisible
            case .animatedStill: return animatedStillVisible
            case .h264: return h264Visible
            case .h265: return h265Visible
            case .av1: return av1Visible
            case .tvHEVC: return tvHEVCVisible
            case .tvAVCIntra: return tvAVCIntraVisible
            case .prores: return proresVisible
            case .proxy: return proxyVisible
            case .streamCopy: return streamCopyVisible
            case .audioUncompressedWAV: return audioWAVVisible
            case .audioStereoAAC: return audioAACVisible
            case .custom1: return customPreset1Active
            case .custom2: return customPreset2Active
            case .custom3: return customPreset3Active
            case .custom4: return customPreset4Active
            case .custom5: return customPreset5Active
            case .custom6: return customPreset6Active
            case .custom7: return customPreset7Active
            case .custom8: return customPreset8Active
            case .custom9: return customPreset9Active
            case .custom10: return customPreset10Active
            }
        }
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
            onOpenMetadata: { ids in
                let validIDs = ids.filter { id in droppedFiles.contains(where: { $0.id == id }) }
                guard !validIDs.isEmpty else { return }
                metadataSheetItemIDs = validIDs
            },
            onToggleDateTag: { index in
                droppedFiles[index].includeDateTag.toggle()
            },
            onPlayFullscreen: { id in
                if let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                    FullscreenPlayerWindowController.shared.openFullscreenPlayer(
                        for: droppedFiles[index],
                        in: droppedFiles
                    )
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
                // Also reset comment and date tag to defaults
                droppedFiles[index].comment = ""
                droppedFiles[index].includeDateTag = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)
            }
        }
    }

    var body: some View {
        mainContentView
            .overlay(alignment: .bottom) { updateNotificationOverlay }
            .frame(minWidth: 780)
            .modifier(ContentViewSheets(
                droppedFiles: $droppedFiles,
                trimSheetItemID: $trimSheetItemID,
                trimWithCropSheetItemID: $trimWithCropSheetItemID,
                timecodeSheetItemID: $timecodeSheetItemID,
                audioConfigSheetItemID: $audioConfigSheetItemID,
                metadataSheetItemIDs: $metadataSheetItemIDs,
                selectedPreset: selectedPreset
            ))
            .background(keyboardShortcutHandler)
            .modifier(ContentViewLifecycle(
                hasInitializedPreset: $hasInitializedPreset,
                hasUserChangedPreset: $hasUserChangedPreset,
                selectedPreset: $selectedPreset,
                currentOutputFolder: $currentOutputFolder,
                isConverting: $isConverting,
                storedDefaultPresetRawValue: storedDefaultPresetRawValue,
                outputFolder: outputFolder,
                scheduleMergeCompatibilityEvaluation: scheduleMergeCompatibilityEvaluation,
                refreshExpectedOutputURLs: refreshExpectedOutputURLs,
                updateChecker: updateChecker
            ))
            .modifier(ContentViewChangeHandlers(
                showUpdateNotification: $showUpdateNotification,
                updateNotificationTask: $updateNotificationTask,
                selectedPreset: $selectedPreset,
                hasUserChangedPreset: $hasUserChangedPreset,
                currentOutputFolder: $currentOutputFolder,
                isFileImporterPresented: $isFileImporterPresented,
                mergeClipsEnabled: mergeClipsEnabled,
                watchFolderModeEnabled: watchFolderModeEnabled,
                isConverting: isConverting,
                droppedFilesCount: droppedFiles.count,
                updateChecker: updateChecker,
                outputFolder: outputFolder,
                storedDefaultPresetRawValue: storedDefaultPresetRawValue,
                refreshExpectedOutputURLs: refreshExpectedOutputURLs,
                scheduleMergeCompatibilityEvaluation: scheduleMergeCompatibilityEvaluation,
                handleWatchFolderToggle: handleWatchFolderToggle,
                scheduleAutoEncode: scheduleAutoEncode
            ))
            .onChange(of: droppedFiles) { _, _ in
                if mergeClipsEnabled {
                    refreshExpectedOutputURLs(for: selectedPreset)
                }
                scheduleMergeCompatibilityEvaluation()
            }
            .modifier(ContentViewNotificationHandlers(
                droppedFiles: $droppedFiles,
                currentOutputFolder: $currentOutputFolder,
                outputFolder: $outputFolder,
                selectedPreset: selectedPreset,
                videoLoopDefaultMuted: videoLoopDefaultMuted,
                startConversion: startConversion
            ))
    }

    // MARK: - Body Subviews

    private var mainContentView: some View {
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

            if isConverting {
                OverallProgressView(progress: overallProgress)
            }
        }
    }

    @ViewBuilder
    private var updateNotificationOverlay: some View {
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

    private var keyboardShortcutHandler: some View {
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
            },
            onToggleConversion: handleConversionToggle
        )
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
            // Save a writable bookmark for persistent sandbox access
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
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
                let metadata = await VideoFileUtils.fetchMetadata(for: url)

                await MainActor.run {
                    if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        self.droppedFiles[index].apply(details: details)
                        self.droppedFiles[index].detailsLoaded = true
                        self.droppedFiles[index].metadata = metadata

                        VideoFileUtils.prefetchPreviewAssets(for: url)
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

    /// Creates a Binding<Bool> for metadata sheet presentation (supports multiple items).
    private var metadataSheetBinding: Binding<Bool> {
        Binding(
            get: { metadataSheetItemIDs != nil && !metadataSheetItemIDs!.isEmpty },
            set: { isPresented in
                if !isPresented {
                    metadataSheetItemIDs = nil
                }
            }
        )
    }

    /// Content for the metadata sheet - shows single item or comparison view.
    @ViewBuilder
    private var metadataSheetContent: some View {
        if let ids = metadataSheetItemIDs {
            if ids.count == 1,
               let id = ids.first,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                VideoMetadataView(item: $droppedFiles[index])
            } else {
                // Sort items by their position in the queue for consistent display order
                let sortedItems = droppedFiles.filter { ids.contains($0.id) }
                MetadataComparisonView(items: sortedItems)
            }
        }
    }

    private func expectedOutputURL(for item: VideoItem, preset: ExportPreset) -> URL? {
        if mergeClipsEnabled && mergeClipsAvailable, let mergedURL = mergedOutputURL(for: preset) {
            return mergedURL
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(item.url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: item.url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        let outputFileName = sanitizedBaseName + suffixPart + "." + resolvedExtension
        return currentOutputFolder.appendingPathComponent(outputFileName)
    }

    private func mergedOutputURL(for preset: ExportPreset) -> URL? {
        guard let referenceItem = droppedFiles.first(where: { $0.status == .waiting }) else {
            return nil
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(referenceItem.url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: referenceItem.url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        let outputFileName = sanitizedBaseName + suffixPart + "_merge" + "." + resolvedExtension
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
            presets: visiblePresets,
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
                let metadata = await VideoFileUtils.fetchMetadata(for: url)

                await MainActor.run {
                    if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        self.droppedFiles[index].apply(details: details)
                        self.droppedFiles[index].detailsLoaded = true
                        self.droppedFiles[index].metadata = metadata

                        VideoFileUtils.prefetchPreviewAssets(for: url)
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
        // Check if "save next to original" is enabled
        let saveNextToOriginal = UserDefaults.standard.bool(forKey: AppConstants.saveNextToOriginalKey)

        if saveNextToOriginal {
            // For "save next to original" mode, validate access to each unique output directory
            let accessGranted = await validateSaveNextToOriginalAccess()
            if !accessGranted {
                return
            }
        } else {
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

    /// Validates that we have write access to all output directories when "save next to original" is enabled.
    /// Prompts the user to grant access to directories we cannot write to.
    /// - Returns: true if all directories are accessible, false if user cancelled
    @MainActor
    private func validateSaveNextToOriginalAccess() async -> Bool {
        let waitingItems = droppedFiles.filter { $0.status == .waiting }
        guard !waitingItems.isEmpty else { return true }

        // Collect unique output directories
        var uniqueDirectories = Set<URL>()
        for item in waitingItems {
            if let outputFolder = VideoFileUtils.resolveOutputFolder(
                for: item.url,
                defaultOutputFolder: currentOutputFolder.path,
                preset: selectedPreset
            ) {
                uniqueDirectories.insert(URL(fileURLWithPath: outputFolder))
            }
        }

        // Check each directory for write access
        var directoriesNeedingAccess: [URL] = []
        for directory in uniqueDirectories {
            // First try: check if writable directly
            if isOutputFolderWritable(directory) {
                continue
            }

            // Second try: try to access via existing bookmark
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: directory) {
                if isOutputFolderWritable(directory) {
                    // Keep the bookmark active - ConversionManager will stop accessing later
                    continue
                }
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: directory)
            }

            // Third try: try parent directory bookmark (for new subdirectories)
            let parentDirectory = directory.deletingLastPathComponent()
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: parentDirectory) {
                // Try to create the directory now that we have parent access
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if isOutputFolderWritable(directory) {
                    // Save a bookmark for this directory too
                    _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: directory)
                    continue
                }
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: parentDirectory)
            }

            // Directory needs user access
            directoriesNeedingAccess.append(directory)
        }

        // Prompt user for access to inaccessible directories
        for directory in directoriesNeedingAccess {
            let granted = await promptForDirectoryAccess(directory)
            if !granted {
                return false
            }
        }

        return true
    }

    /// Prompts the user to grant access to a directory via NSOpenPanel
    /// - Returns: true if access was granted, false if user cancelled
    @MainActor
    private func promptForDirectoryAccess(_ directory: URL) async -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Grant Access"
        panel.message = "Please grant access to save files in:\n\(directory.path)"

        // Try to start at the directory or its parent if it doesn't exist
        if FileManager.default.fileExists(atPath: directory.path) {
            panel.directoryURL = directory
        } else {
            panel.directoryURL = directory.deletingLastPathComponent()
        }

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        if response == .OK, let url = panel.url {
            // User selected a folder - save a writable bookmark
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)

            // If user selected a parent folder, also save bookmark for the target directory
            if url != directory && directory.path.hasPrefix(url.path) {
                // Start accessing the parent, then create and bookmark the target
                if url.startAccessingSecurityScopedResource() {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: directory)
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return true
        }
        return false
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
                // Also reset comment and date tag to defaults
                droppedFiles[index].comment = ""
                droppedFiles[index].includeDateTag = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)
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
    var onToggleConversion: (_ optionKeyPressed: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleWatchFolder: onToggleWatchFolder,
            onSelectOutputFolder: onSelectOutputFolder,
            onToggleMerge: onToggleMerge,
            onResetAll: onResetAll,
            onToggleConversion: onToggleConversion
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
        context.coordinator.onToggleConversion = onToggleConversion
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }
    
    final class Coordinator {
        var onToggleWatchFolder: () -> Void
        var onSelectOutputFolder: () -> Void
        var onToggleMerge: () -> Void
        var onResetAll: () -> Void
        var onToggleConversion: (_ optionKeyPressed: Bool) -> Void
        private var monitor: Any?

        init(
            onToggleWatchFolder: @escaping () -> Void,
            onSelectOutputFolder: @escaping () -> Void,
            onToggleMerge: @escaping () -> Void,
            onResetAll: @escaping () -> Void,
            onToggleConversion: @escaping (_ optionKeyPressed: Bool) -> Void
        ) {
            self.onToggleWatchFolder = onToggleWatchFolder
            self.onSelectOutputFolder = onSelectOutputFolder
            self.onToggleMerge = onToggleMerge
            self.onResetAll = onResetAll
            self.onToggleConversion = onToggleConversion
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

                // Cmd+Return: Start/Stop Conversion
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_Return {
                    self.onToggleConversion(false)
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

// MARK: - Content View Modifiers

/// ViewModifier for all sheet presentations
private struct ContentViewSheets: ViewModifier {
    @Binding var droppedFiles: [VideoItem]
    @Binding var trimSheetItemID: UUID?
    @Binding var trimWithCropSheetItemID: UUID?
    @Binding var timecodeSheetItemID: UUID?
    @Binding var audioConfigSheetItemID: UUID?
    @Binding var metadataSheetItemIDs: [UUID]?
    let selectedPreset: ExportPreset

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding(for: $trimSheetItemID)) {
                trimSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $trimWithCropSheetItemID)) {
                trimWithCropSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $timecodeSheetItemID)) {
                timecodeSheetContent
            }
            .sheet(isPresented: sheetBinding(for: $audioConfigSheetItemID)) {
                audioConfigSheetContent
            }
            .sheet(isPresented: metadataSheetBinding) {
                metadataSheetContent
            }
    }

    @ViewBuilder
    private var trimSheetContent: some View {
        if let id = trimSheetItemID,
           let index = droppedFiles.firstIndex(where: { $0.id == id }) {
            PreviewPlayerView(item: $droppedFiles[index])
        }
    }

    @ViewBuilder
    private var trimWithCropSheetContent: some View {
        if let id = trimWithCropSheetItemID,
           let index = droppedFiles.firstIndex(where: { $0.id == id }) {
            PreviewPlayerView(item: $droppedFiles[index], initialCropExpanded: true)
        }
    }

    @ViewBuilder
    private var timecodeSheetContent: some View {
        if let id = timecodeSheetItemID,
           let index = droppedFiles.firstIndex(where: { $0.id == id }) {
            TimecodeView(item: $droppedFiles[index])
        }
    }

    @ViewBuilder
    private var audioConfigSheetContent: some View {
        if let id = audioConfigSheetItemID,
           let index = droppedFiles.firstIndex(where: { $0.id == id }) {
            AudioRoutingView(item: $droppedFiles[index], preset: selectedPreset)
        }
    }

    @ViewBuilder
    private var metadataSheetContent: some View {
        if let ids = metadataSheetItemIDs {
            if ids.count == 1,
               let id = ids.first,
               let index = droppedFiles.firstIndex(where: { $0.id == id }) {
                VideoMetadataView(item: $droppedFiles[index])
            } else {
                let sortedItems = droppedFiles.filter { ids.contains($0.id) }
                MetadataComparisonView(items: sortedItems)
            }
        }
    }

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

    private var metadataSheetBinding: Binding<Bool> {
        Binding(
            get: { metadataSheetItemIDs != nil && !(metadataSheetItemIDs?.isEmpty ?? true) },
            set: { isPresented in
                if !isPresented {
                    metadataSheetItemIDs = nil
                }
            }
        )
    }
}

/// ViewModifier for onAppear lifecycle
private struct ContentViewLifecycle: ViewModifier {
    @Binding var hasInitializedPreset: Bool
    @Binding var hasUserChangedPreset: Bool
    @Binding var selectedPreset: ExportPreset
    @Binding var currentOutputFolder: URL
    @Binding var isConverting: Bool
    let storedDefaultPresetRawValue: String
    let outputFolder: String
    let scheduleMergeCompatibilityEvaluation: () -> Void
    let refreshExpectedOutputURLs: (ExportPreset) -> Void
    let updateChecker: UpdateChecker

    func body(content: Content) -> some View {
        content
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
                    refreshExpectedOutputURLs(selectedPreset)
                }
                Task {
                    isConverting = await ConversionManager.shared.isConvertingStatus()
                }
                scheduleMergeCompatibilityEvaluation()
                updateChecker.checkForUpdatesIfNeeded()
            }
    }
}

/// ViewModifier for onChange handlers
private struct ContentViewChangeHandlers: ViewModifier {
    @Binding var showUpdateNotification: Bool
    @Binding var updateNotificationTask: Task<Void, Never>?
    @Binding var selectedPreset: ExportPreset
    @Binding var hasUserChangedPreset: Bool
    @Binding var currentOutputFolder: URL
    @Binding var isFileImporterPresented: Bool
    let mergeClipsEnabled: Bool
    let watchFolderModeEnabled: Bool
    let isConverting: Bool
    let droppedFilesCount: Int
    let updateChecker: UpdateChecker
    let outputFolder: String
    let storedDefaultPresetRawValue: String
    let refreshExpectedOutputURLs: (ExportPreset) -> Void
    let scheduleMergeCompatibilityEvaluation: () -> Void
    let handleWatchFolderToggle: (Bool) -> Void
    let scheduleAutoEncode: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: updateChecker.updateAvailable) { _, available in
                handleUpdateAvailable(available)
            }
            .onChange(of: storedDefaultPresetRawValue) { _, newValue in
                selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
                hasUserChangedPreset = false
            }
            .onChange(of: outputFolder) { _, newValue in
                handleOutputFolderChange(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showFileImporter)) { _ in
                isFileImporterPresented = true
            }
            .onChange(of: watchFolderModeEnabled) { _, newValue in
                handleWatchFolderToggle(newValue)
            }
            .onChange(of: mergeClipsEnabled) { _, _ in
                refreshExpectedOutputURLs(selectedPreset)
            }
            .onChange(of: isConverting) { _, _ in
                scheduleMergeCompatibilityEvaluation()
            }
            .onChange(of: droppedFilesCount) { oldCount, newCount in
                if watchFolderModeEnabled && newCount > oldCount {
                    scheduleAutoEncode()
                }
            }
    }

    private func handleUpdateAvailable(_ available: Bool) {
        if available {
            withAnimation {
                showUpdateNotification = true
            }
            updateNotificationTask?.cancel()
            updateNotificationTask = Task {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                withAnimation {
                    showUpdateNotification = false
                }
            }
        }
    }

    private func handleOutputFolderChange(_ newValue: String) {
        let updatedFolderURL = URL(fileURLWithPath: newValue)
        if updatedFolderURL.path != currentOutputFolder.path {
            currentOutputFolder = updatedFolderURL
        } else {
            refreshExpectedOutputURLs(selectedPreset)
        }
    }
}

/// ViewModifier for notification handlers (enqueue and convert immediately)
private struct ContentViewNotificationHandlers: ViewModifier {
    @Binding var droppedFiles: [VideoItem]
    @Binding var currentOutputFolder: URL
    @Binding var outputFolder: String
    let selectedPreset: ExportPreset
    let videoLoopDefaultMuted: Bool
    let startConversion: () async -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .enqueueFileURL)) { notification in
                handleEnqueueNotification(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .convertImmediately)) { notification in
                handleConvertImmediatelyNotification(notification)
            }
    }

    private func handleEnqueueNotification(_ notification: Notification) {
        let urls: [URL]
        if let singleURL = notification.object as? URL {
            urls = [singleURL]
        } else if let multipleURLs = notification.object as? [URL] {
            urls = multipleURLs
        } else {
            return
        }

        for url in urls {
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
            if selectedPreset == .videoLoop && videoLoopDefaultMuted {
                droppedFiles[droppedFiles.count - 1].isMuted = true
            }
            let placeholderID = placeholder.id

            Task(priority: .utility) {
                let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: selectedPreset)
                let metadata = await VideoFileUtils.fetchMetadata(for: url)

                await MainActor.run {
                    if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        droppedFiles[index].apply(details: details)
                        droppedFiles[index].detailsLoaded = true
                        droppedFiles[index].metadata = metadata
                        VideoFileUtils.prefetchPreviewAssets(for: url)
                    }
                }
            }
        }
    }

    private func handleConvertImmediatelyNotification(_ notification: Notification) {
        guard let info = notification.userInfo,
              let folderURL = info["outputFolderURL"] as? URL else { return }

        let fileURLs: [URL]
        if let singleURL = info["fileURL"] as? URL {
            fileURLs = [singleURL]
        } else if let multipleURLs = info["fileURLs"] as? [URL] {
            fileURLs = multipleURLs
        } else {
            return
        }

        Task {
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
