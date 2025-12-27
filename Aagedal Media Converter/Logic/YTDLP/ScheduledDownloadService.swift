// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftUI

/// Represents a scheduled download item
struct ScheduledDownloadItem: Equatable {
    let itemID: UUID
    let scheduledTime: Date

    var isOverdue: Bool {
        scheduledTime <= Date()
    }

    var timeUntilDownload: TimeInterval {
        scheduledTime.timeIntervalSinceNow
    }
}

/// Service for managing scheduled downloads
/// Works with VideoItem IDs - items are created in the queue immediately when scheduled
@MainActor
@Observable
class ScheduledDownloadService {
    static let shared = ScheduledDownloadService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "ScheduledDownloadService")
    private var timer: Timer?

    /// Currently scheduled downloads (itemID -> scheduledTime)
    private(set) var scheduledItems: [ScheduledDownloadItem] = []

    private init() {
        startTimer()
    }

    // MARK: - Public API

    /// Registers a VideoItem as scheduled for download
    /// Called by DownloadManager after creating the item in the queue
    func registerScheduledItem(itemID: UUID, scheduledTime: Date) {
        let item = ScheduledDownloadItem(itemID: itemID, scheduledTime: scheduledTime)
        scheduledItems.append(item)
        scheduledItems.sort { $0.scheduledTime < $1.scheduledTime }
        logger.info("Registered scheduled download: \(itemID) for \(scheduledTime)")
    }

    /// Cancels a scheduled download by item ID
    func cancelScheduledItem(itemID: UUID) {
        scheduledItems.removeAll { $0.itemID == itemID }
        logger.info("Cancelled scheduled download: \(itemID)")
    }

    /// Gets the count of pending scheduled downloads
    var pendingCount: Int {
        scheduledItems.count
    }

    // MARK: - Timer Management

    private func startTimer() {
        // Check every 5 seconds for due downloads
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForDueDownloads()
            }
        }
        // Make sure timer runs on main run loop
        RunLoop.main.add(timer!, forMode: .common)
        logger.info("Scheduled download timer started")
        // Also check immediately
        checkForDueDownloads()
    }

    private func checkForDueDownloads() {
        guard !scheduledItems.isEmpty else { return }

        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current

        // Debug: Log what we're checking
        for item in scheduledItems {
            let timeUntil = item.scheduledTime.timeIntervalSince(now)
            let scheduledStr = formatter.string(from: item.scheduledTime)
            let nowStr = formatter.string(from: now)
            logger.debug("Checking: scheduled=\(scheduledStr), now=\(nowStr), timeUntil=\(Int(timeUntil))s")
        }

        let dueItems = scheduledItems.filter { $0.scheduledTime <= now }

        for item in dueItems {
            let scheduledStr = formatter.string(from: item.scheduledTime)
            let delay = now.timeIntervalSince(item.scheduledTime)
            logger.info("[TIMING] Starting scheduled download: \(item.itemID) (was scheduled for \(scheduledStr), trigger delay: \(String(format: "%.1f", delay))s)")
            // Remove from scheduled list first
            scheduledItems.removeAll { $0.itemID == item.itemID }
            // Start the download via DownloadManager
            let triggerTime = Date()
            Task {
                await DownloadManager.shared.startScheduledDownload(itemID: item.itemID)
                let elapsed = Date().timeIntervalSince(triggerTime)
                await MainActor.run {
                    self.logger.info("[TIMING] startScheduledDownload completed in \(String(format: "%.2f", elapsed))s")
                }
            }
        }
    }
}
