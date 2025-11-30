// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Represents a single audio track with metadata
struct AudioTrackInfo: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let streamIndex: Int
    let channels: Int?
    let channelLayout: String?
    let codec: String?
    let codecLongName: String?
    let sampleRate: Int?
    let languageCode: String?
    let title: String?
    let bitRate: Int64?
    let trackNumber: Int? // Position-based track number (1, 2, 3...) rather than stream index
    
    init(
        id: UUID = UUID(),
        streamIndex: Int,
        channels: Int?,
        channelLayout: String?,
        codec: String?,
        codecLongName: String?,
        sampleRate: Int?,
        languageCode: String? = nil,
        title: String? = nil,
        bitRate: Int64? = nil,
        trackNumber: Int? = nil
    ) {
        self.id = id
        self.streamIndex = streamIndex
        self.channels = channels
        self.channelLayout = channelLayout
        self.codec = codec
        self.codecLongName = codecLongName
        self.sampleRate = sampleRate
        self.languageCode = languageCode
        self.title = title
        self.bitRate = bitRate
        self.trackNumber = trackNumber
    }
    
    /// Human-readable track label
    var displayLabel: String {
        // Use trackNumber if available, otherwise fall back to streamIndex + 1
        let trackLabel = trackNumber.map { "Track \($0)" } ?? "Track \(streamIndex + 1)"
        var components: [String] = [trackLabel]
        
        if let title = title, !title.isEmpty {
            components.append(title)
        }
        
        if let channelLayout = channelLayout {
            components.append(channelLayout)
        } else if let channels = channels {
            switch channels {
            case 1: components.append("Mono")
            case 2: components.append("Stereo")
            default: components.append("\(channels) ch")
            }
        }
        
        return components.joined(separator: " • ")
    }
    
    /// Technical details for subtitle display
    var technicalDetails: String {
        var parts: [String] = []
        
        if let codec = codecLongName ?? codec {
            parts.append(codec)
        }
        
        if let sampleRate = sampleRate {
            parts.append("\(sampleRate) Hz")
        }
        
        if let languageCode = languageCode {
            parts.append(languageCode.uppercased())
        }
        
        return parts.joined(separator: " • ")
    }
}

// MARK: - Channel Operations

/// Represents channel-level audio operations beyond simple track selection
enum ChannelOperation: Equatable, Sendable, Codable {
    /// Merge two mono tracks into a single stereo track
    case mergeToStereo(trackIndices: [Int])
    
    /// Split a stereo track into two mono tracks
    case splitToMono(trackIndex: Int)
    
    /// Swap left and right channels of a stereo track
    case swapChannels(trackIndex: Int)
    
    /// Extract a single channel from a multi-channel track
    case extractChannel(trackIndex: Int, channelIndex: Int, channelName: String)
    
    /// Human-readable description of the operation
    var displayDescription: String {
        switch self {
        case .mergeToStereo(let indices):
            return "Merging \(indices.count) mono tracks into stereo"
        case .splitToMono(let trackIndex):
            return "Splitting track \(trackIndex + 1) into mono channels"
        case .swapChannels(let trackIndex):
            return "Swapping L/R channels on track \(trackIndex + 1)"
        case .extractChannel(let trackIndex, _, let name):
            return "Extracting \(name) channel from track \(trackIndex + 1)"
        }
    }
    
    /// Short label for UI badges
    var shortLabel: String {
        switch self {
        case .mergeToStereo:
            return "Merge to Stereo"
        case .splitToMono:
            return "Split to Mono"
        case .swapChannels:
            return "Swap L/R"
        case .extractChannel(_, _, let name):
            return "Extract \(name)"
        }
    }
}

// MARK: - Audio Routing Configuration

/// Audio routing configuration for a video item
struct AudioRoutingConfig: Equatable, Sendable, Codable {
    /// Source tracks available in the input file
    let inputTracks: [AudioTrackInfo]
    
    /// Selected output tracks in desired order (by stream index)
    var outputTrackIndices: [Int]
    
    /// Optional channel-level operation (overrides simple track mapping)
    var channelOperation: ChannelOperation? = nil
    
    init(inputTracks: [AudioTrackInfo], outputTrackIndices: [Int]? = nil) {
        self.inputTracks = inputTracks
        // Default: include all tracks in original order
        self.outputTrackIndices = outputTrackIndices ?? inputTracks.map(\.streamIndex)
    }
    
    /// Returns true if configuration differs from default (all tracks in order)
    var isCustomized: Bool {
        let defaultOrder = inputTracks.map(\.streamIndex)
        return outputTrackIndices != defaultOrder || channelOperation != nil
    }
    
    /// Returns true if a channel operation is active
    var hasChannelOperation: Bool {
        channelOperation != nil
    }
    
    /// Reset to default configuration (all tracks in original order, no operations)
    mutating func resetToDefault() {
        outputTrackIndices = inputTracks.map(\.streamIndex)
        channelOperation = nil
    }
    
    /// Add a track to output by stream index
    mutating func addTrack(_ streamIndex: Int) {
        guard !outputTrackIndices.contains(streamIndex) else { return }
        outputTrackIndices.append(streamIndex)
        // Clear channel operation when manually adjusting tracks
        channelOperation = nil
    }
    
    /// Remove a track from output by stream index
    mutating func removeTrack(_ streamIndex: Int) {
        outputTrackIndices.removeAll { $0 == streamIndex }
        // Clear channel operation when manually adjusting tracks
        channelOperation = nil
    }
    
    /// Move a track from one position to another in output
    mutating func moveTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard outputTrackIndices.indices.contains(sourceIndex),
              outputTrackIndices.indices.contains(destinationIndex) else {
            return
        }
        let track = outputTrackIndices.remove(at: sourceIndex)
        outputTrackIndices.insert(track, at: destinationIndex)
        // Clear channel operation when manually reordering tracks
        channelOperation = nil
    }
    
    /// Set a channel operation (clears any existing operation)
    mutating func setChannelOperation(_ operation: ChannelOperation) {
        channelOperation = operation
    }
    
    /// Clear the active channel operation
    mutating func clearChannelOperation() {
        channelOperation = nil
    }
    
    /// Get track info for a given stream index
    func trackInfo(for streamIndex: Int) -> AudioTrackInfo? {
        inputTracks.first { $0.streamIndex == streamIndex }
    }
    
    /// Get ordered output tracks with full info
    var outputTracks: [AudioTrackInfo] {
        outputTrackIndices.compactMap { index in
            inputTracks.first { $0.streamIndex == index }
        }
    }
}
