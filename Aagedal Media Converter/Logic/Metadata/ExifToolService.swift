// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// C2PA (Content Authenticity) metadata structure
struct C2PAMetadata: Codable, Sendable, Equatable {
    let hasContentCredentials: Bool
    let hasSignature: Bool
    let actionsAction: String?
    let actionsDigitalSourceType: String?
    let claimGenerator: String?
    let claimGeneratorInfoName: String?
    let manifestStore: String?
    let assertions: [String]?
    let userDescriptiveMetadataName: String?
    let userDescriptiveMetadataContent: String?
    let deviceManufacturer: String?
    let deviceModelName: String?
    let deviceSerialNumber: String?
    let lensModelName: String?
    let creationDateValue: String?

    static let empty = C2PAMetadata(
        hasContentCredentials: false,
        hasSignature: false,
        actionsAction: nil,
        actionsDigitalSourceType: nil,
        claimGenerator: nil,
        claimGeneratorInfoName: nil,
        manifestStore: nil,
        assertions: nil,
        userDescriptiveMetadataName: nil,
        userDescriptiveMetadataContent: nil,
        deviceManufacturer: nil,
        deviceModelName: nil,
        deviceSerialNumber: nil,
        lensModelName: nil,
        creationDateValue: nil
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
        // Check for C2PA metadata stored in XMP and JUMBF blocks
        process.arguments = [
            "-json", "-G", "-s",
            "-XMP-c2pa:all",
            "-JUMBF:all",
            "-XML:UserDescriptiveMetadataMetaName",
            "-XML:UserDescriptiveMetadataMetaContent",
            "-XML:DeviceManufacturer",
            "-XML:DeviceModelName",
            "-XML:DeviceSerialNo",
            "-XML:LensModelName",
            "-XML:CreationDateValue",
            url.path
        ]
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

        let c2paKeys = metadata.keys.filter { key in
            let normalizedKey = normalizeKey(key)
            return normalizedKey.contains("jumbf") || normalizedKey.contains("c2pa")
        }
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
        // Get all C2PA tags (XMP and JUMBF) and related XML metadata
        process.arguments = [
            "-json", "-G", "-s",
            "-XMP-c2pa:all",
            "-JUMBF:all",
            "-XML:UserDescriptiveMetadataMetaName",
            "-XML:UserDescriptiveMetadataMetaContent",
            "-XML:DeviceManufacturer",
            "-XML:DeviceModelName",
            "-XML:DeviceSerialNo",
            "-XML:LensModelName",
            "-XML:CreationDateValue",
            url.path
        ]
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

        let c2paKeys = metadata.keys.filter { key in
            let normalizedKey = normalizeKey(key)
            return normalizedKey.contains("jumbf") || normalizedKey.contains("c2pa")
        }
        guard !c2paKeys.isEmpty else {
            return nil
        }

        // Extract C2PA-specific fields
        let signatureValue = stringValue(in: metadata, matchingKeys: ["Signature"])
        let claimGenerator = stringValue(in: metadata, matchingKeys: ["ClaimGenerator", "Claim Generator"])
        let claimGeneratorInfoName = stringValue(in: metadata, matchingKeys: ["ClaimGeneratorInfoName", "Claim Generator Info Name"])
        let actionsAction = stringValue(in: metadata, matchingKeys: ["ActionsAction", "Actions Action"])
        let actionsDigitalSourceType = stringValue(in: metadata, matchingKeys: ["ActionsDigitalSourceType", "Actions Digital Source Type"])
        let manifestStore = stringValue(in: metadata, matchingKeys: ["ManifestStore", "Manifest Store"])
        let userDescriptiveMetadataName = stringValue(in: metadata, matchingKeys: ["UserDescriptiveMetadataMetaName", "User Descriptive Metadata Meta Name"])
        let userDescriptiveMetadataContent = stringValue(in: metadata, matchingKeys: ["UserDescriptiveMetadataMetaContent", "User Descriptive Metadata Meta Content"])
        let deviceManufacturer = stringValue(in: metadata, matchingKeys: ["DeviceManufacturer", "Device Manufacturer"])
        let deviceModelName = stringValue(in: metadata, matchingKeys: ["DeviceModelName", "Device Model Name"])
        let deviceSerialNumber = stringValue(in: metadata, matchingKeys: ["DeviceSerialNo", "Device Serial No"])
        let lensModelName = stringValue(in: metadata, matchingKeys: ["LensModelName", "Lens Model Name"])
        let creationDateValue = stringValue(in: metadata, matchingKeys: ["CreationDateValue", "Creation Date Value"])

        // Try to get assertions if present
        let assertions = stringArrayValue(in: metadata, matchingKeys: ["Assertions"])

        return C2PAMetadata(
            hasContentCredentials: true,
            hasSignature: signatureValue?.isEmpty == false,
            actionsAction: actionsAction,
            actionsDigitalSourceType: actionsDigitalSourceType,
            claimGenerator: claimGenerator,
            claimGeneratorInfoName: claimGeneratorInfoName,
            manifestStore: manifestStore,
            assertions: assertions,
            userDescriptiveMetadataName: userDescriptiveMetadataName,
            userDescriptiveMetadataContent: userDescriptiveMetadataContent,
            deviceManufacturer: deviceManufacturer,
            deviceModelName: deviceModelName,
            deviceSerialNumber: deviceSerialNumber,
            lensModelName: lensModelName,
            creationDateValue: creationDateValue
        )
    }

