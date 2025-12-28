// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parses rclone progress output
enum RcloneProgressParser {

    /// Parses rclone --stats-one-line output
    /// Examples:
    /// - With Transferred prefix: "Transferred:   1.234 GiB / 5.678 GiB, 22%, 10.5 MiB/s, ETA 7m30s"
    /// - Without prefix: "43.996 MiB / 1.674 GiB, 3%, 0 B/s, ETA -"
    /// - INFO format: "2025/12/27 16:42:38 INFO  :     1.674 GiB / 1.674 GiB, 100%, 12.081 MiB/s, ETA 0s"
    static func parse(_ line: String) -> UploadProgress? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if this is a progress line - must contain "%" and "/" pattern
        guard trimmed.contains("%") && trimmed.contains("/") else {
            return nil
        }

        // Remove "Transferred:" prefix if present
        if trimmed.hasPrefix("Transferred:") {
            trimmed = trimmed.replacingOccurrences(of: "Transferred:", with: "").trimmingCharacters(in: .whitespaces)
        }

        // Remove INFO prefix if present (e.g., "2025/12/27 16:42:38 INFO  :")
        if let infoRange = trimmed.range(of: #"\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+INFO\s*:\s*"#, options: .regularExpression) {
            trimmed = String(trimmed[infoRange.upperBound...]).trimmingCharacters(in: .whitespaces)
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

        if let transferMatch = trimmed.range(of: #"([\d.]+)\s*(B|KiB|MiB|GiB|TiB)\s*/\s*([\d.]+)\s*(B|KiB|MiB|GiB|TiB)"#, options: .regularExpression) {
            let substring = String(trimmed[transferMatch])
            let components = substring.components(separatedBy: "/")

            if components.count == 2 {
                bytesTransferred = parseByteSize(components[0].trimmingCharacters(in: .whitespaces))
                totalBytes = parseByteSize(components[1].trimmingCharacters(in: .whitespaces))
            }
        }

        // Extract speed
        var speed: String?
        if let speedMatch = trimmed.range(of: #"(\d+\.?\d*)\s*(B|KiB|MiB|GiB)/s"#, options: .regularExpression) {
            speed = String(trimmed[speedMatch])
        }

        // Extract ETA
        var eta: String?
        if let etaMatch = trimmed.range(of: #"ETA\s+[\w\d:\-]+"#, options: .regularExpression) {
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
        let lowercased = trimmed.lowercased()

        // Check for common error patterns
        if trimmed.contains("ERROR") || trimmed.contains("Failed") {
            // Extract the error message
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let afterColon = trimmed[trimmed.index(after: colonIndex)...]
                return afterColon.trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }

        // FTP-specific authentication errors
        if trimmed.contains("530") || lowercased.contains("login incorrect") ||
           lowercased.contains("authentication failed") {
            return "Authentication failed"
        }

        // S3-specific errors
        if trimmed.contains("AccessDenied") {
            return "S3 Access Denied - check bucket permissions and credentials"
        }
        if trimmed.contains("InvalidAccessKeyId") {
            return "Invalid AWS Access Key ID"
        }
        if trimmed.contains("SignatureDoesNotMatch") {
            return "Invalid AWS Secret Access Key"
        }
        if trimmed.contains("NoSuchBucket") {
            return "S3 bucket does not exist"
        }
        if trimmed.contains("BucketAlreadyOwnedByYou") || trimmed.contains("BucketAlreadyExists") {
            // Not an error, just informational
            return nil
        }
        if lowercased.contains("the bucket you are attempting to access") {
            return "S3 bucket region mismatch"
        }

        // SMB-specific errors
        if trimmed.contains("NT_STATUS_LOGON_FAILURE") || trimmed.contains("LOGON_FAILURE") {
            return "SMB login failed - check username and password"
        }
        if trimmed.contains("NT_STATUS_BAD_NETWORK_NAME") || trimmed.contains("BAD_NETWORK_NAME") {
            return "SMB share not found - check share name"
        }
        if trimmed.contains("NT_STATUS_ACCESS_DENIED") {
            return "SMB access denied - check permissions"
        }
        if trimmed.contains("NT_STATUS_OBJECT_NAME_NOT_FOUND") {
            return "SMB path not found"
        }
        if trimmed.contains("NT_STATUS_") {
            // Generic SMB error
            if let statusMatch = trimmed.range(of: #"NT_STATUS_\w+"#, options: .regularExpression) {
                return "SMB error: \(trimmed[statusMatch])"
            }
        }

        // SFTP-specific errors
        if lowercased.contains("ssh:") && lowercased.contains("handshake failed") {
            return "SSH handshake failed - server may use unsupported key exchange"
        }
        if lowercased.contains("permission denied (publickey") {
            return "SSH key authentication failed"
        }
        if lowercased.contains("permission denied (password") {
            return "SSH password authentication failed"
        }
        if lowercased.contains("no such identity") || lowercased.contains("no such file") && lowercased.contains("key") {
            return "SSH key file not found"
        }
        if lowercased.contains("host key verification failed") {
            return "SSH host key verification failed"
        }

        // Connection errors (all backends)
        if lowercased.contains("connection refused") || lowercased.contains("no such host") ||
           lowercased.contains("timeout") || lowercased.contains("unreachable") ||
           lowercased.contains("network is unreachable") || lowercased.contains("no route to host") {
            return "Connection failed: \(trimmed)"
        }

        return nil
    }

    /// Checks if rclone completed successfully
    static func isSuccess(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        // rclone outputs "X / X, 100%" when complete (with or without "Transferred:" prefix)
        return trimmed.contains("100%") && trimmed.contains("/")
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
