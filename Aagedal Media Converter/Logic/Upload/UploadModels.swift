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

// MARK: - FTP Profiles

struct FTPUploadProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var username: String
    var remotePath: String
    var useFTPS: Bool

    init(
        id: UUID = UUID(),
        name: String,
        server: String = "",
        port: Int = AppConstants.defaultUploadPort,
        username: String = "",
        remotePath: String = "/",
        useFTPS: Bool = false
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useFTPS = useFTPS
    }
}

enum FTPUploadProfileStore {
    static func loadProfiles() -> [FTPUploadProfile] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.uploadFTPProfilesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([FTPUploadProfile].self, from: data)) ?? []
    }

    static func saveProfiles(_ profiles: [FTPUploadProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: AppConstants.uploadFTPProfilesKey)
    }

    static func loadSelectedProfileID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.uploadFTPSelectedProfileIDKey),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        return id
    }

    static func saveSelectedProfileID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: AppConstants.uploadFTPSelectedProfileIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.uploadFTPSelectedProfileIDKey)
        }
    }

    static func resolveSelectedProfile(from profiles: [FTPUploadProfile]) -> FTPUploadProfile? {
        guard !profiles.isEmpty else { return nil }
        if let selectedID = loadSelectedProfileID(),
           let match = profiles.first(where: { $0.id == selectedID }) {
            return match
        }
        return profiles.first
    }
}

// MARK: - SFTP Profiles

struct SFTPUploadProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var username: String
    var remotePath: String
    var useKeyAuth: Bool
    var keyFilePath: String

    init(
        id: UUID = UUID(),
        name: String,
        server: String = "",
        port: Int = AppConstants.defaultSFTPPort,
        username: String = "",
        remotePath: String = "/",
        useKeyAuth: Bool = false,
        keyFilePath: String = ""
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.useKeyAuth = useKeyAuth
        self.keyFilePath = keyFilePath
    }
}

enum SFTPUploadProfileStore {
    static func loadProfiles() -> [SFTPUploadProfile] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.uploadSFTPProfilesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([SFTPUploadProfile].self, from: data)) ?? []
    }

    static func saveProfiles(_ profiles: [SFTPUploadProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: AppConstants.uploadSFTPProfilesKey)
    }

    static func loadSelectedProfileID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.uploadSFTPSelectedProfileIDKey),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        return id
    }

    static func saveSelectedProfileID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: AppConstants.uploadSFTPSelectedProfileIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.uploadSFTPSelectedProfileIDKey)
        }
    }

    static func resolveSelectedProfile(from profiles: [SFTPUploadProfile]) -> SFTPUploadProfile? {
        guard !profiles.isEmpty else { return nil }
        if let selectedID = loadSelectedProfileID(),
           let match = profiles.first(where: { $0.id == selectedID }) {
            return match
        }
        return profiles.first
    }
}

// MARK: - SMB Profiles

struct SMBUploadProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var server: String
    var port: Int
    var username: String
    var remotePath: String
    var smbShare: String
    var smbDomain: String

    init(
        id: UUID = UUID(),
        name: String,
        server: String = "",
        port: Int = AppConstants.defaultSMBPort,
        username: String = "",
        remotePath: String = "/",
        smbShare: String = "",
        smbDomain: String = ""
    ) {
        self.id = id
        self.name = name
        self.server = server
        self.port = port
        self.username = username
        self.remotePath = remotePath
        self.smbShare = smbShare
        self.smbDomain = smbDomain
    }
}

enum SMBUploadProfileStore {
    static func loadProfiles() -> [SMBUploadProfile] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.uploadSMBProfilesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([SMBUploadProfile].self, from: data)) ?? []
    }

    static func saveProfiles(_ profiles: [SMBUploadProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: AppConstants.uploadSMBProfilesKey)
    }

    static func loadSelectedProfileID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.uploadSMBSelectedProfileIDKey),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        return id
    }

    static func saveSelectedProfileID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: AppConstants.uploadSMBSelectedProfileIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.uploadSMBSelectedProfileIDKey)
        }
    }

    static func resolveSelectedProfile(from profiles: [SMBUploadProfile]) -> SMBUploadProfile? {
        guard !profiles.isEmpty else { return nil }
        if let selectedID = loadSelectedProfileID(),
           let match = profiles.first(where: { $0.id == selectedID }) {
            return match
        }
        return profiles.first
    }
}

// MARK: - S3 Profiles

struct S3UploadProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var bucket: String
    var region: String
    var endpoint: String
    var accessKeyID: String
    var remotePath: String

    init(
        id: UUID = UUID(),
        name: String,
        bucket: String = "",
        region: String = "us-east-1",
        endpoint: String = "",
        accessKeyID: String = "",
        remotePath: String = "/"
    ) {
        self.id = id
        self.name = name
        self.bucket = bucket
        self.region = region
        self.endpoint = endpoint
        self.accessKeyID = accessKeyID
        self.remotePath = remotePath
    }
}

enum S3UploadProfileStore {
    static func loadProfiles() -> [S3UploadProfile] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.uploadS3ProfilesKey) else {
            return []
        }
        return (try? JSONDecoder().decode([S3UploadProfile].self, from: data)) ?? []
    }

    static func saveProfiles(_ profiles: [S3UploadProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: AppConstants.uploadS3ProfilesKey)
    }

    static func loadSelectedProfileID() -> UUID? {
        guard let rawValue = UserDefaults.standard.string(forKey: AppConstants.uploadS3SelectedProfileIDKey),
              let id = UUID(uuidString: rawValue) else {
            return nil
        }
        return id
    }

    static func saveSelectedProfileID(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: AppConstants.uploadS3SelectedProfileIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.uploadS3SelectedProfileIDKey)
        }
    }

    static func resolveSelectedProfile(from profiles: [S3UploadProfile]) -> S3UploadProfile? {
        guard !profiles.isEmpty else { return nil }
        if let selectedID = loadSelectedProfileID(),
           let match = profiles.first(where: { $0.id == selectedID }) {
            return match
        }
        return profiles.first
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
