// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Carbon.HIToolbox
import OSLog

/// Sort mode for the queue list
enum QueueSortMode: CaseIterable {
    case filenameAscending
    case filenameDescending
    case dateOldest
    case dateNewest

    var displayName: String {
        switch self {
        case .filenameAscending: return "Sort by filename: A–Z"
        case .filenameDescending: return "Sort by filename: Z–A"
        case .dateOldest: return "Sort by date: Old–New"
        case .dateNewest: return "Sort by date: New–Old"
        }
    }

    func next() -> QueueSortMode {
        let allCases = QueueSortMode.allCases
        guard let currentIndex = allCases.firstIndex(of: self) else { return .filenameAscending }
        let nextIndex = (currentIndex + 1) % allCases.count
        return allCases[nextIndex]
    }
}

struct VideoFileListView: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoFileListView")
    @Binding var droppedFiles: [VideoItem]
    @Binding var encodingGroups: [EncodingGroup]
    @Binding var currentProgress: Double
    var onFileImport: () -> Void
    var onDoubleClick: () -> Void
    var onDelete: (IndexSet) -> Void
    var onReset: (Int, Bool) -> Void
    var preset: ExportPreset
    var mergeClipsEnabled: Bool
    var mergeClipsAvailable: Bool

    // Callbacks for single-item actions - using UUID for stable reference
    var onOpenTrim: ((UUID) -> Void)?
    var onOpenTrimWithCrop: ((UUID) -> Void)?
    var onOpenTimecode: ((UUID) -> Void)?
    var onOpenAudioConfig: ((UUID) -> Void)?
    var onOpenMetadata: (([UUID]) -> Void)?
    var onOpenDCPMetadata: ((UUID) -> Void)?
    var onOpenIMFMetadata: ((UUID) -> Void)?
    var onToggleDateTag: ((Int) -> Void)?
    var onPlayFullscreen: ((UUID) -> Void)?
    var onURLDrop: ((String) -> Void)?
    var onRenameOutputFileName: ((UUID, String?) -> Void)? = nil
    var encodeOnly: ((UUID) async -> Void)?
    /// Encodes a single group immediately (Option-click on the group's encode
    /// button). Mirrors `encodeOnly` for items.
    var encodeOnlyGroup: ((UUID) async -> Void)?
    var onDeleteGroup: ((UUID) -> Void)?
    var onAddFilesToGroup: ((UUID) -> Void)?
    var onResetGroup: ((UUID) -> Void)?
    /// Called when files are dragged from Finder directly onto a group header.
    /// ContentView resolves these URLs into VideoItems and appends them to the group.
    var onFileDropToGroup: ((UUID, [URL]) -> Void)?
    @Binding var queueOrder: [UUID]
    var onReorder: ((_ movedIDs: [UUID], _ destinationQueueIndex: Int) -> Void)?
    var onQueueSync: (() -> Void)?
    /// Cycles the sort mode of the items inside a specific group (handled in ContentView).
    var onCycleGroupSort: ((UUID) -> Void)?
    /// Opens the dedicated Group Editor window for the given group (handled in ContentView).
    var onOpenGroupEditor: ((UUID) -> Void)?
    /// Opens the Settings window on a specific tab. Triggered by Shift+Cmd-click on a
    /// queue item's Upload/Transcription/Analytics icon (handled in ContentView).
    var onOpenSettingsTab: ((String) -> Void)?
    var disableKeyboardNavigation: Bool = false

    @State private var isTargeted = false
    /// True while an external file drag hovers the queue area (not a group),
    /// reported by the NSTableView. Combined with the empty-state backstop
    /// hover to drive a single dashed-blue queue highlight.
    @State private var isQueueAreaHovered = false
    /// Hover state from the always-on FileDropBackstop NSView. Drives the
    /// highlight in the empty state; in populated mode the table sits on
    /// top so this stays false and `isQueueAreaHovered` takes over.
    @State private var isBackstopHovered = false
    /// Selected row IDs (VideoItem.id) for built-in multi-selection
    @State private var selection = Set<UUID>()
    @State private var focusedCommentID: UUID?
    /// Flag to trigger scroll-to-selection only for keyboard navigation
    @State private var shouldScrollToSelection = false
    /// Current sort mode (nil = original/unsorted order)
    @State private var currentSortMode: QueueSortMode?
    /// Text shown in the bottom-leading toast when the user triggers any kind of
    /// sort (main queue or group). Nil hides the toast. Keeping it as a single
    /// String state lets both sort paths share one overlay and one dismiss timer.
    @State private var sortOverlayText: String?
    /// Work item for dismissing the sort overlay
    @State private var sortOverlayDismissTask: DispatchWorkItem?
    /// Item whose analytics results should be presented, nil = sheet dismissed
    @State private var analyticsResultsItemID: UUID?
    /// Group ID of the most recently created group (via Cmd+N or menu). Drives the
    /// "New group created" toast and its "Scroll to show" button.
    @State private var lastCreatedGroupID: UUID?
    @State private var showGroupCreatedOverlay = false
    @State private var groupCreatedDismissTask: DispatchWorkItem?

    /// Lightweight handle so this view can ask the NSTableView questions (e.g.
    /// whether a specific row is already on screen), instead of duplicating its
    /// scroll state in SwiftUI.
    @StateObject private var tableHandle = QueueTableHandle()


    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted
    @AppStorage(AppConstants.showCommentFieldKey) private var showCommentField = false
    @AppStorage(AppConstants.showDateTagButtonKey) private var showDateTagButton = true
    @AppStorage(AppConstants.queueViewModeKey) private var queueViewMode = AppConstants.defaultQueueViewMode

    private var isCompactMode: Bool { queueViewMode == "compact" }

    @State private var currentTip: LocalizedStringKey = RandomTips.randomTip()

    /// True when any source thinks an external file is being dragged over the
    /// queue area: either the always-on backstop (empty state) or the table's
    /// own validateDrop signal (populated, not over a group). Drives the
    /// dashed-blue highlight overlay.
    private var isDropTargetActive: Bool {
        isTargeted || isQueueAreaHovered || isBackstopHovered
    }

    var body: some View {
        ZStack {
            // Always-on AppKit drop target sitting behind everything. SwiftUI's
            // `.onDrop` stopped firing reliably once the NSTableView landed, so we
            // route external file drops through this backstop in the empty state
            // (and rely on the table's own drop handler when populated).
            FileDropBackstop(isHovering: $isBackstopHovered) { urls in
                Task { @MainActor in await importURLs(urls) }
            }

            if droppedFiles.isEmpty && encodingGroups.isEmpty {
                // Empty state with drag and drop instructions
                VStack {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                        .padding()
                        .padding(.top, 36)
                    Text("Drag and drop video files here")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("or double-click to import files")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                        .padding(.bottom, 24)

                    VStack {
                        Text(currentTip)
                            .font(.callout)
                            .foregroundColor(.secondary.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .padding(.top, 12)
                            .padding(.bottom, 30)
                        Text("Control + R to load a new random tip")
                            .font(.footnote)
                            .foregroundColor(.secondary.opacity(0.8))
                        Spacer()
                    }.frame(width: 500,height: 86)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
            } else {
                // File list - AppKit NSTableView for cell reuse and smooth scrolling
                VideoQueueTableView(
                    droppedFiles: $droppedFiles,
                    encodingGroups: $encodingGroups,
                    selection: $selection,
                    focusedCommentID: $focusedCommentID,
                    shouldScrollToSelection: $shouldScrollToSelection,
                    isCompactMode: isCompactMode,
                    preset: preset,
                    mergeClipsEnabled: mergeClipsEnabled,
                    mergeClipsAvailable: mergeClipsAvailable,
                    showCommentField: showCommentField,
                    showDateTagButton: showDateTagButton,
                    onTabCommentField: { forward in
                        handleTabPress(forward: forward)
                    },
                    onDelete: onDelete,
                    onReset: onReset,
                    onOpenTrim: onOpenTrim,
                    onOpenTrimWithCrop: onOpenTrimWithCrop,
                    onOpenTimecode: onOpenTimecode,
                    onOpenAudioConfig: onOpenAudioConfig,
                    onOpenMetadata: onOpenMetadata,
                    onOpenDCPMetadata: onOpenDCPMetadata,
                    onOpenIMFMetadata: onOpenIMFMetadata,
                    onOpenAnalyticsResults: { itemID in
                        analyticsResultsItemID = itemID
                    },
                    onToggleDateTag: onToggleDateTag,
                    onPlayFullscreen: onPlayFullscreen,
                    onRenameOutputFileName: onRenameOutputFileName,
                    encodeOnly: { itemID in
                        await encodeOnly?(itemID)
                    },
                    encodeOnlyGroup: { groupID in
                        await encodeOnlyGroup?(groupID)
                    },
                    transcribeOnly: { itemID, method in
                        await transcribeOnly(itemID: itemID, method: method)
                    },
                    analyzeOnly: { itemID in
                        await analyzeOnly(itemID: itemID)
                    },
                    analyzeMetrics: { itemID, metrics in
                        await analyzeMetrics(itemID: itemID, metrics: metrics)
                    },
                    onDeleteGroup: onDeleteGroup,
                    onAddFilesToGroup: onAddFilesToGroup,
                    onResetGroup: onResetGroup,
                    queueOrder: queueOrder,
                    onReorder: onReorder,
                    onQueueSync: onQueueSync,
                    onCycleGroupSort: { groupID in
                        cycleGroupSort(groupID: groupID)
                    },
                    onOpenGroupEditor: onOpenGroupEditor,
                    handle: tableHandle,
                    onFileDropToGroup: onFileDropToGroup,
                    onFileDropToMainQueue: { urls in
                        Task { @MainActor in
                            await importURLs(urls)
                        }
                    },
                    onQueueAreaDropHover: { hovered in
                        isQueueAreaHovered = hovered
                    },
                    onOpenSettingsTab: onOpenSettingsTab
                )
                .onChange(of: selection) { _, newSelection in
                    // Sync selection to metadata window state
                    MetadataWindowState.shared.selectedItemIDs = newSelection
                }
                .onChange(of: droppedFiles) { _, newFiles in
                    // Sync all items (including group items) to metadata window state
                    let groupItems = encodingGroups.flatMap { $0.items }
                    MetadataWindowState.shared.allItems = newFiles + groupItems
                }
                .onChange(of: encodingGroups) { _, newGroups in
                    let groupItems = newGroups.flatMap { $0.items }
                    MetadataWindowState.shared.allItems = droppedFiles + groupItems
                }
            }
            
            // Drag-and-drop highlight. Drawn whenever any source — backstop,
            // SwiftUI .onDrop, or the table's "queue area but not over a group"
            // signal — reports an active file drag. Lets users see the drop target
            // even in populated mode where the NSTableView normally claims the drag.
            if isDropTargetActive {
                Color.blue.opacity(0.1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                            .foregroundColor(.blue)
                    )
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let text = sortOverlayText {
                SortModeOverlay(text: text)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sortOverlayText)
        .overlay(alignment: .bottomTrailing) {
            if showGroupCreatedOverlay {
                GroupCreatedOverlay(
                    onScrollToGroup: { scrollToLastCreatedGroup() },
                    onDismiss: { dismissGroupCreatedOverlay() }
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showGroupCreatedOverlay)
        .onReceive(NotificationCenter.default.publisher(for: .encodingGroupCreated)) { notification in
            guard let groupID = notification.userInfo?["groupID"] as? UUID else { return }
            lastCreatedGroupID = groupID
            // Always select the new group so the selection border makes it pop.
            selection = [groupID]
            // Defer the visibility check until after the table has processed the
            // new row — the row only gets a valid rect once updateNSView runs.
            DispatchQueue.main.async {
                if tableHandle.isRowVisible(for: groupID) {
                    // Already on screen — selection highlight is enough, no toast.
                    return
                }
                showGroupCreatedOverlay = true
                groupCreatedDismissTask?.cancel()
                let task = DispatchWorkItem { showGroupCreatedOverlay = false }
                groupCreatedDismissTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: task)
            }
        }
        .sheet(isPresented: Binding(
            get: { analyticsResultsItemID != nil },
            set: { if !$0 { analyticsResultsItemID = nil } }
        )) {
            analyticsResultsSheetContent
        }
        // External file drops are handled by FileDropBackstop in the empty state
        // and by VideoQueueTableView when populated. URL/text drops (yt-dlp links,
        // shared text) still come through SwiftUI's drop handler since the
        // backstop only registers fileURL.
        .onDrop(of: [.url, .plainText], isTargeted: $isTargeted) { providers in
            return handleDrop(providers: providers)
        }
        .overlay(alignment: .topLeading) {
            ZStack {
                KeyEventHandlingView(
                    onTabForward: { handleTabPress(forward: true) },
                    onTabBackward: { handleTabPress(forward: false) },
                    onTrim: handleTrimShortcut,
                    onCrop: handleCropShortcut,
                    onTimecode: handleTimecodeShortcut,
                    onAudioConfig: handleAudioConfigShortcut,
                    onMetadata: handleMetadataShortcut,
                    onToggleDateTag: handleToggleDateTagShortcut,
                    onPlayFullscreen: handlePlayFullscreenShortcut,
                    onMoveUp: { handleMoveSelection(direction: .up) },
                    onMoveDown: { handleMoveSelection(direction: .down) },
                    onResetSelected: handleResetSelectedShortcut,
                    onDeselectAll: { selection.removeAll() },
                    onToggleMute: handleToggleMuteShortcut,
                    onToggleUpload: handleToggleUploadShortcut,
                    onToggleSourceUpload: handleToggleSourceUploadShortcut,
                    onToggleSubtitles: handleToggleSubtitlesShortcut,
                    onToggleAutoEncode: handleToggleAutoEncodeShortcut,
                    onNavigateUp: { handleNavigateSelection(direction: .up) },
                    onNavigateDown: { handleNavigateSelection(direction: .down) },
                    onSort: handleSortShortcut,
                    onDelete: deleteSelectedItems,
                    onPrimaryPreview: handlePlayFullscreenShortcut,
                    onPrimaryAction: handleTrimShortcut,
                    onSelectAll: selectAllItems,
                    disableNavigation: disableKeyboardNavigation
                )

                // Control+R to show a new random tip
                Button(action: { currentTip = RandomTips.randomTip() }) {
                    EmptyView()
                }
                .keyboardShortcut("r", modifiers: [.control])
                .frame(width: 0, height: 0)
                .opacity(0)
            }
        }
        .onChange(of: droppedFiles.isEmpty) { wasEmpty, isEmpty in
            // Show a new random tip when the queue becomes empty
            if !wasEmpty && isEmpty {
                currentTip = RandomTips.randomTip()
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            await self.importProviders(providers)
        }
        return true
    }

    /// Selects the newly created group and flips `shouldScrollToSelection`, which the
    /// NSTableView picks up in `updateNSView` to scroll that row into view. Also
    /// clears the toast so the user sees the group instead of a lingering banner.
    private func scrollToLastCreatedGroup() {
        guard let id = lastCreatedGroupID else { return }
        selection = [id]
        shouldScrollToSelection = true
        dismissGroupCreatedOverlay()
    }

    private func dismissGroupCreatedOverlay() {
        groupCreatedDismissTask?.cancel()
        groupCreatedDismissTask = nil
        showGroupCreatedOverlay = false
    }

    /// Imports a list of concrete file URLs into the main queue. Used by the
    /// NSTableView's external-file-drop handler, which already has resolved URLs
    /// (the NSItemProvider path is only used by SwiftUI's outer .onDrop).
    @MainActor
    private func importURLs(_ urls: [URL]) async {
        let supported = AppConstants.supportedVideoExtensions
        for url in urls {
            let hadAccess = url.startAccessingSecurityScopedResource()
            await self.processFileURL(url, supportedExtensions: supported, hasSecurityAccess: hadAccess)
        }
    }

    @MainActor
    private func importProviders(_ providers: [NSItemProvider]) async {
        let supportedExtensions = AppConstants.supportedVideoExtensions
        let logger = Self.logger

        for provider in providers {
            // Use the proper API to load file URLs
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error = error {
                        logger.error("Error loading URL: \(error.localizedDescription, privacy: .public)")
                        return
                    }
                    if let url = url {
                        // For drag and drop, the URL already has temporary access
                        // We need to start accessing the security-scoped resource immediately
                        let hasAccess = url.startAccessingSecurityScopedResource()

                        Task { @MainActor in
                            await self.processFileURL(url, supportedExtensions: supportedExtensions, hasSecurityAccess: hasAccess)
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func processFileURL(_ url: URL, supportedExtensions: Set<String>, hasSecurityAccess: Bool = false) async {
        // Get the file extension and check if it's supported
        let fileExtension = url.pathExtension.lowercased()

        guard !fileExtension.isEmpty,
              supportedExtensions.contains(fileExtension) else {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            }
            return
        }

        // Handle security-scoped access based on the source
        var needsBookmarkAccess = false
        if !hasSecurityAccess {
            // Attempt to use an existing bookmark for persistent access
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                needsBookmarkAccess = true
            } else {
                // No bookmark found – rely on direct entitlements (e.g. Downloads/Movie directory access)
                if FileManager.default.isReadableFile(atPath: url.path) {
                } else {
                    Self.logger.error("No bookmark and file not readable - access denied")
                    return
                }
            }
        }

        var shouldReleaseImmediately = true
        let releaseSecurityAccess: () -> Void = {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
            } else if needsBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            }
        }
        defer {
            if shouldReleaseImmediately {
                releaseSecurityAccess()
            }
        }

        // Save the bookmark for future access
        _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)

        // Get the output folder from UserDefaults or use default
        let outputFolder = UserDefaults.standard.string(forKey: "outputFolder")
            ?? AppConstants.defaultOutputDirectory.path

        guard let placeholder = VideoFileUtils.makePlaceholderItem(from: url, outputFolder: outputFolder, preset: preset) else {
            Self.logger.error("Failed to create placeholder video item")
            return
        }

        // Check for duplicates before adding
        if self.droppedFiles.contains(where: { $0.url == placeholder.url }) {
            return
        }

        self.droppedFiles.append(placeholder)
        onQueueSync?()
        // Auto-mute if VideoLoop preset is selected and setting is enabled
        if preset == .videoLoop && videoLoopDefaultMuted {
            droppedFiles[droppedFiles.count - 1].isMuted = true
        }
        let placeholderID = placeholder.id

        Task(priority: .utility) {
            defer { releaseSecurityAccess() }

            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)

            let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: preset)
            await MainActor.run {
                if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                    self.droppedFiles[index].apply(details: details)
                    self.droppedFiles[index].detailsLoaded = true
                }
            }
        }
        shouldReleaseImmediately = false
    }
    
    private func handleTabPress(forward: Bool) {
        focusComment(forward: forward, currentFocused: focusedCommentID)
    }

    private func focusComment(forward: Bool, currentFocused: UUID?) {
        guard !droppedFiles.isEmpty else { return }

        let sortedSelectionIndices = selection
            .compactMap { selectedID in droppedFiles.firstIndex(where: { $0.id == selectedID }) }
            .sorted()

        if let currentIndex = sortedSelectionIndices.first {
            let currentID = droppedFiles[currentIndex].id
            if currentFocused == currentID,
               let nextIndex = nextIndex(from: currentIndex, forward: forward) {
                let nextID = droppedFiles[nextIndex].id
                // Clear focus first, then update selection, then set new focus
                // This prevents the old row's deselection handler from clearing our new focus
                focusedCommentID = nil
                selection = [nextID]
                shouldScrollToSelection = true
                // Use async to ensure selection change is processed before setting new focus
                DispatchQueue.main.async {
                    self.focusedCommentID = nextID
                }
            } else {
                focusedCommentID = currentID
                shouldScrollToSelection = true
            }
            return
        }

        if let currentFocused,
           let currentIndex = droppedFiles.firstIndex(where: { $0.id == currentFocused }) {
            if let nextIndex = nextIndex(from: currentIndex, forward: forward) {
                let nextID = droppedFiles[nextIndex].id
                // Clear focus first, then update selection, then set new focus
                focusedCommentID = nil
                selection = [nextID]
                shouldScrollToSelection = true
                DispatchQueue.main.async {
                    self.focusedCommentID = nextID
                }
            }
            return
        }

        let startIndex = forward ? 0 : max(droppedFiles.count - 1, 0)
        let startID = droppedFiles[startIndex].id
        selection = [startID]
        shouldScrollToSelection = true
        // Use async to ensure selection change is processed before setting focus
        DispatchQueue.main.async {
            self.focusedCommentID = startID
        }
    }

    private func nextIndex(from currentIndex: Int, forward: Bool) -> Int? {
        guard !droppedFiles.isEmpty else { return nil }
        let delta = forward ? 1 : -1
        let nextIndex = (currentIndex + delta + droppedFiles.count) % droppedFiles.count
        return nextIndex
    }

    private func deleteSelectedItems() {
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }
        let indices = IndexSet(selectedIndices)
        guard !indices.isEmpty else { return }
        onDelete(indices)
        selection.removeAll()
        focusedCommentID = nil
    }

    private func selectAllItems() {
        var allIDs = Set<UUID>()
        for item in droppedFiles { allIDs.insert(item.id) }
        for group in encodingGroups {
            allIDs.insert(group.id)
            for item in group.items { allIDs.insert(item.id) }
        }
        selection = allIDs
    }
    
    // MARK: - Keyboard Shortcut Handlers
    
    /// Returns the UUID of the single selected item, or nil if zero or multiple items are selected
    private var singleSelectedID: UUID? {
        guard selection.count == 1,
              let selectedID = selection.first else {
            return nil
        }
        // Verify the ID exists in droppedFiles or in an encoding group
        let inDroppedFiles = droppedFiles.contains(where: { $0.id == selectedID })
        let inEncodingGroup = encodingGroups.contains(where: { group in
            group.items.contains(where: { $0.id == selectedID })
        })
        guard inDroppedFiles || inEncodingGroup else {
            return nil
        }
        return selectedID
    }
    
    /// Returns the index of the single selected item, or nil if zero or multiple items are selected
    private var singleSelectedIndex: Int? {
        guard let id = singleSelectedID,
              let index = droppedFiles.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return index
    }
    
    private func handleTrimShortcut() {
        guard let id = singleSelectedID else { return }
        onOpenTrim?(id)
    }
    
    private func handleCropShortcut() {
        guard let id = singleSelectedID else { return }
        onOpenTrimWithCrop?(id)
    }
    
    private func handleTimecodeShortcut() {
        guard let id = singleSelectedID else { return }
        onOpenTimecode?(id)
    }
    
    private func handleAudioConfigShortcut() {
        guard let id = singleSelectedID else { return }
        onOpenAudioConfig?(id)
    }
    
    private func handleMetadataShortcut() {
        // Support both single and multiple selection for metadata comparison
        let selectedIDs = selection.filter { selectedID in
            let inDroppedFiles = droppedFiles.contains(where: { $0.id == selectedID })
            let inEncodingGroup = encodingGroups.contains(where: { group in
                group.items.contains(where: { $0.id == selectedID })
            })
            return inDroppedFiles || inEncodingGroup
        }
        guard !selectedIDs.isEmpty else { return }
        onOpenMetadata?(Array(selectedIDs))
    }
    
    private func handleToggleDateTagShortcut() {
        guard let index = singleSelectedIndex else { return }
        onToggleDateTag?(index)
    }
    
    private func handlePlayFullscreenShortcut() {
        guard let id = singleSelectedID else { return }
        // Check if the item has a video stream
        if let index = droppedFiles.firstIndex(where: { $0.id == id }),
           droppedFiles[index].hasVideoStream {
            onPlayFullscreen?(id)
        }
    }
    
    private func handleResetSelectedShortcut() {
        // Works with single or multi-selection
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        // Check if Option key is pressed
        let optionKeyPressed = NSEvent.modifierFlags.contains(.option)

        for index in selectedIndices {
            onReset(index, optionKeyPressed)
        }
    }

    private func handleToggleMuteShortcut() {
        // Works with single or multi-selection
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        for index in selectedIndices {
            droppedFiles[index].isMuted.toggle()
        }
    }

    private func handleToggleUploadShortcut() {
        // Works with single or multi-selection
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        // Only toggle if upload is configured
        guard UploadManager.shared.isConfigured else { return }

        for index in selectedIndices {
            droppedFiles[index].uploadEnabled.toggle()
            // Clear source upload when disabling upload
            if !droppedFiles[index].uploadEnabled {
                droppedFiles[index].uploadSourceFile = false
            }
        }
    }

    private func handleToggleSourceUploadShortcut() {
        // Works with single or multi-selection - toggles source file upload
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        // Only toggle if upload is configured
        guard UploadManager.shared.isConfigured else { return }

        for index in selectedIndices {
            droppedFiles[index].uploadSourceFile.toggle()
            // Enable upload when enabling source upload
            if droppedFiles[index].uploadSourceFile {
                droppedFiles[index].uploadEnabled = true
                // Start upload immediately for source files
                let itemID = droppedFiles[index].id
                Task {
                    await UploadManager.shared.startUpload(itemID: itemID)
                }
            }
        }
    }

    private func handleToggleSubtitlesShortcut() {
        // Works with single or multi-selection
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        for index in selectedIndices {
            droppedFiles[index].subtitleEnabled.toggle()
        }
    }

    private func handleToggleAutoEncodeShortcut() {
        // Works with single or multi-selection - only affects download items
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        for index in selectedIndices {
            // Only toggle for items that are downloading or scheduled
            if droppedFiles[index].isDownloading || droppedFiles[index].scheduledDownloadTime != nil {
                droppedFiles[index].autoEncodeAfterDownload.toggle()
            }
        }
    }

    private enum MoveDirection {
        case up, down
    }
    
    private func handleMoveSelection(direction: MoveDirection) {
        // Move top-level queue entries (single files + groups) via the authoritative
        // `queueOrder` through the existing onReorder callback. Children inside groups
        // aren't top-level, so they get filtered out.
        let topLevelPositions = selection
            .compactMap { queueOrder.firstIndex(of: $0) }
            .sorted()
        guard !topLevelPositions.isEmpty else { return }

        let movedIDs = topLevelPositions.map { queueOrder[$0] }
        let toRemove = Set(movedIDs)
        var remaining = queueOrder
        remaining.removeAll { toRemove.contains($0) }

        switch direction {
        case .up:
            guard let minPos = topLevelPositions.min(), minPos > 0 else { return }
            let targetItem = queueOrder[minPos - 1]
            let insertAt = remaining.firstIndex(of: targetItem) ?? 0
            onReorder?(movedIDs, insertAt)

        case .down:
            guard let maxPos = topLevelPositions.max(), maxPos < queueOrder.count - 1 else { return }
            let targetItem = queueOrder[maxPos + 1]
            let insertAt = (remaining.firstIndex(of: targetItem) ?? remaining.count) + 1
            onReorder?(movedIDs, insertAt)
        }
        shouldScrollToSelection = true
    }

    private func handleNavigateSelection(direction: MoveDirection) {
        // Navigate the visible queue (`queueOrder`) — singles and group headers —
        // not `droppedFiles`, which stays in insertion order and drifts away from
        // the rendered order after a drag-reorder.
        guard !queueOrder.isEmpty else { return }

        let topLevelPositions = selection
            .compactMap { queueOrder.firstIndex(of: $0) }
            .sorted()

        // No top-level entry selected (empty selection, or only group children
        // selected): jump to the first/last visible row based on direction.
        guard let currentIndex = topLevelPositions.first else {
            switch direction {
            case .down:
                if let firstID = queueOrder.first { selection = [firstID] }
            case .up:
                if let lastID = queueOrder.last { selection = [lastID] }
            }
            shouldScrollToSelection = true
            return
        }

        switch direction {
        case .up:
            let newIndex = max(0, currentIndex - 1)
            selection = [queueOrder[newIndex]]
        case .down:
            let newIndex = min(queueOrder.count - 1, currentIndex + 1)
            selection = [queueOrder[newIndex]]
        }
        shouldScrollToSelection = true
    }

    private func handleSortShortcut() {
        guard droppedFiles.count + encodingGroups.count > 1 else { return }

        // Cycle to the next sort mode
        let nextMode: QueueSortMode = currentSortMode?.next() ?? .filenameAscending
        currentSortMode = nextMode

        // Keep `droppedFiles` sorted for any consumer that iterates it directly.
        droppedFiles.sort(by: comparator(for: nextMode))

        // Sort the actual render order (which is `queueOrder`, not `droppedFiles`).
        // Groups are sorted alongside singles — groups use their name as the
        // filename key and the earliest child's creation date as the date key —
        // but items *inside* a group are left alone; only per-group sort touches
        // those.
        queueOrder.sort { queueEntryLessThan($0, $1, mode: nextMode) }

        showSortToast(nextMode.displayName)
    }

    /// Resolves a queue-order ID (single item OR group) into the two keys the
    /// sort modes compare against: a display name and a representative date.
    /// For groups, the date is the oldest child's creation date — that way
    /// "sort by date" keeps groups next to items with similar recency.
    private func queueEntryLessThan(_ a: UUID, _ b: UUID, mode: QueueSortMode) -> Bool {
        let (nameA, dateA) = queueEntrySortKey(a)
        let (nameB, dateB) = queueEntrySortKey(b)
        switch mode {
        case .filenameAscending:  return nameA.localizedStandardCompare(nameB) == .orderedAscending
        case .filenameDescending: return nameA.localizedStandardCompare(nameB) == .orderedDescending
        case .dateOldest:         return dateA < dateB
        case .dateNewest:         return dateA > dateB
        }
    }

    private func queueEntrySortKey(_ id: UUID) -> (name: String, date: Date) {
        if let file = droppedFiles.first(where: { $0.id == id }) {
            return (file.name, fileCreationDate(for: file.url))
        }
        if let group = encodingGroups.first(where: { $0.id == id }) {
            let earliest = group.items.map { fileCreationDate(for: $0.url) }.min() ?? Date.distantPast
            return (group.name, earliest)
        }
        return ("", Date.distantPast)
    }

    /// Shows the bottom-leading toast with `text` for 3.5s. Replaces any in-flight
    /// dismiss so back-to-back sort cycles read as one toast updating its label.
    private func showSortToast(_ text: String) {
        sortOverlayDismissTask?.cancel()
        sortOverlayText = text
        let task = DispatchWorkItem { sortOverlayText = nil }
        sortOverlayDismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }

    private func fileCreationDate(for url: URL) -> Date {
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey])
        return resourceValues?.creationDate ?? Date.distantPast
    }

    /// Shared comparator used by main-queue sort and per-group sort so ordering is
    /// consistent whether you sort the whole queue or just one group's contents.
    private func comparator(for mode: QueueSortMode) -> (VideoItem, VideoItem) -> Bool {
        switch mode {
        case .filenameAscending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .filenameDescending:
            return { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateOldest:
            return { [self] in fileCreationDate(for: $0.url) < fileCreationDate(for: $1.url) }
        case .dateNewest:
            return { [self] in fileCreationDate(for: $0.url) > fileCreationDate(for: $1.url) }
        }
    }

    /// Cycles a group's internal sort mode on each click. State is stored on the
    /// group itself (`lastSortMode`) so the next click resumes from where the user
    /// left off — mirroring how the main queue's `currentSortMode` works.
    private func cycleGroupSort(groupID: UUID) {
        guard let gIdx = encodingGroups.firstIndex(where: { $0.id == groupID }),
              encodingGroups[gIdx].items.count > 1 else { return }
        let nextMode = encodingGroups[gIdx].lastSortMode?.next() ?? .filenameAscending
        encodingGroups[gIdx].items.sort(by: comparator(for: nextMode))
        encodingGroups[gIdx].lastSortMode = nextMode
        if encodingGroups[gIdx].sequentialNamingEnabled {
            encodingGroups[gIdx].normalizeSequentialNaming()
        }
        // Surface the new mode in the same toast the main-queue sort uses so users
        // get immediate feedback on what happened.
        let groupName = encodingGroups[gIdx].name
        let label = groupName.isEmpty ? "Group" : "“\(groupName)”"
        showSortToast("\(label) · \(nextMode.displayName)")
    }

    // MARK: - Transcribe Only (Option+click)

    /// Generates subtitles directly from source file without encoding
    private func transcribeOnly(itemID: UUID, method: SubtitleConversionMethod) async {
        switch method {
        case .ocr:
            await transcribeOnlyOCR(itemID: itemID)
        case .whisper:
            await transcribeOnlyWhisper(itemID: itemID)
        case .parakeet:
            await transcribeOnlyParakeet(itemID: itemID)
        }
    }

    private func transcribeOnlyWhisper(itemID: UUID) async {
        // Find the item
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let inputURL = droppedFiles[index].url
        let audioStreamIndex = droppedFiles[index].selectedAudioStreamIndex

        // Get model from settings
        let modelRaw = UserDefaults.standard.string(forKey: AppConstants.whisperModelKey) ?? "base"
        let model = WhisperModel(rawValue: modelRaw) ?? .base

        // Get language from settings
        let language = UserDefaults.standard.string(forKey: AppConstants.whisperLanguageKey) ?? "auto"

        // Check if model is downloaded (nonisolated, no await needed)
        guard WhisperModelManager.shared.isModelDownloaded(model) else {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed("Model '\(model.displayName)' not downloaded")
                }
            }
            return
        }

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                droppedFiles[idx].subtitleStatus = .pending
            }
        }

        do {
            let srtURL = try await WhisperService.shared.generateSubtitlesOnly(
                inputFile: inputURL,
                model: model,
                language: language,
                audioStreamIndex: audioStreamIndex
            ) { whisperProgress in
                Task { @MainActor in
                    if let idx = self.droppedFiles.firstIndex(where: { $0.id == itemID }),
                       self.droppedFiles[idx].subtitleStatus.isInProgress {
                        switch whisperProgress.stage {
                        case .extractingAudio:
                            self.droppedFiles[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            self.droppedFiles[idx].subtitleStatus = .generating(progress: whisperProgress.percentage)
                        case .complete:
                            self.droppedFiles[idx].subtitleStatus = .completed
                        case .failed(let error):
                            self.droppedFiles[idx].subtitleStatus = .failed(error)
                        default:
                            break
                        }
                        self.droppedFiles[idx].subtitleProgress = whisperProgress.percentage
                    }
                }
            }

            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .completed
                    droppedFiles[idx].subtitleFilePath = srtURL
                    droppedFiles[idx].subtitleProgress = 1.0
                }
            }
            Self.logger.info("Transcribe-only completed: \(srtURL.lastPathComponent, privacy: .public)")

        } catch WhisperServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .notQueued
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed(error.localizedDescription)
                }
            }
            Self.logger.error("Transcribe-only failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribeOnlyParakeet(itemID: UUID) async {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }

        let inputURL = droppedFiles[index].url
        let audioStreamIndex = droppedFiles[index].selectedAudioStreamIndex

        // Get model from settings
        let modelId = UserDefaults.standard.string(forKey: AppConstants.parakeetModelKey) ?? AppConstants.defaultParakeetModel
        let model = ParakeetModel.model(for: modelId) ?? ParakeetModel.allModels[0]

        // Get language from settings
        let language = UserDefaults.standard.string(forKey: AppConstants.parakeetLanguageKey) ?? AppConstants.defaultParakeetLanguage

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                droppedFiles[idx].subtitleStatus = .pending
            }
        }

        do {
            let srtURL = try await ParakeetService.shared.generateSubtitlesOnly(
                inputFile: inputURL,
                model: model,
                language: language,
                audioStreamIndex: audioStreamIndex
            ) { parakeetProgress in
                Task { @MainActor in
                    if let idx = self.droppedFiles.firstIndex(where: { $0.id == itemID }),
                       self.droppedFiles[idx].subtitleStatus.isInProgress {
                        switch parakeetProgress.stage {
                        case .extractingAudio:
                            self.droppedFiles[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            self.droppedFiles[idx].subtitleStatus = .generating(progress: parakeetProgress.percentage)
                        case .complete:
                            self.droppedFiles[idx].subtitleStatus = .completed
                        case .failed(let error):
                            self.droppedFiles[idx].subtitleStatus = .failed(error)
                        }
                        self.droppedFiles[idx].subtitleProgress = parakeetProgress.percentage
                    }
                }
            }

            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .completed
                    droppedFiles[idx].subtitleFilePath = srtURL
                    droppedFiles[idx].subtitleProgress = 1.0
                }
            }
            Self.logger.info("Parakeet transcribe-only completed: \(srtURL.lastPathComponent, privacy: .public)")

        } catch ParakeetServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .notQueued
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed(error.localizedDescription)
                }
            }
            Self.logger.error("Parakeet transcribe-only failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func transcribeOnlyOCR(itemID: UUID) async {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }

        let sourceURL = droppedFiles[index].url
        let metadata  = droppedFiles[index].metadata
        let chosenStreamIndex = droppedFiles[index].selectedBitmapSubtitleStreamIndex

        // FFprobe-style + Matroska container IDs (SwiftExif's MKV reader surfaces the latter).
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "s_hdmv/pgs", "s_vobsub"]
        guard let stream = metadata?.subtitleStreams.first(where: {
            if let chosen = chosenStreamIndex { return $0.index == chosen }
            return bitmapCodecs.contains($0.codec?.lowercased() ?? "")
        }) else {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed("No bitmap subtitle stream found")
                }
            }
            return
        }

        let streamIndex = stream.index ?? 0
        let codec = stream.codec ?? "pgssub"
        let engineKind = OCREngineKind.userPreferred
        let language: String = {
            if let streamLang = stream.languageCode { return streamLang }
            switch engineKind {
            case .tesseract:
                return UserDefaults.standard.string(forKey: AppConstants.tesseractLanguageKey)
                    ?? AppConstants.defaultTesseractLanguage
            case .appleVision:
                return UserDefaults.standard.string(forKey: AppConstants.visionLanguageKey)
                    ?? AppConstants.defaultVisionLanguage
            }
        }()

        if engineKind == .tesseract, BinaryPathResolver.tesseractPath == nil {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed("Tesseract not found. Configure in Settings → OCR.")
                }
            }
            return
        }

        await MainActor.run {
            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                droppedFiles[idx].subtitleStatus = .pending
            }
        }

        do {
            let srtURL = try await TesseractService.shared.generateSubtitlesOnly(
                sourceFile: sourceURL,
                subtitleStreamIndex: streamIndex,
                codec: codec,
                language: language
            ) { ocrProgress in
                Task { @MainActor in
                    if let idx = self.droppedFiles.firstIndex(where: { $0.id == itemID }),
                       self.droppedFiles[idx].subtitleStatus.isInProgress {
                        switch ocrProgress.stage {
                        case .extractingTrack, .parsingFrames:
                            self.droppedFiles[idx].subtitleStatus = .extractingAudio
                        case .recognizing:
                            self.droppedFiles[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        case .writingSRT:
                            self.droppedFiles[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        case .complete:
                            self.droppedFiles[idx].subtitleStatus = .completed
                        case .failed(let error):
                            self.droppedFiles[idx].subtitleStatus = .failed(error)
                        }
                        self.droppedFiles[idx].subtitleProgress = ocrProgress.percentage
                    }
                }
            }

            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .completed
                    droppedFiles[idx].subtitleFilePath = srtURL
                    droppedFiles[idx].subtitleProgress = 1.0
                }
            }
            Self.logger.info("OCR-only completed: \(srtURL.lastPathComponent, privacy: .public)")

        } catch TesseractServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .notQueued
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].subtitleStatus = .failed(error.localizedDescription)
                }
            }
            Self.logger.error("OCR-only failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Analyze Only (run analytics on already-encoded item)

    /// Runs quality analytics on a completed item using source and output files
    private func analyzeOnly(itemID: UUID) async {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let sourceURL = droppedFiles[index].url
        guard let encodedURL = droppedFiles[index].outputURL else {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].analyticsStatus = .failed("No encoded output file available")
                }
            }
            return
        }

        // Load analytics config from settings
        let enabledMetricsRaw = UserDefaults.standard.stringArray(forKey: AppConstants.analyticsEnabledMetricsKey)
            ?? AppConstants.defaultAnalyticsEnabledMetrics
        let enabledMetrics = enabledMetricsRaw.compactMap { QualityMetric(rawValue: $0) }
        let vmafModelRaw = UserDefaults.standard.string(forKey: AppConstants.analyticsVMAFModelKey)
            ?? AppConstants.defaultAnalyticsVMAFModel
        let vmafModel = VMAFModel(rawValue: vmafModelRaw) ?? .vmaf_v0_6_1

        guard !enabledMetrics.isEmpty else {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].analyticsStatus = .failed("No metrics enabled in Settings > Analytics")
                }
            }
            return
        }

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                droppedFiles[idx].analyticsStatus = .pending
            }
        }

        do {
            let results = try await AnalyticsService.shared.runAnalytics(
                sourceFile: sourceURL,
                encodedFile: encodedURL,
                enabledMetrics: enabledMetrics,
                vmafModel: vmafModel
            ) { metric, progressValue in
                Task { @MainActor in
                    if let idx = self.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        // Drop in-flight progress updates that arrive after cancellation.
                        guard self.droppedFiles[idx].analyticsStatus.isInProgress else { return }
                        self.droppedFiles[idx].analyticsStatus = .running(metric: metric, progress: progressValue)
                        self.droppedFiles[idx].analyticsProgress = progressValue
                    }
                }
            }

            let durationSeconds = droppedFiles.first(where: { $0.id == itemID })?.durationSeconds ?? 0

            let analyticsResults = AnalyticsResults(
                sourceFileName: sourceURL.lastPathComponent,
                encodedFileName: encodedURL.lastPathComponent,
                metrics: results,
                timestamp: Date(),
                durationSeconds: durationSeconds
            )

            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].analyticsStatus = .completed
                    droppedFiles[idx].analyticsResults = analyticsResults
                    droppedFiles[idx].analyticsProgress = 1.0
                }
                AnalyticsExporter.autoExportIfEnabled(results: analyticsResults, encodedFileURL: encodedURL)
            }

            Self.logger.info("Analyze-only completed for \(encodedURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    if case AnalyticsError.cancelled = error {
                        // User-initiated cancel already set status to .notQueued; don't overwrite.
                        return
                    }
                    droppedFiles[idx].analyticsStatus = .failed(error.localizedDescription)
                }
            }
            Self.logger.error("Analyze-only failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Runs specific quality metrics and merges results with existing analytics
    func analyzeMetrics(itemID: UUID, metrics: [QualityMetric]) async {
        guard let index = droppedFiles.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        let sourceURL = droppedFiles[index].url
        guard let encodedURL = droppedFiles[index].outputURL else {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles[idx].analyticsStatus = .failed("No encoded output file available")
                }
            }
            return
        }

        let vmafModelRaw = UserDefaults.standard.string(forKey: AppConstants.analyticsVMAFModelKey)
            ?? AppConstants.defaultAnalyticsVMAFModel
        let vmafModel = VMAFModel(rawValue: vmafModelRaw) ?? .vmaf_v0_6_1

        await MainActor.run {
            if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                droppedFiles[idx].analyticsStatus = .pending
            }
        }

        do {
            let newResults = try await AnalyticsService.shared.runAnalytics(
                sourceFile: sourceURL,
                encodedFile: encodedURL,
                enabledMetrics: metrics,
                vmafModel: vmafModel
            ) { metric, progressValue in
                Task { @MainActor in
                    if let idx = self.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        // Drop in-flight progress updates that arrive after cancellation.
                        guard self.droppedFiles[idx].analyticsStatus.isInProgress else { return }
                        self.droppedFiles[idx].analyticsStatus = .running(metric: metric, progress: progressValue)
                        self.droppedFiles[idx].analyticsProgress = progressValue
                    }
                }
            }

            let durationSeconds = droppedFiles.first(where: { $0.id == itemID })?.durationSeconds ?? 0

            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    // Merge new results with existing
                    var existingMetrics = droppedFiles[idx].analyticsResults?.metrics ?? []
                    let newMetricTypes = Set(newResults.map(\.metric))
                    existingMetrics.removeAll { newMetricTypes.contains($0.metric) }
                    existingMetrics.append(contentsOf: newResults)

                    droppedFiles[idx].analyticsResults = AnalyticsResults(
                        sourceFileName: sourceURL.lastPathComponent,
                        encodedFileName: encodedURL.lastPathComponent,
                        metrics: existingMetrics,
                        timestamp: Date(),
                        durationSeconds: durationSeconds
                    )
                    droppedFiles[idx].analyticsStatus = .completed
                    droppedFiles[idx].analyticsProgress = 1.0

                    if let updatedResults = droppedFiles[idx].analyticsResults {
                        AnalyticsExporter.autoExportIfEnabled(results: updatedResults, encodedFileURL: encodedURL)
                    }
                }
            }

            Self.logger.info("Additional metrics completed for \(encodedURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.firstIndex(where: { $0.id == itemID }) {
                    if case AnalyticsError.cancelled = error {
                        // User-initiated cancel already set status to .notQueued. If the
                        // item has prior completed results, restore that state so the
                        // results badge stays visible.
                        if droppedFiles[idx].analyticsResults != nil {
                            droppedFiles[idx].analyticsStatus = .completed
                        }
                        return
                    }
                    // Restore to completed if we had prior results
                    if droppedFiles[idx].analyticsResults != nil {
                        droppedFiles[idx].analyticsStatus = .completed
                    } else {
                        droppedFiles[idx].analyticsStatus = .failed(error.localizedDescription)
                    }
                }
            }
            Self.logger.error("Additional metrics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @ViewBuilder
    private var analyticsResultsSheetContent: some View {
        if let itemID = analyticsResultsItemID,
           let item = droppedFiles.first(where: { $0.id == itemID }),
           let results = item.analyticsResults {
            AnalyticsResultsView(results: results) { metrics in
                Task { @MainActor in
                    await analyzeMetrics(itemID: itemID, metrics: metrics)
                }
            }
        }
    }

}

