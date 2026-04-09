// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

// MARK: - Custom Row View (suppresses default selection highlight)

private final class TransparentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // No-op: SwiftUI VideoFileRowView handles its own selection border
    }
}

// MARK: - Table Cell View (hosts SwiftUI via NSHostingView)

private final class VideoQueueTableCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    func configure(with content: AnyView) {
        if let hostingView = self.hostingView {
            hostingView.rootView = content
        } else {
            let hosting = NSHostingView(rootView: content)
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.hostingView = hosting
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // hostingView is reused, rootView will be updated via configure()
    }
}

// MARK: - Pasteboard type for internal reorder

private extension NSPasteboard.PasteboardType {
    static let videoQueueItem = NSPasteboard.PasteboardType("com.aagedal.mediaconverter.videoqueueitem")
}

// MARK: - VideoQueueTableView (NSViewRepresentable)

struct VideoQueueTableView: NSViewRepresentable {
    @Binding var droppedFiles: [VideoItem]
    @Binding var encodingGroups: [EncodingGroup]
    @Binding var selection: Set<UUID>
    @Binding var focusedCommentID: UUID?
    @Binding var shouldScrollToSelection: Bool
    let isCompactMode: Bool
    let preset: ExportPreset
    let mergeClipsEnabled: Bool
    let mergeClipsAvailable: Bool
    let showCommentField: Bool
    let showDateTagButton: Bool

    // Callbacks
    var onDelete: (IndexSet) -> Void
    var onReset: (Int, Bool) -> Void
    var onOpenTrim: ((UUID) -> Void)?
    var onOpenTrimWithCrop: ((UUID) -> Void)?
    var onOpenTimecode: ((UUID) -> Void)?
    var onOpenAudioConfig: ((UUID) -> Void)?
    var onOpenMetadata: (([UUID]) -> Void)?
    var onToggleDateTag: ((Int) -> Void)?
    var onPlayFullscreen: ((UUID) -> Void)?
    var onRenameOutputFileName: ((UUID, String?) -> Void)?
    var transcribeOnly: ((UUID, SubtitleConversionMethod) async -> Void)?
    var analyzeOnly: ((UUID) async -> Void)?
    var analyzeMetrics: ((UUID, [QualityMetric]) async -> Void)?
    var onDeleteGroup: ((UUID) -> Void)?
    var onAddFilesToGroup: ((UUID) -> Void)?
    var onResetGroup: ((UUID) -> Void)?
    var queueOrder: [UUID]
    var onReorder: ((_ movedIDs: [UUID], _ destinationQueueIndex: Int) -> Void)?
    var onQueueSync: (() -> Void)?

    // MARK: - Display Rows

    /// Computes a flat list of display rows ordered by queueOrder.
    func computeDisplayRows() -> [FlatQueueRow] {
        var rows: [FlatQueueRow] = []
        for id in queueOrder {
            if let item = droppedFiles.first(where: { $0.id == id }) {
                rows.append(.single(item))
            } else if let group = encodingGroups.first(where: { $0.id == id }) {
                rows.append(.groupHeader(group))
                if group.isExpanded {
                    for item in group.items {
                        rows.append(.groupItem(item, groupID: group.id))
                    }
                }
            }
        }
        return rows
    }

    /// Maps a flat display row index to the corresponding queueOrder index.
    /// Singles and group headers map directly; group items map to their parent group.
    func queueOrderIndex(forDisplayRow row: Int, in displayRows: [FlatQueueRow]) -> Int {
        guard row < displayRows.count else { return queueOrder.count }
        let targetID: UUID
        switch displayRows[row] {
        case .single(let item): targetID = item.id
        case .groupHeader(let group): targetID = group.id
        case .groupItem(_, let groupID): targetID = groupID
        }
        if let idx = queueOrder.firstIndex(of: targetID) {
            return idx
        }
        return queueOrder.count
    }

    // MARK: - makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let tableView = NSTableView()
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = true
        tableView.allowsMultipleSelection = true
        tableView.selectionHighlightStyle = .none
        tableView.rowSizeStyle = .custom

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MainColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        // Register for drag-to-reorder
        tableView.registerForDraggedTypes([.videoQueueItem])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView

