// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

/// Interactive crop overlay view that renders over the video player
/// Allows users to draw and adjust a crop rectangle with handles
struct CropOverlayView: View {
    @Binding var cropConfig: CropConfig
    let sourceWidth: Int
    let sourceHeight: Int
    let videoAspectRatio: Double
    let isEnabled: Bool

    @State private var isDragging = false
    @State private var dragMode: DragMode = .none
    @State private var dragStartRect: CropRect?
    @State private var shiftPressedAspectRatio: Double? = nil
    @State private var isOptionKeyPressed = false
    @State private var isShiftKeyPressed = false

    enum DragMode {
        case none
        case move
        case resizeTopLeft
        case resizeTopRight
        case resizeBottomLeft
        case resizeBottomRight
        case resizeTop
        case resizeBottom
        case resizeLeft
        case resizeRight
    }

    var body: some View {
        GeometryReader { geometry in
            let videoFrame = calculateVideoFrame(in: geometry.size)
            let screenRect = normalizedToScreen(
                cropConfig.normalizedRect,
                videoFrame: videoFrame
            )

            ZStack {
                // Darkened overlay outside crop area
                cropDimOverlay(screenRect: screenRect, geometry: geometry)

                // Crop rectangle with handles
                if isEnabled {
                    cropRectangleView(screenRect: screenRect)
                        .gesture(dragGesture(geometry: geometry, videoFrame: videoFrame))

                    // Cursor tracking overlay (visual feedback only, doesn't intercept events)
                    CursorTrackingView(screenRect: screenRect, videoFrame: videoFrame)
                        .allowsHitTesting(false)

                    // Center crosshair when Option key is pressed (center scaling mode)
                    if isOptionKeyPressed && isDragging {
                        centerCrosshairView(screenRect: screenRect)
                            .allowsHitTesting(false)
                    }

                    // Modifier key tracker
                    ModifierKeyTrackerView(
                        isOptionPressed: $isOptionKeyPressed,
                        isShiftPressed: $isShiftKeyPressed
                    )
                    .allowsHitTesting(false)
                    .onChange(of: isShiftKeyPressed) { _, newValue in
                        if isDragging && newValue {
                            // Shift just pressed during drag - capture current aspect ratio in DISPLAY space
                            let currentRect = cropConfig.normalizedRect
                            // Convert from normalized space to display space
                            // normalized ratio is in fractions of source dimensions
                            // display ratio accounts for video aspect ratio (including PAR)
                            let normalizedRatio = currentRect.width / currentRect.height
                            let displayRatio = normalizedRatio * videoAspectRatio
                            shiftPressedAspectRatio = displayRatio
                        } else if !newValue {
                            // Shift released - clear captured ratio
                            shiftPressedAspectRatio = nil
                        }
                    }
                }
            }
        }
        .allowsHitTesting(isEnabled)
    }

    // MARK: - Overlay Components