struct VideoFileListView_Previews: PreviewProvider {
    static var previews: some View {
        VideoFileListView(
            droppedFiles: .constant([
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo.mp4"),
                    name: "SampleVideo.mp4",
                    size: 1048576,
                    duration: "00:02:30",
                    thumbnailData: nil,
                    status: .waiting,
                    progress: 0.0,
                    eta: nil
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo2.mp4"),
                    name: "SampleVideo2.mp4",
                    size: 1048576,
                    duration: "00:01:30",
                    thumbnailData: nil,
                    status: .done,
                    progress: 0.0,
                    eta: nil
                ),
                VideoItem(
                    url: URL(fileURLWithPath: "/tmp/SampleVideo3.mp4"),
                    name: "SampleVideo.mp4",
                    size: 1048576,
                    duration: "00:05:30",
                    thumbnailData: nil,
                    status: .waiting,
                    progress: 0.0,
                    eta: nil,
                    outputURL: nil
                )
            ]),
            encodingGroups: .constant([]),
            currentProgress: .constant(0.3),
            onFileImport: {},
            onDoubleClick: {},
            onDelete: { _ in },
            onReset: { _, _ in },
            preset: .videoLoop,
            mergeClipsEnabled: true,
            mergeClipsAvailable: true,
            queueOrder: .constant([])
        )
    }
}

