// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages parakeet-mlx model detection and cache management via HuggingFace Hub
actor ParakeetModelManager {
    static let shared = ParakeetModelManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ParakeetModelManager")

    private init() {}

    // MARK: - Model Path Resolution

    /// Returns the HuggingFace Hub cache directory name for a model
    /// e.g. "mlx-community/parakeet-tdt-0.6b-v3" -> "models--mlx-community--parakeet-tdt-0.6b-v3"
    nonisolated func cacheDirectoryName(for model: ParakeetModel) -> String {
        "models--" + model.id.replacingOccurrences(of: "/", with: "--")
    }

    /// Returns the full cache path for a model
    nonisolated func modelCachePath(for model: ParakeetModel) -> URL {
        AppConstants.huggingFaceCacheDirectory
            .appendingPathComponent(cacheDirectoryName(for: model))
    }

    // MARK: - Model Status

    /// Checks if a model is downloaded in the HuggingFace Hub cache
    nonisolated func isModelDownloaded(_ model: ParakeetModel) -> Bool {
        let refsMain = modelCachePath(for: model)
            .appendingPathComponent("refs/main")
        return FileManager.default.fileExists(atPath: refsMain.path)
    }

    /// Gets the status of a model
    func getModelStatus(_ model: ParakeetModel) -> ParakeetModelStatus {
        if isModelDownloaded(model) {
            return .downloaded
        }
        return .notDownloaded
    }

    /// Gets all downloaded models
    nonisolated func getDownloadedModels() -> [ParakeetModel] {
        ParakeetModel.allModels.filter { isModelDownloaded($0) }
    }

    // MARK: - Model Selection

    /// Gets the currently selected model from settings
    nonisolated func getSelectedModel() -> ParakeetModel {
        let modelId = UserDefaults.standard.string(forKey: AppConstants.parakeetModelKey)
            ?? AppConstants.defaultParakeetModel
        return ParakeetModel.model(for: modelId)
            ?? ParakeetModel.allModels.first { $0.id == AppConstants.defaultParakeetModel }
            ?? ParakeetModel.allModels[0]
    }

    /// Sets the selected model in settings
    func setSelectedModel(_ model: ParakeetModel) {
        UserDefaults.standard.set(model.id, forKey: AppConstants.parakeetModelKey)
        logger.info("Selected Parakeet model changed to: \(model.displayName)")
    }

    // MARK: - Model Size

    /// Gets the on-disk size of a downloaded model by walking the snapshots directory
    func getModelSizeOnDisk(_ model: ParakeetModel) -> Int64 {
        let cachePath = modelCachePath(for: model)
        let snapshotsPath = cachePath.appendingPathComponent("snapshots")
        let fm = FileManager.default

        guard fm.fileExists(atPath: snapshotsPath.path) else { return 0 }

        var totalSize: Int64 = 0
        if let enumerator = fm.enumerator(at: snapshotsPath, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      resourceValues.isRegularFile == true,
                      let fileSize = resourceValues.fileSize else {
                    continue
                }
                totalSize += Int64(fileSize)
            }
        }

        return totalSize
    }

    /// Gets the total size of all downloaded Parakeet models
    func getTotalModelsSize() -> Int64 {
        var total: Int64 = 0
        for model in getDownloadedModels() {
            total += getModelSizeOnDisk(model)
        }
        return total
    }

    // MARK: - Model Download

    private var activeDownloadSession: URLSession?

    /// Downloads a model directly from HuggingFace using native URLSession.
    /// Files are stored in the standard HuggingFace Hub cache format for compatibility with huggingface_hub.
    func downloadModel(
        _ model: ParakeetModel,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void
    ) async throws {
        guard let _ = BinaryPathResolver.parakeetMlxPath else {
            throw ParakeetModelDownloadError.parakeetNotInstalled
        }

        guard !isModelDownloaded(model) else {
            logger.info("Model \(model.id) is already downloaded")
            progress(ModelDownloadProgress.completed)
            return
        }

        logger.info("Starting download of Parakeet model: \(model.displayName)")

        // 1. Fetch model metadata from HuggingFace API
        let apiURLString = "https://huggingface.co/api/models/\(model.id)"
        guard let apiURL = URL(string: apiURLString) else {
            throw ParakeetModelDownloadError.downloadFailed("Invalid model ID: \(model.id)")
        }

        let (apiData, apiResponse) = try await URLSession.shared.data(from: apiURL)
        guard let httpAPIResponse = apiResponse as? HTTPURLResponse,
              httpAPIResponse.statusCode == 200 else {
            throw ParakeetModelDownloadError.downloadFailed(
                "Failed to fetch model info from HuggingFace"
            )
        }

        let modelInfo = try JSONDecoder().decode(HFModelAPIResponse.self, from: apiData)
        let commitHash = modelInfo.sha

        // 2. Prepare cache directory structure (matches huggingface_hub format)
        let cacheDir = modelCachePath(for: model)
        let blobsDir = cacheDir.appendingPathComponent("blobs")
        let snapshotsDir = cacheDir.appendingPathComponent("snapshots")
            .appendingPathComponent(commitHash)
        let refsDir = cacheDir.appendingPathComponent("refs")

        let fm = FileManager.default
        try fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: refsDir, withIntermediateDirectories: true)

        // 3. Calculate total download size from API metadata
        let files = modelInfo.siblings
        let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var completedBytes: Int64 = 0
        let downloadStartTime = Date()

        // 4. Download each file with progress tracking
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()

            let encodedFilename = file.rfilename
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                ?? file.rfilename
            guard let fileURL = URL(string:
                "https://huggingface.co/\(model.id)/resolve/main/\(encodedFilename)"
            ) else {
                logger.warning("Skipping file with invalid URL: \(file.rfilename)")
                continue
            }

            logger.info("Downloading file \(index + 1)/\(files.count): \(file.rfilename)")

            let fileCompletedBytes = completedBytes
            let fileCount = files.count
            let fileName = file.rfilename

            let (tempURL, downloadResponse) = try await downloadFileWithProgress(
                from: fileURL
            ) { bytesWritten, totalExpected in
                let overallFraction: Double
                if totalBytes > 0 {
                    overallFraction = min(
                        Double(fileCompletedBytes + bytesWritten) / Double(totalBytes), 0.99
                    )
                } else {
                    let filePct = totalExpected > 0
                        ? Double(bytesWritten) / Double(totalExpected) : 0
                    overallFraction = min(
                        (Double(index) + filePct) / Double(fileCount), 0.99
                    )
                }

                let fileFraction = totalExpected > 0
                    ? min(Double(bytesWritten) / Double(totalExpected), 1.0) : 0

                let elapsed = Date().timeIntervalSince(downloadStartTime)
                let totalDownloaded = fileCompletedBytes + bytesWritten
                let bytesPerSecond = elapsed > 0.5 ? Double(totalDownloaded) / elapsed : 0

                let update = ModelDownloadProgress(
                    overallFraction: overallFraction,
                    currentFileName: fileName,
                    currentFileIndex: index + 1,
                    totalFileCount: fileCount,
                    currentFileFraction: fileFraction,
                    bytesPerSecond: bytesPerSecond
                )
                Task { @MainActor in progress(update) }
            }

            // Determine blob name for huggingface_hub cache compatibility:
            // - LFS files: use the sha256 from the API (matches X-Linked-ETag)
            // - Non-LFS files: use the ETag from the HTTP response
            let httpResp = downloadResponse as? HTTPURLResponse
            let blobName: String
            if let lfsSha = file.lfs?.sha256 {
                blobName = lfsSha
            } else {
                let rawETag = httpResp?.value(forHTTPHeaderField: "ETag") ?? ""
                blobName = rawETag.isEmpty
                    ? UUID().uuidString
                    : Self.normalizeETag(rawETag)
            }

            // Store file as blob
            let blobPath = blobsDir.appendingPathComponent(blobName)
            if fm.fileExists(atPath: blobPath.path) {
                try fm.removeItem(at: blobPath)
            }
            try fm.moveItem(at: tempURL, to: blobPath)

            // Create symlink in snapshots directory (matches huggingface_hub layout)
            let snapshotFilePath = snapshotsDir.appendingPathComponent(file.rfilename)
            let snapshotFileDir = snapshotFilePath.deletingLastPathComponent()
            if !fm.fileExists(atPath: snapshotFileDir.path) {
                try fm.createDirectory(at: snapshotFileDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: snapshotFilePath.path) {
                try fm.removeItem(at: snapshotFilePath)
            }

            // Relative symlink: snapshots/{commit}/{file} -> ../../blobs/{etag}
            // Add extra ../ for each subdirectory level in the filename
            let subdirDepth = file.rfilename.components(separatedBy: "/").count - 1
            let relativePrefix = String(repeating: "../", count: 2 + subdirDepth)
            try fm.createSymbolicLink(
                atPath: snapshotFilePath.path,
                withDestinationPath: relativePrefix + "blobs/" + blobName
            )

            // Track completed bytes (use actual Content-Length if API didn't provide size)
            let actualFileSize = file.size
                ?? Int64(httpResp?.expectedContentLength ?? 0)
            completedBytes += max(actualFileSize, 0)
        }

        // 5. Write refs/main with commit hash
        let refsMainPath = refsDir.appendingPathComponent("main")
        try commitHash.write(to: refsMainPath, atomically: true, encoding: .utf8)

        activeDownloadSession = nil

        // 6. Verify the model is now in cache
        guard isModelDownloaded(model) else {
            throw ParakeetModelDownloadError.downloadFailed(
                "Model not found in cache after download"
            )
        }

        progress(.completed)
        logger.info("Successfully downloaded Parakeet model: \(model.displayName)")
    }

    /// Cancels an ongoing model download
    func cancelDownload() {
        if let session = activeDownloadSession {
            session.invalidateAndCancel()
            activeDownloadSession = nil
            logger.info("Cancelled Parakeet model download")
        }
    }

    // MARK: - Download Helpers

    /// HuggingFace API response for model metadata
    private struct HFModelAPIResponse: Decodable {
        let sha: String
        let siblings: [HFSibling]

        struct HFSibling: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFSInfo?

            struct LFSInfo: Decodable {
                let sha256: String
            }
        }
    }

    /// Normalizes an HTTP ETag to match huggingface_hub's blob naming convention
    private static func normalizeETag(_ etag: String) -> String {
        var result = etag
        if result.hasPrefix("W/") {
            result = String(result.dropFirst(2))
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Downloads a file using URLSession with real-time byte-level progress reporting
    private func downloadFileWithProgress(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(
            configuration: .default, delegate: delegate, delegateQueue: nil
        )
        activeDownloadSession = session

        return try await withCheckedThrowingContinuation { continuation in
            delegate.setContinuation(continuation)
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: - Model Deletion

    /// Deletes a downloaded model from the HuggingFace Hub cache
    func deleteModel(_ model: ParakeetModel) throws {
        let cachePath = modelCachePath(for: model)
        let fm = FileManager.default

        guard fm.fileExists(atPath: cachePath.path) else {
            logger.warning("Tried to delete model that doesn't exist: \(model.displayName)")
            return
        }

        try fm.removeItem(at: cachePath)
        logger.info("Deleted Parakeet model: \(model.displayName)")

        // If this was the selected model, switch to a different downloaded model
        let selected = getSelectedModel()
        if selected.id == model.id {
            let downloaded = getDownloadedModels()
            if let firstAvailable = downloaded.first {
                setSelectedModel(firstAvailable)
            }
        }
    }

    /// Deletes all downloaded Parakeet models from cache
    func deleteAllModels() throws {
        for model in getDownloadedModels() {
            try deleteModel(model)
        }
        logger.info("Deleted all Parakeet models")
    }
}

// MARK: - URLSession Download Delegate

/// Handles URLSession download callbacks, reporting byte-level progress and delivering
/// the downloaded file via a checked continuation.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedFileURL: URL?

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func setContinuation(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move to a persistent temp location before URLSession deletes the original
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: tempURL)
            downloadedFileURL = tempURL
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { continuation = nil }

        if let error = error {
            if let tempURL = downloadedFileURL {
                try? FileManager.default.removeItem(at: tempURL)
            }
            continuation?.resume(throwing: error)
        } else if let fileURL = downloadedFileURL, let response = task.response {
            continuation?.resume(returning: (fileURL, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}

// MARK: - Error Types

enum ParakeetModelDownloadError: Error, LocalizedError {
    case parakeetNotInstalled
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .parakeetNotInstalled:
            return "parakeet-mlx is not installed. Install with: pip install -U parakeet-mlx"
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        }
    }
}

// MARK: - Download Progress

/// Progress information for model downloads, supporting both overall and per-file tracking
struct ModelDownloadProgress: Sendable {
    var overallFraction: Double
    var currentFileName: String
    var currentFileIndex: Int
    var totalFileCount: Int
    var currentFileFraction: Double
    var bytesPerSecond: Double

    /// Terminal state indicating download completed
    static let completed = ModelDownloadProgress(
        overallFraction: 1.0,
        currentFileName: "",
        currentFileIndex: 0,
        totalFileCount: 0,
        currentFileFraction: 1.0,
        bytesPerSecond: 0
    )

    /// Formats the download speed for display (e.g. "12.5 MB/s" or "450 KB/s")
    var formattedSpeed: String {
        if bytesPerSecond <= 0 { return "" }
        let mbps = bytesPerSecond / 1_000_000
        if mbps >= 1.0 {
            return String(format: "%.1f MB/s", mbps)
        } else {
            let kbps = bytesPerSecond / 1_000
            return String(format: "%.0f KB/s", kbps)
        }
    }
}
