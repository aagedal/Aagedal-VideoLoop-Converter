// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import OSLog

/// Lightweight helper for playing short UI feedback sounds (success + error).
@MainActor
final class SoundManager {
    static let shared = SoundManager()
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "SoundManager")

    private let successSound: NSSound?
    private let errorSound: NSSound?

    private init() {
        successSound = SoundManager.loadSound(named: "done", fileExtension: "mp3")
        errorSound = SoundManager.loadSound(named: "error", fileExtension: "mp3")
    }

    func playSuccess() {
        guard UserDefaults.standard.object(forKey: AppConstants.playSoundOnSuccessKey) as? Bool ?? AppConstants.defaultPlaySoundOnSuccess else { return }
        successSound?.stop()
        successSound?.play()
    }

    func playError() {
        guard UserDefaults.standard.object(forKey: AppConstants.playSoundOnErrorKey) as? Bool ?? AppConstants.defaultPlaySoundOnError else { return }
        errorSound?.stop()
        errorSound?.play()
    }

    private static func loadSound(named name: String, fileExtension: String) -> NSSound? {
        let bundle = Bundle.main
        let url = bundle.url(forResource: name, withExtension: fileExtension)
            ?? bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Sounds")

        guard let resolvedURL = url else {
            logger.error("Missing sound resource: \(name, privacy: .public).\(fileExtension, privacy: .public)")
            return nil
        }

        return NSSound(contentsOf: resolvedURL, byReference: true)
    }
}
