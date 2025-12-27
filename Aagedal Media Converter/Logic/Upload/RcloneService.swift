// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Thread-safe state container for upload progress
private final class UploadProgressState: @unchecked Sendable {
    var lastError: String?
    var bytesTransferred: Int64 = 0
}

/// Service for executing rclone uploads
actor RcloneService {
    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "RcloneService")
    private var currentProcess: Process?
    private let updateService = RcloneUpdateService.shared

    /// Uploads a file to a remote server using rclone
    /// - Parameters:
    ///   - localFile: The local file URL to upload
    ///   - config: The upload configuration (server, credentials, etc.)
    ///   - progress: Callback for progress updates (0-1, speed string)
    /// - Returns: The upload result
    func upload(
        localFile: URL,
        config: UploadConfig,
        progress: @escaping @Sendable (Double, String?) -> Void
    ) async throws -> UploadResult {
        guard let rclonePath = await updateService.resolveRclonePath() else {
            throw UploadError.rcloneNotFound
        }

        guard config.isConfigured else {
            throw UploadError.configurationMissing
        }

        // Get password from Keychain
        guard let password = try? KeychainCredentialManager.shared.getCredential(
            server: config.server,
            username: config.username
        ) else {
            throw UploadError.passwordNotFound
        }

        // Obscure the password for rclone
        let obscuredPassword = try await obscurePassword(password, rclonePath: rclonePath)

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        // Build rclone command
        // rclone copy /local/file.mp4 :ftp:/remote/path --ftp-host=... --ftp-user=... --ftp-pass=...
        var args: [String] = ["copy"]

        // Source file
        args.append(localFile.path)

        // Destination (rclone backend syntax)
        let remoteDest = config.rcloneRemotePath
        args.append(remoteDest)

        // Backend-specific options
        switch config.backendType {
        case .ftp:
            args.append(contentsOf: [
                "--ftp-host=\(config.server)",
                "--ftp-port=\(config.port)",
                "--ftp-user=\(config.username)",
                "--ftp-pass=\(obscuredPassword)"
            ])
            if config.useFTPS {
                args.append("--ftp-tls")
            }
        case .sftp:
            args.append(contentsOf: [
                "--sftp-host=\(config.server)",
                "--sftp-port=\(config.port)",
                "--sftp-user=\(config.username)",
                "--sftp-pass=\(obscuredPassword)"
            ])
        case .s3, .gdrive:
            // Future implementation
            throw UploadError.uploadFailed("Backend \(config.backendType.displayName) not yet implemented")
        }

        // Progress options
        args.append(contentsOf: [
            "--progress",
            "--stats=1s",
            "--stats-one-line",
            "-v"
        ])

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Store for cancellation
        currentProcess = process

        let startTime = Date()
        let state = UploadProgressState()

        logger.info("[rclone] Starting upload: \(localFile.lastPathComponent) -> \(config.rcloneRemotePath)")
        logger.info("[rclone] Command: rclone \(args.joined(separator: " ").replacingOccurrences(of: obscuredPassword, with: "***"))")

        // Handle stderr for progress updates
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Log all rclone output for debugging
                    logger.debug("[rclone stderr] \(trimmed)")

                    // Parse progress
                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        logger.info("[rclone] Progress: \(Int(uploadProgress.percentage * 100))% - \(uploadProgress.speed ?? "unknown speed")")
                        progress(uploadProgress.percentage, uploadProgress.speed)
                    }

                    // Check for errors
                    if let error = RcloneProgressParser.parseError(trimmed) {
                        state.lastError = error
                        logger.error("[rclone] Error detected: \(error)")
                    }
                }
            }
        }

        // Also check stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Log all rclone output for debugging
                    logger.debug("[rclone stdout] \(trimmed)")

                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        progress(uploadProgress.percentage, uploadProgress.speed)
                    }
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UploadError.uploadFailed(error.localizedDescription)
        }

        // Clean up
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        let duration = Date().timeIntervalSince(startTime)

        // Check exit status
        if process.terminationStatus != 0 {
            let errorMessage = state.lastError ?? "Upload failed with exit code \(process.terminationStatus)"

            // Check for specific error types
            if errorMessage.contains("authentication") || errorMessage.contains("530") {
                throw UploadError.authenticationFailed
            }
            if errorMessage.contains("connection") || errorMessage.contains("timeout") {
                throw UploadError.connectionFailed(errorMessage)
            }

            throw UploadError.uploadFailed(errorMessage)
        }

        // Report 100% progress
        progress(1.0, nil)

        let remotePath = config.remotePath + "/" + localFile.lastPathComponent
        logger.info("Upload complete: \(localFile.lastPathComponent) -> \(remotePath)")

        return UploadResult.success(
            remotePath: remotePath,
            bytes: state.bytesTransferred,
            duration: duration
        )
    }

    /// Tests connection to the remote server
    func testConnection(config: UploadConfig) async throws -> Bool {
        guard let rclonePath = await updateService.resolveRclonePath() else {
            throw UploadError.rcloneNotFound
        }

        guard config.isConfigured else {
            throw UploadError.configurationMissing
        }

        // Get password from Keychain
        guard let password = try? KeychainCredentialManager.shared.getCredential(
            server: config.server,
            username: config.username
        ) else {
            throw UploadError.passwordNotFound
        }

        let obscuredPassword = try await obscurePassword(password, rclonePath: rclonePath)

        let process = Process()
        let stderrPipe = Pipe()

        // Use rclone lsd to list directories (quick test)
        var args: [String] = ["lsd"]
        args.append(config.rcloneRemotePath)

        switch config.backendType {
        case .ftp:
            args.append(contentsOf: [
                "--ftp-host=\(config.server)",
                "--ftp-port=\(config.port)",
                "--ftp-user=\(config.username)",
                "--ftp-pass=\(obscuredPassword)"
            ])
            if config.useFTPS {
                args.append("--ftp-tls")
            }
        case .sftp:
            args.append(contentsOf: [
                "--sftp-host=\(config.server)",
                "--sftp-port=\(config.port)",
                "--sftp-user=\(config.username)",
                "--sftp-pass=\(obscuredPassword)"
            ])
        case .s3, .gdrive:
            throw UploadError.uploadFailed("Backend \(config.backendType.displayName) not yet implemented")
        }

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw UploadError.connectionFailed(error.localizedDescription)
        }

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            if errorMessage.contains("530") || errorMessage.contains("Login") {
                throw UploadError.authenticationFailed
            }
            throw UploadError.connectionFailed(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return true
    }

    /// Cancels the current upload
    func cancelUpload() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
            logger.info("Upload cancelled")
        }
    }

    // MARK: - Private Methods

    /// Obscures a password using rclone obscure
    private func obscurePassword(_ password: String, rclonePath: String) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["obscure", password]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdinPipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            guard let obscured = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !obscured.isEmpty else {
                throw UploadError.uploadFailed("Failed to obscure password")
            }
            return obscured
        } catch {
            throw UploadError.uploadFailed("Failed to obscure password: \(error.localizedDescription)")
        }
    }
}
