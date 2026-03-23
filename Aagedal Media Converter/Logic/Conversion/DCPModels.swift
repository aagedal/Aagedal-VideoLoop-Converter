// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - DCP Resolution

/// DCI resolution options for DCP export
enum DCPResolution: String, CaseIterable, Identifiable, Sendable {
    case twoKFlat = "2K Flat (1998x1080)"
    case twoKScope = "2K Scope (2048x858)"
    case twoKFull = "2K Full (2048x1080)"
    case fourKFlat = "4K Flat (3996x2160)"
    case fourKScope = "4K Scope (4096x1716)"
    case fourKFull = "4K Full (4096x2160)"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .twoKFlat: return 1998
        case .twoKScope: return 2048
        case .twoKFull: return 2048
        case .fourKFlat: return 3996
        case .fourKScope: return 4096
        case .fourKFull: return 4096
        }
    }

    var height: Int {
        switch self {
        case .twoKFlat: return 1080
        case .twoKScope: return 858
        case .twoKFull: return 1080
        case .fourKFlat: return 2160
        case .fourKScope: return 1716
        case .fourKFull: return 2160
        }
    }

    /// Maximum DCI bitrate in Mbps for this resolution tier
    var maxBitrateMbps: Int {
        switch self {
        case .twoKFlat, .twoKScope, .twoKFull: return 250
        case .fourKFlat, .fourKScope, .fourKFull: return 500
        }
    }

    /// Short label for display in compact contexts
    var shortLabel: String {
        switch self {
        case .twoKFlat: return "2K Flat"
        case .twoKScope: return "2K Scope"
        case .twoKFull: return "2K Full"
        case .fourKFlat: return "4K Flat"
        case .fourKScope: return "4K Scope"
        case .fourKFull: return "4K Full"
        }
    }
}

// MARK: - DCP Frame Rate

/// DCI-compliant frame rates for DCP export
enum DCPFrameRate: String, CaseIterable, Identifiable, Sendable {
    case fps24 = "24 fps"
    case fps25 = "25 fps"
    case fps30 = "30 fps"
    case fps48 = "48 fps"

    var id: String { rawValue }

    var ffmpegValue: String {
        switch self {
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps30: return "30"
        case .fps48: return "48"
        }
    }

    /// Edit rate numerator for DCP XML (CPL)
    var editRateNumerator: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps30: return 30
        case .fps48: return 48
        }
    }

    /// Edit rate denominator for DCP XML (CPL)
    var editRateDenominator: Int { 1 }
}

// MARK: - DCP Bitrate

/// Video bitrate options for DCP JPEG 2000 encoding
enum DCPBitrate: String, CaseIterable, Identifiable, Sendable {
    case low = "100 Mbps"
    case medium = "150 Mbps"
    case high = "200 Mbps"
    case max = "250 Mbps"

    var id: String { rawValue }

    var ffmpegValue: String {
        switch self {
        case .low: return "100M"
        case .medium: return "150M"
        case .high: return "200M"
        case .max: return "250M"
        }
    }
}
