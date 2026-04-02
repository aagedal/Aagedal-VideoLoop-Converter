// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders frequency band visualizer frames as raw BGRA pixel data
// for piping to FFmpeg during native waveform video generation.
// Supports multiple visual styles: capsules, bars, wire.
// Supports gradient fills for foreground/background, background images, and opacity.

import Foundation
import CoreGraphics
import ImageIO
import OSLog

enum NativeWaveformVideoRenderer {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "NativeWaveformRenderer")

    /// Fraction of band width used as horizontal gap between elements.
    private static let gapFraction: CGFloat = 0.4
    /// Vertical margin (fraction of frame height) above/below tallest element.
    private static let verticalMarginFraction: CGFloat = 0.08
    /// Horizontal padding on edges (fraction of frame width).
    private static let horizontalPaddingFraction: CGFloat = 0.04

    // MARK: - Public API

    /// Renders a single video frame as raw BGRA pixel data.
    static func renderFrame(
        style: SwiftWaveformStyle,
        bandMagnitudes: [Float],
        previousMagnitudes: [Float]?,
        width: Int,
        height: Int,
        foregroundColor: (r: UInt8, g: UInt8, b: UInt8),
        backgroundColor: (r: UInt8, g: UInt8, b: UInt8),
        foregroundGradientEnd: (r: UInt8, g: UInt8, b: UInt8)? = nil,
        backgroundGradientEnd: (r: UInt8, g: UInt8, b: UInt8)? = nil,
        backgroundImage: CGImage? = nil,
        waveformOpacity: Double = 1.0
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

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // --- Background rendering (priority: image > gradient > solid) ---
        if let bgImage = backgroundImage {
            ctx.draw(bgImage, in: fullRect)
        } else if let bgEnd = backgroundGradientEnd {
            let bgR = CGFloat(backgroundColor.r) / 255.0
            let bgG = CGFloat(backgroundColor.g) / 255.0
            let bgB = CGFloat(backgroundColor.b) / 255.0
            let endR = CGFloat(bgEnd.r) / 255.0
            let endG = CGFloat(bgEnd.g) / 255.0
            let endB = CGFloat(bgEnd.b) / 255.0
            let colors = [
                CGColor(colorSpace: colorSpace, components: [bgR, bgG, bgB, 1.0])!,
                CGColor(colorSpace: colorSpace, components: [endR, endG, endB, 1.0])!
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                // CGContext origin is bottom-left; visually top = y=height, bottom = y=0
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: 0, y: CGFloat(height)),
                    end: CGPoint(x: 0, y: 0),
                    options: [])
            }
        } else {
            let bgR = CGFloat(backgroundColor.r) / 255.0
            let bgG = CGFloat(backgroundColor.g) / 255.0
            let bgB = CGFloat(backgroundColor.b) / 255.0
            ctx.setFillColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)
            ctx.fill(fullRect)
        }

        // --- Foreground waveform rendering ---
        let fgR = CGFloat(foregroundColor.r) / 255.0
        let fgG = CGFloat(foregroundColor.g) / 255.0
        let fgB = CGFloat(foregroundColor.b) / 255.0

        // Prepare gradient end colors for foreground (nil if no gradient)
        let fgEndR: CGFloat? = foregroundGradientEnd.map { CGFloat($0.r) / 255.0 }
        let fgEndG: CGFloat? = foregroundGradientEnd.map { CGFloat($0.g) / 255.0 }
        let fgEndB: CGFloat? = foregroundGradientEnd.map { CGFloat($0.b) / 255.0 }

        // Apply waveform opacity
        let effectiveOpacity = CGFloat(min(1.0, max(0.5, waveformOpacity)))
        if effectiveOpacity < 1.0 {
            ctx.setAlpha(effectiveOpacity)
        }

        let layout = FrameLayout(width: width, height: height, bandCount: bandCount)

        switch style {
        case .capsules:
            renderCapsules(ctx: ctx, colorSpace: colorSpace, layout: layout,
                           bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                           fgR: fgR, fgG: fgG, fgB: fgB,
                           fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        case .bars:
            renderBars(ctx: ctx, colorSpace: colorSpace, layout: layout,
                       bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                       fgR: fgR, fgG: fgG, fgB: fgB,
                       fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        case .wire:
            renderWire(ctx: ctx, colorSpace: colorSpace, layout: layout,
                       bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                       fgR: fgR, fgG: fgG, fgB: fgB,
                       fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        }

        // Restore alpha
        if effectiveOpacity < 1.0 {
            ctx.setAlpha(1.0)
        }

        guard let data = ctx.data else {
            return Data(count: width * height * 4)
        }
        return Data(bytes: data, count: bytesPerRow * height)
    }

    // MARK: - Background Image Loading

    /// Loads an image from URL and pre-scales it to the target resolution.
    /// Call once before the render loop to avoid per-frame I/O.
    /// Handles security-scoped resource access for sandboxed apps.
    static func loadBackgroundImage(from url: URL, width: Int, height: Int) -> CGImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            logger.error("Failed to load background image from \(url.path)")
            return nil
        }

        // Pre-scale to target resolution
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return cgImage  // Return unscaled as fallback
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Shared Layout

    private struct FrameLayout {
        let frameWidth: CGFloat
        let frameHeight: CGFloat
        let centerY: CGFloat
        let maxBarHeight: CGFloat
        let horizontalPadding: CGFloat
        let availableWidth: CGFloat
        let bandStride: CGFloat
        let bandWidth: CGFloat
        let bandCount: Int

        init(width: Int, height: Int, bandCount: Int) {
            self.frameWidth = CGFloat(width)
            self.frameHeight = CGFloat(height)
            self.centerY = frameHeight / 2.0
            let vMargin = frameHeight * verticalMarginFraction
            self.maxBarHeight = frameHeight - 2 * vMargin
            self.horizontalPadding = frameWidth * horizontalPaddingFraction
            self.availableWidth = frameWidth - 2 * horizontalPadding
            self.bandStride = availableWidth / CGFloat(bandCount)
            self.bandWidth = bandStride / (1.0 + gapFraction)
            self.bandCount = bandCount
        }

        /// X position of the center of band at given index.
        func bandCenterX(_ band: Int) -> CGFloat {
            horizontalPadding + CGFloat(band) * bandStride + bandStride / 2.0
        }

        /// X position of the left edge of band at given index.
        func bandLeftX(_ band: Int) -> CGFloat {
            horizontalPadding + CGFloat(band) * bandStride + (bandStride - bandWidth) / 2.0
        }
    }

    // MARK: - Gradient Helper

    /// Draws a vertical gradient clipped to the current clipping path.
    private static func drawVerticalGradient(
        ctx: CGContext, colorSpace: CGColorSpace,
        startR: CGFloat, startG: CGFloat, startB: CGFloat,
        endR: CGFloat, endG: CGFloat, endB: CGFloat,
        fromY: CGFloat, toY: CGFloat, width: CGFloat
    ) {
        let colors = [
            CGColor(colorSpace: colorSpace, components: [startR, startG, startB, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [endR, endG, endB, 1.0])!
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: 0, y: fromY),
            end: CGPoint(x: 0, y: toY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: - Capsules Style

    private static func renderCapsules(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let cornerRadius = layout.bandWidth / 2.0
        let minHeight = layout.bandWidth  // Never shorter than a circle
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur pass (always solid color at low alpha)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.25)
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(prevMags[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }

        // Main pass
        if hasGradient {
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                // Gradient from center (start color) to edges (end color)
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: y,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }

    // MARK: - Bars Style (mirrored equalizer)

    private static func renderBars(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let minHalfHeight: CGFloat = 2  // Minimum pixel height per half
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur pass (solid color at low alpha)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.20)
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(prevMags[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                ctx.fill(CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH))
                ctx.fill(CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH))
            }
        }

        // Main pass
        if hasGradient {
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                let topRect = CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH)
                let bottomRect = CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH)

                // Top half: gradient from center (start) to top (end)
                ctx.saveGState()
                ctx.clip(to: [topRect])
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY - halfH,
                                     width: layout.frameWidth)
                ctx.restoreGState()

                // Bottom half: gradient from center (start) to bottom (end)
                ctx.saveGState()
                ctx.clip(to: [bottomRect])
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY + halfH,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                ctx.fill(CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH))
                ctx.fill(CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH))
            }
        }
    }

    // MARK: - Wire Style (smooth curve with filled area)

    private static func renderWire(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let vMargin = layout.frameHeight * verticalMarginFraction
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur: previous curve at low opacity (solid color)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.15)
            drawWireCurve(ctx: ctx, layout: layout, magnitudes: prevMags, vMargin: vMargin, mirrored: true)
        }

        // Main curve — filled area between curve and center, mirrored
        if hasGradient {
            // Top half with gradient
            let topPath = buildWireFillPath(layout: layout, magnitudes: bandMagnitudes, above: true)
            if let topPath {
                ctx.saveGState()
                ctx.addPath(topPath)
                ctx.clip()
                let halfMax = layout.maxBarHeight / 2.0
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY + halfMax,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }

            // Bottom half with gradient (mirrored)
            let bottomPath = buildWireFillPath(layout: layout, magnitudes: bandMagnitudes, above: false)
            if let bottomPath {
                ctx.saveGState()
                ctx.addPath(bottomPath)
                ctx.clip()
                let halfMax = layout.maxBarHeight / 2.0
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY - halfMax,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            drawWireCurve(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, mirrored: true)
        }

        // Stroke the outline on top for crispness (always solid)
        ctx.setStrokeColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
        ctx.setLineWidth(max(1.5, layout.bandWidth * 0.15))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        drawWireStroke(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, above: true)
        drawWireStroke(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, above: false)
    }

    /// Builds the array of (x, magnitude) points for the wire curve,
    /// including virtual zero-magnitude anchors at the frame edges so
    /// the curve extends edge-to-edge and tapers to flat.
    private static func wirePoints(layout: FrameLayout, magnitudes: [Float]) -> [(x: CGFloat, mag: CGFloat)] {
        var pts = [(x: CGFloat, mag: CGFloat)]()
        // Left edge anchor at zero
        pts.append((x: 0, mag: 0))
        // Actual band data
        for band in 0..<layout.bandCount {
            pts.append((x: layout.bandCenterX(band), mag: CGFloat(clamp01(magnitudes[band]))))
        }
        // Right edge anchor at zero
        pts.append((x: layout.frameWidth, mag: 0))
        return pts
    }

    /// Builds a CGMutablePath for one half (top or bottom) of the wire fill area.
    private static func buildWireFillPath(layout: FrameLayout, magnitudes: [Float], above: Bool) -> CGMutablePath? {
        let pts = wirePoints(layout: layout, magnitudes: magnitudes)
        guard pts.count > 2 else { return nil }
        let halfMax = layout.maxBarHeight / 2.0
        let sign: CGFloat = above ? 1.0 : -1.0  // In CG coords: above center = +y, below = -y

        let path = CGMutablePath()
        path.move(to: CGPoint(x: pts[0].x, y: layout.centerY))
        for i in 0..<pts.count {
            let x = pts[i].x
            let y = layout.centerY + sign * pts[i].mag * halfMax
            if i == 0 {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                let cpX = (pts[i - 1].x + x) / 2.0
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: path.currentPoint.y))
            }
        }
        if let lastX = pts.last?.x {
            path.addLine(to: CGPoint(x: lastX, y: layout.centerY))
        }
        path.closeSubpath()
        return path
    }

    /// Draws a filled area between the curve and center line, optionally mirrored.
    private static func drawWireCurve(
        ctx: CGContext, layout: FrameLayout,
        magnitudes: [Float], vMargin: CGFloat, mirrored: Bool
    ) {
        let pts = wirePoints(layout: layout, magnitudes: magnitudes)
        guard pts.count > 2, let lastX = pts.last?.x else { return }
        let halfMax = layout.maxBarHeight / 2.0

        // Top half
        let topPath = CGMutablePath()
        topPath.move(to: CGPoint(x: pts[0].x, y: layout.centerY))
        for i in 0..<pts.count {
            let x = pts[i].x
            let y = layout.centerY - pts[i].mag * halfMax
            if i == 0 {
                topPath.addLine(to: CGPoint(x: x, y: y))
            } else {
                let cpX = (pts[i - 1].x + x) / 2.0
                topPath.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: topPath.currentPoint.y))
            }
        }
        topPath.addLine(to: CGPoint(x: lastX, y: layout.centerY))
        topPath.closeSubpath()
        ctx.addPath(topPath)
        ctx.fillPath()

        if mirrored {
            let bottomPath = CGMutablePath()
            bottomPath.move(to: CGPoint(x: pts[0].x, y: layout.centerY))
            for i in 0..<pts.count {
                let x = pts[i].x
                let y = layout.centerY + pts[i].mag * halfMax
                if i == 0 {
                    bottomPath.addLine(to: CGPoint(x: x, y: y))
                } else {
                    let cpX = (pts[i - 1].x + x) / 2.0
                    bottomPath.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: bottomPath.currentPoint.y))
                }
            }
            bottomPath.addLine(to: CGPoint(x: lastX, y: layout.centerY))
            bottomPath.closeSubpath()
            ctx.addPath(bottomPath)
            ctx.fillPath()
        }
    }

    /// Strokes just the curve outline (top or bottom half).
    private static func drawWireStroke(
        ctx: CGContext, layout: FrameLayout,
        magnitudes: [Float], vMargin: CGFloat, above: Bool
    ) {
        let pts = wirePoints(layout: layout, magnitudes: magnitudes)
        guard pts.count > 2 else { return }
        let sign: CGFloat = above ? -1.0 : 1.0
        let halfMax = layout.maxBarHeight / 2.0

        let path = CGMutablePath()
        for i in 0..<pts.count {
            let x = pts[i].x
            let y = layout.centerY + sign * pts[i].mag * halfMax
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                let cpX = (pts[i - 1].x + x) / 2.0
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: path.currentPoint.y))
            }
        }
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: - Helpers

    private static func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
