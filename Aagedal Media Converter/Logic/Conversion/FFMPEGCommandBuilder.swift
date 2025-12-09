//
//  FFMPEGCommandBuilder.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

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

struct FFMPEGCommand {
    let arguments: [String]
    let normalizedTrimStart: Double?
    let normalizedTrimEnd: Double?
    let effectiveDuration: Double?
}

struct WaveformVideoRequest {
    let width: Int
    let height: Int
    let backgroundHex: String
    let foregroundHex: String
    let normalizeAudio: Bool
    let style: WaveformStyle
    let frameRate: Double

    var resolutionString: String {
        "\(width)x\(height)"
    }

    var backgroundFFmpegColor: String {
        "0x" + backgroundHex
    }

    var foregroundFFmpegColor: String {
        "0x" + foregroundHex
    }
}

struct SynthesizedVideoRequest {
    let width: Int
    let height: Int
    let backgroundHex: String
    let frameRate: Double
    let includeAudio: Bool

    var backgroundFFmpegColor: String {
        "0x" + backgroundHex
    }
}

enum FFMPEGCommandBuilder {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformCommand")
    static func buildCommand(
        inputURL: URL,
        outputFileURL: URL,
        preset: ExportPreset,
        comment: String,
        includeDateTag: Bool,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        cropConfig: CropConfig? = nil,
        timecodeConfig: TimecodeConfig? = nil,
        waveformRequest: WaveformVideoRequest? = nil,
        synthesizedVideoRequest: SynthesizedVideoRequest? = nil,
        customInputArguments: [String]? = nil,
        additionalOutputArguments: [String]? = nil
    ) async -> FFMPEGCommand {
        var arguments = ["-y"]

        let normalizedTrimStart = normalizedTrimPoint(trimStart)
        let normalizedTrimEnd = normalizedTrimPoint(trimEnd)

        if let normalizedTrimStart {
            arguments.append(contentsOf: ["-ss", ffmpegTimeString(from: normalizedTrimStart)])
        }

        if let customInputArguments {
            arguments.append(contentsOf: customInputArguments)
        } else {
            arguments.append(contentsOf: ["-i", inputURL.path])
        }

        if let waveformRequest {
            let includeAudioOutput = preset.outputsAudioTrack
            logger.debug("Building waveform command with request: width=\(waveformRequest.width), height=\(waveformRequest.height), background=\(waveformRequest.backgroundHex, privacy: .public), foreground=\(waveformRequest.foregroundHex, privacy: .public), normalize=\(waveformRequest.normalizeAudio), style=\(waveformRequest.style.rawValue, privacy: .public)")
            if let durationArgument = trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
                arguments.append(contentsOf: durationArgument)
            }

            arguments.append(contentsOf: waveformCommandArguments(for: waveformRequest, includeAudioOutput: includeAudioOutput, audioRoutingConfig: audioRoutingConfig))

            var ffmpegArgs = preset.ffmpegArguments
            await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if !includeAudioOutput {
                removeArgumentPair("-map", value: "[audout]", from: &arguments)
            }
            applyCommentMetadata(
                to: &ffmpegArgs,
                comment: comment,
                includeDateTag: includeDateTag
            )

            arguments.append(contentsOf: ffmpegArgs)
            if let additionalOutputArguments {
                arguments.append(contentsOf: additionalOutputArguments)
            }
            logger.debug("Waveform ffmpeg arguments: \(arguments.joined(separator: " "), privacy: .public)")
            arguments.append(outputFileURL.path)

            let effectiveDuration = calculateEffectiveDuration(trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)

            return FFMPEGCommand(
                arguments: arguments,
                normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd,
                effectiveDuration: effectiveDuration
            )
        } else if let synthesizedVideoRequest {
            logger.debug("Building synthesized video command with request: width=\(synthesizedVideoRequest.width), height=\(synthesizedVideoRequest.height), background=\(synthesizedVideoRequest.backgroundHex, privacy: .public), frameRate=\(synthesizedVideoRequest.frameRate)")
            if let durationArgument = trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
                arguments.append(contentsOf: durationArgument)
            }

            arguments.append(contentsOf: synthesizedVideoCommandArguments(for: synthesizedVideoRequest))

