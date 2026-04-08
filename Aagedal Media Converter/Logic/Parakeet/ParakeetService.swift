// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Service for generating subtitles using parakeet-mlx CLI
actor ParakeetService {
    static let shared = ParakeetService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ParakeetService")
    private let modelManager = ParakeetModelManager.shared

    private var isCancelled = false
    private var currentProcess: Process?

    private init() {}

    /// Generates SRT subtitle file from video/audio using parakeet-mlx
    /// - Parameters:
    ///   - inputFile: The input video or audio file
    ///   - outputDirectory: Directory to save the SRT file
    ///   - model: The Parakeet model to use
    ///   - language: Language code (or "auto" for auto-detect), nil for English-only models
    ///   - audioStreamIndex: Specific audio stream to transcribe (nil = default)
    ///   - progress: Callback for progress updates
    /// - Returns: URL to the generated .srt file
    func generateSubtitles(
        inputFile: URL,
        outputDirectory: URL,
        model: ParakeetModel,
        language: String?,
        audioStreamIndex: Int? = nil,
        progress: @escaping @Sendable (ParakeetProgress) -> Void
    ) async throws -> URL {
        isCancelled = false

        guard let parakeetPath = BinaryPathResolver.parakeetMlxPath else {
            throw ParakeetServiceError.binaryNotFound
        }

        logger.info("Starting Parakeet transcription: \(model.displayName), language: \(language ?? "default")")
        progress(ParakeetProgress(stage: .transcribing, percentage: 0, message: "Starting transcription..."))

        // If a specific audio stream is requested, extract it first
        var actualInputFile = inputFile
        var tempAudioFile: URL?

        if let idx = audioStreamIndex {
            guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
                throw ParakeetServiceError.ffmpegNotFound
            }

            progress(ParakeetProgress(stage: .extractingAudio, percentage: 0, message: "Extracting audio track..."))

            let tempDir = FileManager.default.temporaryDirectory
            let tempWav = tempDir.appendingPathComponent(UUID().uuidString + ".wav")
            tempAudioFile = tempWav

            let extractProcess = Process()
            extractProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
            extractProcess.arguments = [
                "-y", "-nostdin",
                "-i", inputFile.path,
                "-map", "0:\(idx)",
                "-acodec", "pcm_s16le",
                "-ar", "16000",
                "-ac", "1",
                tempWav.path
            ]
            extractProcess.standardOutput = FileHandle.nullDevice
            extractProcess.standardError = FileHandle.nullDevice
            extractProcess.standardInput = FileHandle.nullDevice

            do {
                try extractProcess.run()
                extractProcess.waitUntilExit()
            } catch {
                try? FileManager.default.removeItem(at: tempWav)
                throw ParakeetServiceError.audioExtractionFailed
            }

            guard extractProcess.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: tempWav)
                throw ParakeetServiceError.audioExtractionFailed
            }

            actualInputFile = tempWav
        }

        defer {
            if let tempFile = tempAudioFile {
                try? FileManager.default.removeItem(at: tempFile)
            }
        }

        // Build parakeet-mlx arguments
        var args = [actualInputFile.path]
        args += ["--output-format", "srt"]
        args += ["--output-dir", outputDirectory.path]
        args += ["--model", model.id]

        // Note: parakeet-mlx auto-detects language; no --language flag exists

        let chunkDuration = UserDefaults.standard.integer(forKey: AppConstants.parakeetChunkDurationKey)
        if chunkDuration > 0 && chunkDuration != AppConstants.defaultParakeetChunkDuration {
            args += ["--chunk-duration", "\(chunkDuration)"]
        }

        let overlapDuration = UserDefaults.standard.integer(forKey: AppConstants.parakeetOverlapDurationKey)
        if overlapDuration > 0 && overlapDuration != AppConstants.defaultParakeetOverlapDuration {
            args += ["--overlap-duration", "\(overlapDuration)"]
        }

        logger.info("parakeet-mlx args: \(args.joined(separator: " "))")

        progress(ParakeetProgress(stage: .transcribing, percentage: 0.01, message: "Transcribing..."))

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        // Configure process using the generic Python tool executor
        // Inject bundled ffmpeg into PATH so parakeet-mlx can find it
        var extraPathEntries: [String] = []
        if let ffmpegPath = BinaryPathResolver.ffmpegPath {
            let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
            extraPathEntries.append(ffmpegDir)
        }

        HomebrewPythonExecutor.configurePythonToolProcess(
            process,
            scriptPath: parakeetPath,
            arguments: args,
            extraPathEntries: extraPathEntries
        )

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        currentProcess = process

        // Thread-safe state for progress parsing
        final class ProgressState: @unchecked Sendable {
            var lastReportedProgress: Double = 0.01
        }
        let state = ProgressState()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.logger.debug("parakeet stdout: \(line, privacy: .public)")
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                // Log parakeet output for debugging
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.logger.debug("parakeet stderr: \(line, privacy: .public)")
                }

                // Try to parse progress from stderr
                // parakeet-mlx outputs chunk progress like "Processing chunk 3/10" or percentage patterns
                if let chunkMatch = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
                    let parts = String(line[chunkMatch]).components(separatedBy: "/")
                    if parts.count == 2,
                       let current = Double(parts[0]),
                       let total = Double(parts[1]),
                       total > 0 {
                        let currentProgress = min(current / total, 0.99)
                        if currentProgress - state.lastReportedProgress >= 0.01 {
                            state.lastReportedProgress = currentProgress
                            Task { @MainActor in
                                progress(ParakeetProgress(
                                    stage: .transcribing,
                                    percentage: currentProgress,
                                    message: nil
                                ))
                            }
                        }
                    }
                }

                // Also try percentage patterns like "50%" or "50.0%"
                if let pctMatch = line.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression) {
                    let pctStr = String(line[pctMatch]).replacingOccurrences(of: "%", with: "")
                    if let pct = Double(pctStr) {
                        let currentProgress = min(pct / 100.0, 0.99)
                        if currentProgress - state.lastReportedProgress >= 0.01 {
                            state.lastReportedProgress = currentProgress
                            Task { @MainActor in
                                progress(ParakeetProgress(
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

        logger.info("Launching: \(process.executableURL?.path ?? "nil") \(process.arguments?.joined(separator: " ") ?? "", privacy: .public)")

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ParakeetServiceError.transcriptionFailed(error.localizedDescription)
        }

        let exitCode = process.terminationStatus
        logger.info("parakeet-mlx exited with code \(exitCode)")

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        guard !isCancelled else {
            throw ParakeetServiceError.cancelled
        }

        guard exitCode == 0 else {
            // Read stderr for error details
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let lastLine = errorOutput.components(separatedBy: .newlines)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            logger.error("parakeet-mlx stderr: \(errorOutput, privacy: .public)")
            throw ParakeetServiceError.transcriptionFailed(
                "parakeet-mlx exited with code \(exitCode)" +
                (lastLine.isEmpty ? "" : ": \(lastLine)")
            )
        }

        // parakeet-mlx outputs SRT with the same base name as the input file
        let baseName = actualInputFile.deletingPathExtension().lastPathComponent
        let srtFile = outputDirectory.appendingPathComponent(baseName + ".srt")

        // If we used a temp audio file, the SRT name will be based on the temp UUID.
        // Rename it to match the original input file name.
        if tempAudioFile != nil {
            let originalBaseName = inputFile.deletingPathExtension().lastPathComponent
            let expectedSrt = outputDirectory.appendingPathComponent(originalBaseName + ".srt")

            if srtFile.path != expectedSrt.path && FileManager.default.fileExists(atPath: srtFile.path) {
                try? FileManager.default.removeItem(at: expectedSrt)
                try FileManager.default.moveItem(at: srtFile, to: expectedSrt)

                guard FileManager.default.fileExists(atPath: expectedSrt.path) else {
                    throw ParakeetServiceError.srtGenerationFailed
                }

                progress(ParakeetProgress(stage: .complete, percentage: 1.0, message: nil))
                logger.info("Subtitles generated: \(expectedSrt.lastPathComponent)")
                return expectedSrt
            }
        }

        // Verify SRT file was created
        guard FileManager.default.fileExists(atPath: srtFile.path) else {
            throw ParakeetServiceError.srtGenerationFailed
        }

        progress(ParakeetProgress(stage: .complete, percentage: 1.0, message: nil))
        logger.info("Subtitles generated: \(srtFile.lastPathComponent)")

        return srtFile
    }

    /// Generates SRT subtitle file directly from input file (no encoding)
    /// Saves the SRT alongside the input file
    func generateSubtitlesOnly(
        inputFile: URL,
        model: ParakeetModel,
        language: String?,
        audioStreamIndex: Int? = nil,
        progress: @escaping @Sendable (ParakeetProgress) -> Void
    ) async throws -> URL {
        let outputDirectory = inputFile.deletingLastPathComponent()
        return try await generateSubtitles(
            inputFile: inputFile,
            outputDirectory: outputDirectory,
            model: model,
            language: language,
            audioStreamIndex: audioStreamIndex,
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
        logger.info("Parakeet subtitle generation cancelled")
    }

    /// Gets the installation status of parakeet-mlx
    nonisolated func getInstallationStatus() -> ParakeetInstallationStatus {
        guard BinaryPathResolver.parakeetMlxPath != nil else {
            return .notInstalled
        }
        // Version is fetched asynchronously, so return a generic "installed" for sync checks
        return .installed(version: "parakeet-mlx")
    }
}

// MARK: - Error Types

enum ParakeetServiceError: Error, LocalizedError {
    case binaryNotFound
    case modelNotDownloaded(ParakeetModel)
    case ffmpegNotFound
    case audioExtractionFailed
    case transcriptionFailed(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "parakeet-mlx not found. Install with: pip install -U parakeet-mlx"
        case .modelNotDownloaded(let model):
            return "Model '\(model.displayName)' is not downloaded. It will be downloaded on first use."
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