    private func cropDimOverlay(screenRect: CGRect, geometry: GeometryProxy) -> some View {
        // Creates darkened overlay with cutout for crop area
        Color.black.opacity(0.5)
            .mask(
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Rectangle()
                            .frame(width: screenRect.width, height: screenRect.height)
                            .position(x: screenRect.midX, y: screenRect.midY)
                            .blendMode(.destinationOut)
                    )
            )
    }

    private func cropRectangleView(screenRect: CGRect) -> some View {
        ZStack {
            // Transparent fill for better hit testing (makes entire interior draggable)
            Rectangle()
                .fill(Color.white.opacity(0.001))  // Nearly invisible but receives hits
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)

            // White border
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: screenRect.width, height: screenRect.height)
                .position(x: screenRect.midX, y: screenRect.midY)

            // Rule of thirds grid
            ruleOfThirdsGrid(rect: screenRect)

            // Resize handles (8 total)
            resizeHandles(rect: screenRect)
        }
    }

    private func ruleOfThirdsGrid(rect: CGRect) -> some View {
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        return ZStack {
            // Vertical lines
            Path { path in
                path.move(to: CGPoint(x: rect.minX + thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + thirdWidth, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.maxY))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)

            // Horizontal lines
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + thirdHeight))
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + 2 * thirdHeight))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 2 * thirdHeight))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)
        }
    }

    private func centerCrosshairView(screenRect: CGRect) -> some View {
        let center = CGPoint(x: screenRect.midX, y: screenRect.midY)
        let crosshairSize: CGFloat = 20

        return ZStack {
            // Horizontal line
            Path { path in
                path.move(to: CGPoint(x: center.x - crosshairSize, y: center.y))
                path.addLine(to: CGPoint(x: center.x + crosshairSize, y: center.y))
            }
            .stroke(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)

            // Vertical line
            Path { path in
                path.move(to: CGPoint(x: center.x, y: center.y - crosshairSize))
                path.addLine(to: CGPoint(x: center.x, y: center.y + crosshairSize))
            }
            .stroke(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)

            // Center dot
            Circle()
                .fill(Color.white)
                .frame(width: 4, height: 4)
                .position(center)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
        }
    }

    private func resizeHandles(rect: CGRect) -> some View {
        let handleSize: CGFloat = 16

        return Group {
            // Corner handles
            handleView(at: CGPoint(x: rect.minX, y: rect.minY), size: handleSize)
            handleView(at: CGPoint(x: rect.maxX, y: rect.minY), size: handleSize)
            handleView(at: CGPoint(x: rect.minX, y: rect.maxY), size: handleSize)
            handleView(at: CGPoint(x: rect.maxX, y: rect.maxY), size: handleSize)

            // Edge handles
            handleView(at: CGPoint(x: rect.midX, y: rect.minY), size: handleSize)
            handleView(at: CGPoint(x: rect.midX, y: rect.maxY), size: handleSize)
            handleView(at: CGPoint(x: rect.minX, y: rect.midY), size: handleSize)
            handleView(at: CGPoint(x: rect.maxX, y: rect.midY), size: handleSize)
        }
    }

    private func handleView(at point: CGPoint, size: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 2)
            .position(point)
    }

    // MARK: - Gesture Handling

    private func dragGesture(geometry: GeometryProxy, videoFrame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleDragChanged(value: value, geometry: geometry, videoFrame: videoFrame)
            }
            .onEnded { _ in
                handleDragEnded()
            }
    }

    private func handleDragChanged(value: DragGesture.Value, geometry: GeometryProxy, videoFrame: CGRect) {
        if !isDragging {
            isDragging = true
            dragStartRect = cropConfig.normalizedRect
            dragMode = determineDragMode(location: value.startLocation, videoFrame: videoFrame)
        }

        guard let startRect = dragStartRect else { return }

        // Store original center point for Option key (center scaling) mode
        let originalCenter = CGPoint(
            x: startRect.x + startRect.width / 2,
            y: startRect.y + startRect.height / 2
        )

        let screenDelta = value.translation
        let normalizedDelta = screenToNormalizedDelta(screenDelta, videoFrame: videoFrame)

        var newRect = startRect

        // Apply transformations based on drag mode
        switch dragMode {
        case .move:
            newRect = moveRect(startRect, by: normalizedDelta)
        case .resizeTopLeft:
            newRect = resizeTopLeft(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeTopRight:
            newRect = resizeTopRight(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeBottomLeft:
            newRect = resizeBottomLeft(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeBottomRight:
            newRect = resizeBottomRight(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeTop:
            newRect = resizeTop(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeBottom:
            newRect = resizeBottom(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeLeft:
            newRect = resizeLeft(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .resizeRight:
            newRect = resizeRight(startRect, by: normalizedDelta, scaleFromCenter: isOptionKeyPressed)
        case .none:
            return
        }

        // Apply aspect ratio constraint
        // Shift key: lock to aspect ratio when shift was first pressed during this drag
        // Config lock: use configured aspect ratio
        let aspectRatioToUse: Double? = if isShiftKeyPressed {
            shiftPressedAspectRatio
        } else {
            cropConfig.aspectRatioLock?.numericRatio
        }

        if let aspectRatio = aspectRatioToUse {
            newRect = constrainToAspectRatio(newRect, ratio: aspectRatio, dragMode: dragMode)
        }

        // Clamp to valid bounds (0-1), preserving aspect ratio if locked
        // When scaling from center (Option key), preserve the center point
        newRect = clampRect(newRect, aspectRatio: aspectRatioToUse, preserveCenter: isOptionKeyPressed ? originalCenter : nil)

        cropConfig.normalizedRect = newRect
    }

    private func handleDragEnded() {
        isDragging = false
        dragMode = .none
        dragStartRect = nil
        shiftPressedAspectRatio = nil
    }

    // MARK: - Coordinate Mapping

    /// Calculates the rect where video actually renders (accounting for letterbox/pillarbox)
    private func calculateVideoFrame(in playerSize: CGSize) -> CGRect {
        let playerAspect = playerSize.width / playerSize.height

        if abs(videoAspectRatio - playerAspect) < 0.01 {
            // No letterboxing
            return CGRect(origin: .zero, size: playerSize)
        }

        if videoAspectRatio > playerAspect {
            // Video is wider: letterbox top/bottom
            let videoHeight = playerSize.width / videoAspectRatio
            let offsetY = (playerSize.height - videoHeight) / 2
            return CGRect(x: 0, y: offsetY, width: playerSize.width, height: videoHeight)
        } else {
            // Video is taller: pillarbox left/right
            let videoWidth = playerSize.height * videoAspectRatio
            let offsetX = (playerSize.width - videoWidth) / 2
            return CGRect(x: offsetX, y: 0, width: videoWidth, height: playerSize.height)
        }
    }

    /// Converts normalized crop rect (0-1 in source pixel space) to screen coordinates within video frame
    ///
    /// The normalized rect is stored as fractions of SOURCE PIXEL dimensions (for correct FFMPEG output).
    /// The crop box shows WHERE on the displayed video the crop will be taken from.
    ///
    /// For non-square PAR sources (e.g., 1440×1080 displayed as 1920×1080):
    /// - The preview displays the source stretched to 16:9
    /// - The crop box covers the same RELATIVE area of the displayed video as the pixel crop
    /// - A 1:1 PIXEL crop will appear as 4:3 on the stretched preview (covering 75% width, 100% height)
    /// - But the OUTPUT will be 1:1 because it uses setsar=1:1
    ///
    /// Note: The box shows the COVERAGE (which pixels are included), not the OUTPUT shape.
    /// Users rely on the aspect ratio preset label to know what the output will look like.
    private func normalizedToScreen(_ rect: CropRect, videoFrame: CGRect) -> CGRect {
        // Direct mapping: normalized fractions map to video frame fractions
        // This ensures box edges align with the corresponding pixel positions on the displayed video
        CGRect(
            x: videoFrame.origin.x + rect.x * videoFrame.width,
            y: videoFrame.origin.y + rect.y * videoFrame.height,
            width: rect.width * videoFrame.width,
            height: rect.height * videoFrame.height
        )
    }

    /// Converts a screen point to normalized coordinates
    ///
    /// Screen position maps 1:1 with normalized position (center of screen = center of normalized space)
    /// This is because PAR stretching is uniform across the frame.
    private func screenToNormalized(_ point: CGPoint, videoFrame: CGRect) -> CGPoint {
        return CGPoint(
            x: (point.x - videoFrame.origin.x) / videoFrame.width,
            y: (point.y - videoFrame.origin.y) / videoFrame.height
        )
    }

    /// Converts screen delta to normalized delta
    ///
    /// For position changes, this maps 1:1 (no PAR correction needed).
    /// For width changes during resize, PAR correction is needed but that's handled
    /// by computing from absolute positions rather than deltas.
    private func screenToNormalizedDelta(_ delta: CGSize, videoFrame: CGRect) -> CGSize {
        return CGSize(
            width: Double(delta.width) / Double(videoFrame.width),
            height: Double(delta.height) / Double(videoFrame.height)
        )
    }

    /// PAR value for coordinate conversions
    private var par: Double {
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        return videoAspectRatio / sourceAspect
    }

    // MARK: - Drag Mode Detection

    private func determineDragMode(location: CGPoint, videoFrame: CGRect) -> DragMode {
        let screenRect = normalizedToScreen(cropConfig.normalizedRect, videoFrame: videoFrame)
        let hitSize: CGFloat = 20  // Hit area around handles

        // Check corners first (priority over edges)
        if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.minY)) < hitSize {
            return .resizeTopLeft
        }
        if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.minY)) < hitSize {
            return .resizeTopRight
        }
        if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.maxY)) < hitSize {
            return .resizeBottomLeft
        }
        if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY)) < hitSize {
            return .resizeBottomRight
        }

        // Check edges
        if abs(location.y - screenRect.minY) < hitSize &&
           location.x > screenRect.minX + hitSize &&
           location.x < screenRect.maxX - hitSize {
            return .resizeTop
        }
        if abs(location.y - screenRect.maxY) < hitSize &&
           location.x > screenRect.minX + hitSize &&
           location.x < screenRect.maxX - hitSize {
            return .resizeBottom
        }
        if abs(location.x - screenRect.minX) < hitSize &&
           location.y > screenRect.minY + hitSize &&
           location.y < screenRect.maxY - hitSize {
            return .resizeLeft
        }
        if abs(location.x - screenRect.maxX) < hitSize &&
           location.y > screenRect.minY + hitSize &&
           location.y < screenRect.maxY - hitSize {
            return .resizeRight
        }

        // Check if inside rectangle (move mode)
        if screenRect.contains(location) {
            return .move
        }

        return .none
    }

    // MARK: - Rectangle Manipulation

    private func moveRect(_ rect: CropRect, by delta: CGSize) -> CropRect {
        CropRect(
            x: rect.x + delta.width,
            y: rect.y + delta.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func resizeTopLeft(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            // Scale from center: opposite corner moves equally in opposite direction
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y + delta.height,
                width: rect.width - delta.width * 2,
                height: rect.height - delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y + delta.height,
                width: rect.width - delta.width,
                height: rect.height - delta.height
            )
        }
    }

    private func resizeTopRight(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x - delta.width,
                y: rect.y + delta.height,
                width: rect.width + delta.width * 2,
                height: rect.height - delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x,
                y: rect.y + delta.height,
                width: rect.width + delta.width,
                height: rect.height - delta.height
            )
        }
    }

    private func resizeBottomLeft(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y - delta.height,
                width: rect.width - delta.width * 2,
                height: rect.height + delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y,
                width: rect.width - delta.width,
                height: rect.height + delta.height
            )
        }
    }

    private func resizeBottomRight(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x - delta.width,
                y: rect.y - delta.height,
                width: rect.width + delta.width * 2,
                height: rect.height + delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x,
                y: rect.y,
                width: rect.width + delta.width,
                height: rect.height + delta.height
            )
        }
    }

    private func resizeTop(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x,
                y: rect.y + delta.height,
                width: rect.width,
                height: rect.height - delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x,
                y: rect.y + delta.height,
                width: rect.width,
                height: rect.height - delta.height
            )
        }
    }

    private func resizeBottom(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x,
                y: rect.y - delta.height,
                width: rect.width,
                height: rect.height + delta.height * 2
            )
        } else {
            return CropRect(
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height + delta.height
            )
        }
    }

    private func resizeLeft(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y,
                width: rect.width - delta.width * 2,
                height: rect.height
            )
        } else {
            return CropRect(
                x: rect.x + delta.width,
                y: rect.y,
                width: rect.width - delta.width,
                height: rect.height
            )
        }
    }

    private func resizeRight(_ rect: CropRect, by delta: CGSize, scaleFromCenter: Bool) -> CropRect {
        if scaleFromCenter {
            return CropRect(
                x: rect.x - delta.width,
                y: rect.y,
                width: rect.width + delta.width * 2,
                height: rect.height
            )
        } else {
            return CropRect(
                x: rect.x,
                y: rect.y,
                width: rect.width + delta.width,
                height: rect.height
            )
        }
    }

    // MARK: - Aspect Ratio Constraints

    private func constrainToAspectRatio(_ rect: CropRect, ratio: Double, dragMode: DragMode) -> CropRect {
        // Convert target aspect ratio from OUTPUT space to normalized (pixel) space
        // The target ratio specifies the desired OUTPUT aspect ratio (with setsar=1:1).
        // We use sourceAspect (pixel dimensions) so FFMPEG gets correct pixel crop.
        // The preview compensates visually by stretching the crop box by PAR.
        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let normalizedTargetRatio = ratio / sourceAspect

        let currentRatio = rect.width / rect.height

        if abs(currentRatio - normalizedTargetRatio) < 0.01 {
            return rect  // Already at correct ratio
        }

        switch dragMode {
        case .resizeTopLeft, .resizeTopRight, .resizeBottomLeft, .resizeBottomRight:
            // Corner resize: adjust height to match width / normalizedTargetRatio
            let newHeight = rect.width / normalizedTargetRatio
            let deltaY = newHeight - rect.height

            // Adjust y position for top corners to maintain bottom edge
            if dragMode == .resizeTopLeft || dragMode == .resizeTopRight {
                return CropRect(x: rect.x, y: rect.y - deltaY, width: rect.width, height: newHeight)
            } else {
                return CropRect(x: rect.x, y: rect.y, width: rect.width, height: newHeight)
            }

        case .resizeTop, .resizeBottom:
            // Vertical edge: adjust width to match height * normalizedTargetRatio
            let newWidth = rect.height * normalizedTargetRatio
            let deltaX = (newWidth - rect.width) / 2
            return CropRect(x: rect.x - deltaX, y: rect.y, width: newWidth, height: rect.height)

        case .resizeLeft, .resizeRight:
            // Horizontal edge: adjust height to match width / normalizedTargetRatio
            let newHeight = rect.width / normalizedTargetRatio
            let deltaY = (newHeight - rect.height) / 2
            return CropRect(x: rect.x, y: rect.y - deltaY, width: rect.width, height: newHeight)

        default:
            return rect
        }
    }

    private func clampRect(_ rect: CropRect, aspectRatio: Double? = nil, preserveCenter: CGPoint? = nil) -> CropRect {
        var clamped = rect

        // If aspect ratio is locked, we need to maintain it while clamping
        if let targetRatio = aspectRatio {
            // Convert target aspect ratio from OUTPUT space to normalized (pixel) space
            // Use sourceAspect so FFMPEG gets correct pixel crop
            let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
            let normalizedTargetRatio = targetRatio / sourceAspect

            // Calculate the maximum rect that fits within bounds with the target aspect ratio
            // Try both width-constrained and height-constrained and pick the smaller one

            // Width-constrained: fit to width = 1.0
            let widthConstrainedWidth = 1.0
            let widthConstrainedHeight = widthConstrainedWidth / normalizedTargetRatio

            // Height-constrained: fit to height = 1.0
            let heightConstrainedHeight = 1.0
            let heightConstrainedWidth = heightConstrainedHeight * normalizedTargetRatio

            // Pick the constraint that fits
            let maxWidth: Double
            let maxHeight: Double
            if widthConstrainedHeight <= 1.0 {
                // Width-constrained fits
                maxWidth = widthConstrainedWidth
                maxHeight = widthConstrainedHeight
            } else {
                // Must use height-constrained
                maxWidth = heightConstrainedWidth
                maxHeight = heightConstrainedHeight
            }

            // Ensure minimum size (2% of frame for the smaller dimension)
            let minSize = 0.02
            let currentSize = min(clamped.width, clamped.height)

            if currentSize < minSize {
                // Scale up to minimum size while maintaining aspect ratio
                if clamped.width < clamped.height {
                    clamped.width = minSize
                    clamped.height = minSize / normalizedTargetRatio
                } else {
                    clamped.height = minSize
                    clamped.width = minSize * normalizedTargetRatio
                }
            }

            // Clamp to maximum size while maintaining aspect ratio
            if clamped.width > maxWidth || clamped.height > maxHeight {
                clamped.width = maxWidth
                clamped.height = maxHeight
            }

            // Clamp position to ensure rect stays within bounds
            if let center = preserveCenter {
                // Center-locked mode: position based on center point
                clamped.x = center.x - clamped.width / 2
                clamped.y = center.y - clamped.height / 2

                // If centered rect goes out of bounds, clamp it
                clamped.x = max(0, min(1 - clamped.width, clamped.x))
                clamped.y = max(0, min(1 - clamped.height, clamped.y))
            } else {
                clamped.x = max(0, min(1 - clamped.width, clamped.x))
                clamped.y = max(0, min(1 - clamped.height, clamped.y))
            }

        } else {
            // No aspect ratio lock - clamp freely

            // Ensure minimum size (2% of frame)
            let minSize = 0.02
            clamped.width = max(minSize, clamped.width)
            clamped.height = max(minSize, clamped.height)

            if let center = preserveCenter {
                // Center-locked mode: position based on center point
                clamped.x = center.x - clamped.width / 2
                clamped.y = center.y - clamped.height / 2

                // If centered rect goes out of bounds, adjust size to fit
                if clamped.x < 0 {
                    clamped.width = min(clamped.width, center.x * 2)
                    clamped.x = center.x - clamped.width / 2
                }
                if clamped.y < 0 {
                    clamped.height = min(clamped.height, center.y * 2)
                    clamped.y = center.y - clamped.height / 2
                }
                if clamped.x + clamped.width > 1 {
                    clamped.width = min(clamped.width, (1 - center.x) * 2)
                    clamped.x = center.x - clamped.width / 2
                }
                if clamped.y + clamped.height > 1 {
                    clamped.height = min(clamped.height, (1 - center.y) * 2)
                    clamped.y = center.y - clamped.height / 2
                }

                // Final safety clamp
                clamped.x = max(0, min(1 - clamped.width, clamped.x))
                clamped.y = max(0, min(1 - clamped.height, clamped.y))
            } else {
                // Clamp position to bounds
                clamped.x = max(0, min(1 - clamped.width, clamped.x))
                clamped.y = max(0, min(1 - clamped.height, clamped.y))

                // Clamp size to not exceed bounds
                clamped.width = min(1 - clamped.x, clamped.width)
                clamped.height = min(1 - clamped.y, clamped.height)
            }
        }

        return clamped
    }
}

