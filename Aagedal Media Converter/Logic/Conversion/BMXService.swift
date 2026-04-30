// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Thread-safe collector for stderr data
private actor StderrCollector {
    private var buffer = Data()

    func append(_ data: Data) {
        buffer.append(data)
    }

    func snapshot() -> Data {
        buffer
    }
}

// MARK: - MCA Label Models

/// SMPTE ST 377-4 Multi-Channel Audio labels for one MXF audio essence track,
/// extracted from mxf2raw's XML metadata output.
struct AudioTrackMCALabels: Sendable {
    /// 1-based MXF essence track index, in the order mxf2raw emits Sound tracks.
    let trackNumber: Int
    /// Channel count from the sound descriptor (used for content-keyed alignment with FFmpeg).
    let channelCount: Int?
    /// Sampling rate in Hz from the sound descriptor (used for content-keyed alignment with FFmpeg).
    let sampleRate: Int?
    /// Soundfield group symbol such as "5.1", "ST", "7.1DS" (derived from the SoundfieldGroupLabelSubDescriptor).
    let soundfieldGroup: String?
    /// Audio element symbol such as "DX", "ME", "VI-N" (derived from a GroupOfSoundfieldGroupsLabelSubDescriptor
    /// or from a SoundfieldGroup whose tag symbol starts with "ae").
    let audioElement: String?
    /// Per-channel labels in essence channel order (e.g. ["L", "R", "C", "LFE", "Ls", "Rs"]).
    let channelLabels: [String]
}

/// Service for handling BMX tools operations (MXF rewrapping + MCA label extraction)
actor BMXService {
    static let shared = BMXService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "BMXService")
    private var currentProcess: Process?

    /// Cache keyed by URL; entries invalidate when the file's modification date changes.
    private struct MCACacheEntry {
        let modificationDate: Date?
        let labels: [AudioTrackMCALabels]
    }
    private var mcaCache: [URL: MCACacheEntry] = [:]

    private init() {}

    // MARK: - Public API

    /// Rewraps an MXF file to OP1a format using bmxtranswrap
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (OP1a compliant)
    ///   - clipName: Optional clip name for the output
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToOP1a(
        inputURL: URL,
        outputURL: URL,
        clipName: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        var arguments: [String] = [
            "-t", "op1a",
            "--use-avc-subdesc",
        ]

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            progress: progress
        )
    }

    /// Rewraps an MXF file to RDD9 (SMPTE RDD 9) format for DCP-compliant ASDCP MXF
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (ASDCP compliant)
    ///   - isVideo: Whether this is a video MXF (adds DCI color metadata)
    ///   - clipName: Optional clip name for the output
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToRDD9(
        inputURL: URL,
        outputURL: URL,
        isVideo: Bool = true,
        clipName: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        var arguments: [String] = [
            "-t", "rdd9",
        ]

        // Add DCI color metadata for video MXF
        if isVideo {
            arguments.append(contentsOf: [
                "--signal-std", "st428",
                "--transfer-ch", "dcdm",
                "--color-prim", "dcdm",
                "--coding-eq", "gbr",
            ])
        }

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            progress: progress
        )
    }

    /// Cancels the current bmxtranswrap operation
    func cancel() {
        if let process = currentProcess, process.isRunning {
            process.terminate()
            currentProcess = nil
            logger.info("bmxtranswrap cancelled")
        }
    }

    // MARK: - Shared Process Execution

    /// Shared bmxtranswrap execution with input/output validation, progress parsing, and error handling
    private func runBMXTranswrap(
        inputURL: URL,
        outputURL: URL,
        extraArguments: [String],
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        guard let bmxtranswrapPath = BinaryPathResolver.bmxtranswrapPath else {
            logger.error("bmxtranswrap binary not found")
            return false
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            logger.error("Input MXF file not found: \(inputURL.path)")
            return false
        }

        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create output directory: \(error.localizedDescription)")
            return false
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                logger.error("Failed to remove existing output file: \(error.localizedDescription)")
                return false
            }
        }

        var arguments = extraArguments
        arguments.append(contentsOf: ["-o", outputURL.path, "-p"])
        arguments.append(inputURL.path)

        logger.info("Running bmxtranswrap: \(arguments.joined(separator: " "))")

        let process = Process()
        currentProcess = process
        process.executableURL = URL(fileURLWithPath: bmxtranswrapPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasSuffix("%") {
                        let numStr = trimmed.dropLast()
                        if let percent = Double(numStr) {
                            Task { @MainActor in
                                progress(percent / 100.0)
                            }
                        }
                    }
                }
            }
        }

        let stderrCollector = StderrCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                Task { await stderrCollector.append(data) }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to run bmxtranswrap: \(error.localizedDescription)")
            currentProcess = nil
            return false
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        currentProcess = nil

        let success = process.terminationStatus == 0

        if success {
            logger.info("bmxtranswrap completed successfully: \(outputURL.lastPathComponent)")
            progress(1.0)
        } else {
            let stderrData = await stderrCollector.snapshot()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? "(no error output)"
            logger.error("bmxtranswrap failed with code \(process.terminationStatus): \(stderrString)")
        }

        return success
    }

    // MARK: - MXF Info

    /// Gets information about an MXF file using mxf2raw
    /// - Parameter url: The MXF file to analyze
    /// - Returns: MXF info string, or nil if failed
    func getMXFInfo(url: URL) async -> String? {
        guard let mxf2rawPath = BinaryPathResolver.mxf2rawPath else {
            logger.error("mxf2raw binary not found")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("MXF file not found: \(url.path)")
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: mxf2rawPath)
        process.arguments = ["--info", url.path]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            try? stdoutPipe.fileHandleForReading.close()
            if let output = String(data: data, encoding: .utf8) {
                return output
            }
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            logger.error("Failed to run mxf2raw: \(error.localizedDescription)")
        }

        return nil
    }

    /// Checks if an MXF file is OP1a compliant
    /// - Parameter url: The MXF file to check
    /// - Returns: true if OP1a, false otherwise or if check failed
    func isOP1a(url: URL) async -> Bool {
        guard let info = await getMXFInfo(url: url) else {
            return false
        }
        // Check for OP1a in the info output
        return info.contains("OP-1a") || info.contains("OP1a")
    }

    // MARK: - MCA Audio Track Labels

    /// Extracts SMPTE ST 377-4 MCA labels for each audio essence track in an MXF file.
    /// - Parameter url: The MXF file to inspect (caller is responsible for security-scoped access).
    /// - Returns: Per-track MCA labels in the order mxf2raw emits Sound tracks, or nil if mxf2raw fails.
    ///           Tracks without MCA descriptors yield entries with nil/empty label fields.
    func getAudioTrackLabels(url: URL) async -> [AudioTrackMCALabels]? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        if let cached = mcaCache[url], cached.modificationDate == mtime {
            return cached.labels
        }

        guard let mxf2rawPath = BinaryPathResolver.mxf2rawPath else {
            logger.error("mxf2raw binary not found")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("MXF file not found: \(url.path)")
            return nil
        }

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: mxf2rawPath)
        process.arguments = [
            "--info",
            "--info-format", "xml",
            "--mca-detail",
            url.path,
        ]
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let xmlData: Data
        do {
            try process.run()
            xmlData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            try? stdoutPipe.fileHandleForReading.close()
            process.waitUntilExit()
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            logger.error("Failed to run mxf2raw for MCA labels: \(error.localizedDescription)")
            return nil
        }

        guard process.terminationStatus == 0 else {
            logger.warning("mxf2raw exited \(process.terminationStatus) for \(url.lastPathComponent)")
            return nil
        }

        let labels = MXFInfoMCAParser.parse(xmlData: xmlData)
        mcaCache[url] = MCACacheEntry(modificationDate: mtime, labels: labels)
        logger.info("Parsed \(labels.count) MCA-bearing audio tracks from \(url.lastPathComponent)")
        return labels
    }

    /// Invalidates the cached MCA labels for a URL (e.g. when the file is replaced on disk).
    func invalidateMCACache(for url: URL) {
        mcaCache.removeValue(forKey: url)
    }
}

