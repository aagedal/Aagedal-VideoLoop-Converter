import Foundation
import OSLog

struct VideoMetadata: Equatable, Sendable {
    struct Ratio: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var doubleValue: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(numerator: Int, denominator: Int) {
            guard denominator != 0 else { return nil }
            self.numerator = numerator
            self.denominator = denominator
            self.stringValue = "\(numerator):\(denominator)"
        }

        init?(ratioString: String) {
            let trimmed = ratioString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let parsed = Ratio.parse(trimmed, separator: ":") ?? Ratio.parse(trimmed, separator: "/") {
                self = parsed
                return
            }

            if let value = Double(trimmed) {
                let scaledNumerator = Int((value * 10_000).rounded())
                self.numerator = scaledNumerator
                self.denominator = 10_000
                self.stringValue = String(format: value >= 10 ? "%.2f" : "%.4f", value)
                return
            }

            return nil
        }

        static func parse(_ string: String, separator: Character) -> Ratio? {
            let parts = string.split(separator: separator)
            guard parts.count == 2,
                  let numerator = Int(parts[0]),
                  let denominator = Int(parts[1]),
                  denominator != 0 else {
                return nil
            }
            return Ratio(numerator: numerator, denominator: denominator)
        }
    }

    struct FrameRate: Equatable, Sendable {
        let numerator: Int
        let denominator: Int
        let stringValue: String

        var value: Double? {
            guard denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }

        init?(frameRateString: String) {
            let trimmed = frameRateString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if let ratio = Ratio.parse(trimmed, separator: "/") {
                self.numerator = ratio.numerator
                self.denominator = ratio.denominator
                if let value = ratio.doubleValue {
                    self.stringValue = String(format: "%.3f", value)
                } else {
                    self.stringValue = trimmed
                }
                return
            }

            if let value = Double(trimmed), value > 0 {
                self.numerator = Int((value * 1_000).rounded())
                self.denominator = 1_000
                self.stringValue = String(format: "%.3f", value)
                return
            }

            return nil
        }
    }

    let duration: Double?
    let formatName: String?
    let containerLongName: String?
    let sizeBytes: Int64?
    let bitRate: Int64?
    let comment: String?
    let timecode: String?
    let frameCount: Int?

    struct VideoStream: Equatable, Sendable {
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let width: Int?
        let height: Int?
        let pixelFormat: String?
        let hasAlpha: Bool
        let pixelAspectRatio: Ratio?
        let displayAspectRatio: Ratio?
        let frameRate: FrameRate?
        let bitDepth: Int?
        let chromaSubsampling: String?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let colorRange: String?
        let chromaLocation: String?
        let fieldOrder: String?
        let isInterlaced: Bool?

        /// Calculates chroma channel resolution based on subsampling
        /// Returns nil for 4:4:4 (same as luma), grayscale, or unknown subsampling
        var chromaResolution: (width: Int, height: Int)? {
            guard let width, let height, let subsampling = chromaSubsampling else { return nil }

            // 4:4:4 has same resolution as luma, no need to show separately
            let factors: (h: Int, v: Int)? = switch subsampling {
            case "4:2:2": (2, 1)  // Half horizontal
            case "4:2:0": (2, 2)  // Half horizontal and vertical
            case "4:1:1": (4, 1)  // Quarter horizontal
            case "4:1:0": (4, 2)  // Quarter horizontal, half vertical
            default: nil
            }

            guard let factors else { return nil }
            return (width / factors.h, height / factors.v)
        }

        /// Formatted string for chroma resolution display
        var chromaResolutionDescription: String? {
            guard let res = chromaResolution else { return nil }
            return "\(res.width)×\(res.height)"
        }
    }

    struct AudioStream: Equatable, Sendable {
        let index: Int?
        let languageCode: String?
        let title: String?
        let codec: String?
        let codecLongName: String?
        let profile: String?
        let sampleRate: Int?
        let channels: Int?
        let channelLayout: String?
        let bitDepth: Int?
        let bitRate: Int64?
        let isDefault: Bool
    }

    struct SubtitleStream: Equatable, Sendable {
        let index: Int?
        let languageCode: String?
        let title: String?
        let codec: String?
        let codecLongName: String?
        let isDefault: Bool
        let isForced: Bool
    }

    let videoStreams: [VideoStream]
    let audioStreams: [AudioStream]
    let subtitleStreams: [SubtitleStream]

    /// Returns the primary video stream (first non-cover-art stream)
    /// Use this for operations that need a single stream (crop, aspect ratio, codec detection)
    var primaryVideoStream: VideoStream? {
        videoStreams.first
    }

    func isDefaultAudioStream(index: Int) -> Bool {
        guard audioStreams.indices.contains(index) else { return false }
        return audioStreams[index].isDefault
    }
}

