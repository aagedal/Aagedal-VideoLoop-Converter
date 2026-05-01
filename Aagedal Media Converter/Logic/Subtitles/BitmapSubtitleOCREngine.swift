// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// OCR backend used to convert bitmap subtitle frames (PGS / VOBSUB images) to text.
///
/// Concrete engines:
///   - `TesseractOCREngine`  — bundled or system Tesseract binary, called as a subprocess.
///   - `VisionOCREngine`     — Apple's `VNRecognizeTextRequest`, no external dependency.
///
/// To add a new engine: implement this protocol, add a case to `OCREngineKind`,
/// and a branch in `TesseractService.makeOCREngine()`.
protocol BitmapSubtitleOCREngine: Sendable {
    /// Recognise text in a single PNG subtitle frame.
    ///
    /// - Parameter pngURL: PNG file produced by the PGS / VOBSUB parser.
    /// - Parameter language: Tessdata-style ISO 639-2 code (e.g. "eng", "nor").
    ///   Engines that use a different code system (e.g. Vision's BCP-47) map internally.
    /// - Returns: Recognised text, or empty string when nothing was detected.
    /// - Throws: Cancels via `Task.checkCancellation()`; engine-specific failures bubble up.
    func recognize(pngURL: URL, language: String) async throws -> String
}

/// User-facing OCR engine choice, persisted in UserDefaults under
/// `AppConstants.ocrEngineKey`.
enum OCREngineKind: String, CaseIterable, Sendable {
    case tesseract
    case appleVision

    /// Display name for the settings picker.
    var displayName: String {
        switch self {
        case .tesseract:   return "Tesseract"
        case .appleVision: return "Apple Vision"
        }
    }

    /// Reads the user's preferred engine, falling back to the default if unset/invalid.
    static var userPreferred: OCREngineKind {
        let raw = UserDefaults.standard.string(forKey: AppConstants.ocrEngineKey)
            ?? AppConstants.defaultOCREngine
        return OCREngineKind(rawValue: raw) ?? .tesseract
    }
}
