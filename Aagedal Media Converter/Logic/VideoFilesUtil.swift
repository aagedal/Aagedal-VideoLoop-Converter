// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Cocoa
import OSLog

struct VideoFileUtils: Sendable {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoFileUtils")

    struct VideoItemDetails: Sendable {
        let size: Int64
        let duration: String
        let durationSeconds: Double
        let thumbnailData: Data?
        let outputURL: URL?
        let hasVideoStream: Bool
    }

    static func isVideoFile(url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return AppConstants.supportedVideoExtensions.contains(fileExtension)
    }

    static func createVideoItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop, comment: String = "") async -> VideoItem? {
        guard var placeholder = makePlaceholderItem(from: url, outputFolder: outputFolder, preset: preset, comment: comment) else {
            return nil
        }

        let details = await loadDetails(for: url, outputFolder: outputFolder, preset: preset)
        placeholder.apply(details: details)
        placeholder.detailsLoaded = true
        print(" [createVideoItem] VideoItem created successfully: \(placeholder.name)")
        return placeholder
    }

    static func makePlaceholderItem(from url: URL, outputFolder: String? = nil, preset: ExportPreset = .videoLoop, comment: String = "") -> VideoItem? {
        guard isVideoFile(url: url) else { return nil }

        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let includeDateTagByDefault = UserDefaults.standard.bool(forKey: AppConstants.includeDateTagPreferenceKey)

        let waveformEnabledDefault = UserDefaults.standard.bool(forKey: AppConstants.audioWaveformVideoDefaultEnabledKey)

        // Initialize timecode config based on user defaults
        let defaultTimecodeConfig = getDefaultTimecodeConfig()

        let placeholder = VideoItem(
            url: url,
            name: name,
            size: size,
            duration: "--:--",
            durationSeconds: 0.0,
            thumbnailData: nil,
            status: .waiting,
            progress: 0.0,
            eta: nil,
            outputURL: makeOutputURL(for: url, outputFolder: outputFolder, preset: preset),
            comment: comment,
            includeDateTag: includeDateTagByDefault,
            metadata: nil,
            detailsLoaded: false,
            waveformVideoEnabled: waveformEnabledDefault,
            timecodeConfig: defaultTimecodeConfig
        )

        return placeholder
    }

    /// Get the default timecode configuration from user preferences
    static func getDefaultTimecodeConfig() -> TimecodeConfig? {
        let defaultModeRaw = UserDefaults.standard.string(forKey: AppConstants.defaultTimecodeModeKey) ?? AppConstants.defaultTimecodeModeRaw
        let defaultValue = UserDefaults.standard.string(forKey: AppConstants.defaultTimecodeValueKey) ?? AppConstants.defaultTimecodeValue

        switch defaultModeRaw {
        case "preserveSource":
            return TimecodeConfig(mode: .preserveSource)
        case "manual":
            return TimecodeConfig(mode: .manual(defaultValue))
        default: // "disabled"
            return nil
        }
    }

    static func loadDetails(
        for url: URL,
        outputFolder: String? = nil,
        preset: ExportPreset = .videoLoop,
        generateRowThumbnailIfMissing: Bool = true
    ) async -> VideoItemDetails {
        let fileName = url.lastPathComponent

        // Skip if file doesn't exist (e.g., scheduled downloads)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return VideoItemDetails(
                size: 0,
                duration: "",
                durationSeconds: 0,
                thumbnailData: nil,
                outputURL: nil,
                hasVideoStream: false
            )
        }

        // Compute size (cheap, but ensures we have up-to-date info)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        var durationSec: Double = 0.0
        let asset = AVURLAsset(url: url)

        if BinaryPathResolver.ffprobePath != nil {
            logger.info("Attempting to get duration using FFprobe for: \(fileName, privacy: .public)")
            durationSec = await FFMPEGConverter.getVideoDuration(url: url) ?? 0.0

            if durationSec > 0 {
                logger.debug("FFprobe duration: \(durationSec, privacy: .public)s for \(fileName, privacy: .public)")
            } else {
                logger.debug("FFprobe returned 0 duration for \(fileName, privacy: .public); falling back to AVFoundation")
            }
        }

        if durationSec <= 0 {
            let cmDuration = try? await asset.load(.duration)
            durationSec = CMTimeGetSeconds(cmDuration ?? CMTime.zero)
        }

        let durationString = formatDuration(seconds: durationSec)

        // Use VideoMetadataService's fast hasVideoStream check which uses -read_intervals
        // This is fast even for very large files (50+ GB) and results are cached
        let hasVideoStream = await VideoMetadataService.shared.hasVideoStream(for: url)

        let thumbnailData = await getCachedThumbnail(url: url, generateRowThumbnailIfMissing: generateRowThumbnailIfMissing)

        let outputURL = makeOutputURL(for: url, outputFolder: outputFolder, preset: preset)

        return VideoItemDetails(
            size: size,
            duration: durationString,
            durationSeconds: durationSec,
            thumbnailData: thumbnailData,
            outputURL: outputURL,
            hasVideoStream: hasVideoStream
        )
    }

    /// Schedules generation of heavy preview assets (filmstrip thumbnails, waveform)
    /// after the lightweight metadata and row thumbnail are complete.
    static func prefetchPreviewAssets(for url: URL) {
        // Skip if file doesn't exist (e.g., scheduled downloads)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print(" [prefetchPreviewAssets] ⏭️ Skipping - file doesn't exist: \(url.lastPathComponent)")
            return
        }

        Task.detached(priority: .background) {
            let fileName = url.lastPathComponent
            do {
                let generator = PreviewAssetGenerator.shared
                let assets = try await generator.generateAssets(for: url)
                print(" [prefetchPreviewAssets] ✅ Cached filmstrip/waveform for \(fileName) (\(assets.thumbnails.count) thumbnails, waveform: \(assets.waveform != nil))")
            } catch {
                print(" [prefetchPreviewAssets] ⚠️ Failed to generate preview assets for \(fileName): \(error.localizedDescription)")
            }
        }
    }

    static func loadDetailsAsync(
        for url: URL,
        outputFolder: String? = nil,
        preset: ExportPreset = .videoLoop,
        completion: @MainActor @escaping (VideoItemDetails) -> Void
    ) {
        Task.detached(priority: .utility) {
            let details = await loadDetails(for: url, outputFolder: outputFolder, preset: preset)
            await completion(details)
        }
    }

    private static func makeOutputURL(for url: URL, outputFolder: String?, preset: ExportPreset) -> URL? {
        let resolvedOutputFolder = resolveOutputFolder(for: url, defaultOutputFolder: outputFolder, preset: preset)
        guard let resolvedOutputFolder else { return nil }
        let sanitizedBaseName = FileNameProcessor.processFileName(url.deletingPathExtension().lastPathComponent)
        let resolvedExtension = preset.outputExtension(for: url)
        let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""

        // Use FileSafetyUtils to prevent overwriting the input file
        let outputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        return FileSafetyUtils.safeOutputURL(
            inputURL: url,
            outputFolder: outputFolderURL,
            baseName: sanitizedBaseName,
            suffix: suffixPart,
            fileExtension: resolvedExtension
        )
    }

    /// Resolves the output folder based on user preferences.
    /// If "save next to original" is enabled, returns the source file's directory (with optional subfolder).
    /// Otherwise, returns the default output folder.
    static func resolveOutputFolder(for sourceURL: URL, defaultOutputFolder: String?, preset: ExportPreset) -> String? {
        let saveNextToOriginal = UserDefaults.standard.bool(forKey: AppConstants.saveNextToOriginalKey)

        if saveNextToOriginal {
            var outputDirectory = sourceURL.deletingLastPathComponent()

            let useSubfolder = UserDefaults.standard.bool(forKey: AppConstants.saveNextToOriginalSubfolderKey)
            if useSubfolder {
                let subfolderMode = UserDefaults.standard.string(forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
                    ?? AppConstants.defaultSaveNextToOriginalSubfolderMode

                let subfolderName: String
                if subfolderMode == "presetSuffix" {
                    // Use the preset's file suffix without the leading underscore
                    subfolderName = String(preset.fileSuffix.dropFirst(preset.fileSuffix.hasPrefix("_") ? 1 : 0))
                } else {
                    // Use custom folder name
                    subfolderName = UserDefaults.standard.string(forKey: AppConstants.saveNextToOriginalSubfolderNameKey)
                        ?? AppConstants.defaultSaveNextToOriginalSubfolderName
                }

                if !subfolderName.isEmpty {
                    outputDirectory = outputDirectory.appendingPathComponent(subfolderName)
                }
            }

            return outputDirectory.path
        } else {
            return defaultOutputFolder
        }
    }
    
    /// Fetches metadata for a video item in the background
    /// This allows the UI to be responsive while heavy operations complete
    static func fetchMetadata(for url: URL) async -> VideoMetadata? {
        let fileName = url.lastPathComponent

        // Skip if file doesn't exist (e.g., scheduled downloads)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        struct MetadataTimeout: Error {}

        // Fetch metadata with timeout (VideoMetadataService also enforces an internal timeout)
        let metadata: VideoMetadata?
        do {
            metadata = try await withThrowingTaskGroup(of: VideoMetadata?.self) { group in
                group.addTask {
                    let result = try await VideoMetadataService.shared.metadata(for: url)
                    return result
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    throw MetadataTimeout()
                }
                
                let result = try await group.next()
                group.cancelAll()
                return result ?? nil
            }
        } catch is MetadataTimeout {
            logger.warning("Metadata fetch timed out for \(fileName, privacy: .public)")
            metadata = nil
        } catch {
            logger.warning("Failed to fetch metadata for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            metadata = nil
        }
        
        return metadata
    }
    /// Fetches C2PA (Content Authenticity) metadata for a video item
    /// This is done lazily when the user opens the metadata view
    static func fetchC2PAMetadata(for url: URL) async -> C2PAMetadata? {
        let fileName = url.lastPathComponent

        // Skip if file doesn't exist
        guard FileManager.default.fileExists(atPath: url.path) else {
            print(" [fetchC2PAMetadata] ⏭️ Skipping - file doesn't exist: \(fileName)")
            return nil
        }

        // Check if ExifTool is available
        guard ExifToolService.shared.isAvailable else {
            print(" [fetchC2PAMetadata] ⏭️ ExifTool not available")
            return nil
        }

        print(" [fetchC2PAMetadata] ⏱️ Checking C2PA for: \(fileName)")

        do {
            let c2paMetadata = try await ExifToolService.shared.getC2PAMetadata(for: url)
            if c2paMetadata != nil {
                print(" [fetchC2PAMetadata] ✅ Found C2PA metadata for: \(fileName)")
            } else {
                print(" [fetchC2PAMetadata] ℹ️ No C2PA metadata found for: \(fileName)")
            }
            return c2paMetadata
        } catch {
            print(" [fetchC2PAMetadata] ❌ Error fetching C2PA: \(error.localizedDescription)")
            return nil
        }
    }

    /// Utility to format seconds into hh:mm:ss or mm:ss
    static func formatDuration(seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    @available(macOS 13.0, *)
    private static func getDurationFromAVFoundation(url: URL) async -> Double? {
        do {
            let asset = AVURLAsset(url: url)
            let cmDuration = try await asset.load(.duration)
            let duration = CMTimeGetSeconds(cmDuration)
            Logger().info("AVFoundation duration: \(duration) seconds for \(url.lastPathComponent)")
            return duration
        } catch {
            Logger().error("Error getting duration from AVFoundation: \(error.localizedDescription) for \(url.lastPathComponent)")
            return nil
        }
    }
    
    static func getVideoDuration(url: URL) async -> String {
        let fileName = url.lastPathComponent
        var duration: Double = 0.0
        
        if BinaryPathResolver.ffprobePath != nil {
            Logger().info("[getVideoDuration] Attempting FFprobe for: \(fileName)")
            let ffprobeDuration = await FFMPEGConverter.getVideoDuration(url: url)

            if let ffprobeDuration = ffprobeDuration, ffprobeDuration > 0 {
                duration = ffprobeDuration
                Logger().info("[getVideoDuration] FFprobe success: \(duration) seconds for \(fileName)")
            } else {
                Logger().warning("[getVideoDuration] FFprobe failed or returned 0, falling back to AVFoundation for \(fileName)")
                if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                    duration = durationFromAV
                }
            }
        } else {
            Logger().info("[getVideoDuration] FFprobe not found, using AVFoundation for \(fileName)")
            if let durationFromAV = await getDurationFromAVFoundation(url: url) {
                duration = durationFromAV
            }
        }
        
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    /// Gets cached thumbnail or generates row thumbnail if needed (fast, no waveform)
    static func getCachedThumbnail(url: URL, generateRowThumbnailIfMissing: Bool = true) async -> Data? {
        let fileName = url.lastPathComponent
        do {
            // Get the asset directory where thumbnails are cached
            let assetDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: url)
            
            // Try to load row thumbnail first (check both .png and legacy .jpg)
            let rowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.png")
            let legacyRowThumbnailURL = assetDirectory.appendingPathComponent("row_thumb.jpg")
            let rowURL = FileManager.default.fileExists(atPath: rowThumbnailURL.path) ? rowThumbnailURL :
                         (FileManager.default.fileExists(atPath: legacyRowThumbnailURL.path) ? legacyRowThumbnailURL : nil)

            if let rowURL = rowURL {
                do {
                    let thumbnailData = try Data(contentsOf: rowURL)
                    return thumbnailData
                } catch {
                    logger.debug("Failed to read row thumbnail for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }

            // If row thumbnail doesn't exist, generate it now (fast, just the thumbnail)
            if generateRowThumbnailIfMissing {
                if let thumbnailData = try? await PreviewAssetGenerator.shared.generateRowThumbnail(for: url) {
                    return thumbnailData
                }
            }

            // Fallback to first filmstrip thumbnail if row thumbnail generation failed (check both .png and legacy .jpg)
            let firstThumbnailURL = assetDirectory.appendingPathComponent("thumb_0.png")
            let legacyFirstThumbnailURL = assetDirectory.appendingPathComponent("thumb_0.jpg")
            let filmstripURL = FileManager.default.fileExists(atPath: firstThumbnailURL.path) ? firstThumbnailURL :
                               (FileManager.default.fileExists(atPath: legacyFirstThumbnailURL.path) ? legacyFirstThumbnailURL : nil)
            
            if let filmstripURL = filmstripURL {
                do {
                    let thumbnailData = try Data(contentsOf: filmstripURL)
                    return thumbnailData
                } catch {
                    logger.debug("Failed to read filmstrip thumbnail for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            
            return nil
        } catch {
            logger.debug("Error loading thumbnail for \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    static func getVideoThumbnail(url: URL) async -> Data? {
        // Use unified PreviewAssetGenerator for consistent thumbnail generation
        // with HDR support for ProRes RAW and high bit depth content
        do {
            let assets = try await PreviewAssetGenerator.shared.generateAssets(for: url)
            
            // Use row thumbnail if available
            if let rowThumbnailURL = assets.rowThumbnail,
               let thumbnailData = try? Data(contentsOf: rowThumbnailURL) {
                return thumbnailData
            }
            
            // Fallback to first filmstrip thumbnail if row thumbnail failed
            if let firstThumbnail = assets.thumbnails.first,
               let thumbnailData = try? Data(contentsOf: firstThumbnail) {
                return thumbnailData
            }
            
            return nil
        } catch {
            print("Error generating thumbnail via PreviewAssetGenerator for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func isNativelySupported(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else { return false }
            
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if tracks.isEmpty { return true }
            
            for track in tracks {
                let formats = try await track.load(.formatDescriptions) as [CMFormatDescription]
                for desc in formats {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    let codecBytes: [UInt8] = [
                        UInt8((codec >> 24) & 0xFF),
                        UInt8((codec >> 16) & 0xFF),
                        UInt8((codec >> 8) & 0xFF),
                        UInt8(codec & 0xFF)
                    ]
                    if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) {
                        if fourCC == "apv1" || fourCC == "apvx" { return false }
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }
    
    private static func isVLCSupported(_ url: URL) async -> Bool {
        // VLC supports most formats that AVPlayer doesn't, EXCEPT APV
        // Check if it's APV first (APV needs chunk fallback)
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            for track in tracks {
                let formats = try await track.load(.formatDescriptions) as [CMFormatDescription]
                for desc in formats {
                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                    let codecBytes: [UInt8] = [
                        UInt8((codec >> 24) & 0xFF),
                        UInt8((codec >> 16) & 0xFF),
                        UInt8((codec >> 8) & 0xFF),
                        UInt8(codec & 0xFF)
                    ]
                   if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) {
                        // APV is NOT supported by VLC
                        if fourCC == "apv1" || fourCC == "apvx" {
                            return false
                        }
                    }
                }
            }
        } catch {
            // If we can't inspect, assume VLC can handle it
            return true
        }
        
        // If it's not natively supported and not APV, VLC can likely play it
        let isNative = await isNativelySupported(url)
        return !isNative
    }
}

/// Configuration for timecode preservation or manual override
struct TimecodeConfig: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case preserveSource  // Copy timecode from source file
        case manual(String)  // Manually set timecode (HH:MM:SS:FF or HH:MM:SS;FF)
    }

    var mode: Mode = .preserveSource

    var isActive: Bool {
        switch mode {
        case .preserveSource:
            return true
        case .manual(let tc):
            return !tc.isEmpty
        }
    }
}

struct VideoItem: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    var url: URL
    var name: String
    var size: Int64
    var duration: String
    var durationSeconds: Double = 0.0
    var thumbnailData: Data?
    var status: ConversionManager.ConversionStatus
    var progress: Double
    var eta: String?
    var outputURL: URL?
    var comment: String = ""
    var includeDateTag: Bool = true
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var loopPlayback: Bool = false
    var metadata: VideoMetadata?
    var detailsLoaded: Bool = false
    var waveformVideoEnabled: Bool = false
    var hasVideoStream: Bool = true
    var audioRoutingConfig: AudioRoutingConfig? = nil
    var cropConfig: CropConfig? = nil
    var timecodeConfig: TimecodeConfig? = nil
    /// Stored output file size in bytes, set when conversion completes
    var outputFileSizeBytes: Int64? = nil
    /// C2PA (Content Authenticity) metadata if present
    var c2paMetadata: C2PAMetadata? = nil
    /// Whether audio should be muted (removed) in the output
    var isMuted: Bool = false

    // MARK: - yt-dlp Download State
    /// Whether this item is currently being downloaded via yt-dlp
    var isDownloading: Bool = false
    /// Download progress (0.0 to 1.0)
    var downloadProgress: Double = 0.0
    /// Whether we've received any download progress from yt-dlp
    var downloadHasProgress: Bool = false
    /// Current download speed (e.g., "5.2 MiB/s")
    var downloadSpeed: String? = nil
    /// Error message if download failed
    var downloadError: String? = nil
    /// Path to existing file (when download skipped because file exists)
    var fileAlreadyExistsPath: String? = nil
    /// Original URL for yt-dlp download (for retry functionality)
    var sourceURL: String? = nil
    /// Scheduled time for download (nil = download immediately or already started)
    var scheduledDownloadTime: Date? = nil
    /// Whether to automatically start encoding after download completes
    var autoEncodeAfterDownload: Bool = false
    /// Whether to start the live stream download from the beginning
    var downloadLiveFromStart: Bool = false
    /// Whether a live stream download is currently recording
    var isLiveStreamRecording: Bool = false
    /// Whether the download is in the process of stopping (provides immediate UI feedback)
    var downloadStopping: Bool = false
    /// Current file size during live recording (updated periodically)
    var liveRecordingFileSize: Int64? = nil
    /// Estimated duration during live recording (updated periodically)
    var liveRecordingDuration: Double? = nil

    // MARK: - Upload State
    /// Whether upload is enabled for this item
    var uploadEnabled: Bool = false
    /// Whether to upload the source file instead of encoded output
    var uploadSourceFile: Bool = false
    /// Current upload status
    var uploadStatus: UploadStatus = .notQueued
    /// Upload progress (0.0 to 1.0)
    var uploadProgress: Double = 0.0
    /// Upload speed (e.g., "5.2 MiB/s")
    var uploadSpeed: String? = nil
    /// Remote path where file was uploaded
    var uploadedRemotePath: String? = nil

    // MARK: - Subtitle Generation State
    /// Whether subtitle generation is enabled for this item
    var subtitleEnabled: Bool = false
    /// Current subtitle generation status
    var subtitleStatus: SubtitleStatus = .notQueued
    /// Subtitle generation progress (0.0 to 1.0)
    var subtitleProgress: Double = 0.0
    /// Path to generated SRT file
    var subtitleFilePath: URL? = nil

    /// Manual override for output filename (base name, no extension)
    var outputFileNameOverride: String? = nil

    /// Whether this item is ready for upload (conversion done or source upload enabled)
    var isReadyForUpload: Bool {
        if uploadSourceFile {
            return uploadEnabled
        }
        return status == .done && uploadEnabled && outputURL != nil
    }

    /// The file URL to upload (source or output depending on uploadSourceFile setting)
    var fileToUpload: URL? {
        uploadSourceFile ? url : outputURL
    }

    /// Whether this item is scheduled for future download
    var isScheduledDownload: Bool {
        scheduledDownloadTime != nil && !isDownloading
    }

    /// Whether this item can be encoded (not downloading, no error, not scheduled)
    var isEncodable: Bool {
        !isDownloading && downloadError == nil && scheduledDownloadTime == nil
    }

    /// Whether this item can be played/previewed (file is available, not downloading or recording)
    var isPlayable: Bool {
        !isDownloading && !isLiveStreamRecording && scheduledDownloadTime == nil
    }

    mutating func apply(details: VideoFileUtils.VideoItemDetails) {
        size = details.size
        duration = details.duration
        durationSeconds = details.durationSeconds
        thumbnailData = details.thumbnailData
        if outputFileNameOverride == nil {
            outputURL = details.outputURL
        }
        hasVideoStream = details.hasVideoStream
    }
    
    /// Human-readable file size string (<1 MB ⇒ KB, 1–600 MB ⇒ MB, ≥600 MB ⇒ GB)
    var formattedSize: String {
        let bytes = Double(size)
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        
        if bytes < mb {
            return String(format: "%.0f KB", bytes / kb)
        } else if bytes < 600 * mb {
            return String(format: "%.1f MB", bytes / mb)
        } else {
            return String(format: "%.1f GB", bytes / gb)
        }
    }
    
    /// Effective trim-in point in seconds (defaults to 0 when unset).
    var effectiveTrimStart: Double {
        trimStart ?? 0
    }
    
    /// Effective trim-out point in seconds (defaults to full duration when unset).
    var effectiveTrimEnd: Double {
        let end = trimEnd ?? durationSeconds
        return max(end, effectiveTrimStart)
    }
    
    /// Duration of the trimmed range in seconds.
    var trimmedDuration: Double {
        max(effectiveTrimEnd - effectiveTrimStart, 0)
    }

    var outputFileExists: Bool {
        guard let outputURL = outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    /// Size of the output file in bytes, or nil if the file doesn't exist
    var outputFileSize: Int64? {
        guard let outputURL = outputURL else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }

    /// Human-readable output file size string
    var formattedOutputSize: String? {
        // Prefer stored size (set on conversion complete), fall back to computed
        guard let bytes = outputFileSizeBytes ?? outputFileSize else { return nil }
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let bytesDouble = Double(bytes)

        if bytesDouble < mb {
            return String(format: "%.0f KB", bytesDouble / kb)
        } else if bytesDouble < 600 * mb {
            return String(format: "%.1f MB", bytesDouble / mb)
        } else {
            return String(format: "%.1f GB", bytesDouble / gb)
        }
    }

    var requiresWaveformVideo: Bool {
        !hasVideoStream && waveformVideoEnabled
    }

    var metadataComment: String? {
        guard let raw = metadata?.comment?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    var videoDisplayAspectRatio: Double? {
        if let ratioValue = metadata?.primaryVideoStream?.displayAspectRatio?.doubleValue {
            return ratioValue
        }
        if
            let width = metadata?.primaryVideoStream?.width,
            let height = metadata?.primaryVideoStream?.height,
            width > 0,
            height > 0
        {
            return Double(width) / Double(height)
        }
        return nil
    }

    var videoResolutionDescription: String? {
        guard let width = metadata?.primaryVideoStream?.width, let height = metadata?.primaryVideoStream?.height else {
            return nil
        }
        return "\(width) × \(height)"
    }
}