            var ffmpegArgs = preset.ffmpegArguments
            await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if synthesizedVideoRequest.includeAudio {
                removeArgumentPair("-an", value: nil, from: &ffmpegArgs)
            }
            
            // Apply audio routing configuration if provided and preset supports audio and audio routing
            if let audioRoutingConfig, preset.outputsAudioTrack, preset.appliesAudioRouting {
                applyAudioRouting(config: audioRoutingConfig, to: &ffmpegArgs)
            }
            
            applyCommentMetadata(
                to: &ffmpegArgs,
                comment: comment,
                includeDateTag: includeDateTag
            )

            arguments.append(contentsOf: ffmpegArgs)
            if let additionalOutputArguments {
                arguments.append(contentsOf: additionalOutputArguments)
            }
            logger.debug("Synthesized video ffmpeg arguments: \(arguments.joined(separator: " "), privacy: .public)")
            arguments.append(outputFileURL.path)

            let effectiveDuration = calculateEffectiveDuration(trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)

            return FFMPEGCommand(
                arguments: arguments,
                normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd,
                effectiveDuration: effectiveDuration
            )
        }

        var ffmpegArgs = preset.ffmpegArguments
        await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
        await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)

        // Apply crop to video filter if configured and preset supports it
        if let cropConfig = cropConfig,
           cropConfig.isActive,
           preset.outputsVideoTrack,
           preset.appliesCrop {
            if let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL),
               let width = metadata.videoStream?.width,
               let height = metadata.videoStream?.height {
                applyCropToVideoFilter(
                    &ffmpegArgs,
                    cropConfig: cropConfig,
                    sourceWidth: width,
                    sourceHeight: height
                )
            }
        }

        // Only remove video arguments if preset doesn't output video (audio-only export)
        if !preset.outputsVideoTrack {
            removeVideoArguments(from: &ffmpegArgs)
        }
        
        // Apply audio routing configuration if provided and preset supports audio and audio routing
        if let audioRoutingConfig, preset.outputsAudioTrack, preset.appliesAudioRouting {
            applyAudioRouting(config: audioRoutingConfig, to: &ffmpegArgs)
        }

        applyCommentMetadata(
            to: &ffmpegArgs,
            comment: comment,
            includeDateTag: includeDateTag
        )

        // Apply timecode configuration if preset outputs video
        if preset.outputsVideoTrack {
            // Use provided config, or default from settings
            let effectiveConfig: TimecodeConfig?
            if let timecodeConfig = timecodeConfig {
                effectiveConfig = timecodeConfig
            } else {
                // Use default from settings
                let defaultMode = UserDefaults.standard.string(forKey: AppConstants.defaultTimecodeModeKey) ?? AppConstants.defaultTimecodeModeRaw
                let defaultValue = UserDefaults.standard.string(forKey: AppConstants.defaultTimecodeValueKey) ?? AppConstants.defaultTimecodeValue

                switch defaultMode {
                case "preserveSource":
                    effectiveConfig = TimecodeConfig(mode: .preserveSource)
                case "manual":
                    effectiveConfig = TimecodeConfig(mode: .manual(defaultValue))
                default: // "disabled"
                    // Skip timecode application if disabled by default
                    effectiveConfig = nil
                }
            }

            if let effectiveConfig = effectiveConfig,
               effectiveConfig.isActive,
               let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL) {
                await applyTimecode(
                    &ffmpegArgs,
                    timecodeConfig: effectiveConfig,
                    sourceMetadata: metadata,
                    trimStart: normalizedTrimStart
                )
            }
        }

        if let durationArgument = trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
            arguments.append(contentsOf: durationArgument)
        }

        arguments.append(contentsOf: ffmpegArgs)

        // For MOV/QuickTime files with stream copy, add movflags to preserve vendor-specific metadata
        // This is critical for ProRes RAW files to preserve white balance and camera metadata
        if preset == .streamCopy {
            let inputExtension = inputURL.pathExtension.lowercased()
            let outputExtension = outputFileURL.pathExtension.lowercased()
            if (inputExtension == "mov" || outputExtension == "mov") {
                // Add use_metadata_tags to preserve custom QuickTime atoms (com.apple.*, com.atomos.*, org.smpte.*)
                arguments.append(contentsOf: ["-movflags", "use_metadata_tags"])
            }
        }

        if let additionalOutputArguments {
            arguments.append(contentsOf: additionalOutputArguments)
        }
        arguments.append(outputFileURL.path)

        let effectiveDuration = calculateEffectiveDuration(trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)

        return FFMPEGCommand(
            arguments: arguments,
            normalizedTrimStart: normalizedTrimStart,
            normalizedTrimEnd: normalizedTrimEnd,
            effectiveDuration: effectiveDuration
        )
    }
}

