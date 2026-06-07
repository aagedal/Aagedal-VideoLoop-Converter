// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Screen capture pipeline using ScreenCaptureKit + AVAssetWriter.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AudioToolbox
import Darwin
import CoreGraphics
import CoreImage
@preconcurrency import ScreenCaptureKit
import OSLog
import AppKit

private enum AudioSettingKeys {
    static let linearPCMIsNonInterleaved = "AVLinearPCMIsNonInterleaved"
}

struct CaptureDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool
}

enum CapturePreset: String, CaseIterable, Identifiable {
    case hevcGrowing
    case avcGrowing
    case hevc42210Bit
    case proRes4444

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevcGrowing:
            return "Growing HEVC 10-bit 4:2:2 (Resolve/Premiere)"
        case .avcGrowing:
            return "Growing H.264 (Compatibility)"
        case .hevc42210Bit:
            return "HEVC 10-bit 4:2:2 (Hardware)"
        case .proRes4444:
            return "ProRes 4444 (Visually Lossless)"
        }
    }

    var detail: String {
        switch self {
        case .hevcGrowing:
            return "Edit while recording in DaVinci Resolve & Premiere. Hardware HEVC 10-bit 4:2:2, fragmented .mov."
        case .avcGrowing:
            return "Edit while recording with maximum compatibility. Hardware H.264, fragmented .mov."
        case .hevc42210Bit:
            return "Hardware HEVC 10-bit 4:2:2. Source format determines chroma."
        case .proRes4444:
            return "High-fidelity ProRes 4444 for grading-heavy workflows."
        }
    }

    var fileExtension: String {
        "mov"
    }

    var fileType: AVFileType {
        .mov
    }

    var targetFrameRate: Int {
        60
    }

    /// "Growing file": a fragmented `.mov` tagged with the Blackmagic recording
    /// xattr so DaVinci Resolve treats it as a live, edit-while-recording clip
    /// (red REC overlay + fast refresh). See docs/growing-file-research.
    var isGrowing: Bool {
        switch self {
        case .hevcGrowing, .avcGrowing:
            return true
        case .hevc42210Bit, .proRes4444:
            return false
        }
    }

    static var availablePresets: [CapturePreset] {
        // Growing presets first (recommended for edit-while-recording). Stored
        // defaults that don't decode (e.g. the removed `.x264TS`/`.hevcVTTS`
        // FFmpeg-pipe presets) fall back to `.hevcGrowing` at the call sites.
        [.hevcGrowing, .avcGrowing, .hevc42210Bit, .proRes4444]
    }

    func videoSettings(width: Int, height: Int, frameRate: Int, hevcProfileOverride: String? = nil) -> [String: Any] {
        let compressionProperties: [String: Any]
        let codec: AVVideoCodecType
        let encoderSpec: [String: Any]?

        switch self {
        case .hevcGrowing:
            codec = .hevc
            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: growingBitrate(width: width, height: height, frameRate: frameRate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,          // ~1 s GOP
                AVVideoAllowFrameReorderingKey: false              // low-latency for live edit
            ]
            // 10-bit 4:2:2: prefer Main42210, fall back to Main10, else let the
            // encoder choose (resolved from the actual capture pixel format).
            if let hevcProfileOverride {
                properties[AVVideoProfileLevelKey] = hevcProfileOverride
            }
            compressionProperties = properties
            encoderSpec = nil   // allow hardware encoder
        case .avcGrowing:
            codec = .h264
            compressionProperties = [
                AVVideoAverageBitRateKey: growingBitrate(width: width, height: height, frameRate: frameRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,          // ~1 s GOP
                AVVideoAllowFrameReorderingKey: false
            ]
            encoderSpec = nil
        case .hevc42210Bit:
            codec = .hevc
            let bitrate = hevcBitrate(width: width, height: height, frameRate: frameRate)
            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate.average,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                kVTCompressionPropertyKey_DataRateLimits as String: bitrate.dataRateLimits
            ]
            if let hevcProfileOverride {
                properties[AVVideoProfileLevelKey] = hevcProfileOverride
            }
            compressionProperties = properties
            encoderSpec = nil
        case .proRes4444:
            codec = .proRes4444
            compressionProperties = [:]
            encoderSpec = nil
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        if !compressionProperties.isEmpty {
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }

        if let encoderSpec {
            settings[AVVideoEncoderSpecificationKey] = encoderSpec
        }

        return settings
    }

    var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AudioSettingKeys.linearPCMIsNonInterleaved: false
        ]
    }

    /// Bitrate for the growing presets — lighter than the archival HEVC 4:2:2
    /// preset so edit-while-recording files stay manageable. ~0.1 bits/pixel.
    private func growingBitrate(width: Int, height: Int, frameRate: Int) -> Int {
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        let target = Int(pixelsPerSecond * 0.10)
        return min(max(target, 12_000_000), 120_000_000)
    }

    private func hevcBitrate(width: Int, height: Int, frameRate: Int) -> (average: Int, dataRateLimits: [Int]) {
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        let targetBitsPerSecond = pixelsPerSecond * 0.28
        let minBitrate = 50_000_000
        let maxBitrate = 200_000_000
        let clamped = min(max(Int(targetBitsPerSecond), minBitrate), maxBitrate)
        let bytesPerSecond = max(1, clamped / 8)
        return (clamped, [bytesPerSecond, 1])
    }
}

enum CaptureFrameRateOption: String, CaseIterable, Identifiable {
    case auto
    case fps50
    case fps60

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto (Display)"
        case .fps50:
            return "50 fps (PAL)"
        case .fps60:
            return "60 fps (NTSC)"
        }
    }

    var fixedValue: Int? {
        switch self {
        case .auto:
            return nil
        case .fps50:
            return 50
        case .fps60:
            return 60
        }
    }
}

