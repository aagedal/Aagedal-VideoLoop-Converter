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

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ScheduledDownloadService")
    private var timer: Timer?
    private var powerAssertion: UUID?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    /// Currently scheduled downloads (itemID -> scheduledTime)
    private(set) var scheduledItems: [ScheduledDownloadItem] = []

    private init() {}

    // MARK: - Public API

    /// Registers a VideoItem as scheduled for download
    /// Called by DownloadManager after creating the item in the queue
    func registerScheduledItem(itemID: UUID, scheduledTime: Date) {
        let item = ScheduledDownloadItem(itemID: itemID, scheduledTime: scheduledTime)
        scheduledItems.append(item)
        scheduledItems.sort { $0.scheduledTime < $1.scheduledTime }
        logger.info("Registered scheduled download: \(itemID) for \(scheduledTime)")
        startTimerIfNeeded()
    }

    /// Cancels a scheduled download by item ID
    func cancelScheduledItem(itemID: UUID) {
        scheduledItems.removeAll { $0.itemID == itemID }
        logger.info("Cancelled scheduled download: \(itemID)")
        stopTimerIfIdle()
    }

    /// Gets the count of pending scheduled downloads
    var pendingCount: Int {
        scheduledItems.count
    }

    // MARK: - Timer Management

    private func startTimerIfNeeded() {
        if powerAssertion == nil {
            powerAssertion = PowerAssertion.shared.acquire(reason: "Waiting for scheduled download")
        }
        guard timer == nil else { return }
        // Check every 5 seconds for due downloads.
        // Using the non-scheduling Timer init + explicit RunLoop.add so the timer
        // fires during UI event tracking (menus, drags) via `.common` mode.
        let newTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForDueDownloads()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        logger.info("Scheduled download timer started")
    }

    private func stopTimerIfIdle() {
        guard scheduledItems.isEmpty else { return }
        if let timer {
            timer.invalidate()
            self.timer = nil
            logger.info("Scheduled download timer stopped (no pending items)")
        }
        PowerAssertion.shared.release(powerAssertion)
        powerAssertion = nil
    }

    private func checkForDueDownloads() {
        guard !scheduledItems.isEmpty else {
            stopTimerIfIdle()
            return
        }

        let now = Date()
        let dueItems = scheduledItems.filter { $0.scheduledTime <= now }

        for item in dueItems {
            let scheduledStr = Self.timeFormatter.string(from: item.scheduledTime)
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

        stopTimerIfIdle()
    }
}
