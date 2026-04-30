// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Builds the text file consumed by `bmxtranswrap --track-mca-labels` for the
/// TV (AVC-Intra MXF) preset.
///
/// The AVC-Intra preset splits every input audio channel into its own mono
/// output track (in input order: stream 0 channel 0, stream 0 channel 1,
/// stream 1 channel 0, …) and pads with silence to reach the user's configured
/// channel count. FFmpeg discards any MCA descriptors during that pipeline, so
/// the only way to land MCA labels on the OP1a output is to pass a labels file
/// to `bmxtranswrap` at the rewrap step.
///
/// Strategy: prefer labels carried by the input MXF (read upstream via
/// `BMXService.getAudioTrackLabels`); fall back to standard SMPTE labels for
/// recognized channel layouts (mono / stereo / 5.1). Skip labeling streams
/// whose layout we can't identify confidently and skip silent-padding tracks.
enum MCALabelsBuilder {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MCALabelsBuilder")

    /// Per-input-stream channel info used to derive output-track labels.
    struct InputStreamInfo: Sendable {
        /// Audio-relative index of this stream (matches `AudioTrackInfo.streamIndex`),
        /// used to look up user overrides keyed by the routing UI's stream index.
        let audioRelativeIndex: Int
        /// Channel count from FFprobe.
        let channelCount: Int
        /// FFmpeg channel layout string ("mono", "stereo", "5.1", "5.1(side)", "7.1", …) when known.
        let channelLayout: String?
        /// Sample rate in Hz, used to disambiguate the input MCA match.
        let sampleRate: Int?
    }

