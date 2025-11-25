// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fallback preview generation for PreviewPlayerController (composition-based chunked playback).

import Foundation
import AVKit
import OSLog

extension PreviewPlayerController {
    private var chunkSegments: [ClosedRange<Double>] {
        loadedChunks.compactMap { chunkIndex in
            let start = Double(chunkIndex) * chunkDuration
            let duration = chunkDurations[chunkIndex] ?? chunkDuration
            guard duration > 0 else { return nil }
            let end = start + duration
            return start...end
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }

    @discardableResult
    func jumpToNextCachedSegmentStart() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = chunkSegments.first(where: { $0.lowerBound > currentTime + tolerance }) {
            seekTo(segment.lowerBound)
            return true
        }
        return false
    }
    
    @discardableResult
    func jumpToPreviousCachedSegmentEnd() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = chunkSegments.reversed().first(where: { $0.upperBound < currentTime - tolerance }) {
            let target = max(segment.upperBound - tolerance, segment.lowerBound)
            seekTo(target)
            return true
        }
        return false
    }
    
    
    // MARK: - Fallback Preview Initialization
    
    func fallbackToPreview(startTime: TimeInterval) {
        guard !usePreviewFallback else {
            errorMessage = "Unable to play this video format"
            return
        }

        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").debug("fallbackToPreview called. Setting usePreviewFallback = true")
        usePreviewFallback = true
        isPreparing = true
        errorMessage = nil

        let currentItem = videoItem
        
        // Reload preview assets (teardown() clears them when switching from AVPlayer)
        loadPreviewAssets(for: currentItem.url)
        
        // Use the same fingerprint-based cache directory as preview assets
        Task { @MainActor in
            do {
                let cacheDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: currentItem.url)
                let audioStreams = await self.determineAudioStreamOrder(for: currentItem)
                self.previewAudioStreamIndices = audioStreams
                self.mp4Session = MP4PreviewSession(
                    sourceURL: currentItem.url,
                    cacheDirectory: cacheDirectory,
                    audioStreamIndices: audioStreams,
                    hasVideoStream: currentItem.hasVideoStream
                )
                await self.restoreCachedChunkState(from: cacheDirectory)
                self.startFallbackGeneration(startTime: startTime, currentItem: currentItem)
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to create cache directory for fallback preview: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Unable to prepare preview: \(error.localizedDescription)"
                self.isPreparing = false
            }
        }
    }
    
    private func startFallbackGeneration(startTime: TimeInterval, currentItem: VideoItem) {

        preparationTask = Task { @MainActor in
            defer { 
                self.isPreparing = false
                self.isGeneratingFallbackPreview = false
            }
            
            self.isGeneratingFallbackPreview = true
            
            // Ensure fallback flag is true (in case it was reset by unexpected teardown)
            self.usePreviewFallback = true

            do {
                guard let session = self.mp4Session else {
                    throw MP4PreviewSession.PreviewError.outputMissing
                }

                // Extract full audio tracks ONCE (instead of per-chunk)
                let audioURLs = try await session.extractFullAudioTracks()
                self.fullAudioTrackURLs = audioURLs
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Extracted \(audioURLs.count) full audio tracks. URLs: \(audioURLs.map { $0.lastPathComponent })")

                // Generate initial chunk (video only, skip audio)
                let chunkIndex = 0
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                let chunkResult = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge,
                    skipAudio: true
                )
                try Task.checkCancellation()

                self.chunkDurations[chunkIndex] = chunkResult.duration

                // Initialize composition with full audio track (empty video track)
                try await self.initializeComposition()
                
                // Track the loaded chunk
                self.loadedChunks = [chunkIndex]
                self.currentChunkIndex = chunkIndex
                self.appliedChunks = [] // Will be added by applyChunkToComposition
                self.updateFallbackCoverageRange()
                
                // Refresh audio track options now that we have a player item (composition)
                self.refreshAudioTrackOptions(for: currentItem, playerItem: self.player?.currentItem)
                
                // Explicitly apply the selected audio track to the new composition
                // This ensures the AVMutableAudioMix is constructed and applied immediately
                self.applySelectedAudioTrackToCurrentPlayerItem()

                // Apply the first chunk
                try await self.applyChunkToComposition(
                    chunkIndex: chunkIndex,
                    newDuration: chunkResult.duration,
                    previousDuration: nil,
                    session: session
                )

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("MP4 composition playback ready (chunk \(chunkIndex, privacy: .public), 5s) for item \(currentItem.id, privacy: .public)")

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("MP4 composition playback ready (chunk \(chunkIndex, privacy: .public), 5s) for item \(currentItem.id, privacy: .public)")

                // Background: preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)

                // Chunk is ready, clear overlay if it matches this chunk
                let expectedPendingTime = Double(chunkIndex) * self.chunkDuration
                if self.pendingChunkTime == expectedPendingTime {
                    self.pendingChunkTime = nil
                }

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("MP4 fallback cancelled for item \(currentItem.id, privacy: .public)")
                self.pendingChunkTime = nil
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("MP4 fallback failed: \(error.localizedDescription, privacy: .public)")
                self.pendingChunkTime = nil
                self.errorMessage = "Unable to play this video: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Composition Management
    
    /// Initializes composition with audio track (full length) and empty video track
    private func initializeComposition() async throws {
        let composition = AVMutableComposition()

        // Add video track (empty initially)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MP4PreviewSession.PreviewError.failedToStart("Could not create video track")
        }
        
        // Clear existing tracks reference
        self.compositionAudioTracks = []
        
        // Add the SELECTED full audio track
        let selectedIndex = self.selectedAudioTrackOrderIndex
        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
            .info("Initializing composition with audio track index: \(selectedIndex) (Total tracks: \(self.fullAudioTrackURLs.count))")
            
        if selectedIndex >= 0 && selectedIndex < fullAudioTrackURLs.count {
            let audioURL = fullAudioTrackURLs[selectedIndex]
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .info("Using audio file: \(audioURL.lastPathComponent)")
                
            let audioAsset = AVURLAsset(url: audioURL)
            let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
            
            if let sourceTrack = audioTracks.first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                // Insert the FULL audio track
                let audioDuration = try await audioAsset.load(.duration)
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: audioDuration),
                    of: sourceTrack,
                    at: .zero
                )
                self.compositionAudioTracks.append(audioTrack)
            }
        }
        
        // Store references
        self.composition = composition
        self.compositionVideoTrack = videoTrack
        
        // Create player with composition
        let playerItem = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        updatePlayerActionAtEnd()
    }
    
    @MainActor
    private func applyChunkToComposition(
        chunkIndex: Int,
        newDuration: TimeInterval,
        previousDuration: TimeInterval?,
        session: MP4PreviewSession
    ) async throws {
        guard let composition = self.composition,
              let videoTrack = self.compositionVideoTrack else { return }

        let insertTime = CMTime(seconds: Double(chunkIndex) * self.chunkDuration, preferredTimescale: 600)
        let newDurationTime = CMTime(seconds: newDuration, preferredTimescale: 600)
        guard newDurationTime.seconds > 0 else { return }

        let chunkURL = session.chunkURL(for: chunkIndex)
        guard FileManager.default.fileExists(atPath: chunkURL.path) else { return }

        let chunkAsset = AVURLAsset(url: chunkURL)
        let chunkVideoTracks = try await chunkAsset.loadTracks(withMediaType: .video)
        guard let chunkVideoTrack = chunkVideoTracks.first else { return }

        // Handle Video Track ONLY (audio is from full track)
        if let previousDuration {
            let previousDurationTime = CMTime(seconds: previousDuration, preferredTimescale: 600)
            let removeRange = CMTimeRange(start: insertTime, duration: previousDurationTime)
            videoTrack.removeTimeRange(removeRange)
        } else if appliedChunks.contains(chunkIndex) {
            let previousDurationTime = CMTime(seconds: chunkDurations[chunkIndex] ?? self.chunkDuration, preferredTimescale: 600)
            let removeRange = CMTimeRange(start: insertTime, duration: previousDurationTime)
            videoTrack.removeTimeRange(removeRange)
        } else if insertTime < composition.duration {
            let placeholderRange = CMTimeRange(start: insertTime, duration: newDurationTime)
            videoTrack.removeTimeRange(placeholderRange)
        }

        if insertTime > composition.duration {
            let gap = insertTime - composition.duration
            videoTrack.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: gap))
        }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: newDurationTime),
            of: chunkVideoTrack,
            at: insertTime
        )
        
        // Audio is handled by the full audio track, no need to insert chunks

        appliedChunks.insert(chunkIndex)
        chunkDurations[chunkIndex] = newDuration
    }

    private func orderAudioTracks(_ tracks: [AVAssetTrack]) -> [AVAssetTrack] {
        guard !tracks.isEmpty else { return [] }
        let clampedIndex = min(max(selectedAudioTrackOrderIndex, 0), tracks.count - 1)
        var ordered = tracks
        if clampedIndex != 0 {
            let preferred = ordered.remove(at: clampedIndex)
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    // MARK: - Chunk Loading
    
    /// Preloads upcoming chunks in the background to keep playback smooth
    private func loadAdjacentChunksInBackground(currentChunk: Int) {
        chunkPreloadTask?.cancel()
        chunkPreloadTask = Task { @MainActor in
            guard let session = self.mp4Session else { return }

            let totalChunks = Int(ceil(self.videoItem.durationSeconds / self.chunkDuration))
            let lookaheadCount = 5

            let lookbehindCount = 3
            var targets: [Int] = []

            if currentChunk > 0 {
                for offset in 1...lookbehindCount {
                    let previousChunk = currentChunk - offset
                    if previousChunk < 0 { break }
                    if self.appliedChunks.contains(previousChunk) { continue }
                    targets.append(previousChunk)
                }
            }

            for offset in 1...lookaheadCount {
                let nextChunk = currentChunk + offset
                if nextChunk >= totalChunks { break }
                if self.appliedChunks.contains(nextChunk) { continue }
                if targets.contains(nextChunk) { continue }
                targets.append(nextChunk)
            }

            for chunk in targets {
                if Task.isCancelled { return }

                let directionDescription: String
                if chunk < currentChunk {
                    directionDescription = "backfill \(currentChunk - chunk)"
                } else {
                    directionDescription = "lookahead \(chunk - currentChunk)"
                }

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Preloading chunk \(chunk, privacy: .public) (\(directionDescription))")

                do {
                    let chunkStart = Double(chunk) * self.chunkDuration
                    let chunkResult = try await session.generatePreviewChunk(
                        chunkIndex: chunk,
                        startTime: chunkStart,
                        durationLimit: self.chunkDuration,
                        maxShortEdge: self.previewMaxShortEdge,
                        skipAudio: true
                    )

                    let previousDuration = self.chunkDurations[chunk]
                    try await self.applyChunkToComposition(
                        chunkIndex: chunk,
                        newDuration: chunkResult.duration,
                        previousDuration: previousDuration,
                        session: session
                    )
                    self.loadedChunks.insert(chunk)
                    self.updateFallbackCoverageRange()

                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .info("Preloaded chunk \(chunk, privacy: .public)")

                    if Task.isCancelled { return }

                } catch is CancellationError {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .debug("Chunk preloading cancelled")
                    return
                } catch {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .warning("Failed to preload chunk \(chunk, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    /// Loads and switches to a specific chunk for a given time
    func loadChunkForTime(_ time: TimeInterval) {
        let chunkIndex = Int(time / chunkDuration)

        if appliedChunks.contains(chunkIndex), chunkDurations[chunkIndex] != nil {
            currentChunkIndex = chunkIndex
            pendingChunkTime = nil
            loadAdjacentChunksInBackground(currentChunk: chunkIndex)
            return
        }

        // Already on this chunk
        if chunkIndex == currentChunkIndex { return }
        
        // Don't try to load if already loading THIS chunk
        if isLoadingChunk && loadingChunkIndex == chunkIndex { return }

        chunkLoadTask?.cancel()
        loadingChunkIndex = chunkIndex
        
        chunkLoadTask = Task { @MainActor in
            self.isLoadingChunk = true
            defer { 
                self.isLoadingChunk = false 
                if self.loadingChunkIndex == chunkIndex {
                    self.loadingChunkIndex = nil
                }
            }
            
            do {
                guard let session = self.mp4Session else { return }
                let chunkAlreadyGenerated = self.loadedChunks.contains(chunkIndex)
                if chunkAlreadyGenerated {
                    self.pendingChunkTime = nil
                } else {
                    self.pendingChunkTime = Double(chunkIndex) * self.chunkDuration
                }
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Loading chunk \(chunkIndex, privacy: .public) for time \(time, privacy: .public)s")
                
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                let chunkResult = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge,
                    skipAudio: true
                )
                
                try Task.checkCancellation()
                
                let previousDuration = self.chunkDurations[chunkIndex]
                try await self.applyChunkToComposition(
                    chunkIndex: chunkIndex,
                    newDuration: chunkResult.duration,
                    previousDuration: previousDuration,
                    session: session
                )
                self.loadedChunks.insert(chunkIndex)
                self.currentChunkIndex = chunkIndex
                self.updateFallbackCoverageRange()
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Applied chunk \(chunkIndex, privacy: .public) into composition")
                
                // Preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)

                // Chunk ready – clear overlay if it matches
                let expectedPendingTime = Double(chunkIndex) * self.chunkDuration
                if self.pendingChunkTime == expectedPendingTime {
                    self.pendingChunkTime = nil
                }

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("Chunk loading cancelled")
                self.pendingChunkTime = nil
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to load chunk: \(error.localizedDescription, privacy: .public)")
                self.pendingChunkTime = nil
            }
        }
    }
    
    /// Rebuilds the composition with the currently selected audio track
    func rebuildComposition() async {
        guard let session = self.mp4Session, !loadedChunks.isEmpty else { return }
        
        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
            .info("Rebuilding composition for audio track switch (Index: \(self.selectedAudioTrackOrderIndex))")
        
        // 1. Pause playback
        let wasPlaying = (self.player?.rate ?? 0) > 0
        self.player?.pause()
        let currentTime = self.player?.currentTime() ?? .zero
        
        // 2. Reset composition state
        self.composition = nil
        self.compositionVideoTrack = nil
        self.compositionAudioTracks = []
        self.appliedChunks.removeAll()
        
        let sortedChunks = self.loadedChunks.sorted()
        
        // 3. Initialize composition (full audio, empty video)
        do {
            try await self.initializeComposition()
        } catch {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .error("Failed to initialize composition during rebuild: \(error.localizedDescription)")
            return
        }
        
        // 4. Apply all loaded chunks
        for chunkIndex in sortedChunks {
            let chunkDuration = self.chunkDurations[chunkIndex] ?? self.chunkDuration
            do {
                // We pass nil for previousDuration because we are building fresh
                try await self.applyChunkToComposition(
                    chunkIndex: chunkIndex,
                    newDuration: chunkDuration,
                    previousDuration: nil,
                    session: session
                )
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to apply chunk \(chunkIndex) during rebuild: \(error.localizedDescription)")
                // Continue to next chunk even if this one fails
            }
        }
        
        // 5. Restore playback state
        await self.player?.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying {
            self.player?.play()
        }
    }
}