enum VideoMetadataError: Error {
    case ffprobeMissing
    case processFailed(String)
    case decodingFailed(String)
    case timeout
}

/// Essential video information needed for import (obtained in a single FFprobe call)
struct EssentialVideoInfo: Sendable {
    let duration: Double
    let hasVideoStream: Bool
    let videoStreamCount: Int
    let hasAudioStream: Bool
    let primaryCodec: String?
    let width: Int?
    let height: Int?
}

actor VideoMetadataService {
    static let shared = VideoMetadataService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VideoMetadata")
    private let cache = NSCache<NSURL, CachedMetadata>()
    private let essentialInfoCache = NSCache<NSURL, CachedEssentialInfo>()

    private final class CachedMetadata: NSObject {
        let metadata: VideoMetadata
        init(metadata: VideoMetadata) {
            self.metadata = metadata
        }
    }

    private final class CachedEssentialInfo: NSObject {
        let info: EssentialVideoInfo
        init(info: EssentialVideoInfo) {
            self.info = info
        }
    }

    /// Fetches essential video info in a single FFprobe call (optimized for bulk imports)
    /// Returns: duration, hasVideoStream, videoStreamCount, hasAudioStream, primaryCodec
    func fetchEssentialInfo(for url: URL) async throws -> EssentialVideoInfo {
        // Check cache first
        if let cached = essentialInfoCache.object(forKey: url as NSURL) {
            return cached.info
        }

        var didStartDirectAccess = false
        var didStartBookmarkAccess = false
        if url.startAccessingSecurityScopedResource() {
            didStartDirectAccess = true
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            didStartBookmarkAccess = true
        }

        defer {
            if didStartDirectAccess {
                url.stopAccessingSecurityScopedResource()
            } else if didStartBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            }
        }

        guard let ffprobePath = BinaryPathResolver.ffprobePath else {
            throw VideoMetadataError.ffprobeMissing
        }

        // Single FFprobe call that gets both format and all streams
        let response = try await fetchFFprobeResponse(
            url: url,
            ffprobePath: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_format",
                "-show_streams",
                "-of", "json"
            ],
            allowNoStreams: true
        )

        // Parse essential info from response
        let duration = response.format?.duration.flatMap { Double($0) } ?? 0

        // Filter video streams (exclude cover art)
        let videoStreams = response.streams.filter { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic != 1
        }
        let hasVideoStream = !videoStreams.isEmpty
        let videoStreamCount = videoStreams.count
        let primaryVideoStream = videoStreams.first

        // Check for audio streams
        let audioStreams = response.streams.filter { $0.codecType == "audio" }
        let hasAudioStream = !audioStreams.isEmpty

        let info = EssentialVideoInfo(
            duration: duration,
            hasVideoStream: hasVideoStream,
            videoStreamCount: videoStreamCount,
            hasAudioStream: hasAudioStream,
            primaryCodec: primaryVideoStream?.codecName,
            width: primaryVideoStream?.width,
            height: primaryVideoStream?.height
        )

        // Cache the result
        essentialInfoCache.setObject(CachedEssentialInfo(info: info), forKey: url as NSURL)

        return info
    }

    func metadata(for url: URL) async throws -> VideoMetadata {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached.metadata
        }

        var didStartDirectAccess = false
        var didStartBookmarkAccess = false
        if url.startAccessingSecurityScopedResource() {
            didStartDirectAccess = true
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            didStartBookmarkAccess = true
        }

        defer {
            if didStartDirectAccess {
                url.stopAccessingSecurityScopedResource()
            } else if didStartBookmarkAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            }
        }

        guard let ffprobePath = BinaryPathResolver.ffprobePath else {
            throw VideoMetadataError.ffprobeMissing
        }

        let response = try await fetchFFprobeResponse(
            url: url,
            ffprobePath: ffprobePath,
            arguments: [
                "-v", "error",
                "-show_format",
                "-show_streams",
                "-of", "json"
            ],
            allowNoStreams: true
        )

        let videoStreams = response.streams.filter { $0.codecType == "video" }
        let audioStreams = response.streams.filter { $0.codecType == "audio" }
        let subtitleStreams = response.streams.filter { $0.codecType == "subtitle" }

        let metadata = try buildMetadata(
            format: response.format,
            videoStreams: videoStreams,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams
        )
        cache.setObject(CachedMetadata(metadata: metadata), forKey: url as NSURL)
        return metadata
    }

    private func runFFprobeJSON(url: URL, ffprobePath: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobePath)
                var args = arguments
                args.append(url.path)
                process.arguments = args

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Wait with timeout (10 seconds - must be less than fetchMetadata timeout)
                let timeoutSeconds: TimeInterval = 10
                let checkInterval: TimeInterval = 0.5
                var elapsed: TimeInterval = 0
                
                while process.isRunning && elapsed < timeoutSeconds {
                    try? await Task.sleep(for: .seconds(checkInterval))
                    elapsed += checkInterval
                }
                
                if process.isRunning {
                    // Timeout - terminate the process
                    process.terminate()
                    try? await Task.sleep(for: .seconds(0.1))  // Give it a moment to terminate
                    if process.isRunning {
                        process.interrupt()  // Force kill if still running
                    }
                    continuation.resume(throwing: VideoMetadataError.timeout)
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdoutData)
                } else {
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown ffprobe error"
                    continuation.resume(throwing: VideoMetadataError.processFailed(message))
                }
            }
        }
    }

    private func fetchFFprobeResponse(url: URL, ffprobePath: String, arguments: [String], allowNoStreams: Bool = false) async throws -> FFprobeResponse {
        do {
            let data = try await runFFprobeJSON(url: url, ffprobePath: ffprobePath, arguments: arguments)
            return try decodeFFprobeResponse(jsonData: data)
        } catch VideoMetadataError.processFailed(let message) {
            if allowNoStreams, message.contains("Stream specifier") {
                return FFprobeResponse(format: nil, streams: [])
            }
            throw VideoMetadataError.processFailed(message)
        }
    }

    private func decodeFFprobeResponse(jsonData: Data) throws -> FFprobeResponse {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(FFprobeResponse.self, from: jsonData)
        } catch {
            let message = String(data: jsonData, encoding: .utf8) ?? "<non-UTF8>"
            logger.error("Failed to decode ffprobe JSON: \(message)")
            throw VideoMetadataError.decodingFailed(error.localizedDescription)
        }
    }

    private func buildMetadata(format: FFprobeResponse.Format?, videoStreams: [FFprobeResponse.Stream], audioStreams: [FFprobeResponse.Stream], subtitleStreams: [FFprobeResponse.Stream]) throws -> VideoMetadata {
        // Filter to actual video streams (exclude cover art/attached pictures)
        let filteredVideoStreams = videoStreams.filter { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic != 1
        }
        let primaryVideoStream = filteredVideoStreams.first

        let filteredAudioStreams = audioStreams.filter { $0.codecType == "audio" }

        let formatComment = format?.tags?.comment ?? primaryVideoStream?.tags?.comment ?? filteredAudioStreams.first?.tags?.comment

        // Extract timecode from format tags or video stream tags
        let timecode = format?.tags?.timecode ?? primaryVideoStream?.tags?.timecode

        // Extract frame count from video stream, or calculate from duration and frame rate
        let frameCount: Int? = {
            // First try direct nb_frames from stream
            if let nbFrames = primaryVideoStream?.nbFrames, let count = Int(nbFrames) {
                return count
            }
            // Fallback: calculate from duration and frame rate (common for MXF files)
            if let durationStr = format?.duration,
               let duration = Double(durationStr),
               let frameRateStr = primaryVideoStream?.avgFrameRate ?? primaryVideoStream?.rFrameRate,
               let frameRate = VideoMetadata.FrameRate(frameRateString: frameRateStr),
               let fps = frameRate.value,
               fps > 0 {
                return Int(round(duration * fps))
            }
            return nil
        }()

        // Map all video streams (not just primary)
        let video = filteredVideoStreams.map { stream -> VideoMetadata.VideoStream in
            let frameRateString = stream.avgFrameRate ?? stream.rFrameRate
            let hasAlpha = stream.pixFmt.map { hasAlphaChannel(pixelFormat: $0) } ?? false
            // Use bitsPerRawSample if available, otherwise extract from pixel format
            let bitDepth: Int? = stream.bitsPerRawSample.flatMap { Int($0) }
                ?? stream.pixFmt.flatMap { bitDepthFromPixelFormat($0) }
            let chromaSubsampling = stream.pixFmt.flatMap { chromaSubsamplingFromPixelFormat($0) }
            return VideoMetadata.VideoStream(
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                width: stream.width,
                height: stream.height,
                pixelFormat: stream.pixFmt,
                hasAlpha: hasAlpha,
                pixelAspectRatio: stream.sampleAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                displayAspectRatio: stream.displayAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                frameRate: frameRateString.flatMap(VideoMetadata.FrameRate.init(frameRateString:)),
                bitDepth: bitDepth,
                chromaSubsampling: chromaSubsampling,
                colorPrimaries: stream.colorPrimaries,
                colorTransfer: stream.colorTransfer,
                colorSpace: stream.colorSpace,
                colorRange: stream.colorRange,
                chromaLocation: stream.chromaLocation,
                fieldOrder: stream.fieldOrder,
                isInterlaced: stream.fieldOrder.map {
                    let value = $0.lowercased()
                    return value != "progressive" && value != "unknown"
                }
            )
        }

        let audio = filteredAudioStreams.map { stream -> VideoMetadata.AudioStream in
            VideoMetadata.AudioStream(
                index: stream.index,
                languageCode: stream.tags?.language?.lowercased(),
                title: stream.tags?.title,
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                sampleRate: stream.sampleRate.flatMap { Int($0) },
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                bitDepth: stream.bitsPerRawSample.flatMap { Int($0) },
                bitRate: stream.bitRate.flatMap { Int64($0) },
                isDefault: (stream.disposition?.defaultStream == 1)
            )
        }

        let filteredSubtitleStreams = subtitleStreams.filter { $0.codecType == "subtitle" }

        let subtitles = filteredSubtitleStreams.map { stream -> VideoMetadata.SubtitleStream in
            VideoMetadata.SubtitleStream(
                index: stream.index,
                languageCode: stream.tags?.language?.lowercased(),
                title: stream.tags?.title,
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                isDefault: (stream.disposition?.defaultStream == 1),
                isForced: (stream.disposition?.forced == 1)
            )
        }

        return VideoMetadata(
            duration: format?.duration.flatMap { Double($0) },
            formatName: format?.formatName,
            containerLongName: format?.formatLongName,
            sizeBytes: format?.size.flatMap { Int64($0) },
            bitRate: format?.bitRate.flatMap { Int64($0) },
            comment: formatComment,
            timecode: timecode,
            frameCount: frameCount,
            videoStreams: video,
            audioStreams: audio,
            subtitleStreams: subtitles
        )
    }

}

