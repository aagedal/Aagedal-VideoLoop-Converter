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

enum FFMPEGProbeService {
    struct AudioStreamInfo: Decodable, Sendable {
        let index: Int?
        let channels: Int?
        let channelLayout: String?
        let codecName: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case channels
            case channelLayout = "channel_layout"
            case codecName = "codec_name"
        }

        /// Returns true if FFmpeg can decode this audio stream.
        /// Streams with unknown codecs (like Apple's APAC spatial audio) return false.
        var isDecodable: Bool {
            guard let codec = codecName?.lowercased() else { return false }
            // FFmpeg reports unsupported codecs as empty string or with specific names
            // that have no decoder available (e.g., "none" in the demuxer output)
            if codec.isEmpty { return false }
            // Known unsupported codecs on macOS/FFmpeg
            let unsupportedCodecs = ["apac"] // Apple Positional Audio Codec (spatial audio)
            return !unsupportedCodecs.contains(codec)
        }
    }

    private struct AudioStreamsResponse: Decodable {
        let streams: [AudioStreamInfo]
    }

    /// Fetches audio stream metadata for the supplied input URL.
    static func fetchAudioStreams(for url: URL) async -> [AudioStreamInfo]? {
        guard let ffprobePath = ffprobeExecutablePath else { return nil }
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index,channels,channel_layout,codec_name",
            "-of", "json",
            url.path
        ]
        process.standardOutput = pipe

        do {
            try process.run()

            let outputData = try await readDataWithTimeout(
                from: pipe.fileHandleForReading,
                process: process,
                timeout: 5
            )

            guard let outputData, !outputData.isEmpty else {
                Logger().warning("FFprobe returned no audio stream data for \(url.lastPathComponent)")
                return []
            }

            do {
                let response = try JSONDecoder().decode(AudioStreamsResponse.self, from: outputData)
                Logger().debug("FFprobe audio streams for \(url.lastPathComponent): \(response.streams.map { "\($0.codecName ?? "unknown"):\($0.channels ?? 0)ch" })")
                return response.streams
            } catch {
                Logger().error("Failed to decode FFprobe audio stream data for \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        } catch {
            Logger().error("FFprobe audio stream extraction failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Returns the media duration reported by ffprobe.
    static func getVideoDuration(for url: URL) async -> Double? {
        guard let ffprobePath = ffprobeExecutablePath else {
            Logger().info("FFprobe not found in bundle, will use AVFoundation for duration extraction")
            return nil
        }

        Logger().info("Attempting to get duration using ffprobe for: \(url.lastPathComponent)")

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        process.standardOutput = pipe

        do {
            try process.run()

            let outputData = try await readDataWithTimeout(
                from: pipe.fileHandleForReading,
                process: process,
                timeout: 5
            )

            guard
                let outputData,
                let outputString = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                Logger().error("Failed to parse duration from ffprobe output")
                return nil
            }

            Logger().info("FFprobe raw output: \"\(outputString)\"")
            if let duration = Double(outputString) {
                Logger().info("Successfully parsed duration from ffprobe: \(duration) seconds")
                return duration
            }

            Logger().error("Failed to convert ffprobe output to Double: \"\(outputString)\"")
            return nil
        } catch {
            Logger().error("FFprobe process failed: \(error.localizedDescription)")
            return nil
        }
    }
}

private extension FFMPEGProbeService {
    static var ffprobeExecutablePath: String? {
        BinaryPathResolver.ffprobePath
    }

    static func readDataWithTimeout(
        from handle: FileHandle,
        process: Process,
        timeout: TimeInterval
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                process.terminate()
                return data
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                process.terminate()
                try? handle.close()
                throw NSError(
                    domain: "com.aagedal.videoconverter.ffprobe",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "FFprobe timeout"]
                )
            }

            guard let data = try await group.next() else {
                group.cancelAll()
                return nil
            }

            group.cancelAll()
            return data
        }
    }
}