extension FFMPEGCommandBuilder {
    static func normalizedTrimPoint(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return max(value, 0)
    }

    static func ffmpegTimeString(from seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    static func trimDurationArgument(start: Double?, end: Double?) -> [String]? {
        switch (start, end) {
        case let (nil, .some(endSeconds)) where endSeconds > 0:
            return ["-to", ffmpegTimeString(from: endSeconds)]
        case let (.some(startSeconds), .some(endSeconds)):
            let duration = max(endSeconds - startSeconds, 0)
            guard duration > 0 else { return nil }
            return ["-t", ffmpegTimeString(from: duration)]
        default:
            return nil
        }
    }

    static func calculateEffectiveDuration(trimStart: Double?, trimEnd: Double?) -> Double? {
        if let start = trimStart, let end = trimEnd {
            return max(end - start, 0)
        } else if let end = trimEnd {
            return end
        }
        return nil
    }
    
    /// Builds audio routing filter segments for waveform video generation
    /// - Parameter config: The audio routing configuration
    /// - Returns: Tuple of (filter segments, output label for routed audio)
    private static func buildAudioRoutingFilters(config: AudioRoutingConfig) -> (segments: [String], outputLabel: String) {
        // Check if we need channel operations (filter_complex)
        if let operation = config.channelOperation {
            let outputLabel = "arouted"
            let filterSegment: String
            
            switch operation {
            case .mergeToStereo(let trackIndices):
                guard trackIndices.count >= 2 else {
                    // Fallback to simple track selection
                    return buildSimpleTrackRoutingFilters(config: config)
                }
                
                let inputs = trackIndices.map { "[0:a:\($0)]" }.joined()
                if trackIndices.count == 2 {
                    // Simple stereo merge: combine two mono tracks
                    filterSegment = "\(inputs)amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[\(outputLabel)]"
                } else {
                    // Multiple tracks: merge all into multi-channel, then downmix to stereo
                    filterSegment = "\(inputs)amerge=inputs=\(trackIndices.count),pan=stereo|c0<c0|c1<c1[\(outputLabel)]"
                }
                
            case .splitToMono(let trackIndex):
                // For waveform video, we need to merge split channels back to visualize
                // Split then immediately merge them back to stereo for visualization
                filterSegment = "[0:a:\(trackIndex)]channelsplit=channel_layout=stereo[L][R];[L][R]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[\(outputLabel)]"
                
            case .swapChannels(let trackIndex):
                filterSegment = "[0:a:\(trackIndex)]pan=stereo|c0=c1|c1=c0[\(outputLabel)]"
                
            case .extractChannel(let trackIndex, let channelIndex, _):
                // Extract channel but convert to mono for visualization
                filterSegment = "[0:a:\(trackIndex)]pan=mono|c0=c\(channelIndex)[\(outputLabel)]"
            }
            
            return ([filterSegment], outputLabel)
        } else {
            // Simple track selection without channel operations
            return buildSimpleTrackRoutingFilters(config: config)
        }
    }
    
    /// Builds simple track selection filters for waveform video
    private static func buildSimpleTrackRoutingFilters(config: AudioRoutingConfig) -> (segments: [String], outputLabel: String) {
        if config.outputTrackIndices.count == 1 {
            // Single track: use directly
            let trackIndex = config.outputTrackIndices[0]
            return ([], "0:a:\(trackIndex)")
        } else if config.outputTrackIndices.count > 1 {
            // Multiple tracks: merge them for visualization
            let outputLabel = "arouted"
            let inputs = config.outputTrackIndices.map { "[0:a:\($0)]" }.joined()
            let filterSegment = "\(inputs)amerge=inputs=\(config.outputTrackIndices.count),pan=stereo|c0<c0|c1<c1[\(outputLabel)]"
            return ([filterSegment], outputLabel)
        } else {
            // No tracks selected: fallback to all audio
            return ([], "0:a")
        }
    }

    static func waveformFilterGraph(for request: WaveformVideoRequest, includeAudioSplit: Bool, audioRoutingConfig: AudioRoutingConfig? = nil) -> (filterComplex: String, videoMap: String, audioMap: String?) {
        let finalWidth = evenDimension(max(request.width, 2))
        let finalHeight = evenDimension(max(request.height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let background = request.backgroundFFmpegColor
        let foreground = request.foregroundFFmpegColor
        let frameRateValue = max(1, Int(round(request.frameRate)))

        let channelLayout = request.style == .circle ? "mono" : "stereo"
        var audioFilters = ["aformat=channel_layouts=\(channelLayout)"]
        if request.normalizeAudio {
            audioFilters.append("dynaudnorm=f=250:g=30:p=0.9")
        }

        if request.style == .lines {
            audioFilters.append("compand")
        }

        let audioProcessing = audioFilters.joined(separator: ",")
        let waveInputLabel = includeAudioSplit ? "wavesrc" : "audproc"

        var segments: [String] = []
        
        // Apply audio routing if configured
        let audioInputLabel: String
        if let routingConfig = audioRoutingConfig {
            // Generate audio routing filters
            let (routingSegments, routingOutputLabel) = buildAudioRoutingFilters(config: routingConfig)
            segments.append(contentsOf: routingSegments)
            audioInputLabel = routingOutputLabel
        } else {
            // Default: use all audio from input
            audioInputLabel = "0:a"
        }
        
        var audioSegment = "[\(audioInputLabel)]\(audioProcessing)"
        if includeAudioSplit {
            audioSegment += ",asplit=2[\(waveInputLabel)][audout]"
        } else {
            audioSegment += "[\(waveInputLabel)]"
        }
        segments.append(audioSegment)

        segments.append("color=c=\(background):s=\(resolution):d=1[bg]")

        switch request.style {
        case .circle:
            let showwavesArgs = "showwaves=s=\(resolution):mode=cline:draw=full:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            let polarExpression = "mod(W/PI*(PI+atan2(H/2-Y,X-W/2)),W)"
            let radiusExpression = "H-2*hypot(H/2-Y,X-W/2)"
            segments.append("[\(waveInputLabel)]\(showwavesArgs)[wave_linear]")
            segments.append("[wave_linear]geq='p(\(polarExpression),\(radiusExpression))':a='alpha(\(polarExpression),\(radiusExpression))'[wave]")
        case .linear:
            let waveformFilter = "showwaves=s=\(resolution):mode=cline:draw=scale:scale=sqrt:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            segments.append("[\(waveInputLabel)]\(waveformFilter)[wave]")
        case .lines:
            let waveformFilter = "showwaves=s=\(resolution):mode=p2p:draw=full:scale=sqrt:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            segments.append("[\(waveInputLabel)]\(waveformFilter)[wave]")
        case .fisheye:
            let showwavesArgs = "showwaves=s=\(resolution):mode=cline:rate=\(frameRateValue):colors=\(foreground):draw=scale"
            let fisheyeArgs = "v360=input=fisheye:output=equirect:interp=lanczos:w=\(finalWidth):h=\(finalHeight):ih_fov=360:iv_fov=180"
            segments.append("[\(waveInputLabel)]\(showwavesArgs)[wave_linear]")
            segments.append("[wave_linear]\(fisheyeArgs)[wave]")
        case .spectrogram:
            let spectrumArgs = "showspectrum=mode=separate:color=intensity:scale=log:slide=scroll:s=\(resolution):overlap=0.75"
            segments.append("[\(waveInputLabel)]\(spectrumArgs)[wave]")
        }

        segments.append("[bg][wave]overlay=format=auto[outv]")

        let filterComplex = segments.joined(separator: ";")
        let audioMap = includeAudioSplit ? "[audout]" : nil
        return (filterComplex, "[outv]", audioMap)
    }

    static func waveformCommandArguments(for request: WaveformVideoRequest, includeAudioOutput: Bool, audioRoutingConfig: AudioRoutingConfig? = nil) -> [String] {
        let components = waveformFilterGraph(for: request, includeAudioSplit: includeAudioOutput, audioRoutingConfig: audioRoutingConfig)

        var arguments: [String] = [
            "-filter_complex", components.filterComplex,
            "-map", components.videoMap
        ]

        if includeAudioOutput, let audioMap = components.audioMap {
            arguments.append(contentsOf: ["-map", audioMap])
        }

        if request.frameRate.isFinite, request.frameRate > 0 {
            let sanitizedFrameRate = formattedFrameRateString(from: request.frameRate)
            arguments.append(contentsOf: ["-r", sanitizedFrameRate])
        }

        arguments.append("-shortest")

        return arguments
    }

    private static func formattedFrameRateString(from value: Double) -> String {
        guard value.isFinite, value > 0 else { return "1" }

        let rounded = round(value * 1000) / 1000
        if abs(rounded.rounded() - rounded) < 0.001 {
            return String(Int(rounded.rounded()))
        }

        var string = String(format: "%.3f", rounded)
        while string.last == "0" {
            string.removeLast()
        }
        if string.last == "." {
            string.removeLast()
        }

        return string.isEmpty ? "1" : string
    }

    static func evenDimension(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }

    static func applyCommentMetadata(to ffmpegArgs: inout [String], comment: String, includeDateTag: Bool) {
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let commentMetadataValue: String? = {
            if includeDateTag {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd"
                let currentDateString = dateFormatter.string(from: Date())
                let commentSuffix = trimmedComment.isEmpty ? "" : " | \(trimmedComment)"
                return "comment=Date generated: \(currentDateString)\(commentSuffix)"
            } else if !trimmedComment.isEmpty {
                return "comment=\(trimmedComment)"
            } else {
                return nil
            }
        }()

        if let metadataValueIndex = ffmpegArgs.firstIndex(where: { $0.contains("comment=Date generated:") }) {
            if let commentMetadataValue {
                ffmpegArgs[metadataValueIndex] = commentMetadataValue
            } else {
                let metadataKeyIndex = metadataValueIndex - 1
                ffmpegArgs.remove(at: metadataValueIndex)
                if metadataKeyIndex >= 0,
                   metadataKeyIndex < ffmpegArgs.count,
                   ffmpegArgs[metadataKeyIndex] == "-metadata" {
                    ffmpegArgs.remove(at: metadataKeyIndex)
                }
            }
        } else if let commentMetadataValue {
            var hasCommentMetadata = false
            var metadataScanIndex = 0
            while metadataScanIndex < ffmpegArgs.count - 1 {
                if ffmpegArgs[metadataScanIndex] == "-metadata",
                   ffmpegArgs[metadataScanIndex + 1].hasPrefix("comment=") {
                    hasCommentMetadata = true
                    break
                }
                metadataScanIndex += 1
            }
            if !hasCommentMetadata {
                ffmpegArgs.append(contentsOf: ["-metadata", commentMetadataValue])
            }
        }
    }

    static func applyTimecode(
        _ ffmpegArgs: inout [String],
        timecodeConfig: TimecodeConfig,
        sourceMetadata: VideoMetadata,
        trimStart: Double?
    ) async {
        let timecodeValue: String?

        switch timecodeConfig.mode {
        case .preserveSource:
            // Use timecode from source metadata, offsetting by trim-in point if present
            if let sourceTimecode = sourceMetadata.timecode,
               let trimOffset = trimStart,
               trimOffset > 0,
               let frameRate = sourceMetadata.videoStream?.frameRate?.value {
                timecodeValue = offsetTimecode(sourceTimecode, bySeconds: trimOffset, frameRate: frameRate)
            } else {
                timecodeValue = sourceMetadata.timecode
            }
        case .manual(let tc):
            // Use manually specified timecode
            timecodeValue = tc.isEmpty ? nil : tc
        }

        // Remove existing timecode metadata if present in args
        var index = 0
        while index < ffmpegArgs.count - 1 {
            if ffmpegArgs[index] == "-metadata" && ffmpegArgs[index + 1].hasPrefix("timecode=") {
                ffmpegArgs.remove(at: index + 1)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        if let timecode = timecodeValue {
            // Set our timecode value
            // This should override any timecode from -map_metadata since it comes later in args
            ffmpegArgs.append(contentsOf: ["-metadata", "timecode=\(timecode)"])
        }
    }

    /// Offsets a timecode string by a given number of seconds
    /// - Parameters:
    ///   - timecode: Source timecode in format HH:MM:SS:FF or HH:MM:SS;FF
    ///   - seconds: Number of seconds to offset
    ///   - frameRate: Frame rate of the video
    /// - Returns: Offset timecode string, or original if parsing fails
    private static func offsetTimecode(_ timecode: String, bySeconds seconds: Double, frameRate: Double) -> String {
        // Parse timecode components
        let components = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let secs = Int(components[2]),
              let frames = Int(components[3]) else {
            logger.warning("Failed to parse timecode: \(timecode, privacy: .public)")
            return timecode
        }

        // Determine frame rate (round to nearest integer for frame calculation)
        let fps = Int(frameRate.rounded())

        // Convert timecode to total frames
        var totalFrames = hours * 3600 * fps
        totalFrames += minutes * 60 * fps
        totalFrames += secs * fps
        totalFrames += frames

        // Add offset in frames (round to nearest frame to avoid off-by-one errors)
        let offsetFrames = Int(round(seconds * Double(fps)))
        totalFrames += offsetFrames

        // Ensure non-negative
        totalFrames = max(0, totalFrames)

        // Convert back to timecode components
        let newFrames = totalFrames % fps
        var remainingFrames = totalFrames / fps

        let newSeconds = remainingFrames % 60
        remainingFrames /= 60

        let newMinutes = remainingFrames % 60
        remainingFrames /= 60

        let newHours = remainingFrames % 24

        // Preserve the separator (: for non-drop-frame, ; for drop-frame)
        let separator = timecode.contains(";") ? ";" : ":"

        // Build new timecode
        let offsetTimecode = String(format: "%02d:%02d:%02d%@%02d",
                                    newHours,
                                    newMinutes,
                                    newSeconds,
                                    separator,
                                    newFrames)

        logger.debug("Offset timecode from \(timecode, privacy: .public) to \(offsetTimecode, privacy: .public) (offset: \(seconds, privacy: .public)s at \(frameRate, privacy: .public)fps)")

        return offsetTimecode
    }

    static func adjustArgumentsForInput(
        preset: ExportPreset,
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        guard preset == .audioUncompressedWAV else { return }
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
              audioStreams.count > 1 else {
            return
        }

        removeArgumentPair("-map", value: "0:a", from: &ffmpegArgs)

        let totalChannels = audioStreams.compactMap { $0.channels }.reduce(0, +)
        let filterInputs = audioStreams.indices.map { "[0:a:\($0)]" }.joined()
        let filterGraph = "\(filterInputs)amerge=inputs=\(audioStreams.count)[aout]"

        ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph, "-map", "[aout]"])

        if totalChannels > 0 {
            ffmpegArgs.append(contentsOf: ["-ac", "\(totalChannels)"])
        }
    }

    static func removeArgumentPair(_ key: String, value: String?, from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == key {
                if let value {
                    if index + 1 < args.count, args[index + 1] == value {
                        args.remove(at: index)
                        args.remove(at: index)
                        continue
                    }
                } else {
                    args.remove(at: index)
                    if index < args.count {
                        args.remove(at: index)
                    }
                    continue
                }
            }
            index += 1
        }
    }

    static func adjustDeinterlaceFilter(
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        // Only proceed if a video filter graph exists
        guard let vfIndex = ffmpegArgs.firstIndex(of: "-vf"), vfIndex + 1 < ffmpegArgs.count else {
            return
        }

        let isInterlaced: Bool
        if let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL) {
            isInterlaced = metadata.videoStream?.isInterlaced ?? false
        } else {
            isInterlaced = false
        }

        var filters = ffmpegArgs[vfIndex + 1]

        if isInterlaced {
            let bwdifFilter = "bwdif=mode=send_field:parity=auto:deint=all"
            // Replace yadif with bwdif, or insert bwdif at the start if yadif is absent
            if filters.contains("yadif") {
                // Replace common forms of yadif invocation
                filters = filters.replacingOccurrences(of: "yadif=0", with: bwdifFilter)
                filters = filters.replacingOccurrences(of: "yadif", with: bwdifFilter)
            } else {
                // Prepend bwdif to existing chain
                if filters.isEmpty {
                    filters = bwdifFilter
                } else {
                    filters = bwdifFilter + "," + filters
                }
            }
        } else {
            // Progressive source: remove any yadif occurrences entirely
            let patterns = [
                "yadif=0,",
                ",yadif=0",
                "yadif=0",
                "yadif,",
                ",yadif",
                "yadif"
            ]
            for p in patterns {
                filters = filters.replacingOccurrences(of: p, with: "")
            }
            // Clean up any accidental leading/trailing commas and whitespace
            filters = filters.trimmingCharacters(in: .whitespacesAndNewlines)
            while filters.hasPrefix(",") { filters.removeFirst() }
            while filters.hasSuffix(",") { filters.removeLast() }
        }

        ffmpegArgs[vfIndex + 1] = filters
    }

    private static func sanitizeArgumentsForCustomVideoPipeline(_ ffmpegArgs: inout [String]) {
        removeArgumentPair("-vf", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-map", value: nil, from: &ffmpegArgs)
    }
    
    /// Removes video-related arguments for audio-only encoding
    private static func removeVideoArguments(from ffmpegArgs: inout [String]) {
        // Remove video codec arguments
        removeArgumentPair("-c:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-pix_fmt", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-b:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-profile:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-tag:v", value: nil, from: &ffmpegArgs)
        
        // Remove video filter arguments
        removeArgumentPair("-vf", value: nil, from: &ffmpegArgs)
        
        // Remove video mapping (this is the key one causing the error)
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               ffmpegArgs[index + 1].contains("0:v") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }
        
        // Remove metadata for video streams
        var metadataIndex = 0
        while metadataIndex < ffmpegArgs.count {
            if ffmpegArgs[metadataIndex] == "-metadata:s:v:0",
               metadataIndex + 1 < ffmpegArgs.count {
                ffmpegArgs.remove(at: metadataIndex)
                ffmpegArgs.remove(at: metadataIndex)
                continue
            }
            metadataIndex += 1
        }
    }

    /// Applies audio routing configuration by replacing preset's audio map arguments
    /// with custom track selection, ordering, or channel-level operations
    private static func applyAudioRouting(config: AudioRoutingConfig, to ffmpegArgs: inout [String]) {
        // Check if there's already a video map - if not, we need to add one
        let hasVideoMap = ffmpegArgs.contains(where: { arg in
            if let idx = ffmpegArgs.firstIndex(of: "-map"),
               idx + 1 < ffmpegArgs.count {
                return ffmpegArgs[idx + 1].hasPrefix("0:v")
            }
            return false
        })

        // Remove all existing audio mapping arguments from preset
        removeArgumentPair("-map", value: "0:a", from: &ffmpegArgs)

        // Also remove indexed audio maps if present
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               ffmpegArgs[index + 1].hasPrefix("0:a:") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        // Ensure video is mapped if not already present
        if !hasVideoMap {
            // Insert -map 0:v at the beginning
            ffmpegArgs.insert(contentsOf: ["-map", "0:v"], at: 0)
            logger.debug("Added video mapping for audio routing")
        }

        // Generate custom audio arguments (either simple -map or filter_complex)
        let customAudioArgs = AudioRoutingService.buildFFmpegMapArguments(config: config)

        // Check if we're using filter_complex (channel operations)
        if customAudioArgs.contains("-filter_complex") {
            // Remove any existing audio-only filter_complex
            var filterComplexIndex = 0
            while filterComplexIndex < ffmpegArgs.count {
                if ffmpegArgs[filterComplexIndex] == "-filter_complex" {
                    if filterComplexIndex + 1 < ffmpegArgs.count {
                        let filterContent = ffmpegArgs[filterComplexIndex + 1]
                        // Simple heuristic: if it contains audio operations, remove it
                        if filterContent.contains("[aout]") || filterContent.contains("amerge") ||
                           filterContent.contains("channelsplit") || filterContent.contains("pan=") {
                            ffmpegArgs.remove(at: filterComplexIndex)
                            if filterComplexIndex < ffmpegArgs.count {
                                ffmpegArgs.remove(at: filterComplexIndex)
                            }
                            continue
                        }
                    }
                }
                filterComplexIndex += 1
            }

            // Insert filter_complex at the beginning (after input arguments)
            ffmpegArgs.insert(contentsOf: customAudioArgs, at: 0)
            logger.debug("Applied audio routing with filter_complex: \(customAudioArgs.joined(separator: " "))")
        } else {
            // Simple -map arguments: insert after video map if present
            var insertionIndex = 0
            for (idx, arg) in ffmpegArgs.enumerated() {
                if arg == "-map", idx + 1 < ffmpegArgs.count, ffmpegArgs[idx + 1].hasPrefix("0:v") {
                    insertionIndex = idx + 2
                    break
                }
            }

            ffmpegArgs.insert(contentsOf: customAudioArgs, at: insertionIndex)
            logger.debug("Applied audio routing with simple maps: \(customAudioArgs.joined(separator: " "))")
        }
    }
    
    private static func synthesizedVideoCommandArguments(for request: SynthesizedVideoRequest) -> [String] {
        let finalWidth = evenDimension(max(request.width, 2))
        let finalHeight = evenDimension(max(request.height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let frameRateValue = formattedFrameRateString(from: request.frameRate)
        let filterGraph = "color=c=\(request.backgroundFFmpegColor):s=\(resolution):r=\(frameRateValue),format=yuv420p[synth_v]"

        var arguments: [String] = ["-filter_complex", filterGraph, "-map", "[synth_v]"]

        if request.includeAudio {
            arguments.append(contentsOf: ["-map", "0:a?"])
        }

        arguments.append("-shortest")
        return arguments
    }

    /// Applies crop filter to video filter chain
    /// Inserts crop AFTER setsar, BEFORE final scale for maximum quality
    static func applyCropToVideoFilter(
        _ ffmpegArgs: inout [String],
        cropConfig: CropConfig,
        sourceWidth: Int,
        sourceHeight: Int
    ) {
        // Don't apply crop to stream copy preset
        guard !ffmpegArgs.contains("-c:v") || !ffmpegArgs.contains("copy") else {
            logger.debug("Skipping crop for stream copy preset")
            return
        }

        // Find -vf index, or add it if it doesn't exist
        var vfIndex = ffmpegArgs.firstIndex(of: "-vf")
        var filterChain = ""

        if let existingIndex = vfIndex, existingIndex + 1 < ffmpegArgs.count {
            // Use existing filter chain
            filterChain = ffmpegArgs[existingIndex + 1]
        } else {
            // No -vf found, add it
            // Insert before output file (which is last)
            let insertIndex = ffmpegArgs.count
            ffmpegArgs.insert("-vf", at: insertIndex)
            ffmpegArgs.insert("", at: insertIndex + 1)  // Empty placeholder
            vfIndex = insertIndex
            logger.debug("Added -vf argument for crop")
        }

        guard let vfIndex else {
            logger.debug("Failed to create -vf argument for crop")
            return
        }

        // Generate crop filter
        guard let cropFilter = CropService.buildCropFilter(
            config: cropConfig,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        ) else {
            logger.debug("Crop filter not generated (inactive or invalid)")
            return
        }

        // Insert crop into filter chain
        if filterChain.isEmpty {
            // No existing filters, just use crop
            filterChain = cropFilter
        } else if let scaleRange = filterChain.range(of: ",scale=w=") {
            // Insert crop AFTER setsar, BEFORE final scale
            let beforeScale = filterChain[..<scaleRange.lowerBound]
            let afterSetsar = filterChain[scaleRange.lowerBound...]
            filterChain = "\(beforeScale),\(cropFilter)\(afterSetsar)"
        } else if filterChain.contains("setsar") {
            // Fallback: append after setsar
            if let setsarRange = filterChain.range(of: "setsar=1/1") {
                // Check if there's content after setsar
                if setsarRange.upperBound < filterChain.endIndex {
                    // There's more filter chain after setsar
                    let beforeCrop = filterChain[...setsarRange.upperBound]
                    let afterCrop = filterChain[setsarRange.upperBound...]

                    // Insert crop with proper separator
                    if afterCrop.starts(with: ",") {
                        // Already has comma separator
                        filterChain = "\(beforeCrop),\(cropFilter)\(afterCrop)"
                    } else {
                        // No comma, add one
                        filterChain = "\(beforeCrop),\(cropFilter),\(afterCrop)"
                    }
                } else {
                    // setsar is at the end, just append
                    filterChain = "\(filterChain),\(cropFilter)"
                }
            }
        } else {
            // Last resort: prepend to filter chain
            filterChain = "\(cropFilter),\(filterChain)"
        }

        // Update args
        ffmpegArgs[vfIndex + 1] = filterChain
        logger.info("Applied crop to video filter chain: \(filterChain, privacy: .public)")
    }

}
