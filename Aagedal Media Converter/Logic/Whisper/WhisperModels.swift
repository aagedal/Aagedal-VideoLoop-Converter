// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Available whisper.cpp model sizes
enum WhisperModel: String, CaseIterable, Codable, Sendable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case large = "large"
    case norwegianTiny = "nb_tiny"
    case norwegianSmall = "nb_small"
    case norwegianMedium = "nb_medium"
    case norwegianLarge = "nb_large"
    case swedishBase = "sv_base"
    case swedishSmall = "sv_small"
    case swedishMedium = "sv_medium"
    case swedishLarge = "sv_large"
    case custom = "custom"

    static var allCases: [WhisperModel] {
        [
            .tiny,
            .base,
            .small,
            .medium,
            .large,
            .norwegianTiny,
            .norwegianSmall,
            .norwegianMedium,
            .norwegianLarge,
            .swedishBase,
            .swedishSmall,
            .swedishMedium,
            .swedishLarge,
            .custom
        ]
    }

    static var downloadableCases: [WhisperModel] {
        allCases.filter { $0.isDownloadable }
    }

    var isDownloadable: Bool {
        self != .custom
    }

    var isCustom: Bool {
        self == .custom
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .norwegianTiny: return "Norwegian Tiny (NbAiLab)"
        case .norwegianSmall: return "Norwegian Small (NbAiLab)"
        case .norwegianMedium: return "Norwegian Medium (NbAiLab)"
        case .norwegianLarge: return "Norwegian Large (NbAiLab)"
        case .swedishBase: return "Swedish Base (KBLab)"
        case .swedishSmall: return "Swedish Small (KBLab)"
        case .swedishMedium: return "Swedish Medium (KBLab)"
        case .swedishLarge: return "Swedish Large (KBLab)"
        case .custom: return "Custom"
        }
    }

    /// Model file name (GGML format)
    var fileName: String {
        switch self {
        case .tiny: return "ggml-tiny.bin"
        case .base: return "ggml-base.bin"
        case .small: return "ggml-small.bin"
        case .medium: return "ggml-medium.bin"
        case .large: return "ggml-large-v3.bin"
        case .norwegianTiny: return "ggml-nb-whisper-tiny.bin"
        case .norwegianSmall: return "ggml-nb-whisper-small.bin"
        case .norwegianMedium: return "ggml-nb-whisper-medium.bin"
        case .norwegianLarge: return "ggml-nb-whisper-large.bin"
        case .swedishBase: return "ggml-sv-whisper-base.bin"
        case .swedishSmall: return "ggml-sv-whisper-small.bin"
        case .swedishMedium: return "ggml-sv-whisper-medium.bin"
        case .swedishLarge: return "ggml-sv-whisper-large.bin"
        case .custom: return "custom-model.bin"
        }
    }

    /// Download URL from Hugging Face
    var downloadURL: URL {
        switch self {
        case .norwegianTiny:
            return URL(string: "https://huggingface.co/NbAiLab/nb-whisper-tiny/resolve/main/ggml-model.bin")!
        case .norwegianSmall:
            return URL(string: "https://huggingface.co/NbAiLab/nb-whisper-small/resolve/main/ggml-model.bin")!
        case .norwegianMedium:
            return URL(string: "https://huggingface.co/NbAiLab/nb-whisper-medium/resolve/main/ggml-model.bin")!
        case .norwegianLarge:
            return URL(string: "https://huggingface.co/NbAiLab/nb-whisper-large/resolve/main/ggml-model.bin")!
        case .swedishBase:
            return URL(string: "https://huggingface.co/KBLab/kb-whisper-base/resolve/main/ggml-model.bin")!
        case .swedishSmall:
            return URL(string: "https://huggingface.co/KBLab/kb-whisper-small/resolve/main/ggml-model.bin")!
        case .swedishMedium:
            return URL(string: "https://huggingface.co/KBLab/kb-whisper-medium/resolve/main/ggml-model.bin")!
        case .swedishLarge:
            return URL(string: "https://huggingface.co/KBLab/kb-whisper-large/resolve/main/ggml-model.bin")!
        case .custom:
            return URL(fileURLWithPath: "/")
        default:
            let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
            return URL(string: baseURL + fileName)!
        }
    }

    /// Human-readable file size
    var fileSize: String {
        switch self {
        case .tiny: return "75 MB"
        case .base: return "142 MB"
        case .small: return "466 MB"
        case .medium: return "1.5 GB"
        case .large: return "3.1 GB"
        case .norwegianTiny: return "75 MB"
        case .norwegianSmall: return "466 MB"
        case .norwegianMedium: return "1.5 GB"
        case .norwegianLarge: return "3.1 GB"
        case .swedishBase: return "142 MB"
        case .swedishSmall: return "466 MB"
        case .swedishMedium: return "1.5 GB"
        case .swedishLarge: return "3.1 GB"
        case .custom: return "Custom"
        }
    }

    /// Approximate file size in bytes
    var fileSizeBytes: Int64 {
        switch self {
        case .tiny: return 75_000_000
        case .base: return 142_000_000
        case .small: return 466_000_000
        case .medium: return 1_500_000_000
        case .large: return 3_100_000_000
        case .norwegianTiny: return 75_000_000
        case .norwegianSmall: return 466_000_000
        case .norwegianMedium: return 1_500_000_000
        case .norwegianLarge: return 3_100_000_000
        case .swedishBase: return 142_000_000
        case .swedishSmall: return 466_000_000
        case .swedishMedium: return 1_500_000_000
        case .swedishLarge: return 3_100_000_000
        case .custom: return 0
        }
    }

    /// Description of quality/speed tradeoff
    var description: String {
        switch self {
        case .tiny:
            return "Fastest, lowest accuracy. Good for quick tests."
        case .base:
            return "Fast with reasonable accuracy. Recommended for most uses."
        case .small:
            return "Good balance of speed and accuracy."
        case .medium:
            return "High accuracy, slower processing."
        case .large:
            return "Best accuracy, slowest. Requires significant RAM."
        case .norwegianTiny:
            return "Tiny model optimized for Norwegian. Fastest, lowest accuracy."
        case .norwegianSmall:
            return "Small model optimized for Norwegian. Good balance of speed and accuracy."
        case .norwegianMedium:
            return "Medium model optimized for Norwegian. High accuracy, slower processing."
        case .norwegianLarge:
            return "Large model optimized for Norwegian. Best accuracy, slowest."
        case .swedishBase:
            return "Base model optimized for Swedish. Fast with reasonable accuracy."
        case .swedishSmall:
            return "Small model optimized for Swedish. Good balance of speed and accuracy."
        case .swedishMedium:
            return "Medium model optimized for Swedish. High accuracy, slower processing."
        case .swedishLarge:
            return "Large model optimized for Swedish. Best accuracy, slowest."
        case .custom:
            return "Use a custom GGML model file."
        }
    }

    /// Estimated RAM requirement
    var ramRequirement: String {
        switch self {
        case .tiny: return "~1 GB"
        case .base: return "~1 GB"
        case .small: return "~2 GB"
        case .medium: return "~5 GB"
        case .large: return "~10 GB"
        case .norwegianTiny: return "~1 GB"
        case .norwegianSmall: return "~2 GB"
        case .norwegianMedium: return "~5 GB"
        case .norwegianLarge: return "~10 GB"
        case .swedishBase: return "~1 GB"
        case .swedishSmall: return "~2 GB"
        case .swedishMedium: return "~5 GB"
        case .swedishLarge: return "~10 GB"
        case .custom: return "Varies"
        }
    }
}

