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
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneService")
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

        // Build backend-specific arguments and get credentials
        let backendArgs = try await buildBackendArguments(config: config, rclonePath: rclonePath)

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
        args.append(contentsOf: backendArgs)

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
        // Log command with secrets masked
        let sanitizedArgs = args.map { arg in
            if arg.contains("-pass=") || arg.contains("-secret-access-key=") {
                let prefix = arg.split(separator: "=").first ?? ""
                return "\(prefix)=***"
            }
            return arg
        }
        logger.info("[rclone] Command: rclone \(sanitizedArgs.joined(separator: " "))")

        // Capture logger for use in non-isolated closures
        let logger = self.logger

        // Handle stderr for progress updates
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Log all rclone output for debugging
                    logger.debug("[rclone stderr] \(trimmed, privacy: .public)")

                    // Parse progress
                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        logger.debug("[rclone] Progress parsed: \(Int(uploadProgress.percentage * 100))% - \(uploadProgress.speed ?? "?", privacy: .public)")
                        progress(uploadProgress.percentage, uploadProgress.speed)
                    }

                    // Check for errors
                    if let error = RcloneProgressParser.parseError(trimmed) {
                        state.lastError = error
                        logger.error("[rclone] Error detected: \(error, privacy: .public)")
                    }
                }
            }
        }

        // Also check stdout
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    // Log all rclone output for debugging
                    logger.debug("[rclone stdout] \(trimmed, privacy: .public)")

                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        logger.debug("[rclone] Progress parsed: \(Int(uploadProgress.percentage * 100))% - \(uploadProgress.speed ?? "?", privacy: .public)")
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

        // Build backend-specific arguments
        let backendArgs = try await buildBackendArguments(config: config, rclonePath: rclonePath)

        let process = Process()
        let stderrPipe = Pipe()

        // Use rclone lsd to list directories (quick test)
        var args: [String] = ["lsd"]
        args.append(config.rcloneRemotePath)
        args.append(contentsOf: backendArgs)

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

            if errorMessage.contains("530") || errorMessage.contains("Login") ||
               errorMessage.contains("LOGON_FAILURE") || errorMessage.contains("AccessDenied") ||
               errorMessage.contains("InvalidAccessKeyId") {
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

    /// Builds backend-specific rclone arguments
    private func buildBackendArguments(config: UploadConfig, rclonePath: String) async throws -> [String] {
        var args: [String] = []

        switch config.backendType {
        case .ftp:
            // Get password from Keychain
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscuredPassword = try await obscurePassword(password, rclonePath: rclonePath)

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
                "--sftp-user=\(config.username)"
            ])

            // SFTP can use either SSH key file or password
            if let keyFilePath = config.sftpKeyFilePath, !keyFilePath.isEmpty {
                args.append("--sftp-key-file=\(keyFilePath)")
            } else {
                // Use password authentication
                guard let password = try? KeychainCredentialManager.shared.getCredential(
                    server: config.server,
                    username: config.username
                ) else {
                    throw UploadError.passwordNotFound
                }
                let obscuredPassword = try await obscurePassword(password, rclonePath: rclonePath)
                args.append("--sftp-pass=\(obscuredPassword)")
            }

        case .smb:
            // Get password from Keychain
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscuredPassword = try await obscurePassword(password, rclonePath: rclonePath)

            args.append(contentsOf: [
                "--smb-host=\(config.server)",
                "--smb-port=\(config.port)",
                "--smb-user=\(config.username)",
                "--smb-pass=\(obscuredPassword)"
            ])
            if let domain = config.smbDomain, !domain.isEmpty {
                args.append("--smb-domain=\(domain)")
            }

        case .s3:
            // S3 uses access key ID and secret access key
            guard let accessKeyID = config.s3AccessKeyID, !accessKeyID.isEmpty else {
                throw UploadError.configurationMissing
            }

            // Get secret key from Keychain
            guard let secretKey = try? KeychainCredentialManager.shared.getS3SecretKey(accessKeyID: accessKeyID) else {
                throw UploadError.passwordNotFound
            }

            // Determine provider based on endpoint
            if let endpoint = config.s3Endpoint, !endpoint.isEmpty {
                args.append("--s3-provider=Other")
                args.append("--s3-endpoint=\(endpoint)")
            } else {
                args.append("--s3-provider=AWS")
            }

            if let region = config.s3Region, !region.isEmpty {
                args.append("--s3-region=\(region)")
            }

            args.append(contentsOf: [
                "--s3-access-key-id=\(accessKeyID)",
                "--s3-secret-access-key=\(secretKey)"
            ])

        case .gdrive:
            throw UploadError.uploadFailed("Google Drive backend not yet implemented")
        }

        return args
    }

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
