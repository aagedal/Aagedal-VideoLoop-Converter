// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// C2PA (Content Authenticity) metadata extracted from a video container.
struct C2PAMetadata: Codable, Sendable, Equatable {
    let hasContentCredentials: Bool
    let hasSignature: Bool
    let actionsAction: String?
    let actionsDigitalSourceType: String?
    let claimGenerator: String?
    let claimGeneratorInfoName: String?
    let manifestStore: String?
    let assertions: [String]?

    static let empty = C2PAMetadata(
        hasContentCredentials: false,
        hasSignature: false,
        actionsAction: nil,
        actionsDigitalSourceType: nil,
        claimGenerator: nil,
        claimGeneratorInfoName: nil,
        manifestStore: nil,
        assertions: nil
    )
}

/// Camera/clip metadata from Sony NonRealTimeMeta XML (embedded or sidecar).
struct CameraMetadata: Codable, Sendable, Equatable {
    let deviceManufacturer: String?
    let deviceModelName: String?
    let deviceSerialNumber: String?
    let lensModelName: String?
    let timeZone: String?
    let captureGammaEquation: String?
    let recordingModeType: String?
    let captureFps: String?
    /// Paired `<Meta name="..." content="..."/>` entries from Sony NRT
    /// `<UserDescriptiveMetadata>` (e.g. user-supplied Creator / Description / Location).
    let userDescriptiveMetadata: [UserMetadataEntry]?

    static let empty = CameraMetadata(
        deviceManufacturer: nil,
        deviceModelName: nil,
        deviceSerialNumber: nil,
        lensModelName: nil,
        timeZone: nil,
        captureGammaEquation: nil,
        recordingModeType: nil,
        captureFps: nil,
        userDescriptiveMetadata: nil
    )

    /// Whether any camera metadata fields have values
    var hasAnyData: Bool {
        deviceManufacturer != nil ||
        deviceModelName != nil ||
        deviceSerialNumber != nil ||
        lensModelName != nil ||
        timeZone != nil ||
        captureGammaEquation != nil ||
        recordingModeType != nil ||
        captureFps != nil ||
        (userDescriptiveMetadata?.isEmpty == false)
    }
}

/// A single `<Meta name="..." content="..."/>` entry from Sony NRT
/// `<UserDescriptiveMetadata>`.
struct UserMetadataEntry: Codable, Sendable, Equatable {
    let name: String
    let content: String
}
