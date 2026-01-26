// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Shared state for the metadata window, allowing reactive updates when selection changes in the main window.
@MainActor @Observable
final class MetadataWindowState {
    static let shared = MetadataWindowState()

    /// The UUIDs of currently selected items in the main window
    var selectedItemIDs: Set<UUID> = []

    /// All items in the queue (for lookup by ID)
    var allItems: [VideoItem] = []

    /// Whether the metadata window is currently visible
    var isWindowVisible: Bool = false

    /// The items that are currently selected, filtered from allItems
    var selectedItems: [VideoItem] {
        allItems.filter { selectedItemIDs.contains($0.id) }
    }

    private init() {}
}
