// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Service for generating subtitles using FFmpeg's built-in whisper filter
actor WhisperService {
    static let shared = WhisperService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WhisperService")
    private let modelManager = WhisperModelManager.shared

    private var isCancelled = false
    private var currentProcess: Process?

    private init() {}

    /// Generates SRT subtitle file from video/audio using FFmpeg whisper filter
    /// - Parameters:
    ///   - inputFile: The input video or audio file
    ///   - outputDirectory: Directory to save the SRT file
    ///   - model: The whisper model to use
    ///   - language: Language code (or "auto" for auto-detect)
    ///   - maxLineLength: Maximum characters per subtitle line (currently unused by FFmpeg filter)
    ///   - progress: Callback for progress updates
    /// - Returns: URL to the generated .srt file
    func generateSubtitles(
        inputFile: URL,
        outputDirectory: URL,
        model: WhisperModel,
        language: String,
        audioStreamIndex: Int? = nil,
        maxLineLength: Int? = nil,
        progress: @escaping @Sendable (WhisperProgress) -> Void
    ) async throws -> URL {
        isCancelled = false

        // Verify model is downloaded
        let modelPath = modelManager.modelPath(for: model)
        guard modelManager.isModelDownloaded(model) else {
            throw WhisperServiceError.modelNotDownloaded(model)
        }

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw WhisperServiceError.ffmpegNotFound
        }

        var shouldStopAccess = false
        if model.isCustom {
            shouldStopAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: modelPath)
        }
        defer {
            if shouldStopAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: modelPath)
            }
        }

        // Prepare output file path
        let baseName = inputFile.deletingPathExtension().lastPathComponent
        let srtFile = SubtitleSRTNaming.outputURL(directory: outputDirectory, baseName: baseName, method: .whisper)

        // Build whisper filter string
        // whisper=model=/path/to/model.bin:language=auto:format=srt:destination=/path/to/output.srt
        // Note: Paths must be escaped for FFmpeg filter syntax (colons -> \:, backslashes -> \\)
        let escapedModelPath = escapeFFmpegFilterPath(modelPath.path)
        let escapedDestPath = escapeFFmpegFilterPath(srtFile.path)

        let filterComponents = [
            "model=\(escapedModelPath)",
            "language=\(language)",
            "format=srt",
            "destination=\(escapedDestPath)",
            "use_gpu=true"
        ]

        let whisperFilter = "whisper=" + filterComponents.joined(separator: ":")

        logger.info("Starting FFmpeg whisper transcription: \(model.displayName), language: \(language)")
        logger.info("Filter: \(whisperFilter)")

        progress(WhisperProgress(stage: .transcribing, percentage: 0, message: "Starting transcription..."))

        let process = Process()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        var args = ["-i", inputFile.path]
        if let idx = audioStreamIndex {
            args += ["-map", "0:\(idx)"]
        }
        args += ["-af", whisperFilter, "-f", "null", "-"]
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        currentProcess = process

        // Thread-safe state for progress parsing
        final class ProgressState: @unchecked Sendable {
            var durationSeconds: Double = 0
            var lastReportedProgress: Double = 0
        }
        let state = ProgressState()

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                // Debug output
                if line.contains("whisper") || line.contains("Whisper") {
                    self.logger.debug("\(line, privacy: .public)")
                }

                // Parse duration from ffmpeg output
                if let durationMatch = line.range(of: #"Duration:\s*(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) {
                    let durationStr = String(line[durationMatch])
                    if let timeMatch = durationStr.range(of: #"(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) {
                        let components = String(durationStr[timeMatch]).components(separatedBy: ":")
                        if components.count == 3,
                           let hours = Double(components[0]),
                           let mins = Double(components[1]),
                           let secs = Double(components[2]) {
                            state.durationSeconds = hours * 3600 + mins * 60 + secs
                        }
                    }
                }

                // Parse current time from ffmpeg output for progress
                if state.durationSeconds > 0,
                   let timeMatch = line.range(of: #"time=(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) {
                    let timeStr = String(line[timeMatch])
                    if let match = timeStr.range(of: #"(\d{2}):(\d{2}):(\d{2}\.\d+)"#, options: .regularExpression) {
                        let components = String(timeStr[match]).components(separatedBy: ":")
                        if components.count == 3,
                           let hours = Double(components[0]),
                           let mins = Double(components[1]),
                           let secs = Double(components[2]) {
                            let currentSeconds = hours * 3600 + mins * 60 + secs
                            let currentProgress = min(currentSeconds / state.durationSeconds, 0.99)

                            // Only report significant progress changes
                            if currentProgress - state.lastReportedProgress >= 0.01 {
                                state.lastReportedProgress = currentProgress
                                Task { @MainActor in
                                    progress(WhisperProgress(
                                        stage: .transcribing,
                                        percentage: currentProgress,
                                        message: nil
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw WhisperServiceError.transcriptionFailed(error.localizedDescription)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        guard !isCancelled else {
            // Clean up partial SRT file if cancelled
            try? FileManager.default.removeItem(at: srtFile)
            throw WhisperServiceError.cancelled
        }

        guard process.terminationStatus == 0 else {
            throw WhisperServiceError.transcriptionFailed("FFmpeg exited with code \(process.terminationStatus)")
        }

        // Verify SRT file was created
        guard FileManager.default.fileExists(atPath: srtFile.path) else {
            throw WhisperServiceError.srtGenerationFailed
        }

        // Count segments for logging
        let segmentCount = countSRTSegments(at: srtFile)

        progress(WhisperProgress(stage: .complete, percentage: 1.0, message: nil))
        logger.info("Subtitles generated: \(srtFile.lastPathComponent) with \(segmentCount) segments")

        return srtFile
    }

    /// Generates SRT subtitle file directly from input file (no encoding)
    /// Saves the SRT alongside the input file
    func generateSubtitlesOnly(
        inputFile: URL,
        model: WhisperModel,
        language: String,
        audioStreamIndex: Int? = nil,
        maxLineLength: Int? = nil,
        progress: @escaping @Sendable (WhisperProgress) -> Void
    ) async throws -> URL {
        let outputDirectory = inputFile.deletingLastPathComponent()
        return try await generateSubtitles(
            inputFile: inputFile,
            outputDirectory: outputDirectory,
            model: model,
            language: language,
            audioStreamIndex: audioStreamIndex,
            maxLineLength: maxLineLength,
            progress: progress
        )
    }

    /// Cancels the current subtitle generation
    func cancelGeneration() {
        isCancelled = true
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
        }
        logger.info("Subtitle generation cancelled")
    }

    // MARK: - Private Methods

    /// Count the number of segments in an SRT file
    private func countSRTSegments(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        // Count lines that are just numbers (segment indices)
        let lines = content.components(separatedBy: .newlines)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, Int(trimmed) != nil {
                count += 1
            }
        }
        return count
    }

    /// Escapes a file path for use in FFmpeg filter syntax
    /// FFmpeg filter options use : as separator, so paths must escape special characters
    private nonisolated func escapeFFmpegFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")  // Escape backslashes first
            .replacingOccurrences(of: ":", with: "\\:")    // Escape colons
            .replacingOccurrences(of: "'", with: "\\'")    // Escape single quotes
    }
}

// MARK: - Error Types

enum WhisperServiceError: Error, LocalizedError {
    case binaryNotFound
    case modelNotDownloaded(WhisperModel)
    case ffmpegNotFound
    case audioExtractionFailed
    case transcriptionFailed(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "FFmpeg with whisper support not found"
        case .modelNotDownloaded(let model):
            return "Model '\(model.displayName)' is not downloaded. Please download it in Settings."
        case .ffmpegNotFound:
            return "FFmpeg not found"
        case .audioExtractionFailed:
            return "Failed to extract audio from video"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .srtGenerationFailed:
            return "Failed to generate SRT file"
        case .cancelled:
            return "Subtitle generation was cancelled"
        }
    }
}
