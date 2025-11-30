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

/// Service for handling audio routing logic and FFmpeg command generation
enum AudioRoutingService {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AudioRouting")
    
    /// Fetches detailed audio track information from a media file
    /// - Parameter url: The URL of the media file
    /// - Returns: Array of AudioTrackInfo objects, or empty array if no audio tracks
    static func fetchAudioTrackInfo(for url: URL) async -> [AudioTrackInfo] {
        // Use existing FFMPEGProbeService to get basic info, then enhance with VideoMetadata
        guard let basicStreams = await FFMPEGProbeService.fetchAudioStreams(for: url) else {
            logger.warning("Failed to fetch audio streams for \(url.lastPathComponent)")
            return []
        }
        
        // Try to get richer metadata from VideoMetadataService
        let metadata = try? await VideoMetadataService.shared.metadata(for: url)
        
        var trackInfos: [AudioTrackInfo] = []
        
        for (position, basicStream) in basicStreams.enumerated() {
            // Use position as the audio-relative index for FFmpeg's -map 0:a:X notation
            // basicStream.index contains absolute stream index (e.g., 0=video, 1-4=audio)
            // but FFmpeg's 0:a:X expects audio-relative indices (0, 1, 2, 3...)
            let audioRelativeIndex = position
            let absoluteStreamIndex = basicStream.index ?? position
            
            // Try to find matching stream in detailed metadata using absolute index
            let detailedStream = metadata?.audioStreams.first { $0.index == absoluteStreamIndex }
            
            let trackInfo = AudioTrackInfo(
                streamIndex: audioRelativeIndex,
                channels: basicStream.channels ?? detailedStream?.channels,
                channelLayout: basicStream.channelLayout ?? detailedStream?.channelLayout,
                codec: detailedStream?.codec,
                codecLongName: detailedStream?.codecLongName,
                sampleRate: detailedStream?.sampleRate,
                languageCode: detailedStream?.languageCode,
                title: detailedStream?.title,
                bitRate: detailedStream?.bitRate,
                trackNumber: position + 1  // 1-based track number
            )
            
            trackInfos.append(trackInfo)
        }
        
        logger.info("Found \(trackInfos.count) audio tracks in \(url.lastPathComponent)")
        return trackInfos
    }
    
    /// Builds FFmpeg arguments based on audio routing configuration
    /// Returns either simple -map arguments or complex filter graph
    /// - Parameter config: The audio routing configuration
    /// - Returns: Array of FFmpeg arguments for audio routing
    static func buildFFmpegMapArguments(config: AudioRoutingConfig) -> [String] {
        // If channel operation exists, use filter_complex
        if let operation = config.channelOperation {
            return buildChannelOperationArguments(operation: operation, config: config)
        }
        
        // Otherwise use simple -map arguments
        var arguments: [String] = []
        
        for streamIndex in config.outputTrackIndices {
            arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)"])
        }
        