/// Extracts bit depth from pixel format string
/// Examples: yuv420p10le -> 10, yuv422p12be -> 12, yuv420p -> 8
private func bitDepthFromPixelFormat(_ pixelFormat: String) -> Int? {
    let format = pixelFormat.lowercased()

    // Look for bit depth patterns like "10le", "12be", "10", "12", "16"
    // Common patterns: yuv420p10le, yuv422p12be, rgb48be, gray16le
    let patterns = [
        #"(\d{1,2})(le|be)?$"#,  // Ending with bit depth (optionally with endianness)
        #"p(\d{1,2})(le|be)?$"#, // After 'p' for planar formats
    ]

    for pattern in patterns {
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: format, options: [], range: NSRange(format.startIndex..., in: format)) {
            // Get the capture group with the number
            let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            if let range = Range(captureRange, in: format),
               let bitDepth = Int(format[range]),
               bitDepth >= 8 && bitDepth <= 16 {
                return bitDepth
            }
        }
    }

    // Special cases for formats without explicit bit depth (default to 8-bit)
    // yuv420p, yuv422p, yuv444p, rgb24, bgr24, etc. are all 8-bit
    if format.contains("24") || format.contains("32") {
        return 8  // rgb24, bgr24, rgba32 are 8 bits per component
    }

    if format.contains("48") || format.contains("64") {
        return 16  // rgb48, rgba64 are 16 bits per component
    }

    // Formats like yuv420p, yuv422p without bit depth suffix are 8-bit
    let eightBitPatterns = ["yuv420p", "yuv422p", "yuv444p", "yuvj420p", "yuvj422p", "yuvj444p", "nv12", "nv21"]
    for pattern in eightBitPatterns {
        if format == pattern {
            return 8
        }
    }

    return nil
}

