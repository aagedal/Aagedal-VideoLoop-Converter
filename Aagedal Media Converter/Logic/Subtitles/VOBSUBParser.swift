// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreGraphics
import AppKit

/// Parses VOBSUB subtitle files (.idx + .sub) from DVD sources into subtitle frames.
///
/// The .idx file contains timing metadata and a 16-colour palette.
/// The .sub file is an MPEG-PS stream containing subtitle packets with RLE-encoded images.
enum VOBSUBParser {

    // MARK: - Public API

    /// Parses a VOBSUB subtitle pair and returns decoded subtitle frames.
    /// - Parameters:
    ///   - idxURL: Path to the .idx file
    ///   - subURL: Path to the .sub file
    /// - Returns: Array of decoded SubtitleFrame values
    static func parse(idxURL: URL, subURL: URL) throws -> [SubtitleFrame] {
        let idxText = try String(contentsOf: idxURL, encoding: .utf8)
        let subData = try Data(contentsOf: subURL)

        let palette = parsePalette(from: idxText)
        let entries = parseIDXEntries(from: idxText)

        var frames: [SubtitleFrame] = []

        for (idx, entry) in entries.enumerated() {
            let nextOffset = idx + 1 < entries.count ? entries[idx + 1].offset : subData.count
            let packet = extractSubtitlePacket(from: subData, at: entry.offset, end: nextOffset)
            guard let packet else { continue }

            guard let (image, durationMs) = decodeSubtitlePacket(packet, palette: palette) else { continue }
            guard let pngData = image.pngData() else { continue }

            let startTime = Double(entry.timestampMs) / 1000.0
            let endTime: TimeInterval
            if durationMs > 0 {
                endTime = startTime + Double(durationMs) / 1000.0
            } else if idx + 1 < entries.count {
                // Use next subtitle's start time as end time
                endTime = Double(entries[idx + 1].timestampMs) / 1000.0
            } else {
                endTime = startTime + 3.0 // Fallback: 3 seconds
            }

            frames.append(SubtitleFrame(startTime: startTime, endTime: endTime, imageData: pngData))
        }

        return frames
    }

    // MARK: - IDX Parsing

    private struct IDXEntry {
        let timestampMs: Int
        let offset: Int
    }

    private static func parsePalette(from idxText: String) -> [(r: UInt8, g: UInt8, b: UInt8)] {
        // Look for: palette: RRGGBB, RRGGBB, ...
        let pattern = #"palette:\s*((?:[0-9a-fA-F]{6},?\s*)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: idxText, range: NSRange(idxText.startIndex..., in: idxText)),
              let range = Range(match.range(at: 1), in: idxText) else {
            return []
        }
        let colorList = String(idxText[range])
        return colorList
            .components(separatedBy: ",")
            .compactMap { hex -> (r: UInt8, g: UInt8, b: UInt8)? in
                let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
                return (
                    r: UInt8((value >> 16) & 0xFF),
                    g: UInt8((value >> 8) & 0xFF),
                    b: UInt8(value & 0xFF)
                )
            }
    }

    private static func parseIDXEntries(from idxText: String) -> [IDXEntry] {
        // Timestamp lines: timestamp: HH:MM:SS:mmm, filepos: XXXXXXXX
        let pattern = #"timestamp:\s*(\d{2}):(\d{2}):(\d{2}):(\d{3}),\s*filepos:\s*([0-9a-fA-F]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = idxText as NSString
        let matches = regex.matches(in: idxText, range: NSRange(location: 0, length: nsText.length))

        return matches.compactMap { match -> IDXEntry? in
            guard match.numberOfRanges >= 6 else { return nil }
            let h  = Int(nsText.substring(with: match.range(at: 1))) ?? 0
            let m  = Int(nsText.substring(with: match.range(at: 2))) ?? 0
            let s  = Int(nsText.substring(with: match.range(at: 3))) ?? 0
            let ms = Int(nsText.substring(with: match.range(at: 4))) ?? 0
            let offsetHex = nsText.substring(with: match.range(at: 5))
            guard let offset = Int(offsetHex, radix: 16) else { return nil }

            let totalMs = (h * 3600 + m * 60 + s) * 1000 + ms
            return IDXEntry(timestampMs: totalMs, offset: offset)
        }
    }

    // MARK: - MPEG-PS Packet Extraction

