// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// OCR backend that shells out to the Tesseract binary (bundled, Homebrew, or custom).
struct TesseractOCREngine: BitmapSubtitleOCREngine {
    let tesseractPath: String
    let tessdataPrefix: String?

    /// Hard cap per frame. A misbehaving tesseract that wedges shouldn't be able to hang the whole queue.
    private static let perFrameTimeoutSeconds: UInt64 = 10

    func recognize(pngURL: URL, language: String) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = [pngURL.path, "stdout", "--psm", "6", "-l", language]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        if let tessdataPrefix {
            env["TESSDATA_PREFIX"] = tessdataPrefix
        }
        process.environment = env

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                do {
                    try process.run()
                } catch {
                    throw TesseractOCREngineError.processStartFailed(error.localizedDescription)
                }

                // Hard timeout: terminate the process if it overruns. Cancelled below if the
                // process exits on its own first.
                let timeoutTask = Task.detached(priority: .utility) {
                    try? await Task.sleep(nanoseconds: Self.perFrameTimeoutSeconds * 1_000_000_000)
                    if process.isRunning { process.terminate() }
                }

                // Drain stderr concurrently. The 64KB pipe buffer can fill if tesseract prints
                // a lot of warnings, which would deadlock waitUntilExit.
                let stderrDrain = Task.detached(priority: .utility) {
                    stderrPipe.fileHandleForReading.readDataToEndOfFile()
                }

                process.waitUntilExit()
                timeoutTask.cancel()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = await stderrDrain.value

                guard process.terminationStatus == 0 else {
                    let stderrText = String(data: stderrData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw TesseractOCREngineError.processFailed(
                        exitCode: process.terminationStatus,
                        stderr: String(stderrText.suffix(300))
                    )
                }
                return String(data: stdoutData, encoding: .utf8) ?? ""
            }.value
        } onCancel: {
            process.terminate()
        }
    }
}

enum TesseractOCREngineError: Error, LocalizedError {
    case processStartFailed(String)
    case processFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .processStartFailed(let msg):
            return "Failed to launch tesseract: \(msg)"
        case .processFailed(let code, let stderr):
            return stderr.isEmpty
                ? "tesseract exited \(code)"
                : "tesseract exited \(code): \(stderr)"
        }
    }
}
