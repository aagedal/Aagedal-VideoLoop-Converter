// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Thread-safe collector for stderr data
private actor StderrCollector {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func snapshot() -> Data {
        buffer
    }
}

/// Service for handling BMX tools operations (MXF rewrapping)
actor BMXService {
    static let shared = BMXService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "BMXService")
    private var currentProcess: Process?

    private init() {}

    // MARK: - Public API

    /// Rewraps an MXF file to OP1a format using bmxtranswrap
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (OP1a compliant)
    ///   - clipName: Optional clip name for the output
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToOP1a(
        inputURL: URL,
        outputURL: URL,
        clipName: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        var arguments: [String] = [
            "-t", "op1a",
            "--use-avc-subdesc",
        ]

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            progress: progress
        )
    }

    /// Rewraps an MXF file to RDD9 (SMPTE RDD 9) format for DCP-compliant ASDCP MXF
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (ASDCP compliant)
    ///   - isVideo: Whether this is a video MXF (adds DCI color metadata)
    ///   - clipName: Optional clip name for the output
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToRDD9(
        inputURL: URL,
        outputURL: URL,
        isVideo: Bool = true,
        clipName: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        var arguments: [String] = [
            "-t", "rdd9",
        ]

        // Add DCI color metadata for video MXF
        if isVideo {
            arguments.append(contentsOf: [
                "--signal-std", "st428",
                "--transfer-ch", "dcdm",
                "--color-prim", "dcdm",
                "--coding-eq", "gbr",
            ])
        }

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            progress: progress
        )
    }

    /// Cancels the current bmxtranswrap operation
    func cancel() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
            logger.info("bmxtranswrap cancelled")
        }
    }

    // MARK: - Shared Process Execution

    /// Shared bmxtranswrap execution with input/output validation, progress parsing, and error handling
    private func runBMXTranswrap(
        inputURL: URL,
        outputURL: URL,
        extraArguments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        guard let bmxtranswrapPath = BinaryPathResolver.bmxtranswrapPath else {
            logger.error("bmxtranswrap binary not found")
            return false
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            logger.error("Input MXF file not found: \(inputURL.path)")
            return false
        }

        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create output directory: \(error.localizedDescription)")
            return false
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                logger.error("Failed to remove existing output file: \(error.localizedDescription)")
                return false
            }
        }

        var arguments = extraArguments
        arguments.append(contentsOf: ["-o", outputURL.path, "-p"])
        arguments.append(inputURL.path)

        logger.info("Running bmxtranswrap: \(arguments.joined(separator: " "))")

        let process = Process()
        currentProcess = process
        process.executableURL = URL(fileURLWithPath: bmxtranswrapPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasSuffix("%") {
                        let numStr = trimmed.dropLast()
                        if let percent = Double(numStr) {
                            Task { @MainActor in
                                progress(percent / 100.0)
                            }
                        }
                    }
                }
            }
        }

        let stderrCollector = StderrCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await stderrCollector.append(data) }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run bmxtranswrap: \(error.localizedDescription)")
            currentProcess = nil
            return false
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        let success = process.terminationStatus == 0

        if success {
            logger.info("bmxtranswrap completed successfully: \(outputURL.lastPathComponent)")
            progress(1.0)
        } else {
            let stderrData = await stderrCollector.snapshot()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? "(no error output)"
            logger.error("bmxtranswrap failed with code \(process.terminationStatus): \(stderrString)")
        }

        return success
    }

    // MARK: - MXF Info

    /// Gets information about an MXF file using mxf2raw
    /// - Parameter url: The MXF file to analyze
    /// - Returns: MXF info string, or nil if failed
    func getMXFInfo(url: URL) async -> String? {
        guard let mxf2rawPath = BinaryPathResolver.mxf2rawPath else {
            logger.error("mxf2raw binary not found")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("MXF file not found: \(url.path)")
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: mxf2rawPath)
        process.arguments = ["--info", url.path]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            try? stdoutPipe.fileHandleForReading.close()
            if let output = String(data: data, encoding: .utf8) {
                return output
            }
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            logger.error("Failed to run mxf2raw: \(error.localizedDescription)")
        }

        return nil
    }

    /// Checks if an MXF file is OP1a compliant
    /// - Parameter url: The MXF file to check
    /// - Returns: true if OP1a, false otherwise or if check failed
    func isOP1a(url: URL) async -> Bool {
        guard let info = await getMXFInfo(url: url) else {
            return false
        }
        // Check for OP1a in the info output
        return info.contains("OP-1a") || info.contains("OP1a")
    }
}

// MARK: - BMX Errors

enum BMXError: Error, LocalizedError {
    case binaryNotFound
    case inputNotFound
    case rewrapFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "BMX tools not found"
        case .inputNotFound:
            return "Input MXF file not found"
        case .rewrapFailed(let message):
            return "MXF rewrap failed: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
}
