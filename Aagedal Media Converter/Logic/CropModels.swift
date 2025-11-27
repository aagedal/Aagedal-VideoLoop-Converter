// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Represents crop configuration for a video item
/// Stores crop rectangle in normalized coordinates (0.0 to 1.0) for resolution independence
struct CropConfig: Equatable, Sendable, Codable {
    /// Crop rectangle in normalized coordinates (0.0 to 1.0)
    /// Normalized coordinates are resolution-independent and survive preset changes
    var normalizedRect: CropRect

    /// Optional aspect ratio lock (nil = free-form)
    var aspectRatioLock: AspectRatio? = nil

    init(normalizedRect: CropRect, aspectRatioLock: AspectRatio? = nil) {
        self.normalizedRect = normalizedRect
        self.aspectRatioLock = aspectRatioLock
    }

    /// Returns true if crop differs from full frame (no crop)
    var isActive: Bool {
        !normalizedRect.isFullFrame
    }

    /// Converts normalized rect to pixel coordinates for given dimensions
    func pixelRect(sourceWidth: Int, sourceHeight: Int) -> PixelCropRect {
        normalizedRect.toPixelRect(width: sourceWidth, height: sourceHeight)
    }

    /// Creates config from pixel coordinates (for UI input)
    static func fromPixelRect(
        _ pixelRect: PixelCropRect,
        sourceWidth: Int,
        sourceHeight: Int,
        aspectRatioLock: AspectRatio? = nil
    ) -> CropConfig {
        let normalized = CropRect.fromPixelRect(
            pixelRect,
            width: sourceWidth,
            height: sourceHeight
        )
        return CropConfig(normalizedRect: normalized, aspectRatioLock: aspectRatioLock)
    }
}

/// Normalized crop rectangle (0.0 to 1.0 coordinates)
/// These coordinates are resolution-independent and can be applied to any source resolution
struct CropRect: Equatable, Sendable, Codable {
    var x: Double      // 0.0 = left edge, 1.0 = right edge
    var y: Double      // 0.0 = top edge, 1.0 = bottom edge
    var width: Double  // 0.0 to 1.0 of frame width
    var height: Double // 0.0 to 1.0 of frame height

    /// Full frame crop (no crop applied)
    static let fullFrame = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Returns true if this represents a full frame (no crop)
    var isFullFrame: Bool {
        abs(x) < 0.001 && abs(y) < 0.001 &&
        abs(width - 1.0) < 0.001 && abs(height - 1.0) < 0.001
    }

    /// Converts normalized coordinates to pixel coordinates for a given resolution
    func toPixelRect(width: Int, height: Int) -> PixelCropRect {
        PixelCropRect(
            x: Int((x * Double(width)).rounded()),
            y: Int((y * Double(height)).rounded()),
            width: Int((self.width * Double(width)).rounded()),
            height: Int((self.height * Double(height)).rounded())
        )
    }

    /// Creates normalized coordinates from pixel coordinates
    static func fromPixelRect(_ pixel: PixelCropRect, width: Int, height: Int) -> CropRect {
        guard width > 0, height > 0 else { return .fullFrame }
        return CropRect(
            x: Double(pixel.x) / Double(width),
            y: Double(pixel.y) / Double(height),
            width: Double(pixel.width) / Double(width),
            height: Double(pixel.height) / Double(height)
        )
    }
}

/// Pixel-based crop rectangle for UI display and FFMPEG command construction
struct PixelCropRect: Equatable, Sendable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    /// Ensures dimensions are even (required by most video codecs)
    /// Many video codecs require even dimensions for chroma subsampling
    func evenDimensions() -> PixelCropRect {
        PixelCropRect(
            x: x,
            y: y,
            width: (width / 2) * 2,  // Round down to nearest even number
            height: (height / 2) * 2
        )
    }

    /// Clamps crop rectangle to source dimensions
    /// Ensures crop doesn't exceed source bounds and maintains minimum size
    func clamped(maxWidth: Int, maxHeight: Int) -> PixelCropRect {
        // Ensure position is within bounds
        let clampedX = max(0, min(x, maxWidth - 2))
        let clampedY = max(0, min(y, maxHeight - 2))

        // Ensure size is within bounds and minimum 2x2
        let clampedWidth = max(2, min(width, maxWidth - clampedX))
        let clampedHeight = max(2, min(height, maxHeight - clampedY))

        return PixelCropRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
}

/// Common aspect ratios for crop constraints
enum AspectRatio: String, CaseIterable, Identifiable, Sendable, Codable {
    case free = "Free"
    case ratio16_9 = "16:9"
    case ratio4_3 = "4:3"
    case ratio1_1 = "1:1 (Square)"
    case ratio21_9 = "21:9"
    case ratio9_16 = "9:16 (Vertical)"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Numeric ratio (width / height), nil for free-form
    var numericRatio: Double? {
        switch self {
        case .free: return nil
        case .ratio16_9: return 16.0 / 9.0
        case .ratio4_3: return 4.0 / 3.0
        case .ratio1_1: return 1.0
        case .ratio21_9: return 21.0 / 9.0
        case .ratio9_16: return 9.0 / 16.0
        }
    }
}
