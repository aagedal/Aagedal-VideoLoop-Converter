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

/// How aggressively yt-dlp should sanitize downloaded filenames.
enum YTDLPFilenameRestrictionMode: String, CaseIterable, Identifiable {
    /// Default — yt-dlp only strips characters illegal on the current OS (just `/` and NUL on macOS).
    case off
    /// Adds `--windows-filenames` so filenames are also safe on Windows / NTFS / cloud sync.
    /// Strips `< > : " / \ | ? *`, control chars, and trailing space/period. Keeps Unicode letters.
    case windowsSafe = "windows_safe"
    /// Adds `--restrict-filenames` — ASCII letters/digits/`_.-` only. Drops non-Latin scripts and many accents.
    case asciiOnly = "ascii_only"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .windowsSafe: return "Windows-safe (keeps Unicode letters)"
        case .asciiOnly: return "ASCII only (strips non-Latin scripts)"
        }
    }

    static var current: YTDLPFilenameRestrictionMode {
        let raw = UserDefaults.standard.string(forKey: AppConstants.ytdlpFilenameRestrictionModeKey)
            ?? AppConstants.defaultYTDLPFilenameRestrictionMode
        return YTDLPFilenameRestrictionMode(rawValue: raw) ?? .off
    }
}

/// Service for executing yt-dlp downloads
actor YTDLPService {
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "YTDLPService")
    private let updateService = YTDLPUpdateService.shared

    private enum CancelReason {
        case userRequested
        case liveRecordingStop
        case stalled
    }

    /// How long yt-dlp may produce no output before the stall watchdog kills it.
    /// Generous enough to cover slow Python startup and post-processing lulls.
    private static let stallThresholdSeconds: TimeInterval = 300
    private static let stallCheckIntervalNanos: UInt64 = 30_000_000_000 // 30s

    /// Thread-safe storage for the current process (accessible from any thread for cancellation)
    private final class ProcessHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _process: Process?
        private var _cancelReason: CancelReason?

        var process: Process? {
            get { lock.lock(); defer { lock.unlock() }; return _process }
            set { lock.lock(); defer { lock.unlock() }; _process = newValue }
        }

        var cancelReason: CancelReason? {
            get { lock.lock(); defer { lock.unlock() }; return _cancelReason }
            set { lock.lock(); defer { lock.unlock() }; _cancelReason = newValue }
        }

        func terminate(reason: CancelReason) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let proc = _process, proc.isRunning else { return false }
            _cancelReason = reason
            proc.terminate()
            return true
        }
    }

    private let processHolder = ProcessHolder()

    private final class DateBox: @unchecked Sendable {
        var value: Date

        init(value: Date) {
            self.value = value
        }
    }

    /// Path to ffmpeg for post-processing
    private var ffmpegPath: String? {
        BinaryPathResolver.ffmpegPath
    }

    /// Fetches video metadata without downloading
    func fetchMetadata(url: String) async throws -> YTDLPMetadata {
        let startTime = Date()
        logger.info("[TIMING] fetchMetadata started")

        let pathResolveStart = Date()
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        let pathResolveElapsed = Date().timeIntervalSince(pathResolveStart)
        logger.info("[TIMING] yt-dlp path resolved in \(String(format: "%.3f", pathResolveElapsed))s: \(ytdlpPath)")

        let denoPath = await updateService.ensureDenoInstalled()

        // Run process handling on a background thread to avoid blocking async context
        let processStartTime = Date()
        let result: (data: Data, error: String?, exitCode: Int32) = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                // Configure process for Homebrew Python or regular executable
                // Note: --ignore-config prevents yt-dlp from reading user config files
                // Note: --remote-components ejs:github is required for YouTube JS challenge solving
                var arguments = [
                    "--ignore-config",
                    "--remote-components", "ejs:github",
                    "--cache-dir", AppConstants.ytdlpCacheDirectory.path
                ]
                if let denoPath {
                    arguments.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
                }

                // Add browser cookies if configured
                let cookiesBrowser = UserDefaults.standard.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
                if !cookiesBrowser.isEmpty {
                    arguments.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
                }

                // "--" ends flag parsing so a URL that somehow starts with "-" can't be
                // interpreted as an option.
                arguments.append(contentsOf: ["-j", "--no-download", "--no-warnings", "--", url])

                HomebrewPythonExecutor.configureProcess(
                    process,
                    scriptPath: ytdlpPath,
                    arguments: arguments
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

        let processElapsed = Date().timeIntervalSince(processStartTime)
        logger.info("[TIMING] yt-dlp metadata process completed in \(String(format: "%.2f", processElapsed))s, exit status: \(result.exitCode)")

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

        let totalElapsed = Date().timeIntervalSince(startTime)
        logger.info("[TIMING] fetchMetadata completed in \(String(format: "%.2f", totalElapsed))s for: \(title)")

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
    ///   - liveFromStart: Whether to rewind live streams to the beginning
    ///   - audioOnly: Whether to download only the audio track (no video)
    ///   - progress: Callback for progress updates (progress 0-1, speed string, isLiveStream)
    ///   - titleUpdate: Callback when video title is discovered
    /// - Returns: The path to the downloaded file
    func download(
        url: String,
        outputFolder: URL,
        forceOverwrite: Bool = false,
        liveFromStart: Bool = false,
        audioOnly: Bool = false,
        progress: @escaping @Sendable (Double, String?, Bool) -> Void,
        titleUpdate: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> YTDLPDownloadResult {
        let downloadStartTime = Date()
        logger.info("[TIMING] download() started")
        processHolder.cancelReason = nil

        let pathResolveStart = Date()
        guard let ytdlpPath = await updateService.resolveYTDLPPath() else {
            throw YTDLPError.binaryNotFound
        }
        let pathResolveElapsed = Date().timeIntervalSince(pathResolveStart)
        logger.info("[TIMING] yt-dlp path resolved in \(String(format: "%.3f", pathResolveElapsed))s")

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        process.currentDirectoryURL = outputFolder

        // Build arguments array
        // Note: --ignore-config prevents yt-dlp from reading user config files
        // Note: --remote-components ejs:github is required for YouTube JS challenge solving
        var args: [String] = [
            "--ignore-config",
            "--remote-components", "ejs:github",
            "--cache-dir", AppConstants.ytdlpCacheDirectory.path
        ]
        if let denoPath = await updateService.ensureDenoInstalled() {
            args.append(contentsOf: ["--js-runtimes", "deno:\(denoPath)"])
            logger.info("[YTDLPService] Using deno runtime at: \(denoPath)")
        }
        logger.info("[YTDLPService] Using cache dir: \(AppConstants.ytdlpCacheDirectory.path)")

        // Add ffmpeg location if available
        let ffmpegResolveStart = Date()
        let resolvedFFmpegPath = BinaryPathResolver.ffmpegPath
        let ffmpegResolveElapsed = Date().timeIntervalSince(ffmpegResolveStart)
        logger.info("[TIMING] ffmpeg path resolved in \(String(format: "%.3f", ffmpegResolveElapsed))s: \(resolvedFFmpegPath ?? "nil")")
        if let ffmpegPath = resolvedFFmpegPath {
            // yt-dlp needs the directory containing ffmpeg, not the binary itself
            let ffmpegDir = (ffmpegPath as NSString).deletingLastPathComponent
            logger.debug("Using ffmpeg dir: \(ffmpegDir)")
            args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        } else {
            logger.warning("No ffmpeg path available for yt-dlp postprocessing")
        }

        // Add browser cookies if configured
        let cookiesBrowser = UserDefaults.standard.string(forKey: AppConstants.ytdlpCookiesBrowserKey) ?? ""
        if !cookiesBrowser.isEmpty {
            args.append(contentsOf: ["--cookies-from-browser", cookiesBrowser])
            logger.info("[YTDLPService] Using cookies from browser: \(cookiesBrowser)")
        }

        if liveFromStart {
            args.append(contentsOf: ["--live-from-start", "--no-part"])
            logger.info("[YTDLPService] Downloading live stream from start (no-part)")
        }

        switch YTDLPFilenameRestrictionMode.current {
        case .off:
            break
        case .windowsSafe:
            args.append("--windows-filenames")
            logger.info("[YTDLPService] Filename restriction: windows-safe")
        case .asciiOnly:
            args.append("--restrict-filenames")
            logger.info("[YTDLPService] Filename restriction: ASCII only")
        }

        // Format selector: prefer audio-only stream when in audio-only mode, otherwise
        // grab best video+audio. `-x` (--extract-audio) makes yt-dlp post-process to a
        // standalone audio file when the chosen stream is muxed; with `--audio-format
        // best` the original codec is preserved (no re-encoding when avoidable).
        let formatSelector = audioOnly ? "bestaudio/best" : "bestvideo+bestaudio/best"
        args.append(contentsOf: ["-f", formatSelector])
        if audioOnly {
            args.append(contentsOf: ["-x", "--audio-format", "best"])
            logger.info("[YTDLPService] Audio-only download requested")
        }

        args.append(contentsOf: [
            "--no-playlist",
            "--trim-filenames", "200",
            "--newline",
            "--progress",
            "--verbose",  // Enable verbose output to ensure we get stderr
            forceOverwrite ? "--force-overwrites" : "--no-overwrites",
            "--print", "after_move:filepath",
            "-o", "%(title)s.%(ext)s",
            // "--" ends flag parsing so a URL that somehow starts with "-" can't be
            // interpreted as an option.
            "--",
            url
        ])

        // Configure process for Homebrew Python or regular executable
        HomebrewPythonExecutor.configureProcess(process, scriptPath: ytdlpPath, arguments: args)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Store process for cancellation (thread-safe)
        processHolder.cancelReason = nil
        processHolder.process = process

        // Use a class to hold mutable state for thread-safe access from the handler
        final class ParsedState: @unchecked Sendable {
            var outputPath: String?
            var videoTitle: String = "Downloaded Video"
            var firstError: String?
            var fileAlreadyExists: Bool = false
            var existingFilePath: String?
            var firstStdoutLogged: Bool = false
            var firstStderrLogged: Bool = false
            var firstProgressLogged: Bool = false
            /// Timestamp of the last non-empty line seen on stdout/stderr.
            /// The stall watchdog compares against this to decide whether yt-dlp
            /// has gone silent.
            var lastActivity: Date = Date()
            let lock = NSLock()

            func read<T>(_ block: (ParsedState) -> T) -> T {
                lock.lock()
                defer { lock.unlock() }
                return block(self)
            }

            func markActivity() {
                lock.lock()
                lastActivity = Date()
                lock.unlock()
            }

            func markFirstStdout() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStdoutLogged {
                    return false
                }
                firstStdoutLogged = true
                return true
            }

            func markFirstStderr() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstStderrLogged {
                    return false
                }
                firstStderrLogged = true
                return true
            }

            func markFirstProgress() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if firstProgressLogged {
                    return false
                }
                firstProgressLogged = true
                return true
            }
        }
        let parsedState = ParsedState()
        let processStartBox = DateBox(value: Date())

        // Capture logger for use in @Sendable closures and local functions
        let logger = self.logger

        // Helper to process a line of output
        @Sendable func processLine(_ trimmed: String, isStderr: Bool) {
            guard !trimmed.isEmpty else { return }

            // Feed the stall watchdog: any non-empty stdout/stderr line counts
            // as activity, including fragment-download progress for live streams.
            parsedState.markActivity()

            if isStderr {
                if parsedState.markFirstStderr() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stderr after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stderr: \(trimmed, privacy: .public)")
            } else {
                if parsedState.markFirstStdout() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp stdout after \(String(format: "%.3f", delta))s")
                }
                logger.debug("stdout: \(trimmed, privacy: .public)")
            }

            // Parse progress from either stream
            if let progressInfo = YTDLPProgressParser.parse(trimmed) {
                logger.debug("Progress parsed: \(progressInfo.progress * 100)%, isLive: \(progressInfo.isLiveStream)")
                if parsedState.markFirstProgress() {
                    let delta = Date().timeIntervalSince(processStartBox.value)
                    logger.debug("First yt-dlp progress after \(String(format: "%.3f", delta))s")
                }
                progress(progressInfo.progress, progressInfo.speed, progressInfo.isLiveStream)
            }

            // Parse title from either stream
            if let title = YTDLPProgressParser.parseTitle(trimmed) {
                parsedState.lock.lock()
                let previousTitle = parsedState.videoTitle
                parsedState.videoTitle = title
                parsedState.lock.unlock()
                if title != previousTitle && title != "Downloaded Video" {
                    logger.info("Title discovered: \(title, privacy: .public)")
                    titleUpdate(title)
                }
            }

            // Parse output path (from merger or download destination)
            if let path = YTDLPProgressParser.parseOutputPath(trimmed) {
                parsedState.lock.lock()
                parsedState.outputPath = path
                parsedState.lock.unlock()
            }

            // Capture the FIRST error line we see — yt-dlp's initial ERROR: message
            // is the actionable summary ("Sign in to confirm you're not a bot",
            // "Video unavailable", etc.); subsequent lines are stack/detail that
            // look more alarming than they are in the UI.
            if let error = YTDLPProgressParser.parseError(trimmed) {
                parsedState.lock.lock()
                if parsedState.firstError == nil {
                    parsedState.firstError = error
                }
                parsedState.lock.unlock()
            }

            // Check for "already been downloaded" message (stdout only)
            if !isStderr && trimmed.contains("has already been downloaded") {
                logger.info("File already exists detected")
                parsedState.lock.lock()
                parsedState.fileAlreadyExists = true
                if let range = trimmed.range(of: "] "),
                   let endRange = trimmed.range(of: " has already been downloaded") {
                    let filename = String(trimmed[range.upperBound..<endRange.lowerBound])
                    parsedState.existingFilePath = filename
                }
                parsedState.lock.unlock()
            }

            // Parse output path from stdout (--print after_move:filepath).
            // yt-dlp prints an absolute path here, so require a leading slash.
            // This avoids capturing stray verbose/debug stdout (e.g. a raw title or
            // a warning line that happens to lack a "[" prefix) as the output path.
            if !isStderr && trimmed.hasPrefix("/") {
                parsedState.lock.lock()
                parsedState.outputPath = trimmed
                parsedState.lock.unlock()
            }
        }

        let processSetupElapsed = Date().timeIntervalSince(downloadStartTime)
        logger.info("[TIMING] Process setup completed in \(String(format: "%.3f", processSetupElapsed))s, starting download process...")

        processStartBox.value = Date()
        parsedState.markActivity()

        // Stall watchdog: if yt-dlp produces no output for `stallThresholdSeconds`,
        // terminate it so the UI isn't stuck forever on a dead connection. Fragment
        // progress for live streams keeps feeding the watchdog, so legitimate live
        // recordings are unaffected.
        let stallThreshold = Self.stallThresholdSeconds
        let stallCheckInterval = Self.stallCheckIntervalNanos
        let watchdogHolder = processHolder
        let watchdogState = parsedState
        let watchdogLogger = logger
        let watchdogTask = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: stallCheckInterval)
                if Task.isCancelled { break }
                let last = watchdogState.read { $0.lastActivity }
                let elapsed = Date().timeIntervalSince(last)
                if elapsed > stallThreshold {
                    watchdogLogger.warning("yt-dlp appears stalled (no output for \(Int(elapsed))s) — terminating")
                    _ = watchdogHolder.terminate(reason: .stalled)
                    break
                }
            }
        }
        defer { watchdogTask.cancel() }

        // Run process with background pipe reading using DispatchQueue
        // This is more reliable than readabilityHandler with Swift concurrency
        let terminationStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
            let group = DispatchGroup()

            // Read stderr in background
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                logger.debug("stderr reader started")
                let handle = stderrPipe.fileHandleForReading
                var buffer = Data()
                var chunkCount = 0
                while true {
                    let chunk = handle.availableData
                    chunkCount += 1
                    if chunkCount == 1 {
                        logger.debug("stderr first chunk received, size: \(chunk.count)")
                    }
                    if chunk.isEmpty {
                        logger.debug("stderr EOF after \(chunkCount) chunks")
                        // Process any remaining data in buffer
                        if !buffer.isEmpty, let str = String(data: buffer, encoding: .utf8) {
                            for line in str.components(separatedBy: .newlines) {
                                processLine(line.trimmingCharacters(in: .whitespacesAndNewlines), isStderr: true)
                            }
                        }
                        break
                    }
                    buffer.append(chunk)
                    // Process complete lines
                    if let str = String(data: buffer, encoding: .utf8) {
                        let lines = str.components(separatedBy: .newlines)
                        // Keep the last incomplete line in buffer
                        for i in 0..<(lines.count - 1) {
                            processLine(lines[i].trimmingCharacters(in: .whitespacesAndNewlines), isStderr: true)
                        }
                        // Keep last line in buffer (might be incomplete)
                        if let lastLine = lines.last, let lastLineData = lastLine.data(using: .utf8) {
                            buffer = lastLineData
                        } else {
                            buffer = Data()
                        }
                    }
                }
                group.leave()
            }

            // Read stdout in background
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                logger.debug("stdout reader started")
                let handle = stdoutPipe.fileHandleForReading
                var buffer = Data()
                var chunkCount = 0
                while true {
                    let chunk = handle.availableData
                    chunkCount += 1
                    if chunkCount == 1 {
                        logger.debug("stdout first chunk received, size: \(chunk.count)")
                    }
                    if chunk.isEmpty {
                        logger.debug("stdout EOF after \(chunkCount) chunks")
                        // Process any remaining data in buffer
                        if !buffer.isEmpty, let str = String(data: buffer, encoding: .utf8) {
                            for line in str.components(separatedBy: .newlines) {
                                processLine(line.trimmingCharacters(in: .whitespacesAndNewlines), isStderr: false)
                            }
                        }
                        break
                    }
                    buffer.append(chunk)
                    // Process complete lines
                    if let str = String(data: buffer, encoding: .utf8) {
                        let lines = str.components(separatedBy: .newlines)
                        for i in 0..<(lines.count - 1) {
                            processLine(lines[i].trimmingCharacters(in: .whitespacesAndNewlines), isStderr: false)
                        }
                        if let lastLine = lines.last, let lastLineData = lastLine.data(using: .utf8) {
                            buffer = lastLineData
                        } else {
                            buffer = Data()
                        }
                    }
                }
                group.leave()
            }

            process.terminationHandler = { proc in
                // Wait for pipe readers to finish before resuming
                group.notify(queue: .global()) {
                    continuation.resume(returning: proc.terminationStatus)
                }
            }

            do {
                try process.run()
                logger.info("Process started with PID: \(process.processIdentifier)")
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let processRunElapsed = Date().timeIntervalSince(processStartBox.value)
        logger.info("[TIMING] Download process completed in \(String(format: "%.2f", processRunElapsed))s")

        // Clean up
        processHolder.process = nil

        let finalCancelReason = processHolder.cancelReason
        processHolder.cancelReason = nil
        if let finalCancelReason {
            switch finalCancelReason {
            case .userRequested:
                logger.info("Download cancelled")
                throw YTDLPError.cancelled
            case .liveRecordingStop:
                logger.info("Live stream recording stopped")
                throw YTDLPError.liveRecordingStopped
            case .stalled:
                logger.warning("Download terminated due to stall")
                throw YTDLPError.stalled
            }
        }

        // Read final state
        let firstError = parsedState.read { $0.firstError }
        let outputPath = parsedState.read { $0.outputPath }
        let videoTitle = parsedState.read { $0.videoTitle }
        let fileAlreadyExists = parsedState.read { $0.fileAlreadyExists }
        let existingFilePath = parsedState.read { $0.existingFilePath }

        // Check if file already exists (detected via --no-overwrites)
        if fileAlreadyExists {
            let existingPath = existingFilePath ?? outputFolder.appendingPathComponent(videoTitle).path
            logger.info("File already exists at: \(existingPath, privacy: .auto)")
            throw YTDLPError.fileAlreadyExists(path: existingPath, title: videoTitle)
        }

        // Check exit status
        guard terminationStatus == 0 else {
            let errorMessage = firstError ?? "Download failed with exit code \(terminationStatus)"
            throw YTDLPError.downloadFailed(errorMessage)
        }

        // Note: Output path is captured from stdout via the readabilityHandler above
        // The --print after_move:filepath outputs the final path which we parse there
        logger.info("Final output path from parsing: \(outputPath ?? "nil", privacy: .auto)")

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
        progress(1.0, nil, false)

        return YTDLPDownloadResult(outputURL: outputURL, title: videoTitle)
    }

    /// Cancels the current download (nonisolated for immediate response)
    nonisolated func cancelDownload() {
        if processHolder.terminate(reason: .userRequested) {
            logger.info("Download cancelled by user")
        }
    }

    /// Stops a live stream download but keeps the partial file (nonisolated for immediate response)
    nonisolated func stopLiveDownload() {
        if processHolder.terminate(reason: .liveRecordingStop) {
            logger.info("Live stream recording stopped (keeping partial file)")
        }
    }
}

enum YTDLPError: Error, LocalizedError {
    case binaryNotFound
    case metadataFetchFailed(String)
    case downloadFailed(String)
    case outputNotFound
    case cancelled
    case liveRecordingStopped
    case fileAlreadyExists(path: String, title: String)
    case stalled

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
        case .liveRecordingStopped:
            return "Live stream recording stopped"
        case .fileAlreadyExists(let path, _):
            return "File already exists: \(path)"
        case .stalled:
            return "Download stalled — no activity for several minutes"
        }
    }
}
