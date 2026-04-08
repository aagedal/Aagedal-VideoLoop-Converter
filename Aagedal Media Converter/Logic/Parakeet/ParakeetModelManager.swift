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

    // MARK: - Python Resolution

    /// Resolves the Python interpreter from a pip/uv/Homebrew-installed script's shebang.
    /// This finds the virtualenv Python that has access to the script's dependencies (like huggingface_hub).
    private nonisolated func resolveVenvPython(for scriptPath: String) throws -> String {
        // If it's a standalone binary (e.g. PyInstaller), we can't extract a Python interpreter
        if HomebrewPythonExecutor.isStandaloneBinary(at: scriptPath) {
            // Fall back to system Python (may not have huggingface_hub)
            let systemCandidates = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3"
            ]
            if let path = systemCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return path
            }
            throw ParakeetModelDownloadError.pythonNotFound
        }

        // Read the shebang line from the script
        let resolvedPath = (scriptPath as NSString).resolvingSymlinksInPath
        guard let data = FileManager.default.contents(atPath: resolvedPath),
              let content = String(data: data, encoding: .utf8) else {
            throw ParakeetModelDownloadError.pythonNotFound
        }

        let firstLine = content.components(separatedBy: .newlines).first ?? ""
        guard firstLine.hasPrefix("#!") else {
            throw ParakeetModelDownloadError.pythonNotFound
        }

        let shebangPath = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        // The shebang Python is the virtualenv interpreter — it has access to all installed packages
        // e.g. #!/Users/user/.local/share/uv/tools/parakeet-mlx/bin/python
        // e.g. #!/opt/homebrew/Cellar/parakeet-mlx/1.0/libexec/bin/python
        if FileManager.default.isExecutableFile(atPath: shebangPath) {
            return shebangPath
        }

        // Try Homebrew detection as fallback
        if let info = HomebrewPythonExecutor.executionInfo(for: scriptPath) {
            let candidates = [info.mainPythonPath, info.pythonPath]
            if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return path
            }
        }

        throw ParakeetModelDownloadError.pythonNotFound
    }

    // MARK: - Model Download

    private var downloadProcess: Process?

    /// Downloads a model using the huggingface_hub Python package (available because parakeet-mlx depends on it).
    /// Since parakeet-mlx is a Python package, huggingface_hub is guaranteed to be in the same environment.
    func downloadModel(
        _ model: ParakeetModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let parakeetPath = BinaryPathResolver.parakeetMlxPath else {
            throw ParakeetModelDownloadError.parakeetNotInstalled
        }

        guard !isModelDownloaded(model) else {
            logger.info("Model \(model.id) is already downloaded")
            progress(1.0)
            return
        }

        logger.info("Starting download of Parakeet model: \(model.displayName)")
        progress(0.0)

        // Use a Python script that reports download progress on stdout as "PROGRESS:<0-100>" lines.
        // huggingface_hub's tqdm uses \r carriage returns on stderr which are hard to parse from pipes.
        // Instead, we use the low-level hf_hub_download per-file and track bytes ourselves.
        let pythonScript = """
        import sys, os
        from huggingface_hub import HfApi, hf_hub_download
        from huggingface_hub.utils import tqdm as hf_tqdm

        repo_id = "\(model.id)"
        api = HfApi()

        # Get list of files and their sizes
        files = api.list_repo_files(repo_id)
        model_info = api.repo_info(repo_id)
        siblings = model_info.siblings or []
        file_sizes = {s.rfilename: (s.size or 0) for s in siblings}
        total_bytes = sum(file_sizes.values())
        downloaded_bytes = 0

        print(f"TOTAL_FILES:{len(files)}", flush=True)
        print(f"TOTAL_BYTES:{total_bytes}", flush=True)

        for i, filename in enumerate(files):
            fsize = file_sizes.get(filename, 0)
            print(f"FILE:{i+1}/{len(files)}:{filename}:{fsize}", flush=True)
            hf_hub_download(repo_id, filename)
            downloaded_bytes += fsize
            if total_bytes > 0:
                pct = min(int(downloaded_bytes * 100 / total_bytes), 99)
                print(f"PROGRESS:{pct}", flush=True)

        print("PROGRESS:100", flush=True)
        print("DOWNLOAD_COMPLETE", flush=True)
        """

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        // Resolve Python from parakeet-mlx's environment.
        let pythonPath = try resolveVenvPython(for: parakeetPath)
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-u", "-c", pythonScript]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        // Disable tqdm progress bars on stderr to avoid noise
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        process.environment = env

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        downloadProcess = process

        // Buffer for partial line reads
        final class OutputBuffer: @unchecked Sendable {
            var buffer = ""
        }
        let stdoutBuffer = OutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

            stdoutBuffer.buffer += chunk
            // Process complete lines
            while let newlineRange = stdoutBuffer.buffer.range(of: "\n") {
                let line = String(stdoutBuffer.buffer[stdoutBuffer.buffer.startIndex..<newlineRange.lowerBound])
                stdoutBuffer.buffer = String(stdoutBuffer.buffer[newlineRange.upperBound...])

                self?.logger.info("parakeet-download: \(line, privacy: .public)")

                if line.hasPrefix("PROGRESS:") {
                    let numStr = String(line.dropFirst("PROGRESS:".count))
                    if let pct = Double(numStr) {
                        Task { @MainActor in progress(min(pct / 100.0, 0.99)) }
                    }
                } else if line.hasPrefix("FILE:") {
                    // Log file being downloaded: FILE:1/5:config.json:1234
                    self?.logger.info("Downloading: \(line, privacy: .public)")
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self?.logger.warning("parakeet-download stderr: \(trimmed, privacy: .public)")
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            downloadProcess = nil
            throw ParakeetModelDownloadError.downloadFailed(error.localizedDescription)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        downloadProcess = nil

        guard process.terminationStatus == 0 else {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            let lastLine = errorOutput.components(separatedBy: .newlines)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            throw ParakeetModelDownloadError.downloadFailed(
                "Exit code \(process.terminationStatus)" + (lastLine.isEmpty ? "" : ": \(lastLine)")
            )
        }

        // Verify the model is now cached
        guard isModelDownloaded(model) else {
            throw ParakeetModelDownloadError.downloadFailed("Model not found in cache after download")
        }

        progress(1.0)
        logger.info("Successfully downloaded Parakeet model: \(model.displayName)")
    }

    /// Cancels an ongoing model download
    func cancelDownload() {
        if let process = downloadProcess, process.isRunning {
            process.terminate()
            downloadProcess = nil
            logger.info("Cancelled Parakeet model download")
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

// MARK: - Error Types

enum ParakeetModelDownloadError: Error, LocalizedError {
    case parakeetNotInstalled
    case pythonNotFound
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .parakeetNotInstalled:
            return "parakeet-mlx is not installed. Install with: pip install -U parakeet-mlx"
        case .pythonNotFound:
            return "Could not find a Python interpreter to download models"
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        }
    }
}
