// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CryptoKit
import Security
import OSLog

/// Verifies rclone binaries before we trust them. Two checks:
///
///   1. SHA-256 of the downloaded zip matches the entry in the release's `SHA256SUMS` file.
///      This pins the install to whatever rclone published — a tampered mirror or hijacked
///      browser_download_url cannot substitute a malicious binary.
///
///   2. The extracted binary has a valid Apple code signature (`SecStaticCode...`).
///      We do not pin to a specific TeamID because rclone's signing identity may rotate;
///      the SHA check above already guarantees content provenance.
enum RcloneBinaryVerifier {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "RcloneVerifier")

    // MARK: - Checksum verification

    /// Downloads the SHA256SUMS file from the given URL, parses it, and verifies that
    /// the SHA-256 of `zipURL` matches the entry for `assetName`.
    /// Throws on any mismatch, missing entry, or download failure.
    static func verifyChecksum(
        zipURL: URL,
        assetName: String,
        checksumsURL: URL
    ) async throws {
        var request = URLRequest(url: checksumsURL)
        request.setValue(GitHubRequest.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VerificationError.checksumDownloadFailed
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw VerificationError.checksumParseFailed
        }

        guard let expected = parseChecksum(for: assetName, in: text) else {
            logger.error("SHA256SUMS did not contain entry for asset: \(assetName, privacy: .public)")
            throw VerificationError.checksumEntryMissing
        }

        let actual = try sha256Hex(of: zipURL)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            logger.error("SHA256 mismatch for \(assetName, privacy: .public): expected \(expected, privacy: .public), got \(actual, privacy: .public)")
            throw VerificationError.checksumMismatch
        }

        logger.info("SHA256 verified for \(assetName, privacy: .public)")
    }

    /// Parses a SHA256SUMS file. Each line is `<hex>  <filename>` (two spaces) or `<hex> *<filename>` (binary mode).
    /// Returns the hex digest matching `assetName`, or nil if not present.
    static func parseChecksum(for assetName: String, in checksumsText: String) -> String? {
        for rawLine in checksumsText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Split on whitespace; first field is the hash, last field is the filename (may be prefixed by "*").
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let hash = String(parts[0])
            // Filename is the rest of the line after the hash, with leading whitespace and optional "*" stripped.
            var name = String(parts[1...].joined(separator: " "))
            if name.hasPrefix("*") { name.removeFirst() }
            name = name.trimmingCharacters(in: .whitespaces)

            // Asset names in SHA256SUMS may be either bare ("rclone-v1.69.0-osx-arm64.zip") or prefixed
            // with a path. Match on suffix to be lenient.
            if name == assetName || name.hasSuffix("/" + assetName) {
                // Validate hash looks like a SHA-256 hex digest.
                if hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) {
                    return hash
                }
            }
        }
        return nil
    }

    /// Returns the lowercase hex SHA-256 digest of the file at `url`.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Code signature verification

    /// Information extracted from a binary's Apple code signature.
    struct SignatureInfo {
        let teamIdentifier: String?
        let identifier: String?
    }

    /// Verifies that the binary at `url` has an intact Apple code signature.
    /// Throws on any signature issue (unsigned, broken, etc.). Returns extracted identity info on success.
    static func verifyCodeSignature(at url: URL) throws -> SignatureInfo {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw VerificationError.signatureCreateFailed(createStatus)
        }

        let validity = SecStaticCodeCheckValidity(code, [], nil)
        guard validity == errSecSuccess else {
            throw VerificationError.signatureInvalid(validity)
        }

        var info: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard infoStatus == errSecSuccess, let dict = info as? [String: Any] else {
            // Signature is valid but we couldn't read details; that's still a pass.
            return SignatureInfo(teamIdentifier: nil, identifier: nil)
        }

        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        return SignatureInfo(teamIdentifier: teamID, identifier: identifier)
    }

    // MARK: - Versions / identity check

    /// Runs the binary with `--version` and returns its first line, or nil if it does not look like rclone.
    /// Used to validate user-provided custom paths point at an actual rclone binary.
    static func versionString(of binaryPath: String) async -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bound execution to a short timeout — we're just running a CPU-only `--version`.
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = output.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Real rclone always emits "rclone v<semver>" as the first line.
        guard firstLine.hasPrefix("rclone v") else { return nil }
        return firstLine
    }

    // MARK: - Errors

    enum VerificationError: Error, LocalizedError {
        case checksumDownloadFailed
        case checksumParseFailed
        case checksumEntryMissing
        case checksumMismatch
        case signatureCreateFailed(OSStatus)
        case signatureInvalid(OSStatus)

        var errorDescription: String? {
            switch self {
            case .checksumDownloadFailed:
                return "Could not download SHA256SUMS for rclone release"
            case .checksumParseFailed:
                return "Could not read SHA256SUMS file"
            case .checksumEntryMissing:
                return "SHA256SUMS did not include an entry for the downloaded archive"
            case .checksumMismatch:
                return "Downloaded rclone archive failed checksum verification — possible tampering"
            case .signatureCreateFailed(let status):
                return "Could not read code signature (\(status))"
            case .signatureInvalid(let status):
                return "Downloaded rclone binary has an invalid or missing code signature (\(status))"
            }
        }
    }
}

// MARK: - Shared GitHub request constants

/// Centralizes the User-Agent we send to GitHub. GitHub's API requires one and rate-limits anonymous requests,
/// and a stable UA also makes it easier to identify our traffic in support investigations.
enum GitHubRequest {
    static let userAgent: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aagedal.MediaConverter"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "\(bundleID)/\(version)"
    }()
}

private extension Character {
    var isHexDigit: Bool {
        return ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
