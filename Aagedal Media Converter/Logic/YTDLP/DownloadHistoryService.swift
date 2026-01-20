// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Represents a single download history entry
struct DownloadHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let url: String
    let title: String
    let downloadedAt: Date
    let outputFileName: String?

    init(url: String, title: String, outputFileName: String? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.downloadedAt = Date()
        self.outputFileName = outputFileName
    }
}

/// Service for managing download history persistence
enum DownloadHistoryService {
    /// Gets the download history, most recent first
    static func getHistory() -> [DownloadHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.downloadHistoryKey),
              let entries = try? JSONDecoder().decode([DownloadHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    /// Adds a new entry to the history
    /// - Parameters:
    ///   - url: The downloaded URL
    ///   - title: The video title
    ///   - outputFileName: The output file name (optional)
    static func addEntry(url: String, title: String, outputFileName: String? = nil) {
        var history = getHistory()

        // Remove any existing entry with the same URL (to avoid duplicates)
        history.removeAll { $0.url == url }

        // Add new entry at the beginning
        let entry = DownloadHistoryEntry(url: url, title: title, outputFileName: outputFileName)
        history.insert(entry, at: 0)

        // Keep only the most recent entries
        if history.count > AppConstants.downloadHistoryMaxItems {
            history = Array(history.prefix(AppConstants.downloadHistoryMaxItems))
        }

        // Save
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: AppConstants.downloadHistoryKey)
        }
    }

    /// Removes an entry from the history
    static func removeEntry(id: UUID) {
        var history = getHistory()
        history.removeAll { $0.id == id }

        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: AppConstants.downloadHistoryKey)
        }
    }

    /// Clears all history
    static func clearHistory() {
        UserDefaults.standard.removeObject(forKey: AppConstants.downloadHistoryKey)
    }
}
