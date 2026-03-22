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
import OSLog
import ImageIO

struct TrimTimelineView: View {
    @Binding private var trimStart: Double
    @Binding private var trimEnd: Double

    let duration: Double
    let playbackTime: Double
    let thumbnails: [URL]?
    let quickThumbnailImages: [NSImage]
    let waveformURL: URL?
    let waveformChunks: [WaveformChunk]
    let chunkTotalDuration: Double
    let isLoading: Bool
    let step: Double
    let hideFilmstrip: Bool
    let compactMode: Bool
    let onEditingChanged: (Bool) -> Void
    let onSeek: (Double) -> Void

    // Cached images loaded in background
    @State private var cachedThumbnailImages: [NSImage] = []
    @State private var cachedThumbnailImagesById: [Int: NSImage] = [:]  // For progressive loading
    @State private var cachedWaveformImage: NSImage?
    @State private var cachedChunkImages: [Int: NSImage] = [:]
    @State private var failedChunkLoads: [Int: Int] = [:]  // Track retry counts for failed loads

    // Expected thumbnail count matches PreviewAssetGenerator.thumbnailCount
    private let expectedThumbnailCount = 6

    // Key tracking for range selection (Cmd), range sliding (Shift), and symmetric scaling (Option)
    @State private var isCommandKeyPressed: Bool = false
    @State private var isShiftKeyPressed: Bool = false
    @State private var isOptionKeyPressed: Bool = false

    private let filmstripHeight: CGFloat = 72
    private let waveformHeight: CGFloat = 66
    private let combinedHeight: CGFloat = 138
    private let compactHeight: CGFloat = 20

    init(
        trimStart: Binding<Double>,
        trimEnd: Binding<Double>,
        duration: Double,
        playbackTime: Double,
        thumbnails: [URL]?,
        quickThumbnailImages: [NSImage] = [],
        waveformURL: URL?,
        waveformChunks: [WaveformChunk] = [],
        chunkTotalDuration: Double = 0,
        isLoading: Bool,
        step: Double = 0.1,
        hideFilmstrip: Bool = false,
        compactMode: Bool = false,
        onEditingChanged: @escaping (Bool) -> Void,
        onSeek: @escaping (Double) -> Void
    ) {
        self._trimStart = trimStart
        self._trimEnd = trimEnd
        self.duration = duration
        self.playbackTime = playbackTime
        self.thumbnails = thumbnails
        self.quickThumbnailImages = quickThumbnailImages
        self.waveformURL = waveformURL
        self.waveformChunks = waveformChunks
        self.chunkTotalDuration = chunkTotalDuration
        self.isLoading = isLoading
        self.step = step
        self.hideFilmstrip = hideFilmstrip
        self.compactMode = compactMode
        self.onEditingChanged = onEditingChanged
        self.onSeek = onSeek
    }

// MARK: - Interaction Layer

private struct TrimHandlesInteractionLayer: View {
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let duration: Double
    let step: Double
    let isSymmetricScalingActive: Bool
    let onEditingChanged: (Bool) -> Void

    private let handleWidth: CGFloat = 12  // Reduced from 16 for thinner handles

    @State private var startInitialValue: Double?
    @State private var endInitialValue: Double?
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

    // For symmetric scaling, we need to store both initial values
    @State private var symmetricInitialStart: Double?
    @State private var symmetricInitialEnd: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = geometry.size.height
            let startX = position(for: trimStart, width: width)
            let endX = position(for: trimEnd, width: width)
            let clampedStartX = max(0, min(width, startX))
            let clampedEndX = max(0, min(width, endX))