        // Store initial snapshot and populate cache
        let initialRows = computeDisplayRows()
        context.coordinator.cachedDisplayRows = initialRows
        context.coordinator.previousIDs = initialRows.map(\.id)
        context.coordinator.previousCompactMode = isCompactMode

        // Ensure the table loads its initial data — without this, the first
        // updateNSView sees newIDs == oldIDs and only calls updateVisibleCells,
        // which is a no-op on an empty table, leaving the view blank.
        tableView.reloadData()

        return scrollView
    }

    // MARK: - updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        // Always update the parent reference so closures are current
        coordinator.parent = self

        let displayRows = computeDisplayRows()
        coordinator.cachedDisplayRows = displayRows
        let newIDs = displayRows.map(\.id)
        let oldIDs = coordinator.previousIDs

        if newIDs == oldIDs {
            coordinator.updateVisibleCells()
        } else if Set(newIDs) == Set(oldIDs) && newIDs.count == oldIDs.count {
            coordinator.applyRowMoves(from: oldIDs, to: newIDs)
            coordinator.updateVisibleCells()
        } else {
            tableView.reloadData()
        }

        coordinator.previousIDs = newIDs

        // Handle compact mode changes - notify table about row height changes
        if isCompactMode != coordinator.previousCompactMode {
            coordinator.previousCompactMode = isCompactMode
            if tableView.numberOfRows > 0 {
                let allRows = IndexSet(integersIn: 0..<tableView.numberOfRows)
                tableView.noteHeightOfRows(withIndexesChanged: allRows)
            }
        }

        // Sync selection: SwiftUI -> NSTableView
        syncSelectionToTableView(coordinator: coordinator, tableView: tableView)

        // Handle scroll-to-selection
        if shouldScrollToSelection {
            if let firstSelectedID = selection.first,
               let row = displayRows.firstIndex(where: { $0.id == firstSelectedID }) {
                tableView.scrollRowToVisible(row)
            }
            DispatchQueue.main.async {
                self.shouldScrollToSelection = false
            }
        }
    }

    private func syncSelectionToTableView(coordinator: Coordinator, tableView: NSTableView) {
        guard !coordinator.isUpdatingSelection else { return }
        coordinator.isUpdatingSelection = true
        defer { coordinator.isUpdatingSelection = false }

        let rows = coordinator.cachedDisplayRows
        let desiredRows = IndexSet(selection.compactMap { id in
            rows.firstIndex(where: { $0.id == id })
        })

        let currentRows = tableView.selectedRowIndexes
        if desiredRows != currentRows {
            tableView.selectRowIndexes(desiredRows, byExtendingSelection: false)
        }
    }

    // MARK: - makeCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: VideoQueueTableView
        weak var tableView: NSTableView?
        var previousIDs: [UUID] = []
        var previousCompactMode = false
        var isUpdatingSelection = false
        /// Cached display rows to avoid redundant recomputation in delegate callbacks.
        /// Refreshed in updateNSView when SwiftUI pushes new data.
        var cachedDisplayRows: [FlatQueueRow] = []

        private static let cellID = NSUserInterfaceItemIdentifier("VideoQueueCell")

        init(parent: VideoQueueTableView) {
            self.parent = parent
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            cachedDisplayRows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return nil }

            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? VideoQueueTableCellView
                ?? VideoQueueTableCellView()
            cell.identifier = Self.cellID

            let rowContent = buildRowView(for: row, displayRows: displayRows)
            cell.configure(with: AnyView(rowContent))
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            TransparentRowView()
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingSelection else { return }
            isUpdatingSelection = true
            defer { isUpdatingSelection = false }

            guard let tableView = tableView else { return }
            let displayRows = cachedDisplayRows
            let selectedRows = tableView.selectedRowIndexes
            let newSelection = Set(selectedRows.compactMap { row -> UUID? in
                guard row < displayRows.count else { return nil }
                return displayRows[row].id
            })
            parent.selection = newSelection
        }

        // MARK: Drag-to-Reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            // Allow dragging ungrouped (.single) and group item rows
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return nil }
            switch displayRows[row] {
            case .single, .groupItem, .groupHeader:
                let item = NSPasteboardItem()
                item.setString(String(row), forType: .videoQueueItem)
                return item
            }
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource as? NSTableView === tableView else { return [] }

            let displayRows = cachedDisplayRows

            // Dropping ON a group header → move files into that group
            if dropOperation == .on, row < displayRows.count {
                if case .groupHeader = displayRows[row] {
                    return .move
                }
                return []
            }

            // Dropping ABOVE at any position → reorder in queue
            if dropOperation == .above {
                return .move
            }

            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard info.draggingSource as? NSTableView === tableView else { return false }

            let displayRows = cachedDisplayRows

            // Collect source row indices
            var sourceRows: [Int] = []
            info.enumerateDraggingItems(options: [], for: tableView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                if let pasteboardItem = item.item as? NSPasteboardItem,
                   let rowStr = pasteboardItem.string(forType: .videoQueueItem),
                   let sourceRow = Int(rowStr) {
                    sourceRows.append(sourceRow)
                }
            }
            sourceRows.sort()
            guard !sourceRows.isEmpty else { return false }

            // Dropping ON a group header → move items into that group
            if dropOperation == .on, row < displayRows.count,
               case .groupHeader(let targetGroup) = displayRows[row] {
                guard parent.encodingGroups.contains(where: { $0.id == targetGroup.id }) else { return false }

                // Collect items to move and remove from their sources (reverse order)
                var itemsToMove: [VideoItem] = []
                for sourceRow in sourceRows.reversed() {
                    guard sourceRow < displayRows.count else { continue }
                    switch displayRows[sourceRow] {
                    case .single(let item):
                        if let idx = parent.droppedFiles.firstIndex(where: { $0.id == item.id }) {
                            itemsToMove.insert(parent.droppedFiles.remove(at: idx), at: 0)
                        }
                    case .groupItem(let item, let srcGroupID):
                        if let srcGIdx = parent.encodingGroups.firstIndex(where: { $0.id == srcGroupID }),
                           let iIdx = parent.encodingGroups[srcGIdx].items.firstIndex(where: { $0.id == item.id }) {
                            itemsToMove.insert(parent.encodingGroups[srcGIdx].items.remove(at: iIdx), at: 0)
                        }
                    case .groupHeader:
                        continue
                    }
                }

                // Re-lookup group index (may have shifted)
                if let gIdx2 = parent.encodingGroups.firstIndex(where: { $0.id == targetGroup.id }) {
                    parent.encodingGroups[gIdx2].items.append(contentsOf: itemsToMove)
                }

                parent.selection = Set(itemsToMove.map(\.id))
                parent.onQueueSync?()
                return true
            }

            // Dropping ABOVE → reorder in the unified queue
            let destQueueIndex = parent.queueOrderIndex(forDisplayRow: row, in: displayRows)

            // Collect the top-level IDs being moved (singles → item ID, group headers → group ID, group items → move out of group first)
            var movedTopLevelIDs: [UUID] = []
            var itemsToMoveToUngrouped: [VideoItem] = []

            for sourceRow in sourceRows.reversed() {
                guard sourceRow < displayRows.count else { continue }
                switch displayRows[sourceRow] {
                case .single(let item):
                    movedTopLevelIDs.insert(item.id, at: 0)
                case .groupHeader(let group):
                    movedTopLevelIDs.insert(group.id, at: 0)
                case .groupItem(let item, let srcGroupID):
                    // Move out of group → becomes ungrouped single
                    if let gIdx = parent.encodingGroups.firstIndex(where: { $0.id == srcGroupID }),
                       let iIdx = parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == item.id }) {
                        let removed = parent.encodingGroups[gIdx].items.remove(at: iIdx)
                        itemsToMoveToUngrouped.insert(removed, at: 0)
                        movedTopLevelIDs.insert(removed.id, at: 0)
                    }
                }
            }

            // Add items that left a group into droppedFiles
            if !itemsToMoveToUngrouped.isEmpty {
                parent.droppedFiles.append(contentsOf: itemsToMoveToUngrouped)
            }

            guard !movedTopLevelIDs.isEmpty else { return false }

            // Report reorder to ContentView which manages queueOrder
            parent.onReorder?(movedTopLevelIDs, destQueueIndex)

            parent.selection = Set(movedTopLevelIDs)
            return true
        }

        // MARK: Row Moves

        /// Applies row moves to the NSTableView using moveRow(at:to:) instead
        /// of reloadData(). This physically moves existing cells without
        /// recreating them, avoiding the expensive full-table layout pass.
        func applyRowMoves(from oldIDs: [UUID], to newIDs: [UUID]) {
            guard let tableView = tableView else { return }
            var workingIDs = oldIDs
            tableView.beginUpdates()
            for newIndex in 0..<newIDs.count {
                let targetID = newIDs[newIndex]
                if workingIDs[newIndex] == targetID { continue }
                guard let currentIndex = workingIDs.firstIndex(of: targetID) else { continue }
                workingIDs.remove(at: currentIndex)
                workingIDs.insert(targetID, at: newIndex)
                tableView.moveRow(at: currentIndex, to: newIndex)
            }
            tableView.endUpdates()
        }

        // MARK: Update Visible Cells

        /// Updates visible cells in-place by setting hostingView.rootView.
        /// This preserves SwiftUI internal state (focus, hover, text editing)
        /// unlike reloadData(forRowIndexes:) which destroys and recreates cells.
        func updateVisibleCells() {
            guard let tableView = tableView else { return }
            let displayRows = cachedDisplayRows
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }
            let start = visibleRange.location
            let end = min(start + visibleRange.length, displayRows.count)
            for row in start..<end {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? VideoQueueTableCellView else { continue }
                let rowContent = buildRowView(for: row, displayRows: displayRows)
                cell.configure(with: AnyView(rowContent))
            }
        }

        // MARK: Row Builder

        @ViewBuilder
        private func buildRowView(for row: Int, displayRows: [FlatQueueRow]) -> some View {
            switch displayRows[row] {
            case .single(let item):
                buildFileRowView(itemID: item.id, source: .ungrouped)
                    .padding(.vertical, 4)
            case .groupHeader(let group):
                buildGroupHeaderView(groupID: group.id)
                    .padding(.vertical, 4)
            case .groupItem(let item, let groupID):
                buildFileRowView(itemID: item.id, source: .group(groupID))
                    .padding(.vertical, 2)
                    .padding(.leading, 24)
            }
        }

        private enum ItemSource {
            case ungrouped
            case group(UUID)
        }

        private func buildGroupHeaderView(groupID: UUID) -> some View {
            let fallbackGroup = EncodingGroup(name: "")

            let groupBinding = Binding<EncodingGroup>(
                get: { [weak self] in
                    self?.parent.encodingGroups.first(where: { $0.id == groupID }) ?? fallbackGroup
                },
                set: { [weak self] newValue in
                    guard let self,
                          let idx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }) else { return }
                    self.parent.encodingGroups[idx] = newValue
                }
            )

            let isSelected = parent.selection.contains(groupID)

            return EncodingGroupHeaderView(
                group: groupBinding,
                globalPreset: parent.preset,
                isSelected: isSelected,
                onDelete: { [weak self] in
                    self?.parent.onDeleteGroup?(groupID)
                },
                onAddFiles: { [weak self] in
                    self?.parent.onAddFilesToGroup?(groupID)
                },
                onReset: { [weak self] in
                    self?.parent.onResetGroup?(groupID)
                }
            )
        }

        private func buildFileRowView(itemID: UUID, source: ItemSource) -> some View {
            let placeholderItem = VideoItem(
                url: URL(fileURLWithPath: "/"),
                name: "",
                size: 0,
                duration: "",
                thumbnailData: nil,
                status: .waiting,
                progress: 0,
                eta: nil,
                outputURL: nil,
                comment: ""
            )

            let fileBinding: Binding<VideoItem>
            let isGroupItem: Bool

            switch source {
            case .ungrouped:
                isGroupItem = false
                fileBinding = Binding<VideoItem>(
                    get: { [weak self] in
                        guard let self,
                              let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) else {
                            return placeholderItem
                        }
                        return self.parent.droppedFiles[idx]
                    },
                    set: { [weak self] newValue in
                        guard let self,
                              let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }
                        self.parent.droppedFiles[idx] = newValue
                    }
                )
            case .group(let groupID):
                isGroupItem = true
                fileBinding = Binding<VideoItem>(
                    get: { [weak self] in
                        guard let self,
                              let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                              let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID })
                        else { return placeholderItem }
                        return self.parent.encodingGroups[gIdx].items[iIdx]
                    },
                    set: { [weak self] newValue in
                        guard let self,
                              let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                              let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID })
                        else { return }
                        self.parent.encodingGroups[gIdx].items[iIdx] = newValue
                    }
                )
            }

            let isSelected = parent.selection.contains(itemID)

            let focusedBinding = Binding<UUID?>(
                get: { [weak self] in self?.parent.focusedCommentID },
                set: { [weak self] newValue in self?.parent.focusedCommentID = newValue }
            )

            return VideoFileRowView(
                file: fileBinding,
                focusedCommentID: focusedBinding,
                preset: parent.preset,
                onCancel: {
                    Task { await ConversionManager.shared.cancelItem(with: itemID) }
                },
                onDelete: { [weak self] in
                    guard let self else { return }
                    switch source {
                    case .ungrouped:
                        if let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                            self.parent.onDelete(IndexSet(integer: idx))
                        }
                    case .group(let groupID):
                        if let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }) {
                            if let item = self.parent.encodingGroups[gIdx].items.first(where: { $0.id == itemID }) {
                                if item.subtitleStatus.isInProgress {
                                    Task { await TesseractService.shared.cancelGeneration() }
                                    Task { await WhisperService.shared.cancelGeneration() }
                                    Task { await ParakeetService.shared.cancelGeneration() }
                                }
                            }
                            self.parent.encodingGroups[gIdx].items.removeAll { $0.id == itemID }
                        }
                    }
                },
                onReset: { [weak self] optionKeyPressed in
                    guard let self else { return }
                    switch source {
                    case .ungrouped:
                        if let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                            self.parent.onReset(idx, optionKeyPressed)
                        }
                    case .group(let groupID):
                        if let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                           let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                            self.parent.encodingGroups[gIdx].items[iIdx].status = .waiting
                            self.parent.encodingGroups[gIdx].items[iIdx].progress = 0
                        }
                    }
                },
                onCancelDownload: {
                    DownloadManager.shared.cancelDownload(itemID: itemID)
                },
                onStopLiveRecording: {
                    DownloadManager.shared.stopLiveDownload(itemID: itemID)
                },
                onRetryDownload: {
                    Task { await DownloadManager.shared.retryDownload(itemID: itemID) }
                },
                onForceRedownload: {
                    Task { await DownloadManager.shared.forceRedownload(itemID: itemID) }
                },
                onCancelScheduledDownload: { [weak self] in
                    guard let self else { return }
                    ScheduledDownloadService.shared.cancelScheduledItem(itemID: itemID)
                    if case .ungrouped = source,
                       let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.onDelete(IndexSet(integer: idx))
                    }
                },
                onTranscribeOnly: { [weak self] method in
                    guard let self else { return }
                    let callback = self.parent.transcribeOnly
                    Task { @MainActor in
                        await callback?(itemID, method)
                    }
                },
                onCancelSubtitleGeneration: { [weak self] in
                    guard let self else { return }
                    // Cancel whichever subtitle service is running
                    Task { await TesseractService.shared.cancelGeneration() }
                    Task { await WhisperService.shared.cancelGeneration() }
                    Task { await ParakeetService.shared.cancelGeneration() }
                    // Reset subtitle status so the row returns to idle
                    switch source {
                    case .ungrouped:
                        if let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                            self.parent.droppedFiles[idx].subtitleStatus = .notQueued
                        }
                    case .group(let groupID):
                        if let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                           let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                            self.parent.encodingGroups[gIdx].items[iIdx].subtitleStatus = .notQueued
                        }
                    }
                },
                onAnalyzeOnly: { [weak self] in
                    guard let self else { return }
                    let callback = self.parent.analyzeOnly
                    Task { @MainActor in
                        await callback?(itemID)
                    }
                },
                onAnalyzeMetrics: { [weak self] metrics in
                    guard let self else { return }
                    let callback = self.parent.analyzeMetrics
                    Task { @MainActor in
                        await callback?(itemID, metrics)
                    }
                },
                onAttachSubtitleFile: { [weak self] in
                    self?.promptAttachSubtitleFile(itemID: itemID, source: source)
                },
                onRenameOutputFileName: { [weak self] newName in
                    self?.parent.onRenameOutputFileName?(itemID, newName)
                },
                isSelected: isSelected,
                onCommentFocusChange: { [weak self] id, isFocused in
                    guard let self else { return }
                    if isFocused {
                        if !self.parent.selection.contains(id) {
                            self.parent.selection = [id]
                        }
                        if self.parent.focusedCommentID != id {
                            self.parent.focusedCommentID = id
                        }
                    } else if self.parent.focusedCommentID == id {
                        self.parent.focusedCommentID = nil
                    }
                },
                onPlayFullscreen: { [weak self] in
                    self?.parent.onPlayFullscreen?(itemID)
                },
                mergeClipsEnabled: isGroupItem ? false : parent.mergeClipsEnabled,
                mergeClipsAvailable: isGroupItem ? false : parent.mergeClipsAvailable,
                showCommentField: isGroupItem ? false : parent.showCommentField,
                showDateTagButton: isGroupItem ? false : parent.showDateTagButton,
                isCompactMode: isGroupItem ? true : parent.isCompactMode
            )
        }

        // MARK: - Attach Subtitle File

        /// Opens a file picker for SRT/ASS/SSA subtitle files and attaches the selected
        /// file to the given queue item. If the embed-subtitles setting is on and the
        /// item already has an output file, the subtitle is also muxed in.
        private func promptAttachSubtitleFile(itemID: UUID, source: ItemSource) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.title = "Select Subtitle File"
            panel.message = "Choose an SRT, ASS, or SSA subtitle file to attach."
            panel.allowedContentTypes = [
                .init(filenameExtension: "srt")!,
                .init(filenameExtension: "ass")!,
                .init(filenameExtension: "ssa")!,
            ]

            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url, let self else { return }

                // Update the item's subtitleFilePath
                switch source {
                case .ungrouped:
                    if let idx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.droppedFiles[idx].subtitleFilePath = url
                        self.parent.droppedFiles[idx].subtitleStatus = .completed

                        // If embed is enabled and the item already has an output, mux it in
                        let shouldEmbed = UserDefaults.standard.bool(forKey: AppConstants.embedSubtitlesKey)
                        if shouldEmbed, let outputURL = self.parent.droppedFiles[idx].outputURL,
                           self.parent.droppedFiles[idx].status == .done {
                            Task {
                                await ConversionManager.shared.embedSubtitlesForAttachedFile(
                                    srtURL: url,
                                    videoURL: outputURL,
                                    itemID: itemID
                                )
                            }
                        }
                    }
                case .group(let groupID):
                    if let gIdx = self.parent.encodingGroups.firstIndex(where: { $0.id == groupID }),
                       let iIdx = self.parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                        self.parent.encodingGroups[gIdx].items[iIdx].subtitleFilePath = url
                        self.parent.encodingGroups[gIdx].items[iIdx].subtitleStatus = .completed

                        let shouldEmbed = UserDefaults.standard.bool(forKey: AppConstants.embedSubtitlesKey)
                        if shouldEmbed, let outputURL = self.parent.encodingGroups[gIdx].items[iIdx].outputURL,
                           self.parent.encodingGroups[gIdx].items[iIdx].status == .done {
                            Task {
                                await ConversionManager.shared.embedSubtitlesForAttachedFile(
                                    srtURL: url,
                                    videoURL: outputURL,
                                    itemID: itemID
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
