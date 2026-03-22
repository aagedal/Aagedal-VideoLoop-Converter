// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

private actor StderrCollector {
    private var buffer = Data()
    func append(_ data: Data) {
        buffer.append(data)
    }

    func snapshot() -> Data {
        buffer
    }
}

actor FFMPEGConverter {
    private var currentProcess: Process?

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FFMPEGConverter")

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - inputURL: The source video file URL
    ///   - outputURL: The destination URL (without extension)
    ///   - preset: The export preset to use
    ///   - comment: The comment to be added to the metadata
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool)
    func convert(
        inputURL: URL,
        outputURL: URL,
        preset: ExportPreset = .videoLoop,
        comment: String = "",
        includeDateTag: Bool = true,
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        cropConfig: CropConfig? = nil,
        timecodeConfig: TimecodeConfig? = nil,
        waveformRequest: WaveformVideoRequest? = nil,
        synthesizedVideoRequest: SynthesizedVideoRequest? = nil,
        customInputArguments: [String]? = nil,
        additionalOutputArguments: [String]? = nil,
        isMuted: Bool = false,
        expectedDuration: Double? = nil,
        videoFrameRate: Double? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) async {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            print("FFMPEG binary not found")
            completion(false)
            return
        }

        // Ensure output directory exists
        let fileManager = FileManager.default
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create output directory: \(error)")
            completion(false)
            return
        }

        // Add file extension based on preset
        var outputFileURL = outputURL.appendingPathExtension(preset.outputExtension(for: inputURL))

        // CRITICAL: Ensure we never overwrite the source file
        if outputFileURL.standardizedFileURL == inputURL.standardizedFileURL {
            // Add "_encoded" suffix to prevent overwriting source
            let baseName = outputURL.lastPathComponent
            let safeOutputURL = outputDir.appendingPathComponent(baseName + "_encoded")
                .appendingPathExtension(preset.outputExtension(for: inputURL))
            print("⚠️ Safety check: Would have overwritten input file. Changed output to: \(safeOutputURL.lastPathComponent)")
            outputFileURL = safeOutputURL
        }

        // Ensure unique output path (don't overwrite existing files)
        outputFileURL = FileSafetyUtils.uniqueOutputURL(outputFileURL, notOverwriting: inputURL)

        // Register this file as created by the app (for safe deletion later if needed)
        FileSafetyUtils.registerCreatedFile(outputFileURL)

        // For AVC-Intra MXF, FFmpeg outputs to temp file, then bmxtranswrap rewraps to OP1a
        let needsBMXRewrap = preset == .tvAVCIntra
        var ffmpegOutputURL = outputFileURL
        var tempMXFURL: URL? = nil

        if needsBMXRewrap {
            // Create temp file for FFmpeg output
            let tempDir = FileManager.default.temporaryDirectory
            tempMXFURL = tempDir.appendingPathComponent("ffmpeg_mxf_\(UUID().uuidString).mxf")
            ffmpegOutputURL = tempMXFURL!
            Self.logger.info("AVC-Intra: FFmpeg will output to temp file for OP1a rewrap")
        }

        // Check if we need audio pre-processing for AVC-Intra with audio-only files
        // This creates a temp file with mono-split audio channels first
        var effectiveInputURL = inputURL
        var effectiveCustomInputArguments = customInputArguments
        var tempAudioURL: URL? = nil

        if needsAudioPreProcessing(preset: preset, waveformRequest: waveformRequest, synthesizedVideoRequest: synthesizedVideoRequest) {
            Self.logger.info("Audio-only file with AVC-Intra preset detected, running audio pre-processing pass")

            if let preProcessedURL = await preProcessAudioForAVCIntra(
                inputURL: inputURL,
                ffmpegPath: ffmpegPath,
                trimStart: trimStart,
                trimEnd: trimEnd
            ) {
                tempAudioURL = preProcessedURL
                effectiveInputURL = preProcessedURL
                // Use the pre-processed file as input
                effectiveCustomInputArguments = ["-i", preProcessedURL.path]
                Self.logger.info("Audio pre-processing complete: \(preProcessedURL.lastPathComponent)")
            } else {
                Self.logger.error("Audio pre-processing failed, falling back to standard conversion")
            }
        }

        // MARK: Native waveform rendering branch (Swift engine)
        if let waveformRequest, waveformRequest.renderingEngine == .swift {
            await runNativeWaveformConversion(
                inputURL: inputURL,
                ffmpegOutputURL: ffmpegOutputURL,
                ffmpegPath: ffmpegPath,
                preset: preset,
                waveformRequest: waveformRequest,
                audioRoutingConfig: audioRoutingConfig,
                trimStart: trimStart,
                trimEnd: trimEnd,
                comment: comment,
                includeDateTag: includeDateTag,
                isMuted: isMuted,
                additionalOutputArguments: additionalOutputArguments,
                expectedDuration: expectedDuration,
                videoFrameRate: videoFrameRate,
                needsBMXRewrap: needsBMXRewrap,
                tempMXFURL: tempMXFURL,
                outputFileURL: outputFileURL,
                progressUpdate: progressUpdate,
                completion: completion
            )
            return
        }

        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        // Build FFmpeg arguments
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: effectiveInputURL,
            outputFileURL: ffmpegOutputURL,  // Use temp file for AVC-Intra, final file otherwise
            preset: preset,
            comment: comment,
            includeDateTag: includeDateTag,
            trimStart: tempAudioURL != nil ? nil : trimStart,  // Trim already applied in pre-processing
            trimEnd: tempAudioURL != nil ? nil : trimEnd,
            audioRoutingConfig: tempAudioURL != nil ? nil : audioRoutingConfig,  // Audio already processed
            cropConfig: cropConfig,
            timecodeConfig: timecodeConfig,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            customInputArguments: effectiveCustomInputArguments,
            additionalOutputArguments: additionalOutputArguments,
            isMuted: isMuted
        )

        process.arguments = command.arguments

        print("FFmpeg command: \(ffmpegPath) \(command.arguments.joined(separator: " "))")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice  // Prevent FFmpeg from waiting for stdin

        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        effectiveDurationBox.value = command.effectiveDuration
        if let expectedDuration {
            totalDurationBox.value = expectedDuration
            if effectiveDurationBox.value == nil {
                effectiveDurationBox.value = expectedDuration
            }
        }
        let stderrCollector = StderrCollector()
        let frameStallTracker = FrameStallTracker()
        let frameRate = videoFrameRate ?? 24.0  // Default to 24fps if not provided

        let errorReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Process the output through our handler
                let (newTotalDuration, _) = FFMPEGProgressParser.handleOutput(
                    output,
                    totalDuration: totalDurationBox.value,
                    effectiveDuration: effectiveDurationBox.value,
                    frameRate: frameRate,
                    frameStallTracker: frameStallTracker,
                    progressUpdate: progressUpdate
                )
                if let newTotalDuration = newTotalDuration {
                    totalDurationBox.value = newTotalDuration
                    // Set effective duration if not already set
                    if effectiveDurationBox.value == nil {
                        effectiveDurationBox.value = newTotalDuration
                    }
                }
            }

            if !data.isEmpty {
                Task { await stderrCollector.append(data) }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = errorReadabilityHandler

        // Capture values for the closure
        let capturedTempAudioURL = tempAudioURL
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent

        process.terminationHandler = { [weak self] _ in
            // Stop the readability handler to prevent log spam after process ends
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task { [weak self] in
                await self?.setCurrentProcess(nil)
                var success = process.terminationStatus == 0
                print("✅ FFmpeg process terminated with status: \(process.terminationStatus) (success: \(success))")
                if !success {
                    let collectedStderr = await stderrCollector.snapshot()
                    let stderrString = String(data: collectedStderr, encoding: .utf8) ?? "(unable to decode ffmpeg stderr)"
                    print("FFmpeg exited with code \(process.terminationStatus). Output:\n\(stderrString)\n-- end of ffmpeg log --")
                }

                // Run bmxtranswrap for AVC-Intra to ensure OP1a compliance
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap to rewrap MXF to OP1a format")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    let bmxSuccess = await BMXService.shared.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        progress: { bmxProgress in
                            // Map bmx progress to 95-100% range
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                progressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )

                    if bmxSuccess {
                        Self.logger.info("bmxtranswrap completed: \(capturedFinalOutputURL.lastPathComponent)")
                    } else {
                        Self.logger.error("bmxtranswrap failed, keeping FFmpeg output as fallback")
                        // Copy temp file to final location as fallback
                        do {
                            try FileManager.default.copyItem(at: tempMXF, to: capturedFinalOutputURL)
                            Self.logger.warning("Used FFmpeg MXF output as fallback (not OP1a compliant)")
                        } catch {
                            Self.logger.error("Failed to copy fallback MXF: \(error.localizedDescription)")
                            success = false
                        }
                    }

                    // Clean up temp MXF file
                    try? FileManager.default.removeItem(at: tempMXF)
                    Self.logger.debug("Cleaned up temp MXF file")
                }

                // Clean up temp audio file if it exists
                if let tempURL = capturedTempAudioURL {
                    try? FileManager.default.removeItem(at: tempURL)
                    Self.logger.debug("Cleaned up temp audio file: \(tempURL.lastPathComponent)")
                }

                completion(success)
            }
        }

        do {
            try process.run()
        } catch {
            print("Failed to run process: \(error)")
            completion(false)
        }
    }

    // MARK: - Native Waveform Conversion (Swift Renderer)

    /// Runs the native waveform pipeline: decode PCM → FFT → Swift-rendered frames → pipe to FFmpeg.
    private func runNativeWaveformConversion(
        inputURL: URL,
        ffmpegOutputURL: URL,
        ffmpegPath: String,
        preset: ExportPreset,
        waveformRequest: WaveformVideoRequest,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?,
        comment: String,
        includeDateTag: Bool,
        isMuted: Bool,
        additionalOutputArguments: [String]?,
        expectedDuration: Double?,
        videoFrameRate: Double?,
        needsBMXRewrap: Bool,
        tempMXFURL: URL?,
        outputFileURL: URL,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) async {
        Self.logger.info("Starting native waveform conversion (Swift engine)")

        // Compute effective duration for the render
        let effectiveDuration: Double
        if let trimStart, let trimEnd, trimEnd > trimStart {
            effectiveDuration = trimEnd - trimStart
        } else if let expected = expectedDuration {
            effectiveDuration = expected
        } else if let duration = await FFMPEGProbeService.getVideoDuration(for: inputURL) {
            effectiveDuration = duration
        } else {
            Self.logger.error("Cannot determine audio duration for native waveform")
            completion(false)
            return
        }

        // Phase 1: Decode audio and compute frequency bands (~10% of progress)
        progressUpdate(0.02, "Analyzing audio…")
        let frequencyData: FrequencyBandData
        do {
            frequencyData = try await WaveformPCMDecoder.decode(
                url: inputURL,
                ffmpegPath: ffmpegPath,
                frameRate: waveformRequest.frameRate,
                duration: effectiveDuration,
                bandCount: waveformRequest.bandCount,
                frequencyDistribution: waveformRequest.frequencyDistribution,
                normalizeAudio: waveformRequest.normalizeAudio,
                audioRoutingConfig: audioRoutingConfig,
                trimStart: trimStart,
                trimEnd: trimEnd
            )
        } catch {
            Self.logger.error("PCM decode/FFT failed: \(error.localizedDescription)")
            completion(false)
            return
        }

        progressUpdate(0.10, "Rendering waveform…")

        // Phase 2: Build FFmpeg encoding command with rawvideo pipe input
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: inputURL,
            outputFileURL: ffmpegOutputURL,
            preset: preset,
            width: waveformRequest.width,
            height: waveformRequest.height,
            frameRate: waveformRequest.frameRate,
            audioRoutingConfig: audioRoutingConfig,
            trimStart: trimStart,
            trimEnd: trimEnd,
            isMuted: isMuted,
            comment: comment,
            includeDateTag: includeDateTag,
            additionalOutputArguments: additionalOutputArguments
        )

        // Phase 3: Start FFmpeg with stdin pipe for video frames
        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = command.arguments

        let stdinPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        print("FFmpeg native waveform command: \(ffmpegPath) \(command.arguments.joined(separator: " "))")

        let stderrCollector = StderrCollector()
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent

        // Monitor stderr for encoding progress (secondary to our frame-based progress)
        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                Task { await stderrCollector.append(data) }
            }
        }

        process.terminationHandler = { [weak self] _ in
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task { [weak self] in
                await self?.setCurrentProcess(nil)
                var success = process.terminationStatus == 0
                Self.logger.info("Native waveform FFmpeg terminated with status: \(process.terminationStatus)")

                if !success {
                    let collectedStderr = await stderrCollector.snapshot()
                    let stderrString = String(data: collectedStderr, encoding: .utf8) ?? "(unable to decode)"
                    print("FFmpeg native waveform stderr:\n\(stderrString)\n-- end --")
                }

                // BMX rewrap for AVC-Intra if needed
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap for native waveform output")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    let bmxSuccess = await BMXService.shared.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        progress: { bmxProgress in
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                progressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )

                    if !bmxSuccess {
                        Self.logger.error("bmxtranswrap failed for native waveform")
                        do {
                            try FileManager.default.copyItem(at: tempMXF, to: capturedFinalOutputURL)
                        } catch {
                            success = false
                        }
                    }
                    try? FileManager.default.removeItem(at: tempMXF)
                }

                completion(success)
            }
        }

        do {
            try process.run()
        } catch {
            print("Failed to start native waveform FFmpeg: \(error)")
            completion(false)
            return
        }

        // Phase 4: Write rendered frames to the pipe on a background task
        Task.detached { [frequencyData, waveformRequest] in
            await WaveformFramePipeWriter.writeFrames(
                to: stdinPipe,
                frequencyData: frequencyData,
                style: waveformRequest.swiftStyle,
                width: waveformRequest.width,
                height: waveformRequest.height,
                foregroundHex: waveformRequest.foregroundHex,
                backgroundHex: waveformRequest.backgroundHex,
                progressUpdate: { renderProgress in
                    // Map render progress to 10%–95% of overall progress
                    let overall = 0.10 + renderProgress * 0.85
                    progressUpdate(overall, "Rendering waveform…")
                }
            )
        }
    }

    func cancelConversion() async {
        currentProcess?.terminate()
        await setCurrentProcess(nil)
    }

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
    }

    private class DurationBox: @unchecked Sendable {
        var value: Double? = nil
    }

    static func getVideoDuration(url: URL) async -> Double? {
        await FFMPEGProbeService.getVideoDuration(for: url)
    }

    // MARK: - Audio Pre-Processing for AVC-Intra

    /// Checks if audio pre-processing is needed for AVC-Intra with audio-only files.
    /// This is required because the waveform/synthesized video pipeline's filter_complex
    /// conflicts with AVC-Intra's mono channel splitting filter_complex.
    private func needsAudioPreProcessing(
        preset: ExportPreset,
        waveformRequest: WaveformVideoRequest?,
        synthesizedVideoRequest: SynthesizedVideoRequest?
    ) -> Bool {
        guard preset == .tvAVCIntra else { return false }
        // Only needed for audio-only files (which use waveform or synthesized video)
        return waveformRequest != nil || synthesizedVideoRequest != nil
    }

    /// Pre-processes audio for AVC-Intra by splitting stereo to mono channels.
    /// Creates a temp MKA file with the target number of mono audio streams.
    /// - Returns: URL of the temp file, or nil if pre-processing failed
    private func preProcessAudioForAVCIntra(
        inputURL: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?
    ) async -> URL? {
        // Get target channel count from settings
        let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey)
            ?? AppConstants.defaultAVCIntraAudioChannels
        let audioChannels = AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8
        let targetChannelCount = audioChannels.count

        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("avc_audio_\(UUID().uuidString)").appendingPathExtension("mka")

        // Get audio stream info
        let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL) ?? []
        let decodableStreams = audioStreams.filter { $0.isDecodable }

        // Build FFmpeg command for audio pre-processing
        var args: [String] = ["-y"]

        // Add trim if specified
        if let start = trimStart, start > 0 {
            args.append(contentsOf: ["-ss", String(format: "%.3f", start)])
        }

        args.append(contentsOf: ["-i", inputURL.path])

        // Add duration if trim end specified
        if let start = trimStart, let end = trimEnd, end > start {
            args.append(contentsOf: ["-t", String(format: "%.3f", end - start)])
        } else if let end = trimEnd, end > 0 {
            args.append(contentsOf: ["-to", String(format: "%.3f", end)])
        }

        // Build filter graph for mono splitting
        var filterParts: [String] = []
        var monoOutputs: [String] = []
        var outputIndex = 0

        if decodableStreams.isEmpty {
            // No audio streams - create silent mono channels
            // Use aevalsrc for silence generation
            filterParts.append("aevalsrc=0:c=mono:s=48000:d=3600[silentsrc]")

            if targetChannelCount == 1 {
                monoOutputs.append("silentsrc")
            } else {
                var silentLabels: [String] = []
                for i in 0..<targetChannelCount {
                    silentLabels.append("silent\(i)")
                }
                filterParts.append("[silentsrc]asplit=\(targetChannelCount)\(silentLabels.map { "[\($0)]" }.joined())")
                monoOutputs.append(contentsOf: silentLabels)
            }
        } else {
            // Process each audio stream
            for (audioPosition, stream) in audioStreams.enumerated() {
                guard stream.isDecodable else { continue }

                let channels = stream.channels ?? 2

                if channels == 1 {
                    // Mono stream - use directly
                    let outputLabel = "mono\(outputIndex)"
                    filterParts.append("[0:a:\(audioPosition)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(outputLabel)]")
                    monoOutputs.append(outputLabel)
                    outputIndex += 1
                } else {
                    // Multi-channel stream - split to mono
                    let splitLayout: String
                    if channels == 2 {
                        splitLayout = "stereo"
                    } else if channels == 6 {
                        splitLayout = "5.1"
                    } else if channels == 8 {
                        splitLayout = "7.1"
                    } else {
                        splitLayout = stream.channelLayout ?? "stereo"
                    }

                    var channelLabels: [String] = []
                    for ch in 0..<channels {
                        channelLabels.append("s\(audioPosition)c\(ch)")
                    }
                    let outputLabelsStr = channelLabels.map { "[\($0)]" }.joined()

                    filterParts.append("[0:a:\(audioPosition)]channelsplit=channel_layout=\(splitLayout)\(outputLabelsStr)")

                    // Format each split channel
                    for label in channelLabels {
                        let formattedLabel = "mono\(outputIndex)"
                        filterParts.append("[\(label)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(formattedLabel)]")
                        monoOutputs.append(formattedLabel)
                        outputIndex += 1
                    }
                }
            }

            // Pad with silent channels if needed
            let availableChannels = monoOutputs.count
            if availableChannels < targetChannelCount && availableChannels > 0 {
                let silentChannelsNeeded = targetChannelCount - availableChannels

                // Use first channel as template for silence
                let templateLabel = monoOutputs[0]
                let templateForOutput = "\(templateLabel)_out"
                let templateForSilent = "\(templateLabel)_silent"

                filterParts.append("[\(templateLabel)]asplit=2[\(templateForOutput)][\(templateForSilent)]")
                monoOutputs[0] = templateForOutput

                var silentLabels: [String] = []
                for i in 0..<silentChannelsNeeded {
                    silentLabels.append("silent\(availableChannels + i)")
                }

                if silentChannelsNeeded == 1 {
                    filterParts.append("[\(templateForSilent)]volume=0[\(silentLabels[0])]")
                } else {
                    let silentBaseLabel = "silentbase"
                    filterParts.append("[\(templateForSilent)]volume=0[\(silentBaseLabel)]")
                    let splitOutputs = silentLabels.map { "[\($0)]" }.joined()
                    filterParts.append("[\(silentBaseLabel)]asplit=\(silentChannelsNeeded)\(splitOutputs)")
                }

                monoOutputs.append(contentsOf: silentLabels)
            }
        }

        // Truncate if we have more channels than needed
        let finalOutputs = Array(monoOutputs.prefix(targetChannelCount))

        // Build the command
        let filterGraph = filterParts.joined(separator: ";")
        args.append(contentsOf: ["-filter_complex", filterGraph])

        // Map each mono output
        for output in finalOutputs {
            args.append(contentsOf: ["-map", "[\(output)]"])
        }

        // Audio codec settings
        args.append(contentsOf: ["-c:a", "pcm_s24le"])
        args.append(tempURL.path)

        Self.logger.debug("Audio pre-processing command: ffmpeg \(args.joined(separator: " "))")

        // Run the pre-processing
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                Self.logger.info("Audio pre-processing succeeded: \(targetChannelCount) mono channels created")
                return tempURL
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "(unknown error)"
                Self.logger.error("Audio pre-processing failed with code \(process.terminationStatus): \(errorString)")
                return nil
            }
        } catch {
            Self.logger.error("Failed to run audio pre-processing: \(error.localizedDescription)")
            return nil
        }
    }
}