            ZStack(alignment: .topLeading) {
                // Start handle
                handleView(isLeading: true, isActive: isDraggingStart)
                    .frame(width: handleWidth, height: height)
                    .offset(x: clampedStartX - handleWidth / 2)
                    .gesture(startGesture(width: width))
                    .zIndex(isDraggingStart ? 2 : 1)

                // End handle
                handleView(isLeading: false, isActive: isDraggingEnd)
                    .frame(width: handleWidth, height: height)
                    .offset(x: clampedEndX - handleWidth / 2)
                    .gesture(endGesture(width: width))
                    .zIndex(isDraggingEnd ? 2 : 1)
            }
            .allowsHitTesting(duration > 0)
        }
    }

    private func handleView(isLeading: Bool, isActive: Bool) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color.blue.opacity(isActive ? 1.0 : 0.8))
                .frame(width: 2)
        }
    }

    private func startGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDraggingStart {
                    isDraggingStart = true
                    startInitialValue = trimStart
                    symmetricInitialStart = trimStart
                    symmetricInitialEnd = trimEnd
                    onEditingChanged(true)
                }

                let baseValue = startInitialValue ?? trimStart
                let deltaValue = delta(for: value.translation.width, width: width)
                let proposed = baseValue + deltaValue
                let snapped = snap(proposed)

                if isSymmetricScalingActive {
                    // Symmetric scaling: move end handle in opposite direction
                    let initialStart = symmetricInitialStart ?? trimStart
                    let initialEnd = symmetricInitialEnd ?? trimEnd

                    var newStart = snap(initialStart + deltaValue)
                    var newEnd = snap(initialEnd - deltaValue)

                    // Clamp to valid bounds
                    newStart = max(0, newStart)
                    newEnd = min(duration, newEnd)

                    // Ensure they don't cross
                    let minGap = max(step, 0.0001)
                    if newStart >= newEnd - minGap {
                        let midpoint = (initialStart + initialEnd) / 2
                        newStart = midpoint - minGap / 2
                        newEnd = midpoint + minGap / 2
                    }

                    trimStart = newStart
                    trimEnd = newEnd
                } else {
                    trimStart = clampStart(snapped)
                }
            }
            .onEnded { _ in
                if isDraggingStart {
                    isDraggingStart = false
                    startInitialValue = nil
                    symmetricInitialStart = nil
                    symmetricInitialEnd = nil
                    onEditingChanged(false)
                }
            }
    }

    private func endGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard duration > 0 else { return }
                if !isDraggingEnd {
                    isDraggingEnd = true
                    endInitialValue = trimEnd
                    symmetricInitialStart = trimStart
                    symmetricInitialEnd = trimEnd
                    onEditingChanged(true)
                }

                let baseValue = endInitialValue ?? trimEnd
                let deltaValue = delta(for: value.translation.width, width: width)
                let proposed = baseValue + deltaValue
                let snapped = snap(proposed)

                if isSymmetricScalingActive {
                    // Symmetric scaling: move start handle in opposite direction
                    let initialStart = symmetricInitialStart ?? trimStart
                    let initialEnd = symmetricInitialEnd ?? trimEnd

                    var newStart = snap(initialStart - deltaValue)
                    var newEnd = snap(initialEnd + deltaValue)

                    // Clamp to valid bounds
                    newStart = max(0, newStart)
                    newEnd = min(duration, newEnd)

                    // Ensure they don't cross
                    let minGap = max(step, 0.0001)
                    if newStart >= newEnd - minGap {
                        let midpoint = (initialStart + initialEnd) / 2
                        newStart = midpoint - minGap / 2
                        newEnd = midpoint + minGap / 2
                    }

                    trimStart = newStart
                    trimEnd = newEnd
                } else {
                    trimEnd = clampEnd(snapped)
                }
            }
            .onEnded { _ in
                if isDraggingEnd {
                    isDraggingEnd = false
                    endInitialValue = nil
                    symmetricInitialStart = nil
                    symmetricInitialEnd = nil
                    onEditingChanged(false)
                }
            }
    }

    private func clampStart(_ value: Double) -> Double {
        let maxStart = trimEnd - max(step, 0.0001)
        return min(max(0, value), maxStart)
    }

    private func clampEnd(_ value: Double) -> Double {
        let minEnd = trimStart + max(step, 0.0001)
        return max(min(duration, value), minEnd)
    }

    private func delta(for translation: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(translation / width) * duration
    }

    private func snap(_ value: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(value / duration) * width
    }
}

    var body: some View {
        let effectiveHeight = compactMode ? compactHeight : combinedHeight

        return GeometryReader { geometry in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    // let _ = Logger(subsystem: "com.aagedal.MediaConverter", category: "TrimTimeline").debug("View received waveformURL: \(waveformURL?.path ?? "nil")")
                    // For audio-only files (no thumbnails), show waveform spanning full height
                    // Hide filmstrip when crop mode is active to save space
                    if compactMode {
                        // Compact mode: minimal scrubber bar only
                        Color.clear
                            .frame(height: compactHeight)
                    } else if hideFilmstrip {
                        // Crop mode: waveform spans full height
                        GeometryReader { geo in
                            waveformContent(width: geo.size.width, height: geo.size.height)
                        }
                        .frame(height: combinedHeight)
                    } else if let thumbnails, !thumbnails.isEmpty {
                        filmstripSection
                        waveformSection
                    } else {
                        // Audio-only: waveform spans combined height
                        GeometryReader { geo in
                            waveformContent(width: geo.size.width, height: geo.size.height)
                        }
                        .frame(height: combinedHeight)
                    }
                }

                TrimTimelineOverlay(
                    duration: duration,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    playbackTime: playbackTime
                )
                .allowsHitTesting(false)

                // Scrubbing layer (behind handles)
                TimelineScrubLayer(
                    duration: duration,
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    step: step,
                    isRangeSelectionActive: isCommandKeyPressed,
                    isRangeSlidingActive: isShiftKeyPressed,
                    onEditingChanged: onEditingChanged,
                    onSeek: onSeek
                )

                TrimHandlesInteractionLayer(
                    trimStart: $trimStart,
                    trimEnd: $trimEnd,
                    duration: duration,
                    step: step,
                    isSymmetricScalingActive: isOptionKeyPressed,
                    onEditingChanged: onEditingChanged
                )
            }
        }
        .frame(height: effectiveHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(TimelineKeyTrackerView(isCommandKeyPressed: $isCommandKeyPressed, isShiftKeyPressed: $isShiftKeyPressed, isOptionKeyPressed: $isOptionKeyPressed))
        .onChange(of: thumbnails) { _, newThumbnails in
            // Clear cache when thumbnails array reference changes (e.g., different file selected)
            // Note: Individual thumbnails are loaded progressively in thumbnailSlotView
            if newThumbnails == nil || newThumbnails?.isEmpty == true {
                cachedThumbnailImagesById = [:]
            }
        }
        .onChange(of: waveformChunks) { oldChunks, newChunks in
            // Clear chunk cache when chunks change (different file or audio track selected)
            // We detect a track/file switch by checking if the first chunk's URL changed
            let oldFirstURL = oldChunks.first?.url
            let newFirstURL = newChunks.first?.url

            // Clear cache if:
            // 1. Chunks became empty (file closed)
            // 2. First chunk URL changed (different file or audio track)
            if newChunks.isEmpty || (oldFirstURL != nil && newFirstURL != nil && oldFirstURL != newFirstURL) {
                cachedChunkImages = [:]
                failedChunkLoads = [:]
            }
        }
        .task(id: waveformURL) {
            // Load waveform image in background
            guard let url = waveformURL else {
                cachedWaveformImage = nil
                return
            }
            let image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                        kCGImageSourceShouldCache: false
                      ] as CFDictionary) else {
                    return NSImage(contentsOf: url)
                }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
            cachedWaveformImage = image
        }
    }

    // MARK: - Sections

    private var filmstripSection: some View {
        GeometryReader { geometry in
            filmstripContent(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: filmstripHeight)
    }

    private var waveformSection: some View {
        GeometryReader { geometry in
            waveformContent(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: waveformHeight)
    }

    // MARK: - Content Builders

    @ViewBuilder
    private func filmstripContent(width: CGFloat, height: CGFloat) -> some View {
        // Progressive loading: show expected slots and fill with images as they become available
        if thumbnails != nil || isLoading {
            progressiveFilmstripContent(width: width, height: height)
        } else if !quickThumbnailImages.isEmpty {
            // Fallback to quick thumbnails when no filmstrip available
            HStack(spacing: 0) {
                ForEach(Array(quickThumbnailImages.enumerated()), id: \.0) { index, image in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(max(1, quickThumbnailImages.count)), height: height)
                        .clipped()
                }
            }
            .frame(width: width, height: height)
            .background(Color.black.opacity(0.25))
        } else {
            placeholderSection(systemName: "film", text: "No thumbnails")
        }
    }

    @ViewBuilder
    private func progressiveFilmstripContent(width: CGFloat, height: CGFloat) -> some View {
        let thumbWidth = width / CGFloat(expectedThumbnailCount)
        HStack(spacing: 0) {
            ForEach(0..<expectedThumbnailCount, id: \.self) { index in
                thumbnailSlotView(index: index, slotWidth: thumbWidth, height: height)
            }
        }
        .frame(width: width, height: height)
        .background(Color.black.opacity(0.25))
    }

    @ViewBuilder
    private func thumbnailSlotView(index: Int, slotWidth: CGFloat, height: CGFloat) -> some View {
        // Check if we have this thumbnail URL
        let thumbURL: URL? = {
            guard let urls = thumbnails, index < urls.count else { return nil }
            return urls[index]
        }()

        if let image = cachedThumbnailImagesById[index] {
            // Thumbnail is loaded - display it
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: slotWidth, height: height)
                .clipped()
        } else if let url = thumbURL {
            // Thumbnail exists but not loaded - show placeholder and load async
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: slotWidth, height: height)
                .task {
                    await loadThumbnailImage(at: index, from: url)
                }
        } else {
            // Thumbnail not yet generated - show orange placeholder
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: slotWidth, height: height)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                )
        }
    }

    private func loadThumbnailImage(at index: Int, from url: URL) async {
        guard cachedThumbnailImagesById[index] == nil else { return }

        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else {
                return NSImage(contentsOf: url)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value

        if let image = image {
            cachedThumbnailImagesById[index] = image
        }
    }

    @ViewBuilder
    private func waveformContent(width: CGFloat, height: CGFloat) -> some View {
        // Use chunked waveforms when:
        // 1. We already have some chunks, OR
        // 2. We have a totalDuration from assets, OR
        // 3. The video duration exceeds 10 minutes (would need chunks)
        if !waveformChunks.isEmpty || chunkTotalDuration > 0 || duration > 600 {
            chunkedWaveformContent(width: width, height: height)
        } else if let image = cachedWaveformImage {
            // Fallback to legacy single-image waveform
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
                .id(waveformURL) // Force redraw when URL changes
        } else if waveformURL != nil {
            // Show placeholder while loading legacy waveform
            placeholderSection(
                systemName: "waveform",
                text: "Loading waveform…"
            )
            .frame(width: width, height: height)
        } else {
            placeholderSection(
                systemName: "waveform",
                text: isLoading ? "Generating waveform…" : "Waveform unavailable"
            )
            .frame(width: width, height: height)
        }
    }

    /// Expected number of chunks based on duration
    /// Always uses the video's actual duration (not chunkTotalDuration from assets)
    /// to ensure consistent chunk count during progressive loading
    private var expectedChunkCount: Int {
        guard duration > 0 else { return 0 }
        return Int(ceil(duration / 600.0))  // 10-minute chunks
    }

    /// Calculate proportional width for a chunk
    /// Always uses the video's actual duration for consistent positioning
    private func chunkWidth(for index: Int, totalWidth: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }

        // Each chunk represents up to 600 seconds (10 minutes)
        let chunkDurationSeconds: Double = 600.0
        let startTime = Double(index) * chunkDurationSeconds
        let endTime = min(startTime + chunkDurationSeconds, duration)
        let thisChunkDuration = endTime - startTime

        return CGFloat(thisChunkDuration / duration) * totalWidth
    }

    @ViewBuilder
    private func chunkedWaveformContent(width: CGFloat, height: CGFloat) -> some View {
        let chunkCount = expectedChunkCount
        if chunkCount > 0 {
            HStack(spacing: 0) {
                ForEach(0..<chunkCount, id: \.self) { index in
                    chunkView(index: index, totalWidth: width, height: height)
                }
            }
            .frame(width: width, height: height)
        } else {
            placeholderSection(
                systemName: "waveform",
                text: isLoading ? "Generating waveform…" : "Waveform unavailable"
            )
            .frame(width: width, height: height)
        }
    }

    @ViewBuilder
    private func chunkView(index: Int, totalWidth: CGFloat, height: CGFloat) -> some View {
        let chunk = waveformChunks.first { $0.id == index }
        let chunkW = chunkWidth(for: index, totalWidth: totalWidth)

        if chunk != nil, let image = cachedChunkImages[index] {
            // Chunk is loaded and cached - display it
            // Resize to fill the exact frame dimensions
            Image(nsImage: image)
                .resizable()
                .frame(width: chunkW, height: height)
        } else if let chunk = chunk {
            // Chunk exists but image not loaded yet - show gray placeholder and load async
            // Use task(id:) with chunk count to retry when new chunks arrive
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: chunkW, height: height)
                .task(id: waveformChunks.count) {
                    await loadChunkImage(chunk)
                }
        } else {
            // Chunk not yet generated - show orange placeholder
            Rectangle()
                .fill(Color.orange.opacity(0.15))
                .frame(width: chunkW, height: height)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                )
        }
    }

    private func loadChunkImage(_ chunk: WaveformChunk) async {
        guard cachedChunkImages[chunk.id] == nil else { return }

        // Don't retry more than 3 times
        let retryCount = failedChunkLoads[chunk.id] ?? 0
        guard retryCount < 3 else { return }

        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            // Check if file exists and has non-zero size (not still being written)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: chunk.url.path),
                  let fileSize = attributes[.size] as? Int,
                  fileSize > 100 else {  // PNG header is ~100 bytes minimum
                return nil
            }

            guard let imageSource = CGImageSourceCreateWithURL(chunk.url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCache: false
                  ] as CFDictionary) else {
                return NSImage(contentsOf: chunk.url)
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value

        if let image = image {
            cachedChunkImages[chunk.id] = image
            failedChunkLoads.removeValue(forKey: chunk.id)
        } else {
            // Track failed load for retry limiting
            failedChunkLoads[chunk.id] = retryCount + 1
        }
    }

    private func placeholderSection(systemName: String, text: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.15))
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func placeholderOverlay(systemName: String? = nil) -> some View {
        ZStack {
            Color.gray.opacity(0.25)
            if let systemName {
                Image(systemName: systemName)
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            } else if isLoading {
                ProgressView().progressViewStyle(.circular)
            }
        }
    }
}

