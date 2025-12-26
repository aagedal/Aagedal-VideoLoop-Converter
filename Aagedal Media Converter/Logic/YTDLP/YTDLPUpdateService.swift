// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages yt-dlp binary resolution with priority: custom path > downloaded > bundled
actor YTDLPUpdateService {
    static let shared = YTDLPUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "YTDLPUpdate")

    /// Path to bundled yt-dlp binary in app bundle
    /// Note: We don't bundle yt-dlp anymore because PyInstaller binaries
    /// don't work with Hardened Runtime (semctl blocked). Users should
    /// install via Homebrew: brew install yt-dlp
    var bundledPath: String? {
        nil
    }

    /// Path to downloaded yt-dlp binary in Application Support
    var downloadedPath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("yt-dlp")
    }

    /// Path to version file for downloaded binary
    private var versionFilePath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("version.txt")
    }

    /// Returns the path to the best available yt-dlp binary
    /// Priority: 1) Custom path, 2) Downloaded, 3) Bundled
    func resolveYTDLPPath() -> String? {
        // First, check user-provided custom path
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.ytdlpCustomPathKey),
           !customPath.isEmpty {
            // Trust the user's selection - just check if file exists
            // (isExecutableFile can fail for scripts with shebangs)
            if FileManager.default.fileExists(atPath: customPath) {
                logger.info("Using custom yt-dlp at: \(customPath)")
                return customPath
            } else {
                logger.warning("Custom yt-dlp path no longer exists: \(customPath)")
            }
        }

        // Check if downloaded version exists and is executable
        let downloadedPathString = downloadedPath.path
        let fileExists = FileManager.default.fileExists(atPath: downloadedPathString)
        var isExecutable = FileManager.default.isExecutableFile(atPath: downloadedPathString)
        logger.debug("Checking downloaded path: \(downloadedPathString), exists: \(fileExists), executable: \(isExecutable)")

        // If file exists but isn't executable, try to fix permissions
        if fileExists && !isExecutable {
            logger.info("Fixing executable permissions for downloaded yt-dlp")
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloadedPathString)
            isExecutable = FileManager.default.isExecutableFile(atPath: downloadedPathString)
            logger.debug("After chmod: executable: \(isExecutable)")
        }

        // Use file exists check as fallback - isExecutableFile can be overly strict
        if fileExists {
            logger.info("Using downloaded yt-dlp at: \(downloadedPathString)")
            return downloadedPathString
        }

        // Fall back to bundled version (may not work due to PyInstaller/semaphore issues)
        if let bundled = bundledPath,
           FileManager.default.isExecutableFile(atPath: bundled) {
            logger.info("Using bundled yt-dlp at: \(bundled)")
            return bundled
        }

        logger.warning("No yt-dlp binary available")
        return nil
    }

    // MARK: - Custom Path Management

    /// Saves a custom yt-dlp path
    func saveCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppConstants.ytdlpCustomPathKey)
        logger.info("Saved custom yt-dlp path: \(path)")
    }

    /// Gets the custom yt-dlp path
    nonisolated func getCustomPath() -> String? {
        UserDefaults.standard.string(forKey: AppConstants.ytdlpCustomPathKey)
    }

    /// Clears the custom yt-dlp path
    func clearCustomPath() {
        UserDefaults.standard.removeObject(forKey: AppConstants.ytdlpCustomPathKey)
        logger.info("Cleared custom yt-dlp path")
    }

    /// Checks if yt-dlp is available
    func isYTDLPAvailable() -> Bool {
        resolveYTDLPPath() != nil
    }

    /// Downloads yt-dlp if not already installed
    /// Returns true if yt-dlp is available after this call
    func ensureYTDLPInstalled() async -> Bool {
        // Check if already available
        if resolveYTDLPPath() != nil {
            return true
        }

        logger.info("No yt-dlp found, attempting to download...")

        do {
            try await downloadUpdate()
            return resolveYTDLPPath() != nil
        } catch {
            logger.error("Failed to auto-download yt-dlp: \(error.localizedDescription)")
            return false
        }
    }

    /// Gets the current installation status
    func getInstallationStatus() -> YTDLPInstallationStatus {
        // Check custom path
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.ytdlpCustomPathKey),
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return .customPath(customPath)
        }

        // Check downloaded version (use fileExists, not isExecutableFile - permissions can be tricky)
        let downloadedPathString = downloadedPath.path
        if FileManager.default.fileExists(atPath: downloadedPathString) {
            let version = UserDefaults.standard.string(forKey: AppConstants.ytdlpVersionKey)
            return .downloaded(version: version)
        }

        // Check common homebrew paths
        let homebrewPaths = [
            "/opt/homebrew/bin/yt-dlp",  // Apple Silicon
            "/usr/local/bin/yt-dlp"       // Intel
        ]
        for path in homebrewPaths {
            if FileManager.default.fileExists(atPath: path) {
                return .homebrewAvailable(path)
            }
        }

        return .notInstalled
    }

    /// Gets the version of the currently active yt-dlp binary
    func getCurrentVersion() async -> String? {
        guard let ytdlpPath = resolveYTDLPPath() else { return nil }

        let process = Process()
        let pipe = Pipe()

        // Configure process for Homebrew Python or regular executable
        HomebrewPythonExecutor.configureProcess(process, scriptPath: ytdlpPath, arguments: ["--version"])
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return version
            }
        } catch {
            logger.error("Failed to get yt-dlp version: \(error.localizedDescription)")
        }

        return nil
    }

    /// Checks GitHub for the latest yt-dlp release version
    func getLatestReleaseVersion() async throws -> (version: String, downloadURL: URL)? {
        guard let url = URL(string: AppConstants.ytdlpGitHubReleasesURL) else {
            throw YTDLPUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YTDLPUpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw YTDLPUpdateError.parseError
        }

        // Find the macOS asset
        for asset in assets {
            if let name = asset["name"] as? String,
               name == AppConstants.ytdlpMacOSAssetName,
               let downloadURLString = asset["browser_download_url"] as? String,
               let downloadURL = URL(string: downloadURLString) {
                return (version: tagName, downloadURL: downloadURL)
            }
        }

        throw YTDLPUpdateError.assetNotFound
    }

    /// Checks if an update is available
    func checkForUpdates() async -> Bool {
        do {
            guard let currentVersion = await getCurrentVersion(),
                  let (latestVersion, _) = try await getLatestReleaseVersion() else {
                return false
            }

            let isNewer = latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
            logger.info("Current: \(currentVersion), Latest: \(latestVersion), Update available: \(isNewer)")
            return isNewer
        } catch {
            logger.error("Failed to check for updates: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and installs the latest yt-dlp release
    func downloadUpdate() async throws {
        guard let (version, downloadURL) = try await getLatestReleaseVersion() else {
            throw YTDLPUpdateError.assetNotFound
        }

        logger.info("Downloading yt-dlp \(version) from \(downloadURL)")

        // Download the binary
        let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YTDLPUpdateError.downloadFailed
        }

        // Move to final location
        let fm = FileManager.default
        let destinationPath = downloadedPath
        let destinationDir = destinationPath.deletingLastPathComponent()

        logger.info("Tools directory: \(destinationDir.path)")
        logger.info("Destination file: \(destinationPath.path)")

        // Ensure destination directory exists
        do {
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
            logger.info("Created/verified tools directory")
        } catch {
            logger.error("Failed to create tools directory: \(error.localizedDescription)")
            throw YTDLPUpdateError.installFailed
        }

        logger.info("Installing yt-dlp to: \(destinationPath.path)")

        // Remove existing file if present
        if fm.fileExists(atPath: destinationPath.path) {
            try fm.removeItem(at: destinationPath)
        }

        try fm.moveItem(at: tempURL, to: destinationPath)

        // Verify file exists after move
        guard fm.fileExists(atPath: destinationPath.path) else {
            logger.error("File not found after move!")
            throw YTDLPUpdateError.installFailed
        }

        // Remove quarantine attribute (critical for sandbox)
        removeQuarantine(at: destinationPath.path)

        // Set executable permission
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath.path)

        // Verify file is executable
        let isExec = fm.isExecutableFile(atPath: destinationPath.path)
        logger.info("File exists: true, isExecutable: \(isExec)")

        // Save version info
        try version.write(to: versionFilePath, atomically: true, encoding: .utf8)

        // Update last check date
        UserDefaults.standard.set(Date(), forKey: AppConstants.ytdlpLastUpdateCheckKey)
        UserDefaults.standard.set(version, forKey: AppConstants.ytdlpVersionKey)

        logger.info("Successfully installed yt-dlp \(version) at \(destinationPath.path)")
    }

    /// Removes the quarantine extended attribute from a file
    private func removeQuarantine(at path: String) {
        let result = removexattr(path, "com.apple.quarantine", 0)
        // ENOATTR (93) means attribute doesn't exist, which is fine
        // EPERM (1) can happen if file doesn't have quarantine attribute
        if result != 0 && errno != 93 && errno != 1 {
            logger.warning("Failed to remove quarantine attribute: \(errno)")
        }
    }

    /// Performs update check and downloads if available (called on app launch)
    func performUpdateCheckIfNeeded() async {
        // Check if we should check for updates (once per day)
        let lastCheck = UserDefaults.standard.object(forKey: AppConstants.ytdlpLastUpdateCheckKey) as? Date
        let shouldCheck: Bool
        if let lastCheck = lastCheck {
            shouldCheck = Date().timeIntervalSince(lastCheck) > 86400 // 24 hours
        } else {
            shouldCheck = true
        }

        guard shouldCheck else {
            logger.info("Skipping yt-dlp update check (checked recently)")
            return
        }

        logger.info("Checking for yt-dlp updates...")

        do {
            if await checkForUpdates() {
                try await downloadUpdate()
            } else {
                // Update last check date even if no update needed
                UserDefaults.standard.set(Date(), forKey: AppConstants.ytdlpLastUpdateCheckKey)
            }
        } catch {
            logger.error("yt-dlp update failed: \(error.localizedDescription)")
        }
    }
}

enum YTDLPUpdateError: Error, LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case assetNotFound
    case downloadFailed
    case installFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GitHub API URL"
        case .networkError: return "Network error while checking for updates"
        case .parseError: return "Failed to parse GitHub release info"
        case .assetNotFound: return "macOS binary not found in release"
        case .downloadFailed: return "Failed to download yt-dlp binary"
        case .installFailed: return "Failed to install yt-dlp binary"
        }
    }
}

/// Status of yt-dlp installation
enum YTDLPInstallationStatus {
    case notInstalled
    case downloaded(version: String?)
    case customPath(String)
    case homebrewAvailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloaded(let version):
            if let version = version {
                return "Downloaded (v\(version))"
            }
            return "Downloaded"
        case .customPath(let path):
            return "Custom: \(path)"
        case .homebrewAvailable(let path):
            return "Homebrew: \(path)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .downloaded, .customPath, .homebrewAvailable:
            return true
        }
    }

    var isCustomPath: Bool {
        switch self {
        case .customPath, .homebrewAvailable:
            return true
        case .notInstalled, .downloaded:
            return false
        }
    }
}
