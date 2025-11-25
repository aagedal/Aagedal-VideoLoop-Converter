// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import AVFoundation
import OSLog

/// Manages creation and lifecycle of a temporary low-resolution MP4 preview clip.
actor MP4PreviewSession {
    struct PreviewResult: Sendable {
        let url: URL
        let audioURLs: [URL]
        let startTime: TimeInterval
        let duration: TimeInterval
    }
    enum PreviewError: Error, LocalizedError {
        case ffmpegNotFound
        case failedToStart(String)
        case cancelled
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "FFmpeg binary not found in application bundle."
            case .failedToStart(let message):
                return "Failed to start FFmpeg preview: \(message)."
            case .cancelled:
                return "Preview generation was cancelled."
            case .outputMissing:
                return "Preview output file was not created."
            }
        }
    }

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
    private let sourceURL: URL
    private let cacheDirectory: URL
    private let outputURL: URL
    private let audioStreamIndices: [Int]
    private let hasVideoStream: Bool

    private var process: Process?
    private var isCancelled = false

    init(sourceURL: URL, cacheDirectory: URL, audioStreamIndices: [Int], hasVideoStream: Bool = true) {
        self.sourceURL = sourceURL
        self.cacheDirectory = cacheDirectory
        self.outputURL = cacheDirectory.appendingPathComponent("preview.mp4")
        self.hasVideoStream = hasVideoStream
        var seen = Set<Int>()
        self.audioStreamIndices = audioStreamIndices.filter { value in
            let inserted = seen.insert(value).inserted
            return inserted
        }

        // Ensure chunk/section subdirectories exist for cleaner cache cleanup
        let fileManager = FileManager.default
        let chunksDir = cacheDirectory.appendingPathComponent("chunks", isDirectory: true)
        let sectionsDir = cacheDirectory.appendingPathComponent("sections", isDirectory: true)
        if !fileManager.fileExists(atPath: chunksDir.path) {
            try? fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: sectionsDir.path) {
            try? fileManager.createDirectory(at: sectionsDir, withIntermediateDirectories: true)
        }
    }

    /// Generates a low-resolution MP4 preview clip.
    func generatePreview(startTime: TimeInterval, durationLimit: TimeInterval = 30, maxShortEdge: Int = 720) async throws -> PreviewResult {
        // ... (implementation for single file preview remains mostly same but updated for PreviewResult)
        // For full preview, we might still use single file or separate. 
        // But generatePreview is mostly for single-file export/preview, not the chunk system.
        // Let's keep it simple for now and assume it uses the muxed output.
        
        logger.info("Transcoding MP4 preview for \(self.sourceURL.lastPathComponent, privacy: .public)")

        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }

        if FileManager.default.fileExists(atPath: self.outputURL.path) {
            try FileManager.default.removeItem(at: self.outputURL)
        }

        self.isCancelled = false

        let safeStart = max(0, startTime)

        // For full preview, we use the original muxed approach
        let arguments = self.buildArguments(
            startTime: startTime,
            durationLimit: durationLimit,
            maxShortEdge: maxShortEdge,
            outputPath: self.outputURL.path,
            separateAudio: false
        )

        try Task.checkCancellation()

        let previewURL = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: self.outputURL)

        let asset = AVURLAsset(url: previewURL)
        let loadedDuration = try await asset.load(.duration)
        let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit

        return PreviewResult(
            url: previewURL,
            audioURLs: [],
            startTime: safeStart,
            duration: max(0, durationSeconds)
        )
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
    }

    func previewFileURL() -> URL {
        outputURL
    }

    func cleanup() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: outputURL)
        // Note: Audio/video chunk files persist for reuse across sessions. Call cleanupAllChunks() explicitly when removing video from queue or use app-wide cache cleanup.
    }
    
    // ... (cleanupAllChunks updated to clean audio files)
    func cleanupAllChunks() {
        let fileManager = FileManager.default
        do {
            let chunksDir = cacheDirectory.appendingPathComponent("chunks", isDirectory: true)
            if fileManager.fileExists(atPath: chunksDir.path) {
                try fileManager.removeItem(at: chunksDir)
            }
            try fileManager.createDirectory(at: chunksDir, withIntermediateDirectories: true)

            let previewFile = outputURL
            if fileManager.fileExists(atPath: previewFile.path) {
                try? fileManager.removeItem(at: previewFile)
            }
            logger.info("Cleaned up all preview files for \(self.sourceURL.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up preview files: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Generates a preview chunk for a specific time range (duration varies by caller)
    func generatePreviewChunk(chunkIndex: Int, startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int = 720, skipAudio: Bool = false) async throws -> PreviewResult {
        let chunkURL = chunkURL(for: chunkIndex)
        let audioURLs = skipAudio ? [] : audioChunkURLs(for: chunkIndex)
        
        // Check if video chunk exists
        let videoExists = FileManager.default.fileExists(atPath: chunkURL.path)
        // Check if all expected audio chunks exist (if not skipping)
        let allAudioExist = skipAudio || (!audioURLs.isEmpty && audioURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        
        // Skip if already exists
        if videoExists && (audioStreamIndices.isEmpty || allAudioExist) {
            logger.info("Using cached chunk \(chunkIndex, privacy: .public) from: \(chunkURL.path, privacy: .public)")
            let asset = AVURLAsset(url: chunkURL)
            let loadedDuration = try await asset.load(.duration)
            let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit
            return PreviewResult(
                url: chunkURL,
                audioURLs: audioURLs,
                startTime: startTime,
                duration: max(0, durationSeconds)
            )
        }
        
        logger.info("Generating preview chunk \(chunkIndex, privacy: .public) (\(durationLimit, privacy: .public)s starting at \(startTime, privacy: .public)s) for \(self.sourceURL.lastPathComponent, privacy: .public)")
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        let arguments = self.buildArguments(
            startTime: startTime,
            durationLimit: durationLimit,
            maxShortEdge: maxShortEdge,
            outputPath: chunkURL.path,
            separateAudio: !skipAudio,
            audioOutputPaths: audioURLs.map { $0.path }
        )
        
        try Task.checkCancellation()
        
        // We pass the video URL as the primary output to check, but FFmpeg will generate all
        let previewURL = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: chunkURL)
        
        let asset = AVURLAsset(url: previewURL)
        let loadedDuration = try await asset.load(.duration)
        let durationSeconds = loadedDuration.seconds.isFinite ? loadedDuration.seconds : durationLimit
        
        return PreviewResult(
            url: previewURL,
            audioURLs: audioURLs,
            startTime: startTime,
            duration: max(0, durationSeconds)
        )
    }
    
    /// Extracts full audio tracks to separate files
    func extractFullAudioTracks() async throws -> [URL] {
        let audioURLs = fullAudioTrackURLs()
        
        // Check if all exist and are valid (> 1KB)
        let allValid = audioURLs.allSatisfy { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = attr[.size] as? UInt64 ?? 0
                return size > 1024 // Minimum 1KB to be considered valid
            } catch {
                return false
            }
        }
        
        if !audioURLs.isEmpty && allValid {
            logger.info("Using cached full audio tracks")
            return audioURLs
        }
        
        logger.info("Extracting full audio tracks for \(self.sourceURL.lastPathComponent, privacy: .public)")
        
        // Cleanup any partial/invalid files
        for url in audioURLs {
            try? FileManager.default.removeItem(at: url)
        }
        
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw PreviewError.ffmpegNotFound
        }
        
        // We need to run one ffmpeg command to extract all audio tracks
        var arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-i", sourceURL.path
        ]
        
        let targetAudioIndices = audioStreamIndices.isEmpty ? [0] : audioStreamIndices
        
        for (outputIndex, streamIndex) in targetAudioIndices.enumerated() {
            guard outputIndex < audioURLs.count else { continue }
            // Explicitly disable video/subtitles for audio outputs and force MP4 container
            arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)?"])
            arguments.append(contentsOf: ["-c:a", "aac"])
            arguments.append(contentsOf: ["-b:a", "128k"])
            arguments.append(contentsOf: ["-ac", "2"])
            arguments.append(contentsOf: ["-vn", "-sn"])
            arguments.append(contentsOf: ["-f", "mp4"])
            arguments.append(contentsOf: ["-movflags", "+faststart"])
            arguments.append(audioURLs[outputIndex].path)
        }
        
        logger.info("Running ffmpeg for audio extraction with arguments: \(arguments.joined(separator: " "))")
        
        try Task.checkCancellation()
        
        // We use the first audio file as the "outputURL" for runFFmpeg check
        guard let firstAudioURL = audioURLs.first else { return [] }
        
        _ = try await self.runFFmpeg(executablePath: ffmpegPath, arguments: arguments, outputURL: firstAudioURL)
        
        // Verify all outputs were created and are valid
        for url in audioURLs {
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger.error("Expected audio output missing: \(url.path)")
                throw PreviewError.outputMissing
            }
            let attr = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attr?[.size] as? UInt64 ?? 0
            if size < 100 {
                logger.error("Generated audio file is too small (\(size) bytes): \(url.path)")
                throw PreviewError.failedToStart("Generated audio file is empty or too small")
            }
        }
        
        return audioURLs
    }
    
    /// Returns URL for a specific preview chunk video
    nonisolated func chunkURL(for index: Int) -> URL {
        cacheDirectory.appendingPathComponent("chunks/preview_chunk_\(index).mp4")
    }
    
    /// Returns URLs for audio chunks corresponding to the video chunk
    nonisolated func audioChunkURLs(for index: Int) -> [URL] {
        let targetAudioIndices = audioStreamIndices.isEmpty ? [0] : audioStreamIndices
        return targetAudioIndices.enumerated().map { (outputIndex, _) in
            cacheDirectory.appendingPathComponent("chunks/preview_chunk_\(index)_audio_\(outputIndex).m4a")
        }
    }
    
    /// Returns URLs for full audio tracks
    nonisolated func fullAudioTrackURLs() -> [URL] {
        let targetAudioIndices = audioStreamIndices.isEmpty ? [0] : audioStreamIndices
        return targetAudioIndices.enumerated().map { (outputIndex, _) in
            cacheDirectory.appendingPathComponent("full_audio_\(outputIndex).m4a")
        }
    }
    
    // MARK: - Helpers

    private func buildArguments(startTime: TimeInterval, durationLimit: TimeInterval, maxShortEdge: Int, outputPath: String, separateAudio: Bool, audioOutputPaths: [String] = []) -> [String] {
        let safeStart = max(0, startTime)
        let limitedDuration = max(1, durationLimit)

        var arguments: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-ss", String(format: "%.3f", safeStart),
            "-i", sourceURL.path,
            "-t", String(format: "%.3f", limitedDuration),
            "-analyzeduration", "5M",
            "-probesize", "10M"
        ]

        if hasVideoStream {
            let scaleFilter = "scale='if(gt(a,1),-2,\(maxShortEdge))':'if(gt(a,1),\(maxShortEdge),-2)'"
            arguments.append(contentsOf: [
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-c:v", "h264_videotoolbox",
                "-b:v", "3M",
                "-maxrate", "3M",
                "-bufsize", "6M",
                "-pix_fmt", "yuv420p"
            ])
            // Video output file
            arguments.append(outputPath)
        }

        let targetAudioIndices = audioStreamIndices.isEmpty ? [0] : audioStreamIndices
        
        if separateAudio {
            // Separate audio files
            for (outputIndex, streamIndex) in targetAudioIndices.enumerated() {
                guard outputIndex < audioOutputPaths.count else { continue }
                arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)?"])
                arguments.append(contentsOf: ["-c:a", "aac"]) // No stream specifier needed for single stream output
                arguments.append(contentsOf: ["-b:a", "128k"])
                arguments.append(contentsOf: ["-ac", "2"])
                arguments.append(audioOutputPaths[outputIndex])
            }
        } else {
            // Muxed audio (legacy/full preview)
            for (outputIndex, streamIndex) in targetAudioIndices.enumerated() {
                arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)?"])
                arguments.append(contentsOf: ["-c:a:\(outputIndex)", "aac"])
                arguments.append(contentsOf: ["-b:a:\(outputIndex)", "128k"])
                arguments.append(contentsOf: ["-ac:a:\(outputIndex)", "2"])
            }
            // If video stream is missing, outputPath wasn't appended above
            if !hasVideoStream {
                arguments.append(outputPath)
            }
        }

        return arguments
    }

    private func runFFmpeg(executablePath: String, arguments: [String], outputURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
                self.process = process
            } catch {
                continuation.resume(throwing: PreviewError.failedToStart(error.localizedDescription))
                return
            }

            Task.detached(priority: .userInitiated) { [weak self] in
                process.waitUntilExit()

                guard let self else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: PreviewError.failedToStart(message))
                    return
                }

                let cancelled = await self.isCancelled

                if cancelled {
                    continuation.resume(throwing: PreviewError.cancelled)
                    return
                }

                if process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) {
                    continuation.resume(returning: outputURL)
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: PreviewError.failedToStart(message))
                }
            }
        }
    }
}
