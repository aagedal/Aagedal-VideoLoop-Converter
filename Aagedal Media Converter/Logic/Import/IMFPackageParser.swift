// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// One essence (image, audio, data) referenced by an IMF Composition Playlist.
struct IMFEssenceReference: Sendable, Equatable {
    enum Kind: String, Sendable {
        case mainImage
        case mainAudio
        case subtitle
        case marker
        case data
    }

    /// Resolved on-disk URL of the MXF essence file.
    let mxfURL: URL
    /// Human-readable virtual-track name (e.g. "Main Audio 1") used as the queue row title.
    let virtualTrackName: String
    /// Coarse classification of the essence.
    let kind: Kind
}

/// Result of parsing an IMF package's `ASSETMAP.xml` + first CPL.
struct IMFPackageContents: Sendable, Equatable {
    /// Optional human-readable title from the CPL (e.g. `<ContentTitle>` or `<ContentTitleText>`).
    let contentTitle: String?
    /// Deduplicated list of essence references in CPL discovery order.
    let essences: [IMFEssenceReference]
}

/// Parser for IMF (SMPTE ST 2067) packages.
///
/// Reads `ASSETMAP.xml` (SMPTE ST 429-9 / ST 2067-8) to build a URN→URL map,
/// then parses the first SMPTE ST 2067-3 Composition Playlist found in the package
/// to enumerate the essences referenced by the composition.
enum IMFPackageParser {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "IMFPackageParser")

    enum ParseError: Error, LocalizedError {
        case assetMapMissing
        case assetMapUnparseable(String)
        case cplMissing
        case cplUnparseable(String)

        var errorDescription: String? {
            switch self {
            case .assetMapMissing: return "ASSETMAP.xml not found in package"
            case .assetMapUnparseable(let msg): return "Failed to parse ASSETMAP: \(msg)"
            case .cplMissing: return "No Composition Playlist (CPL) found in package"
            case .cplUnparseable(let msg): return "Failed to parse CPL: \(msg)"
            }
        }
    }

    // MARK: - Public API

    /// Returns true if the folder contains an `ASSETMAP.xml` (or extension-less `ASSETMAP`) at its root.
    static func looksLikeIMFPackage(folder: URL) -> Bool {
        assetMapURL(in: folder) != nil
    }

    /// Parses an IMF package folder and returns the deduplicated essence list referenced by the first CPL.
    static func parsePackage(folder: URL) throws -> IMFPackageContents {
        guard let assetMap = assetMapURL(in: folder) else {
            throw ParseError.assetMapMissing
        }
        let assets = try parseAssetMap(at: assetMap, packageFolder: folder)

        guard let cpl = findFirstCPL(in: folder, assetMap: assets) else {
            throw ParseError.cplMissing
        }
        let parsed = try parseCPL(at: cpl, assetMap: assets)
        logger.info("Parsed IMF package \(folder.lastPathComponent): \(parsed.essences.count) essence(s)")
        return parsed
    }

    // MARK: - AssetMap

    static func assetMapURL(in folder: URL) -> URL? {
        let candidates = ["ASSETMAP.xml", "ASSETMAP"]
        for name in candidates {
            let url = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// URN (`urn:uuid:...`) → on-disk URL of the asset file.
    static func parseAssetMap(at url: URL, packageFolder: URL) throws -> [String: URL] {
        guard let data = try? Data(contentsOf: url) else {
            throw ParseError.assetMapUnparseable("could not read \(url.lastPathComponent)")
        }
        let delegate = AssetMapDelegate(packageFolder: packageFolder)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        if !parser.parse(), let err = parser.parserError {
            throw ParseError.assetMapUnparseable(err.localizedDescription)
        }
        return delegate.assets
    }

    // MARK: - CPL discovery

    /// Finds the first `*.xml` in the package whose root element is `CompositionPlaylist`
    /// and whose namespace identifies it as a SMPTE ST 2067 IMF CPL.
    /// Excludes the ASSETMAP and any PKL.
    static func findFirstCPL(in folder: URL, assetMap: [String: URL]) -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        let xmlFiles = entries.filter { $0.pathExtension.lowercased() == "xml" }
        for xml in xmlFiles {
            let name = xml.lastPathComponent.uppercased()
            if name == "ASSETMAP.XML" { continue }
            if name.hasPrefix("PKL_") || name.hasPrefix("PKL.") { continue }
            if isCPL(url: xml) { return xml }
        }
        return nil
    }

    private static func isCPL(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let delegate = RootElementSniffer()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        guard let root = delegate.rootElementLocalName else { return false }
        guard root == "CompositionPlaylist" else { return false }
        // Must be IMF (SMPTE 2067-3); reject DCP CPL (428-7).
        let ns = delegate.rootNamespace ?? ""
        return ns.contains("smpte-ra.org/schemas/2067")
    }

    // MARK: - CPL parsing

    static func parseCPL(at url: URL, assetMap: [String: URL]) throws -> IMFPackageContents {
        guard let data = try? Data(contentsOf: url) else {
            throw ParseError.cplUnparseable("could not read \(url.lastPathComponent)")
        }
        let delegate = CPLDelegate(assetMap: assetMap)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        if !parser.parse(), let err = parser.parserError {
            throw ParseError.cplUnparseable(err.localizedDescription)
        }
        return IMFPackageContents(contentTitle: delegate.contentTitle, essences: delegate.essences)
    }
}

// MARK: - AssetMap delegate

