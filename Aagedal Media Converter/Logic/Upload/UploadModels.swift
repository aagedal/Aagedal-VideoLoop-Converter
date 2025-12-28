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

    // SFTP-specific
    var sftpKeyFilePath: String?

    // SMB-specific
    var smbShare: String?
    var smbDomain: String?

    // S3-specific
    var s3Bucket: String?
    var s3Region: String?
    var s3Endpoint: String?
    var s3AccessKeyID: String?

    init(
        server: String = "",
        port: Int = 21,
        username: String = "",
        remotePath: String = "/",
        useFTPS: Bool = false,
        backendType: UploadBackendType = .ftp,
        sftpKeyFilePath: String? = nil,
        smbShare: String? = nil,
        smbDomain: String? = nil,
        s3Bucket: String? = nil,
        s3Region: String? = nil,
        s3Endpoint: String? = nil,
        s3AccessKeyID: String? = nil
    ) {
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useFTPS = useFTPS
        self.backendType = backendType
        self.sftpKeyFilePath = sftpKeyFilePath
        self.smbShare = smbShare
        self.smbDomain = smbDomain
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.s3Endpoint = s3Endpoint
        self.s3AccessKeyID = s3AccessKeyID
    }

    /// Whether the configuration has minimum required fields filled
    var isConfigured: Bool {
        switch backendType {
        case .ftp, .sftp:
            return !server.isEmpty && !username.isEmpty
        case .smb:
            return !server.isEmpty && !username.isEmpty && !(smbShare ?? "").isEmpty
        case .s3:
            return !(s3Bucket ?? "").isEmpty && !(s3AccessKeyID ?? "").isEmpty
        case .gdrive:
            return false // Not yet implemented
        }
    }

    /// Builds the rclone remote path string
    /// e.g., ":ftp:/uploads/videos" or ":s3:bucket/folder"
    var rcloneRemotePath: String {
        let backend = backendType.rcloneBackendName
        switch backendType {
        case .ftp, .sftp:
            let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
            return ":\(backend):\(path)"
        case .smb:
            // SMB format: :smb:share/path
            let share = smbShare ?? ""
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            if path.isEmpty {
                return ":\(backend):\(share)"
            }
            return ":\(backend):\(share)/\(path)"
        case .s3:
            // S3 format: :s3:bucket/path
            let bucket = s3Bucket ?? ""
            let path = remotePath.hasPrefix("/") ? String(remotePath.dropFirst()) : remotePath
            if path.isEmpty {
                return ":\(backend):\(bucket)"
            }
            return ":\(backend):\(bucket)/\(path)"
        case .gdrive:
            let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
            return ":\(backend):\(path)"
        }
    }
}

// MARK: - Backend Types

/// Supported upload backend types (rclone remotes)
enum UploadBackendType: String, Codable, CaseIterable, Sendable {
    case ftp = "ftp"
    case sftp = "sftp"
    case smb = "smb"
    case s3 = "s3"
    case gdrive = "drive"

    var displayName: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .smb: return "SMB"
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
        case .smb: return "externaldrive.fill.badge.person.crop"
        case .s3: return "cloud"
        case .gdrive: return "folder"
        }
    }

    /// Whether this backend requires a password (vs OAuth or key-based auth)
    var requiresPassword: Bool {
        switch self {
        case .ftp, .smb: return true
        case .sftp: return true  // Can also use SSH key, handled separately
        case .s3, .gdrive: return false
        }
    }

    /// Default port for this backend
    var defaultPort: Int {
        switch self {
        case .ftp: return AppConstants.defaultUploadPort  // 21
        case .sftp: return AppConstants.defaultSFTPPort   // 22
        case .smb: return AppConstants.defaultSMBPort     // 445
        case .s3, .gdrive: return 0  // Not applicable
        }
    }

    /// Whether this backend is currently implemented
    var isImplemented: Bool {
        switch self {
        case .ftp, .sftp, .smb, .s3: return true
        case .gdrive: return false
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
