// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Real-time FFT frequency band analyzer for audio visualization.
// Processes raw Float32 audio samples and outputs per-band magnitudes.

import Foundation
import Accelerate

/// Performs real-time FFT on audio buffers and outputs smoothed frequency band magnitudes.
/// Thread-safe: call `process(samples:)` from any thread; read `bands` from main thread.
final class AudioFrequencyAnalyzer: @unchecked Sendable {

    /// Current smoothed band magnitudes, normalized 0.0–1.0.
    private(set) var bands: [Float]

    private let bandCount: Int
    private let fftSize: Int = 4096
    private let sampleRate: Double = 48000
    private let smoothAttack: Float = 1.0    // Instant rise
    private let smoothDecay: Float = 0.88    // Slow release (~200ms half-life at 60fps)

    private let halfN: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var bandBinRanges: [(Int, Int)]

    // Rolling peak per band for normalization (decays slowly so visualization stays dynamic)
    private var rollingPeaks: [Float]
    private let peakDecay: Float = 0.9995    // Very slow decay for stable normalization

    // Reusable FFT buffers
    private var realp: [Float]
    private var imagp: [Float]
    private var inputBuffer: [Float]

    private let lock = NSLock()

    init(bandCount: Int = 32, frequencyDistribution: FrequencyDistribution = .logarithmic) {
        self.bandCount = bandCount
        self.halfN = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))!
        self.bands = [Float](repeating: 0, count: bandCount)
        self.rollingPeaks = [Float](repeating: 0.001, count: bandCount) // Small initial to avoid div-by-zero
        self.window = [Float](repeating: 0, count: fftSize)
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.inputBuffer = [Float](repeating: 0, count: fftSize)

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let bandEdges = WaveformPCMDecoder.computeBandEdges(distribution: frequencyDistribution, bandCount: bandCount)
        let binWidth = sampleRate / Double(fftSize)
        self.bandBinRanges = AudioFrequencyAnalyzer.computeBinRanges(bandEdges: bandEdges, bandCount: bandCount, halfN: halfN, binWidth: binWidth)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Reconfigure with new band count and distribution (e.g., when settings change).
    func reconfigure(bandCount: Int, frequencyDistribution: FrequencyDistribution) {
        lock.lock()
        defer { lock.unlock() }

        // Only rebuild if changed
        guard bandCount != self.bandCount else {
            let bandEdges = WaveformPCMDecoder.computeBandEdges(distribution: frequencyDistribution, bandCount: bandCount)
            let binWidth = sampleRate / Double(fftSize)
            bandBinRanges = AudioFrequencyAnalyzer.computeBinRanges(bandEdges: bandEdges, bandCount: bandCount, halfN: halfN, binWidth: binWidth)
            return
        }

        // Full reconfigure needed — create new instance instead
    }

    /// Process a buffer of raw Float32 audio samples. Call from audio processing thread.
    func process(samples: UnsafePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }

        // Use last fftSize samples (or zero-pad if fewer)
        let available = min(count, fftSize)
        let offset = max(0, count - fftSize)
        inputBuffer = [Float](repeating: 0, count: fftSize)
        for i in 0..<available {
            inputBuffer[i] = samples[offset + i]
        }

        // Apply Hann window
        vDSP_vmul(inputBuffer, 1, window, 1, &inputBuffer, 1, vDSP_Length(fftSize))

        // Run FFT
        var binMagnitudes = [Float](repeating: 0, count: halfN)
        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var splitComplex = DSPSplitComplex(
                    realp: rBuf.baseAddress!,
                    imagp: iBuf.baseAddress!
                )

                inputBuffer.withUnsafeBufferPointer { inBuf in
                    inBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexBuf in
                        vDSP_ctoz(complexBuf, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &binMagnitudes, 1, vDSP_Length(halfN))
            }
        }

        // Scale and sqrt
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(binMagnitudes, 1, &scale, &binMagnitudes, 1, vDSP_Length(halfN))
        var sqrtCount = Int32(halfN)
        vvsqrtf(&binMagnitudes, binMagnitudes, &sqrtCount)

        // Accumulate into bands
        var rawBands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let (startBin, endBin) = bandBinRanges[band]
            var sum: Float = 0
            var count = 0
            for bin in startBin...endBin {
                sum += binMagnitudes[bin]
                count += 1
            }
            rawBands[band] = count > 0 ? sum / Float(count) : 0
        }

        // Update rolling peaks for normalization
        for band in 0..<bandCount {
            rollingPeaks[band] = max(rawBands[band], rollingPeaks[band] * peakDecay)
        }

        // Normalize per-band and apply smoothing
        for band in 0..<bandCount {
            let normalized = rollingPeaks[band] > 0.0001 ? rawBands[band] / rollingPeaks[band] : 0
            let clamped = min(1.0, max(0.0, normalized))
            // Fast attack, slow release
            if clamped > bands[band] {
                bands[band] = clamped * smoothAttack
            } else {
                bands[band] = bands[band] * smoothDecay
            }
        }
    }

    /// Reset all bands to zero (e.g., when playback stops).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        bands = [Float](repeating: 0, count: bandCount)
        rollingPeaks = [Float](repeating: 0.001, count: bandCount)
    }

    // MARK: - Bin Mapping

    private static func computeBinRanges(bandEdges: [Double], bandCount: Int, halfN: Int, binWidth: Double) -> [(Int, Int)] {
        var ranges = [(Int, Int)](repeating: (0, 0), count: bandCount)
        for band in 0..<bandCount {
            let idealStart = Int(round(bandEdges[band] / binWidth))
            let idealEnd = Int(round(bandEdges[band + 1] / binWidth)) - 1
            var startBin = max(0, min(halfN - 1, idealStart))
            var endBin = max(0, min(halfN - 1, idealEnd))
            if endBin < startBin {
                let centerFreq = (bandEdges[band] + bandEdges[band + 1]) / 2.0
                let nearestBin = max(0, min(halfN - 1, Int(round(centerFreq / binWidth))))
                startBin = nearestBin
                endBin = nearestBin
            }
            ranges[band] = (startBin, endBin)
        }
        return ranges
    }
}