// MARK: - Overlay

private struct TrimTimelineOverlay: View {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let playbackTime: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let startX = width * clampedNormalize(trimStart, duration: duration)
            let endX = width * clampedNormalize(trimEnd, duration: duration, defaultValue: 1)
            let playheadX = width * clampedNormalize(playbackTime, duration: duration)

            ZStack {
                Path { path in
                    if startX > 0 {
                        path.addRect(CGRect(x: 0, y: 0, width: startX, height: height))
                    }
                    if endX < width {
                        path.addRect(CGRect(x: endX, y: 0, width: width - endX, height: height))
                    }
                }
                .fill(Color.black.opacity(0.65))

                // Blue overlay removed for clearer thumbnail visibility
                // Orange overlay for ungenerated chunks is handled by ChunkedPreviewOverlay

                Path { path in
                    let clampedStart = min(max(startX, 0), width)
                    let clampedEnd = min(max(endX, clampedStart), width)
                    path.addRect(CGRect(x: clampedStart, y: 0, width: clampedEnd - clampedStart, height: height))
                }
                .stroke(Color.blue.opacity(0.4), lineWidth: 1)

                Path { path in
                    let clampedPlayhead = min(max(playheadX, 0), width)
                    path.move(to: CGPoint(x: clampedPlayhead, y: 0))
                    path.addLine(to: CGPoint(x: clampedPlayhead, y: height))
                }
                .stroke(Color(red: 1.0, green: 0.071, blue: 0.361), lineWidth: 2) // #FF125C
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 0)
            }
        }
    }

    private func clampedNormalize(_ value: Double, duration: Double, defaultValue: Double = 0) -> CGFloat {
        guard duration > 0 else { return CGFloat(defaultValue) }
        let normalized = value / duration
        return CGFloat(min(max(normalized, 0), 1))
    }
}

