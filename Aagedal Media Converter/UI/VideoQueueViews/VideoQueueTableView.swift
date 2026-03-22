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
    var transcribeOnly: ((UUID) async -> Void)?

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

        // Store initial snapshot
        context.coordinator.previousIDs = droppedFiles.map(\.id)
        context.coordinator.previousCompactMode = isCompactMode

        return scrollView
    }

    // MARK: - updateNSView

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let tableView = coordinator.tableView else { return }

        // Always update the parent reference so closures are current
        coordinator.parent = self

        let newIDs = droppedFiles.map(\.id)
        let oldIDs = coordinator.previousIDs

        if newIDs == oldIDs {
            // Same structure and order - update visible cells in-place.
            // This preserves SwiftUI internal state (focus, hover, etc.)
            coordinator.updateVisibleCells()
        } else if Set(newIDs) == Set(oldIDs) && newIDs.count == oldIDs.count {
            // Same items, different order (reorder only) - use moveRow
            // instead of reloadData to avoid recreating all visible cells.
            coordinator.applyRowMoves(from: oldIDs, to: newIDs)
            coordinator.updateVisibleCells()
        } else {
            // Items added or removed - full reload required
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
               let row = droppedFiles.firstIndex(where: { $0.id == firstSelectedID }) {
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
            droppedFiles.firstIndex(where: { $0.id == id })
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

        private static let cellID = NSUserInterfaceItemIdentifier("VideoQueueCell")

        init(parent: VideoQueueTableView) {
            self.parent = parent
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.droppedFiles.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < parent.droppedFiles.count else { return nil }

            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? VideoQueueTableCellView
                ?? VideoQueueTableCellView()
            cell.identifier = Self.cellID

            let rowContent = buildRowView(for: row)
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
            let selectedRows = tableView.selectedRowIndexes
            let newSelection = Set(selectedRows.compactMap { row -> UUID? in
                guard row < parent.droppedFiles.count else { return nil }
                return parent.droppedFiles[row].id
            })
            parent.selection = newSelection
        }

        // MARK: Drag-to-Reorder

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .videoQueueItem)
            return item
        }

        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            // Only allow drops between rows (above), not on rows
            guard dropOperation == .above else { return [] }

            // Only accept internal reorder drags
            if info.draggingSource as? NSTableView === tableView {
                return .move
            }
            return []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard info.draggingSource as? NSTableView === tableView else { return false }

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

            // Extract items to move
            let movedItems = sourceRows.map { parent.droppedFiles[$0] }

            // Calculate destination accounting for removed items
            var adjustedDest = row
            for sourceRow in sourceRows where sourceRow < row {
                adjustedDest -= 1
            }

            // Remove source items (reverse order to preserve indices)
            for sourceRow in sourceRows.reversed() {
                parent.droppedFiles.remove(at: sourceRow)
            }

            // Insert at destination
            parent.droppedFiles.insert(contentsOf: movedItems, at: adjustedDest)

            // Update selection to moved items
            let movedIDs = Set(movedItems.map(\.id))
            parent.selection = movedIDs

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
            let visibleRange = tableView.rows(in: tableView.visibleRect)
            guard visibleRange.length > 0 else { return }
            let start = visibleRange.location
            let end = min(start + visibleRange.length, parent.droppedFiles.count)
            for row in start..<end {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? VideoQueueTableCellView else { continue }
                let rowContent = buildRowView(for: row)
                cell.configure(with: AnyView(rowContent))
            }
        }

        // MARK: Row Builder

        private func buildRowView(for row: Int) -> some View {
            let itemID = parent.droppedFiles[row].id
            let isSelected = parent.selection.contains(itemID)

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

            let fileBinding = Binding<VideoItem>(
                get: { [weak self] in
                    guard let self,
                          let currentIndex = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) else {
                        return placeholderItem
                    }
                    return self.parent.droppedFiles[currentIndex]
                },
                set: { [weak self] newValue in
                    guard let self,
                          let currentIndex = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) else { return }
                    self.parent.droppedFiles[currentIndex] = newValue
                }
            )

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
                    if let currentIdx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.onDelete(IndexSet(integer: currentIdx))
                    }
                },
                onReset: { [weak self] optionKeyPressed in
                    guard let self else { return }
                    if let currentIdx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.onReset(currentIdx, optionKeyPressed)
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
                    if let currentIdx = self.parent.droppedFiles.firstIndex(where: { $0.id == itemID }) {
                        self.parent.onDelete(IndexSet(integer: currentIdx))
                    }
                },
                onTranscribeOnly: { [weak self] in
                    guard let self else { return }
                    let callback = self.parent.transcribeOnly
                    Task { @MainActor in
                        await callback?(itemID)
                    }
                },
                onRenameOutputFileName: { [weak self] newName in
                    self?.parent.onRenameOutputFileName?(itemID, newName)
                },
                isSelected: isSelected,
                onCommentFocusChange: { [weak self] id, isFocused in
                    guard let self else { return }
                    guard self.parent.droppedFiles.contains(where: { $0.id == id }) else { return }
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
                mergeClipsEnabled: parent.mergeClipsEnabled,
                mergeClipsAvailable: parent.mergeClipsAvailable,
                showCommentField: parent.showCommentField,
                showDateTagButton: parent.showDateTagButton,
                isCompactMode: parent.isCompactMode
            )
            .padding([.vertical], 4)
        }
    }
}
