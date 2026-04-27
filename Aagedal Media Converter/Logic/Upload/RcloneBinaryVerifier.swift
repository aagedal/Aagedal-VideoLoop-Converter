// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Identity check for rclone binaries used by the custom-path resolver.
///
/// Used by `RcloneUpdateService.validateCustomRclonePath` to confirm that a path the user
/// pointed at is actually rclone before we hand arguments and credentials to it.
enum RcloneBinaryVerifier {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneVerifier")

    /// Runs the binary with `--version` and returns its first line, or nil if it does not look like rclone.
    /// Used to validate user-provided custom paths point at an actual rclone binary.
    static func versionString(of binaryPath: String) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bound execution to a short timeout — we're just running a CPU-only `--version`.
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = output.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Real rclone always emits "rclone v<semver>" as the first line.
        guard firstLine.hasPrefix("rclone v") else { return nil }
        return firstLine
    }
}

// MARK: - Shared GitHub request constants

/// Centralizes the User-Agent we send to GitHub. GitHub's API requires one and rate-limits anonymous requests,
/// and a stable UA also makes it easier to identify our traffic in support investigations.
enum GitHubRequest {
    static let userAgent: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aagedal.MediaConverter"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "\(bundleID)/\(version)"
    }()
}
