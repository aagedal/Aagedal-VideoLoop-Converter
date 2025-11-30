// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// Service for building FFMPEG crop filters from crop configurations
enum CropService {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Crop")

    /// Builds FFmpeg crop filter string from config
    /// Returns nil if no crop or invalid config
    /// - Parameters:
    ///   - config: The crop configuration
    ///   - sourceWidth: Source video width in pixels
    ///   - sourceHeight: Source video height in pixels
    /// - Returns: FFmpeg crop filter string like "crop=1280:720:320:180" or nil
    static func buildCropFilter(
        config: CropConfig,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> String? {
        guard config.isActive else {
            logger.debug("Crop config is not active (full frame), skipping")
            return nil
        }

        // Convert to pixel coordinates and ensure even dimensions
        let pixelRect = config.pixelRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            .evenDimensions()
            .clamped(maxWidth: sourceWidth, maxHeight: sourceHeight)

        // Validate crop
        let validation = validateCrop(pixelRect: pixelRect, sourceWidth: sourceWidth, sourceHeight: sourceHeight)

        switch validation {
        case .valid:
            // FFmpeg crop filter: crop=width:height:x:y
            let filter = "crop=\(pixelRect.width):\(pixelRect.height):\(pixelRect.x):\(pixelRect.y)"
            logger.info("Generated crop filter: \(filter, privacy: .public)")
            return filter
        case .invalid(let reason):
            logger.warning("Invalid crop config: \(reason, privacy: .public)")
            return nil
        }
    }

    /// Validates crop config against source dimensions
    private static func validateCrop(
        pixelRect: PixelCropRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CropValidationResult {
        // Check for invalid dimensions
        if pixelRect.width < 2 || pixelRect.height < 2 {
            return .invalid("Crop area too small (minimum 2x2)")
        }

        if pixelRect.x < 0 || pixelRect.y < 0 {
            return .invalid("Crop position cannot be negative")
        }

        if pixelRect.x + pixelRect.width > sourceWidth {
            return .invalid("Crop width exceeds source width")
        }

        if pixelRect.y + pixelRect.height > sourceHeight {
            return .invalid("Crop height exceeds source height")
        }

        return .valid
    }
}

/// Result of crop validation
enum CropValidationResult {
    case valid
    case invalid(String)
}