// MARK: - Scrubbing Layer

private struct TimelineScrubLayer: View {
    let duration: Double
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let step: Double
    let isRangeSelectionActive: Bool
    let isRangeSlidingActive: Bool
    let onEditingChanged: (Bool) -> Void
    let onSeek: (Double) -> Void

    private let handleWidth: CGFloat = 12  // Matches handle visual width
    private let handleMargin: CGFloat = 6  // Increased margin to compensate for thinner handle

    @State private var isScrubbing = false
    @State private var isRangeSelecting = false
    @State private var rangeStartTime: Double?

    // Range sliding state
    @State private var isRangeSliding = false
    @State private var slideInitialTrimStart: Double?
    @State private var slideInitialTrimEnd: Double?
    @State private var slideInitialClickTime: Double?

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }

                            let width = geometry.size.width
                            let clickX = value.location.x
                            let clickTime = timeForPosition(clickX, width: width)

                            // Range selection mode when R is held
                            if isRangeSelectionActive {
                                if !isRangeSelecting {
                                    // Start of range selection - set in-point
                                    isRangeSelecting = true
                                    onEditingChanged(true)
                                    let snapped = snap(clickTime)
                                    rangeStartTime = snapped
                                    trimStart = max(0, snapped)
                                    onSeek(trimStart)
                                } else {
                                    // During range selection - update out-point preview
                                    let snapped = snap(clickTime)
                                    // Temporarily update end to show visual feedback
                                    let start = rangeStartTime ?? trimStart
                                    if snapped >= start {
                                        trimEnd = min(duration, snapped)
                                    } else {
                                        // Dragging before start - swap preview
                                        trimStart = max(0, snapped)
                                        trimEnd = min(duration, start)
                                    }
                                    onSeek(snapped)
                                }
                                return
                            }

                            // Check handle proximity for scrubbing
                            let startX = position(for: trimStart, width: width)
                            let endX = position(for: trimEnd, width: width)
                            let nearStartHandle = abs(clickX - startX) < (handleWidth / 2 + handleMargin)
                            let nearEndHandle = abs(clickX - endX) < (handleWidth / 2 + handleMargin)

                            // Range sliding mode when Shift is held and click is between trim points
                            if isRangeSlidingActive && !nearStartHandle && !nearEndHandle {
                                let isBetweenTrimPoints = clickTime > trimStart && clickTime < trimEnd

                                if !isRangeSliding && isBetweenTrimPoints {
                                    // Start of range sliding
                                    isRangeSliding = true
                                    onEditingChanged(true)
                                    slideInitialTrimStart = trimStart
                                    slideInitialTrimEnd = trimEnd
                                    slideInitialClickTime = clickTime
                                } else if isRangeSliding {
                                    // During range sliding - move both points by the same delta
                                    guard let initialStart = slideInitialTrimStart,
                                          let initialEnd = slideInitialTrimEnd,
                                          let initialClick = slideInitialClickTime else { return }

                                    let delta = clickTime - initialClick
                                    let rangeDuration = initialEnd - initialStart

                                    // Calculate new positions
                                    var newStart = initialStart + delta
                                    var newEnd = initialEnd + delta

                                    // Clamp to valid bounds
                                    if newStart < 0 {
                                        newStart = 0
                                        newEnd = rangeDuration
                                    }
                                    if newEnd > duration {
                                        newEnd = duration
                                        newStart = duration - rangeDuration
                                    }

                                    // Snap to grid
                                    trimStart = snap(max(0, newStart))
                                    trimEnd = snap(min(duration, newEnd))

                                    // Seek to current position within the range
                                    onSeek(clickTime)
                                }
                                return
                            }

                            // Normal scrubbing mode - skip if near handles
                            if nearStartHandle || nearEndHandle {
                                return
                            }

                            if !isScrubbing {
                                isScrubbing = true
                            }
                            onSeek(clickTime)
                        }
                        .onEnded { value in
                            if isRangeSelecting {
                                // End of range selection - finalize out-point
                                let width = geometry.size.width
                                let clickX = value.location.x
                                let time = timeForPosition(clickX, width: width)
                                let snapped = snap(time)
                                let start = rangeStartTime ?? trimStart

                                // Ensure start < end, swap if necessary
                                if snapped >= start {
                                    trimStart = max(0, start)
                                    trimEnd = min(duration, snapped)
                                } else {
                                    trimStart = max(0, snapped)
                                    trimEnd = min(duration, start)
                                }

                                isRangeSelecting = false
                                rangeStartTime = nil
                                onEditingChanged(false)
                            }

                            if isRangeSliding {
                                // End of range sliding
                                isRangeSliding = false
                                slideInitialTrimStart = nil
                                slideInitialTrimEnd = nil
                                slideInitialClickTime = nil
                                onEditingChanged(false)
                            }

                            isScrubbing = false
                        }
                )
        }
    }

    private func position(for value: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(value / duration) * width
    }

    private func timeForPosition(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let fraction = Double(max(0, min(x, width)) / width)
        return max(0, min(duration, duration * fraction))
    }

    private func snap(_ value: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}

