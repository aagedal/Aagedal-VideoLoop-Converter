// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Provides O(1) lookup for VideoItems by URL or ID.
/// Replaces repeated O(n) `firstIndex(where:)` calls during import operations.
@MainActor
final class VideoItemIndex {

    private var urlToIndex: [URL: Int] = [:]
    private var idToIndex: [UUID: Int] = [:]

    /// Returns the index for a given URL, or nil if not found
    func index(for url: URL) -> Int? {
        urlToIndex[url]
    }

    /// Returns the index for a given ID, or nil if not found
    func index(for id: UUID) -> Int? {
        idToIndex[id]
    }

    /// Returns true if the URL already exists in the index
    func contains(url: URL) -> Bool {
        urlToIndex[url] != nil
    }

    /// Returns true if the ID already exists in the index
    func contains(id: UUID) -> Bool {
        idToIndex[id] != nil
    }

    /// Returns the set of all known URLs (for deduplication)
    var allURLs: Set<URL> {
        Set(urlToIndex.keys)
    }

    /// Rebuilds the entire index from the items array
    func rebuild(from items: [VideoItem]) {
        urlToIndex.removeAll(keepingCapacity: true)
        idToIndex.removeAll(keepingCapacity: true)

        for (index, item) in items.enumerated() {
            urlToIndex[item.url] = index
            idToIndex[item.id] = index
        }
    }

    /// Updates the index after items are appended
    /// - Parameters:
    ///   - items: The newly appended items
    ///   - startingAt: The index in the main array where these items start
    func appendedItems(_ items: [VideoItem], startingAt startIndex: Int) {
        for (offset, item) in items.enumerated() {
            let index = startIndex + offset
            urlToIndex[item.url] = index
            idToIndex[item.id] = index
        }
    }

    /// Updates the index after a single item is appended
    func appendedItem(_ item: VideoItem, at index: Int) {
        urlToIndex[item.url] = index
        idToIndex[item.id] = index
    }

    /// Updates the index after an item is removed
    /// Must rebuild subsequent indices since they shift down
    func removedItem(at removedIndex: Int, remainingItems: [VideoItem]) {
        // Remove stale entry (the item that was at removedIndex)
        // We don't know which item was there, so iterate to find and remove it
        urlToIndex = urlToIndex.filter { $0.value != removedIndex }
        idToIndex = idToIndex.filter { $0.value != removedIndex }

        // Decrement indices for all items after the removed one
        for key in urlToIndex.keys {
            if let idx = urlToIndex[key], idx > removedIndex {
                urlToIndex[key] = idx - 1
            }
        }
        for key in idToIndex.keys {
            if let idx = idToIndex[key], idx > removedIndex {
                idToIndex[key] = idx - 1
            }
        }
    }

    /// Updates the index after multiple items are removed
    /// For bulk removals, it's more efficient to just rebuild
    func removedItems(at indices: IndexSet, remainingItems: [VideoItem]) {
        rebuild(from: remainingItems)
    }

    /// Clears the index
    func clear() {
        urlToIndex.removeAll()
        idToIndex.removeAll()
    }
}
