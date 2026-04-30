// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit

/// Helpers shared across SMPTE-style packaging (DCP, IMF). All functions are pure and
/// can be called from any isolation context.
enum SMPTEPackageUtils {

    // MARK: - URN / UUID

    static func urnUUID() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }

    static func uuidString(from urn: String) -> String {
        urn.replacingOccurrences(of: "urn:uuid:", with: "")
    }

    // MARK: - Hash & size

    static func computeSHA1(for url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fileHandle.closeFile() }

        var hasher = Insecure.SHA1()
        let bufferSize = 1024 * 1024
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    /// Convert hex SHA-1 hash to base64 (as required by DCP/IMF PKL).
    static func base64SHA1(hex: String) -> String {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<nextIndex], radix: 16) {
                bytes.append(byte)
            }
            index = nextIndex
        }
        return Data(bytes).base64EncodedString()
    }

    // MARK: - XML

    static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
