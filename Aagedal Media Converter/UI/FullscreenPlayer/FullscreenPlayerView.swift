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
    
    // Timecode display state
    @State private var timecodeDisplayMode: TimecodeDisplayMode = .relative
    @State private var isEditingTimecode = false
    @State private var timecodeInput = ""
    @State private var timecodeJustActivated = false
    @State private var pendingTimecodeCharacter: String?
    @FocusState private var isTimecodeFocused: Bool

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
                // Background - tap gestures applied here
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
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
                
                // Video content - tap gestures also here
                videoContent
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
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

                    // Overlay controls - no tap gestures, blocks clicks from reaching background
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
                onClose: { @Sendable in
                    Task { @MainActor in
                        onClose()
                    }
                },
                onToggleTimecodeMode: { @Sendable in
                    Task { @MainActor in
                        toggleTimecodeMode()
                    }
                },
                onTimecodeInput: { @Sendable char in
                    Task { @MainActor in
                        startTimecodeEditWithChar(char)
                    }
                },
                isEditingTimecode: isEditingTimecode
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

                // Timecode display with mode prefix
                timecodeDisplay(for: currentTime)

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

                // Duration display (always relative)
                Text(TimecodeFormatter.formatTimeForDisplayWithMode(
                    seconds: duration,
                    item: itemState,
                    mode: .relative,
                    isDuration: true
                ))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(minWidth: 90, alignment: .trailing)
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
    
    @ViewBuilder
    private func timecodeDisplay(for currentTime: Double) -> some View {
        if isEditingTimecode {
            // Editable timecode input
            HStack(spacing: 6) {
                timecodeModePrefix
                
                TextField("00:00:00:00", text: $timecodeInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 100)
                    .focused($isTimecodeFocused)
                    .onSubmit { seekToTimecode() }
                    .onExitCommand { cancelTimecodeEdit() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.15))
            )
            .frame(minWidth: 160, alignment: .leading)
        } else {
            // Display timecode with mode prefix
            HStack(spacing: 6) {
                timecodeModePrefix
                
                Text(TimecodeFormatter.formatTimeForDisplayWithMode(
                    seconds: currentTime,
                    item: itemState,
                    mode: timecodeDisplayMode
                ))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            .frame(minWidth: 160, alignment: .leading)
            .onTapGesture(count: 2) { startTimecodeEdit() }
            .help("Double-click to enter timecode. Click mode label or press T to toggle mode.")
        }
    }
    
    private var timecodeModePrefix: some View {
        Text(timecodeDisplayMode.prefix)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.1))
            )
            .contentShape(Rectangle())
            .onTapGesture { toggleTimecodeMode() }
            .help("Click or press T to cycle: REL TC → SRC TC → FRM")
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
    
    // MARK: - Timecode Editing
    
    private func startTimecodeEdit() {
        pendingTimecodeCharacter = nil
        timecodeJustActivated = false
        timecodeInput = TimecodeFormatter.formatTimeForDisplayWithMode(
            seconds: controller.currentPlaybackTime,
            item: itemState,
            mode: timecodeDisplayMode
        )
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTimecodeFocused = true
        }
    }
    
    private func startTimecodeEditWithChar(_ char: String) {
        // Use the same focus-then-append approach as the trim view.
        // This avoids the first character getting overwritten due to TextField auto-selection.
        timecodeInput = ""
        pendingTimecodeCharacter = char
        timecodeJustActivated = true

        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }

        // Focus first, then append initial character after focus is established.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTimecodeFocused = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let initialChar = pendingTimecodeCharacter {
                    timecodeInput = initialChar
                    pendingTimecodeCharacter = nil
                }
                timecodeJustActivated = false
            }
        }
    }
    
    private func cancelTimecodeEdit() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = false
        }
        isTimecodeFocused = false
        timecodeInput = ""
        pendingTimecodeCharacter = nil
        timecodeJustActivated = false
    }
    
    private func seekToTimecode() {
        guard let seekTime = parseTimecodeToSeconds(timecodeInput) else {
            cancelTimecodeEdit()
            return
        }
        
        // Clamp to valid range
        let duration = max(itemState.durationSeconds, 0)
        let clampedTime = max(0, min(seekTime, duration))
        
        // Seek to position
        controller.seekTo(clampedTime)
        
        // Exit edit mode
        cancelTimecodeEdit()
    }
    
    private func parseTimecodeToSeconds(_ timecode: String) -> Double? {
        let trimmed = timecode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        let frameRate = TimecodeFormatter.effectiveFrameRate(for: itemState)
        let fps = Int(frameRate.rounded())
        
        // Frames mode:
        // - "+/-N" moves relatively by N frames
        // - "N" jumps to absolute frame N
        if timecodeDisplayMode == .frames {
            if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
                let isPositive = trimmed.hasPrefix("+")
                if let frameOffset = Int(String(trimmed.dropFirst())), frameOffset >= 0 {
                    let offsetSeconds = Double(frameOffset) / frameRate
                    return isPositive ? controller.currentPlaybackTime + offsetSeconds : controller.currentPlaybackTime - offsetSeconds
                }
            }

            if let frameNumber = Int(trimmed), frameNumber >= 0 {
                return Double(frameNumber) / frameRate
            }
        }
        
        // Check for relative seeking (+/-)
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            let isPositive = trimmed.hasPrefix("+")
            let offsetString = String(trimmed.dropFirst())
            
            guard let offsetSeconds = parseTimecodeOffset(offsetString, frameRate: frameRate, fps: fps) else {
                return nil
            }
            
            let newTime = isPositive ? controller.currentPlaybackTime + offsetSeconds : controller.currentPlaybackTime - offsetSeconds
            return newTime
        }
        
        // Parse absolute timecode
        return parseAbsoluteTimecode(trimmed, frameRate: frameRate, fps: fps)
    }
    
    private func parseTimecodeOffset(_ input: String, frameRate: Double, fps: Int) -> Double? {
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard !components.isEmpty, components.count <= 4 else { return nil }
        
        var hours = 0, minutes = 0, seconds = 0, frames = 0
        
        switch components.count {
        case 1:
            guard let value = Int(components[0]) else { return nil }
            seconds = value
        case 2:
            guard let first = Int(components[0]), let second = Int(components[1]) else { return nil }
            if first < 60 && second < 60 {
                minutes = first; seconds = second
            } else {
                seconds = first; frames = second
            }
        case 3:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        case 4:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]), let f = Int(components[3]) else { return nil }
            hours = h; minutes = m; seconds = s; frames = f
        default:
            return nil
        }
        
        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let frameSeconds = Double(frames) / frameRate
        return totalSeconds + frameSeconds
    }
    
    private func parseAbsoluteTimecode(_ input: String, frameRate: Double, fps: Int) -> Double? {
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard !components.isEmpty, components.count <= 4 else { return nil }
        
        var hours = 0, minutes = 0, seconds = 0, frames = 0
        
        switch components.count {
        case 1:
            guard let s = Int(components[0]) else { return nil }
            seconds = s
        case 2:
            guard let m = Int(components[0]), let s = Int(components[1]) else { return nil }
            minutes = m; seconds = s
        case 3:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        case 4:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]), let f = Int(components[3]) else { return nil }
            hours = h; minutes = m; seconds = s; frames = f
        default:
            return nil
        }
        
        // Validate ranges
        guard hours >= 0, hours < 24, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60, frames >= 0, frames < fps else {
            return nil
        }
        
        // Handle source timecode offset when in source mode
        if timecodeDisplayMode == .source, let startTC = TimecodeFormatter.effectiveStartTimecode(for: itemState) {
            let startComponents = startTC.split(whereSeparator: { $0 == ":" || $0 == ";" })
            guard startComponents.count == 4,
                  let startHours = Int(startComponents[0]),
                  let startMinutes = Int(startComponents[1]),
                  let startSeconds = Int(startComponents[2]),
                  let startFrames = Int(startComponents[3]) else {
                return nil
            }
            
            var inputTotalFrames = hours * 3600 * fps + minutes * 60 * fps + seconds * fps + frames
            var startTotalFrames = startHours * 3600 * fps + startMinutes * 60 * fps + startSeconds * fps + startFrames
            
            let frameOffset = inputTotalFrames - startTotalFrames
            return Double(frameOffset) / frameRate
        }
        
        // Relative mode - treat as absolute from 00:00:00:00
        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let frameSeconds = Double(frames) / frameRate
        return totalSeconds + frameSeconds
    }
    
    private func toggleTimecodeMode() {
        timecodeDisplayMode.toggle()
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
    let onClose: @Sendable () -> Void
    let onToggleTimecodeMode: @Sendable () -> Void
    let onTimecodeInput: @Sendable (String) -> Void
    let isEditingTimecode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onClose: onClose,
            onToggleTimecodeMode: onToggleTimecodeMode,
            onTimecodeInput: onTimecodeInput,
            isEditingTimecode: isEditingTimecode
        )
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
        context.coordinator.onToggleTimecodeMode = onToggleTimecodeMode
        context.coordinator.onTimecodeInput = onTimecodeInput
        context.coordinator.isEditingTimecode = isEditingTimecode
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: @unchecked Sendable {
        var controller: PreviewPlayerController
        var onClose: @Sendable () -> Void
        var onToggleTimecodeMode: @Sendable () -> Void
        var onTimecodeInput: @Sendable (String) -> Void
        var isEditingTimecode: Bool
        private var monitor: Any?

        init(
            controller: PreviewPlayerController,
            onClose: @Sendable @escaping () -> Void,
            onToggleTimecodeMode: @Sendable @escaping () -> Void,
            onTimecodeInput: @Sendable @escaping (String) -> Void,
            isEditingTimecode: Bool
        ) {
            self.controller = controller
            self.onClose = onClose
            self.onToggleTimecodeMode = onToggleTimecodeMode
            self.onTimecodeInput = onTimecodeInput
            self.isEditingTimecode = isEditingTimecode
        }

        func install() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
                guard let self else { return event }
                guard let characters = event.charactersIgnoringModifiers else { return event }

                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let hasOption = modifiers.contains(.option)
                let hasCommand = modifiers.contains(.command)
                let hasShift = modifiers.contains(.shift)
                let hasControl = modifiers.contains(.control)
                let noModifiers = !hasOption && !hasCommand && !hasShift && !hasControl

                // Escape to close
                if keyCode == 53 {
                    self.onClose()
                    return nil
                }

                let lower = characters.lowercased()
                
                // T (no modifiers): Toggle timecode mode
                if noModifiers && !self.isEditingTimecode && lower == "t" {
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleTimecodeMode()
                    }
                    return nil
                }
                
                // Number keys and timecode characters to activate timecode input (when not already editing)
                // Exclude 't' since it's used for timecode mode toggle
                if noModifiers && !self.isEditingTimecode {
                    let timecodeChars = CharacterSet(charactersIn: "0123456789+-.:;")
                    if characters.rangeOfCharacter(from: timecodeChars) != nil {
                        DispatchQueue.main.async { [weak self] in
                            self?.onTimecodeInput(characters)
                        }
                        return nil
                    }
                }

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
