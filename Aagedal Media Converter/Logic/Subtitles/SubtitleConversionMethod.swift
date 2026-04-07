// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The method used to convert a video's subtitle track to SRT
enum SubtitleConversionMethod: String, Sendable, Equatable {
    /// AI audio transcription via whisper.cpp (speech → text)
    case whisper
    /// Optical character recognition via Tesseract (bitmap images → text)
    case ocr
}
