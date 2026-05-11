// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where this copy of the app was installed from.
///
/// Used to keep the in-app updater (and, after the migration, Sparkle) out of
/// the way for Homebrew-managed installs — those users should run
/// `brew upgrade --cask aagedal-media-converter` instead, otherwise an
/// in-app update would replace the bundle that brew thinks it manages and
/// cause a checksum mismatch on the next `brew upgrade`.
enum InstallSource: Equatable {
    case homebrew
    case directDownload

    /// Detects how this copy was installed. Cached after the first call —
    /// the answer can't change without restarting the app.
    static let current: InstallSource = detect()

    private static func detect() -> InstallSource {
        // Case 1: the running bundle resolves to a path under Caskroom. This
        // happens when a cask is installed without the `pkg_destination`
        // strategy (i.e. brew left the .app inside Caskroom and put a symlink
        // in /Applications).
        let resolvedBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if resolvedBundlePath.contains("/Caskroom/") {
            return .homebrew
        }

        // Case 2: the .app was moved to /Applications by brew but the
        // Caskroom metadata directory still exists for this cask. This is
        // the default cask install strategy on modern Homebrew.
        let caskMetadataPaths = [
            "/opt/homebrew/Caskroom/aagedal-media-converter",   // Apple Silicon
            "/usr/local/Caskroom/aagedal-media-converter"        // Intel
        ]
        for path in caskMetadataPaths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return .homebrew
            }
        }

        return .directDownload
    }
}
