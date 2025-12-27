// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parses rclone progress output
enum RcloneProgressParser {

    /// Parses rclone --stats-one-line output
    /// Example: "Transferred:   1.234 GiB / 5.678 GiB, 22%, 10.5 MiB/s, ETA 7m30s"
    static func parse(_ line: String) -> UploadProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if this is a transfer progress line
        guard trimmed.hasPrefix("Transferred:") else {
            return nil
        }

        // Extract percentage
        var percentage: Double = 0
        if let percentMatch = trimmed.range(of: #"(\d+)%"#, options: .regularExpression) {
            let percentStr = trimmed[percentMatch].dropLast() // Remove '%'
            percentage = Double(percentStr) ?? 0
        }

        // Extract bytes transferred and total
        // Pattern: "1.234 GiB / 5.678 GiB" or "123.4 MiB / 456.7 MiB"
        var bytesTransferred: Int64 = 0
        var totalBytes: Int64 = 0

        if let transferMatch = trimmed.range(of: #"Transferred:\s+([\d.]+)\s*(\w+)\s*/\s*([\d.]+)\s*(\w+)"#, options: .regularExpression) {
            let substring = String(trimmed[transferMatch])
            let components = substring
                .replacingOccurrences(of: "Transferred:", with: "")
                .components(separatedBy: "/")

            if components.count == 2 {
                bytesTransferred = parseByteSize(components[0].trimmingCharacters(in: .whitespaces))
                totalBytes = parseByteSize(components[1].trimmingCharacters(in: .whitespaces).components(separatedBy: ",").first ?? "")
            }
        }

        // Extract speed
        var speed: String?
        if let speedMatch = trimmed.range(of: #"(\d+\.?\d*)\s*(B|KiB|MiB|GiB)/s"#, options: .regularExpression) {
            speed = String(trimmed[speedMatch])
        }

        // Extract ETA
        var eta: String?
        if let etaMatch = trimmed.range(of: #"ETA\s+[\w\d:]+"#, options: .regularExpression) {
            eta = String(trimmed[etaMatch]).replacingOccurrences(of: "ETA ", with: "")
        }

        return UploadProgress(
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes,
            percentage: percentage / 100.0,
            speed: speed,
            eta: eta
        )
    }

    /// Parses rclone error messages
    static func parseError(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for common error patterns
        if trimmed.contains("ERROR") || trimmed.contains("Failed") {
            // Extract the error message
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let afterColon = trimmed[trimmed.index(after: colonIndex)...]
                return afterColon.trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }

        // Check for authentication errors
        if trimmed.contains("530") || trimmed.contains("Login incorrect") ||
           trimmed.contains("authentication failed") {
            return "Authentication failed"
        }

        // Check for connection errors
        if trimmed.contains("connection refused") || trimmed.contains("no such host") ||
           trimmed.contains("timeout") || trimmed.contains("unreachable") {
            return "Connection failed: \(trimmed)"
        }

        return nil
    }

    /// Checks if rclone completed successfully
    static func isSuccess(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // rclone outputs "Transferred: X / X, 100%" when complete
        return trimmed.contains("100%") && trimmed.contains("Transferred:")
    }

    // MARK: - Private Helpers

    /// Converts a size string like "1.5 GiB" to bytes
    private static func parseByteSize(_ sizeStr: String) -> Int64 {
        let components = sizeStr.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
        guard components.count >= 1 else { return 0 }

        let numberStr = components[0]
        guard let number = Double(numberStr) else { return 0 }

        let unit = components.count > 1 ? components[1].lowercased() : "b"

        let multiplier: Double
        switch unit {
        case "b", "bytes":
            multiplier = 1
        case "kib", "kb":
            multiplier = 1024
        case "mib", "mb":
            multiplier = 1024 * 1024
        case "gib", "gb":
            multiplier = 1024 * 1024 * 1024
        case "tib", "tb":
            multiplier = 1024 * 1024 * 1024 * 1024
        default:
            multiplier = 1
        }

        return Int64(number * multiplier)
    }
}
