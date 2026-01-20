// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Manages whisper.cpp model downloads and storage
actor WhisperModelManager {
    static let shared = WhisperModelManager()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "WhisperModelManager")
    private var downloadTasks: [WhisperModel: URLSessionDownloadTask] = [:]
    private var progressHandlers: [WhisperModel: @Sendable (Double) -> Void] = [:]

    private init() {
        // Ensure models directory exists
        try? FileManager.default.createDirectory(
            at: AppConstants.whisperModelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Returns the file URL for a given model
    nonisolated func modelPath(for model: WhisperModel) -> URL {
        if model.isCustom, let customURL = customModelURL() {
            return customURL
        }
        return AppConstants.whisperModelsDirectory.appendingPathComponent(model.fileName)
    }

    nonisolated func customModelURL() -> URL? {
        let rawPath = UserDefaults.standard.string(forKey: AppConstants.whisperCustomModelPathKey) ?? ""
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    /// Checks if a model is downloaded
    nonisolated func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let path = modelPath(for: model)
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Gets the status of a model
    func getModelStatus(_ model: WhisperModel) -> WhisperModelStatus {
        if isModelDownloaded(model) {
            return .downloaded
        }
        if downloadTasks[model] != nil {
            return .downloading(progress: 0)
        }
        return .notDownloaded
    }

    /// Gets all downloaded models
    nonisolated func getDownloadedModels() -> [WhisperModel] {
        WhisperModel.downloadableCases.filter { isModelDownloaded($0) }
    }

    /// Gets the currently selected model from settings
    nonisolated func getSelectedModel() -> WhisperModel {
        let rawValue = UserDefaults.standard.string(forKey: AppConstants.whisperModelKey) ?? AppConstants.defaultWhisperModel
        return WhisperModel(rawValue: rawValue) ?? .base
    }

    /// Sets the selected model in settings
    func setSelectedModel(_ model: WhisperModel) {
        UserDefaults.standard.set(model.rawValue, forKey: AppConstants.whisperModelKey)
        logger.info("Selected model changed to: \(model.displayName)")
    }

    /// Gets the total size of all downloaded models
    func getTotalModelsSize() -> Int64 {
        var totalSize: Int64 = 0
        let fm = FileManager.default

        for model in WhisperModel.downloadableCases {
            let path = modelPath(for: model)
            if let attrs = try? fm.attributesOfItem(atPath: path.path),
               let size = attrs[.size] as? Int64 {
                totalSize += size
            }
        }

        return totalSize
    }

    /// Downloads a model with progress tracking
    func downloadModel(
        _ model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard model.isDownloadable else {
            throw WhisperModelError.modelNotFound
        }
        // Check if already downloading
        if downloadTasks[model] != nil {
            logger.warning("Model \(model.rawValue) is already being downloaded")
            return
        }

        // Check if already downloaded
        if isModelDownloaded(model) {
            logger.info("Model \(model.rawValue) is already downloaded")
            progress(1.0)
            return
        }

        logger.info("Starting download of model: \(model.displayName) (\(model.fileSize))")
        progressHandlers[model] = progress

        let delegate = ModelDownloadDelegate(
            model: model,
            manager: self
        )

        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        let task = session.downloadTask(with: model.downloadURL)
        downloadTasks[model] = task

        // Use continuation to wait for completion
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.completion = { result in
                Task {
                    // Call actor-isolated cleanup method
                    await self.performCleanup(for: model)
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            task.resume()
        }
    }

    /// Called by delegate to report progress
    func reportProgress(for model: WhisperModel, progress: Double) {
        progressHandlers[model]?(progress)
    }

    /// Called by delegate when download completes
    func handleDownloadComplete(for model: WhisperModel, tempURL: URL) throws {
        let destinationPath = modelPath(for: model)
        let fm = FileManager.default

        // Remove existing file if present
        if fm.fileExists(atPath: destinationPath.path) {
            try fm.removeItem(at: destinationPath)
        }

        // Move downloaded file to final location
        try fm.moveItem(at: tempURL, to: destinationPath)

        // Verify file exists
        guard fm.fileExists(atPath: destinationPath.path) else {
            throw WhisperModelError.installFailed
        }

        logger.info("Successfully downloaded model: \(model.displayName)")
    }

    /// Cleans up after download (success or failure)
    private func cleanupDownload(for model: WhisperModel) {
        downloadTasks.removeValue(forKey: model)
        progressHandlers.removeValue(forKey: model)
    }

    /// Async wrapper for cleanup to satisfy actor isolation from external Tasks
    private func performCleanup(for model: WhisperModel) async {
        cleanupDownload(for: model)
    }

    /// Cancels an ongoing model download
    func cancelDownload(for model: WhisperModel) {
        if let task = downloadTasks[model] {
            task.cancel()
            cleanupDownload(for: model)
            logger.info("Cancelled download of model: \(model.displayName)")
        }
    }

    /// Deletes a downloaded model
    func deleteModel(_ model: WhisperModel) throws {
        let path = modelPath(for: model)
        let fm = FileManager.default

        guard fm.fileExists(atPath: path.path) else {
            logger.warning("Tried to delete model that doesn't exist: \(model.displayName)")
            return
        }

        try fm.removeItem(at: path)
        logger.info("Deleted model: \(model.displayName)")

        // If this was the selected model, switch to a different downloaded model or base
        let selected = getSelectedModel()
        if selected == model {
            let downloaded = getDownloadedModels()
            if let firstAvailable = downloaded.first {
                setSelectedModel(firstAvailable)
            } else {
                setSelectedModel(.base)
            }
        }
    }

    /// Deletes all downloaded models
    func deleteAllModels() throws {
        for model in getDownloadedModels() {
            try deleteModel(model)
        }
        logger.info("Deleted all models")
    }

    /// Ensures the selected model is downloaded, or falls back to a downloaded model
    func ensureModelAvailable() async throws -> WhisperModel {
        let selected = getSelectedModel()

        if isModelDownloaded(selected) {
            return selected
        }

        if selected.isCustom {
            logger.info("Custom model not available, falling back to a downloaded model")
        }

        // Check if any model is downloaded
        let downloaded = getDownloadedModels()
        if let available = downloaded.first {
            logger.info("Selected model \(selected.displayName) not available, using \(available.displayName)")
            return available
        }

        // No models downloaded - download the base model
        logger.info("No models available, downloading base model")
        try await downloadModel(.base) { _ in }
        return .base
    }
}

// MARK: - Download Delegate

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let model: WhisperModel
    let manager: WhisperModelManager
    var completion: ((Result<Void, Error>) -> Void)?

    init(model: WhisperModel, manager: WhisperModelManager) {
        self.model = model
        self.manager = manager
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expectedBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.fileSizeBytes
        let progress = Double(totalBytesWritten) / Double(expectedBytes)

        Task {
            await manager.reportProgress(for: model, progress: min(progress, 1.0))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            // Copy to permanent temp location before this method returns
            let tempCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".bin")
            try FileManager.default.copyItem(at: location, to: tempCopy)

            Task {
                do {
                    try await manager.handleDownloadComplete(for: model, tempURL: tempCopy)
                    await manager.reportProgress(for: model, progress: 1.0)
                    completion?(.success(()))
                } catch {
                    completion?(.failure(error))
                }
            }
        } catch {
            completion?(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            completion?(.failure(error))
        }
    }
}

// MARK: - Error Types

enum WhisperModelError: Error, LocalizedError {
    case downloadFailed
    case installFailed
    case modelNotFound
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download model"
        case .installFailed: return "Failed to install model"
        case .modelNotFound: return "Model file not found"
        case .cancelled: return "Download was cancelled"
        }
    }
}
