// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Sparkle
import SwiftUI

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` so the rest of
/// the app can interact with the updater through one stable handle and
/// pre-flight checks. Two gates decide whether the updater actually runs:
///
/// 1. **Install source** — Homebrew installs use the in-app `UpdateChecker`
///    (notify, route to `brew upgrade`) so Sparkle never replaces a bundle
///    brew thinks it manages.
/// 2. **Sparkle configuration** — if `SUFeedURL` isn't present in Info.plist,
///    Sparkle has nothing to talk to. We avoid starting the updater so the
///    console doesn't fill with misconfiguration warnings during development.
///
/// Both gates fail closed: `isActive == false` means the updater object still
/// exists (so SwiftUI bindings compile), but `startingUpdater` was `false` and
/// no checks will fire.
@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()

    let controller: SPUStandardUpdaterController

    /// True when Sparkle is actually polling and able to install updates.
    /// False for Homebrew installs or when SUFeedURL is unset.
    let isActive: Bool

    private init() {
        let hasFeedURL = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .isEmpty == false
        let isDirectInstall = InstallSource.current == .directDownload
        let active = hasFeedURL && isDirectInstall

        self.isActive = active
        self.controller = SPUStandardUpdaterController(
            startingUpdater: active,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { controller.updater }
}