    /// Builds the bmx `--track-mca-labels` file content for an AVC-Intra mono-split output.
    /// - Parameters:
    ///   - inputStreams: input audio streams in the order ffmpeg processes them (only `isDecodable` streams).
    ///   - inputMCALabels: optional MCA labels read from the input MXF (empty for non-MXF inputs).
    ///   - overrides: optional manual label overrides keyed by `audioRelativeIndex`.
    ///   - outputTrackCount: total number of mono output tracks (after padding/truncation).
    /// - Returns: file content string, or nil if no useful labels can be derived.
    static func buildAVCIntraLabelsFile(
        inputStreams: [InputStreamInfo],
        inputMCALabels: [AudioTrackMCALabels],
        overrides: [Int: MCALabelOverride] = [:],
        outputTrackCount: Int
    ) -> String? {
        guard outputTrackCount > 0, !inputStreams.isEmpty else { return nil }

        var lines: [String] = []
        var outputTrackIndex = 0
        var soundfieldGroupCounter = 1
        var groupOfGroupsCounter = 1
        var emittedAny = false

        for (streamPosition, stream) in inputStreams.enumerated() {
            // Stop if we've already filled all output tracks (downstream truncation).
            if outputTrackIndex >= outputTrackCount { break }

            let mca = matchMCA(in: inputMCALabels, position: streamPosition, channels: stream.channelCount, sampleRate: stream.sampleRate)
            let override = overrides[stream.audioRelativeIndex]

            guard let group = deriveLabelGroup(stream: stream, inputMCA: mca, override: override) else {
                // Couldn't confidently label this stream — advance the output index past its
                // channels but emit nothing. Subsequent streams keep their correct positions.
                outputTrackIndex += stream.channelCount
                continue
            }

            // Skip the entire group if it can't fit in the remaining output tracks —
            // emitting a partial SG would advertise more channels than actually present.
            if outputTrackIndex + group.channelSymbols.count > outputTrackCount {
                outputTrackIndex += stream.channelCount
                continue
            }

            let groupID = "sg\(soundfieldGroupCounter)"
            soundfieldGroupCounter += 1

            // Emit a GOSG (audio element) line only when the user explicitly chose one.
            // Auto-derivation never emits an audio element to avoid mislabeling.
            let groupOfGroups: (symbol: String, id: String)?
            if let element = override?.audioElement {
                let id = "gosg\(groupOfGroupsCounter)"
                groupOfGroupsCounter += 1
                groupOfGroups = (symbol: element.bmxSymbol, id: id)
            } else {
                groupOfGroups = nil
            }

            for (channelIndex, channelSymbol) in group.channelSymbols.enumerated() {
                let isFirst = channelIndex == 0
                lines.append(contentsOf: trackBlock(
                    outputIndex: outputTrackIndex,
                    channelSymbol: channelSymbol,
                    soundfieldSymbol: group.soundfieldSymbol,
                    soundfieldID: groupID,
                    groupOfGroups: groupOfGroups,
                    isFirstInGroup: isFirst
                ))
                outputTrackIndex += 1
                emittedAny = true
            }
        }

        guard emittedAny else { return nil }
        // bmx tolerates a trailing blank line; ensure each track block is separated by one.
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Block emission

    private static func trackBlock(
        outputIndex: Int,
        channelSymbol: String,
        soundfieldSymbol: String,
        soundfieldID: String,
        groupOfGroups: (symbol: String, id: String)?,
        isFirstInGroup: Bool
    ) -> [String] {
        var block: [String] = []
        if outputIndex > 0 { block.append("") }      // blank line separates tracks
        block.append("\(outputIndex)")
        block.append(channelSymbol)
        if isFirstInGroup {
            block.append("\(soundfieldSymbol), id=\(soundfieldID)")
        } else {
            block.append("\(soundfieldSymbol), id=\(soundfieldID), repeat=false")
        }
        if let gosg = groupOfGroups {
            if isFirstInGroup {
                block.append("\(gosg.symbol), id=\(gosg.id)")
            } else {
                block.append("\(gosg.symbol), id=\(gosg.id), repeat=false")
            }
        }
        return block
    }

    // MARK: - Label derivation

    private struct LabelGroup {
        let soundfieldSymbol: String
        /// One entry per channel in the input stream, in essence channel order.
        let channelSymbols: [String]
    }

    /// Returns labels derived in priority order:
    ///   1. User override (when its soundfield's channel count matches the stream)
    ///   2. Input MCA descriptors (when channel labels align with the stream)
    ///   3. Standard SMPTE channel layouts (mono / stereo / 5.1)
    private static func deriveLabelGroup(stream: InputStreamInfo, inputMCA: AudioTrackMCALabels?, override: MCALabelOverride?) -> LabelGroup? {
        // Manual override wins when its soundfield channel count matches the stream;
        // a mismatched override (e.g. "Stereo" picked on a 6-channel input) falls
        // through so we don't produce a malformed labels file.
        if let soundfield = override?.soundfield, soundfield.channelCount == stream.channelCount {
            return LabelGroup(
                soundfieldSymbol: soundfield.bmxSymbol,
                channelSymbols: soundfield.bmxChannelSymbols
            )
        }

        // Prefer input MCA when channel labels exist and align with the stream channel count.
        if let mca = inputMCA,
           !mca.channelLabels.isEmpty,
           mca.channelLabels.count == stream.channelCount,
           let channels = mapMCAChannelsToTagSymbols(mca.channelLabels)
        {
            let sg = mca.soundfieldGroup.flatMap(canonicalSoundfieldSymbol(from:))
                ?? defaultSoundfieldSymbol(forChannelCount: stream.channelCount)
            if let sg {
                return LabelGroup(soundfieldSymbol: sg, channelSymbols: channels)
            }
        }

        // Fall back to standard channel layouts.
        return standardLabelGroup(channelCount: stream.channelCount, channelLayout: stream.channelLayout)
    }

    /// Standard SMPTE channel labels for the layouts FFmpeg can produce unambiguously.
    /// Only the layouts where channel order is universally agreed are emitted; everything
    /// else returns nil so we don't risk mislabeling.
    private static func standardLabelGroup(channelCount: Int, channelLayout: String?) -> LabelGroup? {
        let layout = (channelLayout ?? "").lowercased()
        switch channelCount {
        case 1:
            return LabelGroup(soundfieldSymbol: "sgM", channelSymbols: ["chM1"])
        case 2 where layout.isEmpty || layout.contains("stereo") || layout.contains("downmix"):
            return LabelGroup(soundfieldSymbol: "sgST", channelSymbols: ["chL", "chR"])
        case 6 where layout.contains("5.1"):
            // FFmpeg "5.1" and "5.1(side)" both deliver channels in L R C LFE Ls Rs order.
            return LabelGroup(soundfieldSymbol: "sg51", channelSymbols: ["chL", "chR", "chC", "chLFE", "chLs", "chRs"])
        default:
            return nil
        }
    }

    /// Maps MCA Tag Names / Symbols (as parsed from mxf2raw) to the bmx tag symbols.
    /// Returns nil if any channel can't be resolved confidently.
    private static func mapMCAChannelsToTagSymbols(_ labels: [String]) -> [String]? {
        var result: [String] = []
        for label in labels {
            guard let symbol = canonicalChannelSymbol(from: label) else { return nil }
            result.append(symbol)
        }
        return result
    }

    /// Resolves an MCA channel label (as stored in `AudioTrackInfo.mcaChannelLabels`,
    /// which is the human-readable Tag Name with Tag Symbol prefix stripped) to the
    /// canonical bmx channel tag symbol. Returns nil for anything ambiguous.
    private static func canonicalChannelSymbol(from label: String) -> String? {
        let normalized = label.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "l", "left", "frontleft", "leftfront": return "chL"
        case "r", "right", "frontright", "rightfront": return "chR"
        case "c", "center", "centre", "frontcenter", "frontcentre": return "chC"
        case "lfe", "lowfrequencyeffects", "subwoofer", "sub": return "chLFE"
        case "ls", "leftsurround", "surroundleft": return "chLs"
        case "rs", "rightsurround", "surroundright": return "chRs"
        case "lss", "leftsidesurround", "sideleft": return "chLss"
        case "rss", "rightsidesurround", "sideright": return "chRss"
        case "lrs", "leftrearsurround", "rearleft": return "chLrs"
        case "rrs", "rightrearsurround", "rearright": return "chRrs"
        case "lc", "leftcenter", "leftcentre": return "chLc"
        case "rc", "rightcenter", "rightcentre": return "chRc"
        case "lt", "lefttotal": return "chLt"
        case "rt", "righttotal": return "chRt"
        case "m1", "mono", "mono1", "monoone": return "chM1"
        case "m2", "mono2", "monotwo": return "chM2"
        case "hi", "hearingimpaired": return "chHI"
        case "vin", "visuallyimpairednarrative", "visuallyimpaired": return "chVIN"
        default: return nil
        }
    }

