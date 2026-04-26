// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Models

/// Outcome of inspecting a single FileZilla site entry.
///
/// FileZilla can store passwords plain (base64), encrypted with a master password,
/// or not at all. We import what we can and surface the rest to the user.
enum FileZillaImportStatus: Equatable, Sendable {
    /// Protocol and credentials are usable. The password (if any) is in `plainPassword`.
    case importable
    /// Site uses a supported protocol but the password is encrypted with a FileZilla master password.
    /// Imports the profile without the password — user re-enters it manually.
    case passwordEncrypted
    /// Site uses a supported protocol but the password is not stored ("Ask for password" / Interactive).
    case passwordRequired
    /// The protocol is recognised but not supported by this app (e.g. WebDAV, Storj).
    case unsupportedProtocol(name: String)
    /// The entry is malformed (missing host, etc.).
    case invalid(reason: String)

    var canImport: Bool {
        switch self {
        case .importable, .passwordEncrypted, .passwordRequired: return true
        case .unsupportedProtocol, .invalid: return false
        }
    }
}

/// A single parsed entry from a FileZilla `sitemanager.xml`.
struct FileZillaSite: Identifiable, Sendable {
    let id: UUID = UUID()
    var name: String
    var host: String
    var port: Int?
    var username: String
    /// Decoded plaintext password, if and only if status == .importable and the site had a password.
    var plainPassword: String?
    var remotePath: String
    var suggestedBackend: UploadBackendType
    var useFTPS: Bool
    var status: FileZillaImportStatus
}

// MARK: - Importer

enum FileZillaImporter {

    enum ImportError: LocalizedError {
        case fileUnreadable
        case malformedXML
        case notFileZillaFile

        var errorDescription: String? {
            switch self {
            case .fileUnreadable:    return "Could not read the selected file."
            case .malformedXML:      return "The file is not valid XML."
            case .notFileZillaFile:  return "This does not appear to be a FileZilla site manager file."
            }
        }
    }