    /// Checks C2PA status when ExifTool is available
    /// - Parameter url: The file to check
    /// - Returns: C2PAMetadata if found, nil otherwise
    func checkC2PAIfEnabled(for url: URL) async -> C2PAMetadata? {
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

    private func stringValue(in metadata: [String: Any], matchingKeys: [String]) -> String? {
        for key in matchingKeys {
            if let value = metadata[key], let stringValue = stringValue(from: value) {
                return stringValue
            }
        }

        let normalizedTargets = matchingKeys.map { normalizeKey($0) }
        for (key, value) in metadata {
            let normalizedKey = normalizeKey(key)
            for target in normalizedTargets where normalizedKey.hasSuffix(target) {
                return stringValue(from: value)
            }
        }

        return nil
    }

    private func stringArrayValue(in metadata: [String: Any], matchingKeys: [String]) -> [String]? {
        for key in matchingKeys {
            if let value = metadata[key], let arrayValue = stringArray(from: value) {
                return arrayValue
            }
        }

        let normalizedTargets = matchingKeys.map { normalizeKey($0) }
        for (key, value) in metadata {
            let normalizedKey = normalizeKey(key)
            for target in normalizedTargets where normalizedKey.hasSuffix(target) {
                return stringArray(from: value)
            }
        }

        return nil
    }

    private func stringValue(from value: Any) -> String? {
        if let stringValue = value as? String {
            return stringValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.stringValue
        }
        if let arrayValue = value as? [String] {
            return arrayValue.joined(separator: ", ")
        }
        if let arrayValue = value as? [Any] {
            let stringValues = arrayValue.compactMap { stringValue(from: $0) }
            return stringValues.isEmpty ? nil : stringValues.joined(separator: ", ")
        }
        return nil
    }

    private func stringArray(from value: Any) -> [String]? {
        if let arrayValue = value as? [String] {
            return arrayValue
        }
        if let stringValue = value as? String {
            return [stringValue]
        }
        if let numberValue = value as? NSNumber {
            return [numberValue.stringValue]
        }
        if let arrayValue = value as? [Any] {
            let stringValues = arrayValue.compactMap { stringValue(from: $0) }
            return stringValues.isEmpty ? nil : stringValues
        }
        return nil
    }

    private func normalizeKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
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