    /// Extracts the raw subtitle data bytes from a single MPEG-PS private stream packet.
    private static func extractSubtitlePacket(from data: Data, at start: Int, end: Int) -> Data? {
        var offset = start
        var subtitleData = Data()

        while offset + 6 < min(end, data.count) {
            // MPEG-PS start code: 0x00 0x00 0x01
            guard data[offset] == 0x00,
                  data[offset + 1] == 0x00,
                  data[offset + 2] == 0x01 else {
                offset += 1
                continue
            }
            let streamID = data[offset + 3]
            let packetLen = Int(data[offset + 4]) << 8 | Int(data[offset + 5])
            offset += 6

            // 0xBD = private stream 1 (DVD subtitles)
            guard streamID == 0xBD else {
                offset += packetLen
                continue
            }

            guard offset + 3 <= data.count else { break }

            // Skip PES header extension
            // PES optional header: flags byte at offset+1 (relative to packet start)
            let flagsByte = data[offset + 1]
            let headerDataLen = Int(data[offset + 2])
            let dataStart = offset + 3 + headerDataLen

            guard dataStart + 1 <= data.count else { break }
            // First byte of payload is the sub-stream ID (0x20 for first subtitle track)
            let subStreamID = data[dataStart]
            guard (subStreamID & 0xE0) == 0x20 else {
                // Not a subtitle sub-stream
                offset += packetLen
                continue
            }

            let payloadStart = dataStart + 1
            let payloadEnd = min(offset + packetLen, data.count)
            if payloadStart < payloadEnd {
                subtitleData.append(contentsOf: data[payloadStart..<payloadEnd])
            }

            _ = flagsByte  // suppress unused warning
            offset += packetLen
        }

        return subtitleData.isEmpty ? nil : subtitleData
    }

    // MARK: - Subtitle Packet Decoder

    /// Decodes a raw VOBSUB subtitle packet into an image and display duration.
    private static func decodeSubtitlePacket(
        _ data: Data,
        palette: [(r: UInt8, g: UInt8, b: UInt8)]
    ) -> (NSImage, durationMs: Int)? {
        guard data.count >= 4 else { return nil }

        // Packet structure:
        //   2 bytes: packet size (big-endian)
        //   2 bytes: offset to control sequence
        //   N bytes: RLE image data (two fields interleaved)
        //   M bytes: control sequence

        let packetSize = Int(readUInt16BE(data, at: 0))
        let controlOffset = Int(readUInt16BE(data, at: 2))
        guard controlOffset < data.count else { return nil }

        // Parse control sequence to get dimensions, colors, display duration
        var width = 0
        var height = 0
        var field1Offset = 0
        var field2Offset = 0
        var durationMs = 0
        var colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = [:]

        var ctrlOff = controlOffset
        while ctrlOff + 1 < min(packetSize, data.count) {
            let displayTime = Int(readUInt16BE(data, at: ctrlOff)) * 1000 / 90
            ctrlOff += 2
            guard ctrlOff < data.count else { break }
            let cmdStart = ctrlOff

            var done = false
            while !done && ctrlOff < data.count {
                let cmd = data[ctrlOff]
                ctrlOff += 1
                switch cmd {
                case 0x00:
                    // Force display
                    break
                case 0x01:
                    // Start display time
                    durationMs = 0
                case 0x02:
                    // Stop display time
                    durationMs = displayTime
                    done = true
                case 0x03:
                    // Set color indices (4 indices into subtitle palette)
                    guard ctrlOff + 1 < data.count else { done = true; break }
                    let b0 = Int(data[ctrlOff]); ctrlOff += 1
                    let b1 = Int(data[ctrlOff]); ctrlOff += 1
                    // Map subtitle color indices 3,2,1,0 to palette entries
                    for k in 0..<4 {
                        let palIdx: Int
                        if k < 2 {
                            palIdx = (b1 >> ((1 - k) * 4)) & 0x0F
                        } else {
                            palIdx = (b0 >> ((3 - k) * 4)) & 0x0F
                        }
                        if palIdx < palette.count {
                            let p = palette[palIdx]
                            colorMap[k] = (r: p.r, g: p.g, b: p.b, a: 255)
                        }
                    }
                case 0x04:
                    // Set alpha values (4 values)
                    guard ctrlOff + 1 < data.count else { done = true; break }
                    let a0 = Int(data[ctrlOff]); ctrlOff += 1
                    let a1 = Int(data[ctrlOff]); ctrlOff += 1
                    for k in 0..<4 {
                        let alpha: UInt8
                        if k < 2 {
                            alpha = UInt8(((a1 >> ((1 - k) * 4)) & 0x0F) * 17)
                        } else {
                            alpha = UInt8(((a0 >> ((3 - k) * 4)) & 0x0F) * 17)
                        }
                        if var entry = colorMap[k] {
                            entry.a = alpha
                            colorMap[k] = entry
                        }
                    }
                case 0x05:
                    // Set display area: x1,x2,y1,y2 packed in 6 bytes
                    guard ctrlOff + 5 < data.count else { done = true; break }
                    let x1 = (Int(data[ctrlOff]) << 4) | (Int(data[ctrlOff + 1]) >> 4)
                    let x2 = ((Int(data[ctrlOff + 1]) & 0x0F) << 8) | Int(data[ctrlOff + 2])
                    let y1 = (Int(data[ctrlOff + 3]) << 4) | (Int(data[ctrlOff + 4]) >> 4)
                    let y2 = ((Int(data[ctrlOff + 4]) & 0x0F) << 8) | Int(data[ctrlOff + 5])
                    ctrlOff += 6
                    width  = x2 - x1 + 1
                    height = y2 - y1 + 1
                case 0x06:
                    // Set pixel data offsets (field 1 and field 2)
                    guard ctrlOff + 3 < data.count else { done = true; break }
                    field1Offset = Int(readUInt16BE(data, at: ctrlOff)); ctrlOff += 2
                    field2Offset = Int(readUInt16BE(data, at: ctrlOff)); ctrlOff += 2
                case 0xFF:
                    // End of control sequence
                    done = true
                default:
                    // Unknown command — stop parsing this block
                    done = true
                }
            }

            // Check if we've moved to a new control block or ended
            if ctrlOff >= cmdStart + 2 && !done {
                // Next block follows
            } else {
                break
            }
        }

        guard width > 0, height > 0 else { return nil }

        // Decode two interlaced fields into a full RGBA image
        let pixels = decodeRLE(
            data: data,
            field1Offset: field1Offset,
            field2Offset: field2Offset,
            width: width,
            height: height,
            colorMap: colorMap
        )

        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        return (image, durationMs)
    }

