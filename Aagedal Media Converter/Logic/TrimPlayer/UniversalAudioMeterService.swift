// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import Combine
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreMedia

/// Service to monitor real-time audio levels from the entire application using ScreenCaptureKit
@MainActor
final class UniversalAudioMeterService: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "UniversalAudioMeter")
    struct AudioLevels {
        let leftChannel: Float  // dB level, typically -60.0 to 0.0
        let rightChannel: Float // dB level, typically -60.0 to 0.0
        let peak: Float         // Peak level across all channels
        
        static let silence = AudioLevels(leftChannel: -60.0, rightChannel: -60.0, peak: -60.0)
    }
    
    @Published private(set) var currentLevels: AudioLevels = .silence
    @Published private(set) var isMonitoring = false
    @Published private(set) var permissionError: Bool = false
    /// Real-time frequency band magnitudes (0.0–1.0 per band). Nil when not monitoring.
    @Published private(set) var frequencyBands: [Float]?

    private var stream: SCStream?
    private let audioOutput = StreamOutput()

    override init() {
        super.init()
        // Load band settings and create analyzer
        let config = AudioWaveformPreferences.loadConfig()
        let analyzer = AudioFrequencyAnalyzer(
            bandCount: config.bandCount,
            frequencyDistribution: config.frequencyDistribution
        )
        audioOutput.frequencyAnalyzer = analyzer

        // Connect the output's level updates to our published property
        audioOutput.levelUpdateHandler = { [weak self] levels in
            Task { @MainActor [weak self] in
                self?.currentLevels = levels
            }
        }
        audioOutput.frequencyUpdateHandler = { [weak self] bands in
            Task { @MainActor [weak self] in
                self?.frequencyBands = bands
            }
        }
    }

    /// Reload frequency analyzer settings (call when user changes waveform settings).
    func reloadFrequencySettings() {
        let config = AudioWaveformPreferences.loadConfig()
        let analyzer = AudioFrequencyAnalyzer(
            bandCount: config.bandCount,
            frequencyDistribution: config.frequencyDistribution
        )
        audioOutput.frequencyAnalyzer = analyzer
    }
    
    /// Start monitoring app audio
    func startMonitoring() async {
        guard !isMonitoring else { return }
        
        do {
            // Create filter in a nonisolated context to avoid MainActor isolation issues with SCShareableContent
            let filter = try await createContentFilter()
            
            // Configure stream for audio only
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            // capturesVideo does not exist, use width/height/frameInterval to minimize video overhead
            config.width = 100
            config.height = 100
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = false // We WANT our own audio
            
            // Create and start stream
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            
            // Use explicit type for SCStreamOutputType
            try stream.addStreamOutput(audioOutput, type: SCStreamOutputType.audio, sampleHandlerQueue: audioOutput.queue)
            
            try await stream.startCapture()
            
            self.stream = stream
            self.isMonitoring = true
            self.permissionError = false
            
        } catch {
            Self.logger.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
            if error is SCStreamError {
                // Likely permission denied or cancelled
                self.permissionError = true
            }
        }
    }
    
    /// Helper to create content filter off the main actor
    nonisolated private func createContentFilter() async throws -> SCContentFilter {
        let content = try await SCShareableContent.current
        
        guard let myApp = content.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
            throw NSError(domain: "UniversalAudioMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find own application"])
        }
        
        guard let display = content.displays.first else {
             throw NSError(domain: "UniversalAudioMeter", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        
        // Explicitly type the array to help overload resolution
        let apps: [SCRunningApplication] = [myApp]
        return SCContentFilter(display: display, including: apps, exceptingWindows: [])
    }
    
    /// Stop monitoring
    func stopMonitoring() async {
        guard isMonitoring else { return }
        
        if let stream = stream {
            try? await stream.stopCapture()
        }
        
        stream = nil
        isMonitoring = false
        currentLevels = .silence
        frequencyBands = nil
        audioOutput.frequencyAnalyzer?.reset()
    }
}

// MARK: - Stream Output Processor

private class StreamOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "com.aagedal.audiometer.processing")
    var levelUpdateHandler: ((UniversalAudioMeterService.AudioLevels) -> Void)?
    var frequencyUpdateHandler: (([Float]) -> Void)?
    var frequencyAnalyzer: AudioFrequencyAnalyzer?

    private var leftPeak: Float = 0.0
    private var rightPeak: Float = 0.0
    private let floorLevel: Float = -60.0
    
    // Process audio buffers
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Extract audio samples
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let data = dataPointer else {
            return
        }
        
        // Assuming Float32 non-interleaved or interleaved depending on SCStream config
        // SCStream usually outputs Float32.
        // Let's assume standard 2-channel Float32 for simplicity or inspect format.
        // For robustness, we can just look at the raw bytes as Float32 and find max peak.
        // This is a simplification but works well for metering.
        
        let floatCount = totalLength / MemoryLayout<Float>.size
        let floats = data.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
        
        var localPeak: Float = 0.0
        for i in 0..<floatCount {
            localPeak = max(localPeak, abs(floats[i]))
        }
        
        // Decay and update
        // We do this on every buffer, but we should probably throttle updates to main thread
        // For now, let's just calculate peaks and update
        
        let db = amplitudeToDecibels(localPeak)
        
        // Simple mono-to-stereo mapping for now since we are just finding max peak in buffer
        // To do true stereo we need to know channel layout from format description
        
        let levels = UniversalAudioMeterService.AudioLevels(
            leftChannel: db,
            rightChannel: db,
            peak: db
        )
        
        levelUpdateHandler?(levels)

        // Run FFT for frequency band visualization
        if let analyzer = frequencyAnalyzer {
            analyzer.process(samples: floats, count: floatCount)
            frequencyUpdateHandler?(analyzer.bands)
        }
    }
    
    private func amplitudeToDecibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return floorLevel }
        let db = 20 * log10(amplitude)
        return max(db, floorLevel)
    }
}
