// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Generates IMF (Interoperable Master Package) manifests — CPL (ST 2067-3),
/// PKL (ST 2067-2), and ASSETMAP (ST 2067-8) — alongside the encoded video and
/// audio essence MXFs to assemble a single-segment, single-essence-pair IMP.
///
/// The structure produced here is intentionally minimal: one Reel containing a
/// MainImageSequence and a MainAudioSequence, each with a single TrackFileResource.
/// This is the smallest CPL the existing `IMFPackageParser` can round-trip.
actor IMFManifestWriter {
    static let shared = IMFManifestWriter()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "IMFManifestWriter")

    private init() {}

    // MARK: - Public API

    /// Assembles an IMF Master Package directory from already-encoded video and audio MXF files.
    /// - Parameters:
    ///   - videoMXFURL: Encoded video essence (J2K or ProRes) wrapped to OP1a MXF.
    ///   - audioMXFURL: Encoded audio essence (PCM) wrapped to OP1a MXF, or nil if source has no audio.
    ///   - outputDirectoryURL: Empty package directory the manifests and renamed essences will be written into.
    ///   - title: ContentTitleText displayed by IMF players.
    ///   - application: Selects App #2e or App #5 — only affects annotation text and metadata, not file structure.
    ///   - editRateNumerator/editRateDenominator: Edit rate for the composition (e.g. 24/1, 30000/1001).
    ///   - frameCount: Total intrinsic duration in edit-rate units.
    ///   - itemMetadata: Per-item user metadata (ContentKind, AnnotationText, AudioLanguage).
    ///   - progress: Progress callback (0.0 → 1.0).
    /// - Returns: true on success.
    func assembleIMP(
        videoMXFURL: URL,
        audioMXFURL: URL?,
        outputDirectoryURL: URL,
        title: String,
        application: IMFApplication,
        editRateNumerator: Int,
        editRateDenominator: Int,
        frameCount: Int,
        itemMetadata: IMFItemMetadata? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> Bool {
        logger.info("Assembling IMP: \(title) (\(application.displayName), \(frameCount) frames @ \(editRateNumerator)/\(editRateDenominator))")

        // Generate all asset UUIDs upfront so cross-references are stable.
        let cplUUID = SMPTEPackageUtils.urnUUID()
        let pklUUID = SMPTEPackageUtils.urnUUID()
        let assetMapUUID = SMPTEPackageUtils.urnUUID()
        let videoUUID = SMPTEPackageUtils.urnUUID()
        let audioUUID = audioMXFURL != nil ? SMPTEPackageUtils.urnUUID() : nil
        let videoResourceUUID = SMPTEPackageUtils.urnUUID()
        let audioResourceUUID = audioMXFURL != nil ? SMPTEPackageUtils.urnUUID() : nil
        let imageSequenceUUID = SMPTEPackageUtils.urnUUID()
        let audioSequenceUUID = audioMXFURL != nil ? SMPTEPackageUtils.urnUUID() : nil
        let segmentUUID = SMPTEPackageUtils.urnUUID()
        let reelUUID = SMPTEPackageUtils.urnUUID()

        // Move essences into the package with UUID-based names (typical IMF practice).
        let videoFileName = "video_\(SMPTEPackageUtils.uuidString(from: videoUUID)).mxf"
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
            let fileName = "audio_\(SMPTEPackageUtils.uuidString(from: aUUID)).mxf"
            audioFileName = fileName
            let destURL = outputDirectoryURL.appendingPathComponent(fileName)
            audioDestURL = destURL
            do {
                if audioMXF != destURL {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.moveItem(at: audioMXF, to: destURL)
                }
            } catch {
                logger.error("Failed to move audio MXF: \(error.localizedDescription)")
                return false
            }
        }
        progress(0.2)

        // Hash + size the essence files (PKL needs hashes, ASSETMAP needs sizes).
        guard let videoHash = SMPTEPackageUtils.computeSHA1(for: videoDestURL) else {
            logger.error("Failed to compute SHA-1 for video MXF")
            return false
        }
        let videoSize = SMPTEPackageUtils.fileSize(at: videoDestURL)
        progress(0.5)

        var audioHash: String? = nil
        var audioSize: Int64? = nil
        if let dest = audioDestURL {
            audioHash = SMPTEPackageUtils.computeSHA1(for: dest)
            audioSize = SMPTEPackageUtils.fileSize(at: dest)
        }
        progress(0.6)

        // CPL — must be written before PKL since PKL needs the CPL's own hash.
        let titleForXML = title.isEmpty ? outputDirectoryURL.lastPathComponent : title
        let annotationText = (itemMetadata?.annotationText.isEmpty == false ? itemMetadata!.annotationText : titleForXML)
        let contentKind = itemMetadata?.contentKind ?? .feature
        let audioLanguage = itemMetadata?.audioLanguage ?? "en"

        let cplFileName = "CPL_\(SMPTEPackageUtils.uuidString(from: cplUUID)).xml"
        let cplContent = generateCPL(
            cplUUID: cplUUID,
            title: titleForXML,
            annotationText: annotationText,
            contentKind: contentKind,
            editRateNumerator: editRateNumerator,
            editRateDenominator: editRateDenominator,
            frameCount: frameCount,
            segmentUUID: segmentUUID,
            reelUUID: reelUUID,
            imageSequenceUUID: imageSequenceUUID,
            videoResourceUUID: videoResourceUUID,
            videoTrackFileUUID: videoUUID,
            audioSequenceUUID: audioSequenceUUID,
            audioResourceUUID: audioResourceUUID,
            audioTrackFileUUID: audioUUID,
            audioLanguage: audioLanguage,
            applicationLabel: application.displayName
        )
        let cplURL = outputDirectoryURL.appendingPathComponent(cplFileName)
        do {
            try cplContent.write(to: cplURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write CPL: \(error.localizedDescription)")
            return false
        }
        guard let cplHashHex = SMPTEPackageUtils.computeSHA1(for: cplURL) else {
            logger.error("Failed to compute SHA-1 for CPL")
            return false
        }
        let cplSize = SMPTEPackageUtils.fileSize(at: cplURL)
        progress(0.8)

        // PKL.
        let pklFileName = "PKL_\(SMPTEPackageUtils.uuidString(from: pklUUID)).xml"
        let pklContent = generatePKL(
            pklUUID: pklUUID,
            annotationText: annotationText,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            cplHashHex: cplHashHex,
            cplSize: cplSize,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoHashHex: videoHash,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioHashHex: audioHash,
            audioSize: audioSize
        )
        let pklURL = outputDirectoryURL.appendingPathComponent(pklFileName)
        do {
            try pklContent.write(to: pklURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write PKL: \(error.localizedDescription)")
            return false
        }
        let pklSize = SMPTEPackageUtils.fileSize(at: pklURL)
        progress(0.9)

        // ASSETMAP.
        let assetMapContent = generateAssetMap(
            assetMapUUID: assetMapUUID,
            annotationText: annotationText,
            pklUUID: pklUUID,
            pklFileName: pklFileName,
            pklSize: pklSize,
            cplUUID: cplUUID,
            cplFileName: cplFileName,
            cplSize: cplSize,
            videoUUID: videoUUID,
            videoFileName: videoFileName,
            videoSize: videoSize,
            audioUUID: audioUUID,
            audioFileName: audioFileName,
            audioSize: audioSize
        )
        let assetMapURL = outputDirectoryURL.appendingPathComponent("ASSETMAP.xml")
        do {
            try assetMapContent.write(to: assetMapURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write ASSETMAP: \(error.localizedDescription)")
            return false
        }

        progress(1.0)
        logger.info("IMP assembly complete: \(outputDirectoryURL.lastPathComponent)")
        return true
    }

    // MARK: - Folder naming

    /// Generates a conventional IMF folder name. IMF doesn't have a single mandated naming
    /// scheme like ISDCF for DCP — the form below mirrors common deliveries.
    /// Format: `Title_App<n>_<ResTier>_<FPS>_<Lang>_<YYYYMMDD>`
    func packageFolderName(
        title: String,
        application: IMFApplication,
        resolution: IMFResolution,
        frameRate: IMFFrameRate,
        audioLanguage: String
    ) -> String {
        let sanitizedTitle = title
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" }
            .map { String($0) }.joined()
            .replacingOccurrences(of: " ", with: "-")
        let appTag: String
        switch application {
        case .app2e: appTag = "App2e"
        case .app5:  appTag = "App5"
        }
        let langCode = String(audioLanguage.prefix(3)).uppercased()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        let dateStr = dateFormatter.string(from: Date())
        let safeTitle = sanitizedTitle.isEmpty ? "IMF" : sanitizedTitle
        return "\(safeTitle)_\(appTag)_\(resolution.shortTier)_\(frameRate.folderTag)_\(langCode)_\(dateStr)"
    }

    // MARK: - CPL (ST 2067-3)

    private func generateCPL(
        cplUUID: String,
        title: String,
        annotationText: String,
        contentKind: IMFContentKind,
        editRateNumerator: Int,
        editRateDenominator: Int,
        frameCount: Int,
        segmentUUID: String,
        reelUUID: String,
        imageSequenceUUID: String,
        videoResourceUUID: String,
        videoTrackFileUUID: String,
        audioSequenceUUID: String?,
        audioResourceUUID: String?,
        audioTrackFileUUID: String?,
        audioLanguage: String,
        applicationLabel: String
    ) -> String {
        let editRate = "\(editRateNumerator) \(editRateDenominator)"
        let escapedTitle = SMPTEPackageUtils.xmlEscape(title)
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let escapedAppLabel = SMPTEPackageUtils.xmlEscape(applicationLabel)
        let escapedLang = SMPTEPackageUtils.xmlEscape(audioLanguage)
        let now = SMPTEPackageUtils.iso8601Now()
        let contentVersionUUID = SMPTEPackageUtils.urnUUID()

        var sequences = """
                  <SequenceList>
                    <cc:MainImageSequence xmlns:cc="http://www.smpte-ra.org/schemas/2067-2/2016">
                      <Id>\(imageSequenceUUID)</Id>
                      <TrackId>\(SMPTEPackageUtils.urnUUID())</TrackId>
                      <ResourceList>
                        <Resource xsi:type="TrackFileResourceType">
                          <Id>\(videoResourceUUID)</Id>
                          <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                          <EntryPoint>0</EntryPoint>
                          <SourceDuration>\(frameCount)</SourceDuration>
                          <RepeatCount>1</RepeatCount>
                          <TrackFileId>\(videoTrackFileUUID)</TrackFileId>
                          <SourceEncoding>\(SMPTEPackageUtils.urnUUID())</SourceEncoding>
                        </Resource>
                      </ResourceList>
                    </cc:MainImageSequence>
        """

        if let audioSeqUUID = audioSequenceUUID,
           let audioResUUID = audioResourceUUID,
           let audioTfUUID = audioTrackFileUUID {
            sequences += """

                    <cc:MainAudioSequence xmlns:cc="http://www.smpte-ra.org/schemas/2067-2/2016">
                      <Id>\(audioSeqUUID)</Id>
                      <TrackId>\(SMPTEPackageUtils.urnUUID())</TrackId>
                      <ResourceList>
                        <Resource xsi:type="TrackFileResourceType">
                          <Id>\(audioResUUID)</Id>
                          <IntrinsicDuration>\(frameCount)</IntrinsicDuration>
                          <EntryPoint>0</EntryPoint>
                          <SourceDuration>\(frameCount)</SourceDuration>
                          <RepeatCount>1</RepeatCount>
                          <TrackFileId>\(audioTfUUID)</TrackFileId>
                          <SourceEncoding>\(SMPTEPackageUtils.urnUUID())</SourceEncoding>
                        </Resource>
                      </ResourceList>
                    </cc:MainAudioSequence>
            """
        }

        sequences += """

                  </SequenceList>
        """

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <CompositionPlaylist xmlns="http://www.smpte-ra.org/schemas/2067-3/2016/CPL"
                             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                             xmlns:dcml="http://www.smpte-ra.org/schemas/433/2008/dcmlTypes/">
          <Id>\(cplUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter (\(escapedAppLabel))</Creator>
          <ContentTitle>\(escapedTitle)</ContentTitle>
          <ContentKind>\(contentKind.rawValue)</ContentKind>
          <ContentVersion>
            <Id>\(contentVersionUUID)</Id>
            <LabelText>\(escapedTitle)_v1</LabelText>
          </ContentVersion>
          <EssenceDescriptorList/>
          <CompositionTimecode>
            <TimecodeDropFrame>false</TimecodeDropFrame>
            <TimecodeRate>\(editRateNumerator)</TimecodeRate>
            <TimecodeStartAddress>00:00:00:00</TimecodeStartAddress>
          </CompositionTimecode>
          <EditRate>\(editRate)</EditRate>
          <LocaleList>
            <Locale>
              <LanguageList>
                <Language>\(escapedLang)</Language>
              </LanguageList>
            </Locale>
          </LocaleList>
          <SegmentList>
            <Segment>
              <Id>\(segmentUUID)</Id>
        \(sequences)
            </Segment>
          </SegmentList>
        </CompositionPlaylist>
        """
    }

    // MARK: - PKL (ST 2067-2)

    private func generatePKL(
        pklUUID: String,
        annotationText: String,
        cplUUID: String,
        cplFileName: String,
        cplHashHex: String,
        cplSize: Int64,
        videoUUID: String,
        videoFileName: String,
        videoHashHex: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioHashHex: String?,
        audioSize: Int64?
    ) -> String {
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let now = SMPTEPackageUtils.iso8601Now()

        var assets = """
            <Asset>
              <Id>\(cplUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: cplUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: cplHashHex))</Hash>
              <Size>\(cplSize)</Size>
              <Type>text/xml</Type>
              <OriginalFileName>\(cplFileName)</OriginalFileName>
            </Asset>
            <Asset>
              <Id>\(videoUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: videoUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: videoHashHex))</Hash>
              <Size>\(videoSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(videoFileName)</OriginalFileName>
            </Asset>
        """

        if let aUUID = audioUUID, let aFileName = audioFileName, let aHash = audioHashHex, let aSize = audioSize {
            assets += """

            <Asset>
              <Id>\(aUUID)</Id>
              <AnnotationText>\(SMPTEPackageUtils.uuidString(from: aUUID))</AnnotationText>
              <Hash>\(SMPTEPackageUtils.base64SHA1(hex: aHash))</Hash>
              <Size>\(aSize)</Size>
              <Type>application/mxf</Type>
              <OriginalFileName>\(aFileName)</OriginalFileName>
            </Asset>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <PackingList xmlns="http://www.smpte-ra.org/schemas/2067-2/2016/PKL">
          <Id>\(pklUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
          <IssueDate>\(now)</IssueDate>
          <Issuer>Aagedal Media Converter</Issuer>
          <Creator>Aagedal Media Converter</Creator>
          <AssetList>
        \(assets)
          </AssetList>
        </PackingList>
        """
    }

    // MARK: - ASSETMAP (ST 2067-8)

    private func generateAssetMap(
        assetMapUUID: String,
        annotationText: String,
        pklUUID: String,
        pklFileName: String,
        pklSize: Int64,
        cplUUID: String,
        cplFileName: String,
        cplSize: Int64,
        videoUUID: String,
        videoFileName: String,
        videoSize: Int64,
        audioUUID: String?,
        audioFileName: String?,
        audioSize: Int64?
    ) -> String {
        let escapedAnnotation = SMPTEPackageUtils.xmlEscape(annotationText)
        let now = SMPTEPackageUtils.iso8601Now()

        var assets = """
            <Asset>
              <Id>\(pklUUID)</Id>
              <PackingList>true</PackingList>
              <ChunkList>
                <Chunk>
                  <Path>\(pklFileName)</Path>
                  <VolumeIndex>1</VolumeIndex>
                  <Offset>0</Offset>
                  <Length>\(pklSize)</Length>
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
                  <Length>\(cplSize)</Length>
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
        <AssetMap xmlns="http://www.smpte-ra.org/schemas/2067-8/2016/AM">
          <Id>\(assetMapUUID)</Id>
          <AnnotationText>\(escapedAnnotation)</AnnotationText>
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
}
