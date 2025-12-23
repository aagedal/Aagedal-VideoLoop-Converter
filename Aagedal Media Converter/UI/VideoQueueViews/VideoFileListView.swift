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
    @Binding var droppedFiles: [VideoItem]
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
    var onToggleDateTag: ((Int) -> Void)?
    var onPlayFullscreen: ((UUID) -> Void)?

    @State private var isTargeted = false
    /// Selected row IDs (VideoItem.id) for built-in multi-selection
    @State private var selection = Set<UUID>()
    @State private var focusedCommentID: UUID?
    /// Flag to trigger scroll-to-selection only for keyboard navigation
    @State private var shouldScrollToSelection = false
    /// Current sort mode (nil = original/unsorted order)
    @State private var currentSortMode: QueueSortMode?
    /// Whether to show the sort mode overlay
    @State private var showSortOverlay = false
    /// Work item for dismissing the sort overlay
    @State private var sortOverlayDismissTask: DispatchWorkItem?

    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted
    @AppStorage(AppConstants.showCommentFieldKey) private var showCommentField = true
    @AppStorage(AppConstants.showDateTagButtonKey) private var showDateTagButton = true
    @AppStorage(AppConstants.queueViewModeKey) private var queueViewMode = AppConstants.defaultQueueViewMode

    private var isCompactMode: Bool { queueViewMode == "compact" }

    @State private var currentTip: LocalizedStringKey = RandomTips.randomTip()

    var body: some View {
        ZStack {
            if droppedFiles.isEmpty {
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
                        Spacer()
                    }.frame(width: 500,height: 86)

                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.windowBackgroundColor))
                .onTapGesture(count: 2) {
                    onDoubleClick()
                }
            } else {
                // File list
                // Enable multi-selection of rows by index
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(Array(droppedFiles.enumerated()), id: \.element.id) { index, file in
                            cardRow(for: index)
                                .id(file.id)
                        }
                        .onDelete(perform: onDelete)
                        .onMove { indices, newOffset in
                            droppedFiles.move(fromOffsets: indices, toOffset: newOffset)
                        }
                    }
                    .listStyle(PlainListStyle())
                    .scrollContentBackground(.hidden) // matches new card background
                    .background(Color.clear)
                    .onChange(of: shouldScrollToSelection) { _, shouldScroll in
                        // Scroll to the first selected item only when triggered by keyboard navigation
                        guard shouldScroll, let firstSelectedID = selection.first else { return }
                        proxy.scrollTo(firstSelectedID, anchor: .center)
                        shouldScrollToSelection = false
                    }
                }
            }
            
            // Drag and drop overlay
            if isTargeted {
                Color.blue.opacity(0.1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [10]))
                            .foregroundColor(.blue)
                    )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if showSortOverlay, let sortMode = currentSortMode {
                SortModeOverlay(text: sortMode.displayName)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.leading, 16)
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showSortOverlay)
        // Support file drops on entire view (empty or populated)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
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
                    onNavigateUp: { handleNavigateSelection(direction: .up) },
                    onNavigateDown: { handleNavigateSelection(direction: .down) },
                    onSort: handleSortShortcut
                )

                Button(action: deleteSelectedItems) {
                    EmptyView()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .frame(width: 0, height: 0)
                .opacity(0)

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
        print(" handleDrop called with \(providers.count) providers")
        Task { @MainActor in
            await self.importProviders(providers)
        }
        print(" handleDrop returning: true")
        return true
    }
    
    @MainActor
    private func importProviders(_ providers: [NSItemProvider]) async {
        let supportedExtensions = AppConstants.supportedVideoExtensions

        for provider in providers {
            print(" Processing provider: \(provider)")
            // Use the proper API to load file URLs
            if provider.canLoadObject(ofClass: URL.self) {
                print(" Provider can load URL")
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    if let error = error {
                        print(" Error loading URL: \(error)")
                        return
                    }
                    if let url = url {
                        print(" Loaded URL: \(url)")
                        
                        // For drag and drop, the URL already has temporary access
                        // We need to start accessing the security-scoped resource immediately
                        let hasAccess = url.startAccessingSecurityScopedResource()
                        print(" Security-scoped access granted: \(hasAccess)")
                        
                        Task { @MainActor in
                            await self.processFileURL(url, supportedExtensions: supportedExtensions, hasSecurityAccess: hasAccess)
                        }
                    } else {
                        print(" Provider cannot load URL")
                    }
                }
            } else {
                print(" Provider cannot load URL")
            }
        }
    }
    
    @MainActor
    private func processFileURL(_ url: URL, supportedExtensions: Set<String>, hasSecurityAccess: Bool = false) async {
        print(" Processing file URL: \(url)")
        
        // Get the file extension and check if it's supported
        let fileExtension = url.pathExtension.lowercased()
        print(" File extension: '\(fileExtension)'")
        print(" Supported extensions: \(supportedExtensions)")
        
        guard !fileExtension.isEmpty,
              supportedExtensions.contains(fileExtension) else {
            print(" File extension '\(fileExtension)' not supported")
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print(" Released security-scoped resource (unsupported file)")
            }
            return
        }
        
        print(" File extension is supported")
        
        // Handle security-scoped access based on the source
        var needsBookmarkAccess = false
        if !hasSecurityAccess {
            // Attempt to use an existing bookmark for persistent access
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                needsBookmarkAccess = true
                print(" Successfully accessed security-scoped resource via bookmark")
            } else {
                // No bookmark found – rely on direct entitlements (e.g. Downloads/Movie directory access)
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print(" Proceeding with direct file access (no bookmark needed)")
                } else {
                    print(" No bookmark and file not readable – access denied")
                    return
                }
            }
        } else {
            print(" Using existing security-scoped resource access")
        }
        
        var shouldReleaseImmediately = true
        let releaseSecurityAccess: () -> Void = {
            if hasSecurityAccess {
                url.stopAccessingSecurityScopedResource()
                print(" Released security-scoped resource (drag and drop)")
            } else if needsBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
                print(" Released security-scoped resource (bookmark)")
            }
        }
        defer {
            if shouldReleaseImmediately {
                releaseSecurityAccess()
            }
        }
        
        // Save the bookmark for future access
        let bookmarkSaved = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
        print(" Bookmark saved: \(bookmarkSaved)")
        
        // Get the output folder from UserDefaults or use default
        let outputFolder = UserDefaults.standard.string(forKey: "outputFolder") 
            ?? AppConstants.defaultOutputDirectory.path
            
        guard let placeholder = VideoFileUtils.makePlaceholderItem(from: url, outputFolder: outputFolder, preset: preset) else {
            print(" Failed to create placeholder video item")
            return
        }

        print(" [processFileURL] Placeholder created: \(placeholder.name)")

        // Check for duplicates before adding
        if self.droppedFiles.contains(where: { $0.url == placeholder.url }) {
            print(" Video item already exists in list")
            return
        }

        self.droppedFiles.append(placeholder)
        // Auto-mute if VideoLoop preset is selected and setting is enabled
        if preset == .videoLoop && videoLoopDefaultMuted {
            droppedFiles[droppedFiles.count - 1].isMuted = true
        }
        let placeholderID = placeholder.id
        print(" Added placeholder video item to list. Total items: \(self.droppedFiles.count)")

        Task(priority: .utility) {
            defer { releaseSecurityAccess() }

            let bookmarkSaved = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            print(" Bookmark saved: \(bookmarkSaved)")

            let details = await VideoFileUtils.loadDetails(for: url, outputFolder: outputFolder, preset: preset)
            await MainActor.run {
                if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                    self.droppedFiles[index].apply(details: details)
                    self.droppedFiles[index].detailsLoaded = true
                    print(" [processFileURL] Details applied for: \(self.droppedFiles[index].name)")
                }
            }

            let metadata = await VideoFileUtils.fetchMetadata(for: url)
            await MainActor.run {
                if let index = self.droppedFiles.firstIndex(where: { $0.id == placeholderID }) {
                    self.droppedFiles[index].metadata = metadata
                    print(" Updated video item with metadata: \(self.droppedFiles[index].name)")
                    VideoFileUtils.prefetchPreviewAssets(for: url)
                }
            }
        }
        shouldReleaseImmediately = false
    }
    
    private func progressText(for item: VideoItem) -> String {
        switch item.status {
        case .waiting:
            return "Waiting"
        case .converting:
            if let eta = item.eta {
                return "Converting... ETA: \(eta)"
            } else {
                return "Converting..."
            }
        case .done:
            return "Done"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
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
    
    // MARK: - Keyboard Shortcut Handlers
    
    /// Returns the UUID of the single selected item, or nil if zero or multiple items are selected
    private var singleSelectedID: UUID? {
        guard selection.count == 1,
              let selectedID = selection.first else {
            return nil
        }
        // Verify the ID exists in droppedFiles
        guard droppedFiles.contains(where: { $0.id == selectedID }) else {
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
            droppedFiles.contains(where: { $0.id == selectedID })
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
    
    private enum MoveDirection {
        case up, down
    }
    
    private func handleMoveSelection(direction: MoveDirection) {
        // Get sorted indices of selected items
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard !selectedIndices.isEmpty else { return }

        switch direction {
        case .up:
            // Can't move up if first item is selected and at index 0
            guard selectedIndices.first != 0 else { return }
            
            // Move items up one by one from top to bottom
            for index in selectedIndices {
                let newIndex = index - 1
                droppedFiles.swapAt(index, newIndex)
            }
            
            // Update selection to new positions
            let newSelection = Set(selectedIndices.map { droppedFiles[$0 - 1].id })
            selection = newSelection
            
        case .down:
            // Can't move down if last item is selected and at last index
            guard selectedIndices.last != droppedFiles.count - 1 else { return }

            // Move items down one by one from bottom to top
            for index in selectedIndices.reversed() {
                let newIndex = index + 1
                droppedFiles.swapAt(index, newIndex)
            }

            // Update selection to new positions
            let newSelection = Set(selectedIndices.map { droppedFiles[$0 + 1].id })
            selection = newSelection
        }
        shouldScrollToSelection = true
    }

    private func handleNavigateSelection(direction: MoveDirection) {
        guard !droppedFiles.isEmpty else { return }

        // If nothing is selected, select first/last item based on direction
        if selection.isEmpty {
            switch direction {
            case .down:
                selection = [droppedFiles.first!.id]
            case .up:
                selection = [droppedFiles.last!.id]
            }
            shouldScrollToSelection = true
            return
        }

        // Get the current selection index (use first selected if multiple)
        let selectedIndices = selection.compactMap { selectedID in
            droppedFiles.firstIndex(where: { $0.id == selectedID })
        }.sorted()

        guard let currentIndex = selectedIndices.first else { return }

        switch direction {
        case .up:
            // Move to previous item (wrap or stay at first)
            let newIndex = max(0, currentIndex - 1)
            selection = [droppedFiles[newIndex].id]
        case .down:
            // Move to next item (wrap or stay at last)
            let newIndex = min(droppedFiles.count - 1, currentIndex + 1)
            selection = [droppedFiles[newIndex].id]
        }
        shouldScrollToSelection = true
    }

    private func handleSortShortcut() {
        guard droppedFiles.count > 1 else { return }

        // Cycle to the next sort mode
        let nextMode: QueueSortMode
        if let current = currentSortMode {
            nextMode = current.next()
        } else {
            nextMode = .filenameAscending
        }
        currentSortMode = nextMode

        // Sort the array based on the mode
        switch nextMode {
        case .filenameAscending:
            droppedFiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .filenameDescending:
            droppedFiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateOldest:
            droppedFiles.sort { fileCreationDate(for: $0.url) < fileCreationDate(for: $1.url) }
        case .dateNewest:
            droppedFiles.sort { fileCreationDate(for: $0.url) > fileCreationDate(for: $1.url) }
        }

        // Show the sort mode overlay
        sortOverlayDismissTask?.cancel()
        showSortOverlay = true

        // Schedule dismissal after 3.5 seconds
        let dismissTask = DispatchWorkItem { [self] in
            showSortOverlay = false
        }
        sortOverlayDismissTask = dismissTask
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: dismissTask)
    }

    private func fileCreationDate(for url: URL) -> Date {
        let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey])
        return resourceValues?.creationDate ?? Date.distantPast
    }

    // MARK: - Row Builder
    @ViewBuilder
    private func cardRow(for index: Int) -> some View {
        // Get a binding to the file in the array
        let file = $droppedFiles[index]
        VideoFileRowView(
            file: file,
            focusedCommentID: $focusedCommentID,
            preset: preset,
            onCancel: {
                Task { await ConversionManager.shared.cancelItem(with: file.wrappedValue.id) }
            },
            onDelete: {
                onDelete(IndexSet(integer: index))
            },
            onReset: { optionKeyPressed in
                onReset(index, optionKeyPressed)
            },
            isSelected: selection.contains(file.wrappedValue.id),
            onCommentFocusChange: { id, isFocused in
                guard droppedFiles[index].id == id else { return }
                if isFocused {
                    // Don't override multi-selection when comment field is focused
                    // Only update focusedCommentID for Tab navigation
                    if !selection.contains(id) {
                        selection = [id]
                    }
                    // Guard against redundant updates to prevent feedback loop
                    if focusedCommentID != id {
                        focusedCommentID = id
                    }
                } else if focusedCommentID == id {
                    focusedCommentID = nil
                }
            },
            onPlayFullscreen: {
                onPlayFullscreen?(file.wrappedValue.id)
            },
            mergeClipsEnabled: mergeClipsEnabled,
            mergeClipsAvailable: mergeClipsAvailable,
            showCommentField: showCommentField,
            showDateTagButton: showDateTagButton,
            isCompactMode: isCompactMode
        )
        .padding([.vertical], 4)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
        .tag(file.wrappedValue.id)
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
            currentProgress: .constant(0.3),
            onFileImport: {},
            onDoubleClick: {},
            onDelete: { _ in },
            onReset: { _, _ in },
            preset: .videoLoop,
            mergeClipsEnabled: true,
            mergeClipsAvailable: true
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
    // Navigation shortcuts (plain arrow keys)
    var onNavigateUp: () -> Void
    var onNavigateDown: () -> Void
    // Sort shortcut
    var onSort: () -> Void

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
            onNavigateUp: onNavigateUp,
            onNavigateDown: onNavigateDown,
            onSort: onSort
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
        context.coordinator.onNavigateUp = onNavigateUp
        context.coordinator.onNavigateDown = onNavigateDown
        context.coordinator.onSort = onSort
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
        var onNavigateUp: () -> Void
        var onNavigateDown: () -> Void
        var onSort: () -> Void
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
            onNavigateUp: @escaping () -> Void,
            onNavigateDown: @escaping () -> Void,
            onSort: @escaping () -> Void
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
            self.onNavigateUp = onNavigateUp
            self.onNavigateDown = onNavigateDown
            self.onSort = onSort
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }

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
                
                // CMD+D: Toggle Date Tag
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_ANSI_D {
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
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_UpArrow {
                    self.onMoveUp()
                    return nil
                }
                
                // CMD+Down Arrow: Move selection down in queue
                if hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_DownArrow {
                    self.onMoveDown()
                    return nil
                }

                // Ctrl+M: Toggle mute on selected items
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_M {
                    self.onToggleMute()
                    return nil
                }

                // Ctrl+S: Cycle through sort modes
                if hasControl && !hasCommand && !hasOption && !hasShift && event.keyCode == kVK_ANSI_S {
                    self.onSort()
                    return nil
                }

                // Plain Up Arrow: Navigate selection up
                if !hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_UpArrow {
                    self.onNavigateUp()
                    return nil
                }

                // Plain Down Arrow: Navigate selection down
                if !hasCommand && !hasOption && !hasShift && !hasControl && event.keyCode == kVK_DownArrow {
                    self.onNavigateDown()
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
