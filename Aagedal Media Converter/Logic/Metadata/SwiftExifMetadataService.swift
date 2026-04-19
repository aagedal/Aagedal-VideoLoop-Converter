// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import SwiftExif

/// In-process replacement for `ExifToolService` backed by the SwiftExif package.
/// Returns the same `C2PAMetadata` / `CameraMetadata` structs so existing callers
/// (and the UI) need no changes.
actor SwiftExifMetadataService {
    static let shared = SwiftExifMetadataService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "SwiftExifMetadataService")

    private init() {}

    /// Always true — SwiftExif is bundled with the app, there is no external binary to detect.
    nonisolated var isAvailable: Bool { true }

    /// File extensions whose container layout SwiftExif can parse. Anything else
    /// (mkv, webm, avi, mp3, m4a, …) is resolved as "no metadata" without a read attempt.
    private static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "mxf"]

    private static func isParsableContainer(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - C2PA

    func getC2PAMetadata(for url: URL) async throws -> C2PAMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftExifMetadataError.fileNotFound
        }
        guard Self.isParsableContainer(url) else { return nil }

        let videoMetadata: SwiftExif.VideoMetadata
        do {
            videoMetadata = try await readVideoMetadata(from: url)
        } catch {
            // The file's extension said it should be parsable but SwiftExif couldn't
            // read it — log once at debug level and treat as "no metadata", matching
            // ExifTool's old behavior on malformed/partial files.
            logger.debug("SwiftExif read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        return Self.makeC2PAMetadata(from: videoMetadata)
    }

    // MARK: - Camera

    func getCameraMetadata(for url: URL) async throws -> CameraMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SwiftExifMetadataError.fileNotFound
        }
        guard Self.isParsableContainer(url) else { return nil }

        let cam: SwiftExif.CameraMetadata?
        do {
            cam = try await SwiftExif.readVideoCameraMetadata(from: url)
        } catch {
            logger.debug("SwiftExif camera read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let cam else { return nil }
        let mapped = Self.makeCameraMetadata(from: cam)
        return mapped.hasAnyData ? mapped : nil
    }

    // MARK: - Convenience variants matching ExifToolService's API

    func checkC2PAIfEnabled(for url: URL) async -> C2PAMetadata? {
        do { return try await getC2PAMetadata(for: url) } catch {
            logger.warning("C2PA check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func checkCameraMetadataIfEnabled(for url: URL) async -> CameraMetadata? {
        do { return try await getCameraMetadata(for: url) } catch {
            logger.warning("Camera metadata check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Mapping

    static func makeC2PAMetadata(from video: SwiftExif.VideoMetadata) -> C2PAMetadata? {
        let manifest = video.c2pa?.activeManifest
        let hasManifest = manifest != nil

        let xmlName = joinedNonEmpty(video.camera?.userMetaNames)
        let xmlContent = joinedNonEmpty(video.camera?.userMetaContents)
        let xmlCreationDate = video.camera?.creationDate.map { $0.formatted(.iso8601) }

        // If neither a C2PA manifest nor the XML-derived fields are present, return nil
        // to match the original ExifTool behavior (absent = don't surface).
        guard hasManifest || xmlName != nil || xmlContent != nil || xmlCreationDate != nil else {
            return nil
        }

        let claimGenerator = manifest?.claim.claimGenerator
        let claimGeneratorInfoName = manifest?.claim.claimGeneratorInfo?.name

        let firstActionAssertion = manifest?.assertions.first { assertion in
            assertion.label.hasPrefix("c2pa.actions")
        }
        let firstAction: C2PAAction? = {
            guard let content = firstActionAssertion?.content,
                  case .actions(let actions) = content else { return nil }
            return actions.actions.first
        }()

        let assertionLabels = manifest?.assertions.map { $0.label }
        let hasSignature = (manifest?.signature.signatureBytes.isEmpty == false)

        return C2PAMetadata(
            hasContentCredentials: hasManifest,
            hasSignature: hasSignature,
            actionsAction: firstAction?.action,
            actionsDigitalSourceType: firstAction?.digitalSourceType,
            claimGenerator: claimGenerator,
            claimGeneratorInfoName: claimGeneratorInfoName,
            manifestStore: manifest?.label,
            assertions: assertionLabels?.isEmpty == true ? nil : assertionLabels,
            userDescriptiveMetadataName: xmlName,
            userDescriptiveMetadataContent: xmlContent,
            creationDateValue: xmlCreationDate
        )
    }

    static func makeCameraMetadata(from cam: SwiftExif.CameraMetadata) -> CameraMetadata {
        CameraMetadata(
            deviceManufacturer: cam.deviceManufacturer,
            deviceModelName: cam.deviceModelName,
            deviceSerialNumber: cam.deviceSerialNumber,
            lensModelName: cam.lensModelName,
            timeZone: cam.timeZone,
            captureGammaEquation: cam.captureGammaEquation,
            recordingModeType: cam.recordingModeType,
            captureFps: cam.captureFps.map { fps in
                fps.truncatingRemainder(dividingBy: 1) == 0
                    ? String(format: "%.0f", fps)
                    : String(format: "%.3f", fps)
            }
        )
    }

    private static func joinedNonEmpty(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        let joined = values.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    private func readVideoMetadata(from url: URL) async throws -> SwiftExif.VideoMetadata {
        try await SwiftExif.readVideoMetadata(from: url)
    }
}

enum SwiftExifMetadataError: Error, LocalizedError {
    case fileNotFound
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "File not found"
        case .readFailed(let msg): return "SwiftExif read failed: \(msg)"
        }
    }
}
