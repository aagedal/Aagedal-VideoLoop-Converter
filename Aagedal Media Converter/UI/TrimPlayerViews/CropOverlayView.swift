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

                    // Modifier key tracker
                    ModifierKeyTrackerView(
                        isOptionPressed: $isOptionKeyPressed,
                        isShiftPressed: $isShiftKeyPressed
                    )
                    .allowsHitTesting(false)
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
        // Shift key: lock to current aspect ratio
        // Config lock: use configured aspect ratio
        let aspectRatioToUse: Double? = if isShiftKeyPressed {
            startRect.width / startRect.height
        } else {
            cropConfig.aspectRatioLock?.numericRatio
        }

        if let aspectRatio = aspectRatioToUse {
            newRect = constrainToAspectRatio(newRect, ratio: aspectRatio, dragMode: dragMode)
        }

        // Clamp to valid bounds (0-1)
        newRect = clampRect(newRect)

        cropConfig.normalizedRect = newRect
    }

    private func handleDragEnded() {
        isDragging = false
        dragMode = .none
        dragStartRect = nil
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
    private func normalizedToScreen(_ rect: CropRect, videoFrame: CGRect) -> CGRect {
        // Scale factors from source pixel space to display space
        let scaleX = videoFrame.width / Double(sourceWidth)
        let scaleY = videoFrame.height / Double(sourceHeight)

        return CGRect(
            x: videoFrame.origin.x + rect.x * Double(sourceWidth) * scaleX,
            y: videoFrame.origin.y + rect.y * Double(sourceHeight) * scaleY,
            width: rect.width * Double(sourceWidth) * scaleX,
            height: rect.height * Double(sourceHeight) * scaleY
        )
    }

    /// Converts screen delta to normalized delta
    private func screenToNormalizedDelta(_ delta: CGSize, videoFrame: CGRect) -> CGSize {
        CGSize(
            width: Double(delta.width) / Double(videoFrame.width),
            height: Double(delta.height) / Double(videoFrame.height)
        )
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
        // Convert target aspect ratio from pixel space to normalized space
        // Normalized coords are fractions of source dimensions
        // To maintain pixel aspect ratio, we must account for source aspect
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

    private func clampRect(_ rect: CropRect) -> CropRect {
        var clamped = rect

        // Ensure minimum size (2% of frame)
        let minSize = 0.02
        clamped.width = max(minSize, clamped.width)
        clamped.height = max(minSize, clamped.height)

        // Clamp position to bounds
        clamped.x = max(0, min(1 - clamped.width, clamped.x))
        clamped.y = max(0, min(1 - clamped.height, clamped.y))

        // Clamp size to not exceed bounds
        clamped.width = min(1 - clamped.x, clamped.width)
        clamped.height = min(1 - clamped.y, clamped.height)

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

            // Check corners first (use system resize cursors from private API or fall back to crosshair)
            if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.minY)) < hitSize {
                return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil) ?? NSImage(),
                               hotSpot: NSPoint(x: 8, y: 8))  // Top-left
            }
            if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.minY)) < hitSize {
                return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage(),
                               hotSpot: NSPoint(x: 8, y: 8))  // Top-right
            }
            if location.distance(to: CGPoint(x: screenRect.minX, y: screenRect.maxY)) < hitSize {
                return NSCursor(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage(),
                               hotSpot: NSPoint(x: 8, y: 8))  // Bottom-left
            }
            if location.distance(to: CGPoint(x: screenRect.maxX, y: screenRect.maxY)) < hitSize {
                return NSCursor(image: NSImage(systemSymbolName: "arrow.up.right.and.arrow.down.left", accessibilityDescription: nil) ?? NSImage(),
                               hotSpot: NSPoint(x: 8, y: 8))  // Bottom-right
            }

            // Check edges
            if abs(location.y - screenRect.minY) < hitSize &&
               location.x > screenRect.minX + hitSize &&
               location.x < screenRect.maxX - hitSize {
                return .resizeUpDown  // Top edge
            }
            if abs(location.y - screenRect.maxY) < hitSize &&
               location.x > screenRect.minX + hitSize &&
               location.x < screenRect.maxX - hitSize {
                return .resizeUpDown  // Bottom edge
            }
            if abs(location.x - screenRect.minX) < hitSize &&
               location.y > screenRect.minY + hitSize &&
               location.y < screenRect.maxY - hitSize {
                return .resizeLeftRight  // Left edge
            }
            if abs(location.x - screenRect.maxX) < hitSize &&
               location.y > screenRect.minY + hitSize &&
               location.y < screenRect.maxY - hitSize {
                return .resizeLeftRight  // Right edge
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