// MARK: - MXF Info MCA XML Parser

/// Streams mxf2raw's XML output and extracts per-track MCA labels.
/// Element names match bmx 1.6's BBC schema (`http://bbc.co.uk/rd/bmx/201312`):
///   `<bmx><clip><tracks><track index="N"><essence_kind>Sound</essence_kind>
///       <sound_descriptor>... <channel_count> <sampling_rate> ...</sound_descriptor>
///       <mca_labels>
///         <channel_label><tag_symbol>chL</tag_symbol><tag_name>Left</tag_name></channel_label>
///         <soundfield_group><tag_symbol>sg51</tag_symbol><tag_name>5.1</tag_name></soundfield_group>
///         <group_of_soundfield_group><tag_symbol>aeDX</tag_symbol><tag_name>Dialog</tag_name></group_of_soundfield_group>
///       </mca_labels>
///     </track></tracks></clip></bmx>`
private final class MXFInfoMCAParser: NSObject, XMLParserDelegate {
    static func parse(xmlData: Data) -> [AudioTrackMCALabels] {
        let delegate = MXFInfoMCAParser()
        let parser = XMLParser(data: xmlData)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.completedTracks
    }

    // MARK: parser state

    private var elementStack: [String] = []
    private var textBuffer: String = ""

    // Per-track scratch state (only populated when inside a Sound track)
    private var inSoundTrack = false
    private var currentTrackSoundIndex = 0    // 1-based index across Sound tracks only
    private var soundTracksSeen = 0
    private var currentChannelCount: Int?
    private var currentSampleRate: Int?
    private var currentChannelLabels: [(channelID: Int?, symbol: String?, name: String?)] = []
    private var currentSoundfieldGroups: [(symbol: String?, name: String?)] = []
    private var currentAudioElements: [(symbol: String?, name: String?)] = []