/// Extracts chroma subsampling from pixel format string
/// Examples: yuv420p -> "4:2:0", yuv422p10le -> "4:2:2", yuv444p -> "4:4:4"
private func chromaSubsamplingFromPixelFormat(_ pixelFormat: String) -> String? {
    let format = pixelFormat.lowercased()

    // YUV 4:2:0 patterns
    if format.contains("420") || format.contains("nv12") || format.contains("nv21") {
        return "4:2:0"
    }

    // YUV 4:2:2 patterns
    if format.contains("422") || format.contains("yuyv") || format.contains("uyvy") {
        return "4:2:2"
    }

    // YUV 4:4:4 patterns
    if format.contains("444") {
        return "4:4:4"
    }

    // YUV 4:1:1 patterns
    if format.contains("411") {
        return "4:1:1"
    }

    // YUV 4:1:0 patterns
    if format.contains("410") {
        return "4:1:0"
    }

    // RGB/RGBA formats have no chroma subsampling (4:4:4 equivalent)
    if format.hasPrefix("rgb") || format.hasPrefix("bgr") || format.hasPrefix("argb") ||
       format.hasPrefix("abgr") || format.hasPrefix("rgba") || format.hasPrefix("bgra") ||
       format.hasPrefix("gbr") {
        return "4:4:4"
    }

    // Grayscale/monochrome has no chroma
    if format.hasPrefix("gray") || format.hasPrefix("mono") || format == "y" {
        return nil  // No chroma subsampling for grayscale
    }

    return nil
}

