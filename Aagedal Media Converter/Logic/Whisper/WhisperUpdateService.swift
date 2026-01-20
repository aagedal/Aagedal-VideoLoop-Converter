// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages whisper availability status
/// Whisper transcription is now handled by FFmpeg's built-in whisper filter
actor WhisperUpdateService {
    static let shared = WhisperUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "WhisperUpdate")

    /// Returns the FFmpeg version (whisper is built into FFmpeg)
    nonisolated var version: String {
        getFFmpegVersion()
    }

    /// Checks if whisper is available (checks if FFmpeg has whisper filter)
    nonisolated func isWhisperAvailable() -> Bool {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            return false
        }

        // Check if FFmpeg has the whisper filter
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
    }

    /// Gets the current installation status
    nonisolated func getInstallationStatus() -> WhisperInstallationStatus {
        if isWhisperAvailable() {
            return .installed(version: "FFmpeg \(getFFmpegVersion()) (built-in)")
        } else {
            return .notInstalled
        }
    }

    /// Gets FFmpeg version string
    private nonisolated func getFFmpegVersion() -> String {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            return "unknown"
        }

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
                // Parse version from first line: "ffmpeg version 8.0.1 ..."
                let lines = output.components(separatedBy: .newlines)
                if let firstLine = lines.first,
                   let versionMatch = firstLine.range(of: #"ffmpeg version (\S+)"#, options: .regularExpression) {
                    let versionStr = String(firstLine[versionMatch])
                        .replacingOccurrences(of: "ffmpeg version ", with: "")
                    return versionStr
                }
            }
        } catch {
            return "unknown"
        }

        return "unknown"
    }
}
