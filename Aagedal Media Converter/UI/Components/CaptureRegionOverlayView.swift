// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct CaptureRegionOverlayView: View {
    let screenSize: CGSize
    let displayScaleFactor: CGFloat
    let initialRegion: CGRect?
    let onRegionChanged: (CGRect) -> Void
    let onCancel: () -> Void

    private enum SelectionPhase {
        case drawing
        case refining
    }

    private enum DragMode {
        case none
        case draw
        case move
        case resizeTopLeft, resizeTopRight, resizeBottomLeft, resizeBottomRight
        case resizeTop, resizeBottom, resizeLeft, resizeRight
    }

    private let minimumSize: CGFloat = 64
    private let handleHitSize: CGFloat = 20

    @State private var phase: SelectionPhase = .drawing
    @State private var selectionRect: CGRect? = nil
    @State private var isDragging = false
    @State private var dragMode: DragMode = .none
    @State private var dragStartPoint: CGPoint? = nil
    @State private var dragStartRect: CGRect? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Cursor tracking layer — must be behind everything but cover the full area
                CaptureRegionCursorView(
                    selectionRect: selectionRect,
                    phase: phase == .refining,
                    handleHitSize: handleHitSize,
                    isDragging: isDragging,
                    dragMode: dragModeForCursor,
                    onEscape: { onCancel() }
                )

                dimOverlay(in: geometry.size)

                if let rect = selectionRect {
                    selectionRectangleView(rect: rect)
                }

                if phase == .drawing, selectionRect == nil {
                    crosshairOverlay
                }
            }
            .contentShape(Rectangle())
            .gesture(mainDragGesture(in: geometry.size))
            .onAppear {
                if let initialRegion {
                    selectionRect = initialRegion
                    phase = .refining
                }
            }
        }
        .ignoresSafeArea()
    }

    /// Maps internal DragMode to a cursor-friendly integer for the NSView
    private var dragModeForCursor: Int {
        switch dragMode {
        case .none: return 0
        case .draw: return 1
        case .move: return 2
        case .resizeTopLeft: return 3
        case .resizeTopRight: return 4
        case .resizeBottomLeft: return 5
        case .resizeBottomRight: return 6
        case .resizeTop: return 7
        case .resizeBottom: return 8
        case .resizeLeft: return 9
        case .resizeRight: return 10
        }
    }

    // MARK: - Overlay Components

    private func dimOverlay(in size: CGSize) -> some View {
        Color.black.opacity(0.4)
            .frame(width: size.width, height: size.height)
            .mask(
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        Group {
                            if let rect = selectionRect {
                                Rectangle()
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .blendMode(.destinationOut)
                            }
                        }
                    )
            )
            .allowsHitTesting(false)
    }

    private var crosshairOverlay: some View {
        ZStack {
            Text("Click and drag to select a recording region")
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 4)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func selectionRectangleView(rect: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if phase == .refining {
                ruleOfThirdsGrid(rect: rect)
                resizeHandles(rect: rect)
            }

            dimensionLabel(for: rect)
        }
        .allowsHitTesting(false)
    }

    private func ruleOfThirdsGrid(rect: CGRect) -> some View {
        let thirdWidth = rect.width / 3
        let thirdHeight = rect.height / 3

        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: rect.minX + thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + thirdWidth, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + 2 * thirdWidth, y: rect.maxY))
            }
            .stroke(Color.white.opacity(0.3), lineWidth: 1)

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
        Group {
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.minY), hDir: -1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.minY), hDir: 1, vDir: -1, in: rect)
            cornerBracket(at: CGPoint(x: rect.minX, y: rect.maxY), hDir: -1, vDir: 1, in: rect)
            cornerBracket(at: CGPoint(x: rect.maxX, y: rect.maxY), hDir: 1, vDir: 1, in: rect)

            edgeHandle(at: CGPoint(x: rect.midX, y: rect.minY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.midX, y: rect.maxY), isVertical: false)
            edgeHandle(at: CGPoint(x: rect.minX, y: rect.midY), isVertical: true)
            edgeHandle(at: CGPoint(x: rect.maxX, y: rect.midY), isVertical: true)
        }
    }

    private func cornerBracket(at corner: CGPoint, hDir: Double, vDir: Double, in rect: CGRect) -> some View {
        let armLength = min(16.0, min(rect.width, rect.height) * 0.15)
        let hPoint = CGPoint(x: corner.x - hDir * armLength, y: corner.y)
        let vPoint = CGPoint(x: corner.x, y: corner.y - vDir * armLength)

        return ZStack {
            Path { path in
                path.move(to: hPoint)
                path.addLine(to: corner)
                path.addLine(to: vPoint)
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))

            Circle()
                .fill(Color.clear)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
                .position(corner)
        }
    }

    private func edgeHandle(at point: CGPoint, isVertical: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(
                    width: isVertical ? 4 : 24,
                    height: isVertical ? 24 : 4
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.black.opacity(0.5), lineWidth: 0.5)
                )

            Rectangle()
                .fill(Color.clear)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .position(point)
    }

    private func dimensionLabel(for rect: CGRect) -> some View {
        let pixelW = Int(rect.width * displayScaleFactor)
        let pixelH = Int(rect.height * displayScaleFactor)
        let evenW = (pixelW / 2) * 2
        let evenH = (pixelH / 2) * 2

        return Text("\(Int(rect.width)) \u{00D7} \(Int(rect.height)) pts \u{2022} \(evenW) \u{00D7} \(evenH) px")
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: rect.midX, y: rect.maxY + 24)
    }

    // MARK: - Gesture Handling

    private func mainDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                handleDragChanged(value: value, in: size)
            }
            .onEnded { _ in
                handleDragEnded()
            }
    }

    private func handleDragChanged(value: DragGesture.Value, in size: CGSize) {
        if !isDragging {
            isDragging = true
            dragStartPoint = value.startLocation

            if phase == .drawing {
                dragMode = .draw
                dragStartRect = nil
            } else if let rect = selectionRect {
                dragStartRect = rect
                dragMode = determineDragMode(location: value.startLocation, rect: rect)
                if dragMode == .none {
                    dragMode = .draw
                    phase = .drawing
                    dragStartRect = nil
                }
            }
        }

        switch dragMode {
        case .draw:
            guard let start = dragStartPoint else { return }
            let current = value.location
            let x = min(start.x, current.x)
            let y = min(start.y, current.y)
            let w = abs(current.x - start.x)
            let h = abs(current.y - start.y)
            selectionRect = CGRect(x: x, y: y, width: max(w, 1), height: max(h, 1))

        case .move:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            var newX = startRect.origin.x + dx
            var newY = startRect.origin.y + dy
            newX = max(0, min(newX, size.width - startRect.width))
            newY = max(0, min(newY, size.height - startRect.height))
            selectionRect = CGRect(x: newX, y: newY, width: startRect.width, height: startRect.height)

        case .resizeTopLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            applyResize(newX: startRect.minX + dx, newY: startRect.minY + dy, newW: startRect.width - dx, newH: startRect.height - dy, in: size)

        case .resizeTopRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            applyResize(newX: startRect.minX, newY: startRect.minY + dy, newW: startRect.width + dx, newH: startRect.height - dy, in: size)

        case .resizeBottomLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            applyResize(newX: startRect.minX + dx, newY: startRect.minY, newW: startRect.width - dx, newH: startRect.height + dy, in: size)

        case .resizeBottomRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: startRect.width + dx, newH: startRect.height + dy, in: size)

        case .resizeTop:
            guard let startRect = dragStartRect else { return }
            let dy = value.translation.height
            applyResize(newX: startRect.minX, newY: startRect.minY + dy, newW: startRect.width, newH: startRect.height - dy, in: size)

        case .resizeBottom:
            guard let startRect = dragStartRect else { return }
            let dy = value.translation.height
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: startRect.width, newH: startRect.height + dy, in: size)

        case .resizeLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            applyResize(newX: startRect.minX + dx, newY: startRect.minY, newW: startRect.width - dx, newH: startRect.height, in: size)

        case .resizeRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: startRect.width + dx, newH: startRect.height, in: size)

        case .none:
            break
        }
    }

    private func applyResize(newX: CGFloat, newY: CGFloat, newW: CGFloat, newH: CGFloat, in size: CGSize) {
        let clampedW = max(minimumSize, newW)
        let clampedH = max(minimumSize, newH)
        let clampedX = max(0, min(newX, size.width - clampedW))
        let clampedY = max(0, min(newY, size.height - clampedH))
        selectionRect = CGRect(x: clampedX, y: clampedY, width: min(clampedW, size.width - clampedX), height: min(clampedH, size.height - clampedY))
    }

    private func handleDragEnded() {
        isDragging = false

        if dragMode == .draw {
            if let rect = selectionRect, rect.width >= minimumSize, rect.height >= minimumSize {
                phase = .refining
                onRegionChanged(rect)
            } else if let rect = selectionRect, (rect.width < minimumSize || rect.height < minimumSize) {
                selectionRect = nil
                phase = .drawing
            }
        } else if let rect = selectionRect {
            onRegionChanged(rect)
        }

        dragMode = .none
        dragStartPoint = nil
        dragStartRect = nil
    }

    private func determineDragMode(location: CGPoint, rect: CGRect) -> DragMode {
        if location.distance(to: CGPoint(x: rect.minX, y: rect.minY)) < handleHitSize {
            return .resizeTopLeft
        }
        if location.distance(to: CGPoint(x: rect.maxX, y: rect.minY)) < handleHitSize {
            return .resizeTopRight
        }
        if location.distance(to: CGPoint(x: rect.minX, y: rect.maxY)) < handleHitSize {
            return .resizeBottomLeft
        }
        if location.distance(to: CGPoint(x: rect.maxX, y: rect.maxY)) < handleHitSize {
            return .resizeBottomRight
        }

        if abs(location.y - rect.minY) < handleHitSize &&
           location.x > rect.minX + handleHitSize &&
           location.x < rect.maxX - handleHitSize {
            return .resizeTop
        }
        if abs(location.y - rect.maxY) < handleHitSize &&
           location.x > rect.minX + handleHitSize &&
           location.x < rect.maxX - handleHitSize {
            return .resizeBottom
        }
        if abs(location.x - rect.minX) < handleHitSize &&
           location.y > rect.minY + handleHitSize &&
           location.y < rect.maxY - handleHitSize {
            return .resizeLeft
        }
        if abs(location.x - rect.maxX) < handleHitSize &&
           location.y > rect.minY + handleHitSize &&
           location.y < rect.maxY - handleHitSize {
            return .resizeRight
        }

        if rect.contains(location) {
            return .move
        }

        return .none
    }
}

