// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages rclone binary resolution with priority: custom path > downloaded > system
actor RcloneUpdateService {
    static let shared = RcloneUpdateService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneUpdate")

    /// Cache key for custom-path validation: (path, mtime, size). If any of those change we re-validate.
    private struct CustomPathFingerprint: Equatable {
        let path: String
        let mtime: Date
        let size: Int64
    }
    private var lastValidatedCustomPath: CustomPathFingerprint?

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
    ///
    /// The custom path is validated by running `--version` (cached per file fingerprint) so a
    /// rogue UserDefaults entry pointing at an arbitrary executable is rejected before we launch it.
    func resolveRclonePath() async -> String? {
        if let customPath = UserDefaults.standard.string(forKey: AppConstants.rcloneCustomPathKey),
           !customPath.isEmpty {
            if await validateCustomRclonePath(customPath) {
                logger.info("Using custom rclone at: \(customPath, privacy: .private)")
                return customPath
            } else {
                logger.warning("Custom rclone path is missing or not a valid rclone binary: \(customPath, privacy: .private)")
            }
        }

        let downloadedPathString = downloadedPath.path
        if FileManager.default.fileExists(atPath: downloadedPathString) {
            if !FileManager.default.isExecutableFile(atPath: downloadedPathString) {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloadedPathString)
            }
            logger.info("Using downloaded rclone")
            return downloadedPathString
        }

        let systemPaths = [
            "/opt/homebrew/bin/rclone"
        ]
        for path in systemPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                logger.info("Using system rclone at: \(path, privacy: .public)")
                return path
            }
        }

        logger.warning("No rclone binary available")
        return nil
    }

    /// Validates that `path` exists and behaves like rclone (`--version` returns "rclone v..."). Caches per file fingerprint.
    private func validateCustomRclonePath(_ path: String) async -> Bool {
        guard let fingerprint = currentFingerprint(for: path) else {
            lastValidatedCustomPath = nil
            return false
        }

        if let cached = lastValidatedCustomPath, cached == fingerprint {
            return true
        }

        guard await RcloneBinaryVerifier.versionString(of: path) != nil else {
            lastValidatedCustomPath = nil
            return false
        }

        lastValidatedCustomPath = fingerprint
        return true
    }

    /// Returns the (path, mtime, size) fingerprint for a file, or nil if it doesn't exist / isn't readable.
    private func currentFingerprint(for path: String) -> CustomPathFingerprint? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        guard let mtime = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return CustomPathFingerprint(path: path, mtime: mtime, size: size)
    }

    /// Checks if rclone is available
    func isRcloneAvailable() async -> Bool {
        await resolveRclonePath() != nil
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
        guard let rclonePath = await resolveRclonePath() else { return nil }

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

    /// Information about the latest rclone release. Includes the SHA256SUMS asset URL so we can
    /// verify the downloaded zip against rclone's published checksums before installing it.
    struct LatestReleaseInfo {
        let version: String
        let assetName: String
        let downloadURL: URL
        let checksumsURL: URL
    }

    /// Checks GitHub for the latest rclone release. Returns the macOS arm64 asset details and the
    /// matching SHA256SUMS file (also published as a release asset).
    func getLatestReleaseInfo() async throws -> LatestReleaseInfo {
        guard let url = URL(string: AppConstants.rcloneGitHubReleasesURL) else {
            throw RcloneUpdateError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(GitHubRequest.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        // Use a redirect-restricted session so a redirect cannot send us to an attacker-controlled host.
        let delegate = GitHubRedirectGuard()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw RcloneUpdateError.networkError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw RcloneUpdateError.parseError
        }

        let assetPattern = "rclone-.*-osx-arm64.zip"
        var binaryAsset: (name: String, url: URL)?
        var checksumsURL: URL?

        for asset in assets {
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let assetURL = URL(string: urlString) else {
                continue
            }
            if name == "SHA256SUMS" {
                checksumsURL = assetURL
            } else if name.range(of: assetPattern, options: .regularExpression) != nil {
                binaryAsset = (name, assetURL)
            }
        }

        guard let binary = binaryAsset else {
            throw RcloneUpdateError.assetNotFound
        }
        guard let checksums = checksumsURL else {
            // No SHA256SUMS asset means we cannot verify integrity. Refuse to install rather than ship blind trust.
            throw RcloneUpdateError.checksumsNotPublished
        }

        return LatestReleaseInfo(
            version: tagName,
            assetName: binary.name,
            downloadURL: binary.url,
            checksumsURL: checksums
        )
    }

    /// Backwards-compatible wrapper for callers that just want the version string.
    func getLatestReleaseVersion() async throws -> (version: String, downloadURL: URL)? {
        let info = try await getLatestReleaseInfo()
        return (info.version, info.downloadURL)
    }

    /// Checks if an update is available
    func checkForUpdates() async -> Bool {
        do {
            guard let currentVersion = await getCurrentVersion() else {
                return false
            }
            let info = try await getLatestReleaseInfo()
            let isNewer = info.version.compare(currentVersion, options: .numeric) == .orderedDescending
            logger.info("rclone - Current: \(currentVersion), Latest: \(info.version), Update available: \(isNewer)")
            return isNewer
        } catch {
            logger.error("Failed to check for rclone updates: \(error.localizedDescription)")
            return false
        }
    }

    /// Downloads and installs the latest rclone release.
    ///
    /// Verification gate (any failure aborts install and removes the partial file):
    ///   1. SHA-256 of the downloaded zip matches rclone's published `SHA256SUMS` entry.
    ///   2. The extracted binary has a valid Apple code signature.
    /// Only after both pass do we strip the quarantine xattr and move it into place.
    ///
    /// - Parameter progress: Callback for download progress (0.0 to 1.0)
    func downloadUpdate(progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await getLatestReleaseInfo()
        logger.info("Downloading rclone \(info.version, privacy: .public) from \(info.downloadURL.host ?? "?", privacy: .public)")

        let tempZipURL = try await downloadWithProgress(from: info.downloadURL, progress: progress)
        // From here on, any thrown error must clean up the temp zip.
        var cleanupZip: URL? = tempZipURL
        defer {
            if let url = cleanupZip { try? FileManager.default.removeItem(at: url) }
        }

        // Step 1: SHA-256 checksum verification before we touch the binary.
        try await RcloneBinaryVerifier.verifyChecksum(
            zipURL: tempZipURL,
            assetName: info.assetName,
            checksumsURL: info.checksumsURL
        )

        let extractedBinaryURL = try await extractRcloneBinary(from: tempZipURL)
        var cleanupExtractDir: URL? = extractedBinaryURL.deletingLastPathComponent()
        defer {
            if let url = cleanupExtractDir { try? FileManager.default.removeItem(at: url) }
        }

        // Step 2: Apple code signature must be present and intact.
        let signature = try RcloneBinaryVerifier.verifyCodeSignature(at: extractedBinaryURL)
        logger.info("rclone code signature OK — team=\(signature.teamIdentifier ?? "?", privacy: .public) id=\(signature.identifier ?? "?", privacy: .public)")

        // Both checks passed; install.
        let fm = FileManager.default
        let destinationPath = downloadedPath
        let destinationDir = destinationPath.deletingLastPathComponent()
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
        if fm.fileExists(atPath: destinationPath.path) {
            try fm.removeItem(at: destinationPath)
        }
        try fm.moveItem(at: extractedBinaryURL, to: destinationPath)

        // Quarantine xattr is stripped only after verification — never on a binary we haven't validated.
        removeQuarantine(at: destinationPath.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath.path)

        // We just consumed the extract dir contents; do not let the defer remove the moved binary.
        cleanupExtractDir = nil
        // Zip is no longer needed.
        try? fm.removeItem(at: tempZipURL)
        cleanupZip = nil

        try info.version.write(to: versionFilePath, atomically: true, encoding: .utf8)
        UserDefaults.standard.set(Date(), forKey: AppConstants.rcloneLastUpdateCheckKey)
        UserDefaults.standard.set(info.version, forKey: AppConstants.rcloneVersionKey)

        // The fingerprint cache for any custom path is unrelated, but a freshly installed download
        // means our resolveRclonePath should re-evaluate priorities on the next call.
        logger.info("Successfully installed rclone \(info.version, privacy: .public)")
    }

    // MARK: - Private Methods

    /// Downloads a file with progress tracking. Sends a User-Agent and rejects redirects
    /// to hosts outside GitHub's serving infrastructure.
    private func downloadWithProgress(
        from url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue(GitHubRequest.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let delegate = DownloadProgressDelegate(progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL, response != nil else {
                    continuation.resume(throwing: RcloneUpdateError.downloadFailed)
                    return
                }

                let persistentTemp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".zip")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: persistentTemp)
                    continuation.resume(returning: persistentTemp)
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(GitHubHostAllowlist.allow(request: request))
    }
}

// MARK: - GitHub redirect guard

/// Refuses HTTP redirects to hosts outside GitHub's release-serving infrastructure.
/// Used for the JSON release info fetch (no progress to report).
private final class GitHubRedirectGuard: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(GitHubHostAllowlist.allow(request: request))
    }
}

/// Whitelist of hosts that GitHub legitimately uses for the API and release artifacts.
/// A redirect to anything else is treated as suspicious and refused (the URL request becomes the original).
private enum GitHubHostAllowlist {
    private static let suffixes: [String] = [
        "github.com",
        "githubusercontent.com",
        "githubassets.com"
    ]

    static func allow(request: URLRequest) -> URLRequest? {
        guard let host = request.url?.host?.lowercased() else { return nil }
        for suffix in suffixes {
            if host == suffix || host.hasSuffix("." + suffix) {
                return request
            }
        }
        return nil
    }
}

// MARK: - Error Types

enum RcloneUpdateError: Error, LocalizedError {
    case invalidURL
    case networkError
    case parseError
    case assetNotFound
    case checksumsNotPublished
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
        case .checksumsNotPublished: return "Release does not include a SHA256SUMS file — refusing to install without integrity verification"
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