    /// Parses a FileZilla `sitemanager.xml` (or exported sites file) and returns
    /// every `<Server>` entry it finds, including those nested inside `<Folder>`.
    static func parse(url: URL) throws -> [FileZillaSite] {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.fileUnreadable }
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw ImportError.malformedXML
        }

        guard let root = document.rootElement(), root.name == "FileZilla3" else {
            throw ImportError.notFileZillaFile
        }

        let serverNodes = (try? document.nodes(forXPath: "//Server")) ?? []
        return serverNodes.compactMap { node -> FileZillaSite? in
            guard let element = node as? XMLElement else { return nil }
            return parseServerElement(element)
        }
    }

    // MARK: - Per-element parsing

    private static func parseServerElement(_ element: XMLElement) -> FileZillaSite? {
        let name = childText(element, "Name") ?? "Untitled"
        let host = childText(element, "Host") ?? ""
        let portRaw = childText(element, "Port")
        let port = portRaw.flatMap { Int($0) }
        let username = childText(element, "User") ?? ""
        let protocolCode = Int(childText(element, "Protocol") ?? "") ?? 0
        let logonType = Int(childText(element, "Logontype") ?? "") ?? 1
        let remoteDirRaw = childText(element, "RemoteDir") ?? ""
        let remotePath = decodeRemoteDir(remoteDirRaw)

        let backendMapping = mapProtocol(protocolCode)

        guard let mapping = backendMapping else {
            return FileZillaSite(
                name: name,
                host: host,
                port: port,
                username: username,
                plainPassword: nil,
                remotePath: remotePath,
                suggestedBackend: .ftp,
                useFTPS: false,
                status: .unsupportedProtocol(name: protocolDisplayName(protocolCode))
            )
        }

        if host.isEmpty {
            return FileZillaSite(
                name: name,
                host: host,
                port: port,
                username: username,
                plainPassword: nil,
                remotePath: remotePath,
                suggestedBackend: mapping.backend,
                useFTPS: mapping.useFTPS,
                status: .invalid(reason: "Missing host")
            )
        }

        let (plainPassword, status) = resolvePassword(element: element, logonType: logonType)

        return FileZillaSite(
            name: name,
            host: host,
            port: port,
            username: username,
            plainPassword: plainPassword,
            remotePath: remotePath,
            suggestedBackend: mapping.backend,
            useFTPS: mapping.useFTPS,
            status: status
        )
    }

    private static func resolvePassword(element: XMLElement, logonType: Int) -> (String?, FileZillaImportStatus) {
        // Logontype: 0=Anonymous, 1=Normal, 2=Ask, 3=Interactive, 4=Account, 5=Key file (SFTP)
        switch logonType {
        case 0, 5:
            return (nil, .importable) // anonymous or key-based — no password needed
        case 2, 3:
            return (nil, .passwordRequired)
        default:
            break
        }

        guard let passElement = childElement(element, "Pass") else {
            // Logontype says credentials should exist but no <Pass> element — treat as needing user input.
            return (nil, .passwordRequired)
        }
        let encoding = passElement.attribute(forName: "encoding")?.stringValue
        let raw = passElement.stringValue ?? ""

        switch encoding {
        case "base64":
            if let data = Data(base64Encoded: raw),
               let decoded = String(data: data, encoding: .utf8) {
                return (decoded, .importable)
            }
            return (nil, .passwordRequired)
        case "crypt":
            // Public-key encrypted (FileZilla 3.26+ default before master-password feature). We can't
            // decrypt it, but the metadata is still useful — surface as encrypted.
            return (nil, .passwordEncrypted)
        case nil, "":
            // No encoding attribute — older versions stored plaintext directly.
            return (raw.isEmpty ? nil : raw, .importable)
        default:
            // "aes256" or anything else we don't handle.
            return (nil, .passwordEncrypted)
        }
    }

    // MARK: - Protocol mapping

    private struct BackendMapping {
        let backend: UploadBackendType
        let useFTPS: Bool
    }

    /// FileZilla protocol code → app backend, or nil if unsupported.
    /// 0=FTP, 1=SFTP, 3=FTPS (implicit), 4=FTPES (explicit). Everything else is unsupported.
    private static func mapProtocol(_ code: Int) -> BackendMapping? {
        switch code {
        case 0: return BackendMapping(backend: .ftp, useFTPS: false)
        case 1: return BackendMapping(backend: .sftp, useFTPS: false)
        case 3, 4: return BackendMapping(backend: .ftp, useFTPS: true)
        default: return nil
        }
    }

    private static func protocolDisplayName(_ code: Int) -> String {
        // Names sourced from FileZilla's ServerProtocol enum. Keeps the import sheet informative
        // when we have to skip something.
        switch code {
        case 0: return "FTP"
        case 1: return "SFTP"
        case 3: return "FTPS"
        case 4: return "FTPES"
        case 6: return "Storj"
        case 7: return "Storj Grant"
        case 8: return "OneDrive"
        case 9: return "WebDAV (HTTP)"
        case 10: return "WebDAV (HTTPS)"
        case 11: return "Azure Blob"
        case 12: return "Swift"
        case 13: return "Google Cloud"
        case 14: return "AWS S3"
        case 15: return "Backblaze B2"
        case 16: return "Box"
        case 17: return "Dropbox"
        case 18: return "Google Drive"
        case 19: return "OpenStack Swift"
        case 20: return "Rackspace"
        default: return "Unknown (code \(code))"
        }
    }

    // MARK: - RemoteDir decoding

    /// FileZilla serialises remote paths as `"<server-type> <prefix> <len1> <seg1> <len2> <seg2> …"`
    /// for path-style servers, or just stores a plain path for some older versions. This best-effort
    /// decoder handles both — anything we can't make sense of becomes "/" so the user can fix it.
    static func decodeRemoteDir(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "/" }
        if trimmed.hasPrefix("/") { return trimmed }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Need at least <type> <prefix> <len> <seg>
        guard tokens.count >= 4,
              Int(tokens[0]) != nil,
              Int(tokens[1]) != nil else {
            return "/"
        }

        var segments: [String] = []
        var index = 2
        while index < tokens.count {
            guard let length = Int(tokens[index]) else { break }
            index += 1
            // Reassemble a segment of `length` UTF-8 bytes — segments may themselves contain spaces,
            // so we walk forward consuming tokens until the byte count matches.
            var consumed = ""
            while index < tokens.count && consumed.utf8.count < length {
                if !consumed.isEmpty { consumed += " " }
                consumed += tokens[index]
                index += 1
            }
            segments.append(consumed)
        }

        if segments.isEmpty { return "/" }
        return "/" + segments.joined(separator: "/")
    }

    // MARK: - XML helpers

    private static func childText(_ element: XMLElement, _ name: String) -> String? {
        guard let child = childElement(element, name) else { return nil }
        return child.stringValue
    }

    private static func childElement(_ element: XMLElement, _ name: String) -> XMLElement? {
        for child in element.children ?? [] {
            if let e = child as? XMLElement, e.name == name { return e }
        }
        return nil
    }
}

// MARK: - UploadProfile bridge

extension UploadProfile {
    /// Builds a profile from a FileZilla site. Caller is responsible for saving the password
    /// to the Keychain separately (only available when site.status == .importable).
    static func from(fileZillaSite site: FileZillaSite) -> UploadProfile {
        var profile = UploadProfile.new(backend: site.suggestedBackend)
        profile.name = site.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported FileZilla Site"
            : site.name
        profile.server = site.host
        if let port = site.port, port > 0 {
            profile.port = port
        }
        profile.username = site.username
        profile.remotePath = site.remotePath.isEmpty ? "/" : site.remotePath
        profile.useFTPS = site.useFTPS
        return profile
    }
}
