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

// MARK: - Custom Table View (initiates file drag instead of row drag when clicking DraggableFileImageView)

private final class VideoQueueNSTableView: NSTableView {

    /// Tracks whether we're in a file-drag so we can override the operation mask.
    private var isFileDrag = false

    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if isFileDrag {
            return .copy
        }
        return super.draggingSession(session, sourceOperationMaskFor: context)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isFileDrag = false
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let hitView = hitTest(localPoint) {
            let dragView = (hitView as? DraggableFileImageView) ?? (hitView.superview as? DraggableFileImageView)
            if let dragView, let fileURL = dragView.fileURL {
                // Start a file drag session from the table view, bypassing row-reorder
                isFileDrag = true
                let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
                let iconBounds = dragView.convert(dragView.bounds, to: self)
                let dragImage = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
                    ?? dragView.image
                    ?? NSImage()
                draggingItem.setDraggingFrame(iconBounds, contents: dragImage)
                beginDraggingSession(with: [draggingItem], event: event, source: self)
                return
            }
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Custom Row View (suppresses default selection highlight)

private final class TransparentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        // No-op: SwiftUI VideoFileRowView handles its own selection border
    }
}

// MARK: - Table Cell View (hosts SwiftUI via NSHostingView)

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
    var encodeOnly: ((UUID) async -> Void)?
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
        let filesByID = Dictionary(uniqueKeysWithValues: droppedFiles.map { ($0.id, $0) })
        let groupsByID = Dictionary(uniqueKeysWithValues: encodingGroups.map { ($0.id, $0) })

        var rows: [FlatQueueRow] = []
        rows.reserveCapacity(queueOrder.count)
        for id in queueOrder {
            if let item = filesByID[id] {
                rows.append(.single(item))
            } else if let group = groupsByID[id] {
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
    func queueOrderIndex(forDisplayRow row: Int, in displayRows: [FlatQueueRow], queueOrderLookup: [UUID: Int]? = nil) -> Int {
        guard row < displayRows.count else { return queueOrder.count }
        let targetID: UUID
        switch displayRows[row] {
        case .single(let item): targetID = item.id
        case .groupHeader(let group): targetID = group.id
        case .groupItem(_, let groupID): targetID = groupID
        }
        if let lookup = queueOrderLookup {
            return lookup[targetID] ?? queueOrder.count
        }
        return queueOrder.firstIndex(of: targetID) ?? queueOrder.count
    }

    // MARK: - makeNSView

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let tableView = VideoQueueNSTableView()
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAutomaticRowHeights = false
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
        context.coordinator.rebuildLookupCaches()
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
        coordinator.rebuildLookupCaches()
        let newIDs = displayRows.map(\.id)
        let oldIDs = coordinator.previousIDs

        // Handle compact mode changes - notify table about row height changes
        // Must happen before updateVisibleCells so cells get reconfigured
        if isCompactMode != coordinator.previousCompactMode {
            coordinator.previousCompactMode = isCompactMode
            if tableView.numberOfRows > 0 {
                let allRows = IndexSet(integersIn: 0..<tableView.numberOfRows)
                tableView.noteHeightOfRows(withIndexesChanged: allRows)
            }
        }

        if newIDs == oldIDs {
            coordinator.updateVisibleCells()
        } else if Set(newIDs) == Set(oldIDs) && newIDs.count == oldIDs.count {
            coordinator.applyRowMoves(from: oldIDs, to: newIDs)
            coordinator.updateVisibleCells()
        } else {
            tableView.reloadData()
        }

        coordinator.previousIDs = newIDs

        // Sync selection: SwiftUI -> NSTableView
        syncSelectionToTableView(coordinator: coordinator, tableView: tableView)

        // Handle scroll-to-selection
        if shouldScrollToSelection {
            if let firstSelectedID = selection.first,
               let row = coordinator.displayRowIndex[firstSelectedID] {
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

        let desiredRows = IndexSet(selection.compactMap { id in
            coordinator.displayRowIndex[id]
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

        // O(1) lookup caches — rebuilt each updateNSView cycle
        var droppedFilesIndex: [UUID: Int] = [:]
        var encodingGroupsIndex: [UUID: Int] = [:]
        var displayRowIndex: [UUID: Int] = [:]
        var queueOrderLookup: [UUID: Int] = [:]
        var itemToGroupID: [UUID: UUID] = [:]

        /// Item IDs with an in-flight background thumbnail decode.
        /// Prevents duplicate enqueues when the same cell scrolls in/out quickly.
        var inFlightThumbnailDecodes: Set<UUID> = []

        /// Previous item count per group, used to auto-reapply sequential naming
        /// when items are added to or removed from a group (mirrors the onChange
        /// watcher in the old SwiftUI EncodingGroupHeaderView).
        var previousGroupItemCount: [UUID: Int] = [:]

        /// Previous snapshot for selective cell updates
        var previousDisplayRows: [FlatQueueRow] = []
        var previousSelection: Set<UUID> = []
        var previousPreset: ExportPreset?
        var previousMergeEnabled = false
        var previousMergeAvailable = false
        var previousShowComment = true
        var previousShowDateTag = true

        private static let cellID = NSUserInterfaceItemIdentifier("VideoQueueCell")
        private static let appkitCellID = NSUserInterfaceItemIdentifier("VideoFileCellView")
        private static let groupHeaderCellID = NSUserInterfaceItemIdentifier("EncodingGroupHeaderCellView")
        private static let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub"]

        init(parent: VideoQueueTableView) {
            self.parent = parent
            super.init()
        }

        /// Rebuilds all UUID → index lookup dictionaries from current state.
        func rebuildLookupCaches() {
            droppedFilesIndex.removeAll(keepingCapacity: true)
            for (i, item) in parent.droppedFiles.enumerated() {
                droppedFilesIndex[item.id] = i
            }

            encodingGroupsIndex.removeAll(keepingCapacity: true)
            for (i, group) in parent.encodingGroups.enumerated() {
                encodingGroupsIndex[group.id] = i
            }

            displayRowIndex.removeAll(keepingCapacity: true)
            for (i, row) in cachedDisplayRows.enumerated() {
                displayRowIndex[row.id] = i
            }

            queueOrderLookup.removeAll(keepingCapacity: true)
            for (i, id) in parent.queueOrder.enumerated() {
                queueOrderLookup[id] = i
            }

            itemToGroupID.removeAll(keepingCapacity: true)
            for group in parent.encodingGroups {
                for item in group.items {
                    itemToGroupID[item.id] = group.id
                }
            }

            // Re-apply sequential naming when a group's item count has changed
            // (drag-in, drag-out, programmatic add/remove). Mirrors the old
            // SwiftUI .onChange(of: group.items.count) watcher.
            for (idx, group) in parent.encodingGroups.enumerated() {
                let prev = previousGroupItemCount[group.id]
                let current = group.items.count
                if let prev, prev != current, group.sequentialNamingEnabled {
                    parent.encodingGroups[idx].normalizeSequentialNaming()
                }
                previousGroupItemCount[group.id] = current
            }

            // Drop tracked counts for groups that no longer exist
            if !previousGroupItemCount.isEmpty {
                let validGroupIDs = Set(parent.encodingGroups.map(\.id))
                previousGroupItemCount = previousGroupItemCount.filter { validGroupIDs.contains($0.key) }
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            cachedDisplayRows.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return nil }

            switch displayRows[row] {
            case .single(let item), .groupItem(let item, _):
                let cell = tableView.makeView(withIdentifier: Self.appkitCellID, owner: nil) as? VideoFileCellView
                    ?? VideoFileCellView()
                cell.identifier = Self.appkitCellID
                let isGroupItem: Bool
                if case .groupItem = displayRows[row] { isGroupItem = true } else { isGroupItem = false }
                let config = buildCellConfiguration(item: item, isGroupItem: isGroupItem)
                let capturedID = item.id
                cell.configure(with: config) { [weak self] (action: CellAction) in
                    guard let self else { return }
                    self.handleCellAction(action, itemID: capturedID, displayRows: self.cachedDisplayRows, row: row)
                }
                return cell
            case .groupHeader(let group):
                let cell = tableView.makeView(withIdentifier: Self.groupHeaderCellID, owner: nil) as? EncodingGroupHeaderCellView
                    ?? EncodingGroupHeaderCellView()
                cell.identifier = Self.groupHeaderCellID
                let config = buildGroupCellConfiguration(group: group)
                let capturedID = group.id
                cell.configure(with: config) { [weak self] (action: CellAction) in
                    self?.handleGroupAction(action, groupID: capturedID)
                }
                return cell
            }
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            TransparentRowView()
        }

        // MARK: Row Height (fixed, avoids Auto Layout solving)

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            let displayRows = cachedDisplayRows
            guard row < displayRows.count else { return 200 }
            // All row types share the same height to unify the column look.
            _ = displayRows[row]
            return parent.isCompactMode ? 103 : 170
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
            let destQueueIndex = parent.queueOrderIndex(forDisplayRow: row, in: displayRows, queueOrderLookup: queueOrderLookup)

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
            var positionOf: [UUID: Int] = Dictionary(minimumCapacity: oldIDs.count)
            for (i, id) in oldIDs.enumerated() { positionOf[id] = i }
            tableView.beginUpdates()
            for newIndex in 0..<newIDs.count {
                let targetID = newIDs[newIndex]
                guard let currentIndex = positionOf[targetID], currentIndex != newIndex else { continue }
                workingIDs.remove(at: currentIndex)
                workingIDs.insert(targetID, at: newIndex)
                let lo = min(currentIndex, newIndex)
                let hi = max(currentIndex, newIndex)
                for i in lo...hi { positionOf[workingIDs[i]] = i }
                tableView.moveRow(at: currentIndex, to: newIndex)
            }
            tableView.endUpdates()
        }

        // MARK: Update Visible Cells

        /// Updates visible cells in-place by setting hostingView.rootView.
        /// This preserves SwiftUI internal state (focus, hover, text editing)
        /// unlike reloadData(forRowIndexes:) which destroys and recreates cells.
        /// Only updates cells whose data or selection actually changed.
        func updateVisibleCells() {
            guard let tableView = tableView else { return }
            let displayRows = cachedDisplayRows
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }
            let start = visibleRange.location
            let end = min(start + visibleRange.length, displayRows.count)

            let newSelection = parent.selection

            // If global view state changed, update all visible cells
            let globalChanged = parent.preset != previousPreset
                || parent.mergeClipsEnabled != previousMergeEnabled
                || parent.mergeClipsAvailable != previousMergeAvailable
                || parent.showCommentField != previousShowComment
                || parent.showDateTagButton != previousShowDateTag
                || parent.isCompactMode != previousCompactMode

            for row in start..<end {
                // Skip cells where row data and selection are unchanged
                if !globalChanged,
                   row < previousDisplayRows.count,
                   displayRows[row] == previousDisplayRows[row],
                   newSelection.contains(displayRows[row].id) == previousSelection.contains(displayRows[row].id) {
                    continue
                }
                guard let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) else { continue }
                if let appkitCell = cellView as? VideoFileCellView {
                    switch displayRows[row] {
                    case .single(let item), .groupItem(let item, _):
                        let isGroupItem: Bool
                        if case .groupItem = displayRows[row] { isGroupItem = true } else { isGroupItem = false }
                        let config = buildCellConfiguration(item: item, isGroupItem: isGroupItem)
                        let capturedID = item.id
                        appkitCell.configure(with: config) { [weak self] (action: CellAction) in
                            guard let self else { return }
                            self.handleCellAction(action, itemID: capturedID, displayRows: self.cachedDisplayRows, row: row)
                        }
                    default: break
                    }
                } else if let groupCell = cellView as? EncodingGroupHeaderCellView {
                    if case .groupHeader(let group) = displayRows[row] {
                        let config = buildGroupCellConfiguration(group: group)
                        let capturedID = group.id
                        groupCell.configure(with: config) { [weak self] (action: CellAction) in
                            self?.handleGroupAction(action, groupID: capturedID)
                        }
                    }
                }
            }

            previousDisplayRows = displayRows
            previousSelection = newSelection
            previousPreset = parent.preset
            previousMergeEnabled = parent.mergeClipsEnabled
            previousMergeAvailable = parent.mergeClipsAvailable
            previousShowComment = parent.showCommentField
            previousShowDateTag = parent.showDateTagButton
        }

        // MARK: - Thumbnail Resolution

        /// Returns a cached thumbnail if available, otherwise kicks off an async
        /// background decode and returns nil. When the decode completes the
        /// matching visible cell is updated directly via `applyDecodedThumbnail`.
        func resolvedThumbnail(for item: VideoItem) -> NSImage? {
            if let cached = ThumbnailCache.shared[item.id] {
                return cached
            }
            if let data = item.thumbnailData {
                enqueueThumbnailDecode(itemID: item.id, data: data)
            }
            return nil
        }

        /// Dispatches a thumbnail decode to a background queue. Hops back to
        /// MainActor to populate the cache and refresh the live cell.
        private func enqueueThumbnailDecode(itemID: UUID, data: Data) {
            guard !inFlightThumbnailDecodes.contains(itemID) else { return }
            inFlightThumbnailDecodes.insert(itemID)
            ThumbnailDecoder.queue.async { [weak self] in
                let image = ThumbnailDecoder.decodeSync(data: data)
                DispatchQueue.main.async {
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.completeThumbnailDecode(itemID: itemID, image: image)
                    }
                }
            }
        }

        private func completeThumbnailDecode(itemID: UUID, image: NSImage?) {
            inFlightThumbnailDecodes.remove(itemID)
            if let image {
                ThumbnailCache.shared[itemID] = image
            }
            guard let tableView = self.tableView,
                  let row = displayRowIndex[itemID] else { return }
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? VideoFileCellView else { return }
            cell.applyDecodedThumbnail(image, forItemID: itemID)
        }

        // MARK: - AppKit Cell Configuration Builder

        func buildCellConfiguration(item: VideoItem, isGroupItem: Bool) -> VideoFileCellConfiguration {
            let metadata = item.metadata
            let audioStreams = metadata?.audioStreams ?? []
            let hasBitmapSubs = metadata?.subtitleStreams.contains { Self.bitmapCodecs.contains($0.codec?.lowercased() ?? "") } ?? false
            let hasSurround = audioStreams.contains { ($0.channels ?? 0) > 2 }
            let audioRouting = item.audioRoutingConfig
            let hasCustomRouting = audioRouting?.isCustomized ?? false
            let hasDownmix = audioRouting?.outputTracks.contains { $0.downmixToStereo } ?? false
            let hasOutputSurroundNoDownmix = audioRouting?.hasOutputSurroundWithoutDownmix ?? false
            let trackCount = audioRouting?.outputTracks.count ?? 0

            var timecodeMode: String? = nil
            if let tc = item.timecodeConfig {
                switch tc.mode {
                case .manual: timecodeMode = "MAN"
                case .preserveSource:
                    timecodeMode = (metadata?.timecode != nil) ? "SRC" : "No TC"
                }
            }

            let cropPct: Int
            let hasCrop: Bool
            if let crop = item.cropConfig, crop.isActive {
                hasCrop = true
                cropPct = Int(crop.normalizedRect.width * 100)
            } else {
                hasCrop = false
                cropPct = 0
            }

            return VideoFileCellConfiguration(
                itemID: item.id,
                name: item.name,
                duration: item.duration,
                durationSeconds: item.durationSeconds,
                formattedSize: item.formattedSize,
                status: item.status,
                progress: item.progress,
                eta: item.eta,
                conversionError: item.conversionError,
                comment: item.comment,
                includeDateTag: item.includeDateTag,
                outputURL: item.outputURL,
                url: item.url,
                thumbnailImage: resolvedThumbnail(for: item),
                hasVideoStream: item.hasVideoStream,
                isSelected: parent.selection.contains(item.id),
                isCompactMode: isGroupItem ? true : parent.isCompactMode,
                showCommentField: isGroupItem ? false : parent.showCommentField,
                showDateTagButton: isGroupItem ? false : parent.showDateTagButton,
                isFocusedComment: parent.focusedCommentID == item.id,
                preset: parent.preset,
                mergeClipsEnabled: isGroupItem ? false : parent.mergeClipsEnabled,
                mergeClipsAvailable: isGroupItem ? false : parent.mergeClipsAvailable,
                outputFileExists: item.outputFileExists,
                outputFileNameOverride: item.outputFileNameOverride,
                isDownloading: item.isDownloading,
                downloadProgress: item.downloadProgress,
                downloadHasProgress: item.downloadHasProgress,
                downloadSpeed: item.downloadSpeed,
                downloadError: item.downloadError,
                fileAlreadyExistsPath: item.fileAlreadyExistsPath,
                sourceURL: item.sourceURL,
                scheduledDownloadTime: item.scheduledDownloadTime,
                autoEncodeAfterDownload: item.autoEncodeAfterDownload,
                isLiveStreamRecording: item.isLiveStreamRecording,
                downloadStopping: item.downloadStopping,
                uploadEnabled: item.uploadEnabled,
                uploadSourceFile: item.uploadSourceFile,
                uploadStatus: item.uploadStatus,
                uploadProgress: item.uploadProgress,
                subtitleEnabled: item.subtitleEnabled,
                subtitleStatus: item.subtitleStatus,
                subtitleProgress: item.subtitleProgress,
                subtitleFilePath: item.subtitleFilePath,
                subtitleMethod: item.subtitleMethod,
                hasBitmapSubtitles: hasBitmapSubs,
                audioStreamCount: audioStreams.count,
                analyticsEnabled: item.analyticsEnabled,
                analyticsStatus: item.analyticsStatus,
                analyticsProgress: item.analyticsProgress,
                hasAnalyticsResults: item.analyticsResults != nil,
                isReadyForAnalytics: item.isReadyForAnalytics,
                canRunAnalyticsWithFilePicker: item.canRunAnalyticsWithFilePicker,
                isMuted: item.isMuted,
                hasCustomAudioRouting: hasCustomRouting,
                hasSurroundAudio: hasSurround,
                hasDownmix: hasDownmix,
                audioTrackCount: trackCount,
                hasOutputSurroundWithoutDownmix: hasOutputSurroundNoDownmix,
                hasTrim: item.trimStart != nil || item.trimEnd != nil,
                trimmedDuration: item.trimmedDuration,
                hasCrop: hasCrop,
                cropPercentage: cropPct,
                hasTimecodeConfig: item.timecodeConfig != nil,
                timecodeMode: timecodeMode,
                loopPlayback: item.loopPlayback,
                waveformVideoEnabled: item.waveformVideoEnabled,
                isImageSequence: item.isImageSequence,
                isGroupChild: isGroupItem,
                isDCPPreset: parent.preset == .dcp,
                dcpMetadataTitle: item.dcpMetadata?.contentTitleText,
                showDCPAudioWarning: parent.preset == .dcp && !(audioRouting?.isCustomized ?? false) && audioStreams.count > 1 && !audioStreams.allSatisfy { ($0.channels ?? 0) == 1 },
                formattedOutputSize: item.formattedOutputSize,
                isTranscriptionAvailable: WhisperUpdateService.shared.getInstallationStatus().isAvailable || ParakeetService.shared.getInstallationStatus().isAvailable,
                isUploadConfigured: UploadManager.shared.isConfigured
            )
        }

        // MARK: - Group Cell Configuration Builder

        func buildGroupCellConfiguration(group: EncodingGroup) -> EncodingGroupCellConfiguration {
            let concatOutputURL: URL? = {
                guard group.concatEnabled, group.status == .done,
                      let first = group.items.first else { return nil }
                return first.outputURL
            }()

            let (concatExists, existingURL): (Bool, URL?) = {
                guard group.concatEnabled, group.status == .waiting,
                      let first = group.items.first,
                      let output = first.outputURL else { return (false, nil) }
                let exists = FileManager.default.fileExists(atPath: output.path)
                return (exists, exists ? output : nil)
            }()

            return EncodingGroupCellConfiguration(
                groupID: group.id,
                name: group.name,
                isExpanded: group.isExpanded,
                itemCount: group.items.count,
                isSelected: parent.selection.contains(group.id),
                isCompactMode: parent.isCompactMode,
                globalPreset: parent.preset,
                groupPreset: group.preset,
                concatEnabled: group.concatEnabled,
                uploadEnabled: group.uploadEnabled,
                transcriptionEnabled: group.transcriptionEnabled,
                analyticsEnabled: group.analyticsEnabled,
                sequentialNamingEnabled: group.sequentialNamingEnabled,
                isUploadConfigured: UploadManager.shared.isConfigured,
                status: group.status,
                progress: group.progress,
                totalDuration: group.formattedTotalDuration,
                totalSize: "",
                concatOutputURL: concatOutputURL,
                concatOutputAlreadyExists: concatExists,
                concatOutputExistingURL: existingURL,
                uploadSummary: buildGroupUploadSummary(items: group.items)
            )
        }

        private func buildGroupUploadSummary(items: [VideoItem]) -> EncodingGroupCellConfiguration.UploadSummaryState {
            let uploadItems = items.filter { $0.uploadEnabled }
            guard !uploadItems.isEmpty else { return .hidden }

            let uploaded = uploadItems.filter { $0.uploadStatus.isComplete }.count
            let failed = uploadItems.filter { $0.uploadStatus.hasFailed }.count
            let uploading = uploadItems.filter { $0.uploadStatus == .uploading }
            let pending = uploadItems.filter { $0.uploadStatus == .pending }.count
            let total = uploadItems.count

            if uploaded == total {
                return .uploaded(count: uploaded, total: total)
            }
            if failed > 0 && uploading.isEmpty && pending == 0 {
                return .failed(count: failed, total: total)
            }
            if let current = uploading.first {
                let completed = Double(uploaded)
                let overall = (completed + current.uploadProgress) / Double(total)
                return .uploading(completed: uploaded, total: total, progress: overall, speed: current.uploadSpeed)
            }
            if pending > 0 {
                return .pending(uploaded: uploaded, total: total)
            }
            return .hidden
        }

        // MARK: - Group Action Handler

        func handleGroupAction(_ action: CellAction, groupID: UUID) {
            guard let idx = encodingGroupsIndex[groupID],
                  idx < parent.encodingGroups.count,
                  parent.encodingGroups[idx].id == groupID else { return }

            switch action {
            case .toggleExpanded:
                parent.encodingGroups[idx].isExpanded.toggle()
            case .groupNameChanged(let name):
                parent.encodingGroups[idx].name = name
                if parent.encodingGroups[idx].sequentialNamingEnabled {
                    parent.encodingGroups[idx].normalizeSequentialNaming()
                }
            case .toggleConcat:
                parent.encodingGroups[idx].concatEnabled.toggle()
            case .toggleGroupUpload:
                parent.encodingGroups[idx].uploadEnabled.toggle()
            case .toggleGroupTranscription:
                parent.encodingGroups[idx].transcriptionEnabled.toggle()
            case .toggleGroupAnalytics:
                parent.encodingGroups[idx].analyticsEnabled.toggle()
            case .toggleSequentialNaming:
                parent.encodingGroups[idx].sequentialNamingEnabled.toggle()
                parent.encodingGroups[idx].normalizeSequentialNaming()
            case .setGroupPreset(let preset):
                parent.encodingGroups[idx].preset = preset
            case .deleteGroup:
                parent.onDeleteGroup?(groupID)
            case .addFilesToGroup:
                parent.onAddFilesToGroup?(groupID)
            case .resetGroup:
                parent.onResetGroup?(groupID)
            default:
                break
            }
        }

        // MARK: - Cell Action Handler

        /// Finds a VideoItem by ID, searching both ungrouped droppedFiles and encoding groups.
        private func findItem(by itemID: UUID) -> VideoItem? {
            // Fast path: use O(1) caches
            if let idx = droppedFilesIndex[itemID], idx < parent.droppedFiles.count,
               parent.droppedFiles[idx].id == itemID {
                return parent.droppedFiles[idx]
            }
            if let gID = itemToGroupID[itemID],
               let gIdx = encodingGroupsIndex[gID], gIdx < parent.encodingGroups.count {
                return parent.encodingGroups[gIdx].items.first(where: { $0.id == itemID })
            }
            return nil
        }

        /// Finds the group ID that contains the given item, if any.
        private func groupID(for itemID: UUID) -> UUID? {
            return itemToGroupID[itemID]
        }

        func handleCellAction(_ action: CellAction, itemID: UUID, displayRows: [FlatQueueRow], row: Int) {
            switch action {
            case .delete:
                if let idx = droppedFilesIndex[itemID] {
                    parent.onDelete(IndexSet(integer: idx))
                } else if let gID = groupID(for: itemID),
                          let gIdx = encodingGroupsIndex[gID],
                          let iIdx = parent.encodingGroups[gIdx].items.firstIndex(where: { $0.id == itemID }) {
                    parent.encodingGroups[gIdx].items.remove(at: iIdx)
                }
            case .reset(let optionKeyPressed):
                if let idx = droppedFilesIndex[itemID] {
                    parent.onReset(idx, optionKeyPressed)
                }
            case .cancel:
                Task { await ConversionManager.shared.cancelItem(with: itemID) }
            case .cancelDownload:
                DownloadManager.shared.cancelDownload(itemID: itemID)
            case .stopLiveRecording:
                DownloadManager.shared.stopLiveDownload(itemID: itemID)
            case .retryDownload:
                Task { await DownloadManager.shared.retryDownload(itemID: itemID) }
            case .forceRedownload:
                Task { await DownloadManager.shared.forceRedownload(itemID: itemID) }
            case .cancelScheduledDownload:
                ScheduledDownloadService.shared.cancelScheduledItem(itemID: itemID)
                if let idx = droppedFilesIndex[itemID] {
                    parent.onDelete(IndexSet(integer: idx))
                }
            case .cancelSubtitleGeneration:
                Task { await TesseractService.shared.cancelGeneration() }
                Task { await WhisperService.shared.cancelGeneration() }
                Task { await ParakeetService.shared.cancelGeneration() }
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].subtitleStatus = .notQueued
                }
            case .cancelAnalytics:
                Task { await AnalyticsService.shared.cancelAnalysis() }
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].analyticsStatus = .notQueued
                    parent.droppedFiles[idx].analyticsProgress = 0
                }
            case .encodeNow(let optionPressed):
                if optionPressed {
                    // Option+click: encode this single item immediately
                    let callback = parent.encodeOnly
                    Task { @MainActor in
                        await callback?(itemID)
                    }
                }
            case .toggleUpload(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        parent.droppedFiles[idx].uploadSourceFile.toggle()
                        if parent.droppedFiles[idx].uploadSourceFile {
                            parent.droppedFiles[idx].uploadEnabled = true
                            Task { await UploadManager.shared.startUpload(itemID: itemID) }
                        }
                    } else {
                        parent.droppedFiles[idx].uploadEnabled.toggle()
                        if !parent.droppedFiles[idx].uploadEnabled {
                            parent.droppedFiles[idx].uploadSourceFile = false
                        }
                    }
                }
            case .toggleTranscription(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        let method: SubtitleConversionMethod = UserDefaults.standard.string(forKey: AppConstants.defaultTranscriptionEngineKey) == "parakeet" ? .parakeet : .whisper
                        Task { @MainActor in
                            await parent.transcribeOnly?(itemID, method)
                        }
                    } else {
                        parent.droppedFiles[idx].subtitleEnabled.toggle()
                        if parent.droppedFiles[idx].subtitleEnabled {
                            let method: SubtitleConversionMethod = UserDefaults.standard.string(forKey: AppConstants.defaultTranscriptionEngineKey) == "parakeet" ? .parakeet : .whisper
                            parent.droppedFiles[idx].subtitleMethod = method
                        }
                    }
                }
            case .toggleOCR(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if optionPressed {
                        Task { @MainActor in
                            await parent.transcribeOnly?(itemID, .ocr)
                        }
                    } else if parent.droppedFiles[idx].subtitleEnabled && parent.droppedFiles[idx].subtitleMethod == .ocr {
                        parent.droppedFiles[idx].subtitleEnabled = false
                    } else {
                        parent.droppedFiles[idx].subtitleMethod = .ocr
                        parent.droppedFiles[idx].subtitleEnabled = true
                    }
                }
            case .toggleAnalytics(let optionPressed):
                if let idx = droppedFilesIndex[itemID] {
                    if parent.droppedFiles[idx].analyticsResults != nil {
                        if optionPressed && parent.droppedFiles[idx].isReadyForAnalytics {
                            parent.droppedFiles[idx].analyticsResults = nil
                            parent.droppedFiles[idx].analyticsStatus = .notQueued
                            Task { @MainActor in
                                await parent.analyzeOnly?(itemID)
                            }
                        } else {
                            // Show results — handled via sheet
                            parent.onOpenMetadata?([itemID])
                        }
                    } else if parent.droppedFiles[idx].isReadyForAnalytics {
                        Task { @MainActor in
                            await parent.analyzeOnly?(itemID)
                        }
                    } else {
                        parent.droppedFiles[idx].analyticsEnabled.toggle()
                    }
                }
            case .toggleAutoEncode:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].autoEncodeAfterDownload.toggle()
                }
            case .toggleWaveform:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].waveformVideoEnabled.toggle()
                }
            case .toggleDateTag:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].includeDateTag.toggle()
                }
            case .toggleMute:
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].isMuted.toggle()
                }
            case .commentChanged(let text):
                if let idx = droppedFilesIndex[itemID] {
                    parent.droppedFiles[idx].comment = text
                }
            case .commentFocusChanged(let focused):
                if focused {
                    if !parent.selection.contains(itemID) {
                        parent.selection = [itemID]
                    }
                    parent.focusedCommentID = itemID
                } else if parent.focusedCommentID == itemID {
                    parent.focusedCommentID = nil
                }
            case .beginRename:
                parent.onRenameOutputFileName?(itemID, nil)
            case .commitRename(let name):
                parent.onRenameOutputFileName?(itemID, name)
            case .showPreview:
                parent.onOpenTrim?(itemID)
            case .showMetadata:
                parent.onOpenMetadata?([itemID])
            case .showAudioRouting:
                parent.onOpenAudioConfig?(itemID)
            case .showTimecode:
                parent.onOpenTimecode?(itemID)
            case .playFullscreen:
                parent.onPlayFullscreen?(itemID)
            case .showInFinder:
                if let item = findItem(by: itemID) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            case .showOutputInFinder:
                if let item = findItem(by: itemID), let url = item.outputURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .showSubtitleInFinder:
                if let item = findItem(by: itemID), let url = item.subtitleFilePath {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case .showDownloadedInFinder:
                if let item = findItem(by: itemID) {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
            case .attachSubtitleFile:
                promptAttachSubtitleFile(itemID: itemID, source: .ungrouped)
            default:
                // Group actions and sheet presentations not yet handled for AppKit cells
                break
            }
        }

        private enum ItemSource {
            case ungrouped
            case group(UUID)
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
