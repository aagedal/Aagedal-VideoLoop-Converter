// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Controller for video preview playback, trimming, and screenshot capture.
// Extensions: +Screenshot, +Observers

import SwiftUI
import AppKit
import AVKit
import Combine
import OSLog

@MainActor
final class PreviewPlayerController: ObservableObject {
    struct AudioTrackOption: Identifiable, Equatable {
        let id: Int
        let position: Int
        let streamIndex: Int
        let mediaOptionIndex: Int?
        let title: String
        let subtitle: String?
    }

    struct SubtitleTrackOption: Identifiable, Equatable {
        let id: Int
        let position: Int
        let trackId: Int32
        let title: String
    }

    // MARK: - Published State
    
    @Published var volume: Double = 100 {
        didSet {
            // Only apply if MPV is active
            if useMPV, let mpvPlayer {
                mpvPlayer.volume = volume
            }
        }
    }
    @Published var isMuted: Bool = false {
        didSet {
            // Only apply if MPV is active
            if useMPV, let mpvPlayer {
                mpvPlayer.isMuted = isMuted
            }
        }
    }
    @Published var player: AVPlayer?
    @Published var isPreparing = false
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published private(set) var currentWaveformURL: URL?
    @Published private(set) var currentWaveformChunks: [WaveformChunk] = []
    @Published private(set) var currentNativeWaveformImage: NSImage?
    @Published private(set) var totalDuration: Double = 0  // For chunk width calculation
    @Published var currentPlaybackTime: Double = 0
    @Published private(set) var currentPlaybackSpeed: Float = 1.0
    @Published private(set) var isReverseSimulating: Bool = false
    // Audio monitoring is defined in extension/bottom section
    
    // Reverse simulation
    private var reverseSpeed: Int = 1 // 1x, 2x, 3x, 4x
    private var reverseTimer: Timer?
    
    // MPV trim observer
    var mpvTrimObserverTimer: Timer?
    @Published var previewAssets: PreviewAssets? {
        didSet { updateCurrentWaveform() }
    }
    @Published var isLoadingPreviewAssets = false
    @Published var isCapturingScreenshot = false
    @Published var audioTrackOptions: [AudioTrackOption] = []
    @Published var subtitleTrackOptions: [SubtitleTrackOption] = []
    @Published var isCropEnabled: Bool = false

    // MARK: - State

    var videoItem: VideoItem
    var preparationTask: Task<Void, Never>?
    var previewAssetTask: Task<Void, Never>?
    private var previewAssetURL: URL?  // Track URL being processed to avoid redundant cancellation
    var loopObserver: Any?
    var playbackDidFinish: (() -> Void)?
    var timeObserver: Any?
    var playbackTimeObserver: Any?
    var audioSyncObserver: Any?
    weak var timeObserverOwner: AVPlayer?
    weak var playbackTimeObserverOwner: AVPlayer?
    weak var audioSyncObserverOwner: AVPlayer?
    var playerItemStatusObserver: Any?
    var mpvEndObserver: AnyCancellable?
    var hasSecurityScope = false
    weak var playerView: AVPlayerView?
    var selectedAudioTrackOrderIndex: Int = 0
    var selectedSubtitleTrackOrderIndex: Int = -1  // -1 means subtitles disabled

    // MARK: - Audio Monitoring
    // UniversalAudioMeterService is defined below in Audio Metering section
    
    // MARK: - MPV State
    @Published var mpvPlayer: MPVPlayer?
    @Published var useMPV = false

    // MARK: - Initialization
    
    var playbackTimePublisher: Published<Double>.Publisher { $currentPlaybackTime }

    /// Returns the effective duration, preferring video item metadata but falling back to player duration
    /// This allows the timeline to be interactive even before metadata loads
    var effectiveDuration: Double {
        // First try the video item's duration (from metadata)
        if videoItem.durationSeconds > 0 {
            return videoItem.durationSeconds
        }
        // Fall back to MPV player's duration if available
        if let mpvDuration = mpvPlayer?.duration, mpvDuration > 0 {
            return mpvDuration
        }
        // Fall back to AVPlayer's duration if available
        if let playerDuration = player?.currentItem?.duration.seconds,
           playerDuration.isFinite && playerDuration > 0 {
            return playerDuration
        }
        return 0
    }

    init(videoItem: VideoItem) {
        self.videoItem = videoItem
        setupAudioMonitoring()
    }
    
    // MARK: - Video Item Management
    