// MARK: - Cursor Tracking + Key Event Handling

/// NSViewRepresentable that covers the full overlay area, manages cursor appearance
/// based on hover position relative to the selection rectangle, and handles key events.
private struct CaptureRegionCursorView: NSViewRepresentable {
    let selectionRect: CGRect?
    let phase: Bool              // true = refining
    let handleHitSize: CGFloat
    let isDragging: Bool
    let dragMode: Int            // mapped from DragMode enum
    let onEscape: () -> Void

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.onEscape = onEscape
        view.autoresizingMask = [.width, .height]
        return view
    }

    func updateNSView(_ nsView: CursorTrackingNSView, context: Context) {
        nsView.selectionRect = selectionRect
        nsView.isRefining = phase
        nsView.handleHitSize = handleHitSize
        nsView.currentDragging = isDragging
        nsView.currentDragMode = dragMode
        nsView.onEscape = onEscape
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    class CursorTrackingNSView: NSView {
        var selectionRect: CGRect?
        var isRefining = false
        var handleHitSize: CGFloat = 20
        var currentDragging = false
        var currentDragMode = 0
        var onEscape: (() -> Void)?

        private var keyEventMonitor: Any?
        private var mouseEventMonitor: Any?
        private var trackingArea: NSTrackingArea?

        // Pass through all hit testing so SwiftUI gestures work
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                if keyEventMonitor == nil {
                    keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                        if event.keyCode == 53 { // Escape
                            self?.onEscape?()
                            return nil
                        }
                        return event
                    }
                }
                if mouseEventMonitor == nil {
                    // Use a global monitor to track mouse movement during drags,
                    // since hitTest returns nil and we won't receive mouseDragged directly.
                    mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                        guard let self else { return event }
                        if self.currentDragging {
                            self.cursorForDragMode(self.currentDragMode).set()
                        }
                        return event
                    }
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                if let monitor = keyEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    keyEventMonitor = nil
                }
                if let monitor = mouseEventMonitor {
                    NSEvent.removeMonitor(monitor)
                    mouseEventMonitor = nil
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func cursorUpdate(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseEntered(with event: NSEvent) {
            updateCursorForCurrentPosition(event)
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.crosshair.set()
        }

        private func updateCursorForCurrentPosition(_ event: NSEvent) {
            if currentDragging {
                cursorForDragMode(currentDragMode).set()
                return
            }

            let locationInView = convert(event.locationInWindow, from: nil)
            // Flip Y: NSView has origin at bottom-left, but selection rect uses top-left (SwiftUI coords)
            let flippedY = bounds.height - locationInView.y
            let point = CGPoint(x: locationInView.x, y: flippedY)

            guard isRefining, let rect = selectionRect else {
                NSCursor.crosshair.set()
                return
            }

            let hitSize = handleHitSize

            // Check corners
            if point.distance(to: CGPoint(x: rect.minX, y: rect.minY)) < hitSize {
                cursorForDragMode(3).set() // topLeft
                return
            }
            if point.distance(to: CGPoint(x: rect.maxX, y: rect.minY)) < hitSize {
                cursorForDragMode(4).set() // topRight
                return
            }
            if point.distance(to: CGPoint(x: rect.minX, y: rect.maxY)) < hitSize {
                cursorForDragMode(5).set() // bottomLeft
                return
            }
            if point.distance(to: CGPoint(x: rect.maxX, y: rect.maxY)) < hitSize {
                cursorForDragMode(6).set() // bottomRight
                return
            }

            // Check edges
            if abs(point.y - rect.minY) < hitSize &&
               point.x > rect.minX + hitSize && point.x < rect.maxX - hitSize {
                cursorForDragMode(7).set() // top
                return
            }
            if abs(point.y - rect.maxY) < hitSize &&
               point.x > rect.minX + hitSize && point.x < rect.maxX - hitSize {
                cursorForDragMode(8).set() // bottom
                return
            }
            if abs(point.x - rect.minX) < hitSize &&
               point.y > rect.minY + hitSize && point.y < rect.maxY - hitSize {
                cursorForDragMode(9).set() // left
                return
            }
            if abs(point.x - rect.maxX) < hitSize &&
               point.y > rect.minY + hitSize && point.y < rect.maxY - hitSize {
                cursorForDragMode(10).set() // right
                return
            }

            // Inside selection
            if rect.contains(point) {
                NSCursor.openHand.set()
                return
            }

            // Outside selection
            NSCursor.crosshair.set()
        }

        /// Maps drag mode int to the appropriate NSCursor
        private func cursorForDragMode(_ mode: Int) -> NSCursor {
            switch mode {
            case 1:  return .crosshair                          // draw
            case 2:  return .closedHand                         // move
            case 3:  return Self.diagonalResizeCursor(nwse: true)  // topLeft
            case 4:  return Self.diagonalResizeCursor(nwse: false) // topRight
            case 5:  return Self.diagonalResizeCursor(nwse: false) // bottomLeft
            case 6:  return Self.diagonalResizeCursor(nwse: true)  // bottomRight
            case 7:  return .resizeUpDown                       // top
            case 8:  return .resizeUpDown                       // bottom
            case 9:  return .resizeLeftRight                    // left
            case 10: return .resizeLeftRight                    // right
            default: return .crosshair
            }
        }

        /// Creates a diagonal resize cursor (NW-SE or NE-SW).
        /// macOS doesn't provide diagonal cursors by default, so we create them from SF Symbols.
        private static func diagonalResizeCursor(nwse: Bool) -> NSCursor {
            let symbolName = nwse
                ? "arrow.up.left.and.arrow.down.right"
                : "arrow.up.right.and.arrow.down.left"
            if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                let configured = symbolImage.withSymbolConfiguration(config) ?? symbolImage

                // Render with white fill and black stroke for visibility
                let size = NSSize(width: 20, height: 20)
                let rendered = NSImage(size: size, flipped: false) { rect in
                    // Draw shadow
                    NSColor.black.withAlphaComponent(0.6).set()
                    configured.draw(in: rect.offsetBy(dx: 0.5, dy: -0.5))
                    // Draw cursor
                    NSColor.white.set()
                    configured.draw(in: rect)
                    return true
                }
                return NSCursor(image: rendered, hotSpot: NSPoint(x: 10, y: 10))
            }
            // Fallback
            return nwse ? .resizeUpDown : .resizeLeftRight
        }
    }
}

// CGPoint.distance(to:) is provided by CropOverlayView.swift
