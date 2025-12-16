// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
@preconcurrency import AppKit
import Carbon.HIToolbox

/// Clean fullscreen video player view
struct FullscreenPlayerView: View {
    let item: VideoItem
    let onClose: () -> Void
    
    @StateObject private var controller: FullscreenPlayerController
    @State private var isHoveringControls = false
    
    init(item: VideoItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        self._controller = StateObject(wrappedValue: FullscreenPlayerController(item: item))
    }
    
    private var aspectRatio: CGFloat {
        if let ratio = item.videoDisplayAspectRatio, ratio.isFinite, ratio > 0 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()
                
                // Video content
                videoContent
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if controller.showControls || isHoveringControls {
                    // Speed indicator (matches trim player)
                    VStack {
                        HStack {
                            PlaybackSpeedIndicator(
                                speed: controller.currentPlaybackSpeed,
                                isReversing: controller.isReverseSimulating
                            )
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(16)
                    .allowsHitTesting(false)

                    // Overlay controls
                    controlsOverlay
                        .transition(.opacity)
                }
                
                // Loading indicator
                if controller.isPreparing {
                    loadingOverlay
                }
                
                // Error message
                if let error = controller.errorMessage {
                    errorOverlay(message: error)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    controller.mouseMoved(x: location.x, viewWidth: geometry.size.width)
                case .ended:
                    break
                }
            }
        }
        .background(
            FullscreenKeyboardHandler(
                controller: controller,
                onClose: onClose
            )
        )
        .onAppear {
            controller.prepare()
        }
        .onDisappear {
            controller.cleanup()
        }

        .gesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    onClose()
                }
        )
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { _ in
                    controller.togglePlayback()
                }
        )
        .cursor(controller.isMouseIdle ? .hidden : .arrow)
    }
    
    // MARK: - Video Content
    
    @ViewBuilder
    private var videoContent: some View {
        if let player = controller.player {
            FullscreenAVPlayerView(player: player)
        } else if controller.useVLC, let vlcPlayer = controller.vlcPlayer {
            FullscreenVLCView(player: vlcPlayer)
        } else {
            Color.black
        }
    }
    
    // MARK: - Controls Overlay
    
    private var controlsOverlay: some View {
        VStack {
            // Top bar with title and close button
            topBar
            
            Spacer()
            
            // Bottom bar with timeline and playback controls
            bottomBar
        }
        .padding()
        .onHover { hovering in
            isHoveringControls = hovering
            controller.setControlsHovering(hovering)
        }
    }
    
    private var topBar: some View {
        HStack {
            // File name
            Text(item.name)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
    }
    
    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Timeline slider
            timelineSlider
            
            // Playback controls
            HStack(spacing: 24) {
                // Time display
                Text(formatTime(controller.currentTime))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 70, alignment: .leading)
                
                Spacer()
                
                // Skip backward
                Button(action: { controller.skipBackward() }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                
                // Play/Pause
                Button(action: { controller.togglePlayback() }) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                
                // Skip forward
                Button(action: { controller.skipForward() }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Speed indicator
                if controller.currentPlaybackSpeed != 1.0 || controller.isReverseSimulating {
                    Text("\(String(format: "%.1fx", controller.currentPlaybackSpeed))")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 50, alignment: .trailing)
                } else {
                    Spacer()
                        .frame(width: 50)
                }
                
                // Duration display
                Text(formatTime(controller.duration))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 70, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 6)
        )
    }
    
    private var timelineSlider: some View {
        GeometryReader { geo in
            let progress = controller.duration > 0 ? controller.currentTime / controller.duration : 0
            
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)
                
                // Progress
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: geo.size.width * CGFloat(progress), height: 4)
                
                // Scrubber handle
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * CGFloat(progress) - 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let targetTime = Double(fraction) * controller.duration
                        controller.seek(to: targetTime)
                    }
            )
        }
        .frame(height: 14)
    }
    
    // MARK: - Loading & Error Overlays
    
    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Loading...")
                .font(.headline)
                .foregroundColor(.white)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
        )
    }
    
    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.yellow)
            
            Text("Playback Error")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            
            Button("Close") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.8))
        )
    }
    
    // MARK: - Helpers
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - Cursor Modifier

private struct CursorVisibilityModifier: ViewModifier {
    let cursor: NSCursor

    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isPushed {
                        cursor.push()
                        isPushed = true
                    }
                case .ended:
                    if isPushed {
                        NSCursor.pop()
                        isPushed = false
                    }
                }
            }
            .onDisappear {
                if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorVisibilityModifier(cursor: cursor))
    }
}

extension NSCursor {
    static var hidden: NSCursor {
        NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
    }
}

// MARK: - AVPlayer View

private struct FullscreenAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.allowsVideoFrameAnalysis = false
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - VLC View

private struct FullscreenVLCView: NSViewRepresentable {
    let player: VLCPlayer
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.mediaPlayer.drawable = view
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }
}

// MARK: - Keyboard Handler

private struct FullscreenKeyboardHandler: NSViewRepresentable {
    let controller: FullscreenPlayerController
    let onClose: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onClose: onClose)
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        context.coordinator.install()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.onClose = onClose
    }
    
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }
    
    final class Coordinator {
        static func consumesKey(characters: String, modifiersRaw: UInt, keyCode: UInt16) -> Bool {
            let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)

            if characters == " " { return true }

            let lower = characters.lowercased()
            if lower == "j" || lower == "k" || lower == "l" { return true }

            switch Int(keyCode) {
            case 53: // escape
                return true
            case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                return true
            default:
                break
            }

            // Don’t consume arbitrary modified keys
            if !modifiers.intersection([.command, .control]).isEmpty {
                return false
            }

            return false
        }

        var controller: FullscreenPlayerController
        var onClose: () -> Void
        private var monitor: Any?
        
        init(controller: FullscreenPlayerController, onClose: @escaping () -> Void) {
            self.controller = controller
            self.onClose = onClose
        }
        
        func install() {
            guard monitor == nil else { return }
            
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
                guard let self else { return event }
                guard let characters = event.charactersIgnoringModifiers else { return event }

                let keyCode = event.keyCode
                let modifiersRaw = event.modifierFlags.rawValue

                // Escape to close
                if keyCode == 53 {
                    self.onClose()
                    return nil
                }

                if Coordinator.consumesKey(characters: characters, modifiersRaw: modifiersRaw, keyCode: keyCode) {
                    let controller = self.controller
                    MainActor.assumeIsolated {
                        _ = controller.handleKeyCommand(key: characters, modifiersRaw: modifiersRaw, keyCode: keyCode)
                    }
                    return nil
                }

                return event
            }
        }
        
        func teardown() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