private struct KeyEventHandlingView: NSViewRepresentable {
    var onTabForward: () -> Void
    var onTabBackward: () -> Void
    // Single-selection shortcuts
    var onTrim: () -> Void
    var onCrop: () -> Void
    var onTimecode: () -> Void
    var onAudioConfig: () -> Void
    var onMetadata: () -> Void
    var onToggleDateTag: () -> Void
    var onPlayFullscreen: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    // Multi-selection shortcuts
    var onResetSelected: () -> Void
    var onDeselectAll: () -> Void
    var onToggleMute: () -> Void
    var onToggleUpload: () -> Void
    var onToggleSourceUpload: () -> Void
    var onToggleSubtitles: () -> Void
    var onToggleAutoEncode: () -> Void
    // Navigation shortcuts (plain arrow keys)
    var onNavigateUp: () -> Void
    var onNavigateDown: () -> Void
    // Sort shortcut
    var onSort: () -> Void
    // Standard list shortcuts
    var onDelete: () -> Void
    var onPrimaryPreview: () -> Void   // Space: fullscreen preview
    var onPrimaryAction: () -> Void    // Return: open trim
    var onSelectAll: () -> Void        // ⌘A
    // Flag to disable navigation when overlays are open
    var disableNavigation: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onForward: onTabForward,
            onBackward: onTabBackward,
            onTrim: onTrim,
            onCrop: onCrop,
            onTimecode: onTimecode,
            onAudioConfig: onAudioConfig,
            onMetadata: onMetadata,
            onToggleDateTag: onToggleDateTag,
            onPlayFullscreen: onPlayFullscreen,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onResetSelected: onResetSelected,
            onDeselectAll: onDeselectAll,
            onToggleMute: onToggleMute,
            onToggleUpload: onToggleUpload,
            onToggleSourceUpload: onToggleSourceUpload,
            onToggleSubtitles: onToggleSubtitles,
            onToggleAutoEncode: onToggleAutoEncode,
            onNavigateUp: onNavigateUp,
            onNavigateDown: onNavigateDown,
            onSort: onSort,
            onDelete: onDelete,
            onPrimaryPreview: onPrimaryPreview,
            onPrimaryAction: onPrimaryAction,
            onSelectAll: onSelectAll,
            disableNavigation: disableNavigation
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onForward = onTabForward
        context.coordinator.onBackward = onTabBackward
        context.coordinator.onTrim = onTrim
        context.coordinator.onCrop = onCrop
        context.coordinator.onTimecode = onTimecode
        context.coordinator.onAudioConfig = onAudioConfig
        context.coordinator.onMetadata = onMetadata
        context.coordinator.onToggleDateTag = onToggleDateTag
        context.coordinator.onPlayFullscreen = onPlayFullscreen
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onResetSelected = onResetSelected
        context.coordinator.onDeselectAll = onDeselectAll
        context.coordinator.onToggleMute = onToggleMute
        context.coordinator.onToggleUpload = onToggleUpload
        context.coordinator.onToggleSourceUpload = onToggleSourceUpload
        context.coordinator.onToggleSubtitles = onToggleSubtitles
        context.coordinator.onToggleAutoEncode = onToggleAutoEncode
        context.coordinator.onNavigateUp = onNavigateUp
        context.coordinator.onNavigateDown = onNavigateDown
        context.coordinator.onSort = onSort
        context.coordinator.onDelete = onDelete
        context.coordinator.onPrimaryPreview = onPrimaryPreview
        context.coordinator.onPrimaryAction = onPrimaryAction
        context.coordinator.onSelectAll = onSelectAll
        context.coordinator.disableNavigation = disableNavigation
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        var onForward: () -> Void
        var onBackward: () -> Void
        var onTrim: () -> Void
        var onCrop: () -> Void
        var onTimecode: () -> Void
        var onAudioConfig: () -> Void
        var onMetadata: () -> Void
        var onToggleDateTag: () -> Void
        var onPlayFullscreen: () -> Void
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onResetSelected: () -> Void
        var onDeselectAll: () -> Void
        var onToggleMute: () -> Void
        var onToggleUpload: () -> Void
        var onToggleSourceUpload: () -> Void
        var onToggleSubtitles: () -> Void
        var onToggleAutoEncode: () -> Void
        var onNavigateUp: () -> Void
        var onNavigateDown: () -> Void
        var onSort: () -> Void
        var onDelete: () -> Void
        var onPrimaryPreview: () -> Void
        var onPrimaryAction: () -> Void
        var onSelectAll: () -> Void
        var disableNavigation: Bool
        private var monitor: Any?

