// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Parses the fixed 32-byte IVF container header. IVF is the simple raw bitstream
/// wrapper the AV2 encoder (avmenc) writes; FFmpeg can read its header (dimensions,
/// frame rate) but cannot decode the AV2 payload, so we read what we need directly.
///
/// Header layout (all little-endian):
///   0..3   signature "DKIF"
///   4..5   version (0)
///   6..7   header length (32)
///   8..11  codec FourCC ("AV02" for AV2)
///   12..13 width  (uint16)
///   14..15 height (uint16)
///   16..19 frame-rate numerator   (uint32)
///   20..23 frame-rate denominator (uint32)
///   24..27 frame count (uint32)
enum IVFHeaderParser {

    struct Header: Equatable, Sendable {
        let fourCC: String
        let width: Int
        let height: Int
        let fpsNumerator: Int
        let fpsDenominator: Int
        let frameCount: Int

        /// True when the contained bitstream is AV2 (the only codec avmdec/avmenc handle).
        var isAV2: Bool { fourCC == "AV02" }

        /// Duration in seconds derived from frame count and frame rate, if determinable.
        var durationSeconds: Double? {
            guard fpsNumerator > 0, frameCount > 0 else { return nil }
            return Double(frameCount) * Double(fpsDenominator) / Double(fpsNumerator)
        }
    }

    /// Reads and parses the IVF header from the start of `url`. Returns nil if the file
    /// is too short, lacks the "DKIF" signature, or reports zero dimensions.
    static func parse(url: URL) -> Header? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32), data.count >= 32 else { return nil }
        return parse(data: data)
    }

    /// Parses an IVF header from the first 32 bytes of `data`.
    static func parse(data: Data) -> Header? {
        guard data.count >= 32 else { return nil }
        let bytes = [UInt8](data)

        guard bytes[0] == 0x44, bytes[1] == 0x4B, bytes[2] == 0x49, bytes[3] == 0x46 else {
            return nil // not "DKIF"
        }

        func u16(_ offset: Int) -> Int { Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8) | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
        }

        let fourCC = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
        let width = u16(12)
        let height = u16(14)
        guard width > 0, height > 0 else { return nil }

        return Header(
            fourCC: fourCC,
            width: width,
            height: height,
            fpsNumerator: u32(16),
            fpsDenominator: u32(20),
            frameCount: u32(24)
        )
    }
}
