// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AVKit
import Combine
import SwiftUI
import AppKit
import Carbon.HIToolbox
@preconcurrency import VLCKit

/// Simplified controller for fullscreen video playback.
/// Supports both AVPlayer (native) and VLCKit (fallback) playback modes.
@MainActor
final class FullscreenPlayerController: ObservableObject {
    
    // MARK: - Published State
    
    @Published var player: AVPlayer?
    @Published var vlcPlayer: VLCPlayer?
    @Published var useVLC = false
    @Published var isPlaying = false
    @Published var isPreparing = false
    @Published var errorMessage: String?
    
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0

    // Match PreviewPlayerController semantics
    @Published private(set) var currentPlaybackSpeed: Float = 1.0
    @Published private(set) var isReverseSimulating: Bool = false
    
    @Published var showControls = true
    @Published var isMouseIdle = false
    
    // MARK: - Private Properties
    
    private var item: VideoItem
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()

    private var controlsHideTask: Task<Void, Never>?
    private var isHoveringControls = false
    private let rightEdgeHideThreshold: CGFloat = 50

    // Reverse simulation (frame stepping)
    private var reverseSpeed: Int = 1
    private var reverseTimer: Timer?

    private enum SecurityScopeAccess {
        case none
        case direct
        case bookmark
    }

    private var securityScopeAccess: SecurityScopeAccess = .none
    
    // MARK: - Initialization
    
    init(item: VideoItem) {
        self.item = item
        self.duration = item.durationSeconds
    }
    
    
    // MARK: - Public Methods
    
    func prepare() {
        isPreparing = true
        errorMessage = nil
        
        // Start security-scoped access
        if item.url.startAccessingSecurityScopedResource() {
            securityScopeAccess = .direct
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: item.url) {
            securityScopeAccess = .bookmark
        } else {
            securityScopeAccess = .none
        }

        if securityScopeAccess == .none, !FileManager.default.isReadableFile(atPath: item.url.path) {
            isPreparing = false
            errorMessage = "No permission to read this file. Try re-importing it so the app can create a security-scoped bookmark."
            return
        }
        
        // Try native AVPlayer first
        let asset = AVURLAsset(url: item.url)
        let playerItem = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: playerItem)
        
