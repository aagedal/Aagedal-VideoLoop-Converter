// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

// MARK: - Encoding Group

/// A group of video items that share conversion settings.
/// Groups can have their own preset, concat, upload, and transcription settings.
struct EncodingGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var items: [VideoItem]
    var isExpanded: Bool
    var preset: ExportPreset?
    var concatEnabled: Bool
    var uploadEnabled: Bool
    var transcriptionEnabled: Bool
    var analyticsEnabled: Bool
    var sequentialNamingEnabled: Bool

    init(
        id: UUID = UUID(),
        name: String,
        items: [VideoItem] = [],
        isExpanded: Bool = false,
        preset: ExportPreset? = nil,
        concatEnabled: Bool = true,
        uploadEnabled: Bool = false,
        transcriptionEnabled: Bool = false,
        analyticsEnabled: Bool = false,
        sequentialNamingEnabled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.isExpanded = isExpanded
        self.preset = preset
        self.concatEnabled = concatEnabled
        self.uploadEnabled = uploadEnabled
        self.transcriptionEnabled = transcriptionEnabled
        self.analyticsEnabled = analyticsEnabled
        self.sequentialNamingEnabled = sequentialNamingEnabled
    }

    var clipCount: Int { items.count }

    var status: ConversionManager.ConversionStatus {
        if items.isEmpty { return .waiting }
        if items.contains(where: { $0.status == .converting }) { return .converting }
        if items.allSatisfy({ $0.status == .done }) { return .done }
        if items.contains(where: { $0.status == .failed }) { return .failed }
        if items.contains(where: { $0.status == .cancelled }) { return .cancelled }
        return .waiting
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0.0) { $0 + $1.progress } / Double(items.count)
    }

    var totalDurationSeconds: Double {
        items.reduce(0.0) { $0 + $1.durationSeconds }
    }

    var formattedTotalDuration: String {
        let total = totalDurationSeconds
        if total <= 0 { return "" }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }
}

// MARK: - Queue Entry

/// A single entry in the conversion queue: either a standalone file or a group.
enum QueueEntry: Identifiable, Equatable, Sendable {
    case single(VideoItem)
    case group(EncodingGroup)

    var id: UUID {
        switch self {
        case .single(let item): return item.id
        case .group(let group): return group.id
        }
    }

    var isSingle: Bool {
        if case .single = self { return true }
        return false
    }

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

// MARK: - Flat Queue Row

/// Flattened representation for the NSTableView data source.
/// Groups are expanded into a header row followed by their item rows.
enum FlatQueueRow: Identifiable {
    case single(VideoItem)
    case groupHeader(EncodingGroup)
    case groupItem(VideoItem, groupID: UUID)

    var id: UUID {
        switch self {
        case .single(let item): return item.id
        case .groupHeader(let group): return group.id
        case .groupItem(let item, _): return item.id
        }
    }
}

// MARK: - Helpers

extension Array where Element == QueueEntry {
    /// Flattens queue entries into rows for the table view.
    /// Expanded groups produce a header row followed by their item rows.
    var flattenedRows: [FlatQueueRow] {
        var rows: [FlatQueueRow] = []
        for entry in self {
            switch entry {
            case .single(let item):
                rows.append(.single(item))
            case .group(let group):
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

    /// All video items across all entries (singles + group items), in queue order.
    var allVideoItems: [VideoItem] {
        flatMap { entry in
            switch entry {
            case .single(let item): return [item]
            case .group(let group): return group.items
            }
        }
    }

    /// All video item URLs for deduplication checks.
    var allVideoURLs: Set<URL> {
        Set(allVideoItems.map { $0.url })
    }

    /// Finds the queue entry index and (for groups) the item index for a given item ID.
    func locate(itemID: UUID) -> (entryIndex: Int, itemIndex: Int?)? {
        for (i, entry) in enumerated() {
            switch entry {
            case .single(let item):
                if item.id == itemID { return (i, nil) }
            case .group(let group):
                if let j = group.items.firstIndex(where: { $0.id == itemID }) {
                    return (i, j)
                }
            }
        }
        return nil
    }

    /// Finds the queue entry index for a given group ID.
    func locateGroup(groupID: UUID) -> Int? {
        firstIndex(where: { $0.id == groupID })
    }
}
