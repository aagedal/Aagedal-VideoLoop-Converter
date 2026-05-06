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
            waveformRequest: request.waveformRequest,
            synthesizedVideoRequest: request.synthesizedVideoRequest,
            customInputArguments: effectiveCustomInputArguments,
            additionalOutputArguments: request.additionalOutputArguments,
            isMuted: request.isMuted
        )

        process.arguments = command.arguments

        Self.logger.info("FFmpeg command: \(ffmpegPath, privacy: .public) \(command.arguments.joined(separator: " "), privacy: .public)")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice  // Prevent FFmpeg from waiting for stdin

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
                    let bmxSuccess = await BMXService.shared.rewrapToOP1a(
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
                        // J2K → asdcp-wrap (mirror DCP path; SMPTE Universal Labels via -L work for IMF App #2e too).
                        let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                        let resolvedAsdcpPath = BinaryPathResolver.asdcpWrapPath
                        print("[IMF] App 2e branch — asdcp-wrap path: \(resolvedAsdcpPath ?? "<nil>"), jp2Dir=\(jp2Dir.path)")
                        if let asdcpWrapPath = resolvedAsdcpPath {
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
                                // UI shows what's happening between FFmpeg finishing and asdcp-wrap.
                                // Also accumulate total J2C bytes so the asdcp-wrap poller below
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

                                let videoWrapArgs: [String] = [
                                    "-v",
                                    "-p", frameRate.ffmpegValue,
                                    "-L",
                                    j2cDir.path + "/",
                                    tmpVideoMXF.path
                                ]
                                let videoWrapProcess = Process()
                                videoWrapProcess.executableURL = URL(fileURLWithPath: asdcpWrapPath)
                                videoWrapProcess.arguments = videoWrapArgs
                                videoWrapProcess.standardInput = FileHandle.nullDevice
                                let stderrPipe = Pipe()
                                videoWrapProcess.standardOutput = stderrPipe
                                videoWrapProcess.standardError = stderrPipe
                                progressUpdate(0.80, "Wrapping J2C → MXF")
                                print("[IMF] launching asdcp-wrap: \(videoWrapArgs.joined(separator: " "))")
                                // Drain the merged stdout/stderr pipe in real time. asdcp-wrap is
                                // launched with `-v` (verbose) and emits one informational line per
                                // wrapped frame; without an active reader the pipe (16–64 KB on
                                // macOS) fills, asdcp-wrap blocks on `write()`, and the MXF stops
                                // growing — exactly the "frozen at 82%" deadlock observed on long
                                // sources. The buffer keeps the bytes around for error reporting.
                                let stderrBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                                    let chunk = handle.availableData
                                    guard !chunk.isEmpty else { return }
                                    stderrBuffer.withLock { $0.append(chunk) }
                                }
                                do {
                                    try videoWrapProcess.run()
                                    // asdcp-wrap has no progress flag; poll the output MXF size
                                    // and estimate progress as bytes-written / expected-essence-size.
                                    // The MXF holds the J2C codestreams plus a small index/header
                                    // overhead, so total J2C bytes is a tight lower-bound estimate.
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
                                    print("[IMF] asdcp-wrap exited with status \(videoWrapProcess.terminationStatus)")
                                    if videoWrapProcess.terminationStatus == 0 {
                                        imfVideoMXF = tmpVideoMXF
                                        Self.logger.info("IMF video essence created (App #2e)")
                                    } else {
                                        Self.logger.error("asdcp-wrap failed for IMF video (status \(videoWrapProcess.terminationStatus)): \(stderrStr.prefix(300))")
                                        errorReason = Self.dcpIMFErrorReason(
                                            base: String(localized: "IMF video wrap failed (asdcp-wrap exit \(Int(videoWrapProcess.terminationStatus)))", comment: "Shown when asdcp-wrap exits with a non-zero status while wrapping the IMF App 2e video essence."),
                                            stderr: stderrStr
                                        )
                                        success = false
                                        Self.cleanupTempFile(at: tmpVideoMXF, label: "failed IMF video MXF")
                                    }
                                } catch {
                                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                                    try? stderrPipe.fileHandleForReading.close()
                                    Self.logger.error("Failed to run asdcp-wrap for IMF video: \(error.localizedDescription)")
                                    print("[IMF] asdcp-wrap launch threw: \(error.localizedDescription)")
                                    errorReason = String(localized: "IMF video wrap failed: \(error.localizedDescription)", comment: "Shown when launching the asdcp-wrap process for IMF video throws an exception.")
                                    success = false
                                }
                                Self.cleanupTempFile(at: j2cDir, label: "IMF J2C frames")
                            }
                        } else {
                            Self.logger.error("asdcp-wrap not found — cannot create IMF App 2e essence")
                            errorReason = String(localized: "IMF video wrap failed: asdcp-wrap not found", comment: "Shown when the bundled asdcp-wrap binary cannot be located, blocking the IMF App 2e export.")
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

                        let bmxColorPrimaries: String?
                        let bmxTransfer: String?
                        let bmxCodingEq: String?
                        switch color {
                        case .rec709:
                            bmxColorPrimaries = "709"; bmxTransfer = "709"; bmxCodingEq = "709"
                        case .rec2020SDR, .rec2020PQ, .rec2020HLG:
                            bmxColorPrimaries = "2020"; bmxTransfer = nil; bmxCodingEq = "2020"
                        }

                        let bmxOK = await BMXService.shared.rewrapToIMFOP1a(
                            inputURL: capturedFinalOutputURL,
                            outputURL: tmpVideoMXF,
                            colorPrimaries: bmxColorPrimaries,
                            transferCharacteristic: bmxTransfer,
                            codingEquations: bmxCodingEq,
                            clipName: capturedInputBaseName,
                            mcaLabelsFile: nil,
                            progress: { bmxProgress in
                                // Map bmx 0..1 onto the 0.78 → 0.84 sub-band of overall progress.
                                let overall = 0.78 + bmxProgress * 0.06
                                let pct = Int(bmxProgress * 100)
                                progressUpdate(overall, "Wrapping ProRes → MXF \(pct)%")
                            }
                        )
                        if bmxOK {
                            imfVideoMXF = tmpVideoMXF
                            Self.logger.info("IMF video essence created (App #5)")
                        } else {
                            Self.logger.error("bmxtranswrap failed for IMF ProRes video essence")
                            errorReason = String(localized: "IMF video wrap failed: bmxtranswrap rejected ProRes essence", comment: "Shown when bmxtranswrap cannot rewrap the ProRes MOV into IMF App 5 OP1a MXF.")
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

                        if let wavURL = audioWavURL {
                            progressUpdate(0.90, "Wrapping audio essence")
                            print("[IMF] wrapping audio essence")
                            let tmpAudioMXF = FileManager.default.temporaryDirectory
                                .appendingPathComponent("imf_audio_\(UUID().uuidString).mxf")

                            let mcaLabelsFile = await MCALabelsBuilder.buildIMFLabelsFile(
                                inputURL: capturedInputURL,
                                audioRoutingConfig: capturedRequest.audioRoutingConfig
                            )

                            let bmxAudioOK = await BMXService.shared.rewrapToIMFOP1a(
                                inputURL: wavURL,
                                outputURL: tmpAudioMXF,
                                colorPrimaries: nil,
                                transferCharacteristic: nil,
                                codingEquations: nil,
                                clipName: capturedInputBaseName + "_audio",
                                mcaLabelsFile: mcaLabelsFile,
                                progress: { bmxProgress in
                                    // Map bmx 0..1 onto the 0.90 → 0.94 sub-band of overall progress.
                                    let overall = 0.90 + bmxProgress * 0.04
                                    let pct = Int(bmxProgress * 100)
                                    progressUpdate(overall, "Wrapping audio essence \(pct)%")
                                }
                            )
                            if let mcaLabelsFile {
                                Self.cleanupTempFile(at: mcaLabelsFile, label: "IMF MCA labels")
                            }
                            if bmxAudioOK {
                                imfAudioMXF = tmpAudioMXF
                            } else {
                                Self.logger.error("bmxtranswrap failed for IMF audio essence")
                                errorReason = String(localized: "IMF audio wrap failed: bmxtranswrap rejected audio essence", comment: "Shown when bmxtranswrap cannot wrap the extracted PCM audio into the IMF audio MXF; the package would otherwise be missing audio.")
                                success = false
                                Self.cleanupTempFile(at: tmpAudioMXF, label: "failed IMF audio MXF")
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
                    let bmxSuccess = await BMXService.shared.rewrapToOP1a(
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

                    if !bmxSuccess {
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
        await setCurrentProcess(nil)
    }

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
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
