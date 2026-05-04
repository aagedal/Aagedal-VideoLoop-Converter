// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

// MARK: - Progress & Error Types

struct TesseractProgress: Sendable {
    enum Stage: Sendable {
        case extractingTrack
        case parsingFrames
        case recognizing(frame: Int, total: Int)
        case writingSRT
        case complete
        case failed(String)
    }
    let stage: Stage
    let percentage: Double

    var stageDescription: String {
        switch stage {
        case .extractingTrack:  return "Extracting subtitle track…"
        case .parsingFrames:    return "Parsing subtitle images…"
        case .recognizing(let f, let t): return "Recognising text (\(f)/\(t))…"
        case .writingSRT:       return "Writing SRT file…"
        case .complete:         return "Done"
        case .failed(let e):    return "Failed: \(e)"
        }
    }
}

enum TesseractServiceError: Error, LocalizedError {
    case tesseractNotFound
    case ffmpegNotFound
    case noSubtitleStream
    case extractionFailed(String)
    case parsingFailed(String)
    case ocrFailed(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .tesseractNotFound:
            return "Tesseract not found. Install via Homebrew or configure in Settings → OCR."
        case .ffmpegNotFound:
            return "FFmpeg binary not found."
        case .noSubtitleStream:
            return "No bitmap subtitle stream found in source file."
        case .extractionFailed(let msg):
            return "Subtitle extraction failed: \(msg)"
        case .parsingFailed(let msg):
            return "Subtitle parsing failed: \(msg)"
        case .ocrFailed(let msg):
            return "OCR failed: \(msg)"
        case .srtGenerationFailed:
            return "Failed to write SRT file."
        case .cancelled:
            return "OCR was cancelled."
        }
    }
}

// MARK: - TesseractService