// MARK: - CGPoint Extension

extension CGPoint {
    func distance(to point: CGPoint) -> CGFloat {
        sqrt(pow(x - point.x, 2) + pow(y - point.y, 2))
    }
}

// MARK: - Cursor Tracking

/// Tracks mouse position and changes cursor based on crop area being hovered
private struct CursorTrackingView: NSViewRepresentable {
    let screenRect: CGRect
    let videoFrame: CGRect

    func makeNSView(context: Context) -> NSView {
        let view = CursorTrackingNSView()
        view.screenRect = screenRect
        view.videoFrame = videoFrame
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let trackingView = nsView as? CursorTrackingNSView {
            trackingView.screenRect = screenRect
            trackingView.videoFrame = videoFrame
        }
    }

    class CursorTrackingNSView: NSView {
        var screenRect: CGRect = .zero
        var videoFrame: CGRect = .zero
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let existingTrackingArea = trackingArea {
                removeTrackingArea(existingTrackingArea)
            }

            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow
            ]

            trackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )

            if let trackingArea = trackingArea {
                addTrackingArea(trackingArea)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            let cursor = cursorForLocation(location)
            cursor.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        private func cursorForLocation(_ location: CGPoint) -> NSCursor {
            let hitSize: CGFloat = 20

            // Helper to create cursor from SF Symbol or fall back to system cursor
            func diagonalCursor(systemName: String, fallback: NSCursor) -> NSCursor {
                if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
                    let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                    let configuredImage = image.withSymbolConfiguration(config) ?? image
                    return NSCursor(image: configuredImage, hotSpot: NSPoint(x: 8, y: 8))
                }
                return fallback
            }

            // Check corners first (higher priority than edges)
            // Note: In NSView coordinates, minY is TOP and maxY is BOTTOM
            // Top-left corner - visually this is NW, should resize diagonally to SE
            if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.minY)) < hitSize {
                if #available(macOS 10.13, *) {
                    return diagonalCursor(systemName: "arrow.up.right.and.arrow.down.left", fallback: .crosshair)
                }
                return .crosshair
            }
            // Top-right corner - visually this is NE, should resize diagonally to SW
            if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.minY)) < hitSize {
                if #available(macOS 10.13, *) {
                    return diagonalCursor(systemName: "arrow.up.left.and.arrow.down.right", fallback: .crosshair)
                }
                return .crosshair
            }
            // Bottom-left corner - visually this is SW, should resize diagonally to NE
            if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.maxY)) < hitSize {
                if #available(macOS 10.13, *) {
                    return diagonalCursor(systemName: "arrow.up.left.and.arrow.down.right", fallback: .crosshair)
                }
                return .crosshair
            }
            // Bottom-right corner - visually this is SE, should resize diagonally to NW
            if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY)) < hitSize {
                if #available(macOS 10.13, *) {
                    return diagonalCursor(systemName: "arrow.up.right.and.arrow.down.left", fallback: .crosshair)
                }
                return .crosshair
            }

            // Check edges (only if not near corners)
            // Top edge
            if abs(location.y - screenRect.minY) < hitSize &&
               location.x >= screenRect.minX + hitSize &&
               location.x <= screenRect.maxX - hitSize {
                return .resizeUpDown
            }
            // Bottom edge
            if abs(location.y - screenRect.maxY) < hitSize &&
               location.x >= screenRect.minX + hitSize &&
               location.x <= screenRect.maxX - hitSize {
                return .resizeUpDown
            }
            // Left edge
            if abs(location.x - screenRect.minX) < hitSize &&
               location.y >= screenRect.minY + hitSize &&
               location.y <= screenRect.maxY - hitSize {
                return .resizeLeftRight
            }
            // Right edge
            if abs(location.x - screenRect.maxX) < hitSize &&
               location.y >= screenRect.minY + hitSize &&
               location.y <= screenRect.maxY - hitSize {
                return .resizeLeftRight
            }

            // Check if inside rectangle (move mode)
            if screenRect.contains(location) {
                return .openHand  // Hand cursor for moving
            }

            return .arrow
        }
    }
}

// MARK: - Modifier Key Tracking

/// Tracks modifier key state (Option and Shift)
private struct ModifierKeyTrackerView: NSViewRepresentable {
    @Binding var isOptionPressed: Bool
    @Binding var isShiftPressed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ModifierKeyTrackingNSView()
        view.isOptionPressed = $isOptionPressed
        view.isShiftPressed = $isShiftPressed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }

    class ModifierKeyTrackingNSView: NSView {
        var isOptionPressed: Binding<Bool>?
        var isShiftPressed: Binding<Bool>?
        private var monitor: Any? {
            willSet {
                if let oldMonitor = monitor {
                    NSEvent.removeMonitor(oldMonitor)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window != nil {
                // Monitor flag changes
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    self?.updateModifierState(event.modifierFlags)
                    return event
                }
            } else {
                monitor = nil
            }
        }

        private func updateModifierState(_ flags: NSEvent.ModifierFlags) {
            DispatchQueue.main.async { [weak self] in
                self?.isOptionPressed?.wrappedValue = flags.contains(.option)
                self?.isShiftPressed?.wrappedValue = flags.contains(.shift)
            }
        }
    }
}