private final class AssetMapDelegate: NSObject, XMLParserDelegate {
    let packageFolder: URL
    var assets: [String: URL] = [:]

    private var elementStack: [String] = []
    private var textBuffer = ""
    private var currentAssetID: String?
    private var currentAssetPath: String?

    init(packageFolder: URL) {
        self.packageFolder = packageFolder
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        elementStack.append(localName(of: elementName))
        textBuffer = ""
        if elementStack.last == "Asset" {
            currentAssetID = nil
            currentAssetPath = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(of: elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "Id":
            // <Id> appears at the AssetMap root and inside each Asset; we want the one inside Asset.
            if elementStack.contains("Asset"), currentAssetID == nil {
                currentAssetID = normalizeURN(value)
            }
        case "Path":
            // First Chunk's Path wins (most IMF essences are single-chunk; multi-chunk is rare).
            if currentAssetPath == nil { currentAssetPath = value }
        case "Asset":
            if let id = currentAssetID, let path = currentAssetPath {
                let resolved = resolveRelativePath(path)
                assets[id] = resolved
            }
            currentAssetID = nil
            currentAssetPath = nil
        default:
            break
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        textBuffer = ""
    }

    private func resolveRelativePath(_ path: String) -> URL {
        // Path may be percent-encoded per ST 429-9.
        let decoded = path.removingPercentEncoding ?? path
        return packageFolder.appendingPathComponent(decoded)
    }
}

// MARK: - CPL delegate

private final class CPLDelegate: NSObject, XMLParserDelegate {
    let assetMap: [String: URL]
    var contentTitle: String?
    var essences: [IMFEssenceReference] = []

    private var elementStack: [String] = []
    private var textBuffer = ""

    /// Tracks the current sequence type so each <TrackFileId> we see can be classified.
    private var currentSequenceLocalName: String?
    /// Per-sequence-type counters so we can name "Main Audio 1", "Main Audio 2", …
    private var sequenceCounters: [String: Int] = [:]
    private var currentSequenceLabel: String?
    /// Already-seen TrackFileIds so the same essence isn't added twice if referenced by
    /// multiple resources (segmented compositions).
    private var seenTrackFileIDs: Set<String> = []

    init(assetMap: [String: URL]) {
        self.assetMap = assetMap
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let local = localName(of: elementName)
        elementStack.append(local)
        textBuffer = ""

        if local.hasSuffix("Sequence"), local != "Sequence" {
            currentSequenceLocalName = local
            let bumped = (sequenceCounters[local] ?? 0) + 1
            sequenceCounters[local] = bumped
            currentSequenceLabel = friendlySequenceName(local, occurrence: bumped)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(of: elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "ContentTitle", "ContentTitleText":
            if contentTitle == nil, !value.isEmpty { contentTitle = value }
        case "TrackFileId":
            if let sequenceLocal = currentSequenceLocalName, let label = currentSequenceLabel {
                let urn = normalizeURN(value)
                if !urn.isEmpty, !seenTrackFileIDs.contains(urn) {
                    if let resolved = assetMap[urn] {
                        seenTrackFileIDs.insert(urn)
                        essences.append(IMFEssenceReference(
                            mxfURL: resolved,
                            virtualTrackName: label,
                            kind: classify(sequenceLocal)
                        ))
                    }
                }
            }
        default:
            if local == currentSequenceLocalName {
                currentSequenceLocalName = nil
                currentSequenceLabel = nil
            }
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        textBuffer = ""
    }

    private func classify(_ sequenceLocalName: String) -> IMFEssenceReference.Kind {
        switch sequenceLocalName {
        case "MainImageSequence": return .mainImage
        case "MainAudioSequence",
             "IABSequence",
             "MGASoundfieldGroupSequence",
             "ImmersiveAudioSequence",
             "CommentarySequence":
            return .mainAudio
        case "SubtitlesSequence", "HearingImpairedCaptionsSequence", "VisuallyImpairedTextSequence":
            return .subtitle
        case "MarkerSequence":
            return .marker
        default:
            return .data
        }
    }

    /// Converts a CamelCase sequence element name into a spaced label, suffixing with the
    /// occurrence index when the same sequence type appears more than once.
    private func friendlySequenceName(_ elementName: String, occurrence: Int) -> String {
        // "MainAudioSequence" → "Main Audio"
        let trimmed: String
        if elementName.hasSuffix("Sequence") {
            trimmed = String(elementName.dropLast("Sequence".count))
        } else {
            trimmed = elementName
        }
        var spaced = ""
        for (i, ch) in trimmed.enumerated() {
            if i > 0, ch.isUppercase { spaced.append(" ") }
            spaced.append(ch)
        }
        if occurrence > 1 { spaced.append(" \(occurrence)") }
        return spaced
    }
}

// MARK: - Root element sniffer

private final class RootElementSniffer: NSObject, XMLParserDelegate {
    var rootElementLocalName: String?
    var rootNamespace: String?
    private var foundRoot = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard !foundRoot else { return }
        foundRoot = true
        rootElementLocalName = localName(of: elementName)
        // shouldProcessNamespaces is false, so namespaceURI isn't populated; pull from xmlns attribute.
        rootNamespace = attributeDict["xmlns"]
        parser.abortParsing()
    }
}

// MARK: - Helpers

private func localName(of elementName: String) -> String {
    if let colon = elementName.firstIndex(of: ":") {
        return String(elementName[elementName.index(after: colon)...])
    }
    return elementName
}

private func normalizeURN(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
