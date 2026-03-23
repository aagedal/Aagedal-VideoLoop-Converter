// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import CryptoKit

/// Service for assembling DCP (Digital Cinema Package) directories
/// Generates Interop DCP XML metadata (CPL, PKL, ASSETMAP, VOLINDEX)
actor DCPService {
    static let shared = DCPService()

    private let logger = Logger(subsystem: "com.aagedal.media-converter", category: "DCPService")

    private init() {}

    // MARK: - Public API

    /// Assembles a DCP directory from video and audio MXF files
    /// - Parameters:
    ///   - videoMXFURL: The JPEG 2000 video MXF file
    ///   - audioMXFURL: The PCM audio MXF file (nil if source has no audio)
    ///   - outputDirectoryURL: The DCP output directory
    ///   - title: The DCP title (used in CPL)
    ///   - resolution: DCP resolution setting
    ///   - frameRate: DCP frame rate setting
    ///   - frameCount: Total number of video frames
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful
    func assembleDCP(
        videoMXFURL: URL,
        audioMXFURL: URL?,
        outputDirectoryURL: URL,
        title: String,
        resolution: DCPResolution,
        frameRate: DCPFrameRate,
        frameCount: Int,
        itemMetadata: DCPItemMetadata? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        logger.info("Assembling DCP: \(title) (\(resolution.shortLabel), \(frameRate.rawValue), \(frameCount) frames)")

        // Generate UUIDs for all assets
        let cplUUID = dcpUUID()
        let pklUUID = dcpUUID()
        let assetMapUUID = dcpUUID()
        let videoUUID = dcpUUID()
        let audioUUID = audioMXFURL != nil ? dcpUUID() : nil

        // Rename MXF files with DCP-standard names (j2c_ for JPEG 2000, pcm_ for PCM audio)
        let videoFileName = "j2c_\(uuidString(from: videoUUID)).mxf"
        let videoDestURL = outputDirectoryURL.appendingPathComponent(videoFileName)

        do {
            if videoMXFURL != videoDestURL {
                if FileManager.default.fileExists(atPath: videoDestURL.path) {
                    try FileManager.default.removeItem(at: videoDestURL)
                }
                try FileManager.default.moveItem(at: videoMXFURL, to: videoDestURL)
            }
        } catch {
            logger.error("Failed to move video MXF: \(error.localizedDescription)")
            return false
        }

        progress(0.1)

        var audioFileName: String? = nil
        var audioDestURL: URL? = nil
        if let audioMXF = audioMXFURL, let aUUID = audioUUID {
            audioFileName = "pcm_\(uuidString(from: aUUID)).mxf"
            audioDestURL = outputDirectoryURL.appendingPathComponent(audioFileName!)

            do {
                if audioMXF != audioDestURL! {
                    if FileManager.default.fileExists(atPath: audioDestURL!.path) {
                        try FileManager.default.removeItem(at: audioDestURL!)
                    }
                    try FileManager.default.moveItem(at: audioMXF, to: audioDestURL!)
                }
            } catch {
                logger.error("Failed to move audio MXF: \(error.localizedDescription)")
                return false
            }
        }

        progress(0.2)

        // Compute SHA-1 hashes
        logger.info("Computing SHA-1 hashes...")
        guard let videoHash = computeSHA1(for: videoDestURL) else {
            logger.error("Failed to compute SHA-1 for video MXF")
            return false
        }
        let videoSize = fileSize(at: videoDestURL)

        progress(0.5)

        var audioHash: String? = nil
        var audioSize: Int64? = nil
        if let aDestURL = audioDestURL {
            audioHash = computeSHA1(for: aDestURL)
            audioSize = fileSize(at: aDestURL)
        }

        progress(0.6)

        // Generate XML files
        let editRate = "\(frameRate.editRateNumerator) \(frameRate.editRateDenominator)"

        // CPL
        let cplFileName = "cpl_\(uuidString(from: cplUUID)).xml"
        let contentKind = itemMetadata?.contentKind ?? .feature
        let annotationText = itemMetadata?.annotationText ?? ""
        let ratingLabel = itemMetadata?.ratingLabel ?? ""
        let audioLanguage = itemMetadata?.audioLanguage ?? "en"

        let cplContent = generateCPL(
            cplUUID: cplUUID,
            title: title,
            editRate: editRate,
            frameCount: frameCount,
            videoUUID: videoUUID,
            audioUUID: audioUUID,
            resolution: resolution,
            contentKind: contentKind,
            annotationText: annotationText,
            ratingLabel: ratingLabel,
            audioLanguage: audioLanguage,
            videoHash: base64SHA1(hex: videoHash),
            audioHash: audioHash != nil ? base64SHA1(hex: audioHash!) : nil
        )

        do {
            let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
            try cplContent.write(to: cplURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write CPL: \(error.localizedDescription)")
            return false
        }

        progress(0.7)

        // Compute CPL hash
        let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
        guard let cplHash = computeSHA1(for: cplURL) else {
            logger.error("Failed to compute SHA-1 for CPL")
            return false
        }
        let cplSize = fileSize(at: cplURL)

        // PKL
        let pklFileName = "pkl_\(uuidString(from: pklUUID)).xml"
        let pklContent = generatePKL(
            pklUUID: pklUUID,
            title: title,
            cplUUID: cplUUID,
            cplHash: cplHash,
            cplSize: cplSize,
            cplFileName: cplFileName,
            videoUUID: videoUUID,
            videoHash: videoHash,
            videoSize: videoSize,
            videoFileName: videoFileName,
            audioUUID: audioUUID,
            audioHash: audioHash,
            audioSize: audioSize,
            audioFileName: audioFileName
        )

        do {
            let pklURL = outputDirectoryURL.appendingPathComponent(pklFileName)
            try pklContent.write(to: pklURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write PKL: \(error.localizedDescription)")
            return false
        }

        progress(0.8)

        // VOLINDEX
        let volIndexContent = generateVolumeIndex()
        do {
            let volURL = outputDirectoryURL.appendingPathComponent("VOLINDEX.xml")
            try volIndexContent.write(to: volURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write VOLINDEX: \(error.localizedDescription)")
            return false
        }

        // ASSETMAP
        let assetMapContent = generateAssetMap(
            assetMapUUID: assetMapUUID,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            pklUUID: pklUUID,
            pklFileName: pklFileName,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioSize: audioSize
        )

        do {
            let assetMapURL = outputDirectoryURL.appendingPathComponent("ASSETMAP")
            try assetMapContent.write(to: assetMapURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write ASSETMAP: \(error.localizedDescription)")
            return false
        }

        progress(1.0)
        logger.info("DCP assembly complete: \(outputDirectoryURL.lastPathComponent)")
        return true
    }

    // MARK: - UUID Helpers

    private func dcpUUID() -> String {
        "urn:uuid:\(UUID().uuidString.lowercased())"
    }

    private func uuidString(from urn: String) -> String {
        urn.replacingOccurrences(of: "urn:uuid:", with: "")
    }

    // MARK: - Hash and Size

    private func computeSHA1(for url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { fileHandle.closeFile() }

        var hasher = Insecure.SHA1()
        let bufferSize = 1024 * 1024 // 1 MB chunks
        while autoreleasepool(invoking: {
            let data = fileHandle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    // MARK: - XML Generation (Interop DCP)

    private func generateCPL(
        cplUUID: String,
        title: String,
        editRate: String,
        frameCount: Int,
        videoUUID: String,
        audioUUID: String?,
        resolution: DCPResolution,
        contentKind: DCPContentKind = .feature,
        annotationText: String = "",
        ratingLabel: String = "",
        audioLanguage: String = "en",
        videoHash: String? = nil,
        audioHash: String? = nil
    ) -> String {
        let escapedTitle = xmlEscape(title)
        let escapedAnnotation = xmlEscape(annotationText)
        let now = iso8601Now()
        let contentVersionUUID = dcpUUID()

        // Markers (FFOC = first frame, LFOC = last frame)
        let markersUUID = dcpUUID()
        var reelAssets = """
              <MainMarkers>
                <Id>\(markersUUID)</Id>
                <EditRate>\(editRate)</EditRate>
                <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                <MarkerList>
                  <Marker>
                    <Label>FFOC</Label>
                    <Offset>1</Offset>
                  </Marker>
                  <Marker>
                    <Label>LFOC</Label>
                    <Offset>\(max(frameCount - 1, 1))</Offset>
                  </Marker>
                </MarkerList>
              </MainMarkers>
              <MainPicture>
                <Id>\(videoUUID)</Id>
                <EditRate>\(editRate)</EditRate>
                <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                <EntryPoint>0</EntryPoint>
                <Duration>\(frameCount)</Duration>
                <FrameRate>\(editRate)</FrameRate>
                <ScreenAspectRatio>\(resolution.width)/\(resolution.height)</ScreenAspectRatio>
        """
        if let vHash = videoHash {
            reelAssets += "\n                <Hash>\(vHash)</Hash>"
        }
        reelAssets += """

              </MainPicture>
        """

        if let aUUID = audioUUID {
            reelAssets += """
              <MainSound>
                <Id>\(aUUID)</Id>
                <EditRate>\(editRate)</EditRate>
                <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                <EntryPoint>0</EntryPoint>
                <Duration>\(frameCount)</Duration>
                <Language>\(xmlEscape(audioLanguage))</Language>
            """
            if let aHash = audioHash {
                reelAssets += "\n                <Hash>\(aHash)</Hash>"
            }
            reelAssets += """

              </MainSound>
            """
        }

        let ratingElement: String
        if !ratingLabel.isEmpty {
            ratingElement = """
              <RatingList>
                <Rating>
                  <Agency>http://www.mpaa.org/2003-ratings</Agency>
                  <Label>\(xmlEscape(ratingLabel))</Label>
                </Rating>
              </RatingList>
            """
        } else {
            ratingElement = "  <RatingList/>"
        }

        var optionalElements = ""
        if !escapedAnnotation.isEmpty {
            optionalElements += "\n          <AnnotationText>\(escapedAnnotation)</AnnotationText>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <CompositionPlaylist xmlns="http://www.digicine.com/PROTO-ASDCP-CPL-20040511#">
          <Id>\(cplUUID)</Id>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <ContentTitleText>\(escapedTitle)</ContentTitleText>
          <ContentKind>\(contentKind.rawValue)</ContentKind>
          <ContentVersion>
            <Id>\(contentVersionUUID)</Id>
            <LabelText>\(escapedTitle)_v1</LabelText>
          </ContentVersion>\(optionalElements)
          \(ratingElement)
          <ReelList>
            <Reel>
              <Id>\(dcpUUID())</Id>
              <AssetList>
        \(reelAssets)
              </AssetList>
            </Reel>
          </ReelList>
        </CompositionPlaylist>
        """
    }

    private func generatePKL(
        pklUUID: String,
        title: String,
        cplUUID: String,
        cplHash: String,
        cplSize: Int64,
        cplFileName: String,
        videoUUID: String,
        videoHash: String,
        videoSize: Int64,
        videoFileName: String,
        audioUUID: String?,
        audioHash: String?,
        audioSize: Int64?,
        audioFileName: String?
    ) -> String {
        let escapedTitle = xmlEscape(title)
        let now = iso8601Now()

        var assetList = """
            <Asset>
              <Id>\(cplUUID)</Id>
              <Hash>\(base64SHA1(hex: cplHash))</Hash>
              <Size>\(cplSize)</Size>
              <Type>text/xml</Type>
              <OriginalFileName>\(cplFileName)</OriginalFileName>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <Hash>\(base64SHA1(hex: videoHash))</Hash>
              <Size>\(videoSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(videoFileName)</OriginalFileName>
            </Asset>
        """

        if let aUUID = audioUUID, let aHash = audioHash, let aSize = audioSize, let aFileName = audioFileName {
            assetList += """

            <Asset>
              <Id>\(aUUID)</Id>
              <Hash>\(base64SHA1(hex: aHash))</Hash>
              <Size>\(aSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(aFileName)</OriginalFileName>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <PackingList xmlns="http://www.digicine.com/PROTO-ASDCP-PKL-20040311#">
          <Id>\(pklUUID)</Id>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <AnnotationText>\(escapedTitle)</AnnotationText>
          <AssetList>
        \(assetList)
          </AssetList>
        </PackingList>
        """
    }

    private func generateVolumeIndex() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <VolumeIndex xmlns="http://www.digicine.com/PROTO-ASDCP-VL-20040311#">
          <Index>1</Index>
        </VolumeIndex>
        """
    }

    private func generateAssetMap(
        assetMapUUID: String,
        cplUUID: String,
        cplFileName: String,
        pklUUID: String,
        pklFileName: String,
        videoUUID: String,
        videoFileName: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioSize: Int64?
    ) -> String {
        let now = iso8601Now()

        var assets = """
            <Asset>
              <Id>\(pklUUID)</Id>
              <PackingList>true</PackingList>
              <ChunkList>
                <Chunk>
                  <Path>\(pklFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                </Chunk>
              </ChunkList>
            </Asset>
            <Asset>
              <Id>\(cplUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(cplFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                </Chunk>
              </ChunkList>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(videoFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(videoSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
        """

        if let aUUID = audioUUID, let aFileName = audioFileName, let aSize = audioSize {
            assets += """

            <Asset>
              <Id>\(aUUID)</Id>
              <ChunkList>
                <Chunk>
                  <Path>\(aFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(aSize)</Length>
                </Chunk>
              </ChunkList>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <AssetMap xmlns="http://www.digicine.com/PROTO-ASDCP-AM-20040311#">
          <Id>\(assetMapUUID)</Id>
          <Creator>Aagedal Media Converter</Creator>
          <VolumeCount>1</VolumeCount>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <AssetList>
        \(assets)
          </AssetList>
        </AssetMap>
        """
    }

    // MARK: - Helpers

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    /// Convert hex SHA-1 hash to base64 (as required by DCP PKL)
    private func base64SHA1(hex: String) -> String {
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
}
