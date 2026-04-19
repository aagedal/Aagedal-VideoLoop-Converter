// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Group Editor Window Controller
//
// Detail editor for an encoding group, shown in a standalone panel. The main
// queue keeps the group card as a compact summary; actions that mutate the
// group's contents (reorder, remove, extract, rename, add files) live here so
// the main queue stays focused on high-level queue manipulation.
//
// Follows the same singleton / NSHostingView pattern as MetadataWindowController.

@MainActor
final class GroupEditorWindowController: NSObject, NSWindowDelegate {

    static let shared = GroupEditorWindowController()

    private var currentWindow: NSWindow?
    private var hostingView: NSHostingView<GroupEditorWindowContent>?

    private override init() { super.init() }

    /// Opens (or re-focuses) the editor on `groupID`. Bindings are passed by the
    /// caller so the editor mutates the same underlying @State that ContentView
    /// owns — no snapshot syncing required.
    func open(
        groupID: UUID,
        groups: Binding<[EncodingGroup]>,
        droppedFiles: Binding<[VideoItem]>,
        queueOrder: Binding<[UUID]>,
        onAddFiles: @escaping (UUID) -> Void
    ) {
        let content = GroupEditorWindowContent(
            groupID: groupID,
            groups: groups,
            droppedFiles: droppedFiles,
            queueOrder: queueOrder,
            onAddFiles: onAddFiles,
            onClose: { [weak self] in self?.close() }
        )

        if let existing = currentWindow {
            hostingView?.rootView = content
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Edit Group"
        window.minSize = NSSize(width: 480, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self

        let hosting = NSHostingView(rootView: content)
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = window.contentView?.bounds ?? .zero
        window.contentView = hosting

        positionNextToMainWindow(window)

        currentWindow = window
        hostingView = hosting
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        currentWindow?.close()
        currentWindow = nil
        hostingView = nil
    }

    var isOpen: Bool { currentWindow != nil }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        currentWindow = nil
        hostingView = nil
    }

    private func positionNextToMainWindow(_ window: NSWindow) {
        guard let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else {
            window.center()
            return
        }
        let mainFrame = main.frame
        let size = window.frame.size
        var origin = NSPoint(x: mainFrame.maxX + 20, y: mainFrame.maxY - size.height)
        if let screen = main.screen {
            let sf = screen.visibleFrame
            if origin.x + size.width > sf.maxX { origin.x = mainFrame.minX - size.width - 20 }
            if origin.x < sf.minX { origin.x = sf.midX - size.width / 2 }
            origin.y = max(sf.minY, min(origin.y, sf.maxY - size.height))
        }
        window.setFrameOrigin(origin)
    }
}

// MARK: - Window Content (root)

struct GroupEditorWindowContent: View {
    let groupID: UUID
    @Binding var groups: [EncodingGroup]
    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    var onAddFiles: (UUID) -> Void
    var onClose: () -> Void

    var body: some View {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            GroupEditorView(
                group: $groups[index],
                droppedFiles: $droppedFiles,
                queueOrder: $queueOrder,
                onAddFiles: { onAddFiles(groupID) },
                onClose: onClose
            )
        } else {
            // The group was deleted while the editor was open — dismiss so the
            // user isn't stuck staring at a stale panel.
            Color.clear.onAppear { onClose() }
        }
    }
}

// MARK: - Editor View

struct GroupEditorView: View {
    @Binding var group: EncodingGroup
    @Binding var droppedFiles: [VideoItem]
    @Binding var queueOrder: [UUID]
    var onAddFiles: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            itemList
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
            TextField("Group name", text: $group.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if group.sequentialNamingEnabled {
                        group.normalizeSequentialNaming()
                    }
                }
            Button {
                onAddFiles()
            } label: {
                Label("Add files", systemImage: "plus")
            }
            .controlSize(.regular)
        }
        .padding(12)
    }

    private var itemList: some View {
        List {
            ForEach(group.items) { item in
                GroupEditorRow(
                    item: item,
                    onExtract: { extractItem(id: item.id) },
                    onRemove: { removeItem(id: item.id) }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            }
            .onMove(perform: moveItems)
        }
        .listStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Text(summaryText)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var summaryText: String {
        let count = group.items.count
        let clips = count == 1 ? "1 clip" : "\(count) clips"
        let duration = group.formattedTotalDuration
        return duration.isEmpty ? clips : "\(clips) · \(duration)"
    }

    // MARK: Mutations

    private func moveItems(from source: IndexSet, to destination: Int) {
        group.items.move(fromOffsets: source, toOffset: destination)
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    /// Pops the item out of the group and back into `droppedFiles` as an ungrouped
    /// single, inserting its ID right after the group so it's easy to find. Mirrors
    /// the logic the old mini-row extract button used.
    private func extractItem(id: UUID) {
        guard let idx = group.items.firstIndex(where: { $0.id == id }) else { return }
        let item = group.items.remove(at: idx)
        droppedFiles.append(item)
        if let groupIdx = queueOrder.firstIndex(of: group.id) {
            queueOrder.insert(item.id, at: groupIdx + 1)
        } else {
            queueOrder.append(item.id)
        }
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }

    private func removeItem(id: UUID) {
        guard let idx = group.items.firstIndex(where: { $0.id == id }) else { return }
        group.items.remove(at: idx)
        if group.sequentialNamingEnabled {
            group.normalizeSequentialNaming()
        }
    }
}

// MARK: - Row

private struct GroupEditorRow: View {
    let item: VideoItem
    let onExtract: () -> Void
    let onRemove: () -> Void

    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.tertiaryLabelColor)
                .font(.system(size: 11))

            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.duration)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onExtract) {
                Image(systemName: "folder.badge.minus")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Move out of group (keep in queue)")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.vertical, 4)
        .task { loadThumbnail() }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.12))
                .frame(width: 64, height: 36)
            if let thumb {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "film")
                    .foregroundColor(.secondary)
            }
        }
    }

    private func loadThumbnail() {
        if let cached = ThumbnailCache.shared[item.id] {
            thumb = cached
        }
    }
}

private extension Color {
    static let tertiaryLabelColor = Color(nsColor: .tertiaryLabelColor)
}
