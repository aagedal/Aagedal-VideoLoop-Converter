// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI Canvas-based real-time frequency band visualizer.
// Renders capsules, bars, or wire from live frequency band magnitudes.

import SwiftUI

/// Renders a real-time frequency band visualization using SwiftUI Canvas.
/// Supports capsule, bar, and wire styles matching the export renderer.
struct FrequencyVisualizerView: View {
    let bandMagnitudes: [Float]
    let style: SwiftWaveformStyle
    let foregroundColor: Color
    let backgroundColor: Color

    /// Fraction of band width used as gap between elements.
    private let gapFraction: CGFloat = 0.4
    /// Vertical margin fraction.
    private let verticalMarginFraction: CGFloat = 0.08
    /// Horizontal padding fraction.
    private let horizontalPaddingFraction: CGFloat = 0.04

    var body: some View {
        Canvas { context, size in
            let bandCount = bandMagnitudes.count
            guard bandCount > 0 else { return }

            // Background
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(backgroundColor))

            let frameWidth = size.width
            let frameHeight = size.height
            let centerY = frameHeight / 2.0
            let verticalMargin = frameHeight * verticalMarginFraction
            let maxBarHeight = frameHeight - 2 * verticalMargin
            let horizontalPadding = frameWidth * horizontalPaddingFraction
            let availableWidth = frameWidth - 2 * horizontalPadding
            let bandStride = availableWidth / CGFloat(bandCount)
            let bandWidth = bandStride / (1.0 + gapFraction)

            switch style {
            case .capsules:
                drawCapsules(context: &context, bandCount: bandCount, centerY: centerY,
                             maxBarHeight: maxBarHeight, horizontalPadding: horizontalPadding,
                             bandStride: bandStride, bandWidth: bandWidth)
            case .bars:
                drawBars(context: &context, bandCount: bandCount, centerY: centerY,
                         maxBarHeight: maxBarHeight, horizontalPadding: horizontalPadding,
                         bandStride: bandStride, bandWidth: bandWidth)
            case .wire:
                drawWire(context: &context, bandCount: bandCount, centerY: centerY,
                         maxBarHeight: maxBarHeight, horizontalPadding: horizontalPadding,
                         bandStride: bandStride, frameWidth: frameWidth, bandWidth: bandWidth)
            }
        }
    }

    // MARK: - Capsules

    private func drawCapsules(context: inout GraphicsContext, bandCount: Int, centerY: CGFloat,
                              maxBarHeight: CGFloat, horizontalPadding: CGFloat,
                              bandStride: CGFloat, bandWidth: CGFloat) {
        let cornerRadius = bandWidth / 2.0
        let minHeight = bandWidth

        for band in 0..<bandCount {
            let mag = CGFloat(clamped(bandMagnitudes[band]))
            let h = max(minHeight, mag * maxBarHeight)
            let x = horizontalPadding + CGFloat(band) * bandStride + (bandStride - bandWidth) / 2.0
            let y = centerY - h / 2.0
            let rect = RoundedRectangle(cornerRadius: cornerRadius)
            let path = Path(roundedRect: CGRect(x: x, y: y, width: bandWidth, height: h), cornerRadius: cornerRadius)
            context.fill(path, with: .color(foregroundColor))
        }
    }

    // MARK: - Bars (mirrored)

    private func drawBars(context: inout GraphicsContext, bandCount: Int, centerY: CGFloat,
                          maxBarHeight: CGFloat, horizontalPadding: CGFloat,
                          bandStride: CGFloat, bandWidth: CGFloat) {
        let minHalfH: CGFloat = 2

        for band in 0..<bandCount {
            let mag = CGFloat(clamped(bandMagnitudes[band]))
            let halfH = max(minHalfH, mag * maxBarHeight / 2.0)
            let x = horizontalPadding + CGFloat(band) * bandStride + (bandStride - bandWidth) / 2.0

            // Top half
            context.fill(Path(CGRect(x: x, y: centerY - halfH, width: bandWidth, height: halfH)), with: .color(foregroundColor))
            // Bottom half
            context.fill(Path(CGRect(x: x, y: centerY, width: bandWidth, height: halfH)), with: .color(foregroundColor))
        }
    }

    // MARK: - Wire (smooth curve, mirrored)

    private func drawWire(context: inout GraphicsContext, bandCount: Int, centerY: CGFloat,
                          maxBarHeight: CGFloat, horizontalPadding: CGFloat,
                          bandStride: CGFloat, frameWidth: CGFloat, bandWidth: CGFloat) {
        let halfMax = maxBarHeight / 2.0

        // Build points with edge anchors at zero
        var pts: [(x: CGFloat, mag: CGFloat)] = []
        pts.append((x: 0, mag: 0))
        for band in 0..<bandCount {
            let x = horizontalPadding + CGFloat(band) * bandStride + bandStride / 2.0
            pts.append((x: x, mag: CGFloat(clamped(bandMagnitudes[band]))))
        }
        pts.append((x: frameWidth, mag: 0))

        // Top half fill
        var topPath = Path()
        topPath.move(to: CGPoint(x: pts[0].x, y: centerY))
        for i in 0..<pts.count {
            let x = pts[i].x
            let y = centerY - pts[i].mag * halfMax
            if i == 0 {
                topPath.addLine(to: CGPoint(x: x, y: y))
            } else {
                let cpX = (pts[i - 1].x + x) / 2.0
                topPath.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: topPath.currentPoint!.y))
            }
        }
        topPath.addLine(to: CGPoint(x: pts.last!.x, y: centerY))
        topPath.closeSubpath()
        context.fill(topPath, with: .color(foregroundColor))

        // Bottom half fill (mirror)
        var bottomPath = Path()
        bottomPath.move(to: CGPoint(x: pts[0].x, y: centerY))
        for i in 0..<pts.count {
            let x = pts[i].x
            let y = centerY + pts[i].mag * halfMax
            if i == 0 {
                bottomPath.addLine(to: CGPoint(x: x, y: y))
            } else {
                let cpX = (pts[i - 1].x + x) / 2.0
                bottomPath.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: bottomPath.currentPoint!.y))
            }
        }
        bottomPath.addLine(to: CGPoint(x: pts.last!.x, y: centerY))
        bottomPath.closeSubpath()
        context.fill(bottomPath, with: .color(foregroundColor))

        // Stroke outlines
        let lineWidth = max(1.5, bandWidth * 0.15)
        for above in [true, false] {
            let sign: CGFloat = above ? -1.0 : 1.0
            var strokePath = Path()
            for i in 0..<pts.count {
                let x = pts[i].x
                let y = centerY + sign * pts[i].mag * halfMax
                if i == 0 {
                    strokePath.move(to: CGPoint(x: x, y: y))
                } else {
                    let cpX = (pts[i - 1].x + x) / 2.0
                    strokePath.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cpX, y: strokePath.currentPoint!.y))
                }
            }
            context.stroke(strokePath, with: .color(foregroundColor), lineWidth: lineWidth)
        }
    }

    private func clamped(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
