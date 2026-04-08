// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Periodically deletes files older than N days from the default output folder.
/// Runs on app launch and every hour while the app is running.
@MainActor
final class OutputFolderCleanupService {
    static let shared = OutputFolderCleanupService()

    private let logger = Logger(subsystem: "me.aagedal.MediaConverter", category: "OutputFolderCleanup")
    private var timer: Timer?

    private init() {}

    /// Start the service: run cleanup immediately and schedule hourly repeats.
    func start() {
        performCleanupIfNeeded()
        scheduleHourlyTimer()
    }

    private func scheduleHourlyTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.performCleanupIfNeeded()
            }
        }
    }

    func performCleanupIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: AppConstants.autoDeleteOldEncodesKey) else { return }

        let days = defaults.integer(forKey: AppConstants.autoDeleteOldEncodesDaysKey)
        guard days > 0 else { return }

        let outputFolder = defaults.string(forKey: "outputFolder") ?? AppConstants.defaultOutputDirectory.path
        let folderURL = URL(fileURLWithPath: outputFolder)

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            logger.info("Could not enumerate output folder at \(outputFolder)")
            return
        }

        var deletedCount = 0
        for fileURL in contents {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let creationDate = resourceValues.creationDate,
                  creationDate < cutoffDate else { continue }

            do {
                try fm.removeItem(at: fileURL)
                deletedCount += 1
                logger.debug("Deleted old encode: \(fileURL.lastPathComponent)")
            } catch {
                logger.warning("Failed to delete \(fileURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if deletedCount > 0 {
            logger.info("Auto-deleted \(deletedCount) file(s) older than \(days) day(s) from output folder")
        }
    }
}
