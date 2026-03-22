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
import SwiftUI
import UniformTypeIdentifiers

/// Bridges FileImportManager actor to SwiftUI with batched updates.
/// This is the single entry point for all file imports in the app.
@MainActor
@Observable
final class FileImportCoordinator {
    static let shared = FileImportCoordinator()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FileImportCoordinator")
    private let updateFlushDelayNanoseconds: UInt64 = 120_000_000

    /// Index for O(1) lookups by URL or ID
    let itemIndex = VideoItemIndex()
    private var pendingUpdates = PendingImportUpdates()
    private var flushTask: Task<Void, Never>?

    // MARK: - Import Methods

    /// Import files from a file picker result
    /// - Parameters:
    ///   - result: The file picker result
    ///   - droppedFiles: Binding to the video items array
    ///   - outputFolder: The output folder path
    ///   - preset: The selected export preset
    ///   - applyMute: Whether to auto-mute (for VideoLoop preset)
    func importFromFilePicker(
        result: Result<[URL], Error>,
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool
    ) async {
        switch result {
        case .success(let urls):
            // Separate folders/images from regular media files
            var mediaURLs: [URL] = []
            var sequenceItems: [VideoItem] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    // Folder — detect image sequences
                    _ = url.startAccessingSecurityScopedResource()
                    let sequences = ImageSequenceDetector.detectSequences(inFolder: url)
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
                    url.stopAccessingSecurityScopedResource()
                    for config in sequences {
                        sequenceItems.append(VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config, outputFolder: outputFolder, preset: preset
                        ))
                    }
                } else {
                    let ext = url.pathExtension.lowercased()
                    if AppConstants.supportedImageSequenceExtensions.contains(ext) {
                        // Image file — detect sequence from parent directory
                        _ = url.startAccessingSecurityScopedResource()
                        if let config = ImageSequenceDetector.detectSequence(fromFile: url) {
                            let parentDir = url.deletingLastPathComponent()
                            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: parentDir)
                            sequenceItems.append(VideoFileUtils.makePlaceholderItem(
                                fromImageSequence: config, outputFolder: outputFolder, preset: preset
                            ))
                        }
                        url.stopAccessingSecurityScopedResource()
                    } else {
                        mediaURLs.append(url)
                    }
                }
            }

            // Add image sequences directly
            if !sequenceItems.isEmpty {
                let startIndex = droppedFiles.wrappedValue.count
                droppedFiles.wrappedValue.append(contentsOf: sequenceItems)
                itemIndex.appendedItems(sequenceItems, startingAt: startIndex)
                await FileImportManager.shared.addToKnownURLs(sequenceItems.map { $0.url })
            }

            // Import regular media files
            if !mediaURLs.isEmpty {
                await performImport(
                    urls: mediaURLs,
                    droppedFiles: droppedFiles,
                    outputFolder: outputFolder,
                    preset: preset,
                    applyMute: applyMute
                )
            }

        case .failure(let error):
            logger.error("Error selecting files: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Import files from a watch folder
    /// - Parameters:
    ///   - urls: URLs to import
    ///   - droppedFiles: Binding to the video items array
    ///   - outputFolder: The output folder path
    ///   - preset: The selected export preset
    ///   - applyMute: Whether to auto-mute (for VideoLoop preset)
    func importFromWatchFolder(
        urls: [URL],
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool
    ) async {
        await performImport(
            urls: urls,
            droppedFiles: droppedFiles,
            outputFolder: outputFolder,
            preset: preset,
            applyMute: applyMute
        )
    }

    /// Import files from drag-and-drop NSItemProviders
    /// - Parameters:
    ///   - providers: NSItemProviders from the drop
    ///   - droppedFiles: Binding to the video items array
    ///   - outputFolder: The output folder path
    ///   - preset: The selected export preset
    ///   - applyMute: Whether to auto-mute (for VideoLoop preset)
    ///   - onURLDrop: Callback for URL drops (like YouTube links)
    func importFromProviders(
        _ providers: [NSItemProvider],
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool,
        onURLDrop: ((URL) -> Void)? = nil
    ) async {
        let (urls, imageSequenceItems) = await extractURLsAndSequences(
            from: providers,
            outputFolder: outputFolder,
            preset: preset,
            onURLDrop: onURLDrop
        )

        // Add any detected image sequence items directly to the queue
        if !imageSequenceItems.isEmpty {
            let startIndex = droppedFiles.wrappedValue.count
            droppedFiles.wrappedValue.append(contentsOf: imageSequenceItems)
            itemIndex.appendedItems(imageSequenceItems, startingAt: startIndex)
            await FileImportManager.shared.addToKnownURLs(imageSequenceItems.map { $0.url })
            logger.info("Added \(imageSequenceItems.count) image sequence(s) to queue")
        }

        // Import regular media files through the normal pipeline
        guard !urls.isEmpty else { return }

        await performImport(
            urls: urls,
            droppedFiles: droppedFiles,
            outputFolder: outputFolder,
            preset: preset,
            applyMute: applyMute
        )
    }

    /// Synchronizes the item index with the current queue state.
    /// Call this when items are removed from the queue.
    func synchronizeIndex(with items: [VideoItem]) {
        itemIndex.rebuild(from: items)
        Task {
            await FileImportManager.shared.synchronizeKnownURLs(itemIndex.allURLs)
        }
    }

    /// Notifies that an item was removed from the queue
    func itemRemoved(at index: Int, remainingItems: [VideoItem]) {
        itemIndex.removedItem(at: index, remainingItems: remainingItems)
        Task {
            await FileImportManager.shared.synchronizeKnownURLs(itemIndex.allURLs)
        }
    }

    /// Notifies that multiple items were removed from the queue
    func itemsRemoved(at indices: IndexSet, remainingItems: [VideoItem]) {
        itemIndex.removedItems(at: indices, remainingItems: remainingItems)
        Task {
            await FileImportManager.shared.synchronizeKnownURLs(itemIndex.allURLs)
        }
    }

    // MARK: - Private Implementation

    private func performImport(
        urls: [URL],
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        applyMute: Bool
    ) async {
        let existingURLs = itemIndex.allURLs

        let stream = await FileImportManager.shared.importFiles(
            urls: urls,
            existingURLs: existingURLs,
            outputFolder: outputFolder,
            preset: preset,
            applyMute: applyMute
        )

        // Process stream updates - first get placeholders synchronously, then handle rest in background
        for await update in stream {
            switch update {
            case .placeholdersAdded:
                // Handle placeholders immediately and let UI render
                await handleImportUpdate(update, droppedFiles: droppedFiles)
                // Give UI time to render before processing more updates
                await Task.yield()
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            case .itemDetailsLoaded, .itemThumbnailLoaded, .itemMetadataLoaded:
                enqueueUpdate(update, droppedFiles: droppedFiles)
            case .completed, .error:
                enqueueUpdate(update, droppedFiles: droppedFiles)
            }
        }

        await flushPendingUpdates(droppedFiles: droppedFiles, cancelScheduledFlush: true)
    }

    private func handleImportUpdate(_ update: ImportUpdate, droppedFiles: Binding<[VideoItem]>) async {
        switch update {
        case .placeholdersAdded(let items):
            // Record starting index for the index
            let startIndex = droppedFiles.wrappedValue.count
            droppedFiles.wrappedValue.append(contentsOf: items)
            itemIndex.appendedItems(items, startingAt: startIndex)
            logger.debug("Added \(items.count) placeholders to queue")
            // Yield to allow UI to render the new items immediately
            await Task.yield()

        case .itemDetailsLoaded(let id, let details):
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count {
                droppedFiles.wrappedValue[index].apply(details: details)
                droppedFiles.wrappedValue[index].detailsLoaded = true
            }

        case .itemThumbnailLoaded(let id, let thumbnailData):
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count,
               droppedFiles.wrappedValue[index].thumbnailData == nil {
                droppedFiles.wrappedValue[index].thumbnailData = thumbnailData
            }

        case .itemMetadataLoaded(let id, let metadata):
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count {
                droppedFiles.wrappedValue[index].metadata = metadata
            }

        case .completed(let addedCount, let duplicateCount, let skippedCount):
            if duplicateCount > 0 || skippedCount > 0 {
                logger.info("Import completed: \(addedCount) added, \(duplicateCount) duplicates, \(skippedCount) skipped")
            }

        case .error(let error):
            logger.error("Import error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enqueueUpdate(_ update: ImportUpdate, droppedFiles: Binding<[VideoItem]>) {
        switch update {
        case .itemDetailsLoaded(let id, let details):
            pendingUpdates.details[id] = details
        case .itemThumbnailLoaded(let id, let thumbnailData):
            pendingUpdates.thumbnails[id] = thumbnailData
        case .itemMetadataLoaded(let id, let metadata):
            pendingUpdates.metadata[id] = MetadataUpdate(value: metadata)
        case .completed(let addedCount, let duplicateCount, let skippedCount):
            pendingUpdates.completion = (addedCount, duplicateCount, skippedCount)
        case .error(let error):
            pendingUpdates.errors.append(error)
        case .placeholdersAdded:
            break
        }

        scheduleFlushIfNeeded(droppedFiles: droppedFiles)
    }

    private func scheduleFlushIfNeeded(droppedFiles: Binding<[VideoItem]>) {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: updateFlushDelayNanoseconds)
            } catch {
                return
            }
            await flushPendingUpdates(droppedFiles: droppedFiles, cancelScheduledFlush: false)
        }
    }

    private func flushPendingUpdates(droppedFiles: Binding<[VideoItem]>, cancelScheduledFlush: Bool) async {
        guard pendingUpdates.hasContent else {
            if cancelScheduledFlush {
                flushTask?.cancel()
            }
            flushTask = nil
            return
        }

        if cancelScheduledFlush {
            flushTask?.cancel()
        }
        let updates = pendingUpdates
        pendingUpdates = PendingImportUpdates()
        flushTask = nil

        for (id, details) in updates.details {
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count {
                droppedFiles.wrappedValue[index].apply(details: details)
                droppedFiles.wrappedValue[index].detailsLoaded = true
            }
        }

        for (id, thumbnailData) in updates.thumbnails {
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count,
               droppedFiles.wrappedValue[index].thumbnailData == nil {
                droppedFiles.wrappedValue[index].thumbnailData = thumbnailData
            }
        }

        for (id, metadataUpdate) in updates.metadata {
            if let index = itemIndex.index(for: id),
               index < droppedFiles.wrappedValue.count {
                droppedFiles.wrappedValue[index].metadata = metadataUpdate.value
            }
        }

        if let completion = updates.completion {
            let (addedCount, duplicateCount, skippedCount) = completion
            if duplicateCount > 0 || skippedCount > 0 {
                logger.info("Import completed: \(addedCount) added, \(duplicateCount) duplicates, \(skippedCount) skipped")
            }
        }

        for error in updates.errors {
            logger.error("Import error: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - URL Extraction from Providers

    private func extractURLs(from providers: [NSItemProvider], onURLDrop: ((URL) -> Void)?) async -> [URL] {
        var fileURLs: [URL] = []
        let supportedExtensions = AppConstants.supportedVideoExtensions

        for provider in providers {
            // Check for plain text URLs (web URLs) first
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let urlString = await loadPlainTextURL(from: provider),
                   DownloadManager.isValidURL(urlString),
                   let url = URL(string: urlString),
                   url.scheme == "http" || url.scheme == "https" {
                    onURLDrop?(url)
                    continue
                }
            }

            // Load file URL using loadObject (works for Finder drops)
            guard provider.canLoadObject(ofClass: URL.self) else { continue }

            let loadedURL: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, error in
                    continuation.resume(returning: object)
                }
            }

            guard let url = loadedURL else { continue }

            // Check if this is a web URL
            if url.scheme == "http" || url.scheme == "https" {
                onURLDrop?(url)
                continue
            }

            // Get security access for the file
            let hasAccess = url.startAccessingSecurityScopedResource()
            var needsBookmarkAccess = false

            if !hasAccess {
                if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                    needsBookmarkAccess = true
                } else if !FileManager.default.isReadableFile(atPath: url.path) {
                    logger.debug("No access to file: \(url.lastPathComponent, privacy: .public)")
                    continue
                }
            }

            // Validate file extension
            let fileExtension = url.pathExtension.lowercased()
            guard !fileExtension.isEmpty, supportedExtensions.contains(fileExtension) else {
                logger.debug("Skipping unsupported file extension: \(fileExtension, privacy: .public) for \(url.lastPathComponent, privacy: .public)")
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                else if needsBookmarkAccess { SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url) }
                continue
            }

            // Save bookmark for future access
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)

            // Stop security access after saving bookmark - the FileImportManager will handle its own access
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            else if needsBookmarkAccess { SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url) }

            fileURLs.append(url)
        }

        return fileURLs
    }

    /// Extended URL extraction that also detects image sequences from dropped folders and image files.
    /// Returns both regular media file URLs and fully-formed VideoItem objects for detected sequences.
    private func extractURLsAndSequences(
        from providers: [NSItemProvider],
        outputFolder: String,
        preset: ExportPreset,
        onURLDrop: ((URL) -> Void)?
    ) async -> (urls: [URL], imageSequenceItems: [VideoItem]) {
        var fileURLs: [URL] = []
        var sequenceItems: [VideoItem] = []
        let supportedExtensions = AppConstants.supportedVideoExtensions
        let imageExtensions = AppConstants.supportedImageSequenceExtensions

        for provider in providers {
            // Check for plain text URLs (web URLs) first
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let urlString = await loadPlainTextURL(from: provider),
                   DownloadManager.isValidURL(urlString),
                   let url = URL(string: urlString),
                   url.scheme == "http" || url.scheme == "https" {
                    onURLDrop?(url)
                    continue
                }
            }

            // Load file URL using loadObject (works for Finder drops)
            guard provider.canLoadObject(ofClass: URL.self) else { continue }

            let loadedURL: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, error in
                    continuation.resume(returning: object)
                }
            }

            guard let url = loadedURL else { continue }

            // Check if this is a web URL
            if url.scheme == "http" || url.scheme == "https" {
                onURLDrop?(url)
                continue
            }

            // Get security access for the file/folder
            let hasAccess = url.startAccessingSecurityScopedResource()
            var needsBookmarkAccess = false

            if !hasAccess {
                if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
                    needsBookmarkAccess = true
                } else if !FileManager.default.isReadableFile(atPath: url.path) {
                    logger.debug("No access to file: \(url.lastPathComponent, privacy: .public)")
                    continue
                }
            }

            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                else if needsBookmarkAccess { SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url) }
            }

            // Check if URL is a directory — try to detect image sequences
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let sequences = ImageSequenceDetector.detectSequences(inFolder: url)
                if !sequences.isEmpty {
                    // Save bookmark for the folder
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
                    for config in sequences {
                        let item = VideoFileUtils.makePlaceholderItem(
                            fromImageSequence: config,
                            outputFolder: outputFolder,
                            preset: preset
                        )
                        sequenceItems.append(item)
                    }
                }
                continue
            }

            // Check if this is an image file that might be part of a sequence
            let fileExtension = url.pathExtension.lowercased()
            if imageExtensions.contains(fileExtension) {
                if let config = ImageSequenceDetector.detectSequence(fromFile: url) {
                    // Save bookmark for the parent directory
                    let parentDir = url.deletingLastPathComponent()
                    _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: parentDir)
                    let item = VideoFileUtils.makePlaceholderItem(
                        fromImageSequence: config,
                        outputFolder: outputFolder,
                        preset: preset
                    )
                    sequenceItems.append(item)
                }
                continue
            }

            // Regular media file
            guard !fileExtension.isEmpty, supportedExtensions.contains(fileExtension) else {
                logger.debug("Skipping unsupported file extension: \(fileExtension, privacy: .public) for \(url.lastPathComponent, privacy: .public)")
                continue
            }

            // Save bookmark for future access
            _ = SecurityScopedBookmarkManager.shared.saveBookmark(for: url)
            fileURLs.append(url)
        }

        return (fileURLs, sequenceItems)
    }

    private func loadPlainTextURL(from provider: NSItemProvider) async -> String? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let data = item as? Data,
                          let string = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: string)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct MetadataUpdate {
    let value: VideoMetadata?
}

private struct PendingImportUpdates {
    var details: [UUID: VideoFileUtils.VideoItemDetails] = [:]
    var thumbnails: [UUID: Data] = [:]
    var metadata: [UUID: MetadataUpdate] = [:]
    var completion: (Int, Int, Int)?
    var errors: [Error] = []

    var hasContent: Bool {
        !details.isEmpty || !thumbnails.isEmpty || !metadata.isEmpty || completion != nil || !errors.isEmpty
    }
}
