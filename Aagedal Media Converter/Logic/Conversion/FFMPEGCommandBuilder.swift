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
        additionalOutputArguments: [String]? = nil,
        isMuted: Bool = false
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
            await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs, trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)
            await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if !includeAudioOutput {
                removeArgumentPair("-map", value: "[audout]", from: &arguments)
            }
            arguments.append(contentsOf: ffmpegArgs)
            
            // Apply comment metadata AFTER all other arguments to ensure it's not stripped by -map_metadata -1
            applyCommentMetadata(
                to: &arguments,
                comment: comment,
                includeDateTag: includeDateTag
            )
            
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
            await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs, trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)
            await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if synthesizedVideoRequest.includeAudio {
                removeArgumentPair("-an", value: nil, from: &ffmpegArgs)
            }
            
            // Apply audio routing configuration if provided and preset supports audio and audio routing
            if let audioRoutingConfig, preset.outputsAudioTrack, preset.appliesAudioRouting {
                applyAudioRouting(config: audioRoutingConfig, to: &ffmpegArgs)
            }

            arguments.append(contentsOf: ffmpegArgs)
            
            // Apply comment metadata AFTER all other arguments to ensure it's not stripped by -map_metadata -1
            applyCommentMetadata(
                to: &arguments,
                comment: comment,
                includeDateTag: includeDateTag
            )
            
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
        await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs, trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)
        await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)

        // Filter out unsupported audio codecs (e.g., APAC spatial audio from iPhone)
        // Skip for stream copy (which doesn't decode) and when audio routing is applied (has its own mapping)
        if preset != .streamCopy && (audioRoutingConfig == nil || !preset.appliesAudioRouting) {
            await filterUnsupportedAudioStreams(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
        }

        // Apply crop to video filter if configured and preset supports it
        if let cropConfig = cropConfig,
           cropConfig.isActive,
           preset.outputsVideoTrack,
           preset.appliesCrop {
            if let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL),
               let width = metadata.videoStream?.width,
               let height = metadata.videoStream?.height {
                
                // Calculate effective Pixel Aspect Ratio (PAR)
                // We use a robust detection strategy:
                // 1. Calculate PAR derived from DAR (Display Aspect Ratio). This is usually the ground truth for playback.
                // 2. Check explicit PAR from metadata.
                // 3. If explicit PAR exists and is 'close' to DAR-derived PAR (within 5%), use explicit PAR (it's likely more precise).
                // 4. If explicit PAR contradicts DAR (e.g. PAR=1 vs DAR=16:9 for 1440 width), use DAR-derived PAR.
                // 5. Default to 1.0.
                let effectivePAR: Double
                let darValues = metadata.videoStream?.displayAspectRatio?.doubleValue
                let parValues = metadata.videoStream?.pixelAspectRatio?.doubleValue
                
                if let dar = darValues, dar > 0, height > 0 {
                    let resolutionAspect = Double(width) / Double(height)
                    let derivedPAR = dar / resolutionAspect
                    
                    if let par = parValues, par > 0 {
                        // Check consistency
                        if abs(derivedPAR - par) < 0.05 {
                            effectivePAR = par // Consistent, use explicit
                        } else {
                            effectivePAR = derivedPAR // Contradiction, trust DAR (Container)
                        }
                    } else {
                        effectivePAR = derivedPAR
                    }
                } else if let par = parValues, par > 0 {
                    effectivePAR = par
                } else {
                    effectivePAR = 1.0
                }
                
                applyCropToVideoFilter(
                    &ffmpegArgs,
                    cropConfig: cropConfig,
                    sourceWidth: width,
                    sourceHeight: height,
                    pixelAspectRatio: effectivePAR
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

        // Apply mute if requested - removes all audio from output
        if isMuted {
            applyMute(to: &ffmpegArgs)
        }

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

        // Apply comment metadata AFTER all other arguments to ensure it's not stripped by -map_metadata -1
        applyCommentMetadata(
            to: &arguments,
            comment: comment,
            includeDateTag: includeDateTag
        )

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
        // Resample to 48kHz for broadcast format compatibility (MXF requires 48kHz)
        var audioFilters = ["aresample=48000", "aformat=channel_layouts=\(channelLayout)"]
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
        
        // Get prefix, suffix, separator, and date format from UserDefaults
        let commentPrefix = UserDefaults.standard.string(forKey: AppConstants.commentPrefixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commentSuffixSetting = UserDefaults.standard.string(forKey: AppConstants.commentSuffixKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let commentSeparator = UserDefaults.standard.string(forKey: AppConstants.commentSeparatorKey) ?? AppConstants.defaultCommentSeparator
        let commentDateFormat = UserDefaults.standard.string(forKey: AppConstants.commentDateFormatKey) ?? AppConstants.defaultCommentDateFormat
        let dateTagPrefixSetting = UserDefaults.standard.string(forKey: AppConstants.dateTagPrefixKey) ?? AppConstants.defaultDateTagPrefix
        let effectiveDateTagPrefix = dateTagPrefixSetting.isEmpty ? AppConstants.defaultDateTagPrefix : dateTagPrefixSetting
        
        let commentText: String? = {
            var parts: [String] = []
            
            if includeDateTag {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = commentDateFormat
                let currentDateString = dateFormatter.string(from: Date())
                parts.append("\(effectiveDateTagPrefix): \(currentDateString)")
            }
            
            if !commentPrefix.isEmpty {
                parts.append(commentPrefix)
            }
            
            if !trimmedComment.isEmpty {
                parts.append(trimmedComment)
            }
            
            if !commentSuffixSetting.isEmpty {
                parts.append(commentSuffixSetting)
            }
            
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: commentSeparator)
        }()

        // First, remove any existing comment metadata from the arguments
        var index = 0
        while index < ffmpegArgs.count - 1 {
            if ffmpegArgs[index] == "-metadata" && ffmpegArgs[index + 1].hasPrefix("comment=") {
                ffmpegArgs.remove(at: index + 1)
                ffmpegArgs.remove(at: index)
                // Don't increment index since we removed elements
                continue
            }
            index += 1
        }
        
        // Add the new comment metadata if we have content
        if let commentText {
            ffmpegArgs.append(contentsOf: ["-metadata", "comment=\(commentText)"])
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

    /// Replaces generic `-map 0:a` with explicit mapping of only decodable audio streams.
    /// This filters out unsupported codecs like Apple's APAC spatial audio.
    static func filterUnsupportedAudioStreams(
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        // Check if we have a generic audio map that needs filtering
        guard ffmpegArgs.contains(where: { $0 == "-map" }),
              let mapIndex = ffmpegArgs.firstIndex(of: "-map"),
              mapIndex + 1 < ffmpegArgs.count else {
            return
        }

        // Find all audio map arguments
        var audioMapIndices: [(index: Int, value: String)] = []
        for i in 0..<ffmpegArgs.count - 1 {
            if ffmpegArgs[i] == "-map" {
                let value = ffmpegArgs[i + 1]
                if value == "0:a" || value == "0:a?" {
                    audioMapIndices.append((i, value))
                }
            }
        }

        // If no generic audio maps, nothing to filter
        guard !audioMapIndices.isEmpty else { return }

        // Fetch audio streams to check codec support
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
              !audioStreams.isEmpty else {
            return
        }

        // Check if all streams are decodable - if so, no need to change anything
        let decodableStreams = audioStreams.filter { $0.isDecodable }
        if decodableStreams.count == audioStreams.count {
            return // All streams are decodable, keep original mapping
        }

        // Log which streams are being filtered
        let skippedStreams = audioStreams.filter { !$0.isDecodable }
        for stream in skippedStreams {
            logger.info("Skipping unsupported audio stream index \(stream.index ?? -1) with codec '\(stream.codecName ?? "unknown", privacy: .public)'")
        }

        // If no decodable streams, remove audio mapping entirely
        if decodableStreams.isEmpty {
            // Remove all generic audio maps and replace with -an if preset expects audio
            for (mapIdx, _) in audioMapIndices.reversed() {
                ffmpegArgs.remove(at: mapIdx + 1)
                ffmpegArgs.remove(at: mapIdx)
            }
            // Also remove audio codec settings if present
            removeArgumentPair("-c:a", value: nil, from: &ffmpegArgs)
            removeArgumentPair("-b:a", value: nil, from: &ffmpegArgs)
            if !ffmpegArgs.contains("-an") {
                ffmpegArgs.append("-an")
            }
            logger.warning("No decodable audio streams found, disabling audio output")
            return
        }

        // Replace generic audio maps with explicit stream indices
        // Process in reverse order to maintain correct indices during removal
        for (mapIdx, _) in audioMapIndices.reversed() {
            ffmpegArgs.remove(at: mapIdx + 1)
            ffmpegArgs.remove(at: mapIdx)
        }

        // Build position-based indices for decodable streams
        // Audio stream positions are 0-based within audio streams (0:a:0, 0:a:1, etc.)
        var audioPosition = 0
        var decodablePositions: [Int] = []
        for stream in audioStreams {
            if stream.isDecodable {
                decodablePositions.append(audioPosition)
            }
            audioPosition += 1
        }

        // Find where to insert the new audio maps (after video map if present)
        var insertionIndex = 0
        for (idx, arg) in ffmpegArgs.enumerated() {
            if arg == "-map", idx + 1 < ffmpegArgs.count, ffmpegArgs[idx + 1].hasPrefix("0:v") {
                insertionIndex = idx + 2
                break
            }
        }

        // Insert explicit audio stream maps
        var offset = 0
        for position in decodablePositions {
            ffmpegArgs.insert("-map", at: insertionIndex + offset)
            ffmpegArgs.insert("0:a:\(position)", at: insertionIndex + offset + 1)
            offset += 2
        }

        logger.info("Filtered audio streams: mapping only decodable streams \(decodablePositions)")
    }

    static func adjustArgumentsForInput(
        preset: ExportPreset,
        inputURL: URL,
        ffmpegArgs: inout [String],
        trimStart: Double? = nil,
        trimEnd: Double? = nil
    ) async {
        // Handle AVC-Intra mono channel splitting
        if preset == .tvAVCIntra {
            // Calculate effective duration for silent streams
            let effectiveDuration = await calculateEffectiveDurationForAudio(inputURL: inputURL, trimStart: trimStart, trimEnd: trimEnd)
            await adjustAVCIntraAudio(inputURL: inputURL, ffmpegArgs: &ffmpegArgs, duration: effectiveDuration)
            return
        }

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

    /// Calculate the effective duration for audio streams, considering trim points
    private static func calculateEffectiveDurationForAudio(
        inputURL: URL,
        trimStart: Double?,
        trimEnd: Double?
    ) async -> Double? {
        // If we have both trim points, use the difference
        if let start = trimStart, let end = trimEnd {
            return end - start
        }

        // Try to get the file's total duration
        if let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL),
           let totalDuration = metadata.duration {
            if let start = trimStart {
                return totalDuration - start
            } else if let end = trimEnd {
                return end
            } else {
                return totalDuration
            }
        }

        return nil
    }

    /// Adjusts audio arguments for AVC-Intra preset to create separate mono streams
    /// Input stereo tracks are split into individual mono streams for MXF broadcast delivery
    private static func adjustAVCIntraAudio(
        inputURL: URL,
        ffmpegArgs: inout [String],
        duration: Double?
    ) async {
        // Get desired mono channel count from settings
        let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey)
            ?? AppConstants.defaultAVCIntraAudioChannels
        let audioChannels = AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8
        let targetChannelCount = audioChannels.count

        // Format duration for anullsrc (add small buffer to ensure it's long enough)
        let durationStr: String
        if let dur = duration {
            durationStr = String(format: "%.3f", dur + 1.0) // Add 1 second buffer
        } else {
            durationStr = "3600" // Default to 1 hour if unknown
        }

        // Fetch audio stream info from input and filter to only decodable streams
        let allAudioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL) ?? []
        let audioStreams = allAudioStreams.filter { $0.isDecodable }

        // Log filtered streams
        let skippedStreams = allAudioStreams.filter { !$0.isDecodable }
        for stream in skippedStreams {
            logger.info("AVC-Intra: Skipping unsupported audio stream index \(stream.index ?? -1) with codec '\(stream.codecName ?? "unknown", privacy: .public)'")
        }

        // Remove existing audio mapping arguments
        removeArgumentPair("-map", value: "0:a?", from: &ffmpegArgs)
        removeArgumentPair("-ac", value: nil, from: &ffmpegArgs)

        // If no decodable audio streams, create silent mono streams
        // Use a single aevalsrc source with asplit to minimize independent audio generators
        // aevalsrc generates samples on-demand, which helps with MXF muxer synchronization
        guard !audioStreams.isEmpty else {
            var filterParts: [String] = []
            var silentMaps: [String] = []

            // Create single silent source using aevalsrc (generates silence on-demand)
            filterParts.append("aevalsrc=0:c=mono:s=48000:d=\(durationStr)[silentsrc]")

            if targetChannelCount == 1 {
                // Just one channel needed
                silentMaps.append(contentsOf: ["-map", "[silentsrc]"])
            } else {
                // Split into multiple channels
                var splitOutputs: [String] = []
                for i in 0..<targetChannelCount {
                    splitOutputs.append("[silent\(i)]")
                }
                filterParts.append("[silentsrc]asplit=\(targetChannelCount)\(splitOutputs.joined())")
                for i in 0..<targetChannelCount {
                    silentMaps.append(contentsOf: ["-map", "[silent\(i)]"])
                }
            }

            let filterGraph = filterParts.joined(separator: ";")
            ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph])
            ffmpegArgs.append(contentsOf: silentMaps)
            // Add -shortest to stop when video ends
            ffmpegArgs.append("-shortest")
            return
        }

        // Build filter graph to split all audio streams into mono channels
        // Important: Use original audio stream positions for FFmpeg's 0:a:X notation
        var filterParts: [String] = []
        var monoOutputs: [String] = []
        var outputIndex = 0

        for (audioPosition, stream) in allAudioStreams.enumerated() {
            // Skip unsupported streams
            guard stream.isDecodable else { continue }

            let channels = stream.channels ?? 2
            let channelLayout = stream.channelLayout ?? (channels == 1 ? "mono" : "stereo")

            if channels == 1 {
                // Mono stream - use directly but ensure consistent format
                let outputLabel = "mono\(outputIndex)"
                filterParts.append("[0:a:\(audioPosition)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(outputLabel)]")
                monoOutputs.append(outputLabel)
                outputIndex += 1
            } else {
                // Multi-channel stream - split into individual mono channels
                // Determine channel layout for splitting
                let splitLayout: String
                if channels == 2 {
                    splitLayout = "stereo"
                } else if channels == 6 {
                    splitLayout = "5.1"
                } else if channels == 8 {
                    splitLayout = "7.1"
                } else {
                    // Generic layout based on channel count
                    splitLayout = channelLayout
                }

                // Generate output labels for each channel
                var channelLabels: [String] = []
                for ch in 0..<channels {
                    channelLabels.append("s\(audioPosition)c\(ch)")
                }
                let outputLabelsStr = channelLabels.map { "[\($0)]" }.joined()

                // Add channelsplit filter
                filterParts.append("[0:a:\(audioPosition)]channelsplit=channel_layout=\(splitLayout)\(outputLabelsStr)")

                // Add format filter for each split channel to ensure consistent output
                for label in channelLabels {
                    let formattedLabel = "mono\(outputIndex)"
                    filterParts.append("[\(label)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(formattedLabel)]")
                    monoOutputs.append(formattedLabel)
                    outputIndex += 1
                }
            }
        }

        // Determine how many channels we actually have vs need
        let availableChannels = monoOutputs.count

        // Add silent streams if we need more channels than available
        // Instead of anullsrc (which causes buffer deadlocks with MXF),
        // derive silent channels from existing audio using volume=0 and asplit
        if availableChannels < targetChannelCount && availableChannels > 0 {
            let silentChannelsNeeded = targetChannelCount - availableChannels

            // Use the first mono output as the template for silent channels
            // We need to split it first: one copy for actual output, one for silent derivation
            let templateLabel = monoOutputs[0]
            let templateForOutput = "\(templateLabel)_out"
            let templateForSilent = "\(templateLabel)_silent"

            // Split the template into two: one for output, one for silent channel derivation
            filterParts.append("[\(templateLabel)]asplit=2[\(templateForOutput)][\(templateForSilent)]")

            // Update monoOutputs to use the split output version
            monoOutputs[0] = templateForOutput

            // Generate labels for all silent outputs
            var silentLabels: [String] = []
            for i in 0..<silentChannelsNeeded {
                silentLabels.append("silent\(availableChannels + i)")
            }

            // Create silent version and split into required number of channels
            if silentChannelsNeeded == 1 {
                // Just one silent channel needed - apply volume=0 directly
                filterParts.append("[\(templateForSilent)]volume=0[\(silentLabels[0])]")
            } else {
                // Multiple silent channels - silence first, then split
                let silentBaseLabel = "silentbase"
                filterParts.append("[\(templateForSilent)]volume=0[\(silentBaseLabel)]")
                let splitOutputs = silentLabels.map { "[\($0)]" }.joined()
                filterParts.append("[\(silentBaseLabel)]asplit=\(silentChannelsNeeded)\(splitOutputs)")
            }

            monoOutputs.append(contentsOf: silentLabels)
        }

        // Truncate if we have more channels than needed
        let finalOutputs = Array(monoOutputs.prefix(targetChannelCount))

        // Build final filter graph
        let filterGraph = filterParts.joined(separator: ";")

        // Build map arguments for each mono output
        var mapArgs: [String] = []
        for output in finalOutputs {
            mapArgs.append(contentsOf: ["-map", "[\(output)]"])
        }

        // Add to ffmpeg arguments
        ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph])
        ffmpegArgs.append(contentsOf: mapArgs)
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
        // Remove any preset-added filter_complex (e.g., AVC-Intra mono channel splitting)
        // since waveform/synthesized video pipelines have their own filter_complex
        removeArgumentPair("-filter_complex", value: nil, from: &ffmpegArgs)
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

    /// Applies mute by removing all audio arguments and ensuring -an flag is present
    private static func applyMute(to ffmpegArgs: inout [String]) {
        // Remove audio codec arguments
        removeArgumentPair("-c:a", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-b:a", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-ac", value: nil, from: &ffmpegArgs)

        // Remove audio mapping
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               (ffmpegArgs[index + 1].contains("0:a") || ffmpegArgs[index + 1] == "[aout]" || ffmpegArgs[index + 1] == "[audout]") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        // Remove audio filter_complex if present and audio-only
        removeArgumentPair("-filter_complex", value: nil, from: &ffmpegArgs)

        // Remove audio metadata
        var metadataIndex = 0
        while metadataIndex < ffmpegArgs.count {
            if ffmpegArgs[metadataIndex] == "-metadata:s:a:0",
               metadataIndex + 1 < ffmpegArgs.count {
                ffmpegArgs.remove(at: metadataIndex)
                ffmpegArgs.remove(at: metadataIndex)
                continue
            }
            metadataIndex += 1
        }

        // Ensure -an flag is present
        if !ffmpegArgs.contains("-an") {
            ffmpegArgs.append("-an")
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
    /// - If the chain contains a DAR-based desqueeze (e.g. scale='trunc(ih*dar...)',setsar=1/1), crop is inserted BEFORE it.
    /// - Otherwise, crop is inserted after setsar and before any final scale when possible.
    static func applyCropToVideoFilter(
        _ ffmpegArgs: inout [String],
        cropConfig: CropConfig,
        sourceWidth: Int,
        sourceHeight: Int,
        pixelAspectRatio: Double?
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

        let filterChainNormalizesAnamorphic = filterChain.contains("trunc(ih*dar") && filterChain.contains("setsar=1/1")

        // Generate crop filter
        guard var cropFilter = CropService.buildCropFilter(
            config: cropConfig,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        ) else {
            logger.debug("Crop filter not generated (inactive or invalid)")
            return
        }

        // Check for anamorphic content (non-square pixels)
        // If PAR deviates significantly from 1.0, scale to square pixels
        // Note: Many built-in presets already normalize anamorphic sources using a DAR-based scale + setsar=1/1.
        // In that case, avoid applying a second desqueeze stage here.
        if let par = pixelAspectRatio, abs(par - 1.0) > 0.01, !filterChainNormalizesAnamorphic {
            // We need to scale the cropped output to square pixels using the effective PAR.
            // We calculate the target dimensions explicitly in Swift rather than relying on ffmpeg's 'sar' variable,
            // because the stream's internal SAR might be 1:1 even if the effective PAR is not (as detected by our DAR priority logic).

            let pixelRect = cropConfig.pixelRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            let targetWidth = Double(pixelRect.width) * par
            let targetHeight = Double(pixelRect.height)

            // Ensure even dimensions for compatibility
            let finalWidth = evenDimension(Int(round(targetWidth)))
            let finalHeight = evenDimension(Int(round(targetHeight)))

            // scale=FINAL_W:FINAL_H,setsar=1
            let scaleFilter = "scale=\(finalWidth):\(finalHeight),setsar=1"
            cropFilter = "\(cropFilter),\(scaleFilter)"
            logger.info("Added anamorphic scaling to crop filter: PAR \(par) -> \(finalWidth)x\(finalHeight)")
        }

        // Insert crop into filter chain
        if filterChain.isEmpty {
            // No existing filters, just use crop
            filterChain = cropFilter
        } else if let desqueezeRange = (filterChain.range(of: "scale='trunc(ih*dar") ?? filterChain.range(of: "scale=trunc(ih*dar")) {
            // Built-in presets start by normalizing display aspect ratio (DAR) into square pixels.
            // The crop rect is stored in SOURCE PIXEL coordinates, so it must be applied BEFORE this DAR-based desqueeze.
            let beforeDesqueeze = String(filterChain[..<desqueezeRange.lowerBound])
            let afterDesqueeze = String(filterChain[desqueezeRange.lowerBound...])

            var newChain = beforeDesqueeze
            if !newChain.isEmpty, !newChain.hasSuffix(",") {
                newChain.append(",")
            }

            newChain.append(cropFilter)

            if !afterDesqueeze.isEmpty {
                if !afterDesqueeze.hasPrefix(",") {
                    newChain.append(",")
                }
                newChain.append(afterDesqueeze)
            }

            filterChain = newChain
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
