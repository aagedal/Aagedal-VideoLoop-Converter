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
import OSLog

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
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ContentView")
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
    
    @State private var encodingGroups: [EncodingGroup] = []
    @State private var queueOrder: [UUID] = []

    @StateObject private var updateChecker = UpdateChecker.shared
    @State private var showUpdateNotification = false
    @State private var updateNotificationTask: Task<Void, Never>?
    @State private var showURLInputOverlay = false
    @State private var showPresetQuickSelect = false
    @State private var showYTDLPNotConfiguredAlert = false
    // showCaptureSheet removed — capture mode now uses CaptureOverlayWindowController

    // Keyboard shortcut sheet states - using optional UUID directly for item-based sheet presentation
    // When non-nil, the corresponding sheet is presented. Set to nil to dismiss.
    @State private var trimSheetItemID: UUID?
    @State private var trimWithCropSheetItemID: UUID?
    @State private var timecodeSheetItemID: UUID?
    @State private var audioConfigSheetItemID: UUID?
    
    // Using shared AppConstants for supported file types
    private var supportedVideoTypes: [UTType] {
        var types = AppConstants.supportedVideoTypes.compactMap { UTType($0) }
        // Allow folder selection for image sequence imports
        types.append(.folder)
        // Allow image file selection for image sequence imports
        if let pngType = UTType("public.png") { types.append(pngType) }
        if let jpegType = UTType("public.jpeg") { types.append(jpegType) }
        if let tiffType = UTType("public.tiff") { types.append(tiffType) }
        types.append(.image)
        return types
    }
    
    // Only allow starting conversion when at least one item is still waiting
    private var canStartConversion: Bool {
        droppedFiles.contains { $0.status == .waiting }
        || encodingGroups.contains { $0.items.contains { $0.status == .waiting } }
    }

    private var hasResettableItems: Bool {
        droppedFiles.contains { $0.status != .waiting }
        || encodingGroups.contains { $0.items.contains { $0.status != .waiting } }
    }

    private var allConversionItems: [VideoItem] {
        droppedFiles + encodingGroups.flatMap { $0.items }
    }

    private var currentConvertingItem: VideoItem? {
        allConversionItems.first { $0.status == .converting }
    }

    private var completedFileCount: Int {
        allConversionItems.filter { $0.status == .done }.count
    }

    private var totalActiveFileCount: Int {
        allConversionItems.filter { $0.status != .cancelled && $0.status != .failed }.count
    }

    private var computedOverallProgress: Double {
        let activeItems = allConversionItems.filter { $0.status != .cancelled && $0.status != .failed }
        guard !activeItems.isEmpty else { return 0.0 }
        let totalDuration = activeItems.reduce(0.0) { $0 + $1.trimmedDuration }
        guard totalDuration > 0 else { return 0.0 }
        let completedDuration = activeItems.reduce(0.0) { sum, file in
            switch file.status {
            case .done: return sum + file.trimmedDuration
            case .converting: return sum + file.trimmedDuration * file.progress
            default: return sum
            }
        }
        return min(max(completedDuration / totalDuration, 0.0), 1.0)
    }

    /// Ensures queueOrder is in sync with droppedFiles and encodingGroups.
    /// Removes stale IDs and appends any missing ones.
    private func sanitizeQueueOrder() {
        let validIDs = Set(droppedFiles.map(\.id)).union(encodingGroups.map(\.id))
        queueOrder.removeAll { !validIDs.contains($0) }
        let ordered = Set(queueOrder)
        for item in droppedFiles where !ordered.contains(item.id) {
            queueOrder.append(item.id)
        }
        for group in encodingGroups where !ordered.contains(group.id) {
            queueOrder.append(group.id)
        }
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
            encodingGroups: $encodingGroups,
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
                // Update the shared state and show the window
                MetadataWindowState.shared.selectedItemIDs = Set(validIDs)
                MetadataWindowState.shared.allItems = droppedFiles
                MetadataWindowController.shared.showWindow()
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
                        in: droppedFiles,
                        onItemTrimChanged: { [self] itemID, trimStart, trimEnd in
                            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                                droppedFiles[idx].trimStart = trimStart
                                droppedFiles[idx].trimEnd = trimEnd
                            }
                        }
                    )
                }
            },
            onURLDrop: { urlString in
                handleURLDownload(urlString, liveFromStart: false)
            },
            onRenameOutputFileName: { id, newName in
                handleOutputFileNameOverride(itemID: id, newName: newName)
            },
            encodeOnly: { itemID in
                await encodeOnlyItem(itemID: itemID)
            },
            onDeleteGroup: { groupID in
                encodingGroups.removeAll { $0.id == groupID }
                queueOrder.removeAll { $0 == groupID }
            },
            onAddFilesToGroup: { groupID in
                Task { await addFilesToGroup(groupID: groupID) }
            },
            onResetGroup: { groupID in
                guard !isConverting else { return }
                if let gi = encodingGroups.firstIndex(where: { $0.id == groupID }) {
                    for ii in encodingGroups[gi].items.indices where encodingGroups[gi].items[ii].status != .waiting {
                        encodingGroups[gi].items[ii].status = .waiting
                        encodingGroups[gi].items[ii].progress = 0.0
                        encodingGroups[gi].items[ii].eta = nil
                        encodingGroups[gi].items[ii].conversionError = nil
                        encodingGroups[gi].items[ii].analyticsResults = nil
                        encodingGroups[gi].items[ii].analyticsStatus = .notQueued
                        encodingGroups[gi].items[ii].analyticsProgress = 0.0
                        encodingGroups[gi].items[ii].analyticsEnabled = false
                    }
                }
            },
            queueOrder: queueOrder,
            onReorder: { movedIDs, destIndex in
                // Remove moved IDs from current position
                queueOrder.removeAll { movedIDs.contains($0) }
                // Insert at destination (clamped)
                let insertAt = max(0, min(destIndex, queueOrder.count))
                queueOrder.insert(contentsOf: movedIDs, at: insertAt)
            },
            onQueueSync: { sanitizeQueueOrder() },
            disableKeyboardNavigation: showPresetQuickSelect || showURLInputOverlay || CaptureOverlayWindowController.shared.isShowing || trimSheetItemID != nil || trimWithCropSheetItemID != nil || timecodeSheetItemID != nil || audioConfigSheetItemID != nil
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
            if item.subtitleStatus.isInProgress {
                Task { await TesseractService.shared.cancelGeneration() }
                Task { await WhisperService.shared.cancelGeneration() }
                Task { await ParakeetService.shared.cancelGeneration() }
            }
        }

        // Note: Cache cleanup is handled by the user's cleanup policy (on app launch or manually)
        // We don't delete cache immediately when files are removed, allowing re-import to reuse cached assets
        let removedIDs = Set(itemsToRemove.map(\.id))
        queueOrder.removeAll { removedIDs.contains($0) }
        droppedFiles.remove(atOffsets: indexSet)
    }

    private func handleFileReset(_ index: Int, optionKeyPressed: Bool = false) {
        if index < droppedFiles.count {
            droppedFiles[index].status = .waiting
            droppedFiles[index].progress = 0.0
            droppedFiles[index].eta = nil
            droppedFiles[index].conversionError = nil
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
            droppedFiles[index].outputFileSizeBytes = nil
            droppedFiles[index].analyticsResults = nil
            droppedFiles[index].analyticsStatus = .notQueued
            droppedFiles[index].analyticsProgress = 0.0
            droppedFiles[index].analyticsEnabled = false

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
                droppedFiles[index].waveformBackgroundImageURL = nil
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
                selectedPreset: selectedPreset,
                showCaptureSheet: .constant(false)
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
            .onReceive(NotificationCenter.default.publisher(for: .showCameraCardImporter)) { _ in
                Task { await handleCameraCardFolderSelection() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .createEncodingGroup)) { _ in
                let group = EncodingGroup(name: "New Group")
                encodingGroups.append(group)
                queueOrder.append(group.id)
            }
            .sheet(item: $cameraCardImportState) { state in
                CameraCardImportView(
                    clipCount: state.videoURLs.count,
                    folderName: state.folderURL.lastPathComponent,
                    masterName: $cameraCardMasterName,
                    selectedPreset: cameraCardPresetBinding,
                    concatEnabled: $cameraCardConcatEnabled,
                    uploadEnabled: $cameraCardUploadEnabled,
                    mergeCompatibilityResult: cardMergeCompatibilityResult,
                    isCheckingCompatibility: isCheckingCardCompatibility,
                    onImport: {
                        Task { await performCameraCardImport() }
                    },
                    onCancel: {
                        cameraCardImportState = nil
                    },
                    onAutoSplit: {
                        Task { await performCameraCardAutoSplit() }
                    },
                    onForceMerge: {
                        showCardConformanceMergeDialog = true
                    }
                )
                .onAppear { checkCardMergeCompatibility() }
                .onChange(of: cameraCardPresetRaw) { _, _ in checkCardMergeCompatibility() }
                .sheet(isPresented: $showCardConformanceMergeDialog) {
                    if let state = cameraCardImportState {
                        ConformanceMergeDialog(
                            items: cardConformanceItems,
                            metadata: cardConformanceMetadata,
                            onConfirm: { referenceID in
                                showCardConformanceMergeDialog = false
                                Task { await performCameraCardForceMerge(referenceItemID: referenceID) }
                            },
                            onCancel: {
                                showCardConformanceMergeDialog = false
                            }
                        )
                    }
                }
            }
            .modifier(ContentViewNotificationHandlers(
                droppedFiles: $droppedFiles,
                queueOrder: $queueOrder,
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
                OverallProgressView(
                    progress: computedOverallProgress,
                    currentFileName: currentConvertingItem?.name,
                    completedCount: completedFileCount,
                    totalCount: totalActiveFileCount,
                    currentFileETA: currentConvertingItem?.eta
                )
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
        .sheet(isPresented: $showPresetQuickSelect) {
            PresetQuickSelectOverlay(
                isPresented: $showPresetQuickSelect,
                presets: visiblePresets,
                currentPreset: selectedPreset,
                displayName: { displayName(for: $0) },
                onSelect: { preset in
                    hasUserChangedPreset = true
                    let oldValue = selectedPreset
                    selectedPreset = preset
                    refreshExpectedOutputURLs(for: preset)
                    Task { @MainActor in
                        await Task.yield()
                        self.scheduleMergeCompatibilityEvaluation()
                    }
                    presetManager.applyAutoMuteSettings(
                        to: &droppedFiles,
                        oldPreset: oldValue,
                        newPreset: preset,
                        videoLoopDefaultMuted: videoLoopDefaultMuted
                    )
                }
            )
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
                CaptureOverlayWindowController.shared.showCaptureOverlay()
            },
            onShowPresetQuickSelect: {
                showPresetQuickSelect = true
            },
            onSelectPresetByIndex: { index in
                // Only handle if no sheets/overlays are open
                let anySheetOpen = trimSheetItemID != nil ||
                    trimWithCropSheetItemID != nil ||
                    timecodeSheetItemID != nil ||
                    audioConfigSheetItemID != nil ||
                    CaptureOverlayWindowController.shared.isShowing ||
                    showURLInputOverlay ||
                    showPresetQuickSelect
                guard !anySheetOpen else { return false }
                guard index < visiblePresets.count else { return false }

                let preset = visiblePresets[index]
                let oldValue = selectedPreset
                hasUserChangedPreset = true
                selectedPreset = preset
                refreshExpectedOutputURLs(for: preset)
                Task { @MainActor in
                    await Task.yield()
                    self.scheduleMergeCompatibilityEvaluation()
                }
                presetManager.applyAutoMuteSettings(
                    to: &droppedFiles,
                    oldPreset: oldValue,
                    newPreset: preset,
                    videoLoopDefaultMuted: videoLoopDefaultMuted
                )
                return true
            },
            onShowShortcuts: {
                // Set the tab to open before opening Settings
                UserDefaults.standard.set("shortcuts", forKey: AppConstants.settingsTabToOpenKey)
                openSettings()
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

    @AppStorage("cameraCardUploadEnabled") private var cameraCardUploadEnabled = false
    @AppStorage("cameraCardConcatEnabled") private var cameraCardConcatEnabled = true
    @AppStorage("cameraCardMasterName") private var cameraCardMasterName = ""
    @AppStorage("cameraCardPreset") private var cameraCardPresetRaw = ExportPreset.streamCopy.rawValue

    private var cameraCardPresetBinding: Binding<ExportPreset> {
        Binding(
            get: { ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy },
            set: { cameraCardPresetRaw = $0.rawValue }
        )
    }
    @State private var cameraCardImportState: CameraCardImportState?
    @State private var cardMergeCompatibilityResult: ConversionManager.MergeCompatibilityResult?
    @State private var isCheckingCardCompatibility = false
    @State private var cardCompatibilityCheckTask: Task<Void, Never>?
    @State private var showCardConformanceMergeDialog = false
    @State private var cardConformanceItems: [VideoItem] = []
    @State private var cardConformanceMetadata: [UUID: VideoMetadata] = [:]

    private struct CameraCardImportState: Identifiable {
        let id = UUID()
        let folderURL: URL
        let videoURLs: [URL]
    }

    @MainActor
    private func handleCameraCardFolderSelection() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Camera Card or Folder"
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        guard response == .OK, let folderURL = panel.url else { return }

        let hasAccess = folderURL.startAccessingSecurityScopedResource()
        _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: folderURL)

        let videoURLs = CameraCardScanner.scanForVideoFiles(in: folderURL)

        if hasAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !videoURLs.isEmpty else { return }

        cameraCardImportState = CameraCardImportState(folderURL: folderURL, videoURLs: videoURLs)
    }

    @MainActor
    private func performCameraCardImport() async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let concatEnabled = cameraCardConcatEnabled
        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() }
        }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Build VideoItems for the group
        var groupItems: [VideoItem] = []
        for url in state.videoURLs {
            if var item = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: cardPreset
            ) {
                if uploadEnabled {
                    item.uploadEnabled = true
                }
                if !masterName.isEmpty {
                    let processedName = FileNameProcessor.processFileName(masterName)
                    if concatEnabled {
                        // For concat, only the first item needs the master name override
                        if groupItems.isEmpty {
                            item.outputFileNameOverride = processedName
                            item.outputURL = expectedOutputURL(for: item, preset: cardPreset)
                        }
                    } else {
                        let sequenceName = String(format: "%@_%03d", processedName, groupItems.count + 1)
                        item.outputFileNameOverride = sequenceName
                        item.outputURL = expectedOutputURL(for: item, preset: cardPreset)
                    }
                }
                groupItems.append(item)
            }
        }

        guard !groupItems.isEmpty else { return }

        let groupName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        let group = EncodingGroup(
            name: groupName,
            items: groupItems,
            preset: cardPreset,
            concatEnabled: concatEnabled,
            uploadEnabled: uploadEnabled
        )

        encodingGroups.append(group)
        queueOrder.append(group.id)

        // Load details (thumbnails, duration, metadata) in background
        let itemIDs = groupItems.map { $0.id }
        Task {
            await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
        }
    }

    /// Runs merge compatibility check for the card import dialog in background.
    private func checkCardMergeCompatibility() {
        cardCompatibilityCheckTask?.cancel()
        cardMergeCompatibilityResult = nil

        guard let state = cameraCardImportState, state.videoURLs.count >= 2 else {
            cardMergeCompatibilityResult = .insufficientItems(cameraCardImportState?.videoURLs.count ?? 0)
            return
        }

        isCheckingCardCompatibility = true
        let urls = state.videoURLs
        let folderURL = state.folderURL
        let preset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        cardCompatibilityCheckTask = Task {
            let hasAccess = folderURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { folderURL.stopAccessingSecurityScopedResource() } }

            var tempItems: [VideoItem] = []
            var metadataMap: [UUID: VideoMetadata] = [:]

            for url in urls {
                if Task.isCancelled { return }
                if var item = VideoFileUtils.makePlaceholderItem(from: url, outputFolder: outputFolder, preset: preset) {
                    if let metadata = try? await VideoMetadataService.shared.metadata(for: url) {
                        item.metadata = metadata
                        metadataMap[item.id] = metadata
                    }
                    tempItems.append(item)
                }
            }

            guard !Task.isCancelled else { return }

            let result = ConversionManager.checkMergeCompatibility(items: tempItems, metadata: metadataMap)
            await MainActor.run {
                cardMergeCompatibilityResult = result
                isCheckingCardCompatibility = false
                // Store for conformance merge dialog
                cardConformanceItems = tempItems
                cardConformanceMetadata = metadataMap
            }
        }
    }

    @MainActor
    private func performCameraCardAutoSplit() async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() } }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Build items with metadata
        var allItems: [VideoItem] = []
        var metadataMap: [UUID: VideoMetadata] = [:]

        for url in state.videoURLs {
            if var item = VideoFileUtils.makePlaceholderItem(from: url, outputFolder: outputFolder, preset: cardPreset) {
                if uploadEnabled { item.uploadEnabled = true }
                if let metadata = try? await VideoMetadataService.shared.metadata(for: url) {
                    item.metadata = metadata
                    metadataMap[item.id] = metadata
                }
                allItems.append(item)
            }
        }

        guard !allItems.isEmpty else { return }

        let compatibleGroups = ConversionManager.groupByCompatibility(items: allItems, metadata: metadataMap)
        let baseName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        for (_, groupItems) in compatibleGroups.enumerated() {
            // Build format suffix from the first item's metadata (e.g. "1080p50_4ch")
            let formatSuffix: String = {
                guard compatibleGroups.count > 1,
                      let first = groupItems.first,
                      let meta = metadataMap[first.id] else { return "" }
                var parts: [String] = []
                if let video = meta.primaryVideoStream, let h = video.height {
                    let scanType = (video.isInterlaced == true) ? "i" : "p"
                    let fr = video.frameRate?.value.map { String(Int($0.rounded())) } ?? ""
                    parts.append("\(h)\(scanType)\(fr)")
                }
                if let audio = meta.audioStreams.first, let ch = audio.channels {
                    parts.append("\(ch)ch")
                }
                return parts.isEmpty ? "" : "_" + parts.joined(separator: "_")
            }()
            let groupName = compatibleGroups.count > 1 ? "\(baseName)\(formatSuffix)" : baseName

            // Apply sequential naming within each group
            var namedItems = groupItems
            for i in namedItems.indices {
                if !masterName.isEmpty {
                    let processedName = FileNameProcessor.processFileName(groupName)
                    if namedItems.count > 1 {
                        // Concat group — only first item gets the name override
                        if i == 0 {
                            namedItems[i].outputFileNameOverride = processedName
                            namedItems[i].outputURL = expectedOutputURL(for: namedItems[i], preset: cardPreset)
                        }
                    } else {
                        namedItems[i].outputFileNameOverride = processedName
                        namedItems[i].outputURL = expectedOutputURL(for: namedItems[i], preset: cardPreset)
                    }
                }
            }

            let group = EncodingGroup(
                name: groupName,
                items: namedItems,
                preset: cardPreset,
                concatEnabled: namedItems.count >= 2,
                uploadEnabled: uploadEnabled
            )

            encodingGroups.append(group)
            queueOrder.append(group.id)

            let itemIDs = namedItems.map { $0.id }
            Task {
                await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
            }
        }
    }

    @MainActor
    private func performCameraCardForceMerge(referenceItemID: UUID) async {
        guard let state = cameraCardImportState else { return }
        cameraCardImportState = nil

        let uploadEnabled = cameraCardUploadEnabled
        let masterName = cameraCardMasterName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardPreset = ExportPreset(rawValue: cameraCardPresetRaw) ?? .streamCopy

        let hasAccess = state.folderURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { state.folderURL.stopAccessingSecurityScopedResource() } }

        for url in state.videoURLs {
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        }

        // Use the items and metadata from the compatibility check
        var groupItems = cardConformanceItems
        for i in groupItems.indices {
            if uploadEnabled { groupItems[i].uploadEnabled = true }
            if !masterName.isEmpty {
                let processedName = FileNameProcessor.processFileName(masterName)
                if i == 0 {
                    groupItems[i].outputFileNameOverride = processedName
                    groupItems[i].outputURL = expectedOutputURL(for: groupItems[i], preset: cardPreset)
                }
            }
        }

        guard !groupItems.isEmpty else { return }

        let groupName = masterName.isEmpty ? state.folderURL.lastPathComponent : masterName

        // Find the reference item ID in our items (it may have a different UUID from the temp items)
        let group = EncodingGroup(
            name: groupName,
            items: groupItems,
            preset: cardPreset,
            concatEnabled: true,
            uploadEnabled: uploadEnabled,
            conformanceMergeEnabled: true,
            conformanceReferenceItemID: referenceItemID
        )

        encodingGroups.append(group)
        queueOrder.append(group.id)

        let itemIDs = groupItems.map { $0.id }
        Task {
            await loadGroupItemDetails(groupID: group.id, itemIDs: itemIDs, preset: cardPreset)
        }
    }

    @MainActor
    private func addFilesToGroup(groupID: UUID) async {
        guard let groupIndex = encodingGroups.firstIndex(where: { $0.id == groupID }) else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = AppConstants.supportedVideoTypes.compactMap { UTType($0) }
        panel.title = "Add Files to Group"

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }

        guard response == .OK, !panel.urls.isEmpty else { return }

        let groupPreset = encodingGroups[groupIndex].preset ?? selectedPreset
        var newItemIDs: [UUID] = []

        for url in panel.urls {
            _ = url.startAccessingSecurityScopedResource()
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            url.stopAccessingSecurityScopedResource()

            if let item = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: groupPreset
            ) {
                newItemIDs.append(item.id)
                encodingGroups[groupIndex].items.append(item)
            }
        }

        // Load details asynchronously for added items
        await loadGroupItemDetails(groupID: groupID, itemIDs: newItemIDs, preset: groupPreset)
    }

    @MainActor
    private func loadGroupItemDetails(groupID: UUID, itemIDs: [UUID], preset: ExportPreset) async {
        for itemID in itemIDs {
            guard let gi = encodingGroups.firstIndex(where: { $0.id == groupID }),
                  let ii = encodingGroups[gi].items.firstIndex(where: { $0.id == itemID }) else { continue }

            let url = encodingGroups[gi].items[ii].url
            let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: preset)

            // Re-lookup indices in case array changed during await
            guard let gi2 = encodingGroups.firstIndex(where: { $0.id == groupID }),
                  let ii2 = encodingGroups[gi2].items.firstIndex(where: { $0.id == itemID }) else { continue }

            encodingGroups[gi2].items[ii2].apply(details: details)
            encodingGroups[gi2].items[ii2].detailsLoaded = true
        }
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

                // Check if URL is a directory — detect image sequences
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    _ = url.startAccessingSecurityScopedResource()
                    let sequences = ImageSequenceDetector.detectSequences(inFolder: url)
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
                    url.stopAccessingSecurityScopedResource()
                    for config in sequences {
                        let item = VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config,
                            outputFolder: outputFolder,
                            preset: selectedPreset
                        )
                        droppedFiles.append(item)
                        queueOrder.append(item.id)
                    }
                    continue
                }

                // Check if it's a single image file that could be part of a sequence
                let ext = url.pathExtension.lowercased()
                if AppConstants.supportedImageSequenceExtensions.contains(ext) {
                    _ = url.startAccessingSecurityScopedResource()
                    if let config = ImageSequenceDetector.detectSequence(fromFile: url) {
                        let parentDir = url.deletingLastPathComponent()
                        _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: parentDir)
                        url.stopAccessingSecurityScopedResource()
                        let item = VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config,
                            outputFolder: outputFolder,
                            preset: selectedPreset
                        )
                        droppedFiles.append(item)
                        queueOrder.append(item.id)
                        continue
                    }
                    url.stopAccessingSecurityScopedResource()
                    continue // Single image without sequence, skip
                }

                guard let placeholder = VideoFileUtils.makePlaceholderItem(
                    from: url,
                    outputFolder: outputFolder,
                    preset: selectedPreset
                ) else {
                    Self.logger.info("Skipping unsupported file: \(url.lastPathComponent, privacy: .public)")
                    continue
                }

                droppedFiles.append(placeholder)
                queueOrder.append(placeholder.id)
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
            Self.logger.error("Error selecting files: \(error.localizedDescription, privacy: .public)")
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
                }
            }
        }
    }
    
    @MainActor
    private func startConversion() async {
        isConverting = true
        // Initialize dock progress with 0% to show it immediately
        dockProgressUpdater.updateProgress(0.0)
        sanitizeQueueOrder()

        // Convert in queue order: batch consecutive ungrouped items, then groups
        var i = 0
        while i < queueOrder.count {
            guard isConverting else { break }
            let id = queueOrder[i]

            if let groupIndex = encodingGroups.firstIndex(where: { $0.id == id }) {
                // Encoding group entry
                let group = encodingGroups[groupIndex]
                if group.items.contains(where: { $0.status == .waiting }) {
                    // Apply sequential naming if enabled
                    if group.sequentialNamingEnabled {
                        let processedName = FileNameProcessor.processFileName(group.name)
                        for itemIndex in encodingGroups[groupIndex].items.indices {
                            let sequenceName = String(format: "%@_%03d", processedName, itemIndex + 1)
                            encodingGroups[groupIndex].items[itemIndex].outputFileNameOverride = sequenceName
                        }
                    }
                    let groupPreset = group.preset ?? selectedPreset
                    // Build conformance metadata if needed
                    var conformanceMeta: [UUID: VideoMetadata]?
                    if group.conformanceMergeEnabled, group.conformanceReferenceItemID != nil {
                        var metaMap: [UUID: VideoMetadata] = [:]
                        for item in encodingGroups[groupIndex].items {
                            if let m = item.metadata { metaMap[item.id] = m }
                        }
                        conformanceMeta = metaMap
                    }

                    await ConversionManager.shared.convertGroup(
                        items: $encodingGroups[groupIndex].items,
                        outputFolder: currentOutputFolder.path,
                        preset: groupPreset,
                        concatEnabled: group.concatEnabled,
                        groupName: group.name,
                        transcriptionEnabled: group.transcriptionEnabled,
                        uploadEnabled: group.uploadEnabled,
                        analyticsEnabled: group.analyticsEnabled,
                        conformanceMergeEnabled: group.conformanceMergeEnabled,
                        conformanceReferenceItemID: group.conformanceReferenceItemID,
                        conformanceMetadata: conformanceMeta
                    )
                }
                i += 1
            } else {
                // Consecutive ungrouped items — collect IDs for this batch
                var batchIDs = Set<UUID>()
                while i < queueOrder.count && !encodingGroups.contains(where: { $0.id == queueOrder[i] }) {
                    batchIDs.insert(queueOrder[i])
                    i += 1
                }
                if droppedFiles.contains(where: { $0.status == .waiting && batchIDs.contains($0.id) }) {
                    await ConversionManager.shared.startConversion(
                        droppedFiles: $droppedFiles,
                        outputFolder: currentOutputFolder.path,
                        preset: selectedPreset,
                        mergeClipsEnabled: mergeClipsEnabled,
                        limitToIDs: batchIDs
                    )
                }
            }
        }

        isConverting = false
        SoundManager.shared.playSuccess()
        watchFolderCoordinator.startConversion()
    }

    /// Encodes a single item immediately (Option+click on encode button).
    @MainActor
    private func encodeOnlyItem(itemID: UUID) async {
        guard !isConverting else { return }
        guard droppedFiles.contains(where: { $0.id == itemID && $0.status == .waiting }) else { return }
        isConverting = true
        dockProgressUpdater.updateProgress(0.0)
        await ConversionManager.shared.startConversion(
            droppedFiles: $droppedFiles,
            outputFolder: currentOutputFolder.path,
            preset: selectedPreset,
            mergeClipsEnabled: false,
            limitToIDs: [itemID]
        )
        isConverting = false
        SoundManager.shared.playSuccess()
    }

    @MainActor
    private func cancelConversion() async {
        await ConversionManager.shared.cancelAllConversions()

        // Cancel waiting group items too (they won't be reached since isConverting is cleared)
        for gi in encodingGroups.indices {
            for ii in encodingGroups[gi].items.indices {
                if encodingGroups[gi].items[ii].status == .converting {
                    encodingGroups[gi].items[ii].status = .cancelled
                    encodingGroups[gi].items[ii].progress = 0
                }
            }
        }

        isConverting = false
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
            hasFiles: !droppedFiles.isEmpty || !encodingGroups.isEmpty,
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
            onShowCapture: { CaptureOverlayWindowController.shared.showCaptureOverlay() },
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
                Self.logger.info("Skipping unsupported file from watch folder: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            droppedFiles.append(placeholder)
            queueOrder.append(placeholder.id)
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
            if isConverting {
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
        encodingGroups.removeAll()
        queueOrder.removeAll()
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
            droppedFiles[index].conversionError = nil
            droppedFiles[index].outputURL = expectedOutputURL(for: droppedFiles[index], preset: selectedPreset)
            droppedFiles[index].outputFileSizeBytes = nil
            droppedFiles[index].analyticsResults = nil
            droppedFiles[index].analyticsStatus = .notQueued
            droppedFiles[index].analyticsProgress = 0.0
            droppedFiles[index].analyticsEnabled = false

            if shouldClearSettings {
                droppedFiles[index].audioRoutingConfig = nil
                droppedFiles[index].cropConfig = nil
                droppedFiles[index].timecodeConfig = nil
                droppedFiles[index].trimStart = nil
                droppedFiles[index].trimEnd = nil
                droppedFiles[index].isMuted = false
                droppedFiles[index].comment = ""
                droppedFiles[index].includeDateTag = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)
            }

            didReset = true
        }

        // Reset group items too
        for gi in encodingGroups.indices {
            for ii in encodingGroups[gi].items.indices where encodingGroups[gi].items[ii].status != .waiting {
                encodingGroups[gi].items[ii].status = .waiting
                encodingGroups[gi].items[ii].progress = 0.0
                encodingGroups[gi].items[ii].eta = nil
                encodingGroups[gi].items[ii].conversionError = nil
                encodingGroups[gi].items[ii].analyticsResults = nil
                encodingGroups[gi].items[ii].analyticsStatus = .notQueued
                encodingGroups[gi].items[ii].analyticsProgress = 0.0
                encodingGroups[gi].items[ii].analyticsEnabled = false
                didReset = true
            }
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
    var onShowPresetQuickSelect: () -> Void
    var onSelectPresetByIndex: (Int) -> Bool
    var onShowShortcuts: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onToggleWatchFolder: onToggleWatchFolder,
            onSelectOutputFolder: onSelectOutputFolder,
            onToggleMerge: onToggleMerge,
            onResetAll: onResetAll,
            onToggleConversion: onToggleConversion,
            onShowURLInput: onShowURLInput,
            onShowCapture: onShowCapture,
            onShowPresetQuickSelect: onShowPresetQuickSelect,
            onSelectPresetByIndex: onSelectPresetByIndex,
            onShowShortcuts: onShowShortcuts
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
        context.coordinator.onShowPresetQuickSelect = onShowPresetQuickSelect
        context.coordinator.onSelectPresetByIndex = onSelectPresetByIndex
        context.coordinator.onShowShortcuts = onShowShortcuts
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
        var onShowPresetQuickSelect: () -> Void
        var onSelectPresetByIndex: (Int) -> Bool
        var onShowShortcuts: () -> Void
        private var monitor: Any?

        init(
            onToggleWatchFolder: @escaping () -> Void,
            onSelectOutputFolder: @escaping () -> Void,
            onToggleMerge: @escaping () -> Void,
            onResetAll: @escaping () -> Void,
            onToggleConversion: @escaping (_ optionKeyPressed: Bool) -> Void,
            onShowURLInput: @escaping () -> Void,
            onShowCapture: @escaping () -> Void,
            onShowPresetQuickSelect: @escaping () -> Void,
            onSelectPresetByIndex: @escaping (Int) -> Bool,
            onShowShortcuts: @escaping () -> Void
        ) {
            self.onToggleWatchFolder = onToggleWatchFolder
            self.onSelectOutputFolder = onSelectOutputFolder
            self.onToggleMerge = onToggleMerge
            self.onResetAll = onResetAll
            self.onToggleConversion = onToggleConversion
            self.onShowURLInput = onShowURLInput
            self.onShowCapture = onShowCapture
            self.onShowPresetQuickSelect = onShowPresetQuickSelect
            self.onSelectPresetByIndex = onSelectPresetByIndex
            self.onShowShortcuts = onShowShortcuts
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

                // Cmd+D: Show URL Input Overlay (D for Download)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_D {
                    self.onShowURLInput()
                    return nil
                }

                // Cmd+Shift+C: Open Capture Mode
                if hasCommand && hasShift && !hasOption && !hasControl && event.keyCode == kVK_ANSI_C {
                    self.onShowCapture()
                    return nil
                }

                // Cmd+P: Show Preset Quick Select
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_P {
                    self.onShowPresetQuickSelect()
                    return nil
                }

                // Control+K: Show Shortcuts (opens Settings to Shortcuts tab)
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_K {
                    self.onShowShortcuts()
                    return nil
                }

                // Cmd+1 through Cmd+0: Quick select preset by index (only when no sheets are open)
                if hasCommand && !hasOption && !hasShift && !hasControl {
                    let numberKeyCodes: [UInt16] = [
                        UInt16(kVK_ANSI_1), UInt16(kVK_ANSI_2), UInt16(kVK_ANSI_3),
                        UInt16(kVK_ANSI_4), UInt16(kVK_ANSI_5), UInt16(kVK_ANSI_6),
                        UInt16(kVK_ANSI_7), UInt16(kVK_ANSI_8), UInt16(kVK_ANSI_9),
                        UInt16(kVK_ANSI_0)  // 0 = 10th preset
                    ]
                    if let index = numberKeyCodes.firstIndex(of: event.keyCode) {
                        // Only consume event if it was actually handled
                        if self.onSelectPresetByIndex(index) {
                            return nil
                        }
                        // Otherwise pass through to let sheets handle it
                        return event
                    }
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
            // Capture mode now uses CaptureOverlayWindowController instead of a sheet
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
                    if !isConverting {
                        isConverting = await ConversionManager.shared.isConvertingStatus()
                    }
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
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ContentViewNotificationHandlers")

    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
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
                Self.logger.info("Skipping unsupported file from AppIntent: \(url.lastPathComponent, privacy: .public)")
                continue
            }

            droppedFiles.append(placeholder)
            queueOrder.append(placeholder.id)
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
                            queueOrder.append(videoItem.id)
                        }
                    }
                }
            }
            await startConversion()
        }
    }
}
