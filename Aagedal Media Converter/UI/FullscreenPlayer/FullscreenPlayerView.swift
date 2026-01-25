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
    let onCloseWithPosition: ((Double) -> Void)?
    let onPreviousItem: (@Sendable () -> Void)?
    let onNextItem: (@Sendable () -> Void)?
    let onOverlayVisibilityChanged: ((Bool) -> Void)?
    let onTimecodeDisplayModeChanged: ((TimecodeDisplayMode) -> Void)?
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let onToggleQueueAutoAdvance: () -> Void
    let onToggleQueueLoop: () -> Void
    let onPlaybackDidFinish: () -> Void
    let autoPlayOnReady: Bool
    let startTime: Double?

    @StateObject private var controller: PreviewPlayerController
    @State private var itemState: VideoItem

    @State private var showOverlay: Bool
    @State private var isMouseIdle = false
    @State private var isHoveringControls = false
    @State private var isHoveringRightEdge = false
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var isDraggingTimeline = false
    @State private var waveformSamples: [CGFloat] = []

    // Timecode display state
    @State private var timecodeDisplayMode: TimecodeDisplayMode
    @State private var isEditingTimecode = false
    @State private var timecodeInput = ""
    @State private var timecodeJustActivated = false
    @State private var pendingTimecodeCharacter: String?
    @FocusState private var isTimecodeFocused: Bool
    @State private var queueAutoAdvanceState: Bool
    @State private var queueLoopState: Bool
    @State private var autoAdvanceTriggered = false
    @State private var autoPlayPending = false

    private let rightEdgeWidth: CGFloat = 60
    private let maxWaveformSamples = AudioVisualizer.maxSampleCount

    init(
        item: VideoItem,
        initialOverlayHidden: Bool = false,
        initialTimecodeDisplayMode: TimecodeDisplayMode = .preferred,
        startTime: Double? = nil,
        onClose: @escaping () -> Void,
        onCloseWithPosition: ((Double) -> Void)? = nil,
        onPreviousItem: (@Sendable () -> Void)? = nil,
        onNextItem: (@Sendable () -> Void)? = nil,
        onOverlayVisibilityChanged: ((Bool) -> Void)? = nil,
        onTimecodeDisplayModeChanged: ((TimecodeDisplayMode) -> Void)? = nil,
        canGoToPrevious: Bool = false,
        canGoToNext: Bool = false,
        queueAutoAdvanceEnabled: Bool = false,
        queueLoopEnabled: Bool = false,
        onToggleQueueAutoAdvance: @escaping () -> Void = {},
        onToggleQueueLoop: @escaping () -> Void = {},
        onPlaybackDidFinish: @escaping () -> Void = {},
        autoPlayOnReady: Bool = false
    ) {
        self.item = item
        self.onClose = onClose
        self.onCloseWithPosition = onCloseWithPosition
        self.onPreviousItem = onPreviousItem
        self.onNextItem = onNextItem
        self.onOverlayVisibilityChanged = onOverlayVisibilityChanged
        self.onTimecodeDisplayModeChanged = onTimecodeDisplayModeChanged
        self.canGoToPrevious = canGoToPrevious
        self.canGoToNext = canGoToNext
        self.onToggleQueueAutoAdvance = onToggleQueueAutoAdvance
        self.onToggleQueueLoop = onToggleQueueLoop
        self.onPlaybackDidFinish = onPlaybackDidFinish
        self.startTime = startTime
        self._itemState = State(initialValue: item)
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item))
        self._showOverlay = State(initialValue: !initialOverlayHidden)
        self._isMouseIdle = State(initialValue: initialOverlayHidden)
        self._timecodeDisplayMode = State(initialValue: initialTimecodeDisplayMode)
        self._queueAutoAdvanceState = State(initialValue: queueAutoAdvanceEnabled)
        self._queueLoopState = State(initialValue: queueLoopEnabled)
        self.autoPlayOnReady = autoPlayOnReady
        self._autoPlayPending = State(initialValue: autoPlayOnReady)
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

                if showOverlay || isHoveringControls || isDraggingTimeline {
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
                if controller.isPreparing {
                    loadingOverlay
                }
                
                // Error message
                if let error = controller.errorMessage {
                    errorOverlay(message: error)
                }

                // Right edge cursor-hide zone - positioned at trailing edge only
                RightEdgeCursorHideZone { hovering in
                    isHoveringRightEdge = hovering
                    if hovering {
                        // Hide overlay when entering right edge
                        if !isHoveringControls, !isDraggingTimeline {
                            overlayHideTask?.cancel()
                            withAnimation(.easeOut(duration: 0.2)) {
                                showOverlay = false
                            }
                            onOverlayVisibilityChanged?(true)
                        }
                    } else {
                        // Show overlay when leaving right edge
                        showOverlay = true
                        scheduleOverlayHide()
                    }
                }
                .frame(width: rightEdgeWidth, height: geometry.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    handleMouseHover()
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
                captureScreenshot: { @Sendable in
                    Task { @MainActor in
                        captureScreenshot()
                    }
                },
                onPreviousItem: onPreviousItem,
                onNextItem: onNextItem,
                canGoToPrevious: canGoToPrevious,
                canGoToNext: canGoToNext,
                isEditingTimecode: isEditingTimecode
            )
        )
        .onReceive(controller.playbackTimePublisher) { time in
            handleAutoAdvanceProximity(time)
        }
        .onReceive(controller.$audioLevels) { levels in
            guard !itemState.hasVideoStream else { return }
            guard let levels else { return }
            appendWaveformSample(from: levels)
        }
        .onChange(of: controller.isReady) { isReady, _ in
            guard isReady, autoPlayPending else { return }
            if !isPlaybackActive {
                controller.togglePlayback()
            }
            autoPlayPending = false
        }
        .onAppear {
            updateAudioMeterState(for: itemState.hasVideoStream)
            autoAdvanceTriggered = false
            controller.playbackDidFinish = onPlaybackDidFinish
            // Schedule overlay hide if it's currently visible
            if showOverlay {
                scheduleOverlayHide()
            }

            // Capture startTime immediately on appear to avoid any SwiftUI state issues
            let capturedStartTime = startTime

            // Prepare preview IMMEDIATELY - don't wait for metadata
            controller.updateVideoItem(itemState)
            let initialTime = capturedStartTime ?? itemState.effectiveTrimStart
            NSLog("FullscreenPlayerView: startTime=\(String(describing: capturedStartTime)), effectiveTrimStart=\(itemState.effectiveTrimStart), using initialTime=\(initialTime)")
            controller.preparePreview(startTime: initialTime)

            // Fetch metadata in background (non-blocking) - only if needed
            if itemState.metadata == nil {
                Task {
                    if let metadata = await VideoFileUtils.fetchMetadata(for: itemState.url) {
                        await MainActor.run {
                            itemState.metadata = metadata
                            // Update controller with new metadata if still relevant
                            controller.updateVideoItem(itemState)
                        }
                    }
                }
            }
        }
        .onChange(of: itemState.hasVideoStream) { _, hasVideo in
            updateAudioMeterState(for: hasVideo)
        }
        .onDisappear {
            controller.playbackDidFinish = nil
            overlayHideTask?.cancel()
            overlayHideTask = nil

            // Report final position before teardown
            let finalPosition = controller.currentPlaybackTime
            onCloseWithPosition?(finalPosition)

            Task { @MainActor in
                controller.teardown()
            }
        }
    }
    
    private func handleAutoAdvanceProximity(_ currentTime: Double) {
        guard queueAutoAdvanceState else {
            autoAdvanceTriggered = false
            return
        }

        guard isPlaybackActive else { return }
        let duration = observedDuration
        guard duration > 0 else { return }

        let threshold = max(0, duration - 0.03)
        if currentTime >= threshold && !autoAdvanceTriggered {
            autoAdvanceTriggered = true
            onPlaybackDidFinish()
        } else if currentTime < threshold {
            autoAdvanceTriggered = false
        }
    }

    private var observedDuration: Double {
        // Prefer item's metadata duration, but fall back to player duration if not available yet
        if itemState.durationSeconds > 0 {
            return itemState.durationSeconds
        }
        // Try MPV player duration
        if let mpvDuration = controller.mpvPlayer?.duration, mpvDuration > 0 {
            return mpvDuration
        }
        // Try AVPlayer duration
        if let avDuration = controller.player?.currentItem?.duration.seconds,
           avDuration.isFinite && avDuration > 0 {
            return avDuration
        }
        return 0
    }

    private func appendWaveformSample(from levels: UniversalAudioMeterService.AudioLevels) {
        let dB = max(levels.leftChannel, levels.rightChannel, levels.peak)
        let normalized = AudioVisualizer.normalizedLevel(from: dB)
        waveformSamples.append(normalized)
        if waveformSamples.count > maxWaveformSamples {
            waveformSamples.removeFirst(waveformSamples.count - maxWaveformSamples)
        }
    }

    private func updateAudioMeterState(for hasVideoStream: Bool) {
        let shouldEnable = !hasVideoStream
        if controller.isAudioMeterEnabled != shouldEnable {
            controller.isAudioMeterEnabled = shouldEnable
        }
        if hasVideoStream && !waveformSamples.isEmpty {
            waveformSamples = []
        }
    }

    // MARK: - Video Content

    @ViewBuilder
    private var videoContent: some View {
        ZStack {
            if !itemState.hasVideoStream {
                AudioVisualizerView(samples: waveformSamples)
            }

            if let player = controller.player {
                FullscreenAVPlayerView(player: player)
                    .opacity(itemState.hasVideoStream ? 1 : 0.001)
            } else if controller.useMPV, let mpvPlayer = controller.mpvPlayer {
                FullscreenMPVView(player: mpvPlayer)
                    .opacity(itemState.hasVideoStream ? 1 : 0.001)
            } else if itemState.hasVideoStream {
                Color.black
            } else {
                Color.clear
            }
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
        .frame(maxWidth: 1200)
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

            queueToggleRow

            // Playback controls
            HStack(spacing: 24) {
                let currentTime = controller.currentPlaybackTime
                let duration = observedDuration

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

                if !controller.subtitleTrackOptions.isEmpty {
                    subtitleTrackSelector
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

                // End point timecode display
                Text(TimecodeFormatter.formatTimeForDisplayWithMode(
                    seconds: duration,
                    item: itemState,
                    mode: timecodeDisplayMode
                ))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(minWidth: 90, alignment: .trailing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: 1200)
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
            // Use observedDuration which includes MPV fallback
            let duration = observedDuration
            let progress = duration > 0 ? controller.currentPlaybackTime / duration : 0
            
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.28))
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
                        isDraggingTimeline = true
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let targetTime = Double(fraction) * duration
                        controller.seekTo(targetTime)
                    }
                    .onEnded { _ in
                        isDraggingTimeline = false
                    }
            )
        }
        .frame(height: 14)
    }

    private var queueToggleRow: some View {
        HStack(spacing: 12) {
            queueToggleButton(
                icon: "arrow.right.circle",
                title: "Auto Next",
                isOn: queueAutoAdvanceState,
                isDisabled: false,
                action: toggleQueueAutoAdvance
            )

            queueToggleButton(
                icon: "repeat",
                title: "Loop Queue",
                isOn: queueLoopState,
                isDisabled: !queueAutoAdvanceState,
                action: toggleQueueLoop
            )

            Spacer()
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(maxWidth: 1200)
    }

    private func queueToggleButton(icon: String, title: String, isOn: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(isOn ? 0.25 : 0.08))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(isOn ? 0.9 : 0.55), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }

    private func toggleQueueAutoAdvance() {
        queueAutoAdvanceState.toggle()
        if !queueAutoAdvanceState {
            autoAdvanceTriggered = false
            autoPlayPending = false
        }
        onToggleQueueAutoAdvance()
    }

    private func toggleQueueLoop() {
        queueLoopState.toggle()
        onToggleQueueLoop()
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
        if controller.useMPV, let mpv = controller.mpvPlayer {
            return mpv.isPlaying || mpv.reachedEnd
        }
        return (controller.player?.rate ?? 0) != 0
    }

    private var isLowQualityPreview: Bool {
        false  // All playback now uses native AVPlayer or MPV
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

    private var subtitleTrackSelector: some View {
        Menu {
            Button {
                controller.selectSubtitleTrack(at: -1)
            } label: {
                HStack {
                    Text("Off")
                    Spacer()
                    if controller.selectedSubtitleTrackOrderIndex < 0 {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !controller.subtitleTrackOptions.isEmpty {
                Divider()

                ForEach(controller.subtitleTrackOptions) { option in
                    Button {
                        controller.selectSubtitleTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.position == controller.selectedSubtitleTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
        }
        .menuStyle(.borderlessButton)
        .help("Select subtitle track")
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

        guard !isHoveringControls, !isDraggingTimeline else { return }

        overlayHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !isHoveringControls, !isDraggingTimeline else { return }

            // Set cursor state immediately (not animatable)
            isMouseIdle = true

            withAnimation(.easeOut(duration: 0.25)) {
                showOverlay = false
                isHoveringControls = false
            }
            onOverlayVisibilityChanged?(true)
        }
    }

    private func forceHideOverlay() {
        // Don't hide while hovering controls or dragging the timeline
        guard !isHoveringControls, !isDraggingTimeline else { return }

        overlayHideTask?.cancel()
        overlayHideTask = nil

        isMouseIdle = true

        withAnimation(.easeOut(duration: 0.2)) {
            showOverlay = false
        }
        onOverlayVisibilityChanged?(true)
    }

    private func captureScreenshot() {
        Task {
            let defaults = UserDefaults.standard
            let directoryPath = defaults.string(forKey: AppConstants.screenshotDirectoryKey) ?? AppConstants.defaultScreenshotDirectory.path
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

            do {
                let savedURL = try await controller.captureScreenshot(to: directoryURL)
                await MainActor.run {
                    controller.lastScreenshotURL = savedURL
                    controller.showScreenshotConfirmationOverlay()
                }
            } catch {
                NSLog("Screenshot capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleMouseHover() {
        // Don't show overlay if in right edge zone
        guard !isHoveringRightEdge else { return }

        if !showOverlay {
            onOverlayVisibilityChanged?(false)
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
            
            let inputTotalFrames = hours * 3600 * fps + minutes * 60 * fps + seconds * fps + frames
            let startTotalFrames = startHours * 3600 * fps + startMinutes * 60 * fps + startSeconds * fps + startFrames
            
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
        onTimecodeDisplayModeChanged?(timecodeDisplayMode)
    }
}

// MARK: - Cursor Modifier

private struct CursorVisibilityModifier: ViewModifier {
    let isHidden: Bool

    @State private var isHovering = false
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isHovering {
                        isHovering = true
                        pushCursor()
                    }
                case .ended:
                    if isHovering {
                        isHovering = false
                        popCursor()
                    }
                }
            }
            .onChange(of: isHidden) { _, _ in
                // Cursor visibility changed while hovering - update the cursor
                if isHovering {
                    popCursor()
                    pushCursor()
                }
            }
            .onDisappear {
                popCursor()
            }
    }

    private func pushCursor() {
        let cursor = isHidden ? NSCursor.hidden : NSCursor.arrow
        cursor.push()
        hasPushedCursor = true
    }

    private func popCursor() {
        if hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
    }
}

extension View {
    func hideCursor(_ hide: Bool) -> some View {
        modifier(CursorVisibilityModifier(isHidden: hide))
    }
}

extension NSCursor {
    static var hidden: NSCursor {
        // Create a transparent cursor image
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }
}

// MARK: - Right Edge Cursor Hide Zone

private struct RightEdgeCursorHideZone: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> RightEdgeCursorHideNSView {
        let view = RightEdgeCursorHideNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: RightEdgeCursorHideNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

private class RightEdgeCursorHideNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    // Allow clicks to pass through while keeping tracking areas active
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        NSCursor.hide()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        NSCursor.unhide()
        onHoverChanged?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateTrackingAreas()
        }
    }

    override func removeFromSuperview() {
        if isHovering {
            NSCursor.unhide()
            isHovering = false
        }
        super.removeFromSuperview()
    }

    deinit {
        if isHovering {
            NSCursor.unhide()
        }
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

// MARK: - Keyboard Handler

private struct FullscreenKeyboardHandler: NSViewRepresentable {
    let controller: PreviewPlayerController
    let onClose: @Sendable () -> Void
    let onToggleTimecodeMode: @Sendable () -> Void
    let onTimecodeInput: @Sendable (String) -> Void
    let captureScreenshot: @Sendable () -> Void
    let onPreviousItem: (@Sendable () -> Void)?
    let onNextItem: (@Sendable () -> Void)?
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let isEditingTimecode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onClose: onClose,
            onToggleTimecodeMode: onToggleTimecodeMode,
            onTimecodeInput: onTimecodeInput,
            captureScreenshot: captureScreenshot,
            onPreviousItem: onPreviousItem,
            onNextItem: onNextItem,
            canGoToPrevious: canGoToPrevious,
            canGoToNext: canGoToNext,
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
        context.coordinator.captureScreenshot = captureScreenshot
        context.coordinator.onPreviousItem = onPreviousItem
        context.coordinator.onNextItem = onNextItem
        context.coordinator.canGoToPrevious = canGoToPrevious
        context.coordinator.canGoToNext = canGoToNext
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
        var captureScreenshot: @Sendable () -> Void
        var onPreviousItem: (@Sendable () -> Void)?
        var onNextItem: (@Sendable () -> Void)?
        var canGoToPrevious: Bool
        var canGoToNext: Bool
        var isEditingTimecode: Bool
        private var monitor: Any?

        init(
            controller: PreviewPlayerController,
            onClose: @Sendable @escaping () -> Void,
            onToggleTimecodeMode: @Sendable @escaping () -> Void,
            onTimecodeInput: @Sendable @escaping (String) -> Void,
            captureScreenshot: @Sendable @escaping () -> Void,
            onPreviousItem: (@Sendable () -> Void)?,
            onNextItem: (@Sendable () -> Void)?,
            canGoToPrevious: Bool,
            canGoToNext: Bool,
            isEditingTimecode: Bool
        ) {
            self.controller = controller
            self.onClose = onClose
            self.onToggleTimecodeMode = onToggleTimecodeMode
            self.onTimecodeInput = onTimecodeInput
            self.captureScreenshot = captureScreenshot
            self.onPreviousItem = onPreviousItem
            self.onNextItem = onNextItem
            self.canGoToPrevious = canGoToPrevious
            self.canGoToNext = canGoToNext
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

                // CMD+B: Go to previous item in queue
                if hasCommand && !hasShift && !hasOption && !hasControl && lower == "b" {
                    if self.canGoToPrevious, let onPrevious = self.onPreviousItem {
                        DispatchQueue.main.async {
                            onPrevious()
                        }
                    }
                    // Always consume the event to prevent propagation to other handlers
                    return nil
                }

                // CMD+N: Go to next item in queue
                if hasCommand && !hasShift && !hasOption && !hasControl && lower == "n" {
                    if self.canGoToNext, let onNext = self.onNextItem {
                        DispatchQueue.main.async {
                            onNext()
                        }
                    }
                    // Always consume the event to prevent propagation to other handlers
                    return nil
                }

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

                // CMD+S: Capture screenshot
                if hasCommand && lower == "s" {
                    DispatchQueue.main.async { [weak self] in
                        self?.captureScreenshot()
                    }
                    return nil
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
