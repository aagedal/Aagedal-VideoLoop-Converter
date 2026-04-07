// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Foundation
import SwiftUI
import AppKit
import OSLog

actor ConversionManager: Sendable {
    @MainActor static let shared = ConversionManager()
    private init() {}

    enum ConversionStatus {
        case waiting
        case converting
        case done
        case failed
        case cancelled
    }
    

    private var isConverting = false
    private var currentProcess: Process?
    private var ffmpegConverter = FFMPEGConverter()
    private var conversionQueue: [VideoItem] = []
    private var currentDroppedFiles: Binding<[VideoItem]>?
    private var currentOutputFolder: String?
    private var currentPreset: ExportPreset = .videoLoop
    
    // Progress tracking with Swift Concurrency
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var progressStream: AsyncStream<Double>?
    // Periodic task that yields overall progress every few seconds while converting
    private var progressTimerTask: Task<Void, Never>?
    // Track URLs that have active security-scoped access during conversion
    private var activeSecurityScopedURLs: Set<URL> = []
    private struct MergePlan {
        let itemIDs: [UUID]
        let listFileURL: URL
        let outputBaseURL: URL
        let outputFolder: String
        let preset: ExportPreset
        let comment: String
        let includeDateTag: Bool
        let waveformRequest: WaveformVideoRequest?
        let synthesizedVideoRequest: SynthesizedVideoRequest?
        let segments: [MergeSegment]
        let temporaryClipURLs: [URL]
        let totalDuration: Double?
        var hasExecuted: Bool
    }

    private struct MergeSegment {
        let itemID: UUID
        let originalURL: URL
        let preparedURL: URL
        let trimStart: Double?
        let trimEnd: Double?
        let isTemporary: Bool
        let duration: Double?
    }
    private var mergePlan: MergePlan?
    private var lastMergeMetadata: [UUID: VideoMetadata] = [:]
    private let mergeLogger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MergeCompatibility")
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ConversionManager")
    
    func progressUpdates() -> AsyncStream<Double> {
        let stream = AsyncStream(Double.self) { continuation in
            // Store the continuation directly without using a weak self capture
            // since we're not mutating any actor state here
            let task = Task {
                self.setProgressContinuation(continuation)
            }
            
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.clearProgressContinuation()
                }
            }
        }
        progressStream = stream
        return stream
    }
    
    private func setProgressContinuation(_ continuation: AsyncStream<Double>.Continuation) {
        progressContinuation = continuation
    }
    
    private func clearProgressContinuation() {
        progressContinuation = nil
    }

    // MARK: - Periodic Progress Timer
        /// Starts a periodic task that emits overall progress every 3 s
    private func startProgressTimer(droppedFiles: Binding<[VideoItem]>) {
        progressTimerTask?.cancel()
        
                progressTimerTask = Task { [weak self] in
            guard let self else { return }
            while await self.isConverting {
                await self.updateOverallProgress(droppedFiles: droppedFiles)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    private func buildMergePlan(
        from items: [VideoItem],
        preset: ExportPreset,
        outputFolder: String
    ) async -> MergePlan? {
        guard case .compatible = await evaluateMergeCompatibility(for: items, preset: preset) else {
            return nil
        }

        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else { return nil }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }

        let durationLookup = buildDurationLookup(for: orderedWaitingItems, metadata: lastMergeMetadata)

        guard let (segments, temporaryFiles, totalDuration) = await prepareMergeSegments(
            from: orderedWaitingItems,
            durationLookup: durationLookup
        ) else {
            return nil
        }

        guard let listFileURL = createConcatListFile(for: segments) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        guard let firstItem = orderedWaitingItems.first else { return nil }

        let resolvedOutputFolder = VideoFileUtils.resolveOutputFolder(for: firstItem.url, defaultOutputFolder: outputFolder, preset: preset) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            mergeLogger.error("Failed to access output directory for merge: \(resolvedOutputFolder)")
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        let baseOutputURL = URL(fileURLWithPath: resolvedOutputFolder)
            .appendingPathComponent(
                FileNameProcessor.processFileName(firstItem.url.deletingPathExtension().lastPathComponent)
                + suffixPart
                + "_merge"
            )

        let waveformPreferences = AudioWaveformPreferences.loadConfig()
        let resolvedWaveformResolution = preset.resolvedWaveformResolution(defaultResolution: waveformPreferences.resolution)

        // Check if waveform generation is compatible with audio routing
        let canGenerateWaveform = {
            guard preset != .streamCopy else { return false }
            guard orderedWaitingItems.contains(where: { $0.requiresWaveformVideo }) else { return false }
            // splitToMono is incompatible with waveform video (needs 2 separate audio outputs)
            // If any audio-only item uses splitToMono, disable waveform for all
            if orderedWaitingItems.contains(where: { item in
                guard item.requiresWaveformVideo else { return false }
                if case .splitToMono = item.audioRoutingConfig?.channelOperation {
                    return true
                }
                return false
            }) {
                return false
            }
            return true
        }()

        let waveformRequest: WaveformVideoRequest? = canGenerateWaveform ? {
            return WaveformVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                foregroundHex: waveformPreferences.foregroundHex,
                normalizeAudio: waveformPreferences.normalizeAudio,
                style: waveformPreferences.style,
                frameRate: waveformPreferences.frameRate,
                renderingEngine: waveformPreferences.renderingEngine,
                swiftStyle: waveformPreferences.swiftStyle,
                bandCount: waveformPreferences.bandCount,
                frequencyDistribution: waveformPreferences.frequencyDistribution,
                foregroundGradientEnabled: waveformPreferences.foregroundGradientEnabled,
                foregroundGradientEndHex: waveformPreferences.foregroundGradientEndHex,
                backgroundGradientEnabled: waveformPreferences.backgroundGradientEnabled,
                backgroundGradientEndHex: waveformPreferences.backgroundGradientEndHex,
                waveformOpacity: waveformPreferences.waveformOpacity
            )
        }() : nil

        let synthesizedVideoRequest: SynthesizedVideoRequest? = {
            guard waveformRequest == nil else { return nil }
            guard preset.outputsVideoTrack else { return nil }
            guard orderedWaitingItems.contains(where: { !$0.hasVideoStream }) else { return nil }
            // splitToMono is incompatible with video generation (needs 2 separate audio outputs)
            if orderedWaitingItems.contains(where: { item in
                guard !item.hasVideoStream else { return false }
                if case .splitToMono = item.audioRoutingConfig?.channelOperation {
                    return true
                }
                return false
            }) {
                return nil
            }
            return SynthesizedVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                frameRate: waveformPreferences.frameRate,
                includeAudio: true
            )
        }()

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: preset,
            comment: firstItem.comment,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            segments: segments,
            temporaryClipURLs: temporaryFiles,
            totalDuration: totalDuration,
            hasExecuted: false
        )
    }

    private func prepareMergeSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double]
    ) async -> ([MergeSegment], [URL], Double?)? {
        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0

        for item in items {
            let baseDuration = durationLookup[item.id]
            let hasTrim = hasActiveTrim(item)
            let segmentDuration = resolveSegmentDuration(for: item, baseDuration: baseDuration, hasTrim: hasTrim)
            if let segmentDuration {
                totalDuration += segmentDuration
            }

            if hasTrim {
                guard let trimmedURL = await prepareTrimmedClip(for: item) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                let segment = MergeSegment(
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: trimmedURL,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: true,
                    duration: segmentDuration
                )
                segments.append(segment)
                temporaryFiles.append(trimmedURL)
            } else {
                let segment = MergeSegment(
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: item.url,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: false,
                    duration: segmentDuration
                )
                segments.append(segment)
            }
        }

        let resolvedTotal = totalDuration > 0 ? totalDuration : nil
        return (segments, temporaryFiles, resolvedTotal)
    }

    private func buildDurationLookup(for items: [VideoItem], metadata: [UUID: VideoMetadata]) -> [UUID: Double] {
        items.reduce(into: [:]) { result, item in
            if let duration = resolveBaseDuration(for: item, metadata: metadata[item.id]), duration > 0 {
                result[item.id] = duration
            }
        }
    }

    private func resolveBaseDuration(for item: VideoItem, metadata: VideoMetadata?) -> Double? {
        if let metadataDuration = metadata?.duration, metadataDuration > 0 {
            return metadataDuration
        }
        if item.durationSeconds > 0 {
            return item.durationSeconds
        }
        return nil
    }

    private func resolveSegmentDuration(for item: VideoItem, baseDuration: Double?, hasTrim: Bool) -> Double? {
        if hasTrim {
            let trimmed = max(item.trimmedDuration, 0)
            if trimmed > 0 {
                return trimmed
            }
        }
        return baseDuration
    }

    private func hasActiveTrim(_ item: VideoItem) -> Bool {
        if let trimStart = item.trimStart, trimStart > 0.0005 {
            return true
        }
        if item.trimEnd != nil {
            return true
        }
        return false
    }

    private func prepareTrimmedClip(for item: VideoItem) async -> URL? {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            mergeLogger.error("FFmpeg binary not found while preparing trimmed clip for \(item.name, privacy: .public)")
            return nil
        }

        let fileExtension = item.url.pathExtension.isEmpty ? "mp4" : item.url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimmed_\(UUID().uuidString).\(fileExtension)")

        let start = max(item.effectiveTrimStart, 0)
        let hasStartTrim = start > 0.0005
        let hasEndTrim = item.trimEnd != nil
        let duration = max(item.effectiveTrimEnd - start, 0)

        if hasEndTrim && duration <= 0.01 {
            mergeLogger.error("Invalid trim duration for \(item.name, privacy: .public). Start=\(start, privacy: .public) end=\(item.effectiveTrimEnd, privacy: .public)")
            return nil
        }

        var arguments = ["-y"]
        if hasStartTrim {
            arguments.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        arguments.append(contentsOf: ["-i", item.url.path])

        if hasEndTrim {
            arguments.append(contentsOf: ["-t", FFMPEGCommandBuilder.ffmpegTimeString(from: duration)])
        }

        arguments.append(contentsOf: ["-c", "copy", tempURL.path])

        let success = await runFFmpeg(at: ffmpegPath, arguments: arguments, context: "trim \(item.name)")
        if success {
            return tempURL
        } else {
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                mergeLogger.warning("Failed to remove temporary trim file \(tempURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    private func runFFmpeg(at executablePath: String, arguments: [String], context: String) async -> Bool {
        let logger = mergeLogger
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = Pipe()
            let errorPipe = Pipe()
            process.standardError = errorPipe

            process.terminationHandler = { process in
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus != 0 {
                    let stderr = String(data: data, encoding: .utf8) ?? "(unable to decode ffmpeg stderr)"
                    logger.error("FFmpeg \(context, privacy: .public) failed with code \(process.terminationStatus). \(stderr, privacy: .public)")
                }
                continuation.resume(returning: process.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                logger.error("Failed to launch FFmpeg \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: false)
            }
        }
    }

    private func cleanupTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                mergeLogger.warning("Failed to remove temporary file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func executeMergePlan(droppedFiles: Binding<[VideoItem]>) async {
        guard let plan = mergePlan else { return }

        let indices: [Int] = plan.itemIDs.compactMap { id in
            droppedFiles.wrappedValue.firstIndex(where: { $0.id == id })
        }

        guard indices.count == plan.itemIDs.count else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: plan.outputFolder, preset: plan.preset)
            return
        }

        await MainActor.run {
            for index in indices {
                droppedFiles.wrappedValue[index].status = .converting
                droppedFiles.wrappedValue[index].progress = 0
                droppedFiles.wrappedValue[index].eta = nil
            }
        }

        let inputItems = indices.compactMap { droppedFiles.wrappedValue[$0] }
        guard let primaryInput = inputItems.first else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            return
        }

        let customInputs = ["-f", "concat", "-safe", "0", "-i", plan.listFileURL.path]

        let mergeOutputArguments: [String]? = plan.preset == .streamCopy ? [
            "-map", "-0:d?",
            "-map", "-0:t?",
            "-ignore_unknown"
        ] : nil

        // For merges, always use the first clip's timecode as the master
        // If no timecode config is set, create one with preserveSource mode
        let mergeTimecodeConfig: TimecodeConfig? = {
            if let existing = primaryInput.timecodeConfig {
                return existing
            }
            // Auto-create a preserveSource config for merges to use first clip as master
            return TimecodeConfig(mode: .preserveSource)
        }()

        // For merges, use the first clip's audio routing as the master
        // This applies the same audio routing to the entire concatenated stream
        let mergeAudioRoutingConfig = primaryInput.audioRoutingConfig

        // For merges, use the first clip's crop settings as the master
        // The crop filter will apply to the entire concatenated stream
        // Note: Crop requires re-encoding and won't work with Stream Copy preset
        let mergeCropConfig = primaryInput.cropConfig

        let mergeRequest = ConversionRequest(
            inputURL: primaryInput.url,
            outputURL: plan.outputBaseURL,
            preset: plan.preset,
            comment: plan.comment,
            includeDateTag: plan.includeDateTag,
            expectedDuration: plan.totalDuration,
            videoFrameRate: primaryInput.metadata?.primaryVideoStream?.frameRate?.value,
            audioRoutingConfig: mergeAudioRoutingConfig,
            cropConfig: mergeCropConfig,
            timecodeConfig: mergeTimecodeConfig,
            isMuted: primaryInput.isMuted,
            waveformRequest: plan.waveformRequest,
            synthesizedVideoRequest: plan.synthesizedVideoRequest,
            waveformBackgroundImageURL: primaryInput.waveformBackgroundImageURL,
            customInputArguments: customInputs,
            additionalOutputArguments: mergeOutputArguments
        )

        await ffmpegConverter.convert(
            request: mergeRequest,
            progressUpdate: { progress, eta in
                Task { @MainActor in
                    for index in indices {
                        droppedFiles.wrappedValue[index].progress = progress
                        droppedFiles.wrappedValue[index].eta = eta
                    }
                }
            },
            completion: { success in
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleMergeCompletion(
                        plan: plan,
                        indices: indices,
                        success: success,
                        droppedFiles: droppedFiles
                    )
                }
            }
        )
    }

    private func createConcatListFile(for segments: [MergeSegment]) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat_\(UUID().uuidString).txt")
        let content = segments.map { segment -> String in
            let escapedPath = segment.preparedURL.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escapedPath)'"
        }.joined(separator: "\n")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }

    private func cleanupMergeArtifacts(for plan: MergePlan) {
        do {
            try FileManager.default.removeItem(at: plan.listFileURL)
        } catch {
            mergeLogger.warning("Failed to remove concat list file \(plan.listFileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cleanupTemporaryFiles(plan.temporaryClipURLs)
    }

    private func handleMergeCompletion(
        plan: MergePlan,
        indices: [Int],
        success: Bool,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        let referenceURL = plan.segments.first?.originalURL
        let finalURL = plan.outputBaseURL.appendingPathExtension(plan.preset.outputExtension(for: referenceURL))

        // Capture file size - try with security-scoped access
        var outputFileSizeBytes: Int64?
        if success {
            let outputFolderURL = finalURL.deletingLastPathComponent()
            let hasAccess = outputFolderURL.startAccessingSecurityScopedResource() ||
                SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputFolderURL)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let fileSize = attrs[.size] as? Int64 {
                outputFileSizeBytes = fileSize
            }
            if hasAccess {
                outputFolderURL.stopAccessingSecurityScopedResource()
            }
        }

        await MainActor.run {
            for index in indices {
                guard droppedFiles.wrappedValue.indices.contains(index) else { continue }
                if droppedFiles.wrappedValue[index].status != .cancelled {
                    droppedFiles.wrappedValue[index].status = success ? .done : .failed
                    droppedFiles.wrappedValue[index].progress = success ? 1.0 : 0.0
                    droppedFiles.wrappedValue[index].outputURL = success ? finalURL : nil
                    droppedFiles.wrappedValue[index].outputFileSizeBytes = outputFileSizeBytes
                }
            }
        }

        cleanupMergeArtifacts(for: plan)
        mergePlan = nil

        if isConverting {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset
            )
        }

        Task { @MainActor in
            if success {
                SoundManager.shared.playSuccess()
            } else {
                SoundManager.shared.playError()
            }
        }
    }


    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }

    // MARK: - Security-Scoped Resource Management

    /// Ensures an input file is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the file is accessible, false otherwise
    private func ensureInputFileAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default

        // First try: check if file is already accessible
        if fileManager.isReadableFile(atPath: url.path) {
            return true
        }

        // Second try: access via bookmark for this exact file
        if let resolvedURL = SecurityScopedBookmarkManager.shared.resolveBookmark(for: url) {
            if resolvedURL.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs.insert(resolvedURL)
                if fileManager.isReadableFile(atPath: url.path) {
                    return true
                }
                resolvedURL.stopAccessingSecurityScopedResource()
                activeSecurityScopedURLs.remove(resolvedURL)
            }
        }

        // Third try: access via bookmark for parent directory
        let parentURL = url.deletingLastPathComponent()
        if let resolvedParent = SecurityScopedBookmarkManager.shared.resolveBookmark(for: parentURL) {
            if resolvedParent.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs.insert(resolvedParent)
                if fileManager.isReadableFile(atPath: url.path) {
                    return true
                }
                resolvedParent.stopAccessingSecurityScopedResource()
                activeSecurityScopedURLs.remove(resolvedParent)
            }
        }

        // Fourth try: try starting access on the URL directly (in case it was granted via NSOpenPanel)
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.insert(url)
            if fileManager.isReadableFile(atPath: url.path) {
                return true
            }
            url.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(url)
        }

        // Fifth try: try parent URL directly
        if parentURL.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.insert(parentURL)
            if fileManager.isReadableFile(atPath: url.path) {
                return true
            }
            parentURL.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(parentURL)
        }

        logger.error("Failed to access input file with any access method: \(url.path, privacy: .public)")
        return false
    }

    /// Ensures a directory exists and is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the directory was created/accessible, false otherwise
    private func ensureDirectoryAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default

        // First try: direct access (works if we already have permission)
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            // Continue to try with bookmark access
        }

        // Second try: access via bookmark for this exact directory
        if let resolvedURL = SecurityScopedBookmarkManager.shared.resolveBookmark(for: url) {
            if resolvedURL.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs.insert(resolvedURL)
                do {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    return true
                } catch {
                    resolvedURL.stopAccessingSecurityScopedResource()
                    activeSecurityScopedURLs.remove(resolvedURL)
                }
            }
        }

        // Third try: access via bookmark for parent directory
        let parentURL = url.deletingLastPathComponent()
        if let resolvedParent = SecurityScopedBookmarkManager.shared.resolveBookmark(for: parentURL) {
            if resolvedParent.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs.insert(resolvedParent)
                do {
                    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                    return true
                } catch {
                    resolvedParent.stopAccessingSecurityScopedResource()
                    activeSecurityScopedURLs.remove(resolvedParent)
                }
            }
        }

        // Fourth try: try starting access on the URL directly (in case it was granted via NSOpenPanel)
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.insert(url)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return true
            } catch {
                url.stopAccessingSecurityScopedResource()
                activeSecurityScopedURLs.remove(url)
            }
        }

        // Fifth try: try parent URL directly
        if parentURL.startAccessingSecurityScopedResource() {
            activeSecurityScopedURLs.insert(parentURL)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return true
            } catch {
                parentURL.stopAccessingSecurityScopedResource()
                activeSecurityScopedURLs.remove(parentURL)
            }
        }

        logger.error("Failed to create directory with any access method: \(url.path, privacy: .public)")
        return false
    }

    /// Releases all security-scoped resource access acquired during conversion
    private func releaseAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func evaluateMergeCompatibility(for items: [VideoItem], preset: ExportPreset) async -> MergeCompatibilityResult {
        lastMergeMetadata = [:]
        // Filter for waiting items, excluding downloads and scheduled downloads
        let waitingItems = items.filter {
            $0.status == .waiting &&
            !$0.isDownloading &&
            $0.scheduledDownloadTime == nil &&
            !$0.isImageSequence // Image sequences are incompatible with merge
        }
        mergeLogger.debug("Evaluating merge compatibility for \(waitingItems.count) waiting clips")
        guard waitingItems.count >= 2 else {
            mergeLogger.debug("Merge incompatible: insufficient items (\(waitingItems.count))")
            return .insufficientItems(waitingItems.count)
        }

        var resolvedMetadata: [UUID: VideoMetadata] = [:]
        for item in waitingItems {
            if Task.isCancelled { return .cancelled }

            if let metadata = item.metadata {
                resolvedMetadata[item.id] = metadata
                continue
            }

            do {
                let metadata = try await VideoMetadataService.shared.metadata(for: item.url)
                resolvedMetadata[item.id] = metadata
            } catch {
                mergeLogger.debug("Merge incompatible: metadata unavailable for \(item.name, privacy: .public) – \(error.localizedDescription, privacy: .public)")
                return .metadataUnavailable(item)
            }
        }

        guard let firstItem = waitingItems.first,
              let referenceMetadata = resolvedMetadata[firstItem.id],
              !referenceMetadata.videoStreams.isEmpty else {
            mergeLogger.debug("Merge incompatible: reference clip missing video track")
            return .missingVideoTrack
        }

        let referenceVideoStreams = referenceMetadata.videoStreams
        let referenceAudio = referenceMetadata.audioStreams.first

        logMetadataSummary(for: waitingItems, metadata: resolvedMetadata)

        for item in waitingItems {
            guard let metadata = resolvedMetadata[item.id], !metadata.videoStreams.isEmpty else {
                mergeLogger.debug("Merge incompatible: \(item.name, privacy: .public) missing video track")
                return .missingVideoTrack
            }

            // Check that video stream count matches
            if metadata.videoStreams.count != referenceVideoStreams.count {
                mergeLogger.debug("Merge incompatible: video stream count mismatch for \(item.name, privacy: .public) \(metadata.videoStreams.count) vs \(referenceVideoStreams.count)")
                // If both have at least one video stream, report as codec mismatch; otherwise missing track
                if metadata.primaryVideoStream != nil && !referenceVideoStreams.isEmpty {
                    return .videoCodecMismatch(item)
                }
                return .missingVideoTrack
            }

            // Compare all video streams
            for (index, (video, referenceVideo)) in zip(metadata.videoStreams, referenceVideoStreams).enumerated() {
                if !stringsEqual(video.codec, referenceVideo.codec) {
                    mergeLogger.debug("Merge incompatible: video codec mismatch in stream \(index) \(item.name, privacy: .public) \(video.codec ?? "unknown", privacy: .public) vs \(referenceVideo.codec ?? "unknown", privacy: .public)")
                    return .videoCodecMismatch(item)
                }

                if video.width != referenceVideo.width || video.height != referenceVideo.height {
                    mergeLogger.debug("Merge incompatible: resolution mismatch in stream \(index) for \(item.name, privacy: .public) \(video.width ?? 0)x\(video.height ?? 0) vs \(referenceVideo.width ?? 0)x\(referenceVideo.height ?? 0)")
                    return .resolutionMismatch(item, expected: referenceVideo)
                }

                if !ratiosEqual(video.pixelAspectRatio, referenceVideo.pixelAspectRatio) {
                    mergeLogger.debug("Merge incompatible: pixel aspect mismatch in stream \(index) for \(item.name, privacy: .public) \(video.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public) vs \(referenceVideo.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public)")
                    return .pixelAspectMismatch(item)
                }

                if !frameRatesEqual(video.frameRate, referenceVideo.frameRate) {
                    mergeLogger.debug("Merge incompatible: frame rate mismatch in stream \(index) for \(item.name, privacy: .public) \(video.frameRate?.stringValue ?? "n/a", privacy: .public) vs \(referenceVideo.frameRate?.stringValue ?? "n/a", privacy: .public)")
                    return .frameRateMismatch(item)
                }
            }

            switch (referenceAudio, metadata.audioStreams.first) {
            case (nil, nil):
                break
            case (nil, .some), (.some, nil):
                mergeLogger.debug("Merge incompatible: audio presence mismatch for \(item.name, privacy: .public)")
                return .audioPresenceMismatch(item)
            case let (.some(refAudio), .some(audio)):
                if audio.channels != refAudio.channels {
                    mergeLogger.debug("Merge incompatible: audio channel mismatch for \(item.name, privacy: .public) \(self.describeInt(audio.channels), privacy: .public) vs \(self.describeInt(refAudio.channels), privacy: .public)")
                    return .audioChannelMismatch(item)
                }
                if audio.sampleRate != refAudio.sampleRate {
                    mergeLogger.debug("Merge incompatible: audio sample rate mismatch for \(item.name, privacy: .public) \(self.describeInt(audio.sampleRate), privacy: .public) vs \(self.describeInt(refAudio.sampleRate), privacy: .public)")
                    return .audioSampleRateMismatch(item)
                }
                if !stringsEqual(audio.codec, refAudio.codec) {
                    mergeLogger.debug("Merge incompatible: audio codec mismatch for \(item.name, privacy: .public) \(audio.codec ?? "unknown", privacy: .public) vs \(refAudio.codec ?? "unknown", privacy: .public)")
                    return .audioCodecMismatch(item)
                }
            }
        }

        mergeLogger.debug("Merge compatibility: PASSED for \(waitingItems.count) clips")
        lastMergeMetadata = resolvedMetadata
        return .compatible
    }

    private func logMetadataSummary(for items: [VideoItem], metadata: [UUID: VideoMetadata]) {
        for item in items {
            guard let data = metadata[item.id] else { continue }
            let video = data.primaryVideoStream
            let audio = data.audioStreams.first
            mergeLogger.debug(
                "Clip \(item.name, privacy: .public): videoStreams=\(data.videoStreams.count) videoCodec=\(video?.codec ?? "none", privacy: .public) resolution=\(video?.width ?? 0)x\(video?.height ?? 0) par=\(video?.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public) frameRate=\(video?.frameRate?.stringValue ?? "n/a", privacy: .public) audioCodec=\(audio?.codec ?? "none", privacy: .public) channels=\(self.describeInt(audio?.channels), privacy: .public) sampleRate=\(self.describeInt(audio?.sampleRate), privacy: .public)"
            )
        }
    }

    private func describeInt(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    enum MergeCompatibilityResult {
        case compatible
        case insufficientItems(Int)
        case metadataUnavailable(VideoItem)
        case missingVideoTrack
        case videoCodecMismatch(VideoItem)
        case resolutionMismatch(VideoItem, expected: VideoMetadata.VideoStream)
        case pixelAspectMismatch(VideoItem)
        case frameRateMismatch(VideoItem)
        case audioPresenceMismatch(VideoItem)
        case audioChannelMismatch(VideoItem)
        case audioSampleRateMismatch(VideoItem)
        case audioCodecMismatch(VideoItem)
        case cancelled

        var tooltip: String {
            switch self {
            case .compatible:
                return "Enable to merge compatible clips into one export."
            case .insufficientItems(let count):
                return count == 0 ? "Add clips to enable merging." : "Need at least two queued clips to merge."
            case .metadataUnavailable(let item):
                return "Gathering metadata for \(item.name)…"
            case .missingVideoTrack:
                return "All clips must contain a video track for merging."
            case .videoCodecMismatch:
                return "Video codec mismatch between clips."
            case .resolutionMismatch(let item, let expected):
                let expectedRes = "\(expected.width ?? 0)x\(expected.height ?? 0)"
                return "Resolution mismatch involving \(item.name). Expected \(expectedRes)."
            case .pixelAspectMismatch:
                return "Pixel aspect ratio mismatch between clips."
            case .frameRateMismatch:
                return "Frame rate mismatch between clips."
            case .audioPresenceMismatch:
                return "Some clips have audio while others do not."
            case .audioChannelMismatch:
                return "Audio channel count mismatch between clips."
            case .audioSampleRateMismatch:
                return "Audio sample rate mismatch between clips."
            case .audioCodecMismatch:
                return "Audio codec mismatch between clips."
            case .cancelled:
                return "Compatibility check cancelled."
            }
        }
    }

    private func stringsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.lowercased() ?? "") == (rhs?.lowercased() ?? "")
    }

    private func ratiosEqual(_ lhs: VideoMetadata.Ratio?, _ rhs: VideoMetadata.Ratio?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if let lhsValue = lhs.doubleValue, let rhsValue = rhs.doubleValue {
                return abs(lhsValue - rhsValue) <= 0.001
            }
            return lhs.stringValue == rhs.stringValue
        case let (nil, rhs?):
            return isUnityRatio(rhs)
        case let (lhs?, nil):
            return isUnityRatio(lhs)
        }
    }

    private func isUnityRatio(_ ratio: VideoMetadata.Ratio) -> Bool {
        if let value = ratio.doubleValue {
            return abs(value - 1.0) <= 0.001
        }
        let normalized = ratio.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
        return normalized == "1:1" || normalized == "1" || normalized == "0:1"
    }

    private func frameRatesEqual(_ lhs: VideoMetadata.FrameRate?, _ rhs: VideoMetadata.FrameRate?) -> Bool {
        switch (lhs?.value, rhs?.value) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) <= 0.01
        default: return lhs?.stringValue == rhs?.stringValue
        }
    }

    /// Converts all items in an encoding group using the group's own settings.
    /// Caller must provide the items binding and resolved group settings as plain values.
    func convertGroup(
        items: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        concatEnabled: Bool,
        transcriptionEnabled: Bool,
        uploadEnabled: Bool
    ) async {
        self.isConverting = true

        // Apply group-level transcription setting to individual items
        if transcriptionEnabled {
            await MainActor.run {
                for i in items.wrappedValue.indices {
                    items.wrappedValue[i].subtitleEnabled = true
                }
            }
        }

        if concatEnabled && items.wrappedValue.filter({ $0.status == .waiting }).count >= 2 {
            self.mergePlan = await buildMergePlan(from: items.wrappedValue, preset: preset, outputFolder: outputFolder)
        } else {
            self.mergePlan = nil
        }

        self.currentDroppedFiles = items
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset

        startProgressTimer(droppedFiles: items)
        await convertNextFile(
            droppedFiles: items,
            outputFolder: outputFolder,
            preset: preset
        )

        // Queue uploads for group items if enabled
        if uploadEnabled {
            await MainActor.run {
                UploadManager.shared.videoItems = items
            }
            for item in items.wrappedValue where item.status == .done {
                Task {
                    await UploadManager.shared.queueUpload(itemID: item.id)
                }
            }
        }
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop,
        mergeClipsEnabled: Bool = false
    ) async {
        guard !self.isConverting else { return }
        self.isConverting = true
        self.currentDroppedFiles = droppedFiles
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset
        if mergeClipsEnabled {
            self.mergePlan = await buildMergePlan(from: droppedFiles.wrappedValue, preset: preset, outputFolder: outputFolder)
        } else {
            self.mergePlan = nil
        }
        progressContinuation?.yield(0.0)
        // Start periodic updates so dock appears immediately
        startProgressTimer(droppedFiles: droppedFiles)
        await convertNextFile(
            droppedFiles: droppedFiles,
            outputFolder: outputFolder,
            preset: preset
        )
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset
    ) async {
        // Update overall progress before starting next file
        await updateOverallProgress(droppedFiles: droppedFiles)

        if let plan = mergePlan, !plan.hasExecuted {
            mergePlan?.hasExecuted = true
            await executeMergePlan(droppedFiles: droppedFiles)
            return
        }

        guard let nextFile = droppedFiles.wrappedValue.first(where: { $0.status == .waiting }) else {
            self.isConverting = false
            progressContinuation?.yield(1.0)
            stopProgressTimer()
            releaseAllSecurityScopedAccess()
            return
        }
        
        let fileId = nextFile.id
        guard let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) else {
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset)
            return
        }
        
        // Ensure details are loaded before conversion
        if !droppedFiles.wrappedValue[idx].detailsLoaded {
            let details = await VideoFileUtils.loadDetails(for: droppedFiles.wrappedValue[idx].url, outputFolder: outputFolder, preset: preset)
            droppedFiles.wrappedValue[idx].apply(details: details)
            droppedFiles.wrappedValue[idx].detailsLoaded = true
        }
        
        // Update status to converting
        droppedFiles.wrappedValue[idx].status = .converting

        let currentItem = droppedFiles.wrappedValue[idx]
        let inputURL = currentItem.url

        // Ensure input file is accessible with security-scoped access
        if !ensureInputFileAccessible(at: inputURL) {
            logger.error("Failed to access input file: \(inputURL.path, privacy: .public)")
            await MainActor.run {
                droppedFiles.wrappedValue[idx].status = .failed
                droppedFiles.wrappedValue[idx].progress = 0
            }
            await MainActor.run {
                SoundManager.shared.playError()
            }
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset)
            return
        }

        let outputFileName = outputBaseName(for: currentItem, inputURL: inputURL, preset: preset)
        let resolvedOutputFolder = VideoFileUtils.resolveOutputFolder(for: inputURL, defaultOutputFolder: outputFolder, preset: preset) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            logger.error("Failed to access output directory: \(resolvedOutputFolder, privacy: .public)")
            await MainActor.run {
                droppedFiles.wrappedValue[idx].status = .failed
                droppedFiles.wrappedValue[idx].progress = 0
            }
            await MainActor.run {
                SoundManager.shared.playError()
            }
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset)
            return
        }

        let outputURL = URL(fileURLWithPath: resolvedOutputFolder).appendingPathComponent(outputFileName)

        let waveformPreferences = AudioWaveformPreferences.loadConfig()
        let resolvedWaveformResolution = preset.resolvedWaveformResolution(defaultResolution: waveformPreferences.resolution)

        // Check if waveform generation is compatible with audio routing
        let canGenerateWaveform = {
            guard preset != .streamCopy && currentItem.requiresWaveformVideo else { return false }
            // splitToMono is incompatible with waveform video (needs 2 separate audio outputs)
            if case .splitToMono = currentItem.audioRoutingConfig?.channelOperation {
                return false
            }
            return true
        }()

        let waveformRequest: WaveformVideoRequest? = canGenerateWaveform ? {
            return WaveformVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                foregroundHex: waveformPreferences.foregroundHex,
                normalizeAudio: waveformPreferences.normalizeAudio,
                style: waveformPreferences.style,
                frameRate: waveformPreferences.frameRate,
                renderingEngine: waveformPreferences.renderingEngine,
                swiftStyle: waveformPreferences.swiftStyle,
                bandCount: waveformPreferences.bandCount,
                frequencyDistribution: waveformPreferences.frequencyDistribution,
                foregroundGradientEnabled: waveformPreferences.foregroundGradientEnabled,
                foregroundGradientEndHex: waveformPreferences.foregroundGradientEndHex,
                backgroundGradientEnabled: waveformPreferences.backgroundGradientEnabled,
                backgroundGradientEndHex: waveformPreferences.backgroundGradientEndHex,
                waveformOpacity: waveformPreferences.waveformOpacity
            )
        }() : nil

        let synthesizedVideoRequest: SynthesizedVideoRequest? = {
            guard waveformRequest == nil else { return nil }
            guard preset.outputsVideoTrack else { return nil }
            guard !currentItem.hasVideoStream else { return nil }
            // splitToMono is incompatible with video generation (needs 2 separate audio outputs)
            if case .splitToMono = currentItem.audioRoutingConfig?.channelOperation {
                return nil
            }
            return SynthesizedVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                frameRate: waveformPreferences.frameRate,
                includeAudio: true
            )
        }()

        // For image sequence input, pass the FFMPEG input arguments and expected duration
        let imageSeqInputArgs = currentItem.imageSequenceConfig?.ffmpegInputArguments
        let imageSeqExpectedDuration = currentItem.imageSequenceConfig?.durationSeconds

        let conversionRequest = ConversionRequest(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            comment: currentItem.comment,
            includeDateTag: currentItem.includeDateTag,
            sourceMetadata: currentItem.metadata,
            sourceCameraMetadata: currentItem.cameraMetadata,
            dcpMetadata: currentItem.dcpMetadata,
            trimStart: currentItem.trimStart,
            trimEnd: currentItem.trimEnd,
            expectedDuration: imageSeqExpectedDuration,
            videoFrameRate: currentItem.metadata?.primaryVideoStream?.frameRate?.value,
            audioRoutingConfig: currentItem.audioRoutingConfig,
            cropConfig: currentItem.cropConfig,
            timecodeConfig: currentItem.timecodeConfig,
            isMuted: currentItem.isMuted,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            waveformBackgroundImageURL: currentItem.waveformBackgroundImageURL,
            customInputArguments: imageSeqInputArgs
        )

        await ffmpegConverter.convert(
            request: conversionRequest,
            progressUpdate: { progress, eta in
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                        droppedFiles.wrappedValue[idx].progress = progress
                        droppedFiles.wrappedValue[idx].eta = eta
                    }
                }
            }
        ) { success in
            Task { @MainActor in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                    // Capture file size FIRST (before setting status to .done)
                    // This ensures all data is ready before SwiftUI re-renders
                    var capturedSize: Int64?
                    var outputFileURL: URL?

                    if success {
                        if preset == .imageSequence || preset == .dcp {
                            // For image sequence / DCP export, the output is a subfolder
                            // Point outputURL to the subfolder (same name as outputBaseName)
                            let subfolderName = outputURL.lastPathComponent
                            let subfolderURL = outputURL.deletingLastPathComponent().appendingPathComponent(subfolderName, isDirectory: true)
                            outputFileURL = subfolderURL

                            // Compute total size of all files in the subfolder
                            if let contents = try? FileManager.default.contentsOfDirectory(at: subfolderURL, includingPropertiesForKeys: [.fileSizeKey]) {
                                capturedSize = contents.reduce(Int64(0)) { total, fileURL in
                                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                                    return total + size
                                }
                            }
                        } else {
                            outputFileURL = outputURL.appendingPathExtension(preset.outputExtension(for: inputURL))
                        }

                        // Capture file size - try multiple approaches
                        if let url = outputFileURL, capturedSize == nil {
                            // First try: direct file access (may work if app created the file)
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                               let fileSize = attrs[.size] as? Int64 {
                                capturedSize = fileSize
                                self.logger.debug("Captured file size (direct): \(fileSize) bytes")
                            }

                            // Second try: with security-scoped access on file
                            if capturedSize == nil {
                                let hasFileAccess = url.startAccessingSecurityScopedResource()
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                   let fileSize = attrs[.size] as? Int64 {
                                    capturedSize = fileSize
                                    self.logger.debug("Captured file size (file scope): \(fileSize) bytes")
                                }
                                if hasFileAccess {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }

                            // Third try: with security-scoped access on folder via bookmark
                            if capturedSize == nil {
                                let outputFolderURL = url.deletingLastPathComponent()
                                let hasFolderAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputFolderURL)
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                   let fileSize = attrs[.size] as? Int64 {
                                    capturedSize = fileSize
                                    self.logger.debug("Captured file size (folder bookmark): \(fileSize) bytes")
                                }
                                if hasFolderAccess {
                                    SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: outputFolderURL)
                                }
                            }

                            if capturedSize == nil {
                                self.logger.warning("Failed to capture file size for: \(url.path, privacy: .public)")
                                self.logger.warning("File exists: \(FileManager.default.fileExists(atPath: url.path))")
                            }
                        }
                    }

                    // Update all properties by replacing the entire item
                    // This ensures SwiftUI detects the change
                    var updatedItem = droppedFiles.wrappedValue[idx]

                    if success, let url = outputFileURL {
                        updatedItem.outputURL = url
                        updatedItem.outputFileSizeBytes = capturedSize
                    }

                    // If user previously cancelled this item, keep it as .cancelled
                    if updatedItem.status != .cancelled {
                        updatedItem.status = success ? .done : .failed
                        updatedItem.progress = success ? 1.0 : 0
                    }

                    // Replace the entire item to ensure SwiftUI detects the change
                    droppedFiles.wrappedValue[idx] = updatedItem

                    // Debug: verify the values
                    self.logger.debug("Final state - outputFileSizeBytes: \(droppedFiles.wrappedValue[idx].outputFileSizeBytes ?? -1)")
                    self.logger.debug("Final state - formattedOutputSize: \(droppedFiles.wrappedValue[idx].formattedOutputSize ?? "nil", privacy: .public)")
                    self.logger.debug("Final state - status: \(String(describing: droppedFiles.wrappedValue[idx].status), privacy: .public)")

                    // Trigger upload if enabled for this item
                    if success && droppedFiles.wrappedValue[idx].uploadEnabled {
                        Task {
                            await UploadManager.shared.startUpload(itemID: fileId)
                        }
                    }

                    // Trigger subtitle generation if enabled for this item
                    if success && droppedFiles.wrappedValue[idx].subtitleEnabled {
                        let method = droppedFiles.wrappedValue[idx].subtitleMethod
                        if method == .ocr, let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                            // OCR reads from the original source file (PGS lives in the MKV, not the re-encode)
                            // but saves the SRT alongside the encoded output
                            let sourceURL = droppedFiles.wrappedValue[idx].url
                            let metadata  = droppedFiles.wrappedValue[idx].metadata
                            Task {
                                await self.generateOCRSubtitles(
                                    for: fileId,
                                    sourceURL: sourceURL,
                                    outputURL: outputURL,
                                    metadata: metadata,
                                    droppedFiles: droppedFiles
                                )
                            }
                        } else if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                            Task {
                                await self.generateSubtitles(
                                    for: fileId,
                                    inputURL: outputURL,
                                    droppedFiles: droppedFiles
                                )
                            }
                        }
                    }

                    // Trigger quality analytics if enabled for this item
                    if success && droppedFiles.wrappedValue[idx].analyticsEnabled {
                        if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                            let sourceURL = droppedFiles.wrappedValue[idx].url
                            Task {
                                await self.runAnalytics(
                                    for: fileId,
                                    sourceURL: sourceURL,
                                    encodedURL: outputURL,
                                    droppedFiles: droppedFiles
                                )
                            }
                        }
                    }
                }

                // Only continue if conversion has not been cancelled
                if await self.isConverting {
                    await self.convertNextFile(
                        droppedFiles: droppedFiles,
                        outputFolder: outputFolder,
                        preset: preset
                    )
                }
                
                Task { @MainActor in
                    if !success {
                        SoundManager.shared.playError()
                    } else if !(await self.isConverting) {
                        SoundManager.shared.playSuccess()
                    }
                }
            }
        }
    }

    func cancelConversion() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()
        currentProcess = nil

        // Update UI-bound items to cancelled
        if let droppedFiles = currentDroppedFiles {
            for idx in droppedFiles.wrappedValue.indices
                where droppedFiles.wrappedValue[idx].status == .converting {
                droppedFiles.wrappedValue[idx].status = .cancelled
                droppedFiles.wrappedValue[idx].progress = 0.0
            }
        }

        // Update internal queue
        for idx in conversionQueue.indices where conversionQueue[idx].status == .converting {
            conversionQueue[idx].status = .cancelled
        }
        stopProgressTimer()
        releaseAllSecurityScopedAccess()
    }
    
    /// Cancels a single video item without aborting the entire queue
    func cancelItem(with id: UUID) async {
        guard let droppedFiles = currentDroppedFiles else { return }
        
        // If the item is currently converting
        if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .converting }) {
            await ffmpegConverter.cancelConversion()
            currentProcess = nil
            droppedFiles.wrappedValue[idx].status = .cancelled
        #if DEBUG
        logger.debug("Item \(droppedFiles.wrappedValue[idx].name, privacy: .public) cancelled (was converting)")
        #endif
            droppedFiles.wrappedValue[idx].progress = 0.0
            
            // Re-compute overall progress; the existing convertNextFile call in the
            // original conversion's completion handler will continue the queue, so
            // we must NOT start a new one here to avoid parallel encodes.
            await updateOverallProgress(droppedFiles: droppedFiles)
            return
        }
        
        // If the item is still waiting, simply mark as cancelled
        if let waitingIdx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .waiting }) {
            droppedFiles.wrappedValue[waitingIdx].status = .cancelled
            #if DEBUG
            logger.debug("Item \(droppedFiles.wrappedValue[waitingIdx].name, privacy: .public) cancelled (was waiting)")
            #endif
            await updateOverallProgress(droppedFiles: droppedFiles)
        }
    }
    func cancelAllConversions() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()

        // Update UI-bound items to cancelled
        if let droppedFiles = currentDroppedFiles {
            for idx in droppedFiles.wrappedValue.indices
                where droppedFiles.wrappedValue[idx].status == .converting
                   || droppedFiles.wrappedValue[idx].status == .waiting {
                droppedFiles.wrappedValue[idx].status = .cancelled
                droppedFiles.wrappedValue[idx].progress = 0.0
            }
        }

        // Clear internal queue
        conversionQueue.removeAll()
        progressContinuation?.yield(0.0)
        stopProgressTimer()
        releaseAllSecurityScopedAccess()
    }
    
    // Convert duration string ("hh:mm:ss" or "mm:ss" or "ss") to seconds
    private func timeStringToSeconds(_ str: String) -> Double {
        let components = str.split(separator: ":").map { Double($0) ?? 0 }
        switch components.count {
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        case 2:
            return components[0] * 60 + components[1]
        case 1:
            return components[0]
        default:
            return 0
        }
    }
    
    private func updateOverallProgress(droppedFiles: Binding<[VideoItem]>) async {
        #if DEBUG
        logger.debug("updateOverallProgress called")
        #endif
        let files = droppedFiles.wrappedValue
        
        // Filter out cancelled items
        #if DEBUG
        logger.debug("Files: \(files.map { ($0.name, $0.status, $0.durationSeconds, $0.progress) }, privacy: .public)")
        #endif
        let activeFiles = files.filter { $0.status != .cancelled && $0.status != .failed }
        
        guard !activeFiles.isEmpty else {
            progressContinuation?.yield(0.0)
            return
        }

        // Total duration of active files (seconds)
        let totalDuration = activeFiles.reduce(0.0) { sum, file in
            sum + file.trimmedDuration
        }
        guard totalDuration > 0 else {
            progressContinuation?.yield(0.0)
            return
        }

        // Completed duration so far (seconds)
        let completedDuration = activeFiles.reduce(0.0) { sum, file in
            let durSec = file.trimmedDuration
            switch file.status {
            case .done:
                return sum + durSec
            case .converting:
                return sum + durSec * file.progress
            default:
                return sum
            }
        }
        let progress = min(max(completedDuration / totalDuration, 0.0), 1.0)
        #if DEBUG
        logger.debug("totalDuration: \(totalDuration) s, completedDuration: \(completedDuration) s, overallProgress: \(progress * 100)%")
        #endif
        progressContinuation?.yield(progress)
    }

    // MARK: - Subtitle Generation

    /// Generates subtitles for a completed conversion
    private func generateSubtitles(
        for itemID: UUID,
        inputURL: URL,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        // Get selected model and language from settings
        let modelRaw = UserDefaults.standard.string(forKey: AppConstants.whisperModelKey) ?? AppConstants.defaultWhisperModel
        let model = WhisperModel(rawValue: modelRaw) ?? .base
        let language = UserDefaults.standard.string(forKey: AppConstants.whisperLanguageKey) ?? AppConstants.defaultWhisperLanguage

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].subtitleStatus = .pending
            }
        }

        // Verify model is downloaded
        guard WhisperModelManager.shared.isModelDownloaded(model) else {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("Model not downloaded")
                }
            }
            return
        }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await WhisperService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                audioStreamIndex: audioStreamIndex
            ) { [weak self] whisperProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                        switch whisperProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: whisperProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        default:
                            break
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = whisperProgress.percentage
                    }
                }
            }

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                }
            }

            logger.info("Subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                }
            }
            logger.error("Subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - OCR Subtitle Generation

    /// Converts bitmap subtitle stream in the source MKV to SRT using Tesseract OCR.
    /// Saves the SRT alongside the encoded output file.
    private func generateOCRSubtitles(
        for itemID: UUID,
        sourceURL: URL,
        outputURL: URL,
        metadata: VideoMetadata?,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        // Identify the chosen (or first) bitmap subtitle stream
        let chosenStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedBitmapSubtitleStreamIndex
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub"]
        guard let stream = metadata?.subtitleStreams.first(where: {
            if let chosen = chosenStreamIndex { return $0.index == chosen }
            return bitmapCodecs.contains($0.codec?.lowercased() ?? "")
        }) else {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("No bitmap subtitle stream found")
                }
            }
            return
        }

        let streamIndex = stream.index ?? 0
        let codec = stream.codec ?? "pgssub"

        // Language: stream language → user default → "eng"
        let streamLang = stream.languageCode
        let language = streamLang
            ?? UserDefaults.standard.string(forKey: AppConstants.tesseractLanguageKey)
            ?? AppConstants.defaultTesseractLanguage

        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].subtitleStatus = .pending
            }
        }

        do {
            // Save SRT alongside the encoded output (mirrors Whisper behaviour)
            let outputDir = outputURL.deletingLastPathComponent()
            let srtURL = try await TesseractService.shared.generateSubtitles(
                sourceFile: sourceURL,
                outputDirectory: outputDir,
                subtitleStreamIndex: streamIndex,
                codec: codec,
                language: language
            ) { [weak self] ocrProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                        switch ocrProgress.stage {
                        case .extractingTrack:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .parsingFrames:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .recognizing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        case .writingSRT:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = ocrProgress.percentage
                    }
                }
            }

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                }
            }

            logger.info("OCR subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                }
            }
            logger.error("OCR subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Quality Analytics

    /// Runs quality analytics for a completed conversion
    private func runAnalytics(
        for itemID: UUID,
        sourceURL: URL,
        encodedURL: URL,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        // Load analytics config from settings
        let enabledMetricsRaw = UserDefaults.standard.stringArray(forKey: AppConstants.analyticsEnabledMetricsKey)
            ?? AppConstants.defaultAnalyticsEnabledMetrics
        let enabledMetrics = enabledMetricsRaw.compactMap { QualityMetric(rawValue: $0) }
        let vmafModelRaw = UserDefaults.standard.string(forKey: AppConstants.analyticsVMAFModelKey)
            ?? AppConstants.defaultAnalyticsVMAFModel
        let vmafModel = VMAFModel(rawValue: vmafModelRaw) ?? .vmaf_v0_6_1

        guard !enabledMetrics.isEmpty else { return }

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].analyticsStatus = .pending
            }
        }

        do {
            let results = try await AnalyticsService.shared.runAnalytics(
                sourceFile: sourceURL,
                encodedFile: encodedURL,
                enabledMetrics: enabledMetrics,
                vmafModel: vmafModel
            ) { metric, progressValue in
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                        droppedFiles.wrappedValue[idx].analyticsStatus = .running(metric: metric, progress: progressValue)
                        droppedFiles.wrappedValue[idx].analyticsProgress = progressValue
                    }
                }
            }

            let durationSeconds = await MainActor.run {
                droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.durationSeconds ?? 0
            }

            let analyticsResults = AnalyticsResults(
                sourceFileName: sourceURL.lastPathComponent,
                encodedFileName: encodedURL.lastPathComponent,
                metrics: results,
                timestamp: Date(),
                durationSeconds: durationSeconds
            )

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].analyticsStatus = .completed
                    droppedFiles.wrappedValue[idx].analyticsResults = analyticsResults
                    droppedFiles.wrappedValue[idx].analyticsProgress = 1.0
                }
            }

            logger.info("Quality analytics completed for \(encodedURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].analyticsStatus = .failed(error.localizedDescription)
                }
            }
            logger.error("Quality analytics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func outputBaseName(for item: VideoItem, inputURL: URL, preset: ExportPreset) -> String {
        if let override = item.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let baseName = (override as NSString).deletingPathExtension
            return FileNameProcessor.processFileName(baseName)
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(inputURL.deletingPathExtension().lastPathComponent)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
        return sanitizedBaseName + suffixPart
    }
}