enum CaptureDynamicRangeOption: String, CaseIterable, Identifiable {
    case sdr
    case hdrP3CanonicalDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sdr:
            return "SDR (Display)"
        case .hdrP3CanonicalDisplay:
            return "HDR Display P3 (macOS 26+)"
        }
    }

    var isHDR: Bool {
        self != .sdr
    }
}

@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject {
    static let shared = ScreenCaptureManager()

    enum CaptureError: LocalizedError {
        case unavailableDisplay
        case accessDenied
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailableDisplay:
                return "No display available for capture."
            case .accessDenied:
                return "Unable to access the output folder."
            case .writerFailed(let message):
                return "Capture writer failed: \(message)"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var lastOutputURL: URL?
    @Published var errorMessage: String?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var audioLevels: UniversalAudioMeterService.AudioLevels = .silence
    @Published private(set) var microphoneLevels: UniversalAudioMeterService.AudioLevels = .silence
    @Published private(set) var microphoneCaptureStatus: MicrophoneCaptureStatus = .disabled
    @Published private(set) var autoStopDate: Date?

    enum MicrophoneCaptureStatus {
        case disabled
        case authorized
        case denied
    }

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ScreenCapture")
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var captureWriter: AnyCaptureOutputWriter?
    private var timerTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var outputAccess: SecurityAccess = .none
    private var recordingURL: URL?
    private var recordingStartDate: Date?
    private var previewStream: SCStream?
    private var previewOutput: CaptureStreamOutput?
    private override init() {
        super.init()
        refreshMicrophoneAuthorizationStatus()
    }

    func startRecording(
        preset: CapturePreset,
        outputDirectory: URL,
        displayID: CGDirectDisplayID?,
        frameRate: CaptureFrameRateOption,
        dynamicRange: CaptureDynamicRangeOption,
        includeSystemAudio: Bool = true,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        hideCursor: Bool,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = [],
        regionRect: CGRect? = nil
    ) async {
        guard !isRecording else { return }

        errorMessage = nil
        lastOutputURL = nil
        if isPreviewing {
            await stopPreview()
        }
        previewImage = nil
        audioLevels = .silence
        microphoneLevels = .silence

        do {
            let content = try await ScreenCaptureManager.shareableContent()
            guard let display = selectDisplay(from: content, preferredDisplayID: displayID) else {
                throw CaptureError.unavailableDisplay
            }

            let resolution: CGSize
            let sourceRect: CGRect
            if let regionRect {
                sourceRect = regionRect
                resolution = regionPixelResolution(for: display, region: regionRect)
            } else {
                resolution = displayPixelResolution(for: display)
                sourceRect = displaySourceRect(for: display)
            }
            let destinationRect = CGRect(origin: .zero, size: resolution)
            let frameRate = resolvedFrameRate(option: frameRate, display: display, fallback: preset.targetFrameRate)
            let effectiveDynamicRange = normalizedDynamicRange(dynamicRange)
            let outputURLs = try prepareOutputURLs(for: preset, directory: outputDirectory)
            let access = startAccessing(outputDirectory: outputDirectory)
            if case .none = access {
                throw CaptureError.accessDenied
            }

            let microphoneCaptureEnabled = await resolveMicrophoneCapture(requested: includeMicrophone)
            let selectedMicrophoneID = microphoneDeviceID?.isEmpty == false ? microphoneDeviceID : nil
            outputAccess = access
            recordingURL = outputURLs.recordingURL

            logger.info("Starting screen capture preset=\(preset.rawValue, privacy: .public) output=\(outputURLs.recordingURL.path, privacy: .public)")

            let pixelFormat = pixelFormat(for: preset, dynamicRange: effectiveDynamicRange)
            let config = makeStreamConfiguration(
                resolution: resolution,
                frameRate: frameRate,
                pixelFormat: pixelFormat,
                sourceRect: sourceRect,
                destinationRect: destinationRect,
                dynamicRange: effectiveDynamicRange
            )
            config.showsCursor = !hideCursor
            if microphoneCaptureEnabled, #available(macOS 15, *) {
                config.captureMicrophone = true
                if let selectedMicrophoneID {
                    config.microphoneCaptureDeviceID = selectedMicrophoneID
                }
            }
            let hevcProfileOverride = resolveHEVCProfileOverride(
                preset: preset,
                width: Int(resolution.width),
                height: Int(resolution.height),
                pixelFormat: config.pixelFormat
            )
            let filter = contentFilter(for: display, content: content, excludeCurrentApp: excludeCurrentApp, excludedAppBundleIDs: excludedAppBundleIDs)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)

            let writer: AnyCaptureOutputWriter = try ScreenCaptureWriter(
                outputURL: outputURLs.recordingURL,
                fileType: preset.fileType,
                videoSettings: preset.videoSettings(
                    width: Int(resolution.width),
                    height: Int(resolution.height),
                    frameRate: frameRate,
                    hevcProfileOverride: hevcProfileOverride
                ),
                audioSettings: preset.audioSettings,
                dynamicRange: effectiveDynamicRange,
                includeMicrophone: microphoneCaptureEnabled,
                isGrowing: preset.isGrowing,
                frameRate: frameRate
            )
            writer.setErrorHandler { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
            }

            let outputQueue = DispatchQueue(label: "com.aagedal.capture.stream")
            let previewContext = CIContext()
            var lastPreviewSeconds: Double = 0
            var lastAudioSeconds: Double = 0
            var lastMicrophoneSeconds: Double = 0
            let skipSystemAudio = !includeSystemAudio
            let output = CaptureStreamOutput(queue: outputQueue) { [weak self, weak writer] sampleBuffer, type in
                // Skip writing system audio samples when muted (still capture for metering)
                if type == .audio && skipSystemAudio {
                    // Fall through to metering below, but don't write
                } else {
                    writer?.append(sampleBuffer: sampleBuffer, type: type)
                }

                if #available(macOS 15, *), type == .microphone {
                    if let levels = ScreenCaptureManager.audioLevels(
                        from: sampleBuffer,
                        lastTimestamp: &lastMicrophoneSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.microphoneLevels = levels
                        }
                    }
                    return
                }

                switch type {
                case .screen:
                    if let image = ScreenCaptureManager.previewImage(
                        from: sampleBuffer,
                        context: previewContext,
                        lastTimestamp: &lastPreviewSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.previewImage = image
                        }
                    }
                case .audio:
                    if let levels = ScreenCaptureManager.audioLevels(
                        from: sampleBuffer,
                        lastTimestamp: &lastAudioSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.audioLevels = levels
                        }
                    }
                default:
                    break
                }
            }

            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            if microphoneCaptureEnabled, #available(macOS 15, *) {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: outputQueue)
            }

            try await stream.startCapture()

            self.stream = stream
            self.streamOutput = output
            self.captureWriter = writer
            self.isRecording = true
            self.recordingStartDate = Date()
            startTimer()
        } catch {
            logger.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            cleanup()
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false

        logger.info("Stopping screen capture")

        timerTask?.cancel()
        timerTask = nil
        elapsedTime = 0
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDate = nil

        if let stream {
            try? await stream.stopCapture()
        }

        let writer = captureWriter
        let recordingURL = recordingURL
        isProcessing = true
        cleanup(clearOutputs: false)

        if let writer {
            do {
                try await writer.finish()
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        if let recordingURL {
            lastOutputURL = recordingURL
        }
        isProcessing = false
        if !isPreviewing {
            previewImage = nil
            audioLevels = .silence
            microphoneLevels = .silence
        }

        releaseAccess()
    }

    func setAutoStop(after duration: TimeInterval) {
        autoStopTask?.cancel()
        guard duration > 0 else {
            autoStopDate = nil
            autoStopTask = nil
            return
        }
        autoStopDate = Date().addingTimeInterval(duration)
        autoStopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self.isRecording else { return }
            await self.stopRecording()
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDate = nil
    }

    func startPreview(
        displayID: CGDirectDisplayID?,
        frameRate: CaptureFrameRateOption,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        hideCursor: Bool,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = [],
        cachedContent: SCShareableContent? = nil,
        regionRect: CGRect? = nil
    ) async {
        guard !isPreviewing, !isRecording else { return }

        errorMessage = nil
        audioLevels = .silence
        microphoneLevels = .silence

        do {
            let content: SCShareableContent
            if let cachedContent {
                content = cachedContent
            } else {
                content = try await ScreenCaptureManager.shareableContent()
            }
            guard let display = selectDisplay(from: content, preferredDisplayID: displayID) else {
                throw CaptureError.unavailableDisplay
            }

            let pixelResolution: CGSize
            let sourceRect: CGRect
            if let regionRect {
                sourceRect = regionRect
                pixelResolution = regionPixelResolution(for: display, region: regionRect)
            } else {
                pixelResolution = displayPixelResolution(for: display)
                sourceRect = displaySourceRect(for: display)
            }
            let previewResolution = scaledPreviewResolution(from: pixelResolution, maxWidth: 1280)
            let destinationRect = CGRect(origin: .zero, size: previewResolution)

            let previewFrameRate = min(resolvedFrameRate(option: frameRate, display: display, fallback: 30), 60)
            let config = makeStreamConfiguration(
                resolution: previewResolution,
                frameRate: previewFrameRate,
                pixelFormat: kCVPixelFormatType_32BGRA,
                sourceRect: sourceRect,
                destinationRect: destinationRect,
                dynamicRange: .sdr
            )
            config.showsCursor = !hideCursor
            let previewMicrophoneEnabled = await resolveMicrophoneCapture(requested: includeMicrophone)
            let selectedMicrophoneID = microphoneDeviceID?.isEmpty == false ? microphoneDeviceID : nil
            if previewMicrophoneEnabled, #available(macOS 15, *) {
                config.captureMicrophone = true
                if let selectedMicrophoneID {
                    config.microphoneCaptureDeviceID = selectedMicrophoneID
                }
            }

            let filter = contentFilter(for: display, content: content, excludeCurrentApp: excludeCurrentApp, excludedAppBundleIDs: excludedAppBundleIDs)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)

            let outputQueue = DispatchQueue(label: "com.aagedal.capture.preview")
            let previewContext = CIContext()
            var lastPreviewSeconds: Double = 0
            var lastAudioSeconds: Double = 0
            var lastMicrophoneSeconds: Double = 0
            let output = CaptureStreamOutput(queue: outputQueue) { [weak self] sampleBuffer, type in
                if #available(macOS 15, *), type == .microphone {
                    if let levels = ScreenCaptureManager.audioLevels(
                        from: sampleBuffer,
                        lastTimestamp: &lastMicrophoneSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.microphoneLevels = levels
                        }
                    }
                    return
                }
                switch type {
                case .screen:
                    if let image = ScreenCaptureManager.previewImage(
                        from: sampleBuffer,
                        context: previewContext,
                        lastTimestamp: &lastPreviewSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.previewImage = image
                        }
                    }
                case .audio:
                    if let levels = ScreenCaptureManager.audioLevels(
                        from: sampleBuffer,
                        lastTimestamp: &lastAudioSeconds
                    ) {
                        Task { @MainActor [weak self] in
                            self?.audioLevels = levels
                        }
                    }
                default:
                    break
                }
            }

            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            if previewMicrophoneEnabled, #available(macOS 15, *) {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: outputQueue)
            }
            try await stream.startCapture()

            previewStream = stream
            previewOutput = output
            isPreviewing = true
        } catch {
            logger.error("Preview start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            await stopPreview()
        }
    }

    func stopPreview() async {
        guard isPreviewing else { return }

        if let previewStream {
            try? await previewStream.stopCapture()
        }
        previewStream = nil
        previewOutput = nil
        isPreviewing = false
        if !isRecording {
            microphoneLevels = .silence
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        let start = recordingStartDate ?? Date()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                elapsedTime = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func cleanup(clearOutputs: Bool = true) {
        stream = nil
        streamOutput = nil
        captureWriter = nil
        recordingStartDate = nil
        previewImage = nil
        audioLevels = .silence
        microphoneLevels = .silence
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDate = nil

        if clearOutputs {
            recordingURL = nil
        }
    }

    private func releaseAccess() {
        switch outputAccess {
        case .direct(let url):
            url.stopAccessingSecurityScopedResource()
        case .bookmark(let url):
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
        case .none:
            break
        }
        outputAccess = .none
    }

    private func selectDisplay(from content: SCShareableContent, preferredDisplayID: CGDirectDisplayID?) -> SCDisplay? {
        if let preferredDisplayID {
            if let preferred = content.displays.first(where: { $0.displayID == preferredDisplayID }) {
                return preferred
            }
        }

        if let mainDisplayID = ScreenCaptureManager.mainDisplayID() {
            return content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first
        }
        return content.displays.first
    }

    private func makeStreamConfiguration(
        resolution: CGSize,
        frameRate: Int,
        pixelFormat: OSType?,
        sourceRect: CGRect,
        destinationRect: CGRect,
        dynamicRange: CaptureDynamicRangeOption
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if dynamicRange != .sdr, #available(macOS 15, *) {
            switch dynamicRange {
            case .hdrP3CanonicalDisplay:
                config.captureDynamicRange = .hdrCanonicalDisplay
                config.colorSpaceName = CGColorSpace.displayP3_PQ
                config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case .sdr:
                break
            }
        }
        config.width = Int(resolution.width)
        config.height = Int(resolution.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        if let pixelFormat {
            config.pixelFormat = pixelFormat
        }
        config.scalesToFit = true
        config.sourceRect = sourceRect
        config.destinationRect = destinationRect
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        return config
    }

    private func pixelFormat(for preset: CapturePreset, dynamicRange: CaptureDynamicRangeOption) -> OSType? {
        switch dynamicRange {
        case .hdrP3CanonicalDisplay:
            return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .sdr:
            break
        }
        if preset == .hevc42210Bit || preset == .hevcGrowing {
            return kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        }
        return kCVPixelFormatType_32BGRA
    }

    private func frameRate(for display: SCDisplay, fallback: Int) -> Int {
        if let screenNumber = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           screenNumber == display.displayID,
           let maxFPS = NSScreen.main?.maximumFramesPerSecond,
           maxFPS > 0 {
            return maxFPS
        }

        if let matchingScreen = NSScreen.screens.first(where: {
            guard let screenID = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenID == display.displayID
        }) {
            return max(1, matchingScreen.maximumFramesPerSecond)
        }

        return max(1, fallback)
    }

    private func resolvedFrameRate(
        option: CaptureFrameRateOption,
        display: SCDisplay,
        fallback: Int
    ) -> Int {
        if let fixed = option.fixedValue {
            return fixed
        }
        return frameRate(for: display, fallback: fallback)
    }

    private func normalizedDynamicRange(_ option: CaptureDynamicRangeOption) -> CaptureDynamicRangeOption {
        if option != .sdr, !isHDRRecordingSupported {
            return .sdr
        }
        return option
    }

    private var isHDRRecordingSupported: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    @MainActor
    func refreshMicrophoneAuthorizationStatus() {
        guard #available(macOS 15, *) else {
            microphoneCaptureStatus = .disabled
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneCaptureStatus = .authorized
        case .denied, .restricted:
            microphoneCaptureStatus = .denied
        default:
            microphoneCaptureStatus = .disabled
        }
    }

    @MainActor
    func requestMicrophonePermission() async {
        _ = await resolveMicrophoneCapture(requested: true)
    }

    private func resolveMicrophoneCapture(requested: Bool) async -> Bool {
        guard requested else {
            microphoneCaptureStatus = .disabled
            return false
        }
        guard #available(macOS 15, *) else {
            microphoneCaptureStatus = .disabled
            return false
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneCaptureStatus = .authorized
            return true
        case .notDetermined:
            let granted = await requestMicrophoneAccess()
            microphoneCaptureStatus = granted ? .authorized : .denied
            return granted
        case .denied, .restricted:
            microphoneCaptureStatus = .denied
            return false
        @unknown default:
            microphoneCaptureStatus = .denied
            return false
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func displayPixelResolution(for display: SCDisplay) -> CGSize {
        let displayID = display.displayID
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let pixelWidth = mode.pixelWidth
            let pixelHeight = mode.pixelHeight
            if pixelWidth > 0 && pixelHeight > 0 {
                return CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            }
        }
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        if pixelWidth > 0 && pixelHeight > 0 {
            return CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        }
        return CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
    }

    private func displaySourceRect(for display: SCDisplay) -> CGRect {
        if let screen = ScreenCaptureManager.screen(for: display.displayID) {
            return CGRect(origin: .zero, size: screen.frame.size)
        }
        return CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
    }

    private func scaledPreviewResolution(from pixelResolution: CGSize, maxWidth: CGFloat) -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else {
            return pixelResolution
        }
        let scale = min(1.0, maxWidth / pixelResolution.width)
        let width = (pixelResolution.width * scale).rounded()
        let height = (pixelResolution.height * scale).rounded()
        return CGSize(width: width, height: height)
    }

    private func regionPixelResolution(for display: SCDisplay, region: CGRect) -> CGSize {
        let fullPointSize = displaySourceRect(for: display).size
        let fullPixelSize = displayPixelResolution(for: display)
        let scaleX = fullPixelSize.width / fullPointSize.width
        let scaleY = fullPixelSize.height / fullPointSize.height
        let w = Int(region.width * scaleX)
        let h = Int(region.height * scaleY)
        return CGSize(width: CGFloat((w / 2) * 2), height: CGFloat((h / 2) * 2))
    }

    private func startAccessing(outputDirectory: URL) -> SecurityAccess {
        if outputDirectory.startAccessingSecurityScopedResource() {
            return .direct(outputDirectory)
        }
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputDirectory) {
            return .bookmark(outputDirectory)
        }
        return .none
    }

    private func prepareOutputURLs(for preset: CapturePreset, directory: URL) throws -> (recordingURL: URL, finalURL: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let baseName = "ScreenCapture_\(timestamp)"

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let outputURL = directory.appendingPathComponent("\(baseName).\(preset.fileExtension)")
        return (outputURL, outputURL)
    }

    private func resolveHEVCProfileOverride(
        preset: CapturePreset,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> String? {
        guard preset == .hevc42210Bit || preset == .hevcGrowing else { return nil }
        guard isTenBitPixelFormat(pixelFormat) else {
            logger.warning("HEVC capture input is 8-bit; letting the encoder select a compatible profile.")
            return nil
        }
        if supportsHEVCMain42210(width: width, height: height, pixelFormat: pixelFormat) {
            return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
        }
        if supportsHEVCMain10(width: width, height: height, pixelFormat: pixelFormat) {
            logger.warning("HEVC Main42210 not supported; falling back to Main10.")
            return kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        logger.warning("HEVC Main10 not supported for capture input; letting the encoder select a compatible profile.")
        return nil
    }

    private func supportsHEVCMain42210(width: Int, height: Int, pixelFormat: OSType) -> Bool {
        var session: VTCompressionSession?
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: bufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main42210_AutoLevel
        )
        return profileStatus == noErr
    }

    private func supportsHEVCMain10(width: Int, height: Int, pixelFormat: OSType) -> Bool {
        var session: VTCompressionSession?
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: bufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel
        )
        return profileStatus == noErr
    }

    private func isTenBitPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_ARGB2101010LEPacked:
            return true
        default:
            return false
        }
    }

    private enum SecurityAccess {
        case none
        case direct(URL)
        case bookmark(URL)
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.current
    }

    private func contentFilter(
        for display: SCDisplay,
        content: SCShareableContent,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = []
    ) -> SCContentFilter {
        var excludedApps: [SCRunningApplication] = []

        if excludeCurrentApp,
           let bundleID = Bundle.main.bundleIdentifier,
           let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            excludedApps.append(app)
        }

        for bundleID in excludedAppBundleIDs {
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                excludedApps.append(app)
            }
        }

        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
    }

    nonisolated private static func previewImage(
        from sampleBuffer: CMSampleBuffer,
        context: CIContext,
        lastTimestamp: inout Double
    ) -> CGImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        if seconds.isFinite, seconds - lastTimestamp < 0.05 {
            return nil
        }
        if seconds.isFinite {
            lastTimestamp = seconds
        }

        let image = CIImage(cvPixelBuffer: imageBuffer)
        return context.createCGImage(image, from: image.extent)
    }

    nonisolated private static func audioLevels(
        from sampleBuffer: CMSampleBuffer,
        lastTimestamp: inout Double
    ) -> UniversalAudioMeterService.AudioLevels? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        if seconds.isFinite, seconds - lastTimestamp < 0.05 {
            return nil
        }
        if seconds.isFinite {
            lastTimestamp = seconds
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0, frameCount > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let inferredBytesPerSample = max(1, (bitsPerChannel + 7) / 8)
        let bytesPerSample: Int
        if bytesPerFrame > 0 {
            bytesPerSample = max(1, isNonInterleaved ? bytesPerFrame : bytesPerFrame / max(1, channelCount))
        } else {
            bytesPerSample = inferredBytesPerSample
        }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList.unsafeMutablePointer)
        let maxChannels = min(channelCount, 2)
        var peaks = [Float](repeating: 0, count: maxChannels)

        func sampleValue(from pointer: UnsafeRawPointer, index: Int) -> Float {
            let byteOffset = index * bytesPerSample
            if isFloat && (bitsPerChannel == 32 || (bitsPerChannel == 0 && bytesPerSample == 4)) {
                return pointer.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: 1).pointee
            }
            if isFloat && (bitsPerChannel == 64 || (bitsPerChannel == 0 && bytesPerSample == 8)) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: 1).pointee
                return Float(value)
            }
            if isSignedInt && (bitsPerChannel == 16 || bytesPerSample == 2) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Int16.self, capacity: 1).pointee
                return Float(value) / Float(Int16.max)
            }
            if isSignedInt && (bitsPerChannel == 24 || bytesPerSample == 3 || bytesPerSample == 4) {
                let base = pointer.advanced(by: byteOffset)
                let b0 = Int32(base.load(as: UInt8.self))
                let b1 = Int32(base.load(fromByteOffset: 1, as: UInt8.self))
                let b2 = Int32(base.load(fromByteOffset: 2, as: UInt8.self))
                let raw: Int32
                if isBigEndian {
                    raw = (b0 << 16) | (b1 << 8) | b2
                } else {
                    raw = (b2 << 16) | (b1 << 8) | b0
                }
                var signed = raw
                if signed & 0x800000 != 0 {
                    signed |= ~0xFFFFFF
                }
                return Float(signed) / Float(1 << 23)
            }
            if isSignedInt && (bitsPerChannel == 32 || bytesPerSample == 4) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Int32.self, capacity: 1).pointee
                return Float(value) / Float(Int32.max)
            }
            return 0
        }

        if isNonInterleaved {
            for channel in 0..<maxChannels {
                guard let data = audioBuffers[channel].mData else { continue }
                for frame in 0..<frameCount {
                    let value = sampleValue(from: data, index: frame)
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
        } else if let data = audioBuffers.first?.mData {
            for frame in 0..<frameCount {
                for channel in 0..<maxChannels {
                    let index = frame * channelCount + channel
                    let value = sampleValue(from: data, index: index)
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
        }

        func toDb(_ amplitude: Float) -> Float {
            guard amplitude > 0 else { return -60 }
            return max(-60, 20 * log10(amplitude))
        }

        let leftDb = toDb(peaks.first ?? 0)
        let rightDb = toDb(peaks.count > 1 ? peaks[1] : peaks.first ?? 0)
        let peakDb = max(leftDb, rightDb)
        return UniversalAudioMeterService.AudioLevels(
            leftChannel: leftDb,
            rightChannel: rightDb,
            peak: peakDb
        )
    }

    static func availableDisplays() async throws -> [CaptureDisplay] {
        let content = try await shareableContent()
        return displays(from: content)
    }

    static func displays(from content: SCShareableContent) -> [CaptureDisplay] {
        let mainDisplayID = mainDisplayID()
        return content.displays.map { display in
            let name = displayName(for: display.displayID)
            return CaptureDisplay(
                id: display.displayID,
                name: name ?? "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                isMain: display.displayID == mainDisplayID
            )
        }
    }

    @available(macOS 15, *)
    static func availableMicrophones() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    private static func mainDisplayID() -> CGDirectDisplayID? {
        guard let mainScreen = NSScreen.main,
              let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return screenNumber
    }

    private static func displayName(for displayID: CGDirectDisplayID) -> String? {
        guard let screen = screen(for: displayID) else { return nil }
        return screen.localizedName
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            if screenNumber == displayID {
                return screen
            }
        }
        return nil
    }
}

private protocol CaptureOutputWriter: AnyObject, Sendable {
    func append(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType)
    func finish() async throws
    func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void)
}

