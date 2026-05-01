// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Vision
import OSLog

/// OCR backend that uses Apple's Vision framework (`VNRecognizeTextRequest`).
///
/// No external binary or model file required — runs entirely on the system
/// frameworks shipped with macOS 15+. Typically faster and more accurate than
/// Tesseract for printed Latin-script text.
struct VisionOCREngine: BitmapSubtitleOCREngine {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VisionOCREngine")

    /// Whether Vision should apply language-model post-correction. On for accuracy.
    var usesLanguageCorrection: Bool = true

    func recognize(pngURL: URL, language: String) async throws -> String {
        try Task.checkCancellation()

        let recognitionLanguages = Self.recognitionLanguages(for: language)
        let useCorrection = usesLanguageCorrection

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            // Vision request handlers are blocking — hop to a background queue.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = useCorrection
                if !recognitionLanguages.isEmpty {
                    request.recognitionLanguages = recognitionLanguages
                }

                let handler = VNImageRequestHandler(url: pngURL, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results ?? [])
                let text = Self.assemble(observations: observations)
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - Helpers

    /// Joins observation strings in top-to-bottom, left-to-right reading order so
    /// multi-line subtitles come out as one string with line breaks preserved.
    private static func assemble(observations: [VNRecognizedTextObservation]) -> String {
        // Sort by Y descending (Vision uses bottom-left origin, so larger Y = higher on screen).
        // Within roughly the same line, sort by X ascending.
        let lineTolerance: CGFloat = 0.02
        let sorted = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) < lineTolerance {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return dy > 0  // higher Y first → top of frame first
        }
        let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// Maps a tessdata-style language code (eng / nor / jpn / …) to one or more
    /// BCP-47 language codes that Vision understands. Falls back to letting Vision
    /// auto-detect when the code is unknown.
    private static func recognitionLanguages(for language: String) -> [String] {
        let key = language.lowercased()
        let mapped = Self.languageMap[key]
        if let mapped { return mapped }
        // If the caller already passed a BCP-47-ish code (contains a hyphen or is 2 chars), trust it.
        if key.contains("-") || key.count == 2 {
            return [language]
        }
        return []
    }

    /// Tessdata code → preferred Vision (BCP-47) codes. Order matters: first entry
    /// is the primary recognition language, additional entries are fallbacks.
    private static let languageMap: [String: [String]] = [
        "eng":     ["en-US"],
        "nor":     ["nb-NO", "nn-NO"],
        "nob":     ["nb-NO"],
        "nno":     ["nn-NO"],
        "dan":     ["da-DK"],
        "swe":     ["sv-SE"],
        "isl":     ["is-IS"],
        "fin":     ["fi-FI"],
        "deu":     ["de-DE"],
        "ger":     ["de-DE"],
        "fra":     ["fr-FR"],
        "fre":     ["fr-FR"],
        "spa":     ["es-ES"],
        "ita":     ["it-IT"],
        "por":     ["pt-BR", "pt-PT"],
        "nld":     ["nl-NL"],
        "dut":     ["nl-NL"],
        "rus":     ["ru-RU"],
        "ukr":     ["uk-UA"],
        "pol":     ["pl-PL"],
        "ces":     ["cs-CZ"],
        "cze":     ["cs-CZ"],
        "hun":     ["hu-HU"],
        "ron":     ["ro-RO"],
        "rum":     ["ro-RO"],
        "tur":     ["tr-TR"],
        "ell":     ["el-GR"],
        "gre":     ["el-GR"],
        "jpn":     ["ja-JP"],
        "kor":     ["ko-KR"],
        "chi_sim": ["zh-Hans"],
        "chi_tra": ["zh-Hant"],
        "tha":     ["th-TH"],
        "vie":     ["vi-VN"],
        "ara":     ["ar-SA"],
        "heb":     ["he-IL"],
    ]

    // MARK: - Public language discovery (used by the settings UI)

    /// Languages currently supported by Vision's text recognizer at the highest revision.
    /// Returns BCP-47 codes (e.g. "en-US"). Empty if Vision is unavailable.
    static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            return try request.supportedRecognitionLanguages()
        } catch {
            logger.warning("Vision supportedRecognitionLanguages failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}
