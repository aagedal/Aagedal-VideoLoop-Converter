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

enum ImageSequenceDetector {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ImageSequenceDetector")

    /// Regex to match a filename with a numeric suffix before the extension.
    /// Captures: (prefix)(number).(extension)
    /// Examples: "frame_0001.png" → ("frame_", "0001", "png")
    ///           "render.0042.exr" → ("render.", "0042", "exr")
    private static let sequencePattern = try! NSRegularExpression(
        pattern: #"^(.+?)(\d+)$"#,
        options: []
    )

    // MARK: - Public API

    /// Detect all image sequences in a folder.
    /// Groups files by matching prefix and extension, returns sequences with ≥2 frames.
    static func detectSequences(inFolder folderURL: URL) -> [ImageSequenceConfig] {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            logger.warning("Could not list contents of folder: \(folderURL.path, privacy: .public)")
            return []
        }

        return buildSequences(from: contents, directory: folderURL)
    }

    /// Detect an image sequence from a single file by scanning its parent directory
    /// for other files matching the same prefix and extension.
    static func detectSequence(fromFile fileURL: URL) -> ImageSequenceConfig? {
        let ext = fileURL.pathExtension.lowercased()
        guard ImageSequenceFormat.allExtensions.contains(ext) else { return nil }

        let directory = fileURL.deletingLastPathComponent()
        let sequences = detectSequences(inFolder: directory)

        // Find the sequence that contains this file's pattern
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        guard let parsed = parseFilename(baseName) else { return nil }

        return sequences.first { seq in
            // Match by prefix and extension
            let seqExt = seq.pattern.components(separatedBy: ".").last ?? ""
            let seqPrefix = extractPrefix(from: seq.pattern)
            return seqPrefix == parsed.prefix && seqExt == ext
        }
    }

    // MARK: - Private

    private struct ParsedFile {
        let url: URL
        let prefix: String
        let number: Int
        let paddingWidth: Int
        let ext: String
        let fileSize: Int64
    }

    /// Parse a filename (without extension) into prefix and numeric parts
    private static func parseFilename(_ baseName: String) -> (prefix: String, number: Int, paddingWidth: Int)? {
        let nsString = baseName as NSString
        let range = NSRange(location: 0, length: nsString.length)

        guard let match = sequencePattern.firstMatch(in: baseName, options: [], range: range) else {
            return nil
        }

        let prefix = nsString.substring(with: match.range(at: 1))
        let numberStr = nsString.substring(with: match.range(at: 2))

        guard let number = Int(numberStr) else { return nil }

        let paddingWidth = numberStr.count
        return (prefix, number, paddingWidth)
    }

    /// Extract the prefix from an FFMPEG pattern string (e.g., "frame_%04d.png" → "frame_")
    private static func extractPrefix(from pattern: String) -> String {
        // Remove the %0Nd.ext part
        guard let percentRange = pattern.range(of: "%") else { return pattern }
        return String(pattern[pattern.startIndex..<percentRange.lowerBound])
    }

    /// Build sequences from a list of file URLs
    private static func buildSequences(from urls: [URL], directory: URL) -> [ImageSequenceConfig] {
        let imageExtensions = ImageSequenceFormat.allExtensions
        var groups: [String: [ParsedFile]] = [:]

        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

            // Check it's a regular file
            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  resourceValues.isRegularFile == true else { continue }

            let baseName = url.deletingPathExtension().lastPathComponent
            guard let parsed = parseFilename(baseName) else { continue }

            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let key = "\(parsed.prefix)|\(ext)"

            let parsedFile = ParsedFile(
                url: url,
                prefix: parsed.prefix,
                number: parsed.number,
                paddingWidth: parsed.paddingWidth,
                ext: ext,
                fileSize: fileSize
            )

            groups[key, default: []].append(parsedFile)
        }

        var sequences: [ImageSequenceConfig] = []

        for (_, files) in groups {
            guard files.count >= 2 else { continue }

            let sorted = files.sorted { $0.number < $1.number }
            guard let first = sorted.first, let last = sorted.last else { continue }

            guard let format = ImageSequenceFormat.format(forExtension: first.ext) else { continue }

            // Determine padding width from the majority of files
            let paddingWidth = first.paddingWidth
            let totalSize = sorted.reduce(Int64(0)) { $0 + $1.fileSize }

            // Build the FFMPEG pattern
            let pattern = "\(first.prefix)%0\(paddingWidth)d.\(first.ext)"

            // Check for gaps in numbering
            let hasGaps = checkForGaps(in: sorted)
            if hasGaps {
                logger.info("Sequence '\(pattern, privacy: .public)' has gaps in numbering (\(sorted.count) files, range \(first.number)-\(last.number))")
            }

            let defaultFrameRate = UserDefaults.standard.double(forKey: AppConstants.imageSequenceFrameRateKey)
            let frameRate = defaultFrameRate > 0 ? defaultFrameRate : AppConstants.defaultImageSequenceFrameRate

            var config = ImageSequenceConfig(
                pattern: pattern,
                directory: directory,
                startNumber: first.number,
                endNumber: last.number,
                frameRate: frameRate,
                imageFormat: format,
                totalSizeBytes: totalSize
            )

            // Detect associated audio file in the same directory
            config.associatedAudioURL = detectAssociatedAudio(for: config)

            // If audio was found, derive frame rate from audio duration
            if let audioURL = config.associatedAudioURL,
               let audioDuration = probeAudioDuration(audioURL),
               audioDuration > 0 {
                let derivedRate = Double(config.frameCount) / audioDuration
                config.frameRate = derivedRate
                logger.info("Derived frame rate \(String(format: "%.3f", derivedRate)) fps from audio duration \(String(format: "%.3f", audioDuration))s (\(config.frameCount) frames)")
            }

            sequences.append(config)
        }

        // Sort by pattern name for consistent ordering
        sequences.sort { $0.pattern < $1.pattern }

        return sequences
    }

    /// Check if a sorted list of parsed files has gaps in numbering
    private static func checkForGaps(in sortedFiles: [ParsedFile]) -> Bool {
        guard let first = sortedFiles.first, let last = sortedFiles.last else { return false }
        let expectedCount = last.number - first.number + 1
        return sortedFiles.count != expectedCount
    }

    // MARK: - Audio File Detection

    /// Audio file extensions to look for alongside image sequences
    private static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "aac", "m4a", "flac", "ogg", "opus", "wma"
    ]

    /// Detect an associated audio file for a given image sequence config.
    /// Searches the sequence directory for audio files matching the sequence prefix
    /// or common names like "audio.wav".
    static func detectAssociatedAudio(for config: ImageSequenceConfig) -> URL? {
        let prefix = extractPrefix(from: config.pattern)
        let directory = config.directory
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        let audioFiles = contents.filter { url in
            audioExtensions.contains(url.pathExtension.lowercased())
        }

        guard !audioFiles.isEmpty else { return nil }

        // Priority 1: Exact prefix match (e.g., "render_.wav" for "render_%04d.exr")
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent
            if baseName == trimmedPrefix {
                logger.info("Found matching audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 2: Prefix starts with the sequence prefix
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent.lowercased()
            if baseName.hasPrefix(trimmedPrefix.lowercased()) {
                logger.info("Found prefix-matching audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 3: Common audio names
        let commonNames: Set<String> = ["audio", "sound", "soundtrack", "music", "mix"]
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent.lowercased()
            if commonNames.contains(baseName) {
                logger.info("Found common-name audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 4: If only one audio file in the folder, use it
        if audioFiles.count == 1 {
            logger.info("Using sole audio file in folder: \(audioFiles[0].lastPathComponent, privacy: .public)")
            return audioFiles[0]
        }

        return nil
    }

    /// Probes the duration of an audio file using ffprobe (synchronous).
    private static func probeAudioDuration(_ url: URL) -> Double? {
        guard let ffprobePath = BinaryPathResolver.ffprobePath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let duration = Double(output), duration > 0 else { return nil }
            return duration
        } catch {
            logger.warning("Failed to probe audio duration: \(error.localizedDescription)")
            return nil
        }
    }
}
