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
import SwiftExif

/// Probe facade preserved for existing callers (ffprobe removed in favour of SwiftExif 1.2.0).
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

    /// Fetches audio stream metadata for the supplied input URL via SwiftExif.
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
            Logger().debug("SwiftExif audio streams for \(url.lastPathComponent): \(streams.map { "\($0.codecName ?? "unknown"):\($0.channels ?? 0)ch" })")
            return streams
        } catch {
            Logger().error("SwiftExif audio stream extraction failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the media duration reported by SwiftExif (or AVFoundation fallback).
    static func getVideoDuration(for url: URL) async -> Double? {
        await SwiftExifMediaProbe.duration(for: url)
    }

    // MARK: - Chapters

    /// Fetches chapter markers for `url`.
    ///
    /// SwiftExif 1.2.0 does not yet expose chapters, so this currently shells out to
    /// the bundled `ffprobe`. When SwiftExif gains chapter support, swap the
    /// implementation here — callers should not need to change.
    static func fetchChapters(for url: URL) async -> [Chapter] {
        await FFprobeChapterReader.read(url: url)
    }
}

// MARK: - ffprobe chapter backend

/// Temporary ffprobe-backed chapter reader. Will be replaced with a SwiftExif
/// implementation once the upstream library exposes chapter markers.
private enum FFprobeChapterReader {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ChapterProbe")

    static func read(url: URL) async -> [Chapter] {
        guard let ffprobe = BinaryPathResolver.ffprobePath else {
            logger.debug("ffprobe unavailable; skipping chapter probe")
            return []
        }

        // Build the process up-front so the cancellation handler can reach it.
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_chapters",
            url.path
        ]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        // We run the blocking ffprobe invocation on a detached task so the main
        // actor stays responsive, but we wrap it with a cancellation handler so
        // a cancelled parent task terminates the live process immediately — a
        // bare `Task.detached.value` would otherwise pin a cooperative-pool
        // thread and a file descriptor triple until ffprobe exited on its own.
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                runProbe(process: process, stdout: stdout, url: url)
            }.value
        } onCancel: {
            // Sendable-safe: Process is a reference type; terminate() is thread-safe.
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func runProbe(process: Process, stdout: Pipe, url: URL) -> [Chapter] {
        let readHandle = stdout.fileHandleForReading
        // Always release the read end, even on early return / throw.
        defer { try? readHandle.close() }

        do {
            try process.run()
        } catch {
            logger.debug("ffprobe launch failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }

        // Reading to end before waitUntilExit is safe here: stderr is /dev/null
        // so the process cannot block on a full stderr pipe, and chapter JSON
        // is tiny (well under any pipe buffer limit).
        let data = (try? readHandle.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return [] }
        return parse(data)
    }

    private static func parse(_ data: Data) -> [Chapter] {
        struct Payload: Decodable {
            struct Entry: Decodable {
                let id: Int?
                let start_time: String?
                let end_time: String?
                let tags: [String: String]?
            }
            let chapters: [Entry]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let entries = payload.chapters else { return [] }

        return entries.enumerated().compactMap { index, entry in
            guard let startString = entry.start_time, let start = Double(startString),
                  let endString = entry.end_time, let end = Double(endString),
                  end > start else { return nil }
            let title = entry.tags?["title"] ?? entry.tags?["TITLE"]
            return Chapter(id: entry.id ?? index, start: start, end: end, title: title)
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