    private static func canonicalSoundfieldSymbol(from label: String) -> String? {
        let normalized = label.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        switch normalized {
        case "st", "stereo", "standardstereo": return "sgST"
        case "mono", "monoaural", "1", "10", "m": return "sgM"
        case "51", "51surround": return "sg51"
        case "71", "71ds", "71surround": return "sg71"
        case "71sds", "sds": return "sgSDS"
        case "61": return "sg61"
        case "ltrt", "lt/rt", "ltrtdownmix": return "sgLtRt"
        case "dm", "dualmono": return "sgDM"
        case "30", "40", "50", "60", "70": return "sg" + normalized
        default: return nil
        }
    }

    private static func defaultSoundfieldSymbol(forChannelCount count: Int) -> String? {
        switch count {
        case 1: return "sgM"
        case 2: return "sgST"
        case 6: return "sg51"
        case 8: return "sg71"
        default: return nil
        }
    }

    // MARK: - MCA matching

    /// Same matching logic as `AudioRoutingService.matchMCALabels`: prefer
    /// content-key match on (channels, sampleRate); fall back to positional
    /// alignment; return nil rather than poison labels with an ambiguous match.
    private static func matchMCA(in mcaLabels: [AudioTrackMCALabels], position: Int, channels: Int?, sampleRate: Int?) -> AudioTrackMCALabels? {
        guard !mcaLabels.isEmpty else { return nil }

        if let channels, let sampleRate {
            let keyMatches = mcaLabels.filter { $0.channelCount == channels && $0.sampleRate == sampleRate }
            if keyMatches.count == 1 { return keyMatches[0] }
        }
        guard mcaLabels.indices.contains(position) else { return nil }
        let candidate = mcaLabels[position]
        if let channels, let candidateChannels = candidate.channelCount, channels != candidateChannels {
            return nil
        }
        return candidate
    }
}