        init(
            onForward: @escaping () -> Void,
            onBackward: @escaping () -> Void,
            onTrim: @escaping () -> Void,
            onCrop: @escaping () -> Void,
            onTimecode: @escaping () -> Void,
            onAudioConfig: @escaping () -> Void,
            onMetadata: @escaping () -> Void,
            onToggleDateTag: @escaping () -> Void,
            onPlayFullscreen: @escaping () -> Void,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onResetSelected: @escaping () -> Void,
            onDeselectAll: @escaping () -> Void,
            onToggleMute: @escaping () -> Void,
            onToggleUpload: @escaping () -> Void,
            onToggleSourceUpload: @escaping () -> Void,
            onToggleSubtitles: @escaping () -> Void,
            onToggleAutoEncode: @escaping () -> Void,
            onNavigateUp: @escaping () -> Void,
            onNavigateDown: @escaping () -> Void,
            onSort: @escaping () -> Void,
            onDelete: @escaping () -> Void,
            onPrimaryPreview: @escaping () -> Void,
            onPrimaryAction: @escaping () -> Void,
            onSelectAll: @escaping () -> Void,
            disableNavigation: Bool
        ) {
            self.onForward = onForward
            self.onBackward = onBackward
            self.onTrim = onTrim
            self.onCrop = onCrop
            self.onTimecode = onTimecode
            self.onAudioConfig = onAudioConfig
            self.onMetadata = onMetadata
            self.onToggleDateTag = onToggleDateTag
            self.onPlayFullscreen = onPlayFullscreen
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onResetSelected = onResetSelected
            self.onDeselectAll = onDeselectAll
            self.onToggleMute = onToggleMute
            self.onToggleUpload = onToggleUpload
            self.onToggleSourceUpload = onToggleSourceUpload
            self.onToggleSubtitles = onToggleSubtitles
            self.onToggleAutoEncode = onToggleAutoEncode
            self.onNavigateUp = onNavigateUp
            self.onNavigateDown = onNavigateDown
            self.onSort = onSort
            self.onDelete = onDelete
            self.onPrimaryPreview = onPrimaryPreview
            self.onPrimaryAction = onPrimaryAction
            self.onSelectAll = onSelectAll
            self.disableNavigation = disableNavigation
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

                // When navigation is disabled (overlay is open), pass through all key events
                // This allows overlays like URLInputOverlay to handle their own keyboard input
                if self.disableNavigation {
                    return event
                }

                // Pass through when the fullscreen player is open. Local NSEvent monitors fire
                // independently per install, so without this guard the queue's Space (QuickLook)
                // and other shortcuts would collide with the fullscreen player's own handlers.
                let isFullscreenPlayerOpen = MainActor.assumeIsolated {
                    FullscreenPlayerWindowController.shared.isFullscreenPlayerOpen
                }
                if isFullscreenPlayerOpen {
                    return event
                }

                // Pass through when the key window is a sheet or modal panel (e.g. NSOpenPanel,
                // NSSavePanel, confirmation alerts). Otherwise this monitor swallows shortcuts
                // the panel itself needs, like ⌘A to select all items in the file picker.
                let isInSheetOrPanel = MainActor.assumeIsolated { () -> Bool in
                    guard let keyWindow = NSApp.keyWindow else { return false }
                    if keyWindow.sheetParent != nil { return true }
                    if keyWindow.attachedSheet != nil { return true }
                    // NSOpenPanel / NSSavePanel are NSPanels; treat any focused panel that isn't
                    // owned by our main content as out-of-scope for queue shortcuts.
                    if keyWindow is NSPanel { return true }
                    return false
                }
                if isInSheetOrPanel {
                    return event
                }

                // Check if a text field or text view is the first responder
                // If so, pass through Arrow keys for cursor movement within the text
                // Note: Tab is NOT passed through - it's handled by focusComment to move between fields
                let firstResponder = MainActor.assumeIsolated { NSApp.keyWindow?.firstResponder }
                if let firstResponder {
                    let isTextInput = firstResponder is NSTextView || firstResponder is NSTextField
                    if isTextInput {
                        // Pass through Arrow keys when editing text for cursor movement
                        if event.keyCode == kVK_UpArrow ||
                           event.keyCode == kVK_DownArrow ||
                           event.keyCode == kVK_LeftArrow ||
                           event.keyCode == kVK_RightArrow {
                            return event
                        }
                    }
                }

                let hasCommand = event.modifierFlags.contains(.command)
                let hasOption = event.modifierFlags.contains(.option)
                let hasShift = event.modifierFlags.contains(.shift)
                let hasControl = event.modifierFlags.contains(.control)

                // Delete / Backspace (with or without ⌘): delete selected rows.
                // Skip if a text field is editing — the isTextInput early return above
                // only intercepts arrow keys, so explicitly guard here too.
                if event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
                    if !hasOption && !hasShift && !hasControl {
                        if let firstResponder, firstResponder is NSTextView || firstResponder is NSTextField {
                            return event
                        }
                        self.onDelete()
                        return nil
                    }
                }

