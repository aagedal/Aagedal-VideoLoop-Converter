// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import CoreGraphics
import os
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
    /// Secondary process for multi-process pipelines (e.g. the AV2 ffmpeg→avmenc pipe).
    /// Tracked separately so `cancelConversion()` can terminate both halves.
    private var auxProcess: Process?

    /// Live ffmpeg/avmenc processes for the parallel chunked AV2 encode (one ffmpeg + one avmenc
    /// per chunk). Tracked as a set so `cancelConversion()` and the inter-worker abort path can
    /// terminate every worker. Each worker removes its own pair once it exits.
    private var av2Workers: Set<Process> = []

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FFMPEGConverter")

    // MARK: - Temp File Cleanup

    /// Removes a temporary file with proper error logging instead of silently swallowing failures.
    /// Silent `try?` on file removal can hide disk space leaks that accumulate over many conversions.
    private static func cleanupTempFile(at url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - AVC-Intra MCA Labels

    /// Builds an MCA labels temp file for the AVC-Intra OP1a rewrap.
    ///
    /// Returns nil if no useful labels can be derived (caller should rewrap without
    /// the labels flag in that case, preserving today's behavior). Mirrors the
    /// AVC-Intra mono-split layout in `FFMPEGCommandBuilder.adjustAVCIntraAudio`:
    /// each input audio channel becomes one mono output track in input order.
    private static func prepareAVCIntraMCALabelsFile(
        inputURL: URL,
        audioRoutingConfig: AudioRoutingConfig?
    ) async -> URL? {
        let allStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL) ?? []
        // Walk the unfiltered list so audio-relative indices match the routing UI
        // (which sees every audio stream, decodable or not). Only decodable streams
        // produce output tracks, but the override key must use the original index.
        let inputInfos = allStreams.enumerated().compactMap { (audioRelIdx, stream) -> MCALabelsBuilder.InputStreamInfo? in
            guard stream.isDecodable else { return nil }
            return MCALabelsBuilder.InputStreamInfo(
                audioRelativeIndex: audioRelIdx,
                channelCount: stream.channels ?? 0,
                channelLayout: stream.channelLayout,
                sampleRate: nil  // FFprobe basic info doesn't expose sampleRate; positional matching is reliable here
            )
        }
        guard !inputInfos.isEmpty else { return nil }

        // Read input MCA labels via mxf2raw only when the input is itself MXF.
        let mcaLabels: [AudioTrackMCALabels]
        if inputURL.pathExtension.lowercased() == "mxf" {
            mcaLabels = await BMXService.shared.getAudioTrackLabels(url: inputURL) ?? []
        } else {
            mcaLabels = []
        }

        // Collect manual overrides from the routing UI's output tracks. When more than
        // one output track points at the same input stream, the FIRST non-empty override
        // wins so the result is deterministic.
        var overrides: [Int: MCALabelOverride] = [:]
        if let routing = audioRoutingConfig {
            for outputTrack in routing.outputTracks {
                guard let override = outputTrack.mcaOverride, !override.isEmpty else { continue }
                if overrides[outputTrack.streamIndex] == nil {
                    overrides[outputTrack.streamIndex] = override
                }
            }
        }

        let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey)
            ?? AppConstants.defaultAVCIntraAudioChannels
        let targetChannelCount = (AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8).count

        guard let content = MCALabelsBuilder.buildAVCIntraLabelsFile(
            inputStreams: inputInfos,
            inputMCALabels: mcaLabels,
            overrides: overrides,
            outputTrackCount: targetChannelCount
        ) else {
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-labels-\(UUID().uuidString).txt")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            logger.info("Wrote MCA labels file for \(inputURL.lastPathComponent, privacy: .public) at \(tempURL.path, privacy: .public)")
            return tempURL
        } catch {
            logger.error("Failed to write MCA labels file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Output Validation

    /// Validates that an output file exists and has a non-zero size after FFmpeg reports success.
    /// FFmpeg can exit with status 0 while producing empty or corrupt output (e.g., disk full,
    /// interrupted I/O, or edge-case codec errors that don't set a non-zero exit code).
    private static func validateOutputFile(at url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return "Output file was not created"
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            if fileSize == 0 {
                return "Output file is empty (0 bytes)"
            }
            logger.info("Output validated: \(url.lastPathComponent, privacy: .public) (\(fileSize) bytes)")
        } catch {
            return "Cannot read output file attributes: \(error.localizedDescription)"
        }
        return nil
    }

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - request: All conversion parameters bundled in a ConversionRequest
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool, errorReason: String?)
    func convert(
        request: ConversionRequest,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) async {
        // Destructure frequently-used fields for readability
        let inputURL = request.inputURL
        let outputURL = request.outputURL
        let preset = request.preset
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            Self.logger.error("FFMPEG binary not found")
            completion(false, "FFmpeg binary not found")
            return
        }

        // Ensure output directory exists
        let fileManager = FileManager.default
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create output directory: \(error.localizedDescription, privacy: .public)")
            completion(false, "Failed to create output directory")
            return
        }

        // Image sequence / DCP / IMF export: create subfolder
        var outputFileURL: URL
        let isImageSequenceExport = preset == .imageSequence
        let isDCPExport = preset == .dcp
        let isIMFJ2KExport = preset == .imfJ2K
        let isIMFProResExport = preset == .imfProRes
        let isIMFExport = isIMFJ2KExport || isIMFProResExport
        var dcpSubfolderURL: URL? = nil
        var imfSubfolderURL: URL? = nil

        if isDCPExport || isIMFJ2KExport {
            // Create working directory for the package output
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)

            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }

            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create package working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create package directory")
                return
            }

            if isDCPExport {
                dcpSubfolderURL = finalSubfolderURL
            } else {
                imfSubfolderURL = finalSubfolderURL
            }

            // DCP / IMF App #2e: FFmpeg outputs JP2 image sequence to a subdirectory in the working folder.
            // This allows the user to optionally keep the JP2 images for image sequence import.
            let jp2Dir = finalSubfolderURL.appendingPathComponent("jp2", isDirectory: true)
            do {
                try fileManager.createDirectory(at: jp2Dir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create JP2 working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create JP2 directory")
                return
            }
            outputFileURL = jp2Dir.appendingPathComponent("frame_%06d.jp2")
            Self.logger.info("\(isDCPExport ? "DCP" : "IMF App 2e"): FFmpeg will output JP2 image sequence")
        } else if isIMFProResExport {
            // IMF App #5: create package working directory; FFmpeg writes to a temp MOV that we
            // later rewrap to OP1a MXF and assemble into the package.
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)
            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }
            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create IMF package working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create IMF directory")
                return
            }
            imfSubfolderURL = finalSubfolderURL
            // FFmpeg outputs to a temp MOV inside the working folder; bmxtranswrap will produce the OP1a MXF.
            outputFileURL = finalSubfolderURL.appendingPathComponent("imf_prores_temp.mov")
            Self.logger.info("IMF App 5: FFmpeg will output ProRes MOV for OP1a rewrap")
        } else if isImageSequenceExport {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceExportFormatKey) ?? AppConstants.defaultImageSequenceExportFormat
            let format = ImageSequenceFormat(rawValue: formatRaw) ?? .png
            let padding = UserDefaults.standard.integer(forKey: AppConstants.imageSequenceNumberingPaddingKey)
            let effectivePadding = padding > 0 ? padding : AppConstants.defaultImageSequenceNumberingPadding

            // Create subfolder: outputDir/basename_seq/
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)

            // Ensure unique folder name
            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }

            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create image sequence output directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create image sequence directory")
                return
            }

            // Build the FFMPEG output pattern: subfolder/basename_%06d.png
            let baseName = outputURL.lastPathComponent
            let patternFileName = "\(baseName)_%0\(effectivePadding)d.\(format.primaryExtension)"
            outputFileURL = finalSubfolderURL.appendingPathComponent(patternFileName)
        } else {
            // Add file extension based on preset
            outputFileURL = outputURL.appendingPathExtension(preset.outputExtension(for: inputURL))

            // CRITICAL: Ensure we never overwrite the source file
            if outputFileURL.standardizedFileURL == inputURL.standardizedFileURL {
                // Add "_encoded" suffix to prevent overwriting source
                let baseName = outputURL.lastPathComponent
                let safeOutputURL = outputDir.appendingPathComponent(baseName + "_encoded")
                    .appendingPathExtension(preset.outputExtension(for: inputURL))
                Self.logger.warning("Safety check: would have overwritten input file. Changed output to: \(safeOutputURL.lastPathComponent, privacy: .public)")
                outputFileURL = safeOutputURL
            }

            // Ensure the output path is unique — prevents silently overwriting
            // a previous conversion output (FFmpeg runs with -y).
            outputFileURL = FileSafetyUtils.uniqueOutputURL(outputFileURL, notOverwriting: inputURL)

            // Register this file as created by the app (for safe deletion later if needed)
            FileSafetyUtils.registerCreatedFile(outputFileURL)
        }

        // For AVC-Intra MXF, FFmpeg outputs to temp file, then bmxtranswrap rewraps to OP1a
        let needsBMXRewrap = preset == .tvAVCIntra
        var ffmpegOutputURL = outputFileURL
        var tempMXFURL: URL? = nil

        if needsBMXRewrap {
            // Create temp file for FFmpeg output
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("ffmpeg_mxf_\(UUID().uuidString).mxf")
            tempMXFURL = tempURL
            ffmpegOutputURL = tempURL
            Self.logger.info("AVC-Intra: FFmpeg will output to temp file for OP1a rewrap")
        }

        // Check if we need audio pre-processing for AVC-Intra with audio-only files
        // This creates a temp file with mono-split audio channels first
        var effectiveInputURL = inputURL
        var effectiveCustomInputArguments = request.customInputArguments
        var tempAudioURL: URL? = nil

        if needsAudioPreProcessing(preset: preset, waveformRequest: request.waveformRequest, synthesizedVideoRequest: request.synthesizedVideoRequest) {
            Self.logger.info("Audio-only file with AVC-Intra preset detected, running audio pre-processing pass")

            if let preProcessedURL = await preProcessAudioForAVCIntra(
                inputURL: inputURL,
                ffmpegPath: ffmpegPath,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd
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
        if let waveformRequest = request.waveformRequest, waveformRequest.renderingEngine == .swift {
            await runNativeWaveformConversion(
                inputURL: inputURL,
                ffmpegOutputURL: ffmpegOutputURL,
                ffmpegPath: ffmpegPath,
                preset: preset,
                waveformRequest: waveformRequest,
                audioRoutingConfig: request.audioRoutingConfig,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                comment: request.comment,
                includeDateTag: request.includeDateTag,
                isMuted: request.isMuted,
                additionalOutputArguments: request.additionalOutputArguments,
                expectedDuration: request.expectedDuration,
                videoFrameRate: request.videoFrameRate,
                needsBMXRewrap: needsBMXRewrap,
                tempMXFURL: tempMXFURL,
                outputFileURL: outputFileURL,
                waveformBackgroundImageURL: request.waveformBackgroundImageURL,
                progressUpdate: progressUpdate,
                completion: completion
            )
            return
        }

        // MARK: Experimental AV2 branch (ffmpeg decode → avmenc encode, two-process pipe)
        if preset == .av2 {
            // Choose output container: a raw video-only `.ivf`, or `.mkv` (AV2 + audio) via the
            // in-app Matroska muxer (FFmpeg can't write AV2). For `.mkv` the encode targets a temp
            // intermediate `.ivf` that the muxer then wraps with the source audio.
            let muxToMKV = (AV2Container.current == .mkv && BinaryPathResolver.avmencPath != nil)
            let encodeURL: URL = muxToMKV
                ? FileManager.default.temporaryDirectory.appendingPathComponent("av2enc_\(UUID().uuidString).ivf")
                : outputFileURL

            // Prefer the parallel chunked path (one avmenc per core) when the source can be split;
            // buildSegments returns nil to fall back to the single-process pipe (chunking disabled,
            // VBR mode, unknown frame count, or a clip too short to usefully split).
            let encodeResult: AV2EncodeResult
            if let plan = await AV2CommandBuilder.buildSegments(
                inputURL: inputURL,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                cropConfig: request.cropConfig
            ), let avmencPath = BinaryPathResolver.avmencPath {
                encodeResult = await runAV2ChunkedConversion(
                    plan: plan,
                    outputFileURL: encodeURL,
                    ffmpegPath: ffmpegPath,
                    avmencPath: avmencPath,
                    progressUpdate: progressUpdate
                )
            } else {
                encodeResult = await runAV2Conversion(
                    inputURL: inputURL,
                    outputFileURL: encodeURL,
                    ffmpegPath: ffmpegPath,
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    cropConfig: request.cropConfig,
                    progressUpdate: progressUpdate
                )
            }

            guard encodeResult.success else {
                if muxToMKV { Self.cleanupTempFile(at: encodeURL, label: "AV2 intermediate .ivf") }
                completion(false, encodeResult.errorReason)
                return
            }

            if muxToMKV, let avmencPath = BinaryPathResolver.avmencPath {
                let bitDepth = await AV2CommandBuilder.resolvedBitDepth(
                    inputURL: inputURL,
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    cropConfig: request.cropConfig
                ) ?? 8
                let (ok, reason) = await muxAV2ToMatroska(
                    videoIvfURL: encodeURL,
                    sourceURL: inputURL,
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    bitDepth: bitDepth,
                    keyframeIndices: encodeResult.keyframeIndices,
                    outputURL: outputFileURL,
                    ffmpegPath: ffmpegPath,
                    avmencPath: avmencPath,
                    progressUpdate: progressUpdate
                )
                Self.cleanupTempFile(at: encodeURL, label: "AV2 intermediate .ivf")
                if ok { progressUpdate(1.0, nil) }
                completion(ok, reason)
                return
            }

            completion(true, nil)
            return
        }

        // MARK: AV2 source decode front-end
        // FFmpeg can't decode AV2, so we run `avmdec` to produce raw frames and pipe them into
        // FFmpeg's stdin; FFmpeg then runs the normal preset command on the decoded frames.
        // avmdec reads both raw `.ivf` bitstreams and AV2-in-Matroska (`.mkv`/`.webm`) directly.
        // For Matroska sources the original file is added as a second FFmpeg input so its
        // (FFmpeg-readable) audio track can be mapped in. Skipped for merges / AVC-Intra / waveform.
        var av2DecodeBridge: Pipe? = nil
        var av2DecodeProcess: Process? = nil
        var av2MatroskaAudioFromInput1 = false
        let av2SourceExt = inputURL.pathExtension.lowercased()
        let av2IsIVF = (av2SourceExt == "ivf") && (IVFHeaderParser.parse(url: inputURL)?.isAV2 ?? false)
        let av2IsMatroska = (av2SourceExt == "mkv" || av2SourceExt == "webm") && Self.matroskaContainsAV2(url: inputURL)
        if (av2IsIVF || av2IsMatroska),
           tempAudioURL == nil,
           request.customInputArguments == nil,
           request.waveformRequest == nil,
           request.synthesizedVideoRequest == nil,
           let avmdecPath = BinaryPathResolver.avmdecPath {
            // avmdec writes self-describing Y4M to stdout, so FFmpeg auto-detects the exact
            // chroma subsampling and bit depth (4:2:0/4:2:2/4:4:4, 8/10/12-bit) with no
            // assumptions — native depth is preserved (a 10-bit source stays 10-bit).
            if av2IsMatroska {
                var customArgs = ["-f", "yuv4mpegpipe", "-i", "pipe:0"]
                if let ts = request.trimStart, ts > 0 {
                    customArgs += ["-ss", String(format: "%.6f", ts)] // seek the audio input to match
                }
                customArgs += ["-i", inputURL.path]
                effectiveCustomInputArguments = customArgs
                av2MatroskaAudioFromInput1 = true
            } else {
                effectiveCustomInputArguments = ["-f", "yuv4mpegpipe", "-i", "pipe:0"]
            }
            let bridge = Pipe()
            let decoder = Process()
            decoder.executableURL = URL(fileURLWithPath: avmdecPath)
            decoder.arguments = [inputURL.path, "-o", "-"]
            decoder.standardOutput = bridge
            decoder.standardError = FileHandle.nullDevice
            decoder.standardInput = FileHandle.nullDevice
            av2DecodeBridge = bridge
            av2DecodeProcess = decoder
            Self.logger.info("AV2 decode front-end: avmdec → ffmpeg for \(inputURL.lastPathComponent, privacy: .public)\(av2IsMatroska ? " (Matroska + audio)" : "")")
        }

        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)

        // Build FFmpeg arguments
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: effectiveInputURL,
            outputFileURL: ffmpegOutputURL,  // Use temp file for AVC-Intra, final file otherwise
            preset: preset,
            comment: request.comment,
            includeDateTag: request.includeDateTag,
            trimStart: tempAudioURL != nil ? nil : request.trimStart,  // Trim already applied in pre-processing
            trimEnd: tempAudioURL != nil ? nil : request.trimEnd,
            audioRoutingConfig: tempAudioURL != nil ? nil : request.audioRoutingConfig,  // Audio already processed
            cropConfig: request.cropConfig,
            timecodeConfig: request.timecodeConfig,
            sourceMetadata: request.sourceMetadata,
            waveformRequest: request.waveformRequest,
            synthesizedVideoRequest: request.synthesizedVideoRequest,
            customInputArguments: effectiveCustomInputArguments,
            additionalOutputArguments: request.additionalOutputArguments,
            isMuted: request.isMuted
        )

        // For an AV2 Matroska source the decoded video arrives on input 0 (the avmdec pipe) and the
        // audio lives on input 1 (the original file). Redirect the preset's audio/subtitle maps,
        // which default to input 0, over to input 1.
        var finalArguments = command.arguments
        if av2MatroskaAudioFromInput1 {
            finalArguments = Self.redirectAudioSubtitleMapsToSecondInput(finalArguments)
        }
        process.arguments = finalArguments

        Self.logger.info("FFmpeg command: \(ffmpegPath, privacy: .public) \(finalArguments.joined(separator: " "), privacy: .public)")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        if let av2DecodeBridge {
            process.standardInput = av2DecodeBridge  // Raw frames from avmdec
        } else {
            process.standardInput = FileHandle.nullDevice  // Prevent FFmpeg from waiting for stdin
        }

        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        effectiveDurationBox.value = command.effectiveDuration
        if let expectedDuration = request.expectedDuration {
            totalDurationBox.value = expectedDuration
            if effectiveDurationBox.value == nil {
                effectiveDurationBox.value = expectedDuration
            }
        }
        let stderrCollector = StderrCollector()
        let frameStallTracker = FrameStallTracker()
        let progressThrottler = ProgressThrottler()
        let frameRate = request.videoFrameRate ?? 24.0  // Default to 24fps if not provided

        // For DCP / IMF exports, scale FFmpeg progress to 0-75% to leave room for post-processing steps
        let ffmpegProgressUpdate: @Sendable (Double, String?) -> Void
        if isDCPExport || isIMFExport {
            ffmpegProgressUpdate = { progress, eta in
                progressUpdate(progress * 0.75, eta)
            }
        } else {
            ffmpegProgressUpdate = progressUpdate
        }

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
                    progressThrottler: progressThrottler,
                    progressUpdate: ffmpegProgressUpdate
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
        let capturedRequest = request
        let capturedTempAudioURL = tempAudioURL
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent
        let capturedIsImageSequenceExport = isImageSequenceExport
        let capturedIsDCPExport = isDCPExport
        let capturedDCPSubfolderURL = dcpSubfolderURL
        let capturedIsIMFJ2KExport = isIMFJ2KExport
        let capturedIsIMFProResExport = isIMFProResExport
        let capturedIsIMFExport = isIMFExport
        let capturedIMFSubfolderURL = imfSubfolderURL
        let capturedInputURL = inputURL
        let capturedFfmpegPath = ffmpegPath

        process.terminationHandler = { [weak self] _ in
            // Stop the readability handler to prevent log spam after process ends
            errorPipe.fileHandleForReading.readabilityHandler = nil

            Task { [weak self] in
                await self?.setCurrentProcess(nil)
                await self?.setAuxProcess(nil)  // Clears the AV2 avmdec decoder when present
                var success = process.terminationStatus == 0
                if capturedIsIMFExport || capturedIsDCPExport {
                    print("[IMF/DCP] termination handler entered, ffmpeg exit=\(process.terminationStatus), success=\(success), isIMF=\(capturedIsIMFExport), isDCP=\(capturedIsDCPExport)")
                }
                if success {
                    Self.logger.info("FFmpeg process terminated with status: \(process.terminationStatus) (success: \(success))")
                } else {
                    Self.logger.error("FFmpeg process terminated with status: \(process.terminationStatus) (success: \(success))")
                }
                var errorReason: String? = nil
                if !success {
                    let collectedStderr = await stderrCollector.snapshot()
                    let stderrString = String(data: collectedStderr, encoding: .utf8) ?? "(unable to decode ffmpeg stderr)"
                    Self.logger.error("FFmpeg exited with code \(process.terminationStatus). Output:\n\(stderrString, privacy: .public)\n-- end of ffmpeg log --")
                    errorReason = Self.extractErrorReason(from: stderrString, exitCode: process.terminationStatus)
                }

                // Validate output file exists and has content.
                // FFmpeg can exit 0 while producing empty/corrupt output (disk full, I/O error, etc.)
                // Skip validation for image sequence and DCP / IMF App 2e exports (they produce directories).
                // For IMF App 5 we still validate the temp MOV here; the rewrap-to-MXF step is the IMF arm below.
                if success && !capturedIsImageSequenceExport && !capturedIsDCPExport && !capturedIsIMFJ2KExport {
                    let fileToValidate = capturedNeedsBMXRewrap ? (capturedTempMXFURL ?? capturedFinalOutputURL) : capturedFinalOutputURL
                    if let validationError = Self.validateOutputFile(at: fileToValidate) {
                        Self.logger.error("Output validation failed: \(validationError, privacy: .public)")
                        errorReason = validationError
                        success = false
                    }
                }

                // Run bmxtranswrap for AVC-Intra to ensure OP1a compliance
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap to rewrap MXF to OP1a format")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    let mcaLabelsFile = await Self.prepareAVCIntraMCALabelsFile(
                        inputURL: capturedInputURL,
                        audioRoutingConfig: capturedRequest.audioRoutingConfig
                    )
                    let bmxResult = await BMXService.shared.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        mcaLabelsFile: mcaLabelsFile,
                        progress: { bmxProgress in
                            // Map bmx progress to 95-100% range
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                progressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )
                    if let mcaLabelsFile {
                        Self.cleanupTempFile(at: mcaLabelsFile, label: "MCA labels")
                    }

                    if bmxResult.success {
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
                    Self.cleanupTempFile(at: tempMXF, label: "BMX rewrap temp MXF")
                }

                // Clean up temp audio file if it exists
                if let tempURL = capturedTempAudioURL {
                    Self.cleanupTempFile(at: tempURL, label: "AVC-Intra pre-processed audio")
                }

                // DCP assembly: wrap JP2 frames + audio WAV into DCP-compliant MXF using asdcp-wrap
                if success && capturedIsDCPExport, let dcpFolder = capturedDCPSubfolderURL {
                    Self.logger.info("Starting DCP assembly...")

                    let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.dcpResolutionKey) ?? AppConstants.defaultDCPResolution
                    let resolution = DCPResolution(rawValue: resolutionRaw) ?? .twoKFull
                    let frameRateRaw = UserDefaults.standard.string(forKey: AppConstants.dcpFrameRateKey) ?? AppConstants.defaultDCPFrameRate
                    let frameRate = DCPFrameRate(rawValue: frameRateRaw) ?? .fps24

                    let fm = FileManager.default
                    let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                    var videoMXFURL: URL? = nil

                    if let asdcpWrapPath = BinaryPathResolver.asdcpWrapPath {
                        // Step 1: Convert JP2 frames to raw J2C codestreams and wrap with asdcp-wrap
                        progressUpdate(0.75, "Creating video MXF for DCP...")
                        let tmpVideoMXF = FileManager.default.temporaryDirectory
                            .appendingPathComponent("dcp_video_\(UUID().uuidString).mxf")

                        // Strip JP2 container headers to get raw J2C codestreams
                        // JP2 files have a header before the raw JPEG 2000 codestream (SOC marker: FF 4F)
                        let jp2Files = (try? fm.contentsOfDirectory(atPath: jp2Dir.path))?
                            .filter { $0.hasSuffix(".jp2") }
                            .sorted() ?? []

                        if jp2Files.isEmpty {
                            Self.logger.error("No JP2 frames found in \(jp2Dir.path)")
                            errorReason = String(localized: "DCP video wrap failed: no JP2 frames produced", comment: "Shown when the JPEG 2000 frame export step produced no usable frames for DCP wrapping.")
                            success = false
                        } else {
                            // Create J2C directory for stripped codestreams
                            let j2cDir = FileManager.default.temporaryDirectory
                                .appendingPathComponent("dcp_j2c_\(UUID().uuidString)", isDirectory: true)
                            try? fm.createDirectory(at: j2cDir, withIntermediateDirectories: true)

                            Self.logger.info("Stripping JP2 headers from \(jp2Files.count) frames...")
                            let socMarker = Data([0xFF, 0x4F])
                            for jp2File in jp2Files {
                                let jp2URL = jp2Dir.appendingPathComponent(jp2File)
                                let j2cFile = jp2File.replacingOccurrences(of: ".jp2", with: ".j2c")
                                let j2cURL = j2cDir.appendingPathComponent(j2cFile)

                                if let data = try? Data(contentsOf: jp2URL),
                                   let socRange = data.range(of: socMarker) {
                                    try? data[socRange.lowerBound...].write(to: j2cURL)
                                }
                            }

                            // Verify J2C files were created
                            let j2cFiles = (try? fm.contentsOfDirectory(atPath: j2cDir.path))?
                                .filter { $0.hasSuffix(".j2c") } ?? []
                            Self.logger.info("Created \(j2cFiles.count) J2C codestream files")

                            // Run asdcp-wrap on J2C directory
                            let videoWrapArgs: [String] = [
                                "-v",                                // Verbose output
                                "-p", frameRate.ffmpegValue,
                                "-L",                                // SMPTE Universal Labels
                                j2cDir.path + "/",                   // Directory of J2C frames
                                tmpVideoMXF.path
                            ]

                            Self.logger.info("Running asdcp-wrap for DCP video: \(videoWrapArgs.joined(separator: " "))")
                            let videoWrapProcess = Process()
                            videoWrapProcess.executableURL = URL(fileURLWithPath: asdcpWrapPath)
                            videoWrapProcess.arguments = videoWrapArgs
                            videoWrapProcess.standardInput = FileHandle.nullDevice

                            // Capture stderr for debugging. Drain in real time — `-v` makes asdcp-wrap
                            // emit per-frame stderr that fills the pipe (16–64 KB) and deadlocks
                            // long encodes if no reader is consuming it.
                            let stderrPipe = Pipe()
                            videoWrapProcess.standardOutput = stderrPipe  // asdcp-wrap prints info to stdout
                            videoWrapProcess.standardError = stderrPipe

                            let stderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                                let chunk = handle.availableData
                                guard !chunk.isEmpty else { return }
                                stderrBuffer.withLock { $0.append(chunk) }
                            }

                            do {
                                try videoWrapProcess.run()
                                videoWrapProcess.waitUntilExit()

                                stderrPipe.fileHandleForReading.readabilityHandler = nil
                                let trailing = stderrPipe.fileHandleForReading.availableData
                                if !trailing.isEmpty { stderrBuffer.withLock { $0.append(trailing) } }
                                try? stderrPipe.fileHandleForReading.close()
                                let stderrData = stderrBuffer.withLock { $0 }
                                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                                if !stderrStr.isEmpty {
                                    Self.logger.info("asdcp-wrap video output: \(stderrStr.prefix(500))")
                                }

                                if videoWrapProcess.terminationStatus == 0 {
                                    videoMXFURL = tmpVideoMXF
                                    Self.logger.info("Video MXF created with asdcp-wrap")
                                } else {
                                    Self.logger.error("asdcp-wrap failed for video MXF (status \(videoWrapProcess.terminationStatus)): \(stderrStr.prefix(300))")
                                    errorReason = Self.dcpIMFErrorReason(
                                        base: String(localized: "DCP video wrap failed (asdcp-wrap exit \(Int(videoWrapProcess.terminationStatus)))", comment: "Shown when the asdcp-wrap tool exits with a non-zero status while wrapping the DCP video essence."),
                                        stderr: stderrStr
                                    )
                                    success = false
                                    Self.cleanupTempFile(at: tmpVideoMXF, label: "failed DCP video MXF")
                                }
                            } catch {
                                stderrPipe.fileHandleForReading.readabilityHandler = nil
                                try? stderrPipe.fileHandleForReading.close()
                                Self.logger.error("Failed to run asdcp-wrap for video: \(error.localizedDescription)")
                                errorReason = String(localized: "DCP video wrap failed: \(error.localizedDescription)", comment: "Shown when launching the asdcp-wrap process for DCP video throws an exception.")
                                success = false
                            }

                            // Clean up J2C frames
                            Self.cleanupTempFile(at: j2cDir, label: "DCP J2C frames")
                        }
                    } else {
                        Self.logger.error("asdcp-wrap not found — cannot create DCP-compliant MXF files")
                        errorReason = String(localized: "DCP video wrap failed: asdcp-wrap not found", comment: "Shown when the bundled asdcp-wrap binary cannot be located, blocking the DCP export.")
                        success = false
                    }

                    // Clean up JP2 images unless user wants to keep them
                    let keepJP2 = UserDefaults.standard.bool(forKey: AppConstants.dcpKeepJP2ImagesKey)
                    if !keepJP2 {
                        Self.cleanupTempFile(at: jp2Dir, label: "DCP JP2 images")
                    }

                    // Step 2: Extract audio as WAV
                    progressUpdate(0.82, "Extracting audio for DCP...")
                    let audioExtractionResult = await Self.extractAudioAsPCMWAV(
                        inputURL: capturedInputURL,
                        outputFolder: FileManager.default.temporaryDirectory,
                        ffmpegPath: capturedFfmpegPath,
                        trimStart: capturedRequest.trimStart,
                        trimEnd: capturedRequest.trimEnd,
                        audioRoutingConfig: capturedRequest.audioRoutingConfig
                    )
                    let audioWavURL: URL?
                    switch audioExtractionResult {
                    case .extracted(let url):
                        audioWavURL = url
                    case .noAudioInSource:
                        audioWavURL = nil
                    case .failed(let reason):
                        audioWavURL = nil
                        errorReason = String(localized: "DCP audio extraction failed: \(reason)", comment: "Shown when ffmpeg cannot extract PCM audio from a source that has audio streams, blocking the DCP audio MXF.")
                        success = false
                    }

                    // Step 3: Wrap audio WAV to DCP MXF with asdcp-wrap
                    var finalAudioMXF: URL? = nil
                    if let wavURL = audioWavURL, let asdcpPath = BinaryPathResolver.asdcpWrapPath {
                        progressUpdate(0.87, "Creating audio MXF for DCP...")
                        let audioMXFURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("dcp_audio_\(UUID().uuidString).mxf")

                        let audioWrapArgs: [String] = [
                            "-p", frameRate.ffmpegValue,
                            "-L",                          // SMPTE Universal Labels
                            wavURL.path,
                            audioMXFURL.path
                        ]

                        Self.logger.info("Running asdcp-wrap for DCP audio")
                        let audioWrapProcess = Process()
                        audioWrapProcess.executableURL = URL(fileURLWithPath: asdcpPath)
                        audioWrapProcess.arguments = audioWrapArgs
                        audioWrapProcess.standardInput = FileHandle.nullDevice

                        let audioStderrPipe = Pipe()
                        audioWrapProcess.standardOutput = audioStderrPipe
                        audioWrapProcess.standardError = audioStderrPipe

                        // Same drain-in-real-time pattern as the video wrap to avoid pipe-buffer deadlock.
                        let audioStderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                        audioStderrPipe.fileHandleForReading.readabilityHandler = { handle in
                            let chunk = handle.availableData
                            guard !chunk.isEmpty else { return }
                            audioStderrBuffer.withLock { $0.append(chunk) }
                        }

                        do {
                            try audioWrapProcess.run()
                            audioWrapProcess.waitUntilExit()

                            audioStderrPipe.fileHandleForReading.readabilityHandler = nil
                            let trailing = audioStderrPipe.fileHandleForReading.availableData
                            if !trailing.isEmpty { audioStderrBuffer.withLock { $0.append(trailing) } }
                            try? audioStderrPipe.fileHandleForReading.close()
                            let audioStderrData = audioStderrBuffer.withLock { $0 }
                            let audioStderrStr = String(data: audioStderrData, encoding: .utf8) ?? ""
                            if !audioStderrStr.isEmpty {
                                Self.logger.info("asdcp-wrap audio output: \(audioStderrStr.prefix(500))")
                            }

                            if audioWrapProcess.terminationStatus == 0 {
                                finalAudioMXF = audioMXFURL
                                Self.logger.info("Audio MXF created with asdcp-wrap")
                            } else {
                                Self.logger.error("asdcp-wrap failed for audio (status \(audioWrapProcess.terminationStatus)): \(audioStderrStr.prefix(300))")
                                errorReason = Self.dcpIMFErrorReason(
                                    base: String(localized: "DCP audio wrap failed (asdcp-wrap exit \(Int(audioWrapProcess.terminationStatus)))", comment: "Shown when asdcp-wrap exits with a non-zero status while wrapping the DCP audio essence; the resulting package would be missing audio."),
                                    stderr: audioStderrStr
                                )
                                success = false
                                Self.cleanupTempFile(at: audioMXFURL, label: "failed DCP audio MXF")
                            }
                        } catch {
                            audioStderrPipe.fileHandleForReading.readabilityHandler = nil
                            try? audioStderrPipe.fileHandleForReading.close()
                            Self.logger.error("Failed to run asdcp-wrap for audio: \(error.localizedDescription)")
                            errorReason = String(localized: "DCP audio wrap failed: \(error.localizedDescription)", comment: "Shown when launching the asdcp-wrap process for DCP audio throws an exception.")
                            success = false
                            Self.cleanupTempFile(at: audioMXFURL, label: "failed DCP audio MXF")
                        }

                        // Clean up WAV
                        Self.cleanupTempFile(at: wavURL, label: "DCP audio WAV")
                    }

                    // Step 4: Assemble DCP XML metadata (only if video MXF was created)
                    if success, let videoMXF = videoMXFURL {
                        progressUpdate(0.91, "Generating DCP metadata...")

                        let duration = effectiveDurationBox.value ?? totalDurationBox.value ?? 0
                        let frameCount = Int(ceil(duration * Double(frameRate.editRateNumerator) / Double(frameRate.editRateDenominator)))

                        let dcpTitle: String
                        if let metadataTitle = capturedRequest.dcpMetadata?.contentTitleText, !metadataTitle.isEmpty {
                            dcpTitle = metadataTitle
                        } else {
                            dcpTitle = capturedInputBaseName
                        }

                        // Create ISDCF-named DCP folder inside the working folder
                        let contentKind = capturedRequest.dcpMetadata?.contentKind ?? .feature
                        let audioLanguage = capturedRequest.dcpMetadata?.audioLanguage ?? "en"
                        let isdcfName = await DCPService.shared.isdcfFolderName(
                            title: dcpTitle,
                            contentKind: contentKind,
                            frameRate: frameRate,
                            resolution: resolution,
                            audioLanguage: audioLanguage
                        )
                        let dcpOutputDir = dcpFolder.appendingPathComponent(
                            isdcfName,
                            isDirectory: true
                        )
                        try? fm.createDirectory(at: dcpOutputDir, withIntermediateDirectories: true)

                        Self.logger.info("DCP output folder: \(dcpOutputDir.lastPathComponent)")

                        let dcpSuccess = await DCPService.shared.assembleDCP(
                            videoMXFURL: videoMXF,
                            audioMXFURL: finalAudioMXF,
                            outputDirectoryURL: dcpOutputDir,
                            title: dcpTitle,
                            resolution: resolution,
                            frameRate: frameRate,
                            frameCount: max(frameCount, 1),
                            itemMetadata: capturedRequest.dcpMetadata,
                            progress: { dcpProgress in
                                let overall = 0.91 + dcpProgress * 0.09
                                Task { @MainActor in
                                    progressUpdate(overall, "Generating DCP metadata...")
                                }
                            }
                        )

                        if !dcpSuccess {
                            Self.logger.error("DCP assembly failed")
                            errorReason = String(localized: "DCP assembly failed", comment: "Shown when DCPService cannot assemble the final DCP package (CPL/PKL/ASSETMAP). Detailed cause is in the app log.")
                            success = false
                        }

                        // Clean up temp video MXF if DCPService moved it
                        if fm.fileExists(atPath: videoMXF.path) {
                            Self.cleanupTempFile(at: videoMXF, label: "DCP video MXF")
                        }
                    }
                }

                // IMF assembly: produce video MXF + audio MXF essences and emit CPL/PKL/ASSETMAP.
                if success && capturedIsIMFExport, let imfFolder = capturedIMFSubfolderURL {
                    Self.logger.info("Starting IMF assembly...")
                    print("[IMF] starting assembly, imfFolder=\(imfFolder.path)")

                    let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.imfResolutionKey) ?? AppConstants.defaultIMFResolution
                    let resolution = IMFResolution(rawValue: resolutionRaw) ?? .hd1080
                    let frameRateRaw = UserDefaults.standard.string(forKey: AppConstants.imfFrameRateKey) ?? AppConstants.defaultIMFFrameRate
                    let frameRate = IMFFrameRate(rawValue: frameRateRaw) ?? .fps24
                    let colorRaw = UserDefaults.standard.string(forKey: AppConstants.imfJ2KColorEncodingKey) ?? AppConstants.defaultIMFJ2KColorEncoding
                    let color = IMFColorEncoding(rawValue: colorRaw) ?? .rec709
                    let application: IMFApplication = capturedIsIMFJ2KExport ? .app2e : .app5

                    let fm = FileManager.default
                    var imfVideoMXF: URL? = nil

                    // ----- Video essence wrap -----
                    if capturedIsIMFJ2KExport {
                        // J2K → raw2bmx with `-t imf` writes a full ST 2067-21 CDCIPictureEssenceDescriptor
                        // including ColorPrimaries/TransferCharacteristic/CodingEquations/ChromaSubsampling
                        // ULs. asdcp-wrap (a DCP tool) cannot, and the resulting sparse descriptor caused
                        // Resolve to read the YCbCr essence as RGBA — see the colour-magenta bug.
                        let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                        let resolvedRaw2bmxPath = BinaryPathResolver.raw2bmxPath
                        print("[IMF] App 2e branch — raw2bmx path: \(resolvedRaw2bmxPath ?? "<nil>"), jp2Dir=\(jp2Dir.path)")
                        if let raw2bmxPath = resolvedRaw2bmxPath {
                            progressUpdate(0.78, "Creating IMF video essence")
                            let tmpVideoMXF = FileManager.default.temporaryDirectory
                                .appendingPathComponent("imf_video_\(UUID().uuidString).mxf")

                            let jp2Files = (try? fm.contentsOfDirectory(atPath: jp2Dir.path))?
                                .filter { $0.hasSuffix(".jp2") }
                                .sorted() ?? []
                            print("[IMF] discovered \(jp2Files.count) JP2 frames in \(jp2Dir.path)")

                            if jp2Files.isEmpty {
                                Self.logger.error("No JP2 frames found for IMF in \(jp2Dir.path)")
                                errorReason = String(localized: "IMF video wrap failed: no JP2 frames produced", comment: "Shown when the JPEG 2000 frame export step produced no usable frames for IMF App 2e wrapping.")
                                success = false
                            } else {
                                let j2cDir = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("imf_j2c_\(UUID().uuidString)", isDirectory: true)
                                try? fm.createDirectory(at: j2cDir, withIntermediateDirectories: true)

                                // Strip JP2 box wrapper to raw J2C codestreams. For long sources
                                // this loop can take many seconds; emit throttled progress so the
                                // UI shows what's happening between FFmpeg finishing and the wrap.
                                // Also accumulate total J2C bytes so the wrap-progress poller below
                                // can estimate real progress against expected MXF essence size.
                                let socMarker = Data([0xFF, 0x4F])
                                let totalFrames = jp2Files.count
                                var totalJ2CBytes: Int64 = 0
                                var lastEmit = Date.distantPast
                                let emitInterval: TimeInterval = 0.25
                                for (index, jp2File) in jp2Files.enumerated() {
                                    let jp2URL = jp2Dir.appendingPathComponent(jp2File)
                                    let j2cFile = jp2File.replacingOccurrences(of: ".jp2", with: ".j2c")
                                    let j2cURL = j2cDir.appendingPathComponent(j2cFile)
                                    if let data = try? Data(contentsOf: jp2URL),
                                       let socRange = data.range(of: socMarker) {
                                        let codestream = data[socRange.lowerBound...]
                                        try? codestream.write(to: j2cURL)
                                        totalJ2CBytes += Int64(codestream.count)
                                    }
                                    let now = Date()
                                    if now.timeIntervalSince(lastEmit) >= emitInterval || index == totalFrames - 1 {
                                        lastEmit = now
                                        let frac = Double(index + 1) / Double(totalFrames)
                                        let overall = 0.78 + frac * 0.02   // 0.78 → 0.80
                                        progressUpdate(overall, "Preparing J2C frames \(index + 1)/\(totalFrames)")
                                    }
                                }
                                let expectedMXFBytes = totalJ2CBytes
                                print("[IMF] J2C extraction complete (\(totalFrames) frames, \(ByteCountFormatter.string(fromByteCount: expectedMXFBytes, countStyle: .file)))")

                                // raw2bmx accepts the same frame-rate syntax as ffmpeg ("24" / "24000/1001").
                                // --j2c_cdci tells raw2bmx the codestream is YCbCr (CDCI descriptor); the
                                // alternative --j2c_rgba would reproduce the original RGBA-mislabelling bug.
                                // The input is a printf-style %d pattern matched against the J2C frames
                                // (extracted above from frame_%06d.jp2 → frame_%06d.j2c).
                                // Per-input flags (--color-prim/--transfer-ch/--coding-eq) bind to the
                                // following --j2c_cdci input, so they must appear before it.
                                let bmxFlags = color.bmxFlags
                                let j2cPattern = j2cDir.appendingPathComponent("frame_%d.j2c").path
                                var videoWrapArgs: [String] = [
                                    "-t", "imf",
                                    "-o", tmpVideoMXF.path,
                                    "-f", frameRate.ffmpegValue,
                                    "--clip", capturedInputBaseName,
                                    "--color-prim", bmxFlags.colorPrimaries,
                                ]
                                if let transfer = bmxFlags.transferCharacteristic {
                                    videoWrapArgs.append(contentsOf: ["--transfer-ch", transfer])
                                }
                                videoWrapArgs.append(contentsOf: [
                                    "--coding-eq", bmxFlags.codingEquations,
                                    "--j2c_cdci", j2cPattern
                                ])
                                let videoWrapProcess = Process()
                                videoWrapProcess.executableURL = URL(fileURLWithPath: raw2bmxPath)
                                videoWrapProcess.arguments = videoWrapArgs
                                videoWrapProcess.standardInput = FileHandle.nullDevice
                                let stderrPipe = Pipe()
                                videoWrapProcess.standardOutput = stderrPipe
                                videoWrapProcess.standardError = stderrPipe
                                progressUpdate(0.80, "Wrapping J2C → MXF")
                                print("[IMF] launching raw2bmx: \(videoWrapArgs.joined(separator: " "))")
                                // Drain the merged stdout/stderr pipe in real time. Same pipe-deadlock
                                // hazard as asdcp-wrap (commit 631dc39): without an active reader the
                                // OS pipe buffer fills, the child blocks on write(), and progress stalls.
                                let stderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                                    let chunk = handle.availableData
                                    guard !chunk.isEmpty else { return }
                                    stderrBuffer.withLock { $0.append(chunk) }
                                }
                                do {
                                    try videoWrapProcess.run()
                                    // Poll the output MXF size and estimate progress as
                                    // bytes-written / expected-essence-size. The MXF holds the J2C
                                    // codestreams plus a small index/header overhead, so total J2C
                                    // bytes is a tight lower-bound estimate.
                                    let pollerTask = Task.detached { [tmpVideoMXF, expectedMXFBytes] in
                                        let pollFM = FileManager.default
                                        while !Task.isCancelled {
                                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                                            if Task.isCancelled { break }
                                            let attrs = try? pollFM.attributesOfItem(atPath: tmpVideoMXF.path)
                                            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                                            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                                            let frac: Double
                                            if expectedMXFBytes > 0 {
                                                frac = min(0.99, Double(bytes) / Double(expectedMXFBytes))
                                            } else {
                                                frac = 0.0
                                            }
                                            let overall = 0.80 + frac * 0.06   // 0.80 → 0.86
                                            let pct = Int(frac * 100)
                                            progressUpdate(overall, "Wrapping J2C → MXF (\(formatted), \(pct)%)")
                                        }
                                    }
                                    videoWrapProcess.waitUntilExit()
                                    pollerTask.cancel()
                                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                                    // Drain anything still in the pipe after the process ended.
                                    let trailing = stderrPipe.fileHandleForReading.availableData
                                    if !trailing.isEmpty {
                                        stderrBuffer.withLock { $0.append(trailing) }
                                    }
                                    try? stderrPipe.fileHandleForReading.close()
                                    let stderrData = stderrBuffer.withLock { $0 }
                                    let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                                    print("[IMF] raw2bmx exited with status \(videoWrapProcess.terminationStatus)")
                                    if videoWrapProcess.terminationStatus == 0 {
                                        imfVideoMXF = tmpVideoMXF
                                        Self.logger.info("IMF video essence created (App #2e)")
                                    } else {
                                        Self.logger.error("raw2bmx failed for IMF video (status \(videoWrapProcess.terminationStatus)): \(stderrStr.prefix(300))")
                                        errorReason = Self.dcpIMFErrorReason(
                                            base: String(localized: "IMF video wrap failed (raw2bmx exit \(Int(videoWrapProcess.terminationStatus)))", comment: "Shown when raw2bmx exits with a non-zero status while wrapping the IMF App 2e video essence."),
                                            stderr: stderrStr
                                        )
                                        success = false
                                        Self.cleanupTempFile(at: tmpVideoMXF, label: "failed IMF video MXF")
                                    }
                                } catch {
                                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                                    try? stderrPipe.fileHandleForReading.close()
                                    Self.logger.error("Failed to run raw2bmx for IMF video: \(error.localizedDescription)")
                                    print("[IMF] raw2bmx launch threw: \(error.localizedDescription)")
                                    errorReason = String(localized: "IMF video wrap failed: \(error.localizedDescription)", comment: "Shown when launching the raw2bmx process for IMF video throws an exception.")
                                    success = false
                                }
                                Self.cleanupTempFile(at: j2cDir, label: "IMF J2C frames")
                            }
                        } else {
                            Self.logger.error("raw2bmx not found — cannot create IMF App 2e essence")
                            errorReason = String(localized: "IMF video wrap failed: raw2bmx not found", comment: "Shown when the bundled raw2bmx binary cannot be located, blocking the IMF App 2e export.")
                            success = false
                        }

                        // Clean up JP2 working folder
                        let keepIntermediates = UserDefaults.standard.bool(forKey: AppConstants.imfKeepIntermediatesKey)
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: jp2Dir, label: "IMF JP2 images")
                        }
                    } else if capturedIsIMFProResExport {
                        // ProRes MOV → bmxtranswrap → OP1a MXF
                        progressUpdate(0.78, "Creating IMF video essence")
                        print("[IMF] App 5 branch — input MOV: \(capturedFinalOutputURL.lastPathComponent)")
                        let tmpVideoMXF = FileManager.default.temporaryDirectory
                            .appendingPathComponent("imf_video_\(UUID().uuidString).mxf")

                        let bmxFlags = color.bmxFlags

                        let bmxResult = await BMXService.shared.rewrapToIMFOP1a(
                            inputURL: capturedFinalOutputURL,
                            outputURL: tmpVideoMXF,
                            colorPrimaries: bmxFlags.colorPrimaries,
                            transferCharacteristic: bmxFlags.transferCharacteristic,
                            codingEquations: bmxFlags.codingEquations,
                            clipName: capturedInputBaseName,
                            mcaLabelsFile: nil,
                            progress: { bmxProgress in
                                // Map bmx 0..1 onto the 0.78 → 0.84 sub-band of overall progress.
                                let overall = 0.78 + bmxProgress * 0.06
                                let pct = Int(bmxProgress * 100)
                                progressUpdate(overall, "Wrapping ProRes → MXF \(pct)%")
                            }
                        )
                        if bmxResult.success {
                            imfVideoMXF = tmpVideoMXF
                            Self.logger.info("IMF video essence created (App #5)")
                        } else {
                            Self.logger.error("bmxtranswrap failed for IMF ProRes video essence")
                            errorReason = Self.dcpIMFErrorReason(
                                base: String(localized: "IMF video wrap failed: bmxtranswrap rejected ProRes essence", comment: "Shown when bmxtranswrap cannot rewrap the ProRes MOV into IMF App 5 OP1a MXF."),
                                stderr: bmxResult.stderr
                            )
                            success = false
                        }
                        // Remove the temporary MOV; if user wants to keep, they can use the .prores preset directly.
                        let keepIntermediates = UserDefaults.standard.bool(forKey: AppConstants.imfKeepIntermediatesKey)
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: capturedFinalOutputURL, label: "IMF ProRes temp MOV")
                        }
                    }

                    // ----- Audio essence wrap (shared between App #2e and App #5) -----
                    var imfAudioMXF: URL? = nil
                    if success {
                        progressUpdate(0.86, "Extracting audio for IMF")
                        print("[IMF] extracting audio")
                        let audioExtractionResult = await Self.extractAudioAsPCMWAV(
                            inputURL: capturedInputURL,
                            outputFolder: FileManager.default.temporaryDirectory,
                            ffmpegPath: capturedFfmpegPath,
                            trimStart: capturedRequest.trimStart,
                            trimEnd: capturedRequest.trimEnd,
                            audioRoutingConfig: capturedRequest.audioRoutingConfig
                        )
                        let audioWavURL: URL?
                        switch audioExtractionResult {
                        case .extracted(let url):
                            audioWavURL = url
                        case .noAudioInSource:
                            audioWavURL = nil
                        case .failed(let reason):
                            audioWavURL = nil
                            errorReason = String(localized: "IMF audio extraction failed: \(reason)", comment: "Shown when ffmpeg cannot extract PCM audio from a source that has audio streams, blocking the IMF audio essence.")
                            success = false
                        }

                        if let originalWavURL = audioWavURL {
                            progressUpdate(0.90, "Wrapping audio essence")
                            print("[IMF] wrapping audio essence")
                            let tmpAudioMXF = FileManager.default.temporaryDirectory
                                .appendingPathComponent("imf_audio_\(UUID().uuidString).mxf")

                            // Pad the WAV to match the picture frame count so asdcp-wrap's
                            // edit-unit index matches the actual essence length. Without this,
                            // sources whose duration doesn't quantise cleanly to picture frames
                            // (e.g. 156.36 s → 3754 frames @ 24 fps but only ~3752.6 audio
                            // frames worth of samples) produce a truncated MXF that Resolve
                            // refuses to play even though mpv tolerates it.
                            let jp2FrameCount: Int
                            if capturedIsIMFJ2KExport {
                                let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                                jp2FrameCount = (try? fm.contentsOfDirectory(atPath: jp2Dir.path))?
                                    .filter { $0.hasSuffix(".jp2") }.count ?? 0
                            } else {
                                let duration = effectiveDurationBox.value ?? totalDurationBox.value ?? 0
                                jp2FrameCount = Int(ceil(duration * Double(frameRate.editRateNumerator) / Double(frameRate.editRateDenominator)))
                            }
                            let wavURL: URL
                            if jp2FrameCount > 0,
                               let padded = await Self.padWAVToFrameCount(
                                   inputWAV: originalWavURL,
                                   frameCount: jp2FrameCount,
                                   editRateNumerator: frameRate.editRateNumerator,
                                   editRateDenominator: frameRate.editRateDenominator,
                                   ffmpegPath: capturedFfmpegPath
                               ) {
                                wavURL = padded
                                Self.cleanupTempFile(at: originalWavURL, label: "IMF audio WAV (pre-pad)")
                            } else {
                                wavURL = originalWavURL
                                print("[IMF] WAV padding skipped (frameCount=\(jp2FrameCount))")
                            }

                            // Wrap PCM WAV → IMF audio MXF using asdcp-wrap. bmxtranswrap is
                            // MXF-only (it cannot ingest WAV), so the prior call always failed
                            // with "Failed to open MXF file '…wav'". asdcp-wrap supports raw
                            // PCM input and produces a SMPTE-labelled audio essence — same
                            // tool the DCP path uses for its audio MXF.
                            if let asdcpPath = BinaryPathResolver.asdcpWrapPath {
                                let audioWrapArgs: [String] = [
                                    "-p", frameRate.ffmpegValue,
                                    "-L",                          // SMPTE Universal Labels
                                    wavURL.path,
                                    tmpAudioMXF.path
                                ]
                                print("[IMF] launching asdcp-wrap (audio): \(audioWrapArgs.joined(separator: " "))")

                                let audioWrapProcess = Process()
                                audioWrapProcess.executableURL = URL(fileURLWithPath: asdcpPath)
                                audioWrapProcess.arguments = audioWrapArgs
                                audioWrapProcess.standardInput = FileHandle.nullDevice

                                let audioStderrPipe = Pipe()
                                audioWrapProcess.standardOutput = audioStderrPipe
                                audioWrapProcess.standardError = audioStderrPipe

                                let audioStderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                                audioStderrPipe.fileHandleForReading.readabilityHandler = { handle in
                                    let chunk = handle.availableData
                                    guard !chunk.isEmpty else { return }
                                    audioStderrBuffer.withLock { $0.append(chunk) }
                                }

                                do {
                                    try audioWrapProcess.run()
                                    audioWrapProcess.waitUntilExit()

                                    audioStderrPipe.fileHandleForReading.readabilityHandler = nil
                                    let trailing = audioStderrPipe.fileHandleForReading.availableData
                                    if !trailing.isEmpty { audioStderrBuffer.withLock { $0.append(trailing) } }
                                    try? audioStderrPipe.fileHandleForReading.close()
                                    let audioStderrData = audioStderrBuffer.withLock { $0 }
                                    let audioStderrStr = String(data: audioStderrData, encoding: .utf8) ?? ""

                                    if audioWrapProcess.terminationStatus == 0 {
                                        imfAudioMXF = tmpAudioMXF
                                        Self.logger.info("IMF audio essence created (asdcp-wrap)")
                                        progressUpdate(0.94, "Wrapping audio essence")
                                    } else {
                                        Self.logger.error("asdcp-wrap failed for IMF audio (status \(audioWrapProcess.terminationStatus)): \(audioStderrStr.prefix(300))")
                                        print("[IMF] asdcp-wrap (audio) exited \(audioWrapProcess.terminationStatus)")
                                        print("[IMF] stderr:\n\(audioStderrStr.isEmpty ? "(empty)" : audioStderrStr)")
                                        errorReason = Self.dcpIMFErrorReason(
                                            base: String(localized: "IMF audio wrap failed (asdcp-wrap exit \(Int(audioWrapProcess.terminationStatus)))", comment: "Shown when asdcp-wrap exits with a non-zero status while wrapping the IMF audio essence; the resulting package would be missing audio."),
                                            stderr: audioStderrStr
                                        )
                                        success = false
                                        Self.cleanupTempFile(at: tmpAudioMXF, label: "failed IMF audio MXF")
                                    }
                                } catch {
                                    audioStderrPipe.fileHandleForReading.readabilityHandler = nil
                                    try? audioStderrPipe.fileHandleForReading.close()
                                    Self.logger.error("Failed to run asdcp-wrap for IMF audio: \(error.localizedDescription)")
                                    print("[IMF] asdcp-wrap (audio) launch threw: \(error.localizedDescription)")
                                    errorReason = String(localized: "IMF audio wrap failed: \(error.localizedDescription)", comment: "Shown when launching the asdcp-wrap process for IMF audio throws an exception.")
                                    success = false
                                }
                            } else {
                                Self.logger.error("asdcp-wrap not found — cannot create IMF audio essence")
                                errorReason = String(localized: "IMF audio wrap failed: asdcp-wrap not found", comment: "Shown when the bundled asdcp-wrap binary cannot be located, blocking IMF audio essence creation.")
                                success = false
                            }
                            Self.cleanupTempFile(at: wavURL, label: "IMF audio WAV")
                        }
                    }

                    // ----- Manifest assembly -----
                    if success, let videoMXF = imfVideoMXF {
                        progressUpdate(0.94, "Generating IMF manifests")
                        print("[IMF] generating manifests")

                        let duration = effectiveDurationBox.value ?? totalDurationBox.value ?? 0
                        let frameCount = Int(ceil(duration * Double(frameRate.editRateNumerator) / Double(frameRate.editRateDenominator)))

                        let imfTitle: String
                        if let metaTitle = capturedRequest.imfMetadata?.contentTitleText, !metaTitle.isEmpty {
                            imfTitle = metaTitle
                        } else {
                            imfTitle = capturedInputBaseName
                        }
                        let audioLanguage = capturedRequest.imfMetadata?.audioLanguage ?? "en"

                        let folderName = await IMFManifestWriter.shared.packageFolderName(
                            title: imfTitle,
                            application: application,
                            resolution: resolution,
                            frameRate: frameRate,
                            audioLanguage: audioLanguage
                        )
                        let imfOutputDir = imfFolder.appendingPathComponent(folderName, isDirectory: true)
                        try? fm.createDirectory(at: imfOutputDir, withIntermediateDirectories: true)

                        Self.logger.info("IMF output folder: \(imfOutputDir.lastPathComponent)")

                        let imfSuccess = await IMFManifestWriter.shared.assembleIMP(
                            videoMXFURL: videoMXF,
                            audioMXFURL: imfAudioMXF,
                            outputDirectoryURL: imfOutputDir,
                            title: imfTitle,
                            application: application,
                            editRateNumerator: frameRate.editRateNumerator,
                            editRateDenominator: frameRate.editRateDenominator,
                            frameCount: max(frameCount, 1),
                            itemMetadata: capturedRequest.imfMetadata,
                            progress: { imfProgress in
                                let overall = 0.94 + imfProgress * 0.06
                                let pct = Int(imfProgress * 100)
                                Task { @MainActor in
                                    progressUpdate(overall, "Generating IMF manifests \(pct)%")
                                }
                            }
                        )
                        if !imfSuccess {
                            Self.logger.error("IMF assembly failed")
                            errorReason = String(localized: "IMF manifest assembly failed", comment: "Shown when IMFManifestWriter cannot assemble the IMP package (CPL/PKL/ASSETMAP). Detailed cause is in the app log.")
                            success = false
                        }
                        // IMFManifestWriter moves the essences into the package folder; clean up
                        // the temp paths only if they still exist (they shouldn't on success).
                        if fm.fileExists(atPath: videoMXF.path) {
                            Self.cleanupTempFile(at: videoMXF, label: "IMF video MXF")
                        }
                        if let audioMXF = imfAudioMXF, fm.fileExists(atPath: audioMXF.path) {
                            Self.cleanupTempFile(at: audioMXF, label: "IMF audio MXF")
                        }
                    }
                    _ = resolution // resolution captured for potential per-essence labelling; quiet "unused" warnings
                }

                // Extract audio as WAV for image sequence exports (if source has audio)
                // Use the output pattern's base name so the WAV matches the image filenames
                if success && capturedIsImageSequenceExport && capturedRequest.customInputArguments == nil {
                    let outputFolder = capturedFinalOutputURL.deletingLastPathComponent()
                    let outputBaseName = outputFolder.lastPathComponent
                    await Self.extractAudioAsWAV(
                        inputURL: capturedInputURL,
                        outputFolder: outputFolder,
                        baseName: outputBaseName,
                        ffmpegPath: capturedFfmpegPath,
                        trimStart: capturedRequest.trimStart,
                        trimEnd: capturedRequest.trimEnd
                    )

                    // Generate metadata sidecar with source color space and technical specs
                    let sidecarEnabled = UserDefaults.standard.object(forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey) != nil
                        ? UserDefaults.standard.bool(forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
                        : AppConstants.defaultImageSequenceMetadataSidecarEnabled

                    if sidecarEnabled, let metadata = capturedRequest.sourceMetadata {
                        let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)
                            ?? AppConstants.defaultImageSequenceMetadataSidecarFormat
                        let format = MetadataSidecarGenerator.SidecarFormat(rawValue: formatRaw) ?? .markdown
                        MetadataSidecarGenerator.generateSidecar(
                            originalFileName: capturedInputBaseName,
                            outputFolder: outputFolder,
                            metadata: metadata,
                            cameraMetadata: capturedRequest.sourceCameraMetadata,
                            format: format
                        )
                    }
                }

                completion(success, errorReason)
            }
        }

        do {
            try process.run()
            // For an AV2 .ivf source, start avmdec now (FFmpeg is already reading pipe:0) and
            // release the parent's bridge fds so EOF/SIGPIPE propagate when either side finishes.
            if let decoder = av2DecodeProcess, let bridge = av2DecodeBridge {
                await setAuxProcess(decoder)
                do {
                    try decoder.run()
                    try? bridge.fileHandleForWriting.close()
                    try? bridge.fileHandleForReading.close()
                } catch {
                    // avmdec failed to launch — FFmpeg would block forever waiting for frames.
                    Self.logger.error("Failed to run avmdec: \(error.localizedDescription, privacy: .public)")
                    process.terminate()
                    await setAuxProcess(nil)
                    completion(false, "Failed to start AV2 decoder (avmdec): \(error.localizedDescription)")
                }
            }
        } catch {
            Self.logger.error("Failed to run process: \(error.localizedDescription, privacy: .public)")
            completion(false, "Failed to start FFmpeg: \(error.localizedDescription)")
        }
    }

    // MARK: - Extract Error Reason

    /// Composes a user-facing reason for a DCP/IMF wrap-step failure. Appends a short,
    /// trimmed slice of the tool's stderr after the base message when present, so the
    /// queue capsule tooltip carries the diagnostic context without dumping the full log.
    private static func dcpIMFErrorReason(base: String, stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        // Use the last non-empty line — wrap tools tend to print the actionable cause last.
        let lastLine = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? trimmed
        return truncateForDisplay("\(base): \(lastLine)")
    }

    /// Extracts a concise reason from avmenc stderr. The encoder's actionable message
    /// (e.g. "Fatal: …", "Error: …") is typically the last meaningful line it prints.
    private static func extractAvmencErrorReason(from stderr: String, exitCode: Int32) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let explicit = lines.last(where: {
            let lower = $0.lowercased()
            return lower.hasPrefix("fatal") || lower.contains("error") || lower.contains("unsupported")
        }) {
            return truncateForDisplay("AV2 encoder: \(explicit)")
        }
        if let last = lines.last {
            return truncateForDisplay("AV2 encoder failed: \(last)")
        }
        return "AV2 encoder failed (exit \(exitCode))"
    }

    /// Extracts a concise, user-facing error reason from FFmpeg stderr output.
    private static func extractErrorReason(from stderr: String, exitCode: Int32) -> String {
        let lines = stderr.components(separatedBy: .newlines).reversed()
        // FFmpeg typically outputs the most relevant error on the last non-empty lines.
        // Look for lines containing common error patterns.
        // Track the last FFmpeg internal error (e.g. "[libx264 @ 0x...] message") as a
        // fallback — these often carry the root cause when no high-level message matches.
        var lastInternalError: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match common FFmpeg error patterns
            if trimmed.contains("No such file or directory") ||
               trimmed.contains("Permission denied") ||
               trimmed.contains("No space left on device") ||
               trimmed.contains("Invalid data found") ||
               (trimmed.contains("Decoder") && trimmed.contains("not found")) ||
               (trimmed.contains("Encoder") && trimmed.contains("not found")) ||
               trimmed.contains("Unknown encoder") ||
               trimmed.contains("Unknown decoder") ||
               (trimmed.contains("Codec") && trimmed.contains("not")) ||
               trimmed.contains("does not support") ||
               trimmed.contains("Invalid argument") ||
               (trimmed.contains("Error") && !trimmed.hasPrefix("frame=")) ||
               trimmed.contains("Cannot") ||
               trimmed.contains("Could not") ||
               trimmed.contains("Impossible") ||
               trimmed.contains("not found") ||
               trimmed.contains("Unrecognized option") ||
               trimmed.contains("already exists. Overwrite") ||
               (trimmed.contains("Discarded") && trimmed.contains("exceeded")) ||
               trimmed.contains("Conversion failed") ||
               trimmed.contains("Failed to") ||
               trimmed.contains("Unable to") ||
               trimmed.contains("Unsupported") ||
               trimmed.contains("Too many packets buffered") ||
               trimmed.contains("Output file is empty") {
                return truncateForDisplay(cleanUpErrorMessage(trimmed))
            }

            // Track FFmpeg internal error messages as fallback (e.g. "[libx264 @ 0x12345] ...")
            if lastInternalError == nil && trimmed.hasPrefix("[") && trimmed.contains(" @ 0x") {
                lastInternalError = trimmed
            }
        }

        // Use the last FFmpeg internal error if no high-level pattern matched
        if let internal_ = lastInternalError {
            return truncateForDisplay(cleanUpErrorMessage(internal_))
        }

        return "Encoding failed (exit code \(exitCode))"
    }

    /// Strips FFmpeg internal prefixes like "[libx264 @ 0x12345abcdef]" to produce
    /// cleaner user-facing error messages while keeping the component name.
    private static func cleanUpErrorMessage(_ message: String) -> String {
        // Pattern: [component @ 0xHEXADDR] rest of message
        // Extract "component: rest of message"
        guard message.hasPrefix("["),
              let closeBracket = message.firstIndex(of: "]") else {
            return message
        }
        let bracketContent = message[message.index(after: message.startIndex)..<closeBracket]
        let remainder = message[message.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)

        // Strip the " @ 0x..." part, keeping just the component name
        if let atRange = bracketContent.range(of: " @ 0x") {
            let component = bracketContent[bracketContent.startIndex..<atRange.lowerBound]
            if remainder.isEmpty {
                return "[\(component)] (no details)"
            }
            return "[\(component)] \(remainder)"
        }

        // No memory address — return as-is
        return message
    }

    /// Truncates a string for UI display, capping at 150 characters.
    private static func truncateForDisplay(_ text: String, maxLength: Int = 150) -> String {
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "…"
        }
        return text
    }

    // MARK: - Native Waveform Conversion (Swift Renderer)

    /// Runs the native waveform pipeline: decode PCM → FFT → Swift-rendered frames → pipe to FFmpeg.
    /// Runs the experimental AV2 export as a two-process pipe: ffmpeg decodes/trims/scales
    /// the source to y4m on stdout, which is piped into avmenc's stdin; avmenc writes the
    /// final video-only `.ivf`. ffmpeg's stderr drives the standard progress parser — pipe
    /// backpressure makes its frame counter advance at avmenc's actual encode rate.
    private func runAV2Conversion(
        inputURL: URL,
        outputFileURL: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> AV2EncodeResult {
        guard let avmencPath = BinaryPathResolver.avmencPath else {
            Self.logger.error("avmenc binary not found in app bundle")
            return AV2EncodeResult(success: false, errorReason: "AV2 encoder (avmenc) not found in the app bundle", keyframeIndices: [])
        }

        guard let command = await AV2CommandBuilder.build(
            inputURL: inputURL,
            outputURL: outputFileURL,
            trimStart: trimStart,
            trimEnd: trimEnd,
            cropConfig: cropConfig
        ) else {
            return AV2EncodeResult(success: false, errorReason: "Could not determine source video dimensions for AV2 encoding", keyframeIndices: [])
        }

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpeg.arguments = command.ffmpegArguments

        let avmenc = Process()
        avmenc.executableURL = URL(fileURLWithPath: avmencPath)
        avmenc.arguments = command.avmencArguments

        // Bridge: ffmpeg stdout → avmenc stdin (same Pipe object on both ends).
        let bridgePipe = Pipe()
        ffmpeg.standardOutput = bridgePipe
        avmenc.standardInput = bridgePipe

        let ffmpegErrPipe = Pipe()
        let avmencErrPipe = Pipe()
        let avmencOutPipe = Pipe()  // avmenc prints per-frame "POC:" progress to stdout (not stderr)
        ffmpeg.standardError = ffmpegErrPipe
        ffmpeg.standardInput = FileHandle.nullDevice
        avmenc.standardError = avmencErrPipe
        avmenc.standardOutput = avmencOutPipe  // bitstream goes to the -o file; stdout is progress text

        await setCurrentProcess(ffmpeg)
        await setAuxProcess(avmenc)

        Self.logger.info("AV2 ffmpeg: \(ffmpegPath, privacy: .public) \(command.ffmpegArguments.joined(separator: " "), privacy: .public)")
        Self.logger.info("AV2 avmenc: \(avmencPath, privacy: .public) \(command.avmencArguments.joined(separator: " "), privacy: .public)")

        // Progress is driven by AVMENC, not ffmpeg. ffmpeg only decodes the source and feeds y4m
        // (fast — it finishes and exits within seconds), while avmenc does the slow encoding and
        // buffers frames via lag-in-frames, so ffmpeg never back-pressures on short clips. Tracking
        // ffmpeg would pin the bar at 100% for the entire real encode (the "stuck at 100%" report).
        // avmenc prints one "POC:" line per encoded frame to stderr, so we count those against the
        // known frame count. (A few extra hidden alt-ref frames may appear; we cap the bar at 99%
        // until the 2-of-2 barrier confirms completion.)
        let totalFrames: Int = {
            guard let dur = command.effectiveDuration, let fps = command.frameRate, dur > 0, fps > 0 else { return 0 }
            return max(1, Int((dur * fps).rounded()))
        }()
        let encodedFrames = OSAllocatedUnfairLock<Int>(initialState: 0)
        let ffmpegStderr = StderrCollector()
        let avmencStderr = StderrCollector()

        // Fallback time-based progress (only used when we can't determine a frame count).
        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        totalDurationBox.value = command.effectiveDuration
        effectiveDurationBox.value = command.effectiveDuration
        let frameStallTracker = FrameStallTracker()
        let progressThrottler = ProgressThrottler()
        let frameRate = command.frameRate ?? 24.0

        ffmpegErrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if totalFrames == 0,
               let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let (newTotal, _) = FFMPEGProgressParser.handleOutput(
                    output,
                    totalDuration: totalDurationBox.value,
                    effectiveDuration: effectiveDurationBox.value,
                    frameRate: frameRate,
                    frameStallTracker: frameStallTracker,
                    progressThrottler: progressThrottler,
                    progressUpdate: progressUpdate
                )
                if let newTotal { totalDurationBox.value = newTotal }
            }
            if !data.isEmpty { Task { await ffmpegStderr.append(data) } }
        }

        // avmenc prints one "POC:" line per encoded frame to STDOUT — count them to drive the
        // encode progress bar. (The IVF bitstream itself goes to the -o file, not stdout.)
        avmencOutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, totalFrames > 0, let text = String(data: data, encoding: .utf8) else { return }
            let newOnes = text.components(separatedBy: "POC:").count - 1
            if newOnes > 0 {
                let count = encodedFrames.withLock { state -> Int in state += newOnes; return state }
                let shown = min(count, totalFrames)
                let fraction = min(0.99, Double(count) / Double(totalFrames))
                progressUpdate(fraction, "Encoding AV2 — frame \(shown)/\(totalFrames)")
            }
        }

        // avmenc stderr carries warnings/errors; drain it continuously (so the encoder never
        // blocks on a full stderr buffer) and keep it for the failure reason.
        avmencErrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await avmencStderr.append(data) } }
        }

        // Show an immediate status: avmenc buffers frames (lag-in-frames) before emitting the
        // first "POC:" line, so there's a gap before frame-based progress starts climbing.
        progressUpdate(0.0, totalFrames > 0 ? "Encoding AV2 — frame 0/\(totalFrames)" : "Encoding AV2…")

        // 2-of-2 termination barrier: finalize only after BOTH processes have exited
        // (the .ivf isn't fully flushed until avmenc terminates).
        let exitState = OSAllocatedUnfairLock<(ffmpeg: Int32?, avmenc: Int32?, resumed: Bool)>(initialState: (nil, nil, false))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            @Sendable func resumeIfBothFinished() {
                let shouldResume = exitState.withLock { state -> Bool in
                    guard state.ffmpeg != nil, state.avmenc != nil, !state.resumed else { return false }
                    state.resumed = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }

            ffmpeg.terminationHandler = { process in
                exitState.withLock { $0.ffmpeg = process.terminationStatus }
                resumeIfBothFinished()
            }
            avmenc.terminationHandler = { process in
                exitState.withLock { $0.avmenc = process.terminationStatus }
                resumeIfBothFinished()
            }

            do {
                // Start the consumer (avmenc) before the producer (ffmpeg).
                try avmenc.run()
                try ffmpeg.run()
                // Release the parent's copies of the bridge fds so EOF propagates correctly:
                // when ffmpeg exits, the last writer closes and avmenc sees end-of-input; if
                // avmenc dies first, ffmpeg's next write gets SIGPIPE and it exits.
                try? bridgePipe.fileHandleForWriting.close()
                try? bridgePipe.fileHandleForReading.close()
            } catch {
                Self.logger.error("AV2: failed to launch pipeline: \(error.localizedDescription, privacy: .public)")
                if avmenc.isRunning { avmenc.terminate() }
                if ffmpeg.isRunning { ffmpeg.terminate() }
                // Synthesize terminations for whichever side never started so the barrier resumes.
                exitState.withLock { state in
                    if state.ffmpeg == nil { state.ffmpeg = -1 }
                    if state.avmenc == nil { state.avmenc = -1 }
                }
                resumeIfBothFinished()
            }
        }

        // Both processes have exited.
        ffmpegErrPipe.fileHandleForReading.readabilityHandler = nil
        avmencErrPipe.fileHandleForReading.readabilityHandler = nil
        avmencOutPipe.fileHandleForReading.readabilityHandler = nil
        await setCurrentProcess(nil)
        await setAuxProcess(nil)

        let (ffmpegStatus, avmencStatus) = exitState.withLock { ($0.ffmpeg ?? -1, $0.avmenc ?? -1) }
        var success = ffmpegStatus == 0 && avmencStatus == 0
        var errorReason: String? = nil

        if success, let validationError = Self.validateOutputFile(at: outputFileURL) {
            success = false
            errorReason = validationError
        }

        if !success {
            // Prefer avmenc's stderr when avmenc failed: if avmenc dies first, ffmpeg exits via
            // SIGPIPE (141) — a symptom, not the root cause.
            if avmencStatus != 0 {
                let stderrString = String(data: await avmencStderr.snapshot(), encoding: .utf8) ?? ""
                errorReason = Self.extractAvmencErrorReason(from: stderrString, exitCode: avmencStatus)
            } else if errorReason == nil {
                let stderrString = String(data: await ffmpegStderr.snapshot(), encoding: .utf8) ?? ""
                errorReason = Self.extractErrorReason(from: stderrString, exitCode: ffmpegStatus)
            }
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "partial AV2 .ivf")
            }
            Self.logger.error("AV2 failed (ffmpeg=\(ffmpegStatus), avmenc=\(avmencStatus)): \(errorReason ?? "unknown", privacy: .public)")
        } else {
            progressUpdate(1.0, nil)
            Self.logger.info("AV2 encode complete: \(outputFileURL.lastPathComponent, privacy: .public)")
        }

        // The single-process encode forces a key frame only at frame 0; that is the lone guaranteed
        // seek point we surface to the muxer (avmenc inserts more, but their positions aren't known
        // here without parsing the bitstream).
        return AV2EncodeResult(success: success, errorReason: errorReason, keyframeIndices: success ? [0] : [])
    }

    // MARK: - Chunked (parallel) AV2 Conversion

    /// Result of an AV2 encode (single-process or chunked). `keyframeIndices` are global frame
    /// indices known to be key frames — used by the `.mkv` muxer to place Cue points.
    struct AV2EncodeResult: Sendable {
        let success: Bool
        let errorReason: String?
        let keyframeIndices: [Int]
    }

    private struct AV2SegmentOutcome: Sendable {
        let index: Int
        let success: Bool
        let errorReason: String?
    }

    /// Runs a parallel chunked AV2 encode: one ffmpeg│avmenc pipe per chunk, all concurrent, with
    /// `POC:` progress aggregated across workers. When every chunk succeeds the segment `.ivf`
    /// files are joined (in order) by ``IVFConcatenator`` into the final video-only `.ivf`. A single
    /// failing chunk aborts the rest. Each chunk is an independent AV2 sequence (key frame at its
    /// first frame), which is what makes the bitstream-level concatenation valid.
    private func runAV2ChunkedConversion(
        plan: AV2CommandBuilder.AV2SegmentPlan,
        outputFileURL: URL,
        ffmpegPath: String,
        avmencPath: String,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> AV2EncodeResult {
        let totalFrames = plan.totalFrames
        let chunkCount = plan.segments.count
        Self.logger.info("AV2 chunked encode: \(chunkCount) workers, \(totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")

        // Aggregate per-worker "POC:" frame counts into one progress value, throttled to per-mille
        // steps so N workers don't flood the main thread.
        let progressState = OSAllocatedUnfairLock<(total: Int, lastPermille: Int)>(initialState: (0, 0))
        let onFrames: @Sendable (Int) -> Void = { delta in
            let (total, emit) = progressState.withLock { st -> (Int, Bool) in
                st.total += delta
                let permille = totalFrames > 0 ? min(990, st.total * 1000 / totalFrames) : 0
                if permille != st.lastPermille { st.lastPermille = permille; return (st.total, true) }
                return (st.total, false)
            }
            if emit {
                let fraction = totalFrames > 0 ? min(0.99, Double(total) / Double(totalFrames)) : 0
                progressUpdate(fraction, "Encoding AV2 — \(chunkCount) chunks — frame \(min(total, totalFrames))/\(totalFrames)")
            }
        }

        progressUpdate(0.0, "Encoding AV2 — \(chunkCount) chunks — frame 0/\(totalFrames)")

        var outcomes: [AV2SegmentOutcome] = []
        await withTaskGroup(of: AV2SegmentOutcome.self) { group in
            for seg in plan.segments {
                group.addTask {
                    await self.encodeAV2Segment(seg, ffmpegPath: ffmpegPath, avmencPath: avmencPath, onFrames: onFrames)
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
                // First failure: kill the remaining workers so we don't burn cores on a doomed encode.
                if !outcome.success { self.terminateAV2Workers() }
            }
        }

        // All workers have exited (the task group is the 2N-of-2N termination barrier).
        if let failed = outcomes.first(where: { !$0.success }) {
            Self.cleanupDirectory(plan.segmentDirectory)
            Self.logger.error("AV2 chunked failed at chunk \(failed.index): \(failed.errorReason ?? "unknown", privacy: .public)")
            return AV2EncodeResult(success: false, errorReason: failed.errorReason ?? "AV2 chunked encode failed", keyframeIndices: [])
        }

        // Join the chunk bitstreams in order.
        let ordered = plan.segments.sorted { $0.index < $1.index }.map { $0.outputURL }
        do {
            let result = try IVFConcatenator.concatenate(segmentURLs: ordered, into: outputFileURL)
            Self.cleanupDirectory(plan.segmentDirectory)
            if let validationError = Self.validateOutputFile(at: outputFileURL) {
                Self.cleanupTempFile(at: outputFileURL, label: "invalid AV2 .ivf")
                return AV2EncodeResult(success: false, errorReason: validationError, keyframeIndices: [])
            }
            progressUpdate(1.0, nil)
            Self.logger.info("AV2 chunked encode complete: \(result.totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")
            return AV2EncodeResult(success: true, errorReason: nil, keyframeIndices: result.keyframeIndices)
        } catch {
            Self.cleanupDirectory(plan.segmentDirectory)
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "partial AV2 .ivf")
            }
            return AV2EncodeResult(success: false, errorReason: "Failed to assemble AV2 chunks: \(error.localizedDescription)", keyframeIndices: [])
        }
    }

    /// Encodes a single chunk via an ffmpeg│avmenc pipe (mirrors `runAV2Conversion` for one range).
    /// Registers both processes in `av2Workers` so they can be cancelled, counts `POC:` frames into
    /// `onFrames`, and resolves only once both processes have exited (the per-chunk 2-of-2 barrier).
    private func encodeAV2Segment(
        _ seg: AV2CommandBuilder.AV2SegmentCommand,
        ffmpegPath: String,
        avmencPath: String,
        onFrames: @escaping @Sendable (Int) -> Void
    ) async -> AV2SegmentOutcome {
        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpeg.arguments = seg.ffmpegArguments

        let avmenc = Process()
        avmenc.executableURL = URL(fileURLWithPath: avmencPath)
        avmenc.arguments = seg.avmencArguments

        let bridgePipe = Pipe()
        ffmpeg.standardOutput = bridgePipe
        avmenc.standardInput = bridgePipe

        let ffmpegErrPipe = Pipe()
        let avmencErrPipe = Pipe()
        let avmencOutPipe = Pipe()
        ffmpeg.standardError = ffmpegErrPipe
        ffmpeg.standardInput = FileHandle.nullDevice
        avmenc.standardError = avmencErrPipe
        avmenc.standardOutput = avmencOutPipe

        let avmencStderr = StderrCollector()

        avmencOutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let newOnes = text.components(separatedBy: "POC:").count - 1
            if newOnes > 0 { onFrames(newOnes) }
        }
        ffmpegErrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData // drain so ffmpeg never blocks on a full stderr buffer
        }
        avmencErrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await avmencStderr.append(data) } }
        }

        av2Workers.insert(ffmpeg)
        av2Workers.insert(avmenc)

        let exitState = OSAllocatedUnfairLock<(ffmpeg: Int32?, avmenc: Int32?, resumed: Bool)>(initialState: (nil, nil, false))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            @Sendable func resumeIfBothFinished() {
                let shouldResume = exitState.withLock { state -> Bool in
                    guard state.ffmpeg != nil, state.avmenc != nil, !state.resumed else { return false }
                    state.resumed = true
                    return true
                }
                if shouldResume { continuation.resume() }
            }
            ffmpeg.terminationHandler = { process in
                exitState.withLock { $0.ffmpeg = process.terminationStatus }
                resumeIfBothFinished()
            }
            avmenc.terminationHandler = { process in
                exitState.withLock { $0.avmenc = process.terminationStatus }
                resumeIfBothFinished()
            }
            do {
                try avmenc.run()
                try ffmpeg.run()
                try? bridgePipe.fileHandleForWriting.close()
                try? bridgePipe.fileHandleForReading.close()
            } catch {
                if avmenc.isRunning { avmenc.terminate() }
                if ffmpeg.isRunning { ffmpeg.terminate() }
                exitState.withLock { state in
                    if state.ffmpeg == nil { state.ffmpeg = -1 }
                    if state.avmenc == nil { state.avmenc = -1 }
                }
                resumeIfBothFinished()
            }
        }

        ffmpegErrPipe.fileHandleForReading.readabilityHandler = nil
        avmencErrPipe.fileHandleForReading.readabilityHandler = nil
        avmencOutPipe.fileHandleForReading.readabilityHandler = nil
        av2Workers.remove(ffmpeg)
        av2Workers.remove(avmenc)

        let (ffmpegStatus, avmencStatus) = exitState.withLock { ($0.ffmpeg ?? -1, $0.avmenc ?? -1) }
        if ffmpegStatus == 0, avmencStatus == 0, Self.fileHasContent(at: seg.outputURL) {
            return AV2SegmentOutcome(index: seg.index, success: true, errorReason: nil)
        }

        let reason: String
        if avmencStatus != 0 {
            let stderrString = String(data: await avmencStderr.snapshot(), encoding: .utf8) ?? ""
            reason = Self.extractAvmencErrorReason(from: stderrString, exitCode: avmencStatus)
        } else {
            reason = "AV2 chunk \(seg.index) failed (ffmpeg=\(ffmpegStatus), avmenc=\(avmencStatus))"
        }
        return AV2SegmentOutcome(index: seg.index, success: false, errorReason: reason)
    }

    /// Terminates every still-running chunked AV2 worker (used to abort siblings after one fails).
    /// Workers remove themselves from `av2Workers` as they exit, so this does not clear the set.
    private func terminateAV2Workers() {
        for worker in av2Workers where worker.isRunning { worker.terminate() }
    }

    private static func fileHasContent(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }

    private static func cleanupDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - AV2 → Matroska (.mkv) muxing

    /// Wraps an already-encoded AV2 `.ivf` plus the source audio into a `.mkv` using the in-app
    /// ``MatroskaMuxer`` (FFmpeg cannot write AV2). The AV2 `CodecPrivate` is harvested from a tiny
    /// `avmenc --webm` probe; the audio is re-encoded to AAC and packetised from its ADTS stream.
    /// Audio is best-effort: a source with no audio (or an audio-extraction failure) yields a valid
    /// video-only `.mkv`.
    private func muxAV2ToMatroska(
        videoIvfURL: URL,
        sourceURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        bitDepth: Int,
        keyframeIndices: [Int],
        outputURL: URL,
        ffmpegPath: String,
        avmencPath: String,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> (Bool, String?) {
        guard let ivfHeader = IVFHeaderParser.parse(url: videoIvfURL), ivfHeader.isAV2 else {
            return (false, "AV2 muxing: the encoded bitstream is not a valid AV2 IVF")
        }
        let width = ivfHeader.width
        let height = ivfHeader.height
        let fpsNum = ivfHeader.fpsNumerator > 0 ? ivfHeader.fpsNumerator : 24
        let fpsDen = ivfHeader.fpsDenominator > 0 ? ivfHeader.fpsDenominator : 1

        progressUpdate(0.99, "Muxing AV2 + audio…")

        // 1. Harvest the authoritative V_AV2 CodecPrivate (level/bit-depth depend on the config).
        let codecPrivate = await harvestAV2CodecPrivate(
            width: width, height: height, bitDepth: bitDepth,
            fpsNum: fpsNum, fpsDen: fpsDen, ffmpegPath: ffmpegPath, avmencPath: avmencPath
        )
        if codecPrivate == nil {
            Self.logger.warning("AV2 muxing: failed to harvest CodecPrivate; writing track without it")
        }

        // 2. Read the video frames, flagging known key frames (chunk boundaries) for seeking.
        let keyset = Set(keyframeIndices)
        var videoFrames: [MatroskaMuxer.VideoFrame] = []
        do {
            var idx = 0
            try IVFConcatenator.forEachFrame(in: videoIvfURL) { payload, _ in
                videoFrames.append(MatroskaMuxer.VideoFrame(data: payload, isKeyframe: idx == 0 || keyset.contains(idx)))
                idx += 1
            }
        } catch {
            return (false, "AV2 muxing: \(error.localizedDescription)")
        }
        guard !videoFrames.isEmpty else { return (false, "AV2 muxing: no video frames in bitstream") }

        // 3. Extract + parse audio (best-effort; a video-only .mkv is fine if absent).
        var audioInfo: MatroskaMuxer.AudioTrackInfo? = nil
        var audioFrames: [MatroskaMuxer.AudioFrame] = []
        if let (info, frames) = await extractAudioForMux(sourceURL: sourceURL, trimStart: trimStart, trimEnd: trimEnd, ffmpegPath: ffmpegPath) {
            audioInfo = info
            audioFrames = frames
        }

        // 4. Write the Matroska file.
        let video = MatroskaMuxer.VideoTrackInfo(
            codecID: "V_AV2", codecPrivate: codecPrivate,
            width: width, height: height, fpsNumerator: fpsNum, fpsDenominator: fpsDen
        )
        do {
            try MatroskaMuxer.write(to: outputURL, video: video, videoFrames: videoFrames, audio: audioInfo, audioFrames: audioFrames)
        } catch {
            return (false, "AV2 muxing failed: \(error.localizedDescription)")
        }
        if let validationError = Self.validateOutputFile(at: outputURL) {
            return (false, validationError)
        }
        Self.logger.info("AV2 mux complete: \(videoFrames.count) video + \(audioFrames.count) audio frames → \(outputURL.lastPathComponent, privacy: .public)")
        return (true, nil)
    }

    /// Encodes a single black frame at the exact geometry/depth/fps to learn the authoritative
    /// AV2 `CodecPrivate` from `avmenc --webm` (the field is config-dependent, not content-dependent).
    private func harvestAV2CodecPrivate(
        width: Int, height: Int, bitDepth: Int, fpsNum: Int, fpsDen: Int,
        ffmpegPath: String, avmencPath: String
    ) async -> Data? {
        let dir = FileManager.default.temporaryDirectory
        let y4m = dir.appendingPathComponent("av2probe_\(UUID().uuidString).y4m")
        let webm = dir.appendingPathComponent("av2probe_\(UUID().uuidString).webm")
        defer {
            Self.cleanupTempFile(at: y4m, label: "AV2 probe y4m")
            Self.cleanupTempFile(at: webm, label: "AV2 probe webm")
        }
        let pix = bitDepth >= 10 ? "yuv420p10le" : "yuv420p"
        let ff = ["-y", "-nostdin", "-hide_banner", "-f", "lavfi",
                  "-i", "color=c=black:s=\(width)x\(height):r=\(fpsNum)/\(fpsDen)",
                  "-frames:v", "1", "-pix_fmt", pix, "-f", "yuv4mpegpipe", "-strict", "-1", y4m.path]
        guard await runBinary(ffmpegPath, ff) == 0, Self.fileHasContent(at: y4m) else { return nil }
        let av = ["--webm", "-w", "\(width)", "-h", "\(height)", "-b", "\(bitDepth)",
                  "--input-bit-depth=\(bitDepth)", "--i420", "--fps=\(fpsNum)/\(fpsDen)",
                  "--end-usage=q", "--qp=110", "--cpu-used=9", "--limit=1", "-o", webm.path, y4m.path]
        guard await runBinary(avmencPath, av) == 0, Self.fileHasContent(at: webm) else { return nil }
        return Self.extractMatroskaCodecPrivate(fromWebM: webm)
    }

    /// Re-encodes the source audio to the configured codec (AAC or Opus), parses the elementary
    /// stream, and returns the Matroska track info + per-frame data ready to mux. Trim-aware.
    /// Returns nil when the source has no audio or extraction/parsing produces nothing.
    private func extractAudioForMux(
        sourceURL: URL, trimStart: Double?, trimEnd: Double?, ffmpegPath: String
    ) async -> (MatroskaMuxer.AudioTrackInfo, [MatroskaMuxer.AudioFrame])? {
        let codec = AV2AudioCodec.current
        let bitrate = AudioBitrate(rawValue: UserDefaults.standard.string(forKey: AppConstants.av2AudioBitrateKey) ?? AppConstants.defaultAV2AudioBitrate)?.ffmpegValue ?? "192k"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("av2audio_\(UUID().uuidString).\(codec.intermediateExtension)")
        defer { Self.cleanupTempFile(at: tmp, label: "AV2 mux audio") }

        var args = ["-y", "-nostdin", "-hide_banner"]
        if let trimStart, trimStart > 0 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += ["-i", sourceURL.path]
        if let trimStart, let trimEnd, trimEnd > trimStart {
            args += ["-t", String(format: "%.6f", trimEnd - trimStart)]
        } else if let trimEnd, trimEnd > 0, trimStart == nil {
            args += ["-t", String(format: "%.6f", trimEnd)]
        }
        args += ["-vn", "-map", "0:a:0?", "-c:a", codec.ffmpegEncoder, "-b:a", bitrate]
        args += codec == .opus ? ["-f", "ogg"] : ["-f", "adts"]
        args += [tmp.path]
        guard await runBinary(ffmpegPath, args) == 0, Self.fileHasContent(at: tmp) else { return nil }

        switch codec {
        case .aac:
            guard let parsed = Self.parseADTS(tmp) else { return nil }
            let info = MatroskaMuxer.AudioTrackInfo(codecID: "A_AAC", codecPrivate: parsed.asc, sampleRate: parsed.sampleRate, channels: parsed.channels)
            let frames = parsed.frames.map { MatroskaMuxer.AudioFrame(data: $0, durationSamples: 1024) }
            return (info, frames)
        case .opus:
            guard let parsed = Self.parseOggOpus(tmp) else { return nil }
            // Opus always runs on a 48 kHz timestamp clock in Matroska. CodecDelay carries the
            // encoder pre-skip; SeekPreRoll is the standard 80 ms.
            let codecDelayNs = Int64((Double(parsed.preSkip) * 1_000_000_000.0 / 48000.0).rounded())
            let info = MatroskaMuxer.AudioTrackInfo(
                codecID: "A_OPUS", codecPrivate: parsed.codecPrivate, sampleRate: 48000, channels: parsed.channels,
                codecDelayNs: codecDelayNs, seekPreRollNs: 80_000_000
            )
            return (info, parsed.frames)
        }
    }

    /// Parses an Ogg-Opus stream into Opus packets (with per-packet sample durations from each TOC
    /// byte), plus the `OpusHead` CodecPrivate, pre-skip and channel count from the identification
    /// header. Reassembles packets across Ogg segment/page boundaries.
    private static func parseOggOpus(_ url: URL) -> (frames: [MatroskaMuxer.AudioFrame], codecPrivate: Data, preSkip: Int, channels: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        var off = 0
        while off + 27 <= bytes.count {
            guard bytes[off] == 0x4F, bytes[off + 1] == 0x67, bytes[off + 2] == 0x67, bytes[off + 3] == 0x53 else { break } // "OggS"
            let nsegs = Int(bytes[off + 26])
            let segStart = off + 27
            guard segStart + nsegs <= bytes.count else { break }
            let segTable = Array(bytes[segStart..<(segStart + nsegs)])
            var bi = segStart + nsegs
            let bodyLen = segTable.reduce(0) { $0 + Int($1) }
            guard bi + bodyLen <= bytes.count else { break }
            for lace in segTable {
                let len = Int(lace)
                partial.append(contentsOf: bytes[bi..<(bi + len)])
                bi += len
                if lace < 255 { packets.append(partial); partial = [] } // packet boundary
            }
            off = bi
        }
        // packet 0 = OpusHead, packet 1 = OpusTags, packets 2… = audio
        guard packets.count >= 3, packets[0].starts(with: Array("OpusHead".utf8)) else { return nil }
        let head = packets[0]
        let channels = head.count > 9 ? Int(head[9]) : 2
        let preSkip = head.count > 11 ? Int(head[10]) | (Int(head[11]) << 8) : 0
        let frames = packets[2...].map { MatroskaMuxer.AudioFrame(data: Data($0), durationSamples: opusPacketSamples($0)) }
        guard !frames.isEmpty else { return nil }
        return (frames, Data(head), preSkip, channels)
    }

    /// Number of 48 kHz samples a single Opus packet decodes to, from its TOC byte (and, for
    /// code 3, the following frame-count byte).
    private static func opusPacketSamples(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 960 }
        // Frame size (samples @ 48 kHz) indexed by the 5-bit config (TOC >> 3).
        let frameSizes = [
            480, 960, 1920, 2880,   // 0–3   SILK NB  10/20/40/60 ms
            480, 960, 1920, 2880,   // 4–7   SILK MB
            480, 960, 1920, 2880,   // 8–11  SILK WB
            480, 960,               // 12–13 Hybrid SWB 10/20 ms
            480, 960,               // 14–15 Hybrid FB  10/20 ms
            120, 240, 480, 960,     // 16–19 CELT NB  2.5/5/10/20 ms
            120, 240, 480, 960,     // 20–23 CELT WB
            120, 240, 480, 960,     // 24–27 CELT SWB
            120, 240, 480, 960,     // 28–31 CELT FB
        ]
        let config = Int(toc >> 3)
        let frameSize = config < frameSizes.count ? frameSizes[config] : 960
        let code = Int(toc & 0x03)
        var frameCount = 1
        switch code {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        case 3: frameCount = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
        default: frameCount = 1
        }
        return frameSize * max(1, frameCount)
    }

    /// Runs a binary to completion (output discarded), tracked in `av2Workers` for cancellation.
    private func runBinary(_ path: String, _ arguments: [String]) async -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        av2Workers.insert(process)
        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in continuation.resume(returning: proc.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        av2Workers.remove(process)
        return status
    }

    /// Scans an avmenc-written WebM for the `V_AV2` track's `CodecPrivate` (`0x63A2`) payload.
    private static func extractMatroskaCodecPrivate(fromWebM url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let needle = Data("V_AV2".utf8)
        guard let r = data.range(of: needle) else { return nil }
        // Find the CodecPrivate element id (0x63 0xA2) shortly after the CodecID value.
        var i = r.upperBound
        let limit = min(data.count - 1, i + 16)
        var found = -1
        while i < limit {
            if data[i] == 0x63 && data[i + 1] == 0xA2 { found = i; break }
            i += 1
        }
        guard found >= 0 else { return nil }
        let sizeIdx = found + 2
        guard sizeIdx < data.count else { return nil }
        // Decode the size VINT (CodecPrivate is tiny, but parse it properly).
        let first = data[sizeIdx]
        var marker: UInt8 = 0x80
        var len = 1
        while marker != 0 && (first & marker) == 0 { marker >>= 1; len += 1 }
        guard marker != 0, sizeIdx + len <= data.count else { return nil }
        var value = UInt64(first & (marker &- 1))
        for k in 1..<len { value = (value << 8) | UInt64(data[sizeIdx + k]) }
        let payloadStart = sizeIdx + len
        guard value > 0, value < 256, payloadStart + Int(value) <= data.count else { return nil }
        return data.subdata(in: payloadStart..<(payloadStart + Int(value)))
    }

    /// Parses an ADTS AAC stream into raw AAC access units plus the derived AudioSpecificConfig,
    /// sample rate and channel count (read from the first frame's header).
    private static func parseADTS(_ url: URL) -> (frames: [Data], asc: Data, sampleRate: Double, channels: Int)? {
        guard let data = try? Data(contentsOf: url), data.count > 7 else { return nil }
        let bytes = [UInt8](data)
        let rateTable: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var frames: [Data] = []
        var asc: Data? = nil
        var sampleRate: Double = 48000
        var channels = 2
        var i = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, (bytes[i + 1] & 0xF0) == 0xF0 else { break } // syncword
            let protectionAbsent = bytes[i + 1] & 0x01
            let headerLen = protectionAbsent == 1 ? 7 : 9
            let profile = (bytes[i + 2] >> 6) & 0x03
            let freqIdx = (bytes[i + 2] >> 2) & 0x0F
            let chanCfg = ((bytes[i + 2] & 0x01) << 2) | ((bytes[i + 3] >> 6) & 0x03)
            let frameLen = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5] >> 5) & 0x07)
            guard frameLen >= headerLen, i + frameLen <= bytes.count else { break }
            if asc == nil {
                let aot = UInt8(profile + 1) // ADTS profile = audioObjectType − 1
                let b0 = (aot << 3) | (freqIdx >> 1)
                let b1 = ((freqIdx & 0x01) << 7) | (chanCfg << 3)
                asc = Data([b0, b1])
                if Int(freqIdx) < rateTable.count { sampleRate = rateTable[Int(freqIdx)] }
                channels = chanCfg == 0 ? 2 : Int(chanCfg)
            }
            let payloadStart = i + headerLen
            frames.append(data.subdata(in: payloadStart..<(i + frameLen)))
            i += frameLen
        }
        guard let asc, !frames.isEmpty else { return nil }
        return (frames, asc, sampleRate, channels)
    }

    /// Returns true if a Matroska/WebM file carries an AV2 video track (CodecID `V_AV2`). Scans the
    /// file head, where the Tracks element lives, so it's cheap and won't false-positive on normal
    /// `.mkv` files. Used to route AV2-in-Matroska sources through the avmdec decode front-end.
    static func matroskaContainsAV2(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_000_000) else { return false }
        return data.range(of: Data("V_AV2".utf8)) != nil
    }

    /// Rewrites `-map 0:a…` / `-map 0:s…` to input 1 (leaving `-map 0:v…` on input 0). Used when an
    /// AV2 Matroska source is decoded via avmdec on input 0 (video) with the original file added as
    /// input 1 (audio/subtitles).
    private static func redirectAudioSubtitleMapsToSecondInput(_ args: [String]) -> [String] {
        var out = args
        var i = 0
        while i + 1 < out.count {
            if out[i] == "-map" {
                let value = out[i + 1]
                if value.hasPrefix("0:a") || value.hasPrefix("0:s") {
                    out[i + 1] = "1:" + value.dropFirst(2)
                }
            }
            i += 1
        }
        return out
    }

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
        waveformBackgroundImageURL: URL? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
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
            completion(false, "Cannot determine audio duration")
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
            completion(false, "Audio analysis failed: \(error.localizedDescription)")
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

        Self.logger.info("FFmpeg native waveform command: \(ffmpegPath, privacy: .public) \(command.arguments.joined(separator: " "), privacy: .public)")

        let stderrCollector = StderrCollector()
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent
        let capturedInputURL = inputURL
        let capturedAudioRoutingConfig = audioRoutingConfig

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

                var errorReason: String? = nil
                if !success {
                    let collectedStderr = await stderrCollector.snapshot()
                    let stderrString = String(data: collectedStderr, encoding: .utf8) ?? "(unable to decode)"
                    Self.logger.error("FFmpeg native waveform stderr:\n\(stderrString, privacy: .public)\n-- end --")
                    errorReason = Self.extractErrorReason(from: stderrString, exitCode: process.terminationStatus)
                }

                // BMX rewrap for AVC-Intra if needed
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap for native waveform output")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    let mcaLabelsFile = await Self.prepareAVCIntraMCALabelsFile(
                        inputURL: capturedInputURL,
                        audioRoutingConfig: capturedAudioRoutingConfig
                    )
                    let bmxResult = await BMXService.shared.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        mcaLabelsFile: mcaLabelsFile,
                        progress: { bmxProgress in
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                progressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )
                    if let mcaLabelsFile {
                        Self.cleanupTempFile(at: mcaLabelsFile, label: "MCA labels")
                    }

                    if !bmxResult.success {
                        Self.logger.error("bmxtranswrap failed for native waveform")
                        do {
                            try FileManager.default.copyItem(at: tempMXF, to: capturedFinalOutputURL)
                        } catch {
                            success = false
                        }
                    }
                    Self.cleanupTempFile(at: tempMXF, label: "waveform BMX rewrap temp MXF")
                }

                completion(success, errorReason)
            }
        }

        do {
            try process.run()
        } catch {
            Self.logger.error("Failed to start native waveform FFmpeg: \(error.localizedDescription, privacy: .public)")
            completion(false, "Failed to start FFmpeg: \(error.localizedDescription)")
            return
        }

        // Pre-load and scale background image (if set) once before render loop
        if let imageURL = waveformBackgroundImageURL {
            Self.logger.info("Loading waveform background image: \(imageURL.path)")
        } else {
            Self.logger.info("No waveform background image set")
        }
        let backgroundCGImage: CGImage? = if let imageURL = waveformBackgroundImageURL {
            NativeWaveformVideoRenderer.loadBackgroundImage(from: imageURL, width: waveformRequest.width, height: waveformRequest.height)
        } else {
            nil
        }

        // Phase 4: Write rendered frames to the pipe on a background task
        Task.detached { [frequencyData, waveformRequest, backgroundCGImage] in
            await WaveformFramePipeWriter.writeFrames(
                to: stdinPipe,
                frequencyData: frequencyData,
                style: waveformRequest.swiftStyle,
                width: waveformRequest.width,
                height: waveformRequest.height,
                foregroundHex: waveformRequest.foregroundHex,
                backgroundHex: waveformRequest.backgroundHex,
                foregroundGradientEnabled: waveformRequest.foregroundGradientEnabled,
                foregroundGradientEndHex: waveformRequest.foregroundGradientEndHex,
                backgroundGradientEnabled: waveformRequest.backgroundGradientEnabled,
                backgroundGradientEndHex: waveformRequest.backgroundGradientEndHex,
                backgroundImage: backgroundCGImage,
                waveformOpacity: waveformRequest.waveformOpacity,
                progressUpdate: { renderProgress in
                    // Map render progress to 10%–95% of overall progress
                    let overall = 0.10 + renderProgress * 0.85
                    progressUpdate(overall, "Rendering waveform…")
                }
            )
        }
    }

    // MARK: - Audio Extraction for Image Sequence Export

    /// Extracts the audio track from a video file as a WAV file alongside the image sequence output.
    /// Only runs if the input has audio streams. The WAV file is placed in the same subfolder as the images.
    private static func extractAudioAsWAV(
        inputURL: URL,
        outputFolder: URL,
        baseName: String,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?
    ) async {
        // Check if source has audio streams
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
              !audioStreams.isEmpty else {
            logger.debug("No audio streams in source, skipping WAV extraction")
            return
        }

        let wavOutputURL = outputFolder.appendingPathComponent("\(baseName).wav")

        var args: [String] = ["-y", "-nostdin"]

        // Apply trim start (input seeking)
        let normalizedStart = FFMPEGCommandBuilder.normalizedTrimPoint(trimStart)
        if let start = normalizedStart {
            args.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        args.append(contentsOf: ["-i", inputURL.path])

        // Apply trim duration
        if let durationArgs = FFMPEGCommandBuilder.trimDurationArgument(start: normalizedStart, end: FFMPEGCommandBuilder.normalizedTrimPoint(trimEnd)) {
            args.append(contentsOf: durationArgs)
        }

        args.append(contentsOf: [
            "-vn",           // No video
            "-c:a", "pcm_s24le",  // 24-bit WAV
            "-rf64", "auto", // Use RF64 for files >4GB
            wavOutputURL.path
        ])

        logger.info("Extracting audio as WAV: \(wavOutputURL.lastPathComponent)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.info("Audio WAV extraction complete: \(wavOutputURL.lastPathComponent)")
            } else {
                logger.warning("Audio WAV extraction failed with status \(process.terminationStatus)")
                // Clean up partial WAV file
                Self.cleanupTempFile(at: wavOutputURL, label: "partial audio WAV")
            }
        } catch {
            logger.error("Failed to start audio extraction: \(error.localizedDescription)")
        }
    }

    /// Extracts audio from source as 24-bit PCM 48 kHz WAV for SMPTE-package exports (DCP, IMF).
    /// FFmpeg's MXF muxer cannot create audio-only MXF files, so we extract to WAV first,
    /// then asdcp-wrap (DCP) or bmxtranswrap (IMF) takes over to produce the MXF essence.
    /// - Returns: URL of the audio WAV file, or nil if source has no audio or extraction failed
    /// Result of `extractAudioAsPCMWAV`. Distinguishes "source has no audio" (a legitimate
    /// silent DCP/IMF) from "extraction failed" (the user had audio but we lost it), so
    /// callers can surface the failure case to the UI instead of silently producing a
    /// package with no audio.
    enum AudioExtractionResult: Sendable {
        case extracted(URL)
        case noAudioInSource
        case failed(reason: String)
    }

    private static func extractAudioAsPCMWAV(
        inputURL: URL,
        outputFolder: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig? = nil
    ) async -> AudioExtractionResult {
        // Check if source has audio streams
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
              !audioStreams.isEmpty else {
            logger.debug("No audio streams in source, skipping audio extraction for DCP")
            return .noAudioInSource
        }

        let audioWavURL = outputFolder.appendingPathComponent("audio_temp_\(UUID().uuidString).wav")

        var args: [String] = ["-y", "-nostdin"]

        // Apply trim start (input seeking)
        let normalizedStart = FFMPEGCommandBuilder.normalizedTrimPoint(trimStart)
        if let start = normalizedStart {
            args.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        args.append(contentsOf: ["-i", inputURL.path])

        // Apply trim duration
        if let durationArgs = FFMPEGCommandBuilder.trimDurationArgument(start: normalizedStart, end: FFMPEGCommandBuilder.normalizedTrimPoint(trimEnd)) {
            args.append(contentsOf: durationArgs)
        }

        // Always suppress video output
        args.append(contentsOf: ["-vn"])

        // Determine which audio streams to use based on routing config
        // If audio routing is configured, use the selected output tracks.
        // Otherwise, only amerge when ALL streams are mono (e.g. separate mono tracks
        // that should be combined). For multi-channel streams (5.1, 7.1, etc.),
        // just use the first stream.
        let selectedStreamIndices: [Int]
        if let routing = audioRoutingConfig, routing.isCustomized {
            selectedStreamIndices = routing.outputTrackIndices
            if selectedStreamIndices.count > 1 {
                logger.info("DCP audio: using \(selectedStreamIndices.count) streams from audio routing config")
            }
        } else {
            // Check if all streams are mono — if so, merge them all
            let allMono = audioStreams.allSatisfy { ($0.channels ?? 0) == 1 }
            if allMono && audioStreams.count > 1 {
                selectedStreamIndices = audioStreams.enumerated().map { $0.offset }
                logger.info("DCP audio: merging \(audioStreams.count) mono streams into one multi-channel output")
            } else {
                // Multiple non-mono streams (e.g. 10x 5.1 surround) — use only the first
                selectedStreamIndices = [0]
                if audioStreams.count > 1 {
                    logger.warning("DCP audio: source has \(audioStreams.count) multi-channel audio streams — using only the first stream. Configure audio routing to select a different track.")
                }
            }
        }

        // For multiple selected streams that are all mono, amerge them.
        // Otherwise, map a single stream.
        let selectedAllMono = selectedStreamIndices.allSatisfy { idx in
            let channels = audioStreams.indices.contains(idx) ? (audioStreams[idx].channels ?? 0) : 0
            return channels == 1
        }
        if selectedStreamIndices.count > 1 && selectedAllMono {
            var filterInputs = ""
            for idx in selectedStreamIndices {
                filterInputs += "[0:a:\(idx)]"
            }
            args.append(contentsOf: [
                "-filter_complex", "\(filterInputs)amerge=inputs=\(selectedStreamIndices.count)[aout]",
                "-map", "[aout]",
            ])
        } else {
            // Map a single audio stream
            args.append(contentsOf: ["-map", "0:a:\(selectedStreamIndices[0])"])
        }

        args.append(contentsOf: [
            "-c:a", "pcm_s24le",     // 24-bit PCM
            "-ar", "48000",          // 48 kHz (DCI standard)
            audioWavURL.path
        ])

        logger.info("Extracting audio as WAV for DCP: \(audioWavURL.lastPathComponent) (streams: \(selectedStreamIndices))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Capture stderr for debugging
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            try? stderrPipe.fileHandleForReading.close()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                logger.info("Audio WAV extraction complete: \(audioWavURL.lastPathComponent)")
                return .extracted(audioWavURL)
            } else {
                logger.error("Audio WAV extraction failed (status \(process.terminationStatus)): \(stderrStr.suffix(300))")
                Self.cleanupTempFile(at: audioWavURL, label: "failed audio WAV")
                return .failed(reason: "ffmpeg exit \(process.terminationStatus)")
            }
        } catch {
            try? stderrPipe.fileHandleForReading.close()
            logger.error("Failed to start audio WAV extraction: \(error.localizedDescription)")
            return .failed(reason: error.localizedDescription)
        }
    }

    func cancelConversion() async {
        currentProcess?.terminate()
        auxProcess?.terminate()
        for worker in av2Workers where worker.isRunning { worker.terminate() }
        av2Workers.removeAll()
        await setCurrentProcess(nil)
        await setAuxProcess(nil)
    }

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
    }

    private func setAuxProcess(_ process: Process?) async {
        self.auxProcess = process
    }

    private final class DurationBox: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Optional<Double>.none)

        var value: Double? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    static func getVideoDuration(url: URL) async -> Double? {
        await FFMPEGProbeService.getVideoDuration(for: url)
    }

    /// Pads (or, if already long enough, leaves alone) a 48 kHz PCM WAV so it has
    /// at least `frameCount` picture frames worth of samples. Required by the
    /// IMF audio path: asdcp-wrap writes a frame-rate-keyed edit-unit index
    /// claiming one entry per picture frame, but the index is computed from the
    /// expected duration — if the WAV is short of that by even a fractional
    /// frame, the resulting MXF has an index entry pointing past the end of the
    /// essence and Resolve refuses to play it (mxf2raw also reports the file as
    /// "general error" with a "last edit unit not available" message).
    ///
    /// For non-integer rates (29.97, 59.94) the per-frame sample count is not
    /// integer, so we use a ceiling on `frameCount × 48000 × den / num` — a
    /// slight overshoot is fine, asdcp-wrap takes only what it needs.
    private static func padWAVToFrameCount(
        inputWAV: URL,
        frameCount: Int,
        editRateNumerator: Int,
        editRateDenominator: Int,
        ffmpegPath: String
    ) async -> URL? {
        guard frameCount > 0, editRateNumerator > 0, editRateDenominator > 0 else { return nil }
        let totalSamples = Int(ceil(Double(frameCount) * 48000.0 * Double(editRateDenominator) / Double(editRateNumerator)))
        let outputWAV = inputWAV.deletingLastPathComponent()
            .appendingPathComponent("audio_padded_\(UUID().uuidString).wav")

        let args: [String] = [
            "-y", "-nostdin",
            "-i", inputWAV.path,
            "-af", "apad=whole_len=\(totalSamples)",
            "-c:a", "pcm_s24le",
            "-ar", "48000",
            outputWAV.path
        ]
        print("[IMF] padding WAV to \(totalSamples) samples (\(frameCount) frames × \(editRateNumerator)/\(editRateDenominator))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        // Drain stderr to avoid pipe-buffer deadlock on long runs.
        let stderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.withLock { $0.append(chunk) }
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrPipe.fileHandleForReading.close()
            print("[IMF] WAV pad ffmpeg launch threw: \(error.localizedDescription)")
            return nil
        }
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stderrPipe.fileHandleForReading.close()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrBuffer.withLock { $0 }
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            print("[IMF] WAV pad ffmpeg exited \(process.terminationStatus): \(stderrStr.prefix(400))")
            try? FileManager.default.removeItem(at: outputWAV)
            return nil
        }
        return outputWAV
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
        let stdoutPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = stdoutPipe

        do {
            try process.run()
            process.waitUntilExit()

            try? stdoutPipe.fileHandleForReading.close()
            if process.terminationStatus == 0 {
                try? errorPipe.fileHandleForReading.close()
                Self.logger.info("Audio pre-processing succeeded: \(targetChannelCount) mono channels created")
                return tempURL
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                try? errorPipe.fileHandleForReading.close()
                let errorString = String(data: errorData, encoding: .utf8) ?? "(unknown error)"
                Self.logger.error("Audio pre-processing failed with code \(process.terminationStatus): \(errorString)")
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    Self.cleanupTempFile(at: tempURL, label: "AVC-Intra pre-processed audio (failed)")
                }
                return nil
            }
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            Self.logger.error("Failed to run audio pre-processing: \(error.localizedDescription)")
            if FileManager.default.fileExists(atPath: tempURL.path) {
                Self.cleanupTempFile(at: tempURL, label: "AVC-Intra pre-processed audio (failed)")
            }
            return nil
        }
    }
}
