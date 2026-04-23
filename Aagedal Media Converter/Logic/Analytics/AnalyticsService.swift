// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Service for running video quality analytics using FFmpeg (VMAF, PSNR, SSIMULACRA2)
actor AnalyticsService {
    static let shared = AnalyticsService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AnalyticsService")
    private var isCancelled = false
    private var currentProcess: Process?

    private init() {}

    /// Runs all enabled metrics sequentially for a source/encoded pair
    /// - Parameters:
    ///   - sourceFile: The original source video file
    ///   - encodedFile: The encoded output file
    ///   - enabledMetrics: Which metrics to compute
    ///   - vmafModel: VMAF model variant to use
    ///   - progress: Callback with (currentMetric, progress 0-1)
    /// - Returns: Array of metric results
    func runAnalytics(
        sourceFile: URL,
        encodedFile: URL,
        enabledMetrics: [QualityMetric],
        vmafModel: VMAFModel,
        progress: @escaping @Sendable (QualityMetric, Double) -> Void
    ) async throws -> [MetricResult] {
        isCancelled = false

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw AnalyticsError.ffmpegNotFound
        }

        guard FileManager.default.fileExists(atPath: sourceFile.path) else {
            throw AnalyticsError.sourceFileNotFound
        }

        guard FileManager.default.fileExists(atPath: encodedFile.path) else {
            throw AnalyticsError.encodedFileNotFound
        }

        var results: [MetricResult] = []

        for metric in enabledMetrics {
            guard !isCancelled else {
                throw AnalyticsError.cancelled
            }

            do {
                let result = try await runMetric(
                    metric,
                    ffmpegPath: ffmpegPath,
                    sourceFile: sourceFile,
                    encodedFile: encodedFile,
                    vmafModel: vmafModel
                ) { metricProgress in
                    progress(metric, metricProgress)
                }
                results.append(result)
            } catch AnalyticsError.cancelled {
                throw AnalyticsError.cancelled
            } catch {
                logger.error("\(metric.displayName) failed: \(error.localizedDescription, privacy: .public)")
                throw AnalyticsError.metricFailed(metric, error.localizedDescription)
            }
        }

        return results
    }

    /// Cancels the current analysis
    func cancelAnalysis() {
        isCancelled = true
        if let process = currentProcess, process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Single Metric Execution

    private func runMetric(
        _ metric: QualityMetric,
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        vmafModel: VMAFModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        logger.info("Starting \(metric.displayName, privacy: .public) analysis")

        // SSIMULACRA2 uses a separate binary (ssimulacra2_rs), not an FFmpeg filter
        if metric == .ssimulacra2 {
            return try await runSSIMULACRA2Metric(
                ffmpegPath: ffmpegPath,
                sourceFile: sourceFile,
                encodedFile: encodedFile,
                progress: progress
            )
        }

        let process = Process()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Build arguments based on metric type
        var vmafLogURL: URL? = nil

        switch metric {
        case .vmaf:
            let tempDir = FileManager.default.temporaryDirectory
            let logFile = tempDir.appendingPathComponent("vmaf_\(UUID().uuidString).json")
            vmafLogURL = logFile
            process.arguments = buildVMAFArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile,
                model: vmafModel,
                logPath: logFile
            )
        case .psnr:
            process.arguments = buildPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile
            )
        case .xpsnr:
            process.arguments = buildXPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile
            )
        case .ssimulacra2:
            throw AnalyticsError.metricFailed(.ssimulacra2, "SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg path")
        }

        currentProcess = process

        // Thread-safe state for progress and stderr collection
        final class ProcessState: @unchecked Sendable {
            var durationSeconds: Double = 0
            var lastReportedProgress: Double = 0
            var stderrBuffer: String = ""
            let lock = NSLock()

            func appendStderr(_ text: String) {
                lock.lock()
                stderrBuffer += text
                lock.unlock()
            }

            func getStderr() -> String {
                lock.lock()
                defer { lock.unlock() }
                return stderrBuffer
            }
        }
        let state = ProcessState()

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                state.appendStderr(line)

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

                // Parse current time for progress
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

                            if currentProgress - state.lastReportedProgress >= 0.01 {
                                state.lastReportedProgress = currentProgress
                                Task { @MainActor in
                                    progress(currentProgress)
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
            throw AnalyticsError.metricFailed(metric, error.localizedDescription)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        guard !isCancelled else {
            // Clean up temp files
            if let logURL = vmafLogURL {
                try? FileManager.default.removeItem(at: logURL)
            }
            throw AnalyticsError.cancelled
        }

        let stderrOutput = state.getStderr()

        guard process.terminationStatus == 0 else {
            logger.error("FFmpeg stderr: \(stderrOutput, privacy: .public)")
            throw AnalyticsError.metricFailed(metric, "FFmpeg exited with code \(process.terminationStatus)")
        }

        // Parse results
        let result: MetricResult
        switch metric {
        case .vmaf:
            guard let logURL = vmafLogURL else {
                throw AnalyticsError.parsingFailed("VMAF log file not created")
            }
            result = try parseVMAFResults(from: logURL)
            // Clean up temp file
            try? FileManager.default.removeItem(at: logURL)
        case .psnr:
            result = try parsePSNRResults(from: stderrOutput)
        case .xpsnr:
            result = try parseXPSNRResults(from: stderrOutput)
        case .ssimulacra2:
            throw AnalyticsError.parsingFailed("SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg parsing path")
        }

        progress(1.0)
        logger.info("\(metric.displayName, privacy: .public) complete: \(result.formattedScore, privacy: .public) (\(result.qualityRating, privacy: .public))")

        return result
    }

    // MARK: - FFmpeg Command Construction

    private func buildVMAFArguments(
        encodedFile: URL,
        sourceFile: URL,
        model: VMAFModel,
        logPath: URL
    ) -> [String] {
        let escapedLogPath = logPath.path.replacingOccurrences(of: ":", with: "\\:")
        let vmafOpts = "libvmaf=model=version=\(model.rawValue):log_path=\(escapedLogPath):log_fmt=json"
        // scale2ref scales source (input 1) to match encoded (input 0) dimensions
        let filter = "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]\(vmafOpts)"
        return [
            "-i", encodedFile.path,
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-f", "null",
            "-"
        ]
    }

    private func buildPSNRArguments(
        encodedFile: URL,
        sourceFile: URL
    ) -> [String] {
        let filter = "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]psnr"
        return [
            "-i", encodedFile.path,
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-f", "null",
            "-"
        ]
    }

    private func buildXPSNRArguments(
        encodedFile: URL,
        sourceFile: URL
    ) -> [String] {
        // XPSNR expects reference first, distorted second
        // scale2ref scales source (input 0) to match encoded (input 1) dimensions
        let filter = "[0:v][1:v]scale2ref=flags=bicubic[ref][dist];[ref][dist]xpsnr"
        return [
            "-i", sourceFile.path,
            "-i", encodedFile.path,
            "-lavfi", filter,
            "-f", "null",
            "-"
        ]
    }

    // MARK: - SSIMULACRA2 (Frame-Based)

    /// Runs SSIMULACRA2 analysis by extracting frames and comparing with ssimulacra2_rs binary
    private func runSSIMULACRA2Metric(
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        guard let ssimulacra2Path = BinaryPathResolver.ssimulacra2Path else {
            throw AnalyticsError.ssimulacra2NotFound
        }

        let duration = try await getVideoDuration(for: encodedFile)
        let resolution = try await getVideoResolution(for: sourceFile)

        let maxFrames = UserDefaults.standard.integer(forKey: AppConstants.ssimulacra2MaxFramesKey)
        let frameCount = max(1, maxFrames > 0 ? maxFrames : AppConstants.defaultSSIMULACRA2MaxFrames)
        let actualFrameCount = min(frameCount, max(1, Int(duration)))
        let interval = duration / Double(actualFrameCount)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssimulacra2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        var scores: [Double] = []

        for i in 0..<actualFrameCount {
            guard !isCancelled else { throw AnalyticsError.cancelled }

            let timestamp = Double(i) * interval
            let sourceFrame = tempDir.appendingPathComponent("source_\(String(format: "%04d", i)).png")
            let encodedFrame = tempDir.appendingPathComponent("encoded_\(String(format: "%04d", i)).png")

            // Extract frames from both videos
            try extractFrame(ffmpegPath: ffmpegPath, input: sourceFile, timestamp: timestamp, output: sourceFrame, scaleFilter: nil)
            try extractFrame(ffmpegPath: ffmpegPath, input: encodedFile, timestamp: timestamp, output: encodedFrame, scaleFilter: "scale=\(resolution.width):\(resolution.height)")

            // Compare with ssimulacra2_rs
            let score = try compareFrames(ssimulacra2Path: ssimulacra2Path, source: sourceFrame, encoded: encodedFrame)
            scores.append(score)

            // Clean up frames immediately to save disk space
            try? FileManager.default.removeItem(at: sourceFrame)
            try? FileManager.default.removeItem(at: encodedFrame)

            let currentProgress = Double(i + 1) / Double(actualFrameCount)
            Task { @MainActor in
                progress(min(currentProgress, 0.99))
            }
        }

        guard !scores.isEmpty else {
            throw AnalyticsError.parsingFailed("No SSIMULACRA2 scores were computed")
        }

        let mean = scores.reduce(0, +) / Double(scores.count)
        progress(1.0)

        logger.info("SSIMULACRA2 complete: \(String(format: "%.1f", mean), privacy: .public) (sampled \(scores.count) frames)")

        return MetricResult(
            metric: .ssimulacra2,
            overallScore: mean,
            min: scores.min(),
            max: scores.max(),
            unit: "score",
            channelScores: nil
        )
    }

    /// Extracts a single frame from a video at the given timestamp
    private func extractFrame(ffmpegPath: String, input: URL, timestamp: Double, output: URL, scaleFilter: String?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        var args = [
            "-ss", String(format: "%.3f", timestamp),
            "-i", input.path
        ]
        if let scaleFilter = scaleFilter {
            args += ["-vf", scaleFilter]
        }
        args += [
            "-frames:v", "1",
            "-update", "1",
            "-y",
            output.path
        ]

        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        currentProcess = process

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Failed to extract frame at \(String(format: "%.1f", timestamp))s")
        }
    }

    /// Compares two image files using ssimulacra2_rs and returns the score
    private func compareFrames(ssimulacra2Path: String, source: URL, encoded: URL) throws -> Double {
        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ssimulacra2Path)
        process.arguments = ["image", source.path, encoded.path]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        currentProcess = process

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "ssimulacra2_rs exited with code \(process.terminationStatus)")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AnalyticsError.parsingFailed("Could not parse ssimulacra2_rs output")
        }

        // Output format: "Score: 97.53500802"
        let scoreString = output.hasPrefix("Score:") ? output.dropFirst(6).trimmingCharacters(in: .whitespaces) : output
        guard let score = Double(scoreString) else {
            throw AnalyticsError.parsingFailed("Could not parse ssimulacra2_rs output: \(output)")
        }

        return score
    }

    /// Gets video duration in seconds via SwiftExif (AVFoundation fallback).
    private func getVideoDuration(for file: URL) async throws -> Double {
        guard let duration = await SwiftExifMediaProbe.duration(for: file), duration > 0 else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video duration")
        }
        return duration
    }

    /// Gets video resolution (width x height) via SwiftExif.
    private func getVideoResolution(for file: URL) async throws -> (width: Int, height: Int) {
        guard SwiftExifMediaProbe.canReadVideo(file),
              let meta = try? await SwiftExifMediaProbe.readVideo(file),
              let primary = meta.videoStreams.first(where: { $0.isAttachedPic != true }),
              let width = primary.width,
              let height = primary.height else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video resolution")
        }
        return (width, height)
    }

    // MARK: - Result Parsing

    private func parseVMAFResults(from jsonURL: URL) throws -> MetricResult {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw AnalyticsError.parsingFailed("VMAF log file not found")
        }

        let data = try Data(contentsOf: jsonURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalyticsError.parsingFailed("Invalid VMAF JSON")
        }

        // Navigate: pooled_metrics -> vmaf -> mean/min/max
        guard let pooledMetrics = json["pooled_metrics"] as? [String: Any],
              let vmafMetrics = pooledMetrics["vmaf"] as? [String: Any],
              let mean = vmafMetrics["mean"] as? Double else {
            throw AnalyticsError.parsingFailed("Could not extract VMAF scores from JSON")
        }

        let min = vmafMetrics["min"] as? Double
        let max = vmafMetrics["max"] as? Double

        return MetricResult(
            metric: .vmaf,
            overallScore: mean,
            min: min,
            max: max,
            unit: "score",
            channelScores: nil
        )
    }

    private func parsePSNRResults(from stderrOutput: String) throws -> MetricResult {
        // Parse: [Parsed_psnr_0 @ ...] PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90
        let pattern = #"PSNR\s+y:([\d.]+)\s+u:([\d.]+)\s+v:([\d.]+)\s+average:([\d.]+)\s+min:([\d.]+)\s+max:([\d.]+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput)) else {
            throw AnalyticsError.parsingFailed("Could not find PSNR summary in FFmpeg output")
        }

        func extractDouble(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: stderrOutput) else { return nil }
            return Double(stderrOutput[range])
        }

        guard let y = extractDouble(1),
              let u = extractDouble(2),
              let v = extractDouble(3),
              let average = extractDouble(4),
              let min = extractDouble(5),
              let max = extractDouble(6) else {
            throw AnalyticsError.parsingFailed("Could not parse PSNR values")
        }

        return MetricResult(
            metric: .psnr,
            overallScore: average,
            min: min,
            max: max,
            unit: "dB",
            channelScores: ["Y": y, "U": u, "V": v]
        )
    }

    private func parseXPSNRResults(from stderrOutput: String) throws -> MetricResult {
        // Parse: [Parsed_xpsnr_1 @ 0x...] XPSNR  y: 35.0515  u: 49.0707  v: 50.7158  (minimum: 35.0515)
        let pattern = #"XPSNR\s+y:\s*([\d.]+)\s+u:\s*([\d.]+)\s+v:\s*([\d.]+)\s+\(minimum:\s*([\d.]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput)) else {
            throw AnalyticsError.parsingFailed("Could not find XPSNR summary in FFmpeg output")
        }

        func extractDouble(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: stderrOutput) else { return nil }
            return Double(stderrOutput[range])
        }

        guard let y = extractDouble(1),
              let u = extractDouble(2),
              let v = extractDouble(3),
              let minimum = extractDouble(4) else {
            throw AnalyticsError.parsingFailed("Could not parse XPSNR values")
        }

        // Weighted XPSNR: (6*Y + U + V) / 8 (luma-weighted average)
        let weighted = (6.0 * y + u + v) / 8.0

        return MetricResult(
            metric: .xpsnr,
            overallScore: weighted,
            min: minimum,
            max: nil,
            unit: "dB",
            channelScores: ["Y": y, "U": u, "V": v]
        )
    }

}
