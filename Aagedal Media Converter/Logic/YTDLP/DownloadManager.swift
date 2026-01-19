// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftUI

/// Manages yt-dlp downloads and coordinates with the video queue
@MainActor
@Observable
class DownloadManager {
    static let shared = DownloadManager()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "DownloadManager")
    private let ytdlpService = YTDLPService()

    /// Active download tasks keyed by VideoItem ID
    private var downloadTasks: [UUID: Task<Void, Never>] = [:]

    /// Queue of video items (bound from ContentView)
    var videoItems: Binding<[VideoItem]>?

    /// Output folder for downloads
    var outputFolder: URL?

    /// Callback to trigger encoding for a specific item (set by ContentView)
    var onAutoEncode: ((UUID) -> Void)?

    private init() {}

    /// Starts a download using stored videoItems and outputFolder references
    /// Used for scheduled downloads where we can't capture fresh bindings
    @discardableResult
    func startDownloadWithStoredReferences(url urlString: String) async -> UUID? {
        guard let items = videoItems, let folder = outputFolder else {
            logger.error("Cannot start scheduled download: videoItems or outputFolder not set")
            return nil
        }
        return await startDownload(url: urlString, items: items, outputFolder: folder)
    }

    /// Schedules a download for a future time - creates an item in the queue immediately
    /// - Parameters:
    ///   - urlString: The video URL to download
    ///   - scheduledTime: When the download should start
    ///   - items: Binding to the video items array
    ///   - outputFolder: The folder to save downloads
    /// - Returns: The UUID of the created VideoItem
    @discardableResult
    func scheduleDownload(url urlString: String, at scheduledTime: Date, items: Binding<[VideoItem]>, outputFolder: URL) async -> UUID? {
        self.videoItems = items
        self.outputFolder = outputFolder

        // Create a placeholder VideoItem with scheduled time
        let placeholderURL = URL(fileURLWithPath: "/tmp/scheduled-\(UUID().uuidString)")
        var item = VideoItem(
            url: placeholderURL,
            name: "Scheduled download",
            size: 0,
            duration: "--:--",
            durationSeconds: 0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        item.sourceURL = urlString
        item.scheduledDownloadTime = scheduledTime

        // Apply default automation settings
        item.autoEncodeAfterDownload = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        item.uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)

        let itemID = item.id

        // Add to queue
        items.wrappedValue.insert(item, at: 0)

        // Debug timezone info
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = .current
        let localTimeStr = formatter.string(from: scheduledTime)
        logger.info("Scheduled download for \(localTimeStr) (local time), URL: \(urlString)")

        // Register with ScheduledDownloadService
        ScheduledDownloadService.shared.registerScheduledItem(itemID: itemID, scheduledTime: scheduledTime)

        return itemID
    }

    /// Starts a previously scheduled download (called by ScheduledDownloadService when time is reached)
    func startScheduledDownload(itemID: UUID) async {
        let startTime = Date()
        logger.info("[TIMING] startScheduledDownload entered")

        guard videoItems != nil, let folder = outputFolder else {
            logger.error("Cannot start scheduled download: videoItems or outputFolder not set")
            return
        }

        guard let item = findItem(itemID), let sourceURL = item.sourceURL else {
            logger.error("Cannot find scheduled item or source URL")
            return
        }

        let findItemElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] Found item in \(String(format: "%.3f", findItemElapsed))s")

        // Clear the scheduled time and mark as downloading
        updateItem(itemID) { item in
            item.scheduledDownloadTime = nil
            item.isDownloading = true
            item.name = "Fetching info..."
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
        }

        let setupElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] Item setup completed in \(String(format: "%.3f", setupElapsed))s, starting download task...")

        // Start download task
        let task = Task {
            await self.performDownload(itemID: itemID, urlString: sourceURL, outputFolder: folder)
        }
        downloadTasks[itemID] = task
    }

    /// Checks if yt-dlp is available and configured
    func isYTDLPConfigured() async -> Bool {
        await YTDLPUpdateService.shared.isYTDLPAvailable()
    }

    /// Starts a download for a URL and adds it to the video queue
    /// - Parameters:
    ///   - urlString: The video URL to download
    ///   - items: Binding to the video items array
    ///   - outputFolder: The folder to save downloads
    /// - Returns: The UUID of the created VideoItem, or nil if yt-dlp is not configured
    @discardableResult
    func startDownload(url urlString: String, items: Binding<[VideoItem]>, outputFolder: URL) async -> UUID? {
        // Check if yt-dlp is available
        guard await isYTDLPConfigured() else {
            logger.error("yt-dlp not configured. Please configure in Settings > General > Video Downloads.")
            return nil
        }

        self.videoItems = items
        self.outputFolder = outputFolder

        // Create a placeholder VideoItem
        let placeholderURL = URL(fileURLWithPath: "/tmp/downloading-\(UUID().uuidString)")
        var item = VideoItem(
            url: placeholderURL,
            name: "Fetching info...",
            size: 0,
            duration: "--:--",
            durationSeconds: 0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        item.isDownloading = true
        item.sourceURL = urlString
        item.downloadProgress = 0
        item.downloadHasProgress = false
        item.downloadSpeed = nil

        // Apply default automation settings
        item.autoEncodeAfterDownload = UserDefaults.standard.bool(forKey: AppConstants.autoEncodeAfterDownloadKey)
        item.uploadEnabled = UserDefaults.standard.bool(forKey: AppConstants.autoUploadAfterDownloadKey)

        let itemID = item.id

        // Add to queue
        items.wrappedValue.insert(item, at: 0)

        // Start download task (using unowned self since DownloadManager is a singleton)
        let task = Task {
            await self.performDownload(itemID: itemID, urlString: urlString, outputFolder: outputFolder)
        }
        downloadTasks[itemID] = task

        return itemID
    }

    /// Performs the actual download
    private func performDownload(itemID: UUID, urlString: String, outputFolder: URL) async {
        let downloadStartTime = Date()
        logger.info("[TIMING] performDownload started at \(downloadStartTime)")

        // Start the actual download immediately (don't wait for metadata)
        do {
            let actualDownloadStartTime = Date()
            logger.info("[TIMING] Starting download immediately for: \(urlString)")

            let result = try await ytdlpService.download(
                url: urlString,
                outputFolder: outputFolder,
                forceOverwrite: false
            ) { [weak self] progress, speed in
                Task { @MainActor in
                    self?.updateItem(itemID) { item in
                        item.downloadProgress = progress
                        item.downloadHasProgress = true
                        item.downloadSpeed = speed
                        // Also update the main progress for the progress bar
                        item.progress = progress
                    }
                }
            }

            // Download complete - update item
            let downloadElapsed = Date().timeIntervalSince(actualDownloadStartTime)
            let totalElapsed = Date().timeIntervalSince(downloadStartTime)
            logger.info("[TIMING] Download complete: \(result.outputURL.path)")
            logger.info("[TIMING] Actual download took \(String(format: "%.2f", downloadElapsed))s, total elapsed: \(String(format: "%.2f", totalElapsed))s")

            let videoTitle = result.title.isEmpty
                ? result.outputURL.deletingPathExtension().lastPathComponent
                : result.title

            // Save to download history
            DownloadHistoryService.addEntry(
                url: urlString,
                title: videoTitle,
                outputFileName: result.outputURL.lastPathComponent
            )

            updateItem(itemID) { item in
                item.url = result.outputURL
                item.name = result.outputURL.lastPathComponent
                item.isDownloading = false
                item.downloadProgress = 1.0
                item.downloadSpeed = nil
                item.progress = 0  // Reset for encoding
                item.status = .waiting
                item.detailsLoaded = false  // Will be loaded by the queue

                // Get file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path),
                   let size = attrs[.size] as? Int64 {
                    item.size = size
                }
            }

            // Trigger details and metadata loading for the downloaded file
            if let item = findItem(itemID) {
                let shouldAutoEncode = item.autoEncodeAfterDownload
                Task.detached {
                    // Load basic details (size, duration, thumbnail)
                    let details = await VideoFileUtils.loadDetails(for: item.url)
                    await MainActor.run {
                        self.updateItem(itemID) { item in
                            item.apply(details: details)
                            item.detailsLoaded = true
                        }
                    }

                    // Load full metadata (video/audio streams, codecs, etc.)
                    let metadata = await VideoFileUtils.fetchMetadata(for: item.url)
                    await MainActor.run {
                        self.updateItem(itemID) { item in
                            item.metadata = metadata
                        }

                        // Trigger auto-encode if enabled
                        if shouldAutoEncode {
                            self.logger.info("Auto-encoding enabled for downloaded item: \(itemID)")
                            self.onAutoEncode?(itemID)
                        }
                    }
                }
            }

        } catch let error as YTDLPError {
            switch error {
            case .fileAlreadyExists(let path, let title):
                logger.warning("File already exists: \(path)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = "File already exists"
                    item.fileAlreadyExistsPath = path
                    item.status = .failed
                    item.name = title
                }
            default:
                logger.error("Download failed: \(error.localizedDescription)")
                updateItem(itemID) { item in
                    item.isDownloading = false
                    item.downloadError = error.localizedDescription
                    item.status = .failed
                }
            }
        } catch {
            logger.error("Download failed: \(error.localizedDescription)")

            updateItem(itemID) { item in
                item.isDownloading = false
                item.downloadError = error.localizedDescription
                item.status = .failed
            }
        }

        // Clean up task reference
        downloadTasks.removeValue(forKey: itemID)
    }

    /// Cancels a download
    func cancelDownload(itemID: UUID) async {
        if let task = downloadTasks[itemID] {
            task.cancel()
            downloadTasks.removeValue(forKey: itemID)
        }

        await ytdlpService.cancelDownload()

        // Update item state
        updateItem(itemID) { item in
            item.isDownloading = false
            item.downloadError = "Cancelled"
            item.status = .cancelled
        }
    }

    /// Retries a failed download
    func retryDownload(itemID: UUID) async {
        guard let item = findItem(itemID),
              let sourceURL = item.sourceURL,
              let outputFolder = outputFolder else {
            return
        }

        // Reset item state
        updateItem(itemID) { item in
            item.isDownloading = true
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
            item.downloadError = nil
            item.fileAlreadyExistsPath = nil
            item.status = .waiting
        }

        // Start new download
        let task = Task {
            await self.performDownload(itemID: itemID, urlString: sourceURL, outputFolder: outputFolder)
        }
        downloadTasks[itemID] = task
    }

    /// Force re-downloads, overwriting existing file
    func forceRedownload(itemID: UUID) async {
        guard let item = findItem(itemID),
              let sourceURL = item.sourceURL,
              let outputFolder = outputFolder else {
            return
        }

        // Reset item state
        updateItem(itemID) { item in
            item.isDownloading = true
            item.downloadProgress = 0
            item.downloadHasProgress = false
            item.downloadSpeed = nil
            item.downloadError = nil
            item.fileAlreadyExistsPath = nil
            item.status = .waiting
        }

        // Start download with force overwrite
        let task = Task {
            await self.performForceDownload(itemID: itemID, urlString: sourceURL, outputFolder: outputFolder)
        }
        downloadTasks[itemID] = task
    }

    /// Performs a forced download (overwrites existing files)
    private func performForceDownload(itemID: UUID, urlString: String, outputFolder: URL) async {
        do {
            // Start the actual download with force overwrite
            logger.info("Starting forced download for: \(urlString)")

            let result = try await ytdlpService.download(
                url: urlString,
                outputFolder: outputFolder,
                forceOverwrite: true
            ) { [weak self] progress, speed in
                Task { @MainActor in
                    self?.updateItem(itemID) { item in
                        item.downloadProgress = progress
                        item.downloadHasProgress = true
                        item.downloadSpeed = speed
                        item.progress = progress
                    }
                }
            }

            // Download complete - update item
            logger.info("Force download complete: \(result.outputURL.path)")

            // Save to download history
            DownloadHistoryService.addEntry(
                url: urlString,
                title: result.title.isEmpty
                    ? result.outputURL.deletingPathExtension().lastPathComponent
                    : result.title,
                outputFileName: result.outputURL.lastPathComponent
            )

            updateItem(itemID) { item in
                item.url = result.outputURL
                item.name = result.outputURL.lastPathComponent
                item.isDownloading = false
                item.downloadProgress = 1.0
                item.downloadSpeed = nil
                item.progress = 0  // Reset for encoding
                item.status = .waiting
                item.detailsLoaded = false

                // Get file size
                if let attrs = try? FileManager.default.attributesOfItem(atPath: result.outputURL.path),
                   let size = attrs[.size] as? Int64 {
                    item.size = size
                }
            }

            // Trigger details and metadata loading for the downloaded file
            if let item = findItem(itemID) {
                let shouldAutoEncode = item.autoEncodeAfterDownload
                Task.detached {
                    // Load basic details (size, duration, thumbnail)
                    let details = await VideoFileUtils.loadDetails(for: item.url)
                    await MainActor.run {
                        self.updateItem(itemID) { item in
                            item.apply(details: details)
                            item.detailsLoaded = true
                        }
                    }

                    // Load full metadata (video/audio streams, codecs, etc.)
                    let metadata = await VideoFileUtils.fetchMetadata(for: item.url)
                    await MainActor.run {
                        self.updateItem(itemID) { item in
                            item.metadata = metadata
                        }

                        // Trigger auto-encode if enabled
                        if shouldAutoEncode {
                            self.logger.info("Auto-encoding enabled for re-downloaded item: \(itemID)")
                            self.onAutoEncode?(itemID)
                        }
                    }
                }
            }

        } catch {
            logger.error("Force download failed: \(error.localizedDescription)")

            updateItem(itemID) { item in
                item.isDownloading = false
                item.downloadError = error.localizedDescription
                item.status = .failed
            }
        }

        // Clean up task reference
        downloadTasks.removeValue(forKey: itemID)
    }

    /// Removes a download from the queue
    func removeDownload(itemID: UUID) async {
        // Cancel if in progress
        await cancelDownload(itemID: itemID)

        // Remove from queue
        videoItems?.wrappedValue.removeAll { $0.id == itemID }
    }

    /// Checks if a URL is likely supported by yt-dlp
    static func isYTDLPCompatibleURL(_ url: URL) -> Bool {
        let supportedHosts = [
            "youtube.com", "www.youtube.com", "youtu.be", "m.youtube.com",
            "vimeo.com", "www.vimeo.com",
            "twitch.tv", "www.twitch.tv",
            "twitter.com", "x.com",
            "facebook.com", "www.facebook.com", "fb.watch",
            "instagram.com", "www.instagram.com",
            "tiktok.com", "www.tiktok.com",
            "reddit.com", "www.reddit.com",
            "dailymotion.com", "www.dailymotion.com"
        ]

        guard let host = url.host?.lowercased() else { return false }
        return supportedHosts.contains { host.contains($0) }
    }

    /// Checks if a string is a valid URL for yt-dlp
    nonisolated static func isValidURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    // MARK: - Private Helpers

    private func updateItem(_ itemID: UUID, update: (inout VideoItem) -> Void) {
        guard let items = videoItems else { return }
        if let index = items.wrappedValue.firstIndex(where: { $0.id == itemID }) {
            update(&items.wrappedValue[index])
        }
    }

    private func findItem(_ itemID: UUID) -> VideoItem? {
        videoItems?.wrappedValue.first { $0.id == itemID }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
