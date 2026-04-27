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

    /// In-memory remote name used to define the upload destination via env vars.
    /// rclone reads RCLONE_CONFIG_<NAME>_* from the environment, so the secret never appears on argv.
    private static let remoteName = "upload"

    /// Hard upper bounds for rclone subprocess runtime. Cancels the process if exceeded.
    private static let uploadTimeoutSeconds: UInt64 = 6 * 60 * 60   // 6h — large media uploads
    private static let testTimeoutSeconds: UInt64 = 60               // listing one dir
    private static let obscureTimeoutSeconds: UInt64 = 5             // pure local CPU

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

        let remoteEnv = try await buildRemoteEnvironment(config: config, rclonePath: rclonePath)
        let destination = uploadDestination(for: config)

        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        var args: [String] = ["copy", localFile.path, destination]
        args.append(contentsOf: [
            "--config=/dev/null",     // Don't read user's ~/.config/rclone/rclone.conf
            "--progress",
            "--stats=1s",
            "--stats-one-line",
            "--contimeout=30s",
            "--timeout=300s",
            "--retries=1"
        ])

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = args
        process.environment = mergedEnvironment(with: remoteEnv)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        currentProcess = process

        let startTime = Date()
        let state = UploadProgressState()

        logger.info("[rclone] Starting upload: \(localFile.lastPathComponent, privacy: .private) -> \(destination, privacy: .private)")
        // Command no longer contains secrets — every credential lives in env vars now.
        logger.info("[rclone] Command: rclone \(args.joined(separator: " "), privacy: .private)")

        let logger = self.logger

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    logger.debug("[rclone stderr] \(trimmed, privacy: .private)")

                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        progress(uploadProgress.percentage, uploadProgress.speed)
                    }

                    if let error = RcloneProgressParser.parseError(trimmed) {
                        state.lastError = error
                        // Log a category, not the raw rclone string — the string can include hostnames or paths.
                        logger.error("[rclone] error category: \(categorizeError(error), privacy: .public)")
                    }
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let line = String(data: data, encoding: .utf8) {
                for singleLine in line.components(separatedBy: .newlines) {
                    let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }

                    logger.debug("[rclone stdout] \(trimmed, privacy: .private)")

                    if let uploadProgress = RcloneProgressParser.parse(trimmed) {
                        state.bytesTransferred = uploadProgress.bytesTransferred
                        progress(uploadProgress.percentage, uploadProgress.speed)
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            currentProcess = nil
            throw UploadError.uploadFailed(error.localizedDescription)
        }

        let timedOut = await waitWithTimeout(process: process, seconds: Self.uploadTimeoutSeconds)

        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        let duration = Date().timeIntervalSince(startTime)

        if timedOut {
            throw UploadError.connectionFailed("Upload exceeded time limit and was cancelled")
        }

        if process.terminationStatus != 0 {
            let raw = state.lastError ?? "Upload failed with exit code \(process.terminationStatus)"
            let safeMessage = sanitizeErrorMessage(raw)

            if categorizeError(raw) == .authentication {
                throw UploadError.authenticationFailed
            }
            if categorizeError(raw) == .connection {
                throw UploadError.connectionFailed(safeMessage)
            }
            throw UploadError.uploadFailed(safeMessage)
        }

        progress(1.0, nil)

        let remotePath = config.remotePath + "/" + localFile.lastPathComponent
        logger.info("Upload complete: \(localFile.lastPathComponent, privacy: .private)")

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

        let remoteEnv = try await buildRemoteEnvironment(config: config, rclonePath: rclonePath)
        let destination = uploadDestination(for: config)

        let process = Process()
        let stderrPipe = Pipe()

        let args: [String] = [
            "lsd", destination,
            "--config=/dev/null",
            "--contimeout=15s",
            "--timeout=30s",
            "--retries=1"
        ]

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = args
        process.environment = mergedEnvironment(with: remoteEnv)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw UploadError.connectionFailed(error.localizedDescription)
        }

        let timedOut = await waitWithTimeout(process: process, seconds: Self.testTimeoutSeconds)
        if timedOut {
            throw UploadError.connectionFailed("Connection test timed out")
        }

        if process.terminationStatus != 0 {
            let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: errorData, encoding: .utf8) ?? "Unknown error"

            if categorizeError(raw) == .authentication {
                throw UploadError.authenticationFailed
            }
            throw UploadError.connectionFailed(sanitizeErrorMessage(raw))
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

    /// Builds the destination path for an upload using the in-memory remote name.
    /// Returns e.g. "upload:/uploads/videos", "upload:share/path", "upload:bucket/path".
    private func uploadDestination(for config: UploadConfig) -> String {
        let name = Self.remoteName
        switch config.backendType {
        case .ftp, .sftp:
            let path = config.remotePath.hasPrefix("/") ? config.remotePath : "/\(config.remotePath)"
            return "\(name):\(path)"
        case .smb:
            let share = config.smbShare ?? ""
            let stripped = config.remotePath.hasPrefix("/") ? String(config.remotePath.dropFirst()) : config.remotePath
            return stripped.isEmpty ? "\(name):\(share)" : "\(name):\(share)/\(stripped)"
        case .s3:
            let bucket = config.s3Bucket ?? ""
            let stripped = config.remotePath.hasPrefix("/") ? String(config.remotePath.dropFirst()) : config.remotePath
            return stripped.isEmpty ? "\(name):\(bucket)" : "\(name):\(bucket)/\(stripped)"
        case .gdrive:
            let path = config.remotePath.hasPrefix("/") ? config.remotePath : "/\(config.remotePath)"
            return "\(name):\(path)"
        }
    }

    /// Builds the RCLONE_CONFIG_<NAME>_* environment variables that define the upload remote in-memory.
    /// Secrets travel through environment variables, never through process arguments — `ps` cannot see them.
    private func buildRemoteEnvironment(
        config: UploadConfig,
        rclonePath: String
    ) async throws -> [String: String] {
        let prefix = "RCLONE_CONFIG_\(Self.remoteName.uppercased())_"
        var env: [String: String] = [:]

        switch config.backendType {
        case .ftp:
            // try? on `throws -> String?` flattens to `String?` (SE-0230) — single unwrap is correct.
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscured = try await obscurePassword(password, rclonePath: rclonePath)

            env["\(prefix)TYPE"] = "ftp"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username
            env["\(prefix)PASS"] = obscured
            if config.useFTPS {
                env["\(prefix)TLS"] = "true"
            }

        case .sftp:
            env["\(prefix)TYPE"] = "sftp"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username

            if let keyFilePath = config.sftpKeyFilePath, !keyFilePath.isEmpty {
                env["\(prefix)KEY_FILE"] = keyFilePath
            } else {
                guard let password = try? KeychainCredentialManager.shared.getCredential(
                    server: config.server,
                    username: config.username
                ) else {
                    throw UploadError.passwordNotFound
                }
                let obscured = try await obscurePassword(password, rclonePath: rclonePath)
                env["\(prefix)PASS"] = obscured
            }

        case .smb:
            guard let password = try? KeychainCredentialManager.shared.getCredential(
                server: config.server,
                username: config.username
            ) else {
                throw UploadError.passwordNotFound
            }
            let obscured = try await obscurePassword(password, rclonePath: rclonePath)

            env["\(prefix)TYPE"] = "smb"
            env["\(prefix)HOST"] = config.server
            env["\(prefix)PORT"] = String(config.port)
            env["\(prefix)USER"] = config.username
            env["\(prefix)PASS"] = obscured
            if let domain = config.smbDomain, !domain.isEmpty {
                env["\(prefix)DOMAIN"] = domain
            }

        case .s3:
            guard let accessKeyID = config.s3AccessKeyID, !accessKeyID.isEmpty else {
                throw UploadError.configurationMissing
            }
            guard let secretKey = try? KeychainCredentialManager.shared.getS3SecretKey(accessKeyID: accessKeyID) else {
                throw UploadError.passwordNotFound
            }

            env["\(prefix)TYPE"] = "s3"
            if let endpoint = config.s3Endpoint, !endpoint.isEmpty {
                env["\(prefix)PROVIDER"] = "Other"
                env["\(prefix)ENDPOINT"] = endpoint
            } else {
                env["\(prefix)PROVIDER"] = "AWS"
            }
            if let region = config.s3Region, !region.isEmpty {
                env["\(prefix)REGION"] = region
            }
            env["\(prefix)ACCESS_KEY_ID"] = accessKeyID
            env["\(prefix)SECRET_ACCESS_KEY"] = secretKey

        case .gdrive:
            throw UploadError.uploadFailed("Google Drive backend not yet implemented")
        }

        return env
    }

    /// Merges our remote-config env vars on top of the parent process environment.
    /// Replacing the env wholesale would strip PATH/HOME/etc. and break rclone's own behaviour.
    private func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (k, v) in overrides { env[k] = v }
        // Defense-in-depth: ensure rclone never reads a stray config file from the user's home directory.
        env["RCLONE_CONFIG"] = "/dev/null"
        return env
    }

    /// Waits up to `seconds` for the process to exit. Returns true if a timeout fired and the process was terminated.
    /// Uses `terminationHandler` instead of `waitUntilExit()` so the timeout watchdog actually races the process.
    private func waitWithTimeout(process: Process, seconds: UInt64) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation: continuation)

            process.terminationHandler = { _ in
                gate.resume(with: false)
            }

            // If the process already finished before terminationHandler was wired (rare race), drain immediately.
            if !process.isRunning {
                gate.resume(with: false)
                return
            }

            Task.detached {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { process.interrupt() }
                gate.resume(with: true)
            }
        }
    }

    /// Obscures a password using rclone's `obscure` subcommand.
    /// Reads the password from stdin (`rclone obscure -`) so it never appears on argv / `ps` output.
    private func obscurePassword(_ password: String, rclonePath: String) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = ["obscure", "-"]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdinPipe
        // Don't inherit RCLONE_CONFIG_* from a parent invocation — obscure doesn't need them and they'd just be noise.
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
        } catch {
            throw UploadError.uploadFailed("Failed to launch rclone: \(error.localizedDescription)")
        }

        // rclone obscure reads one line from stdin.
        let writeHandle = stdinPipe.fileHandleForWriting
        if let data = (password + "\n").data(using: .utf8) {
            try? writeHandle.write(contentsOf: data)
        }
        try? writeHandle.close()

        let timedOut = await waitWithTimeout(process: process, seconds: Self.obscureTimeoutSeconds)
        if timedOut {
            throw UploadError.uploadFailed("Failed to obscure password: timed out")
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let obscured = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !obscured.isEmpty else {
            throw UploadError.uploadFailed("Failed to obscure password")
        }
        return obscured
    }
}