/// Converts bitmap subtitle streams (PGS/VOBSUB) to SRT using Tesseract OCR.
///
/// Pipeline:
///   1. FFmpeg extracts the subtitle stream to a temporary .sup or .sub file
///   2. PGSParser / VOBSUBParser decodes frames into SubtitleFrame values
///   3. Tesseract OCRs each PNG frame
///   4. An SRT file is assembled and written to the output directory
actor TesseractService {
    static let shared = TesseractService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "TesseractService")

    private var isCancelled = false
    private var currentProcess: Process?
    private var currentOCRTask: Task<String, Error>?

    private init() {}

    // MARK: - Public API

    /// Converts a bitmap subtitle stream in `sourceFile` to SRT, saving alongside the
    /// encoded output in `outputDirectory`.
    func generateSubtitles(
        sourceFile: URL,
        outputDirectory: URL,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        isCancelled = false
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let srtURL = outputDirectory.appendingPathComponent(baseName + ".srt")
        return try await runPipeline(
            sourceFile: sourceFile,
            srtURL: srtURL,
            subtitleStreamIndex: subtitleStreamIndex,
            codec: codec,
            language: language,
            progress: progress
        )
    }

    /// Converts a bitmap subtitle stream in `sourceFile` to SRT, saving alongside
    /// the source file. Used for "transcribe-only" (Option+click) mode.
    func generateSubtitlesOnly(
        sourceFile: URL,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        isCancelled = false
        let outputDirectory = sourceFile.deletingLastPathComponent()
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let srtURL = outputDirectory.appendingPathComponent(baseName + ".srt")
        return try await runPipeline(
            sourceFile: sourceFile,
            srtURL: srtURL,
            subtitleStreamIndex: subtitleStreamIndex,
            codec: codec,
            language: language,
            progress: progress
        )
    }

    /// Cancels any in-progress OCR run.
    func cancelGeneration() {
        isCancelled = true
        currentProcess?.terminate()
        currentOCRTask?.cancel()
    }

    // MARK: - Pipeline

    private func runPipeline(
        sourceFile: URL,
        srtURL: URL,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw TesseractServiceError.ffmpegNotFound
        }

        let engine: any BitmapSubtitleOCREngine
        switch OCREngineKind.userPreferred {
        case .tesseract:
            guard let tesseractPath = BinaryPathResolver.tesseractPath else {
                throw TesseractServiceError.tesseractNotFound
            }
            engine = TesseractOCREngine(
                tesseractPath: tesseractPath,
                tessdataPrefix: BinaryPathResolver.tessdataDirectory
            )
        case .appleVision:
            engine = VisionOCREngine()
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseractOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1 — Extract subtitle stream
        progress(TesseractProgress(stage: .extractingTrack, percentage: 0.0))
        logger.info("Extracting subtitle stream \(subtitleStreamIndex) from \(sourceFile.lastPathComponent)")

        let isPGS = isBitmapPGS(codec: codec)
        let frames = try await extractAndParse(
            sourceFile: sourceFile,
            streamIndex: subtitleStreamIndex,
            isPGS: isPGS,
            ffmpegPath: ffmpegPath,
            tempDir: tempDir,
            progress: progress
        )

        guard !frames.isEmpty else {
            throw TesseractServiceError.parsingFailed("No subtitle frames found in stream")
        }

        guard !isCancelled else { throw TesseractServiceError.cancelled }

        // Step 3 — OCR each frame
        let total = frames.count
        var srtEntries: [(index: Int, start: TimeInterval, end: TimeInterval, text: String)] = []

        for (i, frame) in frames.enumerated() {
            guard !isCancelled else { throw TesseractServiceError.cancelled }

            let pct = 0.3 + 0.65 * (Double(i) / Double(total))
            progress(TesseractProgress(stage: .recognizing(frame: i + 1, total: total), percentage: pct))

            let pngFile = tempDir.appendingPathComponent("frame_\(i).png")
            try frame.imageData.write(to: pngFile)

            let task = Task<String, Error> {
                try await engine.recognize(pngURL: pngFile, language: language)
            }
            currentOCRTask = task
            let text: String
            do {
                text = try await task.value
            } catch is CancellationError {
                throw TesseractServiceError.cancelled
            } catch {
                throw TesseractServiceError.ocrFailed(error.localizedDescription)
            }
            currentOCRTask = nil

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                srtEntries.append((index: srtEntries.count + 1, start: frame.startTime, end: frame.endTime, text: trimmed))
            }
        }

        guard !isCancelled else { throw TesseractServiceError.cancelled }

        // Step 4 — Write SRT
        progress(TesseractProgress(stage: .writingSRT, percentage: 0.97))
        let srtContent = buildSRT(from: srtEntries)
        do {
            try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            throw TesseractServiceError.srtGenerationFailed
        }

        progress(TesseractProgress(stage: .complete, percentage: 1.0))
        logger.info("OCR complete: \(srtURL.lastPathComponent) (\(srtEntries.count) subtitles)")
        return srtURL
    }

    // MARK: - Extract + Parse

    private func extractAndParse(
        sourceFile: URL,
        streamIndex: Int,
        isPGS: Bool,
        ffmpegPath: String,
        tempDir: URL,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> [SubtitleFrame] {
        if isPGS {
            let supFile = tempDir.appendingPathComponent("subs.sup")
            try extractStream(
                source: sourceFile.path,
                streamIndex: streamIndex,
                outputPath: supFile.path,
                ffmpegPath: ffmpegPath
            )
            progress(TesseractProgress(stage: .parsingFrames, percentage: 0.15))
            do {
                let data = try Data(contentsOf: supFile)
                return try PGSParser.parse(supData: data)
            } catch {
                throw TesseractServiceError.parsingFailed(error.localizedDescription)
            }
        } else {
            // VOBSUB — FFmpeg outputs .sub + .idx
            let subFile = tempDir.appendingPathComponent("subs.sub")
            let idxFile = tempDir.appendingPathComponent("subs.idx")
            try extractStream(
                source: sourceFile.path,
                streamIndex: streamIndex,
                outputPath: subFile.path,
                ffmpegPath: ffmpegPath
            )
            progress(TesseractProgress(stage: .parsingFrames, percentage: 0.15))
            guard FileManager.default.fileExists(atPath: subFile.path),
                  FileManager.default.fileExists(atPath: idxFile.path) else {
                throw TesseractServiceError.extractionFailed("VOBSUB .sub/.idx files not created")
            }
            do {
                return try VOBSUBParser.parse(idxURL: idxFile, subURL: subFile)
            } catch {
                throw TesseractServiceError.parsingFailed(error.localizedDescription)
            }
        }
    }

    private func extractStream(
        source: String,
        streamIndex: Int,
        outputPath: String,
        ffmpegPath: String
    ) throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-y",
            "-i", source,
            "-map", "0:\(streamIndex)",
            "-c", "copy",
            outputPath
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        currentProcess = process
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TesseractServiceError.extractionFailed(error.localizedDescription)
        }
        currentProcess = nil

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.suffix(300) ?? "unknown error"
            throw TesseractServiceError.extractionFailed("FFmpeg exited \(process.terminationStatus): \(msg)")
        }
    }

    // MARK: - SRT Builder

    private func buildSRT(from entries: [(index: Int, start: TimeInterval, end: TimeInterval, text: String)]) -> String {
        var lines: [String] = []
        for entry in entries {
            lines.append("\(entry.index)")
            lines.append("\(srtTimestamp(entry.start)) --> \(srtTimestamp(entry.end))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func srtTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds * 1000)
        let ms = total % 1000
        let s  = (total / 1000) % 60
        let m  = (total / 60_000) % 60
        let h  = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - Helpers

    private func isBitmapPGS(codec: String) -> Bool {
        let lower = codec.lowercased()
        // FFprobe-style + Matroska container ID (SwiftExif's MKV reader emits the latter).
        return lower == "pgssub" || lower == "hdmv_pgs_subtitle" || lower == "s_hdmv/pgs"
    }
}