/// Installation status for whisper.cpp binary
enum WhisperInstallationStatus: Sendable, Equatable {
    case notInstalled
    case installed(version: String)
    case updateAvailable(current: String, latest: String)

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .installed, .updateAvailable:
            return true
        }
    }

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .installed(let version):
            return "Installed (v\(version))"
        case .updateAvailable(let current, let latest):
            return "Update available: v\(current) → v\(latest)"
        }
    }
}

/// Model download status
enum WhisperModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(String)

    var isDownloaded: Bool {
        if case .downloaded = self { return true }
        return false
    }
}

/// Configuration for subtitle generation
struct WhisperGenerationConfig: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var model: WhisperModel = .base
    var language: String = "auto"

    static let `default` = WhisperGenerationConfig()
}

/// Progress information during subtitle generation
struct WhisperProgress: Sendable {
    var stage: WhisperProgressStage
    var percentage: Double
    var message: String?
}

/// Stages of subtitle generation
enum WhisperProgressStage: Sendable, Equatable {
    case extractingAudio
    case transcribing
    case writingSRT
    case complete
    case failed(String)

    var displayText: String {
        switch self {
        case .extractingAudio:
            return "Extracting audio..."
        case .transcribing:
            return "Transcribing..."
        case .writingSRT:
            return "Writing SRT..."
        case .complete:
            return "Complete"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Subtitle generation status for VideoItem
enum SubtitleStatus: Equatable, Sendable {
    case notQueued
    case pending
    case extractingAudio
    case generating(progress: Double)
    case embedding
    case completed
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .pending, .extractingAudio, .generating, .embedding:
            return true
        default:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .notQueued:
            return ""
        case .pending:
            return "Pending"
        case .extractingAudio:
            return "Extracting audio"
        case .generating(let progress):
            return "Generating \(Int(progress * 100))%"
        case .embedding:
            return "Embedding subtitles"
        case .completed:
            return "Done"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Supported whisper language codes
enum WhisperLanguage: String, CaseIterable, Sendable {
    case auto = "auto"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case japanese = "ja"
    case chinese = "zh"
    case korean = "ko"
    case russian = "ru"
    case arabic = "ar"
    case hindi = "hi"
    case norwegian = "no"
    case swedish = "sv"
    case danish = "da"
    case finnish = "fi"
    case polish = "pl"
    case turkish = "tr"
    case greek = "el"
    case hebrew = "he"
    case thai = "th"
    case vietnamese = "vi"
    case indonesian = "id"
    case malay = "ms"
    case czech = "cs"
    case romanian = "ro"
    case hungarian = "hu"
    case ukrainian = "uk"

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .dutch: return "Dutch"
        case .japanese: return "Japanese"
        case .chinese: return "Chinese"
        case .korean: return "Korean"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .hindi: return "Hindi"
        case .norwegian: return "Norwegian"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .finnish: return "Finnish"
        case .polish: return "Polish"
        case .turkish: return "Turkish"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .thai: return "Thai"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        case .malay: return "Malay"
        case .czech: return "Czech"
        case .romanian: return "Romanian"
        case .hungarian: return "Hungarian"
        case .ukrainian: return "Ukrainian"
        }
    }
}
