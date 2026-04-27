// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

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

    private let releasesAPIURL = URL(string: "https://api.github.com/repos/aagedal/Aagedal-Media-Converter/releases/latest")!
    private let fallbackReleasesPageURL = URL(string: "https://github.com/aagedal/Aagedal-Media-Converter/releases/latest")!

    private init() {}

    func checkForUpdatesIfNeeded() {
        guard checkForUpdates else { return }

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
        isChecking = true
        defer { isChecking = false }

        var request = URLRequest(url: releasesAPIURL)
        request.setValue(GitHubRequest.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let delegate = GitHubRedirectGuard()
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
}
