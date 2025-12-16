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

    @StateObject private var controller: PreviewPlayerController
    @State private var itemState: VideoItem

    @State private var showOverlay = true
    @State private var isMouseIdle = false
    @State private var isHoveringControls = false
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var lastMouseLocation: CGPoint?

    private let rightEdgeHideThreshold: CGFloat = 50

    init(item: VideoItem, onClose: @escaping () -> Void) {
        self.item = item
        self.onClose = onClose
        self._itemState = State(initialValue: item)
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item))
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

                if showOverlay || isHoveringControls {
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
                if controller.isPreparing || controller.isGeneratingFallbackPreview || controller.isLoadingChunk || controller.isGeneratingFallbackStill {
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
                     handleMouseHover(location: location, in: geometry.size)
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
            scheduleOverlayHide()

            Task {
                if itemState.metadata == nil {
                    if let metadata = await VideoFileUtils.fetchMetadata(for: itemState.url) {
                        await MainActor.run {
                            itemState.metadata = metadata
                        }
                    }
                }

                await MainActor.run {
                    controller.updateVideoItem(itemState)
                    controller.preparePreview(startTime: itemState.effectiveTrimStart)
                }
            }
        }
        .onDisappear {
            overlayHideTask?.cancel()
            overlayHideTask = nil

            Task { @MainActor in
                controller.teardown()
            }
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
        .cursor(isMouseIdle ? .hidden : .arrow)
    }
    
    // MARK: - Video Content
    
    @ViewBuilder
    private var videoContent: some View {
        if let still = controller.fallbackStillImage {
            Image(nsImage: still)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let player = controller.player {
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
            if hovering {
                showOverlay = true
                isMouseIdle = false
                overlayHideTask?.cancel()
            } else {
                scheduleOverlayHide()
            }
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

            if isLowQualityPreview {
                Text("Low quality preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                    )
            }
            
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
                let currentTime = controller.currentPlaybackTime
                let duration = max(itemState.durationSeconds, 0)

                // Time display
                Text(formatTime(currentTime))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: 70, alignment: .leading)

                Spacer()

                // Skip backward
                Button(action: { controller.seek(by: -10) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                // Play/Pause
                Button(action: { controller.togglePlayback() }) {
                    Image(systemName: isPlaybackActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                // Skip forward
                Button(action: { controller.seek(by: 10) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                if controller.audioTrackOptions.count > 1 {
                    audioTrackSelector
                }

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
                Text(formatTime(duration))
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
            let duration = max(itemState.durationSeconds, 0)
            let progress = duration > 0 ? controller.currentPlaybackTime / duration : 0
            
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.28))
                    .frame(height: 4)

                // Chunk availability overlay (orange = not yet rendered)
                if controller.fallbackPreviewRange != nil, duration > 0 {
                    let chunkDuration = controller.chunkDuration
                    let totalChunks = Int(ceil(duration / chunkDuration))

                    ForEach(0..<totalChunks, id: \.self) { chunkIndex in
                        if !controller.loadedChunks.contains(chunkIndex) {
                            let chunkStart = Double(chunkIndex) * chunkDuration
                            let chunkEnd = min(Double(chunkIndex + 1) * chunkDuration, duration)

                            let startX = CGFloat(chunkStart / duration) * geo.size.width
                            let endX = CGFloat(chunkEnd / duration) * geo.size.width
                            let width = max(0, endX - startX)

                            Rectangle()
                                .fill(Color.orange.opacity(0.35))
                                .frame(width: width, height: 4)
                                .offset(x: startX)
                        }
                    }
                }

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
                         let targetTime = Double(fraction) * duration
                         controller.seekTo(targetTime)
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

    private var isPlaybackActive: Bool {
        if controller.isReverseSimulating { return true }
        if controller.useVLC { return controller.vlcPlayer?.isPlaying ?? false }
        return (controller.player?.rate ?? 0) != 0
    }

    private var isLowQualityPreview: Bool {
        controller.fallbackPreviewRange != nil
            || controller.isGeneratingFallbackPreview
            || controller.isGeneratingFallbackStill
            || controller.isLoadingChunk
    }

    private var audioTrackSelector: some View {
        Menu {
            if controller.audioTrackOptions.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(controller.audioTrackOptions) { option in
                    Button {
                        controller.selectAudioTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            if let subtitle = option.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if option.position == controller.selectedAudioTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(option.position == controller.selectedAudioTrackOrderIndex)
                }
            }
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .menuStyle(.borderlessButton)
        .help(controller.audioTrackOptions.isEmpty ? "No alternate audio tracks" : "Select audio track")
    }

    private func handleKeyCommand(_ key: String, _ modifiersRaw: UInt, _ keyCode: UInt16) -> Bool {
        _ = modifiersRaw

        if key == " " {
            controller.togglePlayback()
            return true
        }

        switch key.lowercased() {
        case "j":
            controller.startReverseSimulation()
            return true
        case "k":
            controller.togglePlayback()
            return true
        case "l":
            controller.fastForward()
            return true
        default:
            break
        }

        switch Int(keyCode) {
        case kVK_LeftArrow:
            controller.seekByFrames(-1)
            return true
        case kVK_RightArrow:
            controller.seekByFrames(1)
            return true
        case kVK_UpArrow:
            controller.seekByFrames(-10)
            return true
        case kVK_DownArrow:
            controller.seekByFrames(10)
            return true
        default:
            break
        }

        return false
    }

    private func scheduleOverlayHide() {
        overlayHideTask?.cancel()

        guard !isHoveringControls else { return }

        overlayHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !isHoveringControls else { return }

            withAnimation(.easeOut(duration: 0.25)) {
                showOverlay = false
                isMouseIdle = true
                isHoveringControls = false
            }
        }
    }

    private func forceHideOverlay() {
        overlayHideTask?.cancel()
        overlayHideTask = nil

        withAnimation(.easeOut(duration: 0.2)) {
            showOverlay = false
            isMouseIdle = true
            isHoveringControls = false
        }
    }

    private func handleMouseHover(location: CGPoint, in size: CGSize) {
        let epsilon: CGFloat = 0.5
        if let last = lastMouseLocation {
            let dx = abs(last.x - location.x)
            let dy = abs(last.y - location.y)
            if dx < epsilon, dy < epsilon {
                return
            }
        }
        lastMouseLocation = location

        if location.x >= size.width - rightEdgeHideThreshold {
            forceHideOverlay()
            return
        }

        showOverlay = true
        isMouseIdle = false
        scheduleOverlayHide()
    }

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
    let controller: PreviewPlayerController
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
        var controller: PreviewPlayerController
        var onClose: () -> Void
        private var monitor: Any?

        init(controller: PreviewPlayerController, onClose: @escaping () -> Void) {
            self.controller = controller
            self.onClose = onClose
        }

        func install() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
                guard let self else { return event }
                guard let characters = event.charactersIgnoringModifiers else { return event }

                let keyCode = event.keyCode

                // Escape to close
                if keyCode == 53 {
                    self.onClose()
                    return nil
                }

                let lower = characters.lowercased()

                // Only consume keys we actually use
                let shouldConsume: Bool = {
                    if characters == " " { return true }
                    if lower == "j" || lower == "k" || lower == "l" { return true }
                    switch Int(keyCode) {
                    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                        return true
                    default:
                        return false
                    }
                }()

                guard shouldConsume else { return event }

                let controller = self.controller
                MainActor.assumeIsolated {
                    if characters == " " {
                        controller.togglePlayback()
                        return
                    }

                    switch lower {
                    case "j":
                        controller.startReverseSimulation()
                        return
                    case "k":
                        controller.togglePlayback()
                        return
                    case "l":
                        controller.fastForward()
                        return
                    default:
                        break
                    }

                    switch Int(keyCode) {
                    case kVK_LeftArrow:
                        controller.seekByFrames(-1)
                    case kVK_RightArrow:
                        controller.seekByFrames(1)
                    case kVK_UpArrow:
                        controller.seekByFrames(-10)
                    case kVK_DownArrow:
                        controller.seekByFrames(10)
                    default:
                        break
                    }
                }

                return nil
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