    func updateVideoItem(_ newValue: VideoItem) {
        let previous = videoItem
        videoItem = newValue

        if previous.id != newValue.id || previous.url != newValue.url {
            preparePreview(startTime: newValue.effectiveTrimStart)
            loadPreviewAssets(for: newValue.url)
        } else if previous.loopPlayback != newValue.loopPlayback {
            updatePlayerActionAtEnd()
        } else if previous.trimStart != newValue.trimStart || previous.trimEnd != newValue.trimEnd {
            // Trim values changed, reinstall time observer with new boundaries
            if let player = player {
                installTimeObserver(for: player)
            }
        }
    }
    
    // MARK: - Preview Preparation

    /// Check if the video has surround audio (any track with more than 2 channels)
    /// QuickTime/AVPlayer doesn't handle surround audio well, so we use MPV for these files
    private var hasSurroundAudio: Bool {
        guard let audioStreams = videoItem.metadata?.audioStreams else { return false }
        return audioStreams.contains { ($0.channels ?? 0) > 2 }
    }

    /// Check if the video codec is ProRes (any variant including RAW)
    /// ProRes files handle surround audio correctly in AVPlayer, unlike other codecs
    private var hasProResVideoCodec: Bool {
        guard let videoStream = videoItem.metadata?.primaryVideoStream,
              let codec = videoStream.codec?.lowercased() else { return false }

        // ProRes variants (including ProRes RAW) handle surround audio correctly in AVPlayer
        // Other codecs like HEVC may have silent audio with certain surround layouts (e.g., 5.1 side AAC)
        let proresCodecs = [
            "prores", "prores_ks",           // ProRes (all profiles)
            "ap4h", "ap4x",                   // ProRes 4444 / 4444 XQ
            "apcn", "apch", "apcs", "apco",   // ProRes 422 variants
            "aprn", "aprh",                   // ProRes RAW / RAW HQ
        ]

        return proresCodecs.contains { codec.contains($0) }
    }