private typealias AnyCaptureOutputWriter = any CaptureOutputWriter & Sendable

private final class ScreenCaptureWriter: CaptureOutputWriter, @unchecked Sendable {
    private let outputURL: URL
    private let fileType: AVFileType
    private let videoSettings: [String: Any]
    private let audioSettings: [String: Any]
    private let dynamicRange: CaptureDynamicRangeOption
    private let includeMicrophone: Bool
    /// Growing preset: fragmented `.mov` + CFR pump + timecode track + the
    /// Blackmagic recording xattr (the DaVinci Resolve growing-file trigger).
    private let isGrowing: Bool
    private let frameRate: Int
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var timecodeInput: AVAssetWriterInput?
    private var timecodeFormat: CMTimeCodeFormatDescription?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hasVideoInput = false
    private var hasAudioInput = false
    private var hasMicrophoneInput = false
    private var hasTimecodeInput = false
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ScreenCaptureWriter")
    private var started = false
    private var finished = false
    private var writeError: Error?
    private var videoSampleCount = 0
    private var audioSampleCount = 0
    private var microphoneSampleCount = 0
    private var errorHandler: (@Sendable (Error) -> Void)?

    // CFR pump (growing presets only): SCStream is variable-rate, so we re-emit
    // the latest frame on a fixed clock to produce a constant-frame-rate file.
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var copyPool: CVPixelBufferPool?
    private var cfrTimer: DispatchSourceTimer?
    private let cfrQueue = DispatchQueue(label: "com.aagedal.capture.cfr")
    private let hostClock = CMClockGetHostTimeClock()
    private var sessionStartPTS: CMTime = .zero
    private var emittedFrameIndex = 0
    private var timecodeStartFrame = 0

