//
//  FFMPEGProbeService.swift
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
import SwiftMediaMetadata

/// Probe facade preserved for existing callers (ffprobe removed in favour of SwiftMediaMetadata).
enum FFMPEGProbeService {
    struct AudioStreamInfo: Sendable {
        let index: Int?
        let channels: Int?
        let channelLayout: String?
        let codecName: String?

        /// Returns true if FFmpeg can decode this audio stream.
        /// Streams with unknown codecs (like Apple's APAC spatial audio) return false.
        var isDecodable: Bool {
            guard let codec = codecName?.lowercased() else { return false }
            if codec.isEmpty { return false }
            let unsupportedCodecs = ["apac"] // Apple Positional Audio Codec (spatial audio)
            return !unsupportedCodecs.contains(codec)
        }
    }

    /// Fetches audio stream metadata for the supplied input URL via SwiftMediaMetadata.
    static func fetchAudioStreams(for url: URL) async -> [AudioStreamInfo]? {
        guard SwiftExifMediaProbe.canReadVideo(url) else {
            // Audio-only containers go through readAudio — still materialise a single
            // AudioStreamInfo so callers that expect a non-nil array keep working.
            if SwiftExifMediaProbe.canReadAudio(url),
               let meta = try? await SwiftExifMediaProbe.readAudio(url) {
                return [AudioStreamInfo(
                    index: 0,
                    channels: meta.channels,
                    channelLayout: meta.channelLayout,
                    codecName: meta.codec
                )]
            }
            return []
        }

        do {
            let meta = try await SwiftExifMediaProbe.readVideo(url)
            let streams = meta.audioStreams.map { AudioStreamInfo(
                index: $0.index,
                channels: $0.channels,
                channelLayout: $0.channelLayout,
                codecName: $0.codec
            ) }
            Logger().debug("SwiftMediaMetadata audio streams for \(url.lastPathComponent): \(streams.map { "\($0.codecName ?? "unknown"):\($0.channels ?? 0)ch" })")
            return streams
        } catch {
            Logger().error("SwiftMediaMetadata audio stream extraction failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the media duration reported by SwiftMediaMetadata (or AVFoundation fallback).
    static func getVideoDuration(for url: URL) async -> Double? {
        await SwiftExifMediaProbe.duration(for: url)
    }

    // MARK: - Chapters

    /// Fetches chapter markers for `url` via SwiftMediaMetadata's container parsers.
    ///
    /// Supports MP4/MOV `chpl` boxes, QuickTime text-track chapters, and
    /// Matroska `Chapters` master elements. Returns an empty array for
    /// containers SwiftMediaMetadata can't parse (e.g. FLV, raw audio) or that carry
    /// no chapter data.
    ///
    /// Chapters whose duration can't be determined (Matroska open-ended
    /// entries, Nero `chpl` boxes) get their end time inferred from the
    /// start of the next chapter or from the container duration.
    static func fetchChapters(for url: URL) async -> [Chapter] {
        guard SwiftExifMediaProbe.canReadVideo(url) else { return [] }

        let meta: SwiftMediaMetadata.VideoMetadata
        do {
            meta = try await SwiftExifMediaProbe.readVideo(url)
        } catch {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "ChapterProbe")
                .debug("SwiftMediaMetadata chapter read failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        let sorted = meta.chapters.sorted { $0.startTime < $1.startTime }
        let duration = meta.duration ?? 0

        return sorted.enumerated().compactMap { idx, chapter in
            let start = chapter.startTime
            let end: Double = {
                if let e = chapter.endTime { return e }
                // Open-ended: use the next chapter's start, else the container duration.
                if idx + 1 < sorted.count { return sorted[idx + 1].startTime }
                return duration > start ? duration : start
            }()
            guard end > start else { return nil }
            let id = chapter.id.map { Int(truncatingIfNeeded: $0) } ?? chapter.index
            return Chapter(id: id, start: start, end: end, title: chapter.title)
        }
    }
}

// MARK: - Post-Export Verification

extension FFMPEGProbeService {
    /// Result of verifying output file stream presence.
    struct StreamVerificationResult: Sendable {
        let videoStreamCount: Int
        let audioStreamCount: Int
    }

    /// Probes the output file to count video and audio streams.
    /// Used as a safety check after merge/concat to detect silent data loss.
    static func verifyOutputStreams(for url: URL) async -> StreamVerificationResult? {
        if SwiftExifMediaProbe.canReadVideo(url),
           let meta = try? await SwiftExifMediaProbe.readVideo(url) {
            let videoCount = meta.videoStreams.filter { $0.isAttachedPic != true }.count
            let audioCount = meta.audioStreams.count
            return StreamVerificationResult(videoStreamCount: videoCount, audioStreamCount: audioCount)
        }
        if SwiftExifMediaProbe.canReadAudio(url),
           (try? await SwiftExifMediaProbe.readAudio(url)) != nil {
            return StreamVerificationResult(videoStreamCount: 0, audioStreamCount: 1)
        }
        return nil
    }
}
