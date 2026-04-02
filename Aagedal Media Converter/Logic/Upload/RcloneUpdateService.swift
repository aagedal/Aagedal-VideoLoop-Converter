// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages rclone binary resolution with priority: custom path > downloaded > system
actor RcloneUpdateService {
    static let shared = RcloneUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneUpdate")

    /// Path to downloaded rclone binary in Application Support
    nonisolated var downloadedPath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("rclone")
    }

    /// Path to version file for downloaded binary
    private var versionFilePath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("rclone-version.txt")
    }

    /// Returns the path to the best available rclone binary
    /// Priority: 1) Custom path, 2) Downloaded, 3) System (Homebrew)
    func resolveRclonePath() -> String? {
        // First, check user-provided custom path
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
           !customPath.isEmpty {
            if FileManager.default.fileExists(atPath: customPath) {
                logger.info("Using custom rclone at: \(customPath)")
                return customPath
            } else {
                logger.warning("Custom rclone path no longer exists: \(customPath)")
            }
        }

        // Check if downloaded version exists
        let downloadedPathString = downloadedPath.path
        if FileManager.default.fileExists(atPath: downloadedPathString) {
            // Try to fix permissions if needed
            if !FileManager.default.isExecutableFile(atPath: downloadedPathString) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloadedPathString)
            }
            logger.info("Using downloaded rclone at: \(downloadedPathString)")
            return downloadedPathString
        }

        // Check system paths (Homebrew)
        let systemPaths = [
            "/opt/homebrew/bin/rclone"
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Using system rclone at: \(path)")
                return path
            }
        }

        logger.warning("No rclone binary available")
        return nil
    }

    /// Checks if rclone is available
    func isRcloneAvailable() -> Bool {
        resolveRclonePath() != nil
    }

    /// Gets the current installation status
    nonisolated func getInstallationStatus() -> RcloneInstallationStatus {
        // Check custom path
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
           !customPath.isEmpty,
           FileManager.default.fileExists(atPath: customPath) {
            return .customPath(customPath)
        }

        // Check downloaded version
        if FileManager.default.fileExists(atPath: downloadedPath.path) {
            let version = UserDefaults.standard.string(forKey: AppConstants.rcloneVersionKey)
            return .downloaded(version: version)
        }

        // Check system paths
        let systemPaths = ["/opt/homebrew/bin/rclone"]
        for path in systemPaths {
            if FileManager.default.fileExists(atPath: path) {
                return .systemAvailable(path)
            }
        }

        return .notInstalled
    }

    /// Gets the version of the currently active rclone binary
    func getCurrentVersion() async -> String? {
        guard let rclonePath = resolveRclonePath() else { return nil }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // First line is like: "rclone v1.68.2"
                let firstLine = output.components(separatedBy: .newlines).first ?? ""
                // Extract version number
                if let range = firstLine.range(of: "v[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) {
                    return String(firstLine[range])
                }
                return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.error("Failed to get rclone version: \(error.localizedDescription)")
        }

        return nil
    }

    /// Checks GitHub for the latest rclone release version
    func getLatestReleaseVersion() async throws -> (version: String, downloadURL: URL)? {
        guard let url = URL(string: AppConstants.rcloneGitHubReleasesURL) else {
            throw RcloneUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RcloneUpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw RcloneUpdateError.parseError
        }

        let assetPattern = "rclone-.*-osx-arm64.zip"

        // Find the macOS asset
        for asset in assets {
            if let name = asset["name"] as? String,
               name.range(of: assetPattern, options: .regularExpression) != nil,
               let downloadURLString = asset["browser_download_url"] as? String,
               let downloadURL = URL(string: downloadURLString) {
                return (version: tagName, downloadURL: downloadURL)
            }
        }

        throw RcloneUpdateError.assetNotFound
    }

    /// Checks if an update is available
    func checkForUpdates() async -> Bool {
        do {
            guard let currentVersion = await getCurrentVersion(),
                  let (latestVersion, _) = try await getLatestReleaseVersion() else {
                return false
            }

            let isNewer = latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
            logger.info("rclone - Current: \(currentVersion), Latest: \(latestVersion), Update available: \(isNewer)")
            return isNewer
        } catch {
            logger.error("Failed to check for rclone updates: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and installs the latest rclone release
    /// - Parameter progress: Callback for download progress (0.0 to 1.0)
    func downloadUpdate(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let (version, downloadURL) = try await getLatestReleaseVersion() else {
            throw RcloneUpdateError.assetNotFound
        }

        logger.info("Downloading rclone \(version) from \(downloadURL)")

        // Download with progress tracking
        let (tempZipURL, _) = try await downloadWithProgress(from: downloadURL, progress: progress)

        // Extract binary from zip
        let extractedBinaryURL = try await extractRcloneBinary(from: tempZipURL)

        // Move to final location
        let fm = FileManager.default
        let destinationPath = downloadedPath
        let destinationDir = destinationPath.deletingLastPathComponent()

        // Ensure destination directory exists
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)

        // Remove existing file if present
        if fm.fileExists(atPath: destinationPath.path) {
            try fm.removeItem(at: destinationPath)
        }

        try fm.moveItem(at: extractedBinaryURL, to: destinationPath)

        // Remove quarantine attribute
        removeQuarantine(at: destinationPath.path)

        // Set executable permission
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath.path)

        // Clean up temp zip
        try? fm.removeItem(at: tempZipURL)

        // Save version info
        try version.write(to: versionFilePath, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(Date(), forKey: AppConstants.rcloneLastUpdateCheckKey)
        UserDefaults.standard.set(version, forKey: AppConstants.rcloneVersionKey)

        logger.info("Successfully installed rclone \(version) at \(destinationPath.path)")
    }

    // MARK: - Private Methods

    /// Downloads a file with progress tracking
    private func downloadWithProgress(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (URL, URLResponse) {
        let request = URLRequest(url: url)

        // Use a delegate to track progress
        let delegate = DownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, let response = response else {
                    continuation.resume(throwing: RcloneUpdateError.downloadFailed)
                    return
                }

                // Move to a more permanent temp location (the download temp file gets deleted)
                let persistentTemp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".zip")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: persistentTemp)
                    continuation.resume(returning: (persistentTemp, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    /// Extracts the rclone binary from a downloaded zip file
    private func extractRcloneBinary(from zipURL: URL) async throws -> URL {
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Use ditto to extract (preserves permissions)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, extractDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RcloneUpdateError.extractionFailed
        }

        // Find the rclone binary inside the extracted folder
        // Structure is typically: rclone-vX.XX.X-osx-arm64/rclone
        let contents = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
        for item in contents {
            let binaryPath = item.appendingPathComponent("rclone")
            if fm.fileExists(atPath: binaryPath.path) {
                return binaryPath
            }
        }

        throw RcloneUpdateError.binaryNotFound
    }

    /// Removes the quarantine extended attribute from a file
    private func removeQuarantine(at path: String) {
        let result = removexattr(path, "com.apple.quarantine", 0)
        if result != 0 && errno != 93 && errno != 1 {
            logger.warning("Failed to remove quarantine attribute: \(errno)")
        }
    }

    // MARK: - Custom Path Management

    /// Saves a custom rclone path
    func saveCustomPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: AppConstants.rcloneCustomPathKey)
        logger.info("Saved custom rclone path: \(path)")
    }

    /// Gets the custom rclone path
    nonisolated func getCustomPath() -> String? {
        UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey)
    }

    /// Clears the custom rclone path
    func clearCustomPath() {
        UserDefaults.standard.removeObject(forKey: AppConstants.rcloneCustomPathKey)
        logger.info("Cleared custom rclone path")
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            self.progressHandler(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled in the completion handler
    }
}

// MARK: - Error Types

enum RcloneUpdateError: Error, LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case assetNotFound
    case downloadFailed
    case extractionFailed
    case binaryNotFound
    case installFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid GitHub API URL"
        case .networkError: return "Network error while checking for updates"
        case .parseError: return "Failed to parse GitHub release info"
        case .assetNotFound: return "macOS binary not found in release"
        case .downloadFailed: return "Failed to download rclone binary"
        case .extractionFailed: return "Failed to extract rclone from zip"
        case .binaryNotFound: return "rclone binary not found in archive"
        case .installFailed: return "Failed to install rclone binary"
        }
    }
}

// MARK: - Installation Status

/// Status of rclone installation
enum RcloneInstallationStatus {
    case notInstalled
    case downloaded(version: String?)
    case customPath(String)
    case systemAvailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloaded(let version):
            if let version = version {
                return "Downloaded (\(version))"
            }
            return "Downloaded"
        case .customPath(let path):
            return "Custom: \(path)"
        case .systemAvailable(let path):
            return "System: \(path)"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .notInstalled:
            return false
        case .downloaded, .customPath, .systemAvailable:
            return true
        }
    }
}
