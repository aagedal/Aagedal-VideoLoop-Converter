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

private final class MergeCompatibilityScheduler: ObservableObject {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func schedule(after delayNanoseconds: UInt64 = 200_000_000, action: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await action()
        }
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
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
    @AppStorage(AppConstants.downloadFolderKey) private var downloadFolder = AppConstants.defaultDownloadDirectory.path

    @State private var isConverting: Bool = false
    @State private var overallProgress: Double = 0.0
    @State private var isFileImporterPresented = false
    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue
    @State private var selectedPreset: ExportPreset = .videoLoop
    @State private var hasInitializedPreset = false
    @State private var hasUserChangedPreset = false
    @State private var dockProgressUpdater = DockProgressUpdater()
    @State private var progressTask: Task<Void, Never>?
    private let presetManager = PresetManager.shared
    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted
    @AppStorage(AppConstants.watchFolderModeKey) private var watchFolderModeEnabled = false
    @AppStorage(AppConstants.watchFolderPathKey) private var watchFolderPath = ""
    @StateObject private var watchFolderCoordinator = WatchFolderCoordinator()
    @State private var mergeClipsEnabled = false
    @State private var mergeClipsAvailable = false
    @State private var mergeClipsTooltip = "Add at least two compatible clips to enable merging."
    @StateObject private var mergeCompatibilityScheduler = MergeCompatibilityScheduler()
    
    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var showUpdateNotification = false
    @State private var updateNotificationTask: Task<Void, Never>?
    @State private var showURLInputOverlay = false
    @State private var showYTDLPNotConfiguredAlert = false
    @State private var showCaptureSheet = false

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

    /// Presets that are currently visible in the picker
    private var visiblePresets: [ExportPreset] {
        presetManager.visiblePresets
    }