// MARK: - Resume-once continuation gate

/// One-shot gate around a CheckedContinuation so concurrent callers (terminationHandler + watchdog)
/// can race to resume without crashing the runtime. Whoever wins, wins; the loser is a no-op.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Bool, Never>

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Bool) {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
    }
}

// MARK: - Error sanitization

private enum RcloneErrorCategory: String, CustomStringConvertible {
    case authentication
    case connection
    case other

    var description: String { rawValue }
}

/// Categorize an rclone error string into a small enum so we can surface a generic UploadError
/// without including the raw message (which can contain hostnames, paths, or partial credentials).
private func categorizeError(_ message: String) -> RcloneErrorCategory {
    let lower = message.lowercased()
    if lower.contains("authentication") || lower.contains("530")
        || lower.contains("logon_failure") || lower.contains("accessdenied")
        || lower.contains("invalidaccesskeyid") || lower.contains("login") {
        return .authentication
    }
    if lower.contains("connection") || lower.contains("timeout")
        || lower.contains("no such host") || lower.contains("network is unreachable")
        || lower.contains("no route to host") {
        return .connection
    }
    return .other
}

/// Strips embedded credentials from URLs and bounds the length so error messages stay safe to log/display.
private func sanitizeErrorMessage(_ message: String) -> String {
    var sanitized = message
    // Strip user:pass@ from URLs.
    if let regex = try? NSRegularExpression(pattern: #"(https?|ftp|sftp)://[^/\s:]+:[^@\s]+@"#, options: []) {
        sanitized = regex.stringByReplacingMatches(
            in: sanitized,
            options: [],
            range: NSRange(sanitized.startIndex..., in: sanitized),
            withTemplate: "$1://[redacted]@"
        )
    }
    sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    if sanitized.count > 500 {
        sanitized = String(sanitized.prefix(500)) + "…"
    }
    return sanitized
}