        logger.debug("Generated FFmpeg map arguments: \(arguments.joined(separator: " "))")
        return arguments
    }
    
    /// Builds FFmpeg filter_complex arguments for channel-level operations
    /// - Parameters:
    ///   - operation: The channel operation to perform
    ///   - config: The audio routing configuration
    /// - Returns: Array of FFmpeg arguments including filter_complex
    private static func buildChannelOperationArguments(
        operation: ChannelOperation,
        config: AudioRoutingConfig
    ) -> [String] {
        var arguments: [String] = []
        
        switch operation {
        case .mergeToStereo(let trackIndices):
            // Example: [0:a:0][0:a:1]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[aout]
            guard trackIndices.count >= 2 else {
                logger.warning("mergeToStereo requires at least 2 tracks, got \(trackIndices.count)")
                return buildFallbackArguments(config: config)
            }
            
            let inputs = trackIndices.map { "[0:a:\($0)]" }.joined()
            let filter: String
            
            if trackIndices.count == 2 {
                // Simple stereo merge: combine two mono tracks
                filter = "\(inputs)amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[aout]"
            } else {
                // Multiple tracks: merge all into multi-channel, then downmix to stereo
                filter = "\(inputs)amerge=inputs=\(trackIndices.count),pan=stereo|c0<c0|c1<c1[aout]"
            }
            
            arguments = ["-filter_complex", filter, "-map", "[aout]"]
            logger.debug("Generated merge-to-stereo filter: \(filter)")
            
        case .splitToMono(let trackIndex):
            // Example: [0:a:0]channelsplit=channel_layout=stereo[L][R]
            guard let trackInfo = config.trackInfo(for: trackIndex),
                  let channels = trackInfo.channels, channels == 2 else {
                logger.warning("splitToMono requires a stereo track")
                return buildFallbackArguments(config: config)
            }
            
            let layout = trackInfo.channelLayout ?? "stereo"
            let filter = "[0:a:\(trackIndex)]channelsplit=channel_layout=\(layout)[L][R]"
            
            arguments = ["-filter_complex", filter, "-map", "[L]", "-map", "[R]"]
            logger.debug("Generated split-to-mono filter: \(filter)")
            
        case .swapChannels(let trackIndex):
            // Example: [0:a:0]pan=stereo|c0=c1|c1=c0[aout]
            guard let trackInfo = config.trackInfo(for: trackIndex),
                  let channels = trackInfo.channels, channels == 2 else {
                logger.warning("swapChannels requires a stereo track")
                return buildFallbackArguments(config: config)
            }
            
            let filter = "[0:a:\(trackIndex)]pan=stereo|c0=c1|c1=c0[aout]"
            
            arguments = ["-filter_complex", filter, "-map", "[aout]"]
            logger.debug("Generated swap-channels filter: \(filter)")
            
        case .extractChannel(let trackIndex, let channelIndex, _):
            // Example: [0:a:0]pan=mono|c0=c0[aout] (extract left channel)
            guard let trackInfo = config.trackInfo(for: trackIndex),
                  let channels = trackInfo.channels, channelIndex < channels else {
                logger.warning("extractChannel: invalid track or channel index")
                return buildFallbackArguments(config: config)
            }
            
            let filter = "[0:a:\(trackIndex)]pan=mono|c0=c\(channelIndex)[aout]"
            
            arguments = ["-filter_complex", filter, "-map", "[aout]"]
            logger.debug("Generated extract-channel filter: \(filter)")
        }
        
        return arguments
    }
    
    /// Fallback to simple mapping when operation fails
    private static func buildFallbackArguments(config: AudioRoutingConfig) -> [String] {
        var arguments: [String] = []
        for streamIndex in config.outputTrackIndices {
            arguments.append(contentsOf: ["-map", "0:a:\(streamIndex)"])
        }
        logger.warning("Using fallback simple mapping due to invalid operation")
        return arguments
    }
    
    /// Validates routing configuration against preset requirements
    /// - Parameters:
    ///   - config: The audio routing configuration
    ///   - preset: The export preset being used
    /// - Returns: Array of warning/info messages (empty if no issues)
    static func validateRoutingConfig(config: AudioRoutingConfig, preset: ExportPreset) -> [String] {
        var messages: [String] = []

        // Check if preset removes all audio
        if !preset.outputsAudioTrack {
            messages.append("Note: \(preset.displayName) preset removes all audio. Routing configuration will not affect output.")
            return messages
        }

        // Check if preset supports audio routing
        if !preset.appliesAudioRouting {
            messages.append("Warning: Audio routing is not compatible with \(preset.displayName) preset. Routing will be ignored.")
            return messages
        }

        // Check for preset-specific audio handling
        switch preset {
        case .audioStereoAAC:
            if config.outputTrackIndices.count > 1 {
                messages.append("Note: AAC format supports only one audio track. Multiple tracks will be converted to stereo and merged.")
            }
            
        case .videoLoopWithAudio:
            if config.outputTrackIndices.count > 1 {
                messages.append("Note: This preset converts audio to stereo AAC. Multiple tracks will be included but may increase file size.")
            }
            
        default:
            break
        }
        
        // Warn if all tracks are removed
        if config.outputTrackIndices.isEmpty {
            messages.append("Warning: No audio tracks selected. Output will have no audio.")
        }
        
        return messages
    }
    
    /// Creates a default routing configuration from audio track info
    /// - Parameter tracks: Array of available audio tracks
    /// - Returns: Default configuration with all tracks in original order
    static func createDefaultConfig(from tracks: [AudioTrackInfo]) -> AudioRoutingConfig {
        AudioRoutingConfig(inputTracks: tracks)
    }
    
    /// Generates a preview of the FFmpeg command for debugging
    /// - Parameter config: The audio routing configuration
    /// - Returns: Human-readable command preview
    static func previewFFmpegCommand(config: AudioRoutingConfig) -> String {
        let mapArgs = buildFFmpegMapArguments(config: config)
        
        var preview = "ffmpeg -i input.mp4"
        
        if !mapArgs.isEmpty {
            preview += " " + mapArgs.joined(separator: " ")
        }
        
        preview += " [other preset arguments] output.mp4"
        
        if let operation = config.channelOperation {
            preview += "\n\n# Active Operation: \(operation.displayDescription)"
        }
        
        return preview
    }
}
