// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Installation status for ExifTool
enum ExifToolInstallationStatus: Sendable {
    case notInstalled
    case downloaded(version: String?)
    case customPath(String)
    case systemInstalled(path: String, version: String?)

    var isAvailable: Bool {
        switch self {
        case .notInstalled: return false
        case .downloaded, .customPath, .systemInstalled: return true
        }
    }

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Not installed"
        case .downloaded(let version):
            if let v = version {
                return "Downloaded (v\(v))"
            }
            return "Downloaded"
        case .customPath(let path):
            return "Custom: \(path)"
        case .systemInstalled(_, let version):
            if let v = version {
                return "System (v\(v))"
            }
            return "System (Homebrew)"
        }
    }
}

/// Manages ExifTool download and updates
actor ExifToolUpdateService {
    static let shared = ExifToolUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "ExifToolUpdate")

    /// Path where downloaded ExifTool is stored
    var downloadedPath: URL {
        AppConstants.ytdlpToolsDirectory.appendingPathComponent("exiftool")
    }

    private init() {}

    // MARK: - Path Resolution

    /// Resolves the best available ExifTool path
    /// Priority: Custom path > Downloaded > System (Homebrew)
    nonisolated func resolveExifToolPath() -> String? {
        BinaryPathResolver.exiftoolPath
    }

    // MARK: - Installation Status

    /// Gets the current installation status
    func getInstallationStatus() async -> ExifToolInstallationStatus {
        // Check custom path first
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.exiftoolCustomPathKey),
           !customPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: customPath) {
            return .customPath(customPath)
        }

        // Check downloaded version
        if FileManager.default.isExecutableFile(atPath: downloadedPath.path) {
            let version = await getCurrentVersion(at: downloadedPath.path)
            return .downloaded(version: version)
        }

        // Check system locations
        let systemPaths = [
            "/opt/homebrew/bin/exiftool",
            "/usr/local/bin/exiftool"
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                let version = await getCurrentVersion(at: path)
                return .systemInstalled(path: path, version: version)
            }
        }

        return .notInstalled
    }

    // MARK: - Version Management

    /// Gets the current version of ExifTool at the given path
    func getCurrentVersion(at path: String? = nil) async -> String? {
        let exiftoolPath = path ?? resolveExifToolPath()
        guard let exiftoolPath else { return nil }

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-ver"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            logger.error("Failed to get ExifTool version: \(error.localizedDescription)")
        }

        return nil
    }

    /// Gets the latest version available from exiftool.org
    func getLatestVersion() async throws -> String {
        guard let url = URL(string: AppConstants.exiftoolVersionURL) else {
            throw ExifToolUpdateError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExifToolUpdateError.networkError("Failed to fetch version info")
        }

        guard let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ExifToolUpdateError.parseError("Invalid version format")
        }

        return version
    }

    /// Checks if an update is available
    func checkForUpdates() async throws -> (hasUpdate: Bool, currentVersion: String?, latestVersion: String) {
        let latestVersion = try await getLatestVersion()
        let currentVersion = await getCurrentVersion()

        // Record update check time
        UserDefaults.standard.set(Date(), forKey: AppConstants.exiftoolLastUpdateCheckKey)

        guard let current = currentVersion else {
            // Not installed, so "update" is available (i.e., install)
            return (true, nil, latestVersion)
        }

        // Compare versions numerically
        let hasUpdate = current.compare(latestVersion, options: .numeric) == .orderedAscending
        return (hasUpdate, current, latestVersion)
    }

    // MARK: - Download

    /// Downloads and installs the latest version of ExifTool
    func downloadUpdate(progress: @escaping @Sendable (Double) -> Void) async throws {
        let latestVersion = try await getLatestVersion()
        logger.info("Downloading ExifTool version \(latestVersion)")

        // Build download URL: https://exiftool.org/Image-ExifTool-XX.XX.tar.gz
        let downloadURLString = "\(AppConstants.exiftoolDownloadBaseURL)Image-ExifTool-\(latestVersion).tar.gz"
        guard let downloadURL = URL(string: downloadURLString) else {
            throw ExifToolUpdateError.invalidURL
        }

        // Download the tar.gz file
        let delegate = DownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        let (tempURL, response) = try await session.download(from: downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ExifToolUpdateError.downloadFailed
        }

        // Extract the tar.gz
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("exiftool_extract_\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Extract using tar
        let tarProcess = Process()
        tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tarProcess.arguments = ["-xzf", tempURL.path, "-C", tempDir.path]
        tarProcess.standardOutput = FileHandle.nullDevice
        tarProcess.standardError = FileHandle.nullDevice

        try tarProcess.run()
        tarProcess.waitUntilExit()

        guard tarProcess.terminationStatus == 0 else {
            throw ExifToolUpdateError.extractionFailed
        }

        // Find the exiftool executable in the extracted directory
        // It's at: Image-ExifTool-XX.XX/exiftool
        let extractedDir = tempDir.appendingPathComponent("Image-ExifTool-\(latestVersion)")
        let exiftoolBinary = extractedDir.appendingPathComponent("exiftool")

        guard FileManager.default.fileExists(atPath: exiftoolBinary.path) else {
            throw ExifToolUpdateError.binaryNotFound
        }

        // Ensure tools directory exists
        try FileManager.default.createDirectory(
            at: AppConstants.ytdlpToolsDirectory,
            withIntermediateDirectories: true
        )

        // Remove existing version if present
        if FileManager.default.fileExists(atPath: downloadedPath.path) {
            try FileManager.default.removeItem(at: downloadedPath)
        }

        // Copy exiftool to tools directory
        try FileManager.default.copyItem(at: exiftoolBinary, to: downloadedPath)

        // Set executable permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: downloadedPath.path
        )

        // Save version info
        UserDefaults.standard.set(latestVersion, forKey: AppConstants.exiftoolVersionKey)
        UserDefaults.standard.set(Date(), forKey: AppConstants.exiftoolLastUpdateCheckKey)

        // Clean up temp download file
        try? FileManager.default.removeItem(at: tempURL)

        logger.info("ExifTool \(latestVersion) installed successfully")
        progress(1.0)
    }

    /// Performs update check if needed (throttled to once per 24 hours)
    func performUpdateCheckIfNeeded() async {
        let lastCheck = UserDefaults.standard.object(forKey: AppConstants.exiftoolLastUpdateCheckKey) as? Date
        let shouldCheck = lastCheck == nil || Date().timeIntervalSince(lastCheck!) > 86400 // 24 hours

        guard shouldCheck else { return }

        do {
            let (hasUpdate, _, latestVersion) = try await checkForUpdates()
            if hasUpdate {
                logger.info("ExifTool update available: \(latestVersion)")
            }
        } catch {
            logger.warning("Failed to check for ExifTool updates: \(error.localizedDescription)")
        }
    }

    /// Saves a custom ExifTool path
    func saveCustomPath(_ path: String?) {
        if let path = path, !path.isEmpty {
            UserDefaults.standard.set(path, forKey: AppConstants.exiftoolCustomPathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.exiftoolCustomPathKey)
        }
    }
}

// MARK: - Download Progress Delegate

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: @Sendable (Double) -> Void

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
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        Task { @MainActor in
            progressHandler(min(progress, 0.95)) // Reserve last 5% for extraction
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the caller
    }
}

// MARK: - Error Types

enum ExifToolUpdateError: Error, LocalizedError {
    case invalidURL
    case networkError(String)
    case parseError(String)
    case downloadFailed
    case extractionFailed
    case binaryNotFound
    case installFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid download URL"
        case .networkError(let message):
            return "Network error: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .downloadFailed:
            return "Download failed"
        case .extractionFailed:
            return "Failed to extract archive"
        case .binaryNotFound:
            return "ExifTool binary not found in archive"
        case .installFailed:
            return "Failed to install ExifTool"
        }
    }
}