/// Detects if a pixel format contains an alpha channel
/// Based on common FFmpeg pixel format naming conventions
private func hasAlphaChannel(pixelFormat: String) -> Bool {
    let format = pixelFormat.lowercased()

    // Common patterns for alpha channel pixel formats:
    // - Formats ending with 'a' (e.g., rgba, yuva420p, gbrap)
    // - Formats containing 'alpha' (e.g., pal8_alpha)
    // - Specific ProRes formats with alpha (4444, 4444xq)

    // ProRes 4444 and 4444 XQ have alpha
    if format.contains("4444") {
        return true
    }

    // RGBA, BGRA, ARGB, ABGR formats
    if format.contains("rgba") || format.contains("bgra") ||
       format.contains("argb") || format.contains("abgr") {
        return true
    }

    // YUV formats with alpha (yuva, yuv444ap, etc.)
    if format.hasPrefix("yuva") {
        return true
    }

    // GBRAP (planar RGB with alpha)
    if format.hasPrefix("gbrap") {
        return true
    }

    // Generic patterns
    if format.contains("alpha") {
        return true
    }

    // Formats ending with 'a' followed by bit depth or 'p' (planar)
    // e.g., rgba64, yuva420p, etc.
    let alphaPatterns = ["rgba", "bgra", "argb", "yuva", "gbrap"]
    for pattern in alphaPatterns {
        if format.hasPrefix(pattern) {
            return true
        }
    }

    return false
}

