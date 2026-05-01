// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// OCR backend that shells out to the Tesseract binary (bundled, Homebrew, or custom).
struct TesseractOCREngine: BitmapSubtitleOCREngine {
    let tesseractPath: String
    let tessdataPrefix: String?

    func recognize(pngURL: URL, language: String) async throws -> String {
        try Task.checkCancellation()

        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tesseractPath)
        process.arguments = [pngURL.path, "stdout", "--psm", "6", "-l", language]
        process.standardOutput = stdoutPipe
        // Suppress TIFF-absent warnings from the PNG-only bundled build.
        process.standardError = FileHandle.nullDevice
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
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    // Non-zero on a single frame is non-fatal — return empty (matches prior behavior).
                    return ""
                }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            }.value
        } onCancel: {
            process.terminate()
        }
    }
}

enum TesseractOCREngineError: Error, LocalizedError {
    case processStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .processStartFailed(let msg): return "Failed to launch tesseract: \(msg)"
        }
    }
}
