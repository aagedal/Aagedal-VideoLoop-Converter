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

enum CameraCardScanner {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "CameraCardScanner")

    /// Recursively scans a folder for video files, sorted by filename (natural sort).
    /// Camera cards typically store clips in nested subfolders with incrementing filenames.
    /// - Parameter folderURL: The root folder to scan (e.g., root of a camera card).
    /// - Returns: Array of video file URLs found, sorted naturally by filename.
    static func scanForVideoFiles(in folderURL: URL) -> [URL] {
        let supportedExtensions = AppConstants.supportedVideoExtensions

        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            logger.warning("Failed to create directory enumerator for \(folderURL.path, privacy: .public)")
            return []
        }

        var videoURLs: [URL] = []

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            guard !ext.isEmpty, supportedExtensions.contains(ext) else { continue }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard resourceValues.isRegularFile == true else { continue }
            } catch {
                continue
            }

            videoURLs.append(fileURL)
        }

        videoURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        logger.info("Found \(videoURLs.count) video file(s) in \(folderURL.lastPathComponent, privacy: .public)")
        return videoURLs
    }
}