    // Per-MCA-block scratch state
    private enum MCABlockKind { case channelLabel, soundfieldGroup, groupOfSoundfieldGroups }
    private var currentBlockKind: MCABlockKind?
    private var currentBlockSymbol: String?
    private var currentBlockName: String?
    private var currentBlockChannelID: Int?

    private var completedTracks: [AudioTrackMCALabels] = []

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let local = localName(of: elementName)
        elementStack.append(local)
        textBuffer = ""

        switch local {
        case "track":
            // Reset per-track state; we'll find out if it's a Sound track when essence_kind appears.
            inSoundTrack = false
            currentChannelCount = nil
            currentSampleRate = nil
            currentChannelLabels = []
            currentSoundfieldGroups = []
            currentAudioElements = []
        case "channel_label":
            currentBlockKind = .channelLabel
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        case "soundfield_group":
            currentBlockKind = .soundfieldGroup
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        case "group_of_soundfield_group", "group_of_soundfield_groups":
            currentBlockKind = .groupOfSoundfieldGroups
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(of: elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "essence_kind":
            // Direct child of <track>.
            if elementStack.dropLast().last == "track", value == "Sound" {
                inSoundTrack = true
                soundTracksSeen += 1
                currentTrackSoundIndex = soundTracksSeen
            }
        case "channel_count":
            if inSoundTrack, let n = Int(value) {
                currentChannelCount = n
            }
        case "sampling_rate":
            if inSoundTrack {
                currentSampleRate = parseRate(value)
            }
        case "tag_symbol":
            if currentBlockKind != nil { currentBlockSymbol = value }
        case "tag_name":
            if currentBlockKind != nil { currentBlockName = value }
        case "channel_id":
            if currentBlockKind == .channelLabel { currentBlockChannelID = Int(value) }
        case "channel_label":
            if inSoundTrack, currentBlockKind == .channelLabel {
                currentChannelLabels.append((channelID: currentBlockChannelID, symbol: currentBlockSymbol, name: currentBlockName))
            }
            currentBlockKind = nil
        case "soundfield_group":
            if inSoundTrack, currentBlockKind == .soundfieldGroup {
                // Audio elements often appear as soundfield groups whose tag symbol starts with "ae".
                let symbol = currentBlockSymbol ?? ""
                if symbol.lowercased().hasPrefix("ae") {
                    currentAudioElements.append((symbol: currentBlockSymbol, name: currentBlockName))
                } else {
                    currentSoundfieldGroups.append((symbol: currentBlockSymbol, name: currentBlockName))
                }
            }
            currentBlockKind = nil
        case "group_of_soundfield_group", "group_of_soundfield_groups":
            if inSoundTrack, currentBlockKind == .groupOfSoundfieldGroups {
                currentAudioElements.append((symbol: currentBlockSymbol, name: currentBlockName))
            }
            currentBlockKind = nil
        case "track":
            if inSoundTrack {
                let channels = currentChannelLabels
                    .sorted { (a, b) in (a.channelID ?? Int.max) < (b.channelID ?? Int.max) }
                    .compactMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                let soundfield = currentSoundfieldGroups.first.flatMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                let element = currentAudioElements.first.flatMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                completedTracks.append(AudioTrackMCALabels(
                    trackNumber: currentTrackSoundIndex,
                    channelCount: currentChannelCount,
                    sampleRate: currentSampleRate,
                    soundfieldGroup: soundfield,
                    audioElement: element,
                    channelLabels: channels
                ))
            }
            inSoundTrack = false
        default:
            break
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        textBuffer = ""
    }

    // MARK: helpers

    private func localName(of elementName: String) -> String {
        // Strip an XML namespace prefix if any (`prefix:local`).
        if let colon = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    /// Convert a sampling_rate of the form "48000/1" to integer Hz; tolerate bare integers.
    private func parseRate(_ value: String) -> Int? {
        if let slash = value.firstIndex(of: "/") {
            let num = Int(value[..<slash]) ?? 0
            let den = Int(value[value.index(after: slash)...]) ?? 1
            guard den != 0 else { return nil }
            return num / den
        }
        return Int(value)
    }

    /// Prefer the human-readable Tag Name when available; fall back to the SMPTE Tag Symbol
    /// (stripped of its "ch"/"sg"/"ae" prefix to keep the routing UI compact).
    private func displayLabel(symbol: String?, name: String?) -> String? {
        if let name, !name.isEmpty { return name }
        guard let symbol, !symbol.isEmpty else { return nil }
        let lowered = symbol.lowercased()
        if lowered.hasPrefix("ch") || lowered.hasPrefix("sg") || lowered.hasPrefix("ae") {
            return String(symbol.dropFirst(2))
        }
        return symbol
    }
}

// MARK: - BMX Errors

enum BMXError: Error, LocalizedError {
    case binaryNotFound
    case inputNotFound
    case rewrapFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "BMX tools not found"
        case .inputNotFound:
            return "Input MXF file not found"
        case .rewrapFailed(let message):
            return "MXF rewrap failed: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
}