    private var downloadFolderURL: URL {
        let url = URL(fileURLWithPath: downloadFolder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
                    let selectedItem = droppedFiles[index]
                    if FullscreenPlayerWindowController.shared.isCurrentlyPlaying(itemID: selectedItem.id) {
                        return
                    }
                    FullscreenPlayerWindowController.shared.openFullscreenPlayer(
                        for: selectedItem,
                        in: droppedFiles
                    )
                }
            },
            onURLDrop: { urlString in
                handleURLDownload(urlString, liveFromStart: false)
            },
            onRenameOutputFileName: { id, newName in
                handleOutputFileNameOverride(itemID: id, newName: newName)
            }
        )
    }

    private func handleFileDeletion(_ indexSet: IndexSet) {
        let itemsToRemove = indexSet.compactMap { index -> VideoItem? in
            guard index < droppedFiles.count else { return nil }
            return droppedFiles[index]
        }

        for item in itemsToRemove {
            if item.isDownloading {
                DownloadManager.shared.cancelDownload(itemID: item.id)
            } else if let _ = item.scheduledDownloadTime {
                ScheduledDownloadService.shared.cancelScheduledItem(itemID: item.id)
            }
        }

        // Note: Cache cleanup is handled by the user's cleanup policy (on app launch or manually)
        // We don't delete cache immediately when files are removed, allowing re-import to reuse cached assets
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
                droppedFiles[index].outputFileNameOverride = nil
                // Also reset comment and date tag to defaults
                droppedFiles[index].comment = ""
                droppedFiles[index].includeDateTag = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)
            }
        }
    }

    var body: some View {
        mainContentView
            .overlay(alignment: .bottom) { updateNotificationOverlay }
            .frame(minWidth: 860)
            .modifier(ContentViewSheets(
                droppedFiles: $droppedFiles,
                trimSheetItemID: $trimSheetItemID,
                trimWithCropSheetItemID: $trimWithCropSheetItemID,
                timecodeSheetItemID: $timecodeSheetItemID,
                audioConfigSheetItemID: $audioConfigSheetItemID,
                metadataSheetItemIDs: $metadataSheetItemIDs,
                selectedPreset: selectedPreset,
                showCaptureSheet: $showCaptureSheet
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
                .onAppear {
                    setupScheduledDownloads()
                }
                .toolbar {
                    conversionToolbar
                }

            if isConverting {
                OverallProgressView(progress: overallProgress)
            }
        }
        .overlay {
            if showURLInputOverlay {
                URLInputOverlay(
                    isPresented: $showURLInputOverlay,
                    onSubmit: { urlString, liveFromStart in
                        handleURLDownload(urlString, liveFromStart: liveFromStart)
                    },
                    onSchedule: { urlString, scheduledDate, liveFromStart in
                        handleScheduledDownload(urlString, at: scheduledDate, liveFromStart: liveFromStart)
                    }
                )
            }
        }
        .alert("yt-dlp Not Available", isPresented: $showYTDLPNotConfiguredAlert) {
            Button("Open Settings") {
                openSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To download videos from URLs, you need yt-dlp. Install with Homebrew (brew install yt-dlp) or configure a custom path in Settings > Downloads.")
        }
    }

    /// Handles URL download from the overlay
    private func handleURLDownload(_ urlString: String, liveFromStart: Bool) {
        Task {
            // Check if yt-dlp is configured
            guard await DownloadManager.shared.isYTDLPConfigured() else {
                showYTDLPNotConfiguredAlert = true
                return
            }

            await DownloadManager.shared.startDownload(
                url: urlString,
                items: $droppedFiles,
                outputFolder: downloadFolderURL,
                liveFromStart: liveFromStart
            )
        }
    }

    /// Handles scheduling a download for later
    private func handleScheduledDownload(_ urlString: String, at date: Date, liveFromStart: Bool) {
        Task {
            await DownloadManager.shared.scheduleDownload(
                url: urlString,
                at: date,
                items: $droppedFiles,
                outputFolder: downloadFolderURL,
                liveFromStart: liveFromStart
            )
        }
    }

    /// Sets up the download manager references for scheduled downloads
    private func setupScheduledDownloads() {
        // Store references in DownloadManager so scheduled downloads can access them
        DownloadManager.shared.videoItems = $droppedFiles
        DownloadManager.shared.outputFolder = downloadFolderURL

        // Store references in UploadManager for upload functionality
        UploadManager.shared.videoItems = $droppedFiles

        // Set up auto-encode callback for downloads
        DownloadManager.shared.onAutoEncode = { [self] _ in
            Task { @MainActor in
                // Only start if not already converting
                if !isConverting {
                    await startConversion()
                }
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
            onToggleConversion: handleConversionToggle,
            onShowURLInput: {
                showURLInputOverlay = true
            },
            onShowCapture: {
                showCaptureSheet = true
            }
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
        presetManager.displayName(for: preset)
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

        let resolvedExtension = preset.outputExtension(for: item.url)
        let outputBaseName = outputBaseName(for: item, preset: preset)
        let outputFileName = outputBaseName + "." + resolvedExtension
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

    private func outputBaseName(for item: VideoItem, preset: ExportPreset) -> String {
        if let override = item.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let baseName = (override as NSString).deletingPathExtension
            return FileNameProcessor.processFileName(baseName)
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(item.url.deletingPathExtension().lastPathComponent)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        return sanitizedBaseName + suffixPart
    }

    private func handleOutputFileNameOverride(itemID: UUID, newName: String?) {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }
        let trimmed = newName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            droppedFiles[index].outputFileNameOverride = nil
        } else {
            let baseName = (trimmed as NSString).deletingPathExtension
            droppedFiles[index].outputFileNameOverride = FileNameProcessor.processFileName(baseName)
        }
        droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
    }

    private var toolbarPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { selectedPreset },
            set: { newValue in
                let oldValue = selectedPreset
                hasUserChangedPreset = true
                selectedPreset = newValue
                refreshExpectedOutputURLs(for: newValue)

                // Defer merge evaluation to avoid modifying state during view update
                Task { @MainActor in
                    await Task.yield()
                    self.scheduleMergeCompatibilityEvaluation()
                }

                // Apply auto-mute settings via PresetManager
                presetManager.applyAutoMuteSettings(
                    to: &droppedFiles,
                    oldPreset: oldValue,
                    newPreset: newValue,
                    videoLoopDefaultMuted: videoLoopDefaultMuted
                )
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
            onShowDownload: { showURLInputOverlay = true },
            onShowCapture: { showCaptureSheet = true },
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
        mergeCompatibilityScheduler.schedule {
            await evaluateMergeClipsState()
        }
    }

    @MainActor
    private func evaluateMergeClipsState() async {
        await Task.yield()

        if isConverting {
            mergeClipsAvailable = false
            mergeClipsEnabled = false
            mergeClipsTooltip = "Cannot toggle merging while conversion is running."
            return
        }

        let result = await ConversionManager.shared.evaluateMergeCompatibility(for: droppedFiles, preset: selectedPreset)

        guard !Task.isCancelled else { return }

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

    private func handleConversionToggle(_ optionKeyPressed: Bool) {
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

        for item in droppedFiles {
            if item.isDownloading {
                DownloadManager.shared.cancelDownload(itemID: item.id)
            } else if let _ = item.scheduledDownloadTime {
                ScheduledDownloadService.shared.cancelScheduledItem(itemID: item.id)
            }
        }

        // Note: Cache cleanup is handled by the user's cleanup policy (on app launch or manually)
        // We don't delete cache immediately when files are removed, allowing re-import to reuse cached assets
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
            // Defer merge evaluation to be safe
            Task { @MainActor in
                await Task.yield()
                self.scheduleMergeCompatibilityEvaluation()
            }
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
    var onShowURLInput: () -> Void
    var onShowCapture: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleWatchFolder: onToggleWatchFolder,
            onSelectOutputFolder: onSelectOutputFolder,
            onToggleMerge: onToggleMerge,
            onResetAll: onResetAll,
            onToggleConversion: onToggleConversion,
            onShowURLInput: onShowURLInput,
            onShowCapture: onShowCapture
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
        context.coordinator.onShowURLInput = onShowURLInput
        context.coordinator.onShowCapture = onShowCapture
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
        var onShowURLInput: () -> Void
        var onShowCapture: () -> Void
        private var monitor: Any?

        init(
            onToggleWatchFolder: @escaping () -> Void,
            onSelectOutputFolder: @escaping () -> Void,
            onToggleMerge: @escaping () -> Void,
            onResetAll: @escaping () -> Void,
            onToggleConversion: @escaping (_ optionKeyPressed: Bool) -> Void,
            onShowURLInput: @escaping () -> Void,
            onShowCapture: @escaping () -> Void
        ) {
            self.onToggleWatchFolder = onToggleWatchFolder
            self.onSelectOutputFolder = onSelectOutputFolder
            self.onToggleMerge = onToggleMerge
            self.onResetAll = onResetAll
            self.onToggleConversion = onToggleConversion
            self.onShowURLInput = onShowURLInput
            self.onShowCapture = onShowCapture
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

                // Cmd+L: Show URL Input Overlay (L for Load)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_L {
                    self.onShowURLInput()
                    return nil
                }

                // Cmd+Shift+C: Open Capture Mode
                if hasCommand && hasShift && !hasOption && !hasControl && event.keyCode == kVK_ANSI_C {
                    self.onShowCapture()
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
    @Binding var showCaptureSheet: Bool

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
            .sheet(isPresented: $showCaptureSheet) {
                CaptureModeView()
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
                let details = await VideoFileUtils.loadDetails(
                    for: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset,
                    generateRowThumbnailIfMissing: false
                )

                await MainActor.run {
                    if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                        droppedFiles[index].apply(details: details)
                        droppedFiles[index].detailsLoaded = true
                    }
                }

                if details.thumbnailData == nil {
                    Task.detached(priority: .background) {
                        let thumbnailData = await VideoFileUtils.getCachedThumbnail(url: url, generateRowThumbnailIfMissing: true)
                        guard let thumbnailData else { return }
                        await MainActor.run {
                            if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }),
                               droppedFiles[index].thumbnailData == nil {
                                droppedFiles[index].thumbnailData = thumbnailData
                            }
                        }
                    }
                }

                Task.detached(priority: .background) {
                    let metadata = await VideoFileUtils.fetchMetadata(for: url)
                    await MainActor.run {
                        if let index = droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                            droppedFiles[index].metadata = metadata
                        }
                    }
                }

                VideoFileUtils.prefetchPreviewAssets(for: url)
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
