// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import os

/// Detects an IMF (SMPTE ST 2067) package on disk and expands it into the list of
/// MXF essences that the queue should ingest.
///
/// v1 behavior: each unique essence becomes its own queue item; CPL timeline assembly
/// (edit-unit splice points) is left to the user via the existing merge feature.
enum IMFPackageImporter {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "IMFPackageImporter")

    /// One essence resolved out of an IMF package, ready to be added to the queue.
    struct ExpandedEssence: Sendable, Equatable {
        let url: URL
        /// CPL-derived virtual track name (e.g. "Main Audio 1") to use as the queue row title.
        let displayName: String
        let kind: IMFEssenceReference.Kind
    }

    /// Cheap check used by the file-import code paths to decide whether to expand a folder
    /// as an IMF package before falling through to image-sequence detection.
    static func isIMFPackage(folder: URL) -> Bool {
        IMFPackageParser.looksLikeIMFPackage(folder: folder)
    }

    /// Parses the package, saves a security-scoped bookmark for the folder so child
    /// essences remain accessible across launches, and returns the expanded essence list.
    static func expandPackage(folder: URL) -> [ExpandedEssence] {
        let hadAccess = folder.startAccessingSecurityScopedResource()
        defer { if hadAccess { folder.stopAccessingSecurityScopedResource() } }

        do {
            let parsed = try IMFPackageParser.parsePackage(folder: folder)
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: folder)

            // Filter to essences that actually exist on disk and that the app can probe.
            let result = parsed.essences.compactMap { essence -> ExpandedEssence? in
                guard FileManager.default.fileExists(atPath: essence.mxfURL.path) else {
                    logger.warning("CPL references missing essence: \(essence.mxfURL.path)")
                    return nil
                }
                return ExpandedEssence(
                    url: essence.mxfURL,
                    displayName: essence.virtualTrackName,
                    kind: essence.kind
                )
            }
            logger.info("Expanded IMF package \(folder.lastPathComponent) → \(result.count) essence(s)")

            // Stash display-name overrides so VideoFileUtils.makePlaceholderItem can pick them up.
            for essence in result {
                IMFNameOverrides.set(essence.displayName, for: essence.url)
            }
            return result
        } catch {
            logger.error("Failed to expand IMF package \(folder.lastPathComponent): \(error.localizedDescription)")
            return []
        }
    }
}

/// Process-wide store that maps essence URLs to CPL-derived display names.
///
/// Populated by `IMFPackageImporter.expandPackage` and consumed inside
/// `VideoFileUtils.makePlaceholderItem(from:)` so the queue row carries the
/// virtual-track name (e.g. "Main Audio 1") instead of the cryptic UUID-based
/// MXF filename. Entries are removed when consumed so a re-import of the same
/// path falls back to the file's own basename.
enum IMFNameOverrides {
    private static let lock = OSAllocatedUnfairLock<[URL: String]>(initialState: [:])

    static func set(_ name: String, for url: URL) {
        lock.withLock { $0[url] = name }
    }

    /// Returns and clears any pending display-name override for this URL.
    static func consume(for url: URL) -> String? {
        lock.withLock { state in
            if let name = state[url] {
                state.removeValue(forKey: url)
                return name
            }
            return nil
        }
    }
}
