// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// Represents the phase of an import operation
enum ImportPhase: Sendable {
    case placeholder        // Basic info only (name, size)
    case detailsLoaded      // Duration, hasVideoStream, outputURL
    case thumbnailLoaded    // Row thumbnail
    case metadataLoaded     // Full VideoMetadata
    case complete           // All data loaded
}

/// Update sent through the import stream
enum ImportUpdate: Sendable {
    /// Initial batch of placeholders added
    case placeholdersAdded([VideoItem])
    /// Details loaded for a specific item
    case itemDetailsLoaded(id: UUID, details: VideoFileUtils.VideoItemDetails)
    /// Thumbnail loaded for a specific item
    case itemThumbnailLoaded(id: UUID, thumbnailData: Data)
    /// Metadata loaded for a specific item
    case itemMetadataLoaded(id: UUID, metadata: VideoMetadata?)
    /// Batch import completed
    case completed(addedCount: Int, duplicateCount: Int, skippedCount: Int)
    /// Error occurred
    case error(Error)
}

/// Result of an import batch operation
struct ImportBatchResult: Sendable {
    let addedItems: [VideoItem]
    let duplicateCount: Int
    let skippedCount: Int
    let failedURLs: [URL]
}

/// Actor that manages file imports with proper concurrency, deduplication, and streaming updates.
/// Replaces the duplicate import logic in ContentView and VideoFileListView.
actor FileImportManager {
    static let shared = FileImportManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FileImportManager")

    // Configuration
    // SwiftExif video parsing is I/O- and memory-bound, not CPU-bound: more parallelism
    // doesn't speed it up much but multiplies peak RAM (a single MKV parse can hold
    // tens of GB transiently). Keep this small to avoid OOM on bulk imports of large files.
    private let maxConcurrentLoads = 2

    // State tracking for deduplication across concurrent imports
    private var importingURLs: Set<URL> = []
    private var knownURLs: Set<URL> = []

    // Active import task (allows cancellation)
    private var activeImportTask: Task<Void, Never>?

    // MARK: - Public API

    /// Synchronizes the known URLs set with the current queue state
    /// Call this when items are removed from the queue
    func synchronizeKnownURLs(_ urls: Set<URL>) {
        knownURLs = urls
    }

    /// Adds URLs to the known set (for deduplication without full sync)
    func addToKnownURLs(_ urls: [URL]) {
        for url in urls {
            knownURLs.insert(url)
        }
    }

    /// Removes a URL from the known set (when item is removed from queue)
    func removeFromKnownURLs(_ url: URL) {
        knownURLs.remove(url)
    }

    /// Returns true if any imports are currently in progress
    var isImporting: Bool {
        !importingURLs.isEmpty
    }

    /// Cancels any in-progress imports
    func cancelImports() {
        activeImportTask?.cancel()
        activeImportTask = nil
        importingURLs.removeAll()
    }

    /// Imports files and streams updates back to the caller
    /// - Parameters:
    ///   - urls: URLs to import
    ///   - existingURLs: Already known URLs for deduplication (from current queue)
    ///   - outputFolder: Current output folder path
    ///   - preset: Selected export preset
    ///   - applyMute: Whether to auto-mute (for VideoLoop preset)
    /// - Returns: AsyncStream of ImportUpdate events
    func importFiles(
        urls: [URL],
        existingURLs: Set<URL>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool
    ) -> AsyncStream<ImportUpdate> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                await self.performImport(
                    urls: urls,
                    existingURLs: existingURLs,
                    outputFolder: outputFolder,
                    preset: preset,
                    applyMute: applyMute,
                    continuation: continuation
                )
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Implementation

    private func performImport(
        urls: [URL],
        existingURLs: Set<URL>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool,
        continuation: AsyncStream<ImportUpdate>.Continuation
    ) async {
        var duplicateCount = 0
        var skippedCount = 0
        var newItems: [VideoItem] = []
        var itemsToProcess: [(UUID, URL)] = []

        // Combine existing URLs with currently importing URLs for deduplication
        let allKnownURLs = existingURLs.union(knownURLs).union(importingURLs)

        // 1. Create placeholders synchronously (fast)
        for url in urls {
            // Check for duplicates against all known sources
            guard !allKnownURLs.contains(url) && !newItems.contains(where: { $0.url == url }) else {
                duplicateCount += 1
                continue
            }

            // Mark as importing immediately to prevent races
            importingURLs.insert(url)

            guard var placeholder = VideoFileUtils.makePlaceholderItem(
                from: url,
                outputFolder: outputFolder,
                preset: preset
            ) else {
                logger.debug("Skipping unsupported file: \(url.lastPathComponent, privacy: .public)")
                importingURLs.remove(url)
                skippedCount += 1
                continue
            }

            // Apply auto-mute if needed
            if applyMute {
                placeholder.isMuted = true
            }

            newItems.append(placeholder)
            itemsToProcess.append((placeholder.id, url))
        }

        guard !newItems.isEmpty else {
            continuation.yield(.completed(addedCount: 0, duplicateCount: duplicateCount, skippedCount: skippedCount))
            continuation.finish()
            return
        }

        // 2. Yield placeholders immediately for UI display
        continuation.yield(.placeholdersAdded(newItems))

        // Add to known URLs for future deduplication
        for item in newItems {
            knownURLs.insert(item.url)
        }

        // 3. Load details with bounded concurrency
        await withTaskGroup(of: Void.self) { group in
            var iterator = itemsToProcess.makeIterator()
            let maxConcurrent = self.maxConcurrentLoads

            func enqueueNext() {
                guard let (id, url) = iterator.next() else { return }
                group.addTask {
                    await self.loadItemDetails(
                        id: id,
                        url: url,
                        outputFolder: outputFolder,
                        preset: preset,
                        continuation: continuation
                    )
                }
            }

            // Start initial batch of concurrent tasks
            for _ in 0..<min(maxConcurrent, itemsToProcess.count) {
                enqueueNext()
            }

            // As tasks complete, enqueue more to maintain max concurrency
            while await group.next() != nil {
                enqueueNext()
            }
        }

        // 4. Clean up importing state
        for (_, url) in itemsToProcess {
            importingURLs.remove(url)
        }

        // 5. Signal completion
        continuation.yield(.completed(addedCount: newItems.count, duplicateCount: duplicateCount, skippedCount: skippedCount))
        continuation.finish()
    }

    private func loadItemDetails(
        id: UUID,
        url: URL,
        outputFolder: String,
        preset: ExportPreset,
        continuation: AsyncStream<ImportUpdate>.Continuation
    ) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let outputURL = VideoFileUtils.makeOutputURLPublic(for: url, outputFolder: outputFolder, preset: preset)

        // Phase 1: Single SwiftExif probe that returns duration + topology in one parse,
        // and seeds the metadata caches so Phase 2 hits cache instead of re-parsing.
        var earlyDuration: Double = 0
        if let essential = try? await VideoMetadataService.shared.fetchEssentialInfo(for: url) {
            earlyDuration = essential.duration
            let earlyDetails = VideoFileUtils.VideoItemDetails(
                size: size,
                duration: VideoFileUtils.formatDuration(seconds: essential.duration),
                durationSeconds: essential.duration,
                thumbnailData: nil,
                outputURL: outputURL,
                hasVideoStream: essential.hasVideoStream
            )
            continuation.yield(.itemDetailsLoaded(id: id, details: earlyDetails))
        }

        // Phase 2: Full metadata probe (cached after Phase 1 for SwiftExif-readable containers)
        do {
            let metadata = try await VideoMetadataService.shared.metadata(for: url)

            let duration = metadata.duration ?? earlyDuration
            let hasVideoStream = !metadata.videoStreams.isEmpty

            // Yield corrected details if duration or hasVideoStream changed
            if earlyDuration <= 0 || duration != earlyDuration || !hasVideoStream {
                let details = VideoFileUtils.VideoItemDetails(
                    size: size,
                    duration: VideoFileUtils.formatDuration(seconds: duration),
                    durationSeconds: duration,
                    thumbnailData: nil,
                    outputURL: outputURL,
                    hasVideoStream: hasVideoStream
                )
                continuation.yield(.itemDetailsLoaded(id: id, details: details))
            }

            continuation.yield(.itemMetadataLoaded(id: id, metadata: metadata))

        } catch {
            logger.error("Failed to load metadata for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")

            // If Phase 1 yielded nothing, fall back to legacy loadDetails so the row still gets duration/thumbnail.
            if earlyDuration <= 0 {
                let details = await VideoFileUtils.loadDetails(
                    for: url,
                    outputFolder: outputFolder,
                    preset: preset,
                    generateRowThumbnailIfMissing: false
                )
                continuation.yield(.itemDetailsLoaded(id: id, details: details))
            }

            continuation.yield(.itemMetadataLoaded(id: id, metadata: nil))
        }

        // Phase 3: Thumbnail (always after duration is visible)
        if let thumbnailData = await VideoFileUtils.getCachedThumbnail(
            url: url,
            generateRowThumbnailIfMissing: true
        ) {
            continuation.yield(.itemThumbnailLoaded(id: id, thumbnailData: thumbnailData))
        }
    }
}

// MARK: - VideoFileUtils Extension for Public Access

extension VideoFileUtils {
    /// Public wrapper for makeOutputURL (used by FileImportManager)
    static func makeOutputURLPublic(for url: URL, outputFolder: String?, preset: ExportPreset) -> URL? {
        let resolvedOutputFolder = resolveOutputFolder(for: url, defaultOutputFolder: outputFolder, preset: preset)
        guard let resolvedOutputFolder else { return nil }
        let sanitizedBaseName = FileNameProcessor.processFileName(url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""

        let outputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        return FileSafetyUtils.safeOutputURL(
            inputURL: url,
            outputFolder: outputFolderURL,
            baseName: sanitizedBaseName,
            suffix: suffixPart,
            fileExtension: resolvedExtension
        )
    }
}
