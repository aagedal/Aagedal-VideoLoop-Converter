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
        case .ssimulacra2:
            process.arguments = buildSSIMULACRA2Arguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile
            )
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
        case .ssimulacra2:
            result = try parseSSIMULACRA2Results(from: stderrOutput)
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

    private func buildSSIMULACRA2Arguments(
        encodedFile: URL,
        sourceFile: URL
    ) -> [String] {
        let filter = "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]ssimulacra2"
        return [
            "-i", encodedFile.path,
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-f", "null",
            "-"
        ]
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

    private func parseSSIMULACRA2Results(from stderrOutput: String) throws -> MetricResult {
        // Parse the final aggregate score from ssimulacra2 filter output
        // Try the "All:" summary line first
        let patterns = [
            #"All:\s*([\d.]+)"#,
            #"SSIMULACRA2\s+score:\s*([\d.]+)"#,
            #"\[Parsed_ssimulacra2_0.*?\]\s*([\d.]+)"#
        ]

        var scores: [Double] = []

        // Collect all per-frame scores to compute the mean
        let perFramePattern = #"SSIMULACRA2\s+score:\s*([\d.]+)"#
        if let perFrameRegex = try? NSRegularExpression(pattern: perFramePattern) {
            let matches = perFrameRegex.matches(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput))
            for match in matches {
                if let range = Range(match.range(at: 1), in: stderrOutput),
                   let score = Double(stderrOutput[range]) {
                    scores.append(score)
                }
            }
        }

        // Try aggregate patterns
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput)),
               let range = Range(match.range(at: 1), in: stderrOutput),
               let score = Double(stderrOutput[range]) {
                return MetricResult(
                    metric: .ssimulacra2,
                    overallScore: score,
                    min: scores.min(),
                    max: scores.max(),
                    unit: "score",
                    channelScores: nil
                )
            }
        }

        // Fall back to mean of per-frame scores
        guard !scores.isEmpty else {
            throw AnalyticsError.parsingFailed("Could not find SSIMULACRA2 scores in FFmpeg output")
        }

        let mean = scores.reduce(0, +) / Double(scores.count)
        return MetricResult(
            metric: .ssimulacra2,
            overallScore: mean,
            min: scores.min(),
            max: scores.max(),
            unit: "score",
            channelScores: nil
        )
    }
}
