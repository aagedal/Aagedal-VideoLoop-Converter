// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parses yt-dlp output for progress information
struct YTDLPProgressParser: Sendable {
    struct ProgressInfo: Sendable {
        let progress: Double      // 0.0 to 1.0
        let speed: String?        // e.g., "5.2MiB/s"
        let eta: String?          // e.g., "01:23"
        let downloaded: String?   // e.g., "45.2MiB"
        let total: String?        // e.g., "1.23GiB"
    }

    /// Parses a line of yt-dlp output for download progress
    /// Example lines:
    /// [download]  45.2% of 1.23GiB at 5.67MiB/s ETA 01:23
    /// [download] 100% of 1.23GiB in 00:04:32
    /// [download] Destination: Video Title.mp4
    static func parse(_ line: String) -> ProgressInfo? {
        // Match progress percentage
        let progressPattern = #"\[download\]\s+(\d+\.?\d*)%"#
        guard let progressMatch = line.range(of: progressPattern, options: .regularExpression) else {
            return nil
        }

        let progressString = String(line[progressMatch])
        let numberPattern = #"(\d+\.?\d*)"#
        guard let numberMatch = progressString.range(of: numberPattern, options: .regularExpression) else {
            return nil
        }

        let percentString = String(progressString[numberMatch])
        guard let percent = Double(percentString) else {
            return nil
        }

        let progress = percent / 100.0

        // Extract speed (e.g., "5.67MiB/s")
        var speed: String? = nil
        let speedPattern = #"at\s+([\d.]+\s*\w+/s)"#
        if let speedMatch = line.range(of: speedPattern, options: .regularExpression) {
            let speedFull = String(line[speedMatch])
            if let atIndex = speedFull.range(of: "at ") {
                speed = String(speedFull[atIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract ETA (e.g., "01:23")
        var eta: String? = nil
        let etaPattern = #"ETA\s+(\d{1,2}:\d{2}(?::\d{2})?)"#
        if let etaMatch = line.range(of: etaPattern, options: .regularExpression) {
            let etaFull = String(line[etaMatch])
            if let etaIndex = etaFull.range(of: "ETA ") {
                eta = String(etaFull[etaIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract total size (e.g., "1.23GiB")
        var total: String? = nil
        let totalPattern = #"of\s+([\d.]+\s*\w+)"#
        if let totalMatch = line.range(of: totalPattern, options: .regularExpression) {
            let totalFull = String(line[totalMatch])
            if let ofIndex = totalFull.range(of: "of ") {
                total = String(totalFull[ofIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return ProgressInfo(
            progress: progress,
            speed: speed,
            eta: eta,
            downloaded: nil,
            total: total
        )
    }

    /// Parses the final output path from yt-dlp
    /// Example: [Merger] Merging formats into "Video Title.mp4"
    /// Or from --print after_move:filepath output
    static func parseOutputPath(_ line: String) -> String? {
        // Check for merger output
        let mergerPattern = #"\[Merger\] Merging formats into \"(.+)\""#
        if let mergerMatch = line.range(of: mergerPattern, options: .regularExpression) {
            let fullMatch = String(line[mergerMatch])
            if let firstQuote = fullMatch.firstIndex(of: "\""),
               let lastQuote = fullMatch.lastIndex(of: "\""),
               firstQuote < lastQuote {
                let pathStart = fullMatch.index(after: firstQuote)
                return String(fullMatch[pathStart..<lastQuote])
            }
        }

        // Check for download destination
        let destPattern = #"\[download\] Destination: (.+)$"#
        if let destMatch = line.range(of: destPattern, options: .regularExpression) {
            let fullMatch = String(line[destMatch])
            if let colonIndex = fullMatch.range(of: "Destination: ") {
                return String(fullMatch[colonIndex.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Check for ExtractAudio output
        let extractPattern = #"\[ExtractAudio\] Destination: (.+)$"#
        if let extractMatch = line.range(of: extractPattern, options: .regularExpression) {
            let fullMatch = String(line[extractMatch])
            if let colonIndex = fullMatch.range(of: "Destination: ") {
                return String(fullMatch[colonIndex.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Parses video title from yt-dlp metadata output
    static func parseTitle(_ line: String) -> String? {
        // From --print title output or extraction info
        let titlePattern = #"\[.*\] (.+): Downloading"#
        if let titleMatch = line.range(of: titlePattern, options: .regularExpression) {
            let fullMatch = String(line[titleMatch])
            if let colonIndex = fullMatch.range(of: ": Downloading") {
                let afterBracket = fullMatch.firstIndex(of: "]")
                if let start = afterBracket {
                    let titleStart = fullMatch.index(after: start)
                    return String(fullMatch[titleStart..<colonIndex.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    /// Checks if the line indicates an error
    static func parseError(_ line: String) -> String? {
        if line.contains("ERROR:") {
            if let errorIndex = line.range(of: "ERROR:") {
                return String(line[errorIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return nil
    }
}
