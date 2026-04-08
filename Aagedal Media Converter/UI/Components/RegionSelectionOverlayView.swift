// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct RegionSelectionOverlayView: View {
    let screenSize: CGSize
    let displayScaleFactor: CGFloat
    let initialRegion: CGRect?
    let onConfirmed: (CGRect?) -> Void

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
                // Dimmed overlay with cutout
                dimOverlay(in: geometry.size)

                // Selection rectangle with handles
                if let rect = selectionRect {
                    selectionRectangleView(rect: rect)
                }

                // Crosshair cursor when in drawing phase and no rect yet
                if phase == .drawing, selectionRect == nil {
                    crosshairOverlay
                }

                // Floating toolbar
                if let rect = selectionRect, phase == .refining {
                    toolbar(for: rect)
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
        .background(KeyEventHandlingView(onEscape: { cancel() }, onReturn: { confirm() }))
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
        // Crosshair cursor lines covering the full screen
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
            // Transparent fill for hit testing
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // White border
            Rectangle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Rule of thirds grid
            if phase == .refining {
                ruleOfThirdsGrid(rect: rect)
                resizeHandles(rect: rect)
            }

            // Dimension label
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
        // Ensure even for display
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

    private func toolbar(for rect: CGRect) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 16) {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)

                Button(action: { resetSelection() }) {
                    Label("Redraw", systemImage: "arrow.counterclockwise")
                }

                Button(action: confirm) {
                    Label("Confirm", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
            .padding(.bottom, 60)
        }
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
                    // Clicked outside the selection — start a new drawing
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
            // Clamp to screen bounds
            newX = max(0, min(newX, size.width - startRect.width))
            newY = max(0, min(newY, size.height - startRect.height))
            selectionRect = CGRect(x: newX, y: newY, width: startRect.width, height: startRect.height)

        case .resizeTopLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            let newX = startRect.minX + dx
            let newY = startRect.minY + dy
            let newW = startRect.width - dx
            let newH = startRect.height - dy
            applyResize(newX: newX, newY: newY, newW: newW, newH: newH, in: size)

        case .resizeTopRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            let newY = startRect.minY + dy
            let newW = startRect.width + dx
            let newH = startRect.height - dy
            applyResize(newX: startRect.minX, newY: newY, newW: newW, newH: newH, in: size)

        case .resizeBottomLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            let newX = startRect.minX + dx
            let newW = startRect.width - dx
            let newH = startRect.height + dy
            applyResize(newX: newX, newY: startRect.minY, newW: newW, newH: newH, in: size)

        case .resizeBottomRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let dy = value.translation.height
            let newW = startRect.width + dx
            let newH = startRect.height + dy
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: newW, newH: newH, in: size)

        case .resizeTop:
            guard let startRect = dragStartRect else { return }
            let dy = value.translation.height
            let newY = startRect.minY + dy
            let newH = startRect.height - dy
            applyResize(newX: startRect.minX, newY: newY, newW: startRect.width, newH: newH, in: size)

        case .resizeBottom:
            guard let startRect = dragStartRect else { return }
            let dy = value.translation.height
            let newH = startRect.height + dy
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: startRect.width, newH: newH, in: size)

        case .resizeLeft:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let newX = startRect.minX + dx
            let newW = startRect.width - dx
            applyResize(newX: newX, newY: startRect.minY, newW: newW, newH: startRect.height, in: size)

        case .resizeRight:
            guard let startRect = dragStartRect else { return }
            let dx = value.translation.width
            let newW = startRect.width + dx
            applyResize(newX: startRect.minX, newY: startRect.minY, newW: newW, newH: startRect.height, in: size)

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
            // Enforce minimum size
            if let rect = selectionRect, rect.width >= minimumSize, rect.height >= minimumSize {
                phase = .refining
            } else if let rect = selectionRect, (rect.width < minimumSize || rect.height < minimumSize) {
                // Too small — reset
                selectionRect = nil
                phase = .drawing
            }
        }

        dragMode = .none
        dragStartPoint = nil
        dragStartRect = nil
    }

    private func determineDragMode(location: CGPoint, rect: CGRect) -> DragMode {
        // Check corners first
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

        // Check edges
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

        // Inside rectangle
        if rect.contains(location) {
            return .move
        }

        return .none
    }

    // MARK: - Actions

    private func confirm() {
        guard let rect = selectionRect, rect.width >= minimumSize, rect.height >= minimumSize else {
            cancel()
            return
        }
        onConfirmed(rect)
    }

    private func cancel() {
        onConfirmed(nil)
    }

    private func resetSelection() {
        selectionRect = nil
        phase = .drawing
    }
}

// MARK: - Key Event Handling

private struct KeyEventHandlingView: NSViewRepresentable {
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> KeyEventNSView {
        let view = KeyEventNSView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: KeyEventNSView, context: Context) {
        nsView.onEscape = onEscape
        nsView.onReturn = onReturn
    }

    class KeyEventNSView: NSView {
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, eventMonitor == nil {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if event.keyCode == 53 { // Escape
                        self?.onEscape?()
                        return nil
                    }
                    if event.keyCode == 36 { // Return
                        self?.onReturn?()
                        return nil
                    }
                    return event
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil, let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }
}