    init(
        outputURL: URL,
        fileType: AVFileType,
        videoSettings: [String: Any],
        audioSettings: [String: Any],
        dynamicRange: CaptureDynamicRangeOption,
        includeMicrophone: Bool,
        isGrowing: Bool = false,
        frameRate: Int = 60
    ) throws {
        self.outputURL = outputURL
        self.fileType = fileType
        self.videoSettings = videoSettings
        self.audioSettings = audioSettings
        self.dynamicRange = dynamicRange
        self.includeMicrophone = includeMicrophone
        self.isGrowing = isGrowing
        self.frameRate = max(1, frameRate)
    }

    func append(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard writeError == nil else { return }
        if let writer, writer.status == .failed {
            writeError = writer.error
            return
        }

        if !started {
            guard type == .screen else {
                return
            }
            do {
                try setupWriterIfNeeded(sampleBuffer: sampleBuffer)
            } catch {
                recordError(error)
                return
            }

            if let writer {
                let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startWriting()
                writer.startSession(atSourceTime: startTime)
                started = true
                if writer.status == .failed {
                    recordError(writer.error ?? CaptureWriterError.writerStartFailed)
                    return
                }
                logger.info("Capture writer started.")
                if isGrowing {
                    sessionStartPTS = startTime
                    setRecordingXattr()      // the DaVinci Resolve growing-file trigger
                    startCFRPump()
                }
            }
        }

        if #available(macOS 15, *), type == .microphone {
            if hasMicrophoneInput, let microphoneInput, microphoneInput.isReadyForMoreMediaData {
                if microphoneSampleCount == 0 {
                    logger.info("First microphone sample received.")
                }
                microphoneSampleCount += 1
                if !microphoneInput.append(sampleBuffer) {
                    recordError(writer?.error ?? CaptureWriterError.microphoneAppendFailed)
                }
            }
            return
        }

