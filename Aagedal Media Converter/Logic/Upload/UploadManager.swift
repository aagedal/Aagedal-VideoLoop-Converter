// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftUI

/// Manages the upload queue and coordinates uploads after conversion
@MainActor
@Observable
class UploadManager {
    static let shared = UploadManager()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "UploadManager")
    private let rcloneService = RcloneService()
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]

    /// Reference to video items for updating status
    var videoItems: Binding<[VideoItem]>?

    /// Whether upload is configured and available
    var isConfigured: Bool {
        guard let config = loadUploadConfig() else { return false }
        return config.isConfigured && RcloneUpdateService.shared.getInstallationStatus().isAvailable
    }

    /// Whether rclone is installed
    var isRcloneInstalled: Bool {
        RcloneUpdateService.shared.getInstallationStatus().isAvailable
    }

    private init() {}

    // MARK: - Public Methods

    /// Queues an upload for a completed conversion
    func queueUpload(itemID: UUID) {
        guard let index = findItemIndex(itemID) else {
            logger.warning("Cannot queue upload: item \(itemID) not found")
            return
        }

        videoItems?.wrappedValue[index].uploadStatus = .pending
        logger.info("Queued upload for item: \(itemID)")

        // Start upload immediately (non-blocking)
        Task {
            await startUpload(itemID: itemID)
        }
    }

    /// Starts upload for an item
    func startUpload(itemID: UUID) async {
        logger.info("Starting upload for item: \(itemID)")
        let hasBinding = self.videoItems != nil
        logger.info("videoItems binding set: \(hasBinding)")

        guard let index = findItemIndex(itemID) else {
            logger.warning("Cannot start upload: item \(itemID) not found")
            let itemCount = self.videoItems?.wrappedValue.count ?? -1
            logger.warning("Total items in binding: \(itemCount)")
            return
        }

        let itemName = self.videoItems?.wrappedValue[index].name ?? "unknown"
        logger.info("Found item at index \(index): \(itemName)")

        guard let config = loadUploadConfig() else {
            logger.warning("Cannot start upload: no configuration")
            videoItems?.wrappedValue[index].uploadStatus = .failed("Upload not configured")
            return
        }

        logger.info("Upload config loaded: server=\(config.server), path=\(config.remotePath)")

        let item = videoItems?.wrappedValue[index]
        let isSourceUpload = item?.uploadSourceFile ?? false
        guard let fileURL = item?.fileToUpload else {
            let errorMsg = isSourceUpload ? "No source file" : "No output file"
            logger.warning("Cannot start upload: \(errorMsg)")
            videoItems?.wrappedValue[index].uploadStatus = .failed(errorMsg)
            return
        }

        logger.info("\(isSourceUpload ? "Source" : "Output") file: \(fileURL.path)")

        // Cancel any existing upload task for this item
        uploadTasks[itemID]?.cancel()

        // Create new upload task
        let task = Task { [weak self] in
            guard let self = self else { return }

            await MainActor.run {
                if let idx = self.findItemIndex(itemID) {
                    self.videoItems?.wrappedValue[idx].uploadStatus = .uploading
                    self.videoItems?.wrappedValue[idx].uploadProgress = 0.0
                }
            }

            do {
                let result = try await self.rcloneService.upload(
                    localFile: fileURL,
                    config: config
                ) { [weak self] progress, speed in
                    print("[UploadManager] Progress callback: \(Int(progress * 100))%, speed: \(speed ?? "nil")")
                    Task { @MainActor in
                        guard let self = self,
                              let idx = self.findItemIndex(itemID) else {
                            print("[UploadManager] Could not find item \(itemID) for progress update")
                            return
                        }
                        self.videoItems?.wrappedValue[idx].uploadProgress = progress
                        self.videoItems?.wrappedValue[idx].uploadSpeed = speed
                    }
                }

                await MainActor.run {
                    if let idx = self.findItemIndex(itemID) {
                        if result.success {
                            self.videoItems?.wrappedValue[idx].uploadStatus = .uploaded
                            self.videoItems?.wrappedValue[idx].uploadedRemotePath = result.remotePath
                            self.videoItems?.wrappedValue[idx].uploadProgress = 1.0
                            self.logger.info("Upload complete for \(itemID)")
                        } else {
                            self.videoItems?.wrappedValue[idx].uploadStatus = .failed(result.errorMessage ?? "Unknown error")
                            self.logger.error("Upload failed for \(itemID): \(result.errorMessage ?? "Unknown")")
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if let idx = self.findItemIndex(itemID) {
                        self.videoItems?.wrappedValue[idx].uploadStatus = .failed(error.localizedDescription)
                        self.logger.error("Upload error for \(itemID): \(error.localizedDescription)")
                    }
                }
            }

            _ = await MainActor.run {
                self.uploadTasks.removeValue(forKey: itemID)
            }
        }

        uploadTasks[itemID] = task
    }

    /// Cancels an upload in progress
    func cancelUpload(itemID: UUID) async {
        uploadTasks[itemID]?.cancel()
        uploadTasks.removeValue(forKey: itemID)

        await rcloneService.cancelUpload()

        if let index = findItemIndex(itemID) {
            videoItems?.wrappedValue[index].uploadStatus = .cancelled
            videoItems?.wrappedValue[index].uploadProgress = 0.0
            videoItems?.wrappedValue[index].uploadSpeed = nil
        }

        logger.info("Cancelled upload for item: \(itemID)")
    }

    /// Retries a failed upload
    func retryUpload(itemID: UUID) async {
        guard let index = findItemIndex(itemID) else { return }

        // Reset status
        videoItems?.wrappedValue[index].uploadStatus = .pending
        videoItems?.wrappedValue[index].uploadProgress = 0.0
        videoItems?.wrappedValue[index].uploadSpeed = nil

        await startUpload(itemID: itemID)
    }

    /// Cancels all uploads
    func cancelAllUploads() async {
        for (itemID, task) in uploadTasks {
            task.cancel()
            if let index = findItemIndex(itemID) {
                videoItems?.wrappedValue[index].uploadStatus = .cancelled
            }
        }
        uploadTasks.removeAll()
        await rcloneService.cancelUpload()
    }

    // MARK: - Configuration

    /// Loads the current upload configuration from UserDefaults
    func loadUploadConfig() -> UploadConfig? {
        // Read backend type
        let backendTypeRaw = UserDefaults.standard.string(forKey: AppConstants.uploadBackendTypeKey) ?? "ftp"
        let backendType = UploadBackendType(rawValue: backendTypeRaw) ?? .ftp

        // Read common fields
        let server = UserDefaults.standard.string(forKey: AppConstants.uploadServerKey) ?? ""
        let port = UserDefaults.standard.integer(forKey: AppConstants.uploadPortKey)
        let username = UserDefaults.standard.string(forKey: AppConstants.uploadUsernameKey) ?? ""
        let remotePath = UserDefaults.standard.string(forKey: AppConstants.uploadRemotePathKey) ?? "/"
        let useFTPS = UserDefaults.standard.bool(forKey: AppConstants.uploadUseFTPSKey)

        // Create config with common fields
        var config = UploadConfig(
            server: server,
            port: port > 0 ? port : backendType.defaultPort,
            username: username,
            remotePath: remotePath,
            useFTPS: useFTPS,
            backendType: backendType
        )

        // Load backend-specific fields
        switch backendType {
        case .ftp:
            // FTP uses common fields only
            break

        case .sftp:
            config.sftpKeyFilePath = UserDefaults.standard.string(forKey: AppConstants.uploadSFTPKeyFileKey)

        case .smb:
            config.smbShare = UserDefaults.standard.string(forKey: AppConstants.uploadSMBShareKey)
            config.smbDomain = UserDefaults.standard.string(forKey: AppConstants.uploadSMBDomainKey)

        case .s3:
            config.s3Bucket = UserDefaults.standard.string(forKey: AppConstants.uploadS3BucketKey)
            config.s3Region = UserDefaults.standard.string(forKey: AppConstants.uploadS3RegionKey)
            config.s3Endpoint = UserDefaults.standard.string(forKey: AppConstants.uploadS3EndpointKey)
            config.s3AccessKeyID = UserDefaults.standard.string(forKey: AppConstants.uploadS3AccessKeyKey)

        case .gdrive:
            // Not yet implemented
            break
        }

        return config.isConfigured ? config : nil
    }

    /// Tests the current upload configuration
    func testConnection() async throws -> Bool {
        guard let config = loadUploadConfig() else {
            throw UploadError.configurationMissing
        }

        return try await rcloneService.testConnection(config: config)
    }

    // MARK: - Private Methods

    private func findItemIndex(_ id: UUID) -> Int? {
        videoItems?.wrappedValue.firstIndex(where: { $0.id == id })
    }
}
