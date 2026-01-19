// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// C2PA (Content Authenticity) metadata structure
struct C2PAMetadata: Codable, Sendable, Equatable {
    let hasContentCredentials: Bool
    let claimGenerator: String?
    let manifestStore: String?
    let assertions: [String]?

    static let empty = C2PAMetadata(
        hasContentCredentials: false,
        claimGenerator: nil,
        manifestStore: nil,
        assertions: nil
    )
}

/// Service for extracting metadata using ExifTool
actor ExifToolService {
    static let shared = ExifToolService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "ExifToolService")

    private init() {}

    // MARK: - Path Resolution

    /// Gets the ExifTool path from the resolver
    nonisolated func getExifToolPath() -> String? {
        BinaryPathResolver.exiftoolPath
    }

    /// Checks if ExifTool is available
    nonisolated var isAvailable: Bool {
        getExifToolPath() != nil
    }

    // MARK: - General Metadata

    /// Gets all metadata from a file as a dictionary
    /// - Parameter url: The file to analyze
    /// - Returns: Dictionary of metadata tags and values
    func getMetadata(for url: URL) async throws -> [String: Any] {
        guard let exiftoolPath = getExifToolPath() else {
            throw ExifToolServiceError.notInstalled
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExifToolServiceError.fileNotFound
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        // -json: Output as JSON
        // -G: Include group names
        // -struct: Enable structured output
        process.arguments = ["-json", "-G", "-struct", url.path]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run ExifTool: \(error.localizedDescription)")
            throw ExifToolServiceError.executionFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: stderrData, encoding: .utf8) ?? "Unknown error"
            logger.error("ExifTool failed: \(errorMessage)")
            throw ExifToolServiceError.executionFailed(errorMessage)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = jsonArray.first else {
            throw ExifToolServiceError.parseError("Failed to parse JSON output")
        }

        return metadata
    }

    /// Gets specific metadata tags from a file
    /// - Parameters:
    ///   - tags: Array of tag names to retrieve
    ///   - url: The file to analyze
    /// - Returns: Dictionary of tag names to values
    func getTags(_ tags: [String], for url: URL) async throws -> [String: String] {
        guard let exiftoolPath = getExifToolPath() else {
            throw ExifToolServiceError.notInstalled
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExifToolServiceError.fileNotFound
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        // Build arguments with requested tags
        var arguments = ["-json"]
        for tag in tags {
            arguments.append("-\(tag)")
        }
        arguments.append(url.path)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ExifToolServiceError.executionFailed(error.localizedDescription)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = jsonArray.first else {
            return [:]
        }

        // Convert to string dictionary
        var result: [String: String] = [:]
        for (key, value) in metadata {
            if let stringValue = value as? String {
                result[key] = stringValue
            } else if let numberValue = value as? NSNumber {
                result[key] = numberValue.stringValue
            }
        }

        return result
    }

    // MARK: - C2PA (Content Authenticity)

    /// Checks if a file has C2PA (Content Authenticity) metadata
    /// - Parameter url: The file to check
    /// - Returns: true if C2PA metadata is present
    func hasC2PAMetadata(for url: URL) async throws -> Bool {
        guard let exiftoolPath = getExifToolPath() else {
            throw ExifToolServiceError.notInstalled
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExifToolServiceError.fileNotFound
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        // Check for C2PA namespace tags
        process.arguments = ["-json", "-XMP-c2pa:all", url.path]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ExifToolServiceError.executionFailed(error.localizedDescription)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        // Parse JSON to check if there are any C2PA tags
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = jsonArray.first else {
            return false
        }

        // Check if there are any keys besides SourceFile
        let c2paKeys = metadata.keys.filter { $0 != "SourceFile" }
        return !c2paKeys.isEmpty
    }

    /// Gets C2PA-specific metadata if present
    /// - Parameter url: The file to analyze
    /// - Returns: C2PAMetadata structure, or nil if no C2PA data found
    func getC2PAMetadata(for url: URL) async throws -> C2PAMetadata? {
        guard let exiftoolPath = getExifToolPath() else {
            throw ExifToolServiceError.notInstalled
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExifToolServiceError.fileNotFound
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        // Get all C2PA tags
        process.arguments = ["-json", "-G", "-XMP-c2pa:all", url.path]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ExifToolServiceError.executionFailed(error.localizedDescription)
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let metadata = jsonArray.first else {
            return nil
        }

        // Check if there are any C2PA tags (besides SourceFile)
        let c2paKeys = metadata.keys.filter { $0 != "SourceFile" }
        guard !c2paKeys.isEmpty else {
            return nil
        }

        // Extract C2PA-specific fields
        let claimGenerator = metadata["XMP-c2pa:ClaimGenerator"] as? String
            ?? metadata["ClaimGenerator"] as? String
        let manifestStore = metadata["XMP-c2pa:ManifestStore"] as? String
            ?? metadata["ManifestStore"] as? String

        // Try to get assertions if present
        var assertions: [String]? = nil
        if let assertionsValue = metadata["XMP-c2pa:Assertions"] ?? metadata["Assertions"] {
            if let assertionsArray = assertionsValue as? [String] {
                assertions = assertionsArray
            } else if let assertionsString = assertionsValue as? String {
                assertions = [assertionsString]
            }
        }

        return C2PAMetadata(
            hasContentCredentials: true,
            claimGenerator: claimGenerator,
            manifestStore: manifestStore,
            assertions: assertions
        )
    }

    /// Checks C2PA status only if enabled in settings
    /// - Parameter url: The file to check
    /// - Returns: C2PAMetadata if enabled and found, nil otherwise
    func checkC2PAIfEnabled(for url: URL) async -> C2PAMetadata? {
        // Check if C2PA checking is enabled in settings
        guard UserDefaults.standard.bool(forKey: AppConstants.c2paCheckEnabledKey) else {
            return nil
        }

        // Check if ExifTool is available
        guard isAvailable else {
            return nil
        }

        do {
            return try await getC2PAMetadata(for: url)
        } catch {
            logger.warning("Failed to check C2PA metadata: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Error Types

enum ExifToolServiceError: Error, LocalizedError {
    case notInstalled
    case fileNotFound
    case executionFailed(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ExifTool is not installed"
        case .fileNotFound:
            return "File not found"
        case .executionFailed(let message):
            return "ExifTool execution failed: \(message)"
        case .parseError(let message):
            return "Failed to parse ExifTool output: \(message)"
        }
    }
}
