// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Upload Configuration

/// Configuration for uploading files to a remote server
struct UploadConfig: Codable, Sendable, Equatable {
    var server: String
    var port: Int
    var username: String
    var remotePath: String
    var useFTPS: Bool
    var backendType: UploadBackendType

    init(
        server: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useFTPS: Bool = false,
        backendType: UploadBackendType = .ftp
    ) {
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useFTPS = useFTPS
        self.backendType = backendType
    }

    /// Whether the configuration has minimum required fields filled
    var isConfigured: Bool {
        !server.isEmpty && !username.isEmpty
    }

    /// Builds the rclone remote path string
    /// e.g., ":ftp:/uploads/videos"
    var rcloneRemotePath: String {
        let backend = backendType.rcloneBackendName
        let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        return ":\(backend):\(path)"
    }
}

// MARK: - Backend Types

/// Supported upload backend types (rclone remotes)
enum UploadBackendType: String, Codable, CaseIterable, Sendable {
    case ftp = "ftp"
    case sftp = "sftp"
    case s3 = "s3"
    case gdrive = "drive"

    var displayName: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .s3: return "Amazon S3"
        case .gdrive: return "Google Drive"
        }
    }

    var rcloneBackendName: String {
        return rawValue
    }

    /// Icon name for this backend
    var iconName: String {
        switch self {
        case .ftp, .sftp: return "externaldrive.connected.to.line.below"
        case .s3: return "cloud"
        case .gdrive: return "folder"
        }
    }

    /// Whether this backend requires a password (vs OAuth)
    var requiresPassword: Bool {
        switch self {
        case .ftp, .sftp: return true
        case .s3, .gdrive: return false
        }
    }
}

// MARK: - Upload Status

/// Status of an upload operation
enum UploadStatus: Equatable, Sendable {
    case notQueued
    case pending
    case uploading
    case uploaded
    case failed(String)
    case cancelled

    var displayText: String {
        switch self {
        case .notQueued: return ""
        case .pending: return "Waiting to upload"
        case .uploading: return "Uploading..."
        case .uploaded: return "Uploaded"
        case .failed(let error): return "Upload failed: \(error)"
        case .cancelled: return "Upload cancelled"
        }
    }

    var isActive: Bool {
        switch self {
        case .pending, .uploading: return true
        default: return false
        }
    }

    var isComplete: Bool {
        switch self {
        case .uploaded: return true
        default: return false
        }
    }

    var hasFailed: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Upload Result

/// Result of a completed upload operation
struct UploadResult: Sendable {
    let success: Bool
    let remotePath: String?
    let bytesTransferred: Int64
    let duration: TimeInterval
    let errorMessage: String?

    static func success(remotePath: String, bytes: Int64, duration: TimeInterval) -> UploadResult {
        UploadResult(
            success: true,
            remotePath: remotePath,
            bytesTransferred: bytes,
            duration: duration,
            errorMessage: nil
        )
    }

    static func failure(error: String) -> UploadResult {
        UploadResult(
            success: false,
            remotePath: nil,
            bytesTransferred: 0,
            duration: 0,
            errorMessage: error
        )
    }
}

// MARK: - Upload Progress

/// Progress information for an upload operation
struct UploadProgress: Sendable {
    let bytesTransferred: Int64
    let totalBytes: Int64
    let percentage: Double
    let speed: String?
    let eta: String?

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let transferred = formatter.string(fromByteCount: bytesTransferred)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(transferred) / \(total)"
    }
}

// MARK: - Upload Error

enum UploadError: Error, LocalizedError {
    case rcloneNotFound
    case configurationMissing
    case connectionFailed(String)
    case authenticationFailed
    case uploadFailed(String)
    case cancelled
    case passwordNotFound

    var errorDescription: String? {
        switch self {
        case .rcloneNotFound:
            return "rclone is not installed. Please download it in Settings > Upload."
        case .configurationMissing:
            return "Upload configuration is incomplete. Please configure in Settings > Upload."
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .authenticationFailed:
            return "Authentication failed. Please check your username and password."
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .cancelled:
            return "Upload was cancelled"
        case .passwordNotFound:
            return "Password not found in Keychain. Please re-enter your password in Settings."
        }
    }
}
