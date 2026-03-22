// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders capsule-style frequency band visualizer frames as raw BGRA pixel data
// for piping to FFmpeg during native waveform video generation.

import Foundation
import CoreGraphics
import OSLog

enum NativeWaveformVideoRenderer {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "NativeWaveformRenderer")

    /// Fraction of capsule width used as horizontal gap between capsules.
    private static let gapFraction: CGFloat = 0.4
    /// Minimum capsule height in points (visible even during silence).
    private static let minCapsuleHeight: CGFloat = 4
    /// Vertical margin (fraction of frame height) above/below tallest capsule.
    private static let verticalMarginFraction: CGFloat = 0.08

    // MARK: - Public API

    /// Renders a single video frame with capsule visualizer as raw BGRA pixel data.
    ///
    /// - Parameters:
    ///   - bandMagnitudes: Per-band magnitude values in 0.0–1.0 (already smoothed).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - foregroundColor: RGB tuple for capsule fill color.
    ///   - backgroundColor: RGB tuple for frame background color.
    /// - Returns: Raw BGRA pixel data (width × height × 4 bytes).
    static func renderFrame(
        bandMagnitudes: [Float],
        width: Int,
        height: Int,
        foregroundColor: (r: UInt8, g: UInt8, b: UInt8),
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8)
    ) -> Data {
        let bandCount = bandMagnitudes.count
        guard bandCount > 0, width > 0, height > 0 else {
            return Data(count: width * height * 4)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)  // BGRA layout

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            logger.error("Failed to create CGContext for frame rendering")
            return Data(count: width * height * 4)
        }

        // Fill background
        let bgR = CGFloat(backgroundColor.r) / 255.0
        let bgG = CGFloat(backgroundColor.g) / 255.0
        let bgB = CGFloat(backgroundColor.b) / 255.0
        ctx.setFillColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Capsule layout
        let fgR = CGFloat(foregroundColor.r) / 255.0
        let fgG = CGFloat(foregroundColor.g) / 255.0
        let fgB = CGFloat(foregroundColor.b) / 255.0
        ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)

        let frameWidth = CGFloat(width)
        let frameHeight = CGFloat(height)
        let verticalMargin = frameHeight * verticalMarginFraction
        let maxCapsuleHeight = frameHeight - 2 * verticalMargin
        let centerY = frameHeight / 2.0

        // Calculate capsule dimensions
        // Total width = bandCount * capsuleWidth + (bandCount - 1) * gap
        // gap = capsuleWidth * gapFraction
        // totalWidth = bandCount * capsuleWidth * (1 + gapFraction) - capsuleWidth * gapFraction
        let horizontalPadding = frameWidth * 0.04  // Small padding on edges
        let availableWidth = frameWidth - 2 * horizontalPadding
        let capsuleStride = availableWidth / CGFloat(bandCount)
        let capsuleWidth = capsuleStride / (1.0 + gapFraction)
        let cornerRadius = capsuleWidth / 2.0  // Pill shape

        for band in 0..<bandCount {
            let magnitude = CGFloat(max(0, min(1, bandMagnitudes[band])))
            let capsuleHeight = max(minCapsuleHeight, magnitude * maxCapsuleHeight)

            let x = horizontalPadding + CGFloat(band) * capsuleStride + (capsuleStride - capsuleWidth) / 2.0
            let y = centerY - capsuleHeight / 2.0

            let rect = CGRect(x: x, y: y, width: capsuleWidth, height: capsuleHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Extract raw pixel data
        guard let data = ctx.data else {
            return Data(count: width * height * 4)
        }

        return Data(bytes: data, count: bytesPerRow * height)
    }
}