    // MARK: - VOBSUB RLE Decoder

    /// Decodes VOBSUB 2-bit RLE into an RGBA pixel buffer.
    /// VOBSUB images are stored as two interlaced fields (even lines = field 1, odd lines = field 2).
    private static func decodeRLE(
        data: Data,
        field1Offset: Int,
        field2Offset: Int,
        width: Int,
        height: Int,
        colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)]
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        decodeField(
            data: data, startOffset: field1Offset,
            width: width, height: height, startLine: 0, step: 2,
            colorMap: colorMap, into: &pixels
        )
        decodeField(
            data: data, startOffset: field2Offset,
            width: width, height: height, startLine: 1, step: 2,
            colorMap: colorMap, into: &pixels
        )

        return pixels
    }

    private static func decodeField(
        data: Data,
        startOffset: Int,
        width: Int,
        height: Int,
        startLine: Int,
        step: Int,
        colorMap: [Int: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)],
        into pixels: inout [UInt8]
    ) {
        var byteOffset = startOffset
        var bitPos = 0  // next bit to read within current byte (0 = MSB)
        var line = startLine

        func readBits(_ n: Int) -> Int {
            var result = 0
            for _ in 0..<n {
                guard byteOffset < data.count else { return result }
                let byte = Int(data[byteOffset])
                let bit = (byte >> (7 - bitPos)) & 1
                result = (result << 1) | bit
                bitPos += 1
                if bitPos == 8 { bitPos = 0; byteOffset += 1 }
            }
            return result
        }

        while line < height {
            var col = 0
            while col < width {
                // VOBSUB 2-bit RLE:
                // Read nibbles until we get a run:
                // 0b11cc: run of cc+1 for rest of line? No — standard RLE:
                // Starts with 2 bits for run length + 2 bits for color
                // Extended runs: leading zeros double the range each time
                var runLength = 0
                var color = 0
                var bits = readBits(4)

                if bits == 0 {
                    // Long run (at least 3 nibbles)
                    bits = readBits(4)
                    if bits == 0 {
                        // Even longer (5+ nibbles)
                        bits = readBits(4)
                        if bits == 0 {
                            // Maximum length run (to end of line or 255)
                            bits = readBits(4)
                            runLength = bits + 48
                            color = readBits(2)
                            // Actually for VOBSUB: if run == 0 after all nibbles, fill to end of line
                        } else {
                            runLength = bits + 12
                        }
                    } else {
                        runLength = bits + 4
                    }
                } else {
                    runLength = bits >> 2
                    color = bits & 0x03
                }

                if runLength == 0 {
                    // Fill to end of line
                    runLength = width - col
                }

                // Read color if not yet read
                if bits > 3 {
                    color = readBits(2)
                }

                let entry = colorMap[color]
                for _ in 0..<runLength {
                    if col >= width { break }
                    let pixelIdx = (line * width + col) * 4
                    if let c = entry {
                        pixels[pixelIdx]     = c.r
                        pixels[pixelIdx + 1] = c.g
                        pixels[pixelIdx + 2] = c.b
                        pixels[pixelIdx + 3] = c.a
                    }
                    col += 1
                }
            }
            // Align to byte boundary between lines
            if bitPos != 0 { bitPos = 0; byteOffset += 1 }
            line += step
        }
    }

    // MARK: - Helpers

    @inline(__always)
    private static func readUInt16BE(_ data: Data, at index: Int) -> UInt16 {
        guard index + 1 < data.count else { return 0 }
        return (UInt16(data[index]) << 8) | UInt16(data[index + 1])
    }
}

// MARK: - NSImage PNG helper

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }
}
