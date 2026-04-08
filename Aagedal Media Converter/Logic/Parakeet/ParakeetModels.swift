// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Available parakeet-mlx models from HuggingFace
struct ParakeetModel: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let description: String
    let fileSize: String
    let fileSizeBytes: Int64
    let isMultilingual: Bool

    /// All known parakeet-mlx models
    static let allModels: [ParakeetModel] = [
        ParakeetModel(
            id: "mlx-community/parakeet-tdt-0.6b-v2",
            displayName: "Parakeet TDT 0.6B v2 (English)",
            description: "Best English accuracy (6.05% WER). Fast on Apple Silicon.",
            fileSize: "~2.5 GB",
            fileSizeBytes: 2_500_000_000,
            isMultilingual: false
        ),
        ParakeetModel(
            id: "mlx-community/parakeet-tdt-0.6b-v3",
            displayName: "Parakeet TDT 0.6B v3 (Multilingual)",
            description: "25 European languages including Norwegian and Swedish. Recommended.",
            fileSize: "~2.5 GB",
            fileSizeBytes: 2_500_000_000,
            isMultilingual: true
        ),
        ParakeetModel(
            id: "mlx-community/parakeet-tdt_ctc-110m",
            displayName: "Parakeet TDT-CTC 110M (English)",
            description: "Smallest and fastest model. Good for quick tests.",
            fileSize: "~459 MB",
            fileSizeBytes: 459_000_000,
            isMultilingual: false
        ),
        ParakeetModel(
            id: "mlx-community/parakeet-tdt-1.1b",
            displayName: "Parakeet TDT 1.1B (English)",
            description: "Largest model with highest accuracy. Requires significant RAM.",
            fileSize: "~4.3 GB",
            fileSizeBytes: 4_300_000_000,
            isMultilingual: false
        ),
    ]

    /// Find a model by its HuggingFace ID
    static func model(for id: String) -> ParakeetModel? {
        allModels.first { $0.id == id }
    }
}

/// Installation status for parakeet-mlx binary
enum ParakeetInstallationStatus: Sendable, Equatable {
    case notInstalled
    case installed(version: String)

    var isAvailable: Bool {
        if case .installed = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .installed(let version):
            return "Installed (\(version))"
        }
    }
}

/// Model download/cache status
enum ParakeetModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading
    case downloaded

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }
}

/// Supported languages for multilingual Parakeet models (v3)
enum ParakeetLanguage: String, CaseIterable, Sendable {
    case auto = "auto"
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case polish = "pl"
    case portuguese = "pt"
    case dutch = "nl"
    case catalan = "ca"
    case czech = "cs"
    case danish = "da"
    case finnish = "fi"
    case galician = "gl"
    case hungarian = "hu"
    case latvian = "lv"
    case lithuanian = "lt"
    case norwegian = "no"
    case romanian = "ro"
    case slovak = "sk"
    case slovenian = "sl"
    case swedish = "sv"
    case turkish = "tr"
    case ukrainian = "uk"
    case estonian = "et"
    case croatian = "hr"

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .german: return "German"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .italian: return "Italian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .catalan: return "Catalan"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .finnish: return "Finnish"
        case .galician: return "Galician"
        case .hungarian: return "Hungarian"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .norwegian: return "Norwegian"
        case .romanian: return "Romanian"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .swedish: return "Swedish"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .estonian: return "Estonian"
        case .croatian: return "Croatian"
        }
    }
}

/// Progress information during Parakeet subtitle generation
struct ParakeetProgress: Sendable {
    var stage: ParakeetProgressStage
    var percentage: Double
    var message: String?
}

/// Stages of Parakeet subtitle generation
enum ParakeetProgressStage: Sendable, Equatable {
    case extractingAudio
    case transcribing
    case complete
    case failed(String)

    var displayText: String {
        switch self {
        case .extractingAudio:
            return "Extracting audio..."
        case .transcribing:
            return "Transcribing..."
        case .complete:
            return "Complete"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}
