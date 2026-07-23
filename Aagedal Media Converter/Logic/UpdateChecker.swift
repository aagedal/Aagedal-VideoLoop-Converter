// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Update checker for the two cases Sparkle deliberately does not handle:
//   1. Homebrew-installed copies — Sparkle would replace the bundle that brew
//      thinks it manages. This checker fetches the latest release info from
//      GitHub and the UI routes the user to `brew upgrade --cask …`.
//   2. Bridge users coming from the pre-Sparkle releases — their old build
//      still polls this checker (now pointed at GitHub) and shows the
//      in-app banner so they can manually install the first Sparkle-enabled
//      release.
//
// Gated off whenever `SparkleUpdater.shared.isActive` is true, so direct-
// download users on the Sparkle-enabled build get exactly one update path.

import Foundation
import OSLog
import SwiftUI

enum UpdateCheckFrequency: String, CaseIterable, Identifiable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"

    var id: String { self.rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .daily: return 86400 // 24 * 60 * 60
        case .weekly: return 604800 // 7 * 24 * 60 * 60
        case .monthly: return 2592000 // 30 * 24 * 60 * 60 (approx)
        }
    }
}

@MainActor
class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "UpdateChecker")

    @AppStorage(AppConstants.checkForUpdatesKey) private var checkForUpdates = true
    @AppStorage(AppConstants.updateCheckFrequencyKey) private var checkFrequencyRaw = UpdateCheckFrequency.weekly.rawValue
    @AppStorage(AppConstants.lastUpdateCheckDateKey) private var lastUpdateCheckDate: Double = 0

    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String = ""
    @Published var releaseNotesURL: URL? = nil
    @Published var downloadAssetURL: URL? = nil
    @Published var isChecking: Bool = false

    /// True when this app was installed via Homebrew. The checker still
    /// fetches the release feed and reports `updateAvailable`, but the UI
    /// branches: brew users get the `brew upgrade --cask …` command instead
    /// of a Download button, so we don't replace a bundle brew thinks it
    /// manages.
    let isHomebrewInstall: Bool = (InstallSource.current == .homebrew)

    /// The shell command shown to Homebrew-managed users when an update
    /// exists. Single source of truth for the Settings hint and the banner.
    static let homebrewUpgradeCommand = "brew upgrade --cask aagedal-media-converter"

    private let releasesAPIURL = URL(string: "https://api.github.com/repos/aagedal/Aagedal-Media-Converter/releases/latest")!
    private let fallbackReleasesPageURL = URL(string: "https://github.com/aagedal/Aagedal-Media-Converter/releases/latest")!

    private init() {}

    func checkForUpdatesIfNeeded() {
        guard checkForUpdates else { return }
        guard !SparkleUpdater.shared.isActive else { return }

        let lastCheck = Date(timeIntervalSince1970: lastUpdateCheckDate)
        let frequency = UpdateCheckFrequency(rawValue: checkFrequencyRaw) ?? .weekly

        if Date().timeIntervalSince(lastCheck) >= frequency.timeInterval {
            Task {
                await performUpdateCheck(isUserInitiated: false)
            }
        }
    }

    func performUpdateCheck(isUserInitiated: Bool) async {
        guard !isChecking else { return }
        guard !SparkleUpdater.shared.isActive else { return }
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: releasesAPIURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let delegate = GitHubReleasesRedirectGuard()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                Self.logger.error("Update check returned non-200 status")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawTag = json["tag_name"] as? String else {
                Self.logger.error("Update check could not parse tag_name from release JSON")
                return
            }

            let remoteVersion = normalizeVersion(rawTag)
            let notesURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let assetURL = pickDownloadAsset(from: json["assets"] as? [[String: Any]] ?? [])

            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

            self.latestVersion = remoteVersion
            self.releaseNotesURL = notesURL
            self.downloadAssetURL = assetURL
            self.updateAvailable = isVersion(remoteVersion, newerThan: currentVersion)

            if !isUserInitiated {
                self.lastUpdateCheckDate = Date().timeIntervalSince1970
            }
        } catch {
            Self.logger.error("Error checking for updates: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// GitHub release tags may be prefixed with `v` (e.g. "v4.0.0"). The numeric comparator
    /// in `isVersion(_:newerThan:)` and the bundle's `CFBundleShortVersionString` are both bare
    /// numeric strings, so strip the prefix to keep the comparison consistent.
    private func normalizeVersion(_ tag: String) -> String {
        if tag.hasPrefix("v") || tag.hasPrefix("V") {
            return String(tag.dropFirst())
        }
        return tag
    }

    /// Picks the user-facing download asset from a GitHub release. Prefers `.zip` (current
    /// distribution format) and falls back to `.dmg` so a future packaging change doesn't break
    /// the in-app updater silently.
    private func pickDownloadAsset(from assets: [[String: Any]]) -> URL? {
        let candidates: [(name: String, url: URL)] = assets.compactMap { asset in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString) else {
                return nil
            }
            return (name, url)
        }

        if let zip = candidates.first(where: { $0.name.lowercased().hasSuffix(".zip") }) {
            return zip.url
        }
        if let dmg = candidates.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return dmg.url
        }
        return nil
    }

    private func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        return v1.compare(v2, options: .numeric) == .orderedDescending
    }

    func openDownloadAsset() {
        NSWorkspace.shared.open(downloadAssetURL ?? fallbackReleasesPageURL)
    }

    func openReleaseNotes() {
        NSWorkspace.shared.open(releaseNotesURL ?? fallbackReleasesPageURL)
    }

    private static let userAgent: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aagedal.MediaConverter"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "\(bundleID)/\(version)"
    }()
}

// MARK: - GitHub redirect guard

/// Refuses HTTP redirects away from GitHub's API host. A cross-host redirect
/// indicates either a hijack or a misconfigured request and is rejected.
private final class GitHubReleasesRedirectGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host?.lowercased() else {
            completionHandler(nil)
            return
        }
        if host == "api.github.com" {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