        switch type {
        case .screen:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            applyColorAttachments(to: imageBuffer, dynamicRange: dynamicRange)
            if isGrowing {
                // Growing presets don't append here — the CFR pump re-emits the
                // latest frame on a fixed clock. Stash a private copy so SCStream
                // can recycle its buffer immediately.
                storeLatestFrame(imageBuffer)
                return
            }
            if hasVideoInput, let videoInput, videoInput.isReadyForMoreMediaData {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let appended: Bool
                if let adaptor = pixelBufferAdaptor {
                    appended = adaptor.append(imageBuffer, withPresentationTime: presentationTime)
                } else {
                    appended = videoInput.append(sampleBuffer)
                }
                if appended {
                    if videoSampleCount == 0 {
                        logger.info("First video sample received.")
                    }
                    videoSampleCount += 1
                } else {
                    recordError(writer?.error ?? CaptureWriterError.videoAppendFailed)
                }
            }
        case .audio:
            if hasAudioInput, let audioInput, audioInput.isReadyForMoreMediaData {
                if audioSampleCount == 0 {
                    logger.info("First audio sample received.")
                }
                audioSampleCount += 1
                if !audioInput.append(sampleBuffer) {
                    recordError(writer?.error ?? CaptureWriterError.audioAppendFailed)
                }
            }
        default:
            break
        }
    }

    func finish() async throws {
        guard !finished else { return }

        finished = true
        // Stop the CFR pump first so no tick appends after markAsFinished.
        stopCFRPump()
        // The recording xattr only marks a file as *currently growing*; a
        // finished file carries none (matches the reference recorder).
        if isGrowing {
            clearRecordingXattr()
        }

        guard let writer else {
            if let error = writeError {
                throw error
            }
            return
        }

        guard started else {
            writer.cancelWriting()
            if let error = writeError ?? writer.error {
                throw error
            }
            return
        }

        if hasVideoInput {
            videoInput?.markAsFinished()
        }
        if hasAudioInput {
            audioInput?.markAsFinished()
        }
        if hasMicrophoneInput {
            microphoneInput?.markAsFinished()
        }
        if hasTimecodeInput {
            timecodeInput?.markAsFinished()
        }

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        if videoSampleCount == 0 {
            throw CaptureWriterError.noVideoFrames
        }
        if let error = writeError ?? writer.error {
            throw error
        }
    }

    func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        errorHandler = handler
    }

    private func setupWriterIfNeeded(sampleBuffer: CMSampleBuffer) throws {
        guard writer == nil else { return }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        if isGrowing {
            // ~1 s fragments so the file is a valid growing movie on disk.
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        }
        let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer)
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let pixelFormat = imageBuffer.map { CVPixelBufferGetPixelFormatType($0) } ?? 0
        let bufferWidth = imageBuffer.map { CVPixelBufferGetWidth($0) } ?? 0
        let bufferHeight = imageBuffer.map { CVPixelBufferGetHeight($0) } ?? 0
        if pixelFormat != 0 {
            logger.info("Capture pixel format: \(pixelFormat, privacy: .public)")
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings,
            sourceFormatHint: formatHint
        )
        videoInput.expectsMediaDataInRealTime = true

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        var microphoneInput: AVAssetWriterInput?
        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            microphoneInput = input
        }

        hasVideoInput = writer.canAdd(videoInput)
        if hasVideoInput {
            writer.add(videoInput)
            var sourceAttributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            if pixelFormat != 0 {
                sourceAttributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
            }
            if bufferWidth > 0, bufferHeight > 0 {
                sourceAttributes[kCVPixelBufferWidthKey as String] = bufferWidth
                sourceAttributes[kCVPixelBufferHeightKey as String] = bufferHeight
            }
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: sourceAttributes
            )
        } else {
            throw CaptureWriterError.videoInputNotSupported
        }

        hasAudioInput = writer.canAdd(audioInput)
        if hasAudioInput {
            writer.add(audioInput)
        } else {
            recordError(CaptureWriterError.audioInputNotSupported)
        }

        if let microphoneInput {
            hasMicrophoneInput = writer.canAdd(microphoneInput)
            if hasMicrophoneInput {
                writer.add(microphoneInput)
            } else {
                recordError(CaptureWriterError.microphoneInputNotSupported)
            }
        }

        if isGrowing {
            setupTimecodeTrack(on: writer, videoInput: videoInput)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
    }

    /// Adds a per-frame `tmcd` timecode track (growing presets) starting at
    /// wall-clock time-of-day, associated with the video track. Must run before
    /// `startWriting()`.
    private func setupTimecodeTrack(on writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        var tcFormat: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            frameQuanta: UInt32(frameRate),
            flags: 0,
            extensions: nil,
            formatDescriptionOut: &tcFormat
        )
        guard status == noErr, let tcFormat else { return }
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        if videoInput.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue) {
            videoInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
        }
        timecodeInput = input
        timecodeFormat = tcFormat
        hasTimecodeInput = true

        let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        let seconds = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        let subFrame = Int(Double(comps.nanosecond ?? 0) / 1_000_000_000.0 * Double(frameRate))
        timecodeStartFrame = seconds * frameRate + subFrame
    }

    // MARK: - Growing-file CFR pump

    /// Stash a private copy of the latest screen frame so SCStream can recycle
    /// its buffer immediately (we re-append our copy from the CFR timer).
    private func storeLatestFrame(_ imageBuffer: CVImageBuffer) {
        guard let copy = copyIntoPool(imageBuffer) else { return }
        bufferLock.lock()
        latestPixelBuffer = copy
        bufferLock.unlock()
    }

    private func copyIntoPool(_ source: CVImageBuffer) -> CVPixelBuffer? {
        if copyPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(source),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            copyPool = pool
        }
        guard let pool = copyPool else { return nil }
        var destinationOptional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationOptional) == kCVReturnSuccess,
              let destination = destinationOptional else {
            return nil
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            if let src = CVPixelBufferGetBaseAddress(source),
               let dst = CVPixelBufferGetBaseAddress(destination) {
                let rowBytes = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination))
                let height = CVPixelBufferGetHeight(source)
                let srcBpr = CVPixelBufferGetBytesPerRow(source)
                let dstBpr = CVPixelBufferGetBytesPerRow(destination)
                for row in 0..<height { memcpy(dst + row * dstBpr, src + row * srcBpr, rowBytes) }
            }
        } else {
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                let srcBpr = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBpr = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rowBytes = min(srcBpr, dstBpr)
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                for row in 0..<height { memcpy(dst + row * dstBpr, src + row * srcBpr, rowBytes) }
            }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func startCFRPump() {
        let interval = 1.0 / Double(frameRate)
        let timer = DispatchSource.makeTimerSource(queue: cfrQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pumpTick() }
        cfrTimer = timer
        timer.resume()
    }

    private func stopCFRPump() {
        cfrTimer?.cancel()
        cfrTimer = nil
        // Drain any in-flight tick so nothing appends after markAsFinished().
        cfrQueue.sync { }
        bufferLock.lock()
        latestPixelBuffer = nil
        bufferLock.unlock()
    }

    /// Emit duplicate frames up to the current host-clock position so the file
    /// is constant-frame-rate even while the screen is static.
    private func pumpTick() {
        guard !finished, writeError == nil else { return }
        guard let videoInput, let adaptor = pixelBufferAdaptor else { return }
        bufferLock.lock()
        let buffer = latestPixelBuffer
        bufferLock.unlock()
        guard let buffer else { return }   // no frame captured yet

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(hostClock), sessionStartPTS))
        guard elapsed.isFinite, elapsed >= 0 else { return }
        let targetIndex = Int(elapsed * Double(frameRate))

        while emittedFrameIndex <= targetIndex {
            guard writeError == nil else { return }
            guard videoInput.isReadyForMoreMediaData else { break }  // backpressure: retry next tick
            let pts = CMTimeAdd(
                sessionStartPTS,
                CMTime(value: CMTimeValue(emittedFrameIndex), timescale: CMTimeScale(frameRate))
            )
            if adaptor.append(buffer, withPresentationTime: pts) {
                if videoSampleCount == 0 { logger.info("First video frame emitted (CFR).") }
                videoSampleCount += 1
                appendTimecode(frameIndex: emittedFrameIndex)
                emittedFrameIndex += 1
            } else {
                recordError(writer?.error ?? CaptureWriterError.videoAppendFailed)
                return
            }
        }
    }

    private func appendTimecode(frameIndex: Int) {
        guard hasTimecodeInput, let input = timecodeInput, let format = timecodeFormat,
              input.isReadyForMoreMediaData else { return }
        var frameNumber = UInt32(truncatingIfNeeded: timecodeStartFrame + frameIndex).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { return }
        let copied = withUnsafeBytes(of: &frameNumber) { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: 4) == noErr
        }
        guard copied else { return }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
            presentationTimeStamp: CMTimeAdd(
                sessionStartPTS,
                CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(frameRate))
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 4
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { return }
        input.append(sample)
    }

    // MARK: - Growing-file xattr (DaVinci Resolve trigger)

    private func setRecordingXattr() {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let json = "{\"r\":1, \"uuid\":\"\(uuid)\"}"
        let bytes = Array(json.utf8)
        let result = bytes.withUnsafeBytes { raw in
            setxattr(outputURL.path, "com.blackmagicdesign.metadata:recording", raw.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 {
            logger.warning("Failed to set growing-file xattr (errno \(errno, privacy: .public)).")
        }
    }

    private func clearRecordingXattr() {
        removexattr(outputURL.path, "com.blackmagicdesign.metadata:recording", 0)
    }

    private func recordError(_ error: Error) {
        writeError = error
        let nsError = error as NSError
        logger.error("Capture writer error: \(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .public)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("Underlying error: \(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public) \(underlying.localizedDescription, privacy: .public)")
        }
        errorHandler?(error)
    }

    private func applyColorAttachments(
        to imageBuffer: CVImageBuffer,
        dynamicRange: CaptureDynamicRangeOption
    ) {
        switch dynamicRange {
        case .sdr:
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                "ColorRange" as CFString,
                "FullRange" as CFString,
                .shouldPropagate
            )
        case .hdrP3CanonicalDisplay:
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_P3_D65,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                "ColorRange" as CFString,
                "VideoRange" as CFString,
                .shouldPropagate
            )
        }
    }

    private enum CaptureWriterError: LocalizedError {
        case videoInputNotSupported
        case audioInputNotSupported
        case microphoneInputNotSupported
        case writerStartFailed
        case videoAppendFailed
        case audioAppendFailed
        case microphoneAppendFailed
        case noVideoFrames
        case videoBufferUnavailable

        var errorDescription: String? {
            switch self {
            case .videoInputNotSupported:
                return "Video input could not be added to the capture writer."
            case .audioInputNotSupported:
                return "Audio input could not be added to the capture writer."
            case .microphoneInputNotSupported:
                return "Microphone input could not be added to the capture writer."
            case .writerStartFailed:
                return "Failed to start the capture writer."
            case .videoAppendFailed:
                return "Failed to append video samples to the capture writer."
            case .audioAppendFailed:
                return "Failed to append audio samples to the capture writer."
            case .microphoneAppendFailed:
                return "Failed to append microphone samples to the capture writer."
            case .noVideoFrames:
                return "No video frames were captured. Check Screen Recording permission."
            case .videoBufferUnavailable:
                return "Video pixel buffer was unavailable for capture."
            }
        }
    }
}

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    let queue: DispatchQueue
    private let handler: (CMSampleBuffer, SCStreamOutputType) -> Void

    init(queue: DispatchQueue, handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handler(sampleBuffer, type)
    }
}