        // Observe player item status
        statusObserver = playerItem.observe(\.status) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handlePlayerItemStatus(item.status, error: item.error)
            }
        }
        
        player = avPlayer
        setupTimeObserver()
    }
    
    // MARK: - Unified Playback Control (mirrors PreviewPlayerController)

    func togglePlayback() {
        // If reversing, K/Space should just stop reverse (stay paused)
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        if useVLC, let vlc = vlcPlayer {
            let wasPlaying = vlc.isPlaying
            vlc.rate = 1.0
            currentPlaybackSpeed = 1.0

            if wasPlaying {
                vlc.pause()
                isPlaying = false
            } else {
                vlc.play()
                isPlaying = true
            }
        } else if let player {
            currentPlaybackSpeed = 1.0
            if player.rate != 0 {
                player.pause()
                isPlaying = false
            } else {
                player.rate = 1.0
                player.play()
                isPlaying = true
            }
        }

        if isPlaying {
            scheduleControlsHide()
        } else {
            showControls = true
            isMouseIdle = false
            scheduleControlsHide()
        }
    }

    func pause() {
        stopReverseSimulation()

        if useVLC, let vlc = vlcPlayer {
            vlc.rate = 1.0
            currentPlaybackSpeed = 1.0
            vlc.pause()
        } else {
            currentPlaybackSpeed = 1.0
            player?.pause()
        }

        isPlaying = false
        showControls = true
        isMouseIdle = false
        scheduleControlsHide()
    }

    private func stepRate(forward: Bool) {
        if useVLC, let vlc = vlcPlayer {
            let current = vlc.rate
            let step: Float = 0.5
            let newRate = forward ? current + step : current - step
            vlc.rate = max(0.25, min(newRate, 4.0))
            currentPlaybackSpeed = vlc.rate
            isPlaying = vlc.isPlaying
            return
        }

        if let player {
            let current = player.rate
            let step: Float = 1.0
            let newRate = forward ? current + step : current - step
            player.rate = newRate
            currentPlaybackSpeed = player.rate
            isPlaying = player.rate != 0
        }
    }

    func startReverseSimulation() {
        // If already reversing, increase speed (max 4x)
        if isReverseSimulating {
            reverseSpeed = min(reverseSpeed + 1, 4)
            reverseTimer?.invalidate()

            let interval = (1.0 / 24.0) / Double(reverseSpeed)
            reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.seekByFrames(-1)
                }
            }

            currentPlaybackSpeed = -Float(reverseSpeed)
            return
        }

        pause()
        reverseSpeed = 1
        isReverseSimulating = true
        currentPlaybackSpeed = -1.0

        let interval = 1.0 / 24.0
        reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.seekByFrames(-1)
            }
        }
    }

    func stopReverseSimulation() {
        isReverseSimulating = false
        reverseSpeed = 1
        reverseTimer?.invalidate()
        reverseTimer = nil

        if !isReverseSimulating {
            currentPlaybackSpeed = 1.0
        }
    }

    func fastForward() {
        // If reversing, L stops reverse
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        // If paused, start playing at 1×
        if useVLC, let vlc = vlcPlayer {
            if !vlc.isPlaying {
                vlc.rate = 1.0
                currentPlaybackSpeed = 1.0
                vlc.play()
                isPlaying = true
                scheduleControlsHide()
                return
            }
        } else if let player {
            if player.rate == 0 {
                player.rate = 1.0
                currentPlaybackSpeed = 1.0
                player.play()
                isPlaying = true
                scheduleControlsHide()
                return
            }
        }

        stepRate(forward: true)
        if isPlaying {
            scheduleControlsHide()
        }
    }
    
    func seek(to time: Double) {
        let clampedTime = max(0, min(time, duration))
        
        if useVLC {
            vlcPlayer?.seek(to: clampedTime)
        } else {
            let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        
        currentTime = clampedTime
    }
    
    func seekRelative(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func skipForward() {
        seekRelative(by: 10)
    }

    func skipBackward() {
        seekRelative(by: -10)
    }
    
    func seekByFrames(_ count: Int) {
        guard let frameRate = item.metadata?.videoStream?.frameRate?.value, frameRate > 0 else {
            // Fallback: assume 24fps
            seekRelative(by: Double(count) / 24.0)
            return
        }
        seekRelative(by: Double(count) / frameRate)
    }
    
    func userDidInteract() {
        showControls = true
        isMouseIdle = false
        scheduleControlsHide()
    }

    func setControlsHovering(_ hovering: Bool) {
        isHoveringControls = hovering
        if hovering {
            cancelControlsHide()
            showControls = true
            isMouseIdle = false
        } else {
            scheduleControlsHide()
        }
    }

    func mouseMoved(x: CGFloat, viewWidth: CGFloat) {
        // Hide immediately when hovering near the right edge.
        if x >= viewWidth - rightEdgeHideThreshold {
            forceHideControls()
            return
        }

        showControls = true
        isMouseIdle = false
        scheduleControlsHide()
    }

    func forceHideControls() {
        cancelControlsHide()
        withAnimation(.easeOut(duration: 0.2)) {
            showControls = false
            isMouseIdle = true
        }
    }
    
    func cleanup() {
        controlsHideTask?.cancel()
        stopReverseSimulation()

        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }

        timeObserver = nil
        statusObserver = nil
        
        player?.pause()
        player = nil
        
        vlcPlayer?.stop()
        vlcPlayer = nil
        
        switch securityScopeAccess {
        case .none:
            break
        case .direct:
            item.url.stopAccessingSecurityScopedResource()
        case .bookmark:
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: item.url)
        }
        securityScopeAccess = .none
        
        cancellables.removeAll()
    }
    
    // MARK: - Keyboard Handling
    
    /// Returns true if the key was handled
    func handleKeyCommand(key: String, modifiersRaw: UInt, keyCode: UInt16) -> Bool {
        _ = modifiersRaw
        // Escape handled separately by the view to close
        
        // Space: same as K in trim player
        if key == " " {
            togglePlayback()
            return true
        }

        // J/K/L: mirror trim player behavior
        switch key.lowercased() {
        case "j":
            startReverseSimulation()
            return true
        case "k":
            togglePlayback()
            return true
        case "l":
            fastForward()
            return true
        default:
            break
        }
        
        // Arrow keys: match trim player default stepping
        switch Int(keyCode) {
        case kVK_LeftArrow:
            seekByFrames(-1)
            return true

        case kVK_RightArrow:
            seekByFrames(1)
            return true

        case kVK_UpArrow:
            seekByFrames(-10)
            return true

        case kVK_DownArrow:
            seekByFrames(10)
            return true

        default:
            break
        }
        
        return false
    }
    
    // MARK: - Private Methods
    
    private func handlePlayerItemStatus(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            isPreparing = false
            
            // Get actual duration from player
            if let playerItem = player?.currentItem {
                let cmDuration = playerItem.duration
                if cmDuration.isNumeric {
                    duration = CMTimeGetSeconds(cmDuration)
                }
            }
            
            // Stay paused on launch (match trim player)
            let startTime = item.effectiveTrimStart
            currentTime = startTime
            let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
            player?.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pause()
                }
            }
            
        case .failed:
            print("AVPlayer failed, falling back to VLC: \(error?.localizedDescription ?? "unknown")")
            fallbackToVLC()
            
        case .unknown:
            break
            
        @unknown default:
            break
        }
    }
    
    private func fallbackToVLC() {
        // Clean up AVPlayer
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObserver = nil
        player = nil
        
        // Setup VLC
        useVLC = true
        let vlc = VLCPlayer()
        vlcPlayer = vlc
        
        // Subscribe to VLC time updates
        vlc.$timePos
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
            }
            .store(in: &cancellables)
        
        vlc.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                if dur > 0 {
                    self?.duration = dur
                }
            }
            .store(in: &cancellables)
        
        vlc.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                self?.isPlaying = playing
            }
            .store(in: &cancellables)
        
        vlc.load(url: item.url, autostart: false)
        isPreparing = false
        
        // Mirror trim player: force-render first frame, but remain paused
        let startTime = item.effectiveTrimStart
        currentTime = startTime
        vlc.isMuted = true
        vlc.seek(to: startTime)
        vlc.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak vlc] in
            guard let self, let vlc else { return }
            vlc.pause()
            vlc.seek(to: startTime)
            vlc.isMuted = false
            vlc.rate = 1.0
            self.currentPlaybackSpeed = 1.0
            self.isPlaying = false
        }
    }
    
    private func setupTimeObserver() {
        guard let player = player else { return }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }
    }
    
    private func scheduleControlsHide() {
        controlsHideTask?.cancel()

        // Keep controls visible while hovering over them.
        guard !isHoveringControls else { return }

        controlsHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            guard let self, !Task.isCancelled else { return }

            // If user moved back onto controls, don’t hide.
            guard !self.isHoveringControls else { return }

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    self.showControls = false
                    self.isMouseIdle = true
                }
            }
        }
    }
    
    private func cancelControlsHide() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
    }
}
