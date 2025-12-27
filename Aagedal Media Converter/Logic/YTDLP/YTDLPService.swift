// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Metadata fetched from yt-dlp for a video URL
struct YTDLPMetadata: Sendable {
    let title: String
    let duration: Double?
    let thumbnailURL: URL?
    let uploader: String?
    let description: String?
}

/// Result of a successful download
struct YTDLPDownloadResult: Sendable {
    let outputURL: URL
    let title: String
}

/// Service for executing yt-dlp downloads
actor YTDLPService {
    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "YTDLPService")
    private var currentProcess: Process?
    private let updateService = YTDLPUpdateService.shared

    /// Path to ffmpeg for post-processing
    private var ffmpegPath: String? {
        BinaryPathResolver.ffmpegPath
    }

    /// Fetches video metadata without downloading
    func fetchMetadata(url: String) async throws -> YTDLPMetadata {
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }

        // Run process handling on a background thread to avoid blocking async context
        let result: (data: Data, error: String?, exitCode: Int32) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                // Configure process for Homebrew Python or regular executable
                // Note: --ignore-config prevents yt-dlp from reading user config files
                // Note: --remote-components ejs:github is required for YouTube JS challenge solving
                HomebrewPythonExecutor.configureProcess(
                    process,
                    scriptPath: ytdlpPath,
                    arguments: ["--ignore-config", "--remote-components", "ejs:github", "-j", "--no-download", "--no-warnings", url]
                )
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                process.standardInput = FileHandle.nullDevice

                // Read pipes in background to prevent buffer blocking
                // Use a thread-safe container for captured data
                final class DataContainer: @unchecked Sendable {
                    var stdout = Data()
                    var stderr = Data()
                    let lock = NSLock()
                }
                let container = DataContainer()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    container.lock.lock()
                    container.stdout = data
                    container.lock.unlock()
                    group.leave()
                }

                group.enter()
                DispatchQueue.global().async {
                    let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    container.lock.lock()
                    container.stderr = data
                    container.lock.unlock()
                    group.leave()
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    group.wait()

                    let errorStr = String(data: container.stderr, encoding: .utf8)
                    continuation.resume(returning: (container.stdout, errorStr, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        logger.info("yt-dlp process exited with status: \(result.exitCode)")

        guard result.exitCode == 0 else {
            let errorMessage = result.error ?? "Unknown error"
            logger.error("yt-dlp metadata fetch failed: \(errorMessage)")
            throw YTDLPError.metadataFetchFailed(errorMessage)
        }

        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            throw YTDLPError.metadataFetchFailed("Failed to parse JSON response")
        }

        let title = json["title"] as? String ?? "Unknown Title"
        let duration = json["duration"] as? Double
        let thumbnailURLString = json["thumbnail"] as? String
        let thumbnailURL = thumbnailURLString.flatMap { URL(string: $0) }
        let uploader = json["uploader"] as? String
        let description = json["description"] as? String

        return YTDLPMetadata(
            title: title,
            duration: duration,
            thumbnailURL: thumbnailURL,
            uploader: uploader,
            description: description
        )
    }

    /// Downloads a video using yt-dlp
    /// - Parameters:
    ///   - url: The video URL to download
    ///   - outputFolder: The folder to save the downloaded video
    ///   - forceOverwrite: If true, overwrites existing files instead of skipping
    ///   - progress: Callback for progress updates (progress 0-1, speed string)
    /// - Returns: The path to the downloaded file
    func download(
        url: String,
        outputFolder: URL,
        forceOverwrite: Bool = false,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> YTDLPDownloadResult {
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        process.currentDirectoryURL = outputFolder

        // Build arguments array
        // Note: --ignore-config prevents yt-dlp from reading user config files
        // Note: --remote-components ejs:github is required for YouTube JS challenge solving
        var args: [String] = ["--ignore-config", "--remote-components", "ejs:github"]

        // Add ffmpeg location if available
        let resolvedFFmpegPath = BinaryPathResolver.ffmpegPath
        print("[YTDLPService] Resolved ffmpeg path: \(resolvedFFmpegPath ?? "nil")")
        if let ffmpegPath = resolvedFFmpegPath {
            // yt-dlp needs the directory containing ffmpeg, not the binary itself
            let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
            print("[YTDLPService] Using ffmpeg dir: \(ffmpegDir)")
            args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        } else {
            print("[YTDLPService] WARNING: No ffmpeg path available for yt-dlp postprocessing")
        }

        args.append(contentsOf: [
            "-f", "bestvideo+bestaudio/best",
            "--no-playlist",
            "--newline",
            "--progress",
            forceOverwrite ? "--force-overwrites" : "--no-overwrites",
            "--print", "after_move:filepath",
            "-o", "%(title)s.%(ext)s",
            url
        ])

        // Configure process for Homebrew Python or regular executable
        HomebrewPythonExecutor.configureProcess(process, scriptPath: ytdlpPath, arguments: args)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Store process for cancellation
        currentProcess = process

        // Use a class to hold mutable state for thread-safe access from the handler
        final class ParsedState: @unchecked Sendable {
            var outputPath: String?
            var videoTitle: String = "Downloaded Video"
            var lastError: String?
            var fileAlreadyExists: Bool = false
            var existingFilePath: String?
            let lock = NSLock()

            func read<T>(_ block: (ParsedState) -> T) -> T {
                lock.lock()
                defer { lock.unlock() }
                return block(self)
            }
        }
        let parsedState = ParsedState()

        // Handle stderr for progress updates
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Debug: Log all stderr output
                    print("[YTDLPService] stderr: \(trimmed)")

                    // Parse progress
                    if let progressInfo = YTDLPProgressParser.parse(trimmed) {
                        print("[YTDLPService] Progress parsed: \(progressInfo.progress * 100)%")
                        progress(progressInfo.progress, progressInfo.speed)
                    }

                    // Parse title
                    if let title = YTDLPProgressParser.parseTitle(trimmed) {
                        parsedState.lock.lock()
                        parsedState.videoTitle = title
                        parsedState.lock.unlock()
                    }

                    // Parse output path (from merger or download destination)
                    if let path = YTDLPProgressParser.parseOutputPath(trimmed) {
                        parsedState.lock.lock()
                        parsedState.outputPath = path
                        parsedState.lock.unlock()
                    }

                    // Check for errors
                    if let error = YTDLPProgressParser.parseError(trimmed) {
                        parsedState.lock.lock()
                        parsedState.lastError = error
                        parsedState.lock.unlock()
                    }
                }
            }
        }

        // Also handle stdout for progress (yt-dlp may output progress to stdout when run as module)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Debug: Log stdout output
                    print("[YTDLPService] stdout: \(trimmed)")

                    // Check for "already been downloaded" message
                    if trimmed.contains("has already been downloaded") {
                        print("[YTDLPService] File already exists detected")
                        parsedState.lock.lock()
                        parsedState.fileAlreadyExists = true
                        // Extract filename from message like "[download] filename.ext has already been downloaded"
                        if let range = trimmed.range(of: "] "),
                           let endRange = trimmed.range(of: " has already been downloaded") {
                            let filename = String(trimmed[range.upperBound..<endRange.lowerBound])
                            parsedState.existingFilePath = filename
                        }
                        parsedState.lock.unlock()
                    }

                    // Check for progress on stdout too
                    if let progressInfo = YTDLPProgressParser.parse(trimmed) {
                        print("[YTDLPService] Progress from stdout: \(progressInfo.progress * 100)%")
                        progress(progressInfo.progress, progressInfo.speed)
                    }

                    // Parse output path from stdout (--print after_move:filepath)
                    // Store potential output path for later use
                    if !trimmed.hasPrefix("[") && !trimmed.contains("%") {
                        // Could be a file path from --print
                        parsedState.lock.lock()
                        parsedState.outputPath = trimmed
                        parsedState.lock.unlock()
                    }
                }
            }
        }

        try process.run()
        process.waitUntilExit()
        
        // Clean up
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        // Read final state
        let lastError = parsedState.read { $0.lastError }
        let outputPath = parsedState.read { $0.outputPath }
        let videoTitle = parsedState.read { $0.videoTitle }
        let fileAlreadyExists = parsedState.read { $0.fileAlreadyExists }
        let existingFilePath = parsedState.read { $0.existingFilePath }

        // Check if file already exists (detected via --no-overwrites)
        if fileAlreadyExists {
            let existingPath = existingFilePath ?? outputFolder.appendingPathComponent(videoTitle).path
            print("[YTDLPService] File already exists at: \(existingPath)")
            throw YTDLPError.fileAlreadyExists(path: existingPath, title: videoTitle)
        }

        // Check exit status
        guard process.terminationStatus == 0 else {
            let errorMessage = lastError ?? "Download failed with exit code \(process.terminationStatus)"
            throw YTDLPError.downloadFailed(errorMessage)
        }

        // Note: Output path is captured from stdout via the readabilityHandler above
        // The --print after_move:filepath outputs the final path which we parse there
        print("[YTDLPService] Final output path from parsing: \(outputPath ?? "nil")")

        // Verify output file exists
        guard let finalPath = outputPath else {
            throw YTDLPError.outputNotFound
        }

        let outputURL: URL
        if finalPath.hasPrefix("/") {
            outputURL = URL(fileURLWithPath: finalPath)
        } else {
            outputURL = outputFolder.appendingPathComponent(finalPath)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw YTDLPError.outputNotFound
        }

        // Report 100% progress
        progress(1.0, nil)

        return YTDLPDownloadResult(outputURL: outputURL, title: videoTitle)
    }

    /// Cancels the current download
    func cancelDownload() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
            logger.info("Download cancelled")
        }
    }
}

enum YTDLPError: Error, LocalizedError {
    case binaryNotFound
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case outputNotFound
    case cancelled
    case fileAlreadyExists(path: String, title: String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "yt-dlp binary not found"
        case .metadataFetchFailed(let message):
            return "Failed to fetch metadata: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .outputNotFound:
            return "Downloaded file not found"
        case .cancelled:
            return "Download was cancelled"
        case .fileAlreadyExists(let path, _):
            return "File already exists: \(path)"
        }
    }
}
