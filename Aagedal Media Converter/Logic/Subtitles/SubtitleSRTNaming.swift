// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Engine-discriminating suffix for an SRT filename. Keeps OCR, Whisper, and Parakeet
/// outputs from clobbering each other when more than one is run on the same source.
enum SubtitleSRTMethod: String {
    case ocr
    case whisper
    case parakeet
}

enum SubtitleSRTNaming {
    /// Decides where to write an engine's SRT.
    ///
    /// - First time any engine produces an SRT for a given basename: returns the bare
    ///   `<base>.srt`, preserving the long-standing naming users expect.
    /// - Once a bare `<base>.srt` exists, subsequent runs from a *different* engine
    ///   write to `<base>.<method>.srt` instead — so a user who runs both OCR and
    ///   Whisper ends up with `Movie.srt` plus `Movie.ocr.srt` (or vice-versa) rather
    ///   than the second engine silently overwriting the first.
    /// - Re-running the same engine that owns the bare file simply overwrites it.
    static func outputURL(
        directory: URL,
        baseName: String,
        method: SubtitleSRTMethod
    ) -> URL {
        let bare = directory.appendingPathComponent(baseName + ".srt")
        let suffixed = directory.appendingPathComponent("\(baseName).\(method.rawValue).srt")

        let fm = FileManager.default
        if fm.fileExists(atPath: suffixed.path) {
            // We already own a method-suffixed file from a previous run — keep using it.
            return suffixed
        }
        if fm.fileExists(atPath: bare.path) {
            // The bare slot is taken. Best-effort guess: if the existing bare file is
            // ours (this method's previous run), overwrite it. Otherwise step aside.
            return ownsBareFile(bare, method: method) ? bare : suffixed
        }
        return bare
    }

    /// Heuristic: a bare `<base>.srt` is considered "owned" by `method` only if no
    /// suffixed file from a *different* engine sits next to it. If a sibling like
    /// `<base>.whisper.srt` exists, it strongly implies the bare one belongs to a
    /// different engine and we shouldn't trample it.
    private static func ownsBareFile(_ bare: URL, method: SubtitleSRTMethod) -> Bool {
        let directory = bare.deletingLastPathComponent()
        let baseName = bare.deletingPathExtension().lastPathComponent
        for other in SubtitleSRTMethod.allCases where other != method {
            let sibling = directory.appendingPathComponent("\(baseName).\(other.rawValue).srt")
            if FileManager.default.fileExists(atPath: sibling.path) {
                return false
            }
        }
        return true
    }
}

extension SubtitleSRTMethod: CaseIterable {}
