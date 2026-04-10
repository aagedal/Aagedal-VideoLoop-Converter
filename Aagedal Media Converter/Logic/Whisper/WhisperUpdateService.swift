// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages whisper availability status
/// Whisper transcription is now handled by FFmpeg's built-in whisper filter
actor WhisperUpdateService {
    static let shared = WhisperUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WhisperUpdate")

    /// Cached availability — checked once at init, avoids subprocess on every UI access.
    private static let _cachedIsAvailable: Bool = {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else { return false }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-filters"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("whisper")
            }
        } catch {
            return false
        }
        return false
    }()

    private static let _cachedVersion: String = {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else { return "unknown" }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                if let firstLine = lines.first,
                   let versionMatch = firstLine.range(of: #"ffmpeg version (\S+)"#, options: .regularExpression) {
                    return String(firstLine[versionMatch]).replacingOccurrences(of: "ffmpeg version ", with: "")
                }
            }
        } catch {
            return "unknown"
        }
        return "unknown"
    }()

    /// Returns the FFmpeg version (whisper is built into FFmpeg)
    nonisolated var version: String {
        Self._cachedVersion
    }

    /// Checks if whisper is available (uses cached result)
    nonisolated func isWhisperAvailable() -> Bool {
        Self._cachedIsAvailable
    }

    /// Gets the current installation status (uses cached result)
    nonisolated func getInstallationStatus() -> WhisperInstallationStatus {
        if Self._cachedIsAvailable {
            return .installed(version: "FFmpeg \(Self._cachedVersion) (built-in)")
        } else {
            return .notInstalled
        }
    }

}