private struct FFprobeResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case format
        case streams
    }

    let format: Format?
    let streams: [Stream]

    init(format: Format?, streams: [Stream]) {
        self.format = format
        self.streams = streams
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try container.decodeIfPresent(Format.self, forKey: .format)
        self.streams = try container.decodeIfPresent([Stream].self, forKey: .streams) ?? []
    }

    struct Format: Decodable {
        let duration: String?
        let formatName: String?
        let formatLongName: String?
        let size: String?
        let bitRate: String?
        let tags: Tags?
    }

    struct Stream: Decodable {
        let index: Int?
        let codecName: String?
        let codecLongName: String?
        let profile: String?
        let codecType: String?
        let width: Int?
        let height: Int?
        let pixFmt: String?
        let sampleAspectRatio: String?
        let displayAspectRatio: String?
        let avgFrameRate: String?
        let rFrameRate: String?
        let bitRate: String?
        let bitsPerRawSample: String?
        let sampleRate: String?
        let channels: Int?
        let channelLayout: String?
        let colorPrimaries: String?
        let colorTransfer: String?
        let colorSpace: String?
        let colorRange: String?
        let chromaLocation: String?
        let fieldOrder: String?
        let maxBitRate: String?
        let nbFrames: String?
        let disposition: Disposition?
        let tags: Tags?

        struct Disposition: Decodable {
            let defaultStream: Int?
            let attachedPic: Int?
            let forced: Int?
        }
    }

    struct Tags: Decodable {
        let comment: String?
        let language: String?
        let title: String?
        let timecode: String?
    }

    func toVideoMetadata() -> VideoMetadata {
        let formatMetadata = format

        // Filter to actual video streams (exclude cover art/attached pictures)
        let filteredVideoStreams = streams.filter { stream in
            stream.codecType == "video" && stream.disposition?.attachedPic != 1
        }
        let primaryVideoStream = filteredVideoStreams.first

        // Get all audio streams
        let audioStreams = streams.filter { $0.codecType == "audio" }

        let formatComment = formatMetadata?.tags?.comment ?? primaryVideoStream?.tags?.comment

        // Extract timecode from format tags or video stream tags
        let timecode = formatMetadata?.tags?.timecode ?? primaryVideoStream?.tags?.timecode

        // Extract frame count from video stream, or calculate from duration and frame rate
        let frameCount: Int? = {
            // First try direct nb_frames from stream
            if let nbFrames = primaryVideoStream?.nbFrames, let count = Int(nbFrames) {
                return count
            }
            // Fallback: calculate from duration and frame rate (common for MXF files)
            if let durationStr = formatMetadata?.duration,
               let duration = Double(durationStr),
               let frameRateStr = primaryVideoStream?.avgFrameRate ?? primaryVideoStream?.rFrameRate,
               let frameRate = VideoMetadata.FrameRate(frameRateString: frameRateStr),
               let fps = frameRate.value,
               fps > 0 {
                return Int(round(duration * fps))
            }
            return nil
        }()

        // Map all video streams (not just primary)
        let video = filteredVideoStreams.map { stream -> VideoMetadata.VideoStream in
            let frameRateString = stream.avgFrameRate ?? stream.rFrameRate
            let hasAlpha = stream.pixFmt.map { hasAlphaChannel(pixelFormat: $0) } ?? false
            // Use bitsPerRawSample if available, otherwise extract from pixel format
            let bitDepth: Int? = stream.bitsPerRawSample.flatMap { Int($0) }
                ?? stream.pixFmt.flatMap { bitDepthFromPixelFormat($0) }
            let chromaSubsampling = stream.pixFmt.flatMap { chromaSubsamplingFromPixelFormat($0) }
            return VideoMetadata.VideoStream(
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                width: stream.width,
                height: stream.height,
                pixelFormat: stream.pixFmt,
                hasAlpha: hasAlpha,
                pixelAspectRatio: stream.sampleAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                displayAspectRatio: stream.displayAspectRatio.flatMap(VideoMetadata.Ratio.init(ratioString:)),
                frameRate: frameRateString.flatMap(VideoMetadata.FrameRate.init(frameRateString:)),
                bitDepth: bitDepth,
                chromaSubsampling: chromaSubsampling,
                colorPrimaries: stream.colorPrimaries,
                colorTransfer: stream.colorTransfer,
                colorSpace: stream.colorSpace,
                colorRange: stream.colorRange,
                chromaLocation: stream.chromaLocation,
                fieldOrder: stream.fieldOrder,
                isInterlaced: stream.fieldOrder.map {
                    let value = $0.lowercased()
                    // Field order values: progressive, tt (top first), bb (bottom first), tb, bt
                    // Anything other than "progressive" or "unknown" is interlaced
                    return value != "progressive" && value != "unknown"
                }
            )
        }

        let audio = audioStreams.map { stream -> VideoMetadata.AudioStream in
            return VideoMetadata.AudioStream(
                index: stream.index,
                languageCode: stream.tags?.language?.lowercased(),
                title: stream.tags?.title,
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                sampleRate: stream.sampleRate.flatMap { Int($0) },
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                bitDepth: stream.bitsPerRawSample.flatMap { Int($0) },
                bitRate: stream.bitRate.flatMap { Int64($0) },
                isDefault: (stream.disposition?.defaultStream == 1)
            )
        }

        // Get all subtitle streams
        let subtitleStreams = streams.filter { $0.codecType == "subtitle" }

        let subtitles = subtitleStreams.map { stream -> VideoMetadata.SubtitleStream in
            return VideoMetadata.SubtitleStream(
                index: stream.index,
                languageCode: stream.tags?.language?.lowercased(),
                title: stream.tags?.title,
                codec: stream.codecName,
                codecLongName: stream.codecLongName,
                isDefault: (stream.disposition?.defaultStream == 1),
                isForced: (stream.disposition?.forced == 1)
            )
        }

        return VideoMetadata(
            duration: formatMetadata?.duration.flatMap { Double($0) },
            formatName: formatMetadata?.formatName,
            containerLongName: formatMetadata?.formatLongName,
            sizeBytes: formatMetadata?.size.flatMap { Int64($0) },
            bitRate: formatMetadata?.bitRate.flatMap { Int64($0) },
            comment: formatComment,
            timecode: timecode,
            frameCount: frameCount,
            videoStreams: video,
            audioStreams: audio,
            subtitleStreams: subtitles
        )
    }
}