                // Space: fullscreen preview (QuickLook-style) on the focused item
                if !hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_Space {
                    if let firstResponder, firstResponder is NSTextView || firstResponder is NSTextField {
                        return event
                    }
                    self.onPrimaryPreview()
                    return nil
                }

                // Return / Enter: open trim preview on the focused item
                if !hasCommand && !hasOption && !hasShift && !hasControl
                    && (event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter) {
                    if let firstResponder, firstResponder is NSTextView || firstResponder is NSTextField {
                        return event
                    }
                    self.onPrimaryAction()
                    return nil
                }

                // ⌘A: select all rows
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_A {
                    if let firstResponder, firstResponder is NSTextView || firstResponder is NSTextField {
                        return event
                    }
                    self.onSelectAll()
                    return nil
                }

                // Tab handling (no command/option/control)
                if event.keyCode == kVK_Tab {
                    let disallowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
                    if !event.modifierFlags.intersection(disallowedModifiers).isEmpty {
                        return event
                    }
                    if hasShift {
                        self.onBackward()
                    } else {
                        self.onForward()
                    }
                    return nil
                }
                
                // CMD+T: Open Trim (single selection)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_T {
                    self.onTrim()
                    return nil
                }

                // CMD+Option+T: Toggle subtitles on selected items
                if hasCommand && hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_T {
                    self.onToggleSubtitles()
                    return nil
                }
                
                // Option+C: Open Crop mode (opens trim editor with crop enabled)
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_C {
                    self.onCrop()
                    return nil
                }
                
                // Option+T: Open Timecode
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_T {
                    self.onTimecode()
                    return nil
                }
                
                // Option+A: Open Audio Config
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_A {
                    self.onAudioConfig()
                    return nil
                }
                
                // Option+I: Open Metadata Info (single or multiple selection for comparison)
                // Note: CMD+I is used for Import, so we use Option+I instead
                // Skip if we're in a sheet (trim view uses Option+I to clear trim start)
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_I {
                    // Check if the key window IS a sheet (has a sheetParent) or HAS a sheet attached
                    let isInSheet = MainActor.assumeIsolated {
                        if let keyWindow = NSApp.keyWindow {
                            return keyWindow.sheetParent != nil || keyWindow.attachedSheet != nil
                        }
                        return false
                    }
                    if isInSheet {
                        return event  // Pass through to let the sheet handle it
                    }
                    self.onMetadata()
                    return nil
                }
                
                // CTRL+D: Toggle Date Tag
                if hasControl && !hasOption && !hasShift && !hasCommand && event.keyCode == kVK_ANSI_D {
                    self.onToggleDateTag()
                    return nil
                }
                
                // CMD+F: Play Fullscreen
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_F {
                    self.onPlayFullscreen()
                    return nil
                }
                
                // Option+D: Deselect all items
                if hasOption && !hasCommand && !hasShift && !hasControl && event.keyCode == kVK_ANSI_D {
                    self.onDeselectAll()
                    return nil
                }
                
                // CMD+R: Reset selected items
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_R {
                    self.onResetSelected()
                    return nil
                }
                
                // CMD+Up Arrow: Move selection up in queue
                // Skip if we're in a sheet (crop view uses CMD+Up to move crop box)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_UpArrow {
                    let isInSheet = MainActor.assumeIsolated {
                        if let keyWindow = NSApp.keyWindow {
                            return keyWindow.sheetParent != nil || keyWindow.attachedSheet != nil
                        }
                        return false
                    }
                    if isInSheet {
                        return event  // Pass through to let the sheet handle it
                    }
                    self.onMoveUp()
                    return nil
                }

                // CMD+Down Arrow: Move selection down in queue
                // Skip if we're in a sheet (crop view uses CMD+Down to move crop box)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_DownArrow {
                    let isInSheet = MainActor.assumeIsolated {
                        if let keyWindow = NSApp.keyWindow {
                            return keyWindow.sheetParent != nil || keyWindow.attachedSheet != nil
                        }
                        return false
                    }
                    if isInSheet {
                        return event  // Pass through to let the sheet handle it
                    }
                    self.onMoveDown()
                    return nil
                }

                // Ctrl+M: Toggle mute on selected items
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_M {
                    self.onToggleMute()
                    return nil
                }

                // CMD+U: Toggle upload on selected items
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_U {
                    self.onToggleUpload()
                    return nil
                }

                // CMD+Option+U: Toggle source file upload on selected items
                if hasCommand && hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_U {
                    self.onToggleSourceUpload()
                    return nil
                }

                // CMD+E: Toggle auto-encode on selected items (for download items)
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_E {
                    self.onToggleAutoEncode()
                    return nil
                }

                // Ctrl+S: Cycle through sort modes
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_S {
                    self.onSort()
                    return nil
                }

                // Plain Up Arrow: Navigate selection up (skip if navigation disabled for overlays)
                if !hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_UpArrow {
                    if !self.disableNavigation {
                        self.onNavigateUp()
                        return nil
                    }
                    return event
                }

                // Plain Down Arrow: Navigate selection down (skip if navigation disabled for overlays)
                if !hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_DownArrow {
                    if !self.disableNavigation {
                        self.onNavigateDown()
                        return nil
                    }
                    return event
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

// MARK: - Sort Mode Overlay

private struct SortModeOverlay: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}

/// Toast shown after Cmd+N creates a new group. The group is appended at the end
/// of the queue where the user may not see it — the "Scroll to group" action
/// brings it on-screen, and the "×" dismisses the toast immediately.
private struct GroupCreatedOverlay: View {
    let onScrollToGroup: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill.badge.plus")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.accentColor)
            Text("New group created")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
            Button(action: onScrollToGroup) {
                Label("Scroll to group", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
    }
}