    func preparePreview(startTime: TimeInterval, resetAudioSelection: Bool = true) {
        teardown(resetAudioSelection: resetAudioSelection)
        isPreparing = true
        isReady = false
        errorMessage = nil
        isLoadingPreviewAssets = true
        previewAssets = nil
        useMPV = false

        let url = videoItem.url
        let fileExtension = url.pathExtension.lowercased()

        // Force MPV for container formats that AVPlayer doesn't support well
        // MKV, WebM, AVI, FLV etc. often fail silently with AVPlayer
        let avPlayerUnsupportedContainers = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "ts", "mts", "m2ts"]
        if avPlayerUnsupportedContainers.contains(fileExtension) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .info("Using MPV for \(fileExtension.uppercased()) container: \(url.lastPathComponent)")
            setupMPV(url: url, startTime: startTime)
            return
        }

        // Force MPV for surround audio files - but not for ProRes
        // ProRes handles surround audio correctly, other codecs (HEVC, H.264) may have silent audio
        if hasSurroundAudio && !hasProResVideoCodec {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .info("Surround audio detected with non-ProRes codec, using MPV player for \(url.lastPathComponent)")
            setupMPV(url: url, startTime: startTime)
            return
        }

        // Try AVPlayer directly first with security-scoped resource access
        
        // First try bookmark-based access (more reliable for sandboxed apps)
        let bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        let directAccess = !bookmarkAccess && url.startAccessingSecurityScopedResource()
        hasSecurityScope = bookmarkAccess || directAccess
        
        // Create asset with security-scoped access preference
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        
        // Monitor player item status for failures, fallback to MPV if needed
        installPlayerItemStatusObserver(for: playerItem, startTime: startTime)
        
        self.isPreparing = false
        refreshAudioTrackOptions(for: videoItem, playerItem: playerItem)

        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        updatePlayerActionAtEnd()
        loadPreviewAssets(for: videoItem.url)
        
        // Audio monitoring is handled globally by UniversalAudioMeterService
    }
    
    var debugWindowController: Any? // Holds strong reference to keep window alive

    func setupMPV(url: URL, startTime: Double) {
        // Explicitly nil the player to prevent key consumption
        player = nil

        // Re-acquire security-scoped access for MPV (teardown released it)
        let bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        let directAccess = !bookmarkAccess && url.startAccessingSecurityScopedResource()
        hasSecurityScope = bookmarkAccess || directAccess

        let mpv = MPVPlayer()
        self.mpvPlayer = mpv
        self.useMPV = true
        self.isPreparing = false

        mpvEndObserver?.cancel()
        mpvEndObserver = mpv.$reachedEnd
            .removeDuplicates()
            .sink { [weak self] reached in
                NSLog("📍 mpvEndObserver: reachedEnd changed to \(reached)")
                guard reached else { return }
                Task { @MainActor in
                    let hasCallback = self?.playbackDidFinish != nil
                    NSLog("📍 mpvEndObserver: calling playbackDidFinish (callback exists: \(hasCallback))")
                    self?.playbackDidFinish?()
                }
            }

        // Apply volume/mute state before loading
        mpv.volume = volume
        mpv.isMuted = isMuted

        // Load without autostarting, with start time
        mpv.load(url: url, startTime: startTime, autostart: false)

        // Sync time position
        Task { @MainActor [weak self, weak mpv] in
            guard let self, let mpv else { return }
            for await time in mpv.$timePos.values {
                self.currentPlaybackTime = time
            }
        }

        // Observe file loaded state for isReady
        Task { @MainActor [weak self, weak mpv] in
            guard let self, let mpv else { return }
            for await isLoaded in mpv.$isFileLoaded.values {
                if isLoaded {
                    self.isReady = true
                    break  // Only need to set once per file
                }
            }
        }

        // Refresh audio tracks after a brief delay for MPV to parse the media
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshAudioTrackOptions(for: self.videoItem, playerItem: nil)
        }

        // Install MPV trim boundary observer for looping
        installMPVTrimObserver()

        // Reload preview assets (teardown() clears them when switching from AVPlayer)
        // This uses the cache so it's instant
        loadPreviewAssets(for: url)

        // Audio monitoring is handled globally by UniversalAudioMeterService

        // DON'T call updateCurrentWaveform() here!
        // It will be called automatically via previewAssets.didSet when assets finish loading
    }
    
    // MARK: - Unified Playback Control

    func togglePlayback() {
        // Ignore if player is not ready yet
        guard isReady else { return }

        // If reversing, K/Space should just stop reverse (stay paused)
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        if useMPV, let mpv = mpvPlayer {
            // Check if currently playing
            let wasPlaying = mpv.isPlaying
            // Reset rate FIRST, ensure it's applied
            mpv.rate = 1.0
            currentPlaybackSpeed = 1.0

            if wasPlaying {
                mpv.pause()
            } else {
                // Make sure rate is 1.0 before playing
                mpv.play()
            }
        } else if let player = player {
            currentPlaybackSpeed = 1.0
            if player.rate != 0 {
                player.pause()
            } else {
                player.rate = 1.0
                player.play()
            }
        }
    }
    
    func pause() {
        stopReverseSimulation()

        if useMPV, let mpv = mpvPlayer {
            // Reset rate FIRST, then pause
            mpv.rate = 1.0
            currentPlaybackSpeed = 1.0
            mpv.pause()
        } else {
            currentPlaybackSpeed = 1.0
            player?.pause()
        }
    }
    
    func stepRate(forward: Bool) {
        if useMPV, let mpv = mpvPlayer {
            // MPV rate stepping: 0.5 -> 1.0 -> 1.5 -> 2.0 etc
            let current = mpv.rate
            let step: Float = 0.5
            let newRate = forward ? current + step : current - step
            mpv.rate = max(0.25, min(newRate, 4.0))
            currentPlaybackSpeed = mpv.rate
        } else if let player = player {
            // AVPlayer rate stepping
            let current = player.rate
            let step: Float = 1.0
            let newRate = forward ? current + step : current - step
            player.rate = newRate
            currentPlaybackSpeed = player.rate
        }
    }
    
    func startReverseSimulation() {
        // Ignore if player is not ready yet
        guard isReady else { return }

        // If already reversing, increase speed (max 4x)
        if isReverseSimulating {
            reverseSpeed = min(reverseSpeed + 1, 4)
            // Restart timer with new speed
            reverseTimer?.invalidate()
            let interval = (1.0/24.0) / Double(reverseSpeed)
            reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.seekByFrames(-1)
                }
            }
            currentPlaybackSpeed = -Float(reverseSpeed)
            return
        }
        
        // Start new reverse simulation
        pause()
        reverseSpeed = 1
        isReverseSimulating = true
        currentPlaybackSpeed = -1.0
        
        // Start reverse simulation (step backwards at ~24fps)
        let interval = 1.0/24.0
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
        // Reset speed when stopping reverse
        if !isReverseSimulating {
            currentPlaybackSpeed = 1.0
        }
    }
    
    func rewind() {
        stopReverseSimulation()
        stepRate(forward: false)
    }
    
    func fastForward() {
        // Ignore if player is not ready yet
        guard isReady else { return }

        // If reversing, L stops reverse
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        // If paused, start playing at 1×
        if useMPV, let mpv = mpvPlayer {
            if !mpv.isPlaying {
                mpv.rate = 1.0
                currentPlaybackSpeed = 1.0
                mpv.play()
                return
            }
        } else if let player = player {
            if player.rate == 0 {
                player.rate = 1.0
                currentPlaybackSpeed = 1.0
                player.play()
                return
            }
        }

        // Otherwise increase forward speed
        stepRate(forward: true)
    }
    
    func seek(by seconds: Double) {
        let currentTime = getCurrentTime() ?? 0
        let newTime = currentTime + seconds
        // Allow seeking anywhere in the video, not just within trim range
        seekTo(max(0, min(newTime, videoItem.durationSeconds)))
    }
    
    func seekByFrames(_ frameCount: Int) {
        // Calculate seconds per frame from video metadata
        if let frameRate = videoItem.metadata?.primaryVideoStream?.frameRate,
           let frameRateValue = frameRate.value, frameRateValue > 0 {
            let secondsPerFrame = 1.0 / frameRateValue
            seek(by: Double(frameCount) * secondsPerFrame)
        } else {
            // Fallback to 1/30th second if no frame rate available
            seek(by: Double(frameCount) / 30.0)
        }
    }

    /// Determines the preferred ordering of audio stream indices based on metadata (default + channel count).
    nonisolated func determineAudioStreamOrder(for item: VideoItem) async -> [Int] {
        if let metadata = item.metadata {
            return orderAudioStreams(from: metadata)
        }
        if let metadata = try? await VideoMetadataService.shared.metadata(for: item.url) {
            return orderAudioStreams(from: metadata)
        }
        return []
    }
    
    nonisolated private func orderAudioStreams(from metadata: VideoMetadata) -> [Int] {
        guard !metadata.audioStreams.isEmpty else { return [] }
        // Default stream first, fall back to original order, then by descending channel count.
        let sorted = metadata.audioStreams.enumerated().sorted { lhs, rhs in
            let lhsDefault = metadata.isDefaultAudioStream(index: lhs.offset)
            let rhsDefault = metadata.isDefaultAudioStream(index: rhs.offset)
            if lhsDefault != rhsDefault { return lhsDefault }
            let lhsChannels = lhs.element.channels ?? 0
            let rhsChannels = rhs.element.channels ?? 0
            if lhsChannels != rhsChannels { return lhsChannels > rhsChannels }
            return lhs.offset < rhs.offset
        }
        return sorted.map { $0.offset }
    }

    func refreshAudioTrackOptions(for item: VideoItem, playerItem: AVPlayerItem?) {
        let existingSelection = selectedAudioTrackOrderIndex
        Task { @MainActor [weak self] in
            guard let self else { return }

            if useMPV {
                guard let mpv = mpvPlayer else { return }
                let names = mpv.audioTrackNames
                let indexes = mpv.audioTrackIndexes
                buildMPVAudioTrackOptions(names: names, indexes: indexes)
                buildMPVSubtitleTrackOptions()
            } else {
                let metadata: VideoMetadata?
                if let cached = item.metadata {
                    metadata = cached
                } else {
                    metadata = try? await VideoMetadataService.shared.metadata(for: item.url)
                }

                let orderedIndices = metadata.map { self.orderAudioStreams(from: $0) } ?? []
                let mediaGroup: AVMediaSelectionGroup?
                if let playerItem {
                    mediaGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
                } else {
                    mediaGroup = nil
                }

                self.buildAudioTrackOptions(metadata: metadata, orderedIndices: orderedIndices, mediaGroup: mediaGroup)
            }

            if self.audioTrackOptions.isEmpty {
                self.selectedAudioTrackOrderIndex = 0
            } else {
                let clamped = min(max(existingSelection, 0), self.audioTrackOptions.count - 1)
                self.selectedAudioTrackOrderIndex = clamped
            }

            self.applySelectedAudioTrack()
        }
    }

    private func buildAudioTrackOptions(metadata: VideoMetadata?, orderedIndices: [Int], mediaGroup: AVMediaSelectionGroup?) {
        let metadataStreams = metadata?.audioStreams ?? []
        let effectiveOrder = orderedIndices.isEmpty ? Array(metadataStreams.indices) : orderedIndices
        let mediaOptions = mediaGroup?.options ?? []

        if metadataStreams.isEmpty && mediaOptions.isEmpty {
            audioTrackOptions = []
            return
        }

        var options: [AudioTrackOption] = []
        let count = max(effectiveOrder.count, mediaOptions.count)
        for position in 0..<count {
            let streamIndex = effectiveOrder.indices.contains(position) ? effectiveOrder[position] : position
            let stream = metadataStreams.indices.contains(streamIndex) ? metadataStreams[streamIndex] : nil
            let mediaOption = mediaOptions.indices.contains(position) ? mediaOptions[position] : nil
            let mediaOptionIndex = mediaOptions.indices.contains(position) ? position : nil

            let title: String
            if let stream {
                title = self.formattedAudioTrackTitle(for: stream, position: position)
            } else if let mediaOption {
                title = mediaOption.displayName
            } else {
                title = "Audio Track \(position + 1)"
            }

            var details: [String] = []
            if let stream {
                if stream.isDefault {
                    details.append("Default")
                }
                if let channels = stream.channels {
                    details.append("\(channels) ch")
                }
                if let sampleRate = stream.sampleRate {
                    details.append("\(sampleRate) Hz")
                }
                if let codec = stream.codecLongName ?? stream.codec {
                    details.append(codec)
                }
            }

            if let mediaOption, details.isEmpty {
                if let locale = mediaOption.locale {
                    details.append(locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier)
                }
            }

            options.append(
                AudioTrackOption(
                    id: streamIndex,
                    position: position,
                    streamIndex: streamIndex,
                    mediaOptionIndex: mediaOptionIndex,
                    title: title,
                    subtitle: details.isEmpty ? nil : details.joined(separator: " • ")
                )
            )
        }

        audioTrackOptions = options
    }
    
    private func buildMPVAudioTrackOptions(names: [String], indexes: [Int32]) {
        var options: [AudioTrackOption] = []

        // MPV returns tracks with 1-based IDs
        // We skip any "Disable" track (id 0 or -1 if present)

        for (index, trackID) in indexes.enumerated() {
            if trackID <= 0 { continue } // Skip "Disable" or invalid tracks

            let name = index < names.count ? names[index] : "Track \(trackID)"

            // Position in our UI list (0-based)
            let position = options.count

            options.append(
                AudioTrackOption(
                    id: Int(trackID),
                    position: position,
                    streamIndex: Int(trackID) - 1, // MPV track IDs are 1-based, waveforms are 0-based
                    mediaOptionIndex: nil,
                    title: name,
                    subtitle: nil
                )
            )
        }

        audioTrackOptions = options

        // Update selection if needed
        if !audioTrackOptions.isEmpty {
            if selectedAudioTrackOrderIndex >= audioTrackOptions.count {
                selectedAudioTrackOrderIndex = 0
            }
        }
    }

    private func formattedAudioTrackTitle(for stream: VideoMetadata.AudioStream, position: Int) -> String {
        var components: [String] = []

        if let index = stream.index {
            components.append("#\(index)")
        } else {
            components.append("#\(position)")
        }

        if let language = stream.languageCode, !language.isEmpty {
            components.append(language)
        }

        if let codecName = stream.codecLongName ?? stream.codec, !codecName.isEmpty {
            components.append(codecName)
        }

        if let layout = stream.channelLayout, !layout.isEmpty {
            components.append(layout)
        }

        if components.isEmpty {
            return "Audio Track \(position + 1)"
        }

        return components.joined(separator: " – ")
    }

    func selectAudioTrack(at position: Int) {
        guard position != selectedAudioTrackOrderIndex else { return }

        // Pause playback to prevent audio overlap/buffering issues
        let wasPlaying = (player?.rate ?? 0) > 0 || (mpvPlayer?.isPlaying ?? false)
        if wasPlaying {
            pause()
        }
        
        selectedAudioTrackOrderIndex = position
        applySelectedAudioTrack()
        updateCurrentWaveform()
        
        // Resume if it was playing, with a tiny delay to ensure track switch takes effect
        if wasPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.togglePlayback()
            }
        }
    }

    func applySelectedAudioTrack() {
        if useMPV {
            applySelectedAudioTrackToMPV()
        } else {
            applySelectedAudioTrackToCurrentPlayerItem()
        }
        updateCurrentWaveform()
    }

    private func applySelectedAudioTrackToMPV() {
        guard let mpv = mpvPlayer else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").error("applySelectedAudioTrackToMPV: mpvPlayer is nil")
            return
        }

        let indexes = mpv.audioTrackIndexes
        let names = mpv.audioTrackNames

        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
            .debug("applySelectedAudioTrackToMPV: indexes=\(indexes), names=\(names), selectedOrderIndex=\(self.selectedAudioTrackOrderIndex)")

        // MPV track IDs are 1-based
        // Our selectedAudioTrackOrderIndex is 0-based for actual tracks

        if self.selectedAudioTrackOrderIndex < indexes.count {
            let trackID = indexes[self.selectedAudioTrackOrderIndex]
            mpv.currentAudioTrackIndex = trackID
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .debug("Selected MPV audio track ID: \(trackID) (name: \(self.selectedAudioTrackOrderIndex < names.count ? names[self.selectedAudioTrackOrderIndex] : "?"))")
        } else {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .warning("Could not map audio track index \(self.selectedAudioTrackOrderIndex) to MPV indexes: \(indexes)")
        }
    }

    func applySelectedAudioTrackToCurrentPlayerItem() {
        guard let playerItem = player?.currentItem else { return }

        Task { @MainActor [weak self, weak playerItem] in
            guard let self, let playerItem else { return }

            // 1. Try to load media selection group first (for alternate tracks)
            var mediaGroup: AVMediaSelectionGroup?
            do {
                mediaGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").error("Failed to load audible group: \(error)")
            }

            // 2. Build options (this populates self.audioTrackOptions)
            self.buildAudioTrackOptions(metadata: self.videoItem.metadata, orderedIndices: [], mediaGroup: mediaGroup)

            guard !self.audioTrackOptions.isEmpty else { return }

            let desiredPosition = min(max(self.selectedAudioTrackOrderIndex, 0), self.audioTrackOptions.count - 1)
            let selectedOption = self.audioTrackOptions[desiredPosition]

            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .debug("Applying audio selection: position=\(desiredPosition), option=\(selectedOption.title)")

            // 3. Strategy A: If we have a valid media group and option index, try using select()
            // This works for mutually exclusive tracks (e.g. languages)
            if let mediaGroup, let mappedIndex = selectedOption.mediaOptionIndex, mediaGroup.options.indices.contains(mappedIndex) {
                let avOption = mediaGroup.options[mappedIndex]
                if playerItem.currentMediaSelection.selectedMediaOption(in: mediaGroup) != avOption {
                    playerItem.select(avOption, in: mediaGroup)
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").debug("Selected media option via group")
                    return // Done if successful
                }
            }

            // 4. Strategy B: Direct track enabling/disabling
            // This handles cases where tracks are not in a group (e.g. multi-channel recording)
            let tracks = playerItem.tracks
            var audioTracks: [AVPlayerItemTrack] = []

            for track in tracks {
                if track.assetTrack?.mediaType == .audio {
                    audioTracks.append(track)
                }
            }

            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").debug("Found \(audioTracks.count) audio tracks in player item")

            if !audioTracks.isEmpty {
                for (index, track) in audioTracks.enumerated() {
                    let shouldEnable = (index == desiredPosition)
                    if track.isEnabled != shouldEnable {
                        track.isEnabled = shouldEnable
                        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                            .debug("Set track \(index) enabled: \(shouldEnable)")
                    }
                }
            }
        }
    }



    private func selectedAudioStreamIndex() -> Int? {
        let position = selectedAudioTrackOrderIndex
        guard audioTrackOptions.indices.contains(position) else { return nil }
        return audioTrackOptions[position].streamIndex
    }

    private func updateCurrentWaveform() {
        let streamIndex = selectedAudioStreamIndex()
        // Native waveform image (preferred, fast)
        currentNativeWaveformImage = previewAssets?.nativeWaveform(forAudioStream: streamIndex)
        // Legacy single-image waveform (kept for backwards compatibility)
        currentWaveformURL = previewAssets?.waveform(forAudioStream: streamIndex)
        // Chunked waveform support (fallback)
        currentWaveformChunks = previewAssets?.waveformChunks(forAudioStream: streamIndex) ?? []
        totalDuration = previewAssets?.totalDuration ?? 0
        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").debug("Updated waveform: native=\(self.currentNativeWaveformImage != nil), \(self.currentWaveformChunks.count) chunks, totalDuration: \(self.totalDuration)s for stream index: \(streamIndex ?? -1)")
    }

    // MARK: - Subtitle Track Selection

    func buildMPVSubtitleTrackOptions() {
        guard let mpv = mpvPlayer else {
            subtitleTrackOptions = []
            return
        }

        let names = mpv.subtitleTrackNames
        let indexes = mpv.subtitleTrackIndexes

        var options: [SubtitleTrackOption] = []

        for (index, trackID) in indexes.enumerated() {
            if trackID <= 0 { continue }

            let name = index < names.count ? names[index] : "Subtitle \(trackID)"
            let position = options.count

            options.append(
                SubtitleTrackOption(
                    id: Int(trackID),
                    position: position,
                    trackId: trackID,
                    title: name
                )
            )
        }

        subtitleTrackOptions = options
    }

    func selectSubtitleTrack(at position: Int) {
        guard useMPV, let mpv = mpvPlayer else { return }

        if position < 0 {
            // Disable subtitles
            mpv.disableSubtitles()
            selectedSubtitleTrackOrderIndex = -1
        } else if position < subtitleTrackOptions.count {
            let option = subtitleTrackOptions[position]
            mpv.currentSubtitleTrackIndex = option.trackId
            selectedSubtitleTrackOrderIndex = position
        }
    }

    func teardown(resetAudioSelection: Bool = true) {
        preparationTask?.cancel()
        preparationTask = nil
        previewAssetTask?.cancel()
        previewAssetTask = nil

        // NOTE: We do NOT cancel FFmpeg processes here - generation continues in the
        // background even after the trim view is closed. This allows waveforms to
        // complete generating for all files in the queue.
        previewAssetURL = nil  // Reset URL tracking so next load can proceed
        player?.pause()

        // Release security-scoped resource only if we acquired it
        if hasSecurityScope {
            let url = videoItem.url
            // Try both release methods to ensure cleanup
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            url.stopAccessingSecurityScopedResource()
            hasSecurityScope = false
        }

        player = nil

        if let mpv = mpvPlayer {
            mpv.stop()
            mpvPlayer = nil
        }
        mpvEndObserver?.cancel()
        mpvEndObserver = nil
        useMPV = false

        isPreparing = false
        removeLoopObserver()
        removeTimeObserver()
        removePlaybackTimeObserver()
        removePlayerItemStatusObserver()
        if resetAudioSelection {
            selectedAudioTrackOrderIndex = 0
            selectedSubtitleTrackOrderIndex = -1
        }
        audioTrackOptions = []
        subtitleTrackOptions = []
        currentWaveformURL = nil
        currentWaveformChunks = []
        currentNativeWaveformImage = nil
        totalDuration = 0

        // Stop asset refresh polling
        assetRefreshTask?.cancel()
        assetRefreshTask = nil

        // Stop audio monitoring
        isAudioMeterEnabled = false

        // NOTE: Do NOT clear playbackDidFinish here - it's owned by the View
        // and is set before preparePreview() is called. The View clears it in onDisappear.
    }
    
    // MARK: - Playback Control
    
    func refreshPreviewForTrim() {
        if useMPV, let mpv = mpvPlayer {
            mpv.seek(to: videoItem.effectiveTrimStart)
            return
        }
        
        guard let player else {
            preparePreview(startTime: videoItem.effectiveTrimStart)
            return
        }
        
        // Check if currently playing
        let isPlaying = player.rate > 0
        
        // Seek to the new trim start position
        let seekTime = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self = self, isPlaying else { return }
                // Only resume playback if it was playing before
                self.player?.play()
            }
        }
    }
    
    func seekTo(_ time: Double) {
        // Allow seeking even before player is fully ready - seeks will queue up
        // This enables scrubbing the timeline while player is still loading

        // Update playback time immediately for UI responsiveness
        currentPlaybackTime = time

        if useMPV, let mpv = mpvPlayer {
            mpv.seek(to: time)
            return
        }

        guard let player else { return }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func getCurrentTime() -> TimeInterval? {
        // Return the UI's current playhead position
        // This is the authoritative source - it updates when:
        // - Player is playing (continuously synced from player)
        // - User drags the playhead (set by UI)
        // - User seeks with keyboard (updated before seeking)
        return currentPlaybackTime
    }
    
    func toggleFullscreen() {
        // Try to get window from playerView first, fallback to key window
        let window = playerView?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }
    
    // MARK: - Preview Assets
    
    private var assetRefreshTask: Task<Void, Never>?

    func loadPreviewAssets(for url: URL) {
        // Only restart local tasks if requesting assets for a different URL
        // This prevents waveform generation from being interrupted when the same file
        // is re-selected (e.g., opening/closing fullscreen, clicking the same row)
        // NOTE: We do NOT cancel FFmpeg processes for the old URL - generation continues
        // in the background. Only the UI tracking tasks are cancelled.
        if previewAssetURL != url {
            // Cancel local UI tracking tasks (not the actual FFmpeg generation)
            previewAssetTask?.cancel()
            assetRefreshTask?.cancel()
            previewAssetURL = url
        } else if previewAssetTask != nil {
            // Same URL and task already running - don't restart
            return
        }

        isLoadingPreviewAssets = true

        // Start a refresh task that periodically updates previewAssets with partial results
        // This enables progressive loading of waveform chunks
        assetRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isLoadingPreviewAssets {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }

                if let cached = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: url) {
                    // Only update if we have new chunks
                    let currentChunkCount = self.previewAssets?.waveformChunks.count ?? 0
                    if cached.waveformChunks.count > currentChunkCount || cached.thumbnails.count > (self.previewAssets?.thumbnails.count ?? 0) {
                        self.previewAssets = cached
                    }
                }
            }
        }

        previewAssetTask = Task { [weak self] in
            guard let self else { return }

            // Capture the URL this task is for, to avoid race conditions
            let taskURL = url

            do {
                // 1. Try to load cached assets first for immediate display
                if let cached = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: taskURL) {
                    // Only update if we're still viewing this file
                    if self.previewAssetURL == taskURL {
                        self.previewAssets = cached
                    }

                    // 2. If we have complete waveform chunks, we're good! Return early.
                    let expectedChunks = cached.expectedChunkCount
                    if expectedChunks > 0 && cached.waveformChunks.count >= expectedChunks {
                        // Only stop loading if still viewing this file
                        if self.previewAssetURL == taskURL {
                            self.isLoadingPreviewAssets = false
                            self.assetRefreshTask?.cancel()
                        }
                        return
                    }
                    // If chunks are missing, continue to generateAssets to get the rest
                }

                // 3. Generate full assets (waits for existing task if running)
                let assets = try await PreviewAssetGenerator.shared.generateAssets(for: taskURL)
                try Task.checkCancellation()

                // Only update if we're still viewing this file
                if self.previewAssetURL == taskURL {
                    self.previewAssets = assets
                }
            } catch {
                // Only handle errors if we're still viewing this file
                if self.previewAssetURL == taskURL {
                    // Only clear assets if we don't have any (don't wipe partial cache on error)
                    if self.previewAssets == nil {
                        self.previewAssets = nil
                    }
                    if (error as? CancellationError) == nil {
                        Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewAssets").error("Failed to load preview assets for \(taskURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            // Only update loading state if we're still viewing this file
            // This prevents a cancelled old task from stopping the new task's refresh
            if self.previewAssetURL == taskURL {
                self.isLoadingPreviewAssets = false
                self.assetRefreshTask?.cancel()
                self.previewAssetTask = nil
            }
        }
    }
    
    // MARK: - Audio Metering
    
    private let universalAudioMeter = UniversalAudioMeterService()
    private var cancellables = Set<AnyCancellable>()
    
    @Published var audioLevels: UniversalAudioMeterService.AudioLevels?
    /// Real-time frequency band magnitudes for the frequency visualizer.
    @Published var frequencyBands: [Float]?
    @Published var isAudioMeterEnabled = false {
        didSet {
            toggleAudioMeter()
        }
    }
    
    private func setupAudioMonitoring() {
        // Subscribe to universal meter updates
        universalAudioMeter.$currentLevels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                self?.audioLevels = levels
            }
            .store(in: &cancellables)

        // Subscribe to frequency band updates for visualizer
        universalAudioMeter.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                self?.frequencyBands = bands
            }
            .store(in: &cancellables)
            
        // Handle permission errors if needed
        universalAudioMeter.$permissionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasError in
                if hasError {
                    print("PreviewPlayerController: Audio meter permission denied")
                    // Could show alert here or disable meter
                    self?.isAudioMeterEnabled = false
                }
            }
            .store(in: &cancellables)
    }
    
    private func toggleAudioMeter() {
        Task {
            if isAudioMeterEnabled {
                await universalAudioMeter.startMonitoring()
            } else {
                await universalAudioMeter.stopMonitoring()
            }
        }
    }
}