// MARK: - Timeline Key Tracker

/// Tracks modifier keys: Command (range selection), Shift (range sliding), Option (symmetric scaling)
private struct TimelineKeyTrackerView: NSViewRepresentable {
    @Binding var isCommandKeyPressed: Bool
    @Binding var isShiftKeyPressed: Bool
    @Binding var isOptionKeyPressed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = TimelineKeyTrackingNSView()
        view.isCommandKeyPressed = $isCommandKeyPressed
        view.isShiftKeyPressed = $isShiftKeyPressed
        view.isOptionKeyPressed = $isOptionKeyPressed
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No updates needed
    }

    @MainActor
    class TimelineKeyTrackingNSView: NSView {
        var isCommandKeyPressed: Binding<Bool>?
        var isShiftKeyPressed: Binding<Bool>?
        var isOptionKeyPressed: Binding<Bool>?

        private var flagsChangedMonitor: Any? {
            willSet {
                if let oldMonitor = flagsChangedMonitor {
                    NSEvent.removeMonitor(oldMonitor)
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window != nil {
                // Initialize from current modifier state immediately
                // This prevents "sticky" modifiers when CMD+T opens the view with CMD held
                let currentFlags = NSEvent.modifierFlags
                isCommandKeyPressed?.wrappedValue = currentFlags.contains(.command)
                isShiftKeyPressed?.wrappedValue = currentFlags.contains(.shift)
                isOptionKeyPressed?.wrappedValue = currentFlags.contains(.option)

                // Monitor modifier flags for Command, Shift, and Option
                flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                    Task { @MainActor in
                        self?.isCommandKeyPressed?.wrappedValue = event.modifierFlags.contains(.command)
                        self?.isShiftKeyPressed?.wrappedValue = event.modifierFlags.contains(.shift)
                        self?.isOptionKeyPressed?.wrappedValue = event.modifierFlags.contains(.option)
                    }
                    return event
                }
            } else {
                flagsChangedMonitor = nil
            }
        }

        override func removeFromSuperview() {
            // Clean up monitors before removal
            flagsChangedMonitor = nil
            super.removeFromSuperview()
        }
    }
}
