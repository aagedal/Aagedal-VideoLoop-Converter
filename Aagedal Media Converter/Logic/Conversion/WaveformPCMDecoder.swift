// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Decodes audio to raw PCM via FFmpeg, then computes per-frame frequency band
// magnitudes using Accelerate vDSP FFT for the native waveform video renderer.

import Foundation
import Accelerate
import OSLog

/// Per-frame frequency band magnitude data for driving the capsule visualizer.
struct FrequencyBandData: Sendable {
    let bandCount: Int
    let frameCount: Int
    /// magnitudes[frameIndex][bandIndex], each value in 0.0–1.0.
    let magnitudes: [[Float]]
    let totalDuration: Double
}

enum WaveformPCMDecoder {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformPCMDecoder")

    /// Sample rate used for FFT analysis (48 kHz for good frequency resolution).
    private static let analysisRate = 48000
    /// FFT window size: 4096 samples ≈ 85 ms at 48 kHz.
    private static let fftSize = 4096
    /// Number of frequency bands for the capsule visualizer.
    static let defaultBandCount = 32
    /// Lowest frequency edge (Hz).
    private static let minFrequency: Double = 20
    /// Highest frequency edge (Hz).
    private static let maxFrequency: Double = 20000

    // MARK: - Public API

    /// Decodes audio and computes frequency-band magnitudes for every video frame.
    ///
    /// - Parameters:
    ///   - url: Input audio file.
    ///   - ffmpegPath: Path to the FFmpeg binary.
    ///   - frameRate: Video frame rate (determines FFT hop size).
    ///   - duration: Total audio duration in seconds (after trim).
    ///   - bandCount: Number of frequency bands (default 32).
    ///   - normalizeAudio: Apply dynamic normalization during decode.
    ///   - audioRoutingConfig: Optional channel routing applied during decode.
    ///   - trimStart: Optional trim start in seconds.
    ///   - trimEnd: Optional trim end in seconds.
    /// - Returns: ``FrequencyBandData`` with magnitudes for each frame.
    static func decode(
        url: URL,
        ffmpegPath: String,
        frameRate: Double,
        duration: Double,
        bandCount: Int = defaultBandCount,
        normalizeAudio: Bool = false,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        trimStart: Double? = nil,
        trimEnd: Double? = nil
    ) async throws -> FrequencyBandData {
        // 1. Decode audio to mono PCM temp file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.aagedal.MediaConverter.pcmdecode.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pcmFile = tempDir.appendingPathComponent("audio.raw")

        let arguments = buildDecodeArguments(
            url: url,
            outputPath: pcmFile.path,
            normalizeAudio: normalizeAudio,
            audioRoutingConfig: audioRoutingConfig,
            trimStart: trimStart,
            trimEnd: trimEnd
        )

        try await runFFmpeg(path: ffmpegPath, arguments: arguments)
        try Task.checkCancellation()

        // 2. Read PCM data
        let pcmData = try Data(contentsOf: pcmFile)
        let totalSamples = pcmData.count / MemoryLayout<Float>.size
        guard totalSamples > 0 else {
            throw WaveformPCMDecoderError.noAudioSamples
        }

        // 3. Compute frequency bands via FFT
        let bandEdges = computeLogBandEdges(bandCount: bandCount)
        let hopSize = Int(Double(analysisRate) / frameRate)
        let frameCount = max(1, Int(ceil(duration * frameRate)))

        let magnitudes = try computeFrequencyBands(
            pcmData: pcmData,
            totalSamples: totalSamples,
            hopSize: hopSize,
            frameCount: frameCount,
            bandEdges: bandEdges,
            bandCount: bandCount
        )

        try Task.checkCancellation()

        return FrequencyBandData(
            bandCount: bandCount,
            frameCount: frameCount,
            magnitudes: magnitudes,
            totalDuration: duration
        )
    }

    // MARK: - FFmpeg Decode Arguments

    private static func buildDecodeArguments(
        url: URL,
        outputPath: String,
        normalizeAudio: Bool,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?
    ) -> [String] {
        var args: [String] = ["-hide_banner", "-loglevel", "error"]

        // Trim start (seek before input for efficiency)
        if let trimStart, trimStart > 0.01 {
            args.append(contentsOf: ["-ss", String(format: "%.6f", trimStart)])
        }

        args.append(contentsOf: ["-i", url.path])

        // Trim duration
        if let trimStart, let trimEnd, trimEnd > trimStart {
            let duration = trimEnd - trimStart
            args.append(contentsOf: ["-t", String(format: "%.6f", duration)])
        } else if let trimEnd, trimEnd > 0 {
            if trimStart == nil || trimStart! <= 0.01 {
                args.append(contentsOf: ["-t", String(format: "%.6f", trimEnd)])
            }
        }

        args.append("-vn")  // No video

        // Audio routing filter for decode (pick the right channels/tracks for analysis)
        var audioFilters: [String] = []

        if let routingConfig = audioRoutingConfig, let operation = routingConfig.channelOperation {
            // Apply channel routing during decode
            switch operation {
            case .mergeToStereo(let trackIndices):
                if trackIndices.count >= 2 {
                    let inputs = trackIndices.map { "[0:a:\($0)]" }.joined()
                    let mergeFilter = "\(inputs)amerge=inputs=\(trackIndices.count),pan=mono|c0<c0+c1[pcm]"
                    args.append(contentsOf: ["-filter_complex", mergeFilter, "-map", "[pcm]"])
                } else {
                    args.append(contentsOf: ["-map", "0:a:0", "-ac", "1"])
                }
            case .swapChannels(let trackIndex):
                args.append(contentsOf: ["-map", "0:a:\(trackIndex)", "-ac", "1"])
            case .extractChannel(let trackIndex, let channelIndex, _):
                let filter = "[0:a:\(trackIndex)]pan=mono|c0=c\(channelIndex)[pcm]"
                args.append(contentsOf: ["-filter_complex", filter, "-map", "[pcm]"])
            case .splitToMono:
                // splitToMono shouldn't reach here (incompatible with waveform), but handle gracefully
                args.append(contentsOf: ["-map", "0:a:0", "-ac", "1"])
            }
        } else if let routingConfig = audioRoutingConfig, !routingConfig.outputTrackIndices.isEmpty {
            // Simple track selection — use first selected track
            args.append(contentsOf: ["-map", "0:a:\(routingConfig.outputTrackIndices[0])", "-ac", "1"])
        } else {
            // Default: first audio stream, downmix to mono
            args.append(contentsOf: ["-ac", "1"])
        }

        // Audio processing filters (applied after routing)
        audioFilters.append("aresample=\(analysisRate)")
        if normalizeAudio {
            audioFilters.append("dynaudnorm=f=250:g=30:p=0.9")
        }

        // If we didn't use -filter_complex for routing, apply audio filters via -af
        if !args.contains("-filter_complex") {
            args.append(contentsOf: ["-af", audioFilters.joined(separator: ",")])
        } else {
            // Routing used filter_complex; we need to chain audio filters
            // Find the filter_complex argument and append our filters
            if let fcIdx = args.firstIndex(of: "-filter_complex"), fcIdx + 1 < args.count {
                // Replace [pcm] output label with audio processing chain
                var fc = args[fcIdx + 1]
                if fc.hasSuffix("[pcm]") {
                    fc = fc.replacingOccurrences(of: "[pcm]", with: ",\(audioFilters.joined(separator: ","))[pcm]")
                    args[fcIdx + 1] = fc
                }
            }
        }

        // Output format: mono float32 PCM
        args.append(contentsOf: [
            "-f", "f32le",
            "-c:a", "pcm_f32le",
            "-ar", "\(analysisRate)",
            "-y", outputPath
        ])

        return args
    }

    // MARK: - FFT Computation

    /// Computes logarithmically-spaced band edges from minFrequency to maxFrequency.
    private static func computeLogBandEdges(bandCount: Int) -> [Double] {
        var edges = [Double](repeating: 0, count: bandCount + 1)
        let logMin = log2(minFrequency)
        let logMax = log2(maxFrequency)
        for i in 0...bandCount {
            edges[i] = pow(2.0, logMin + (logMax - logMin) * Double(i) / Double(bandCount))
        }
        return edges
    }

    /// Runs FFT on each hop position and groups bins into frequency bands.
    private static func computeFrequencyBands(
        pcmData: Data,
        totalSamples: Int,
        hopSize: Int,
        frameCount: Int,
        bandEdges: [Double],
        bandCount: Int
    ) throws -> [[Float]] {
        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw WaveformPCMDecoderError.fftSetupFailed
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let halfN = fftSize / 2
        let binWidth = Double(analysisRate) / Double(fftSize)

        // Precompute which FFT bins map to which band
        let binToBand = precomputeBinMapping(bandEdges: bandEdges, bandCount: bandCount, halfN: halfN, binWidth: binWidth)

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: bandCount), count: frameCount)

        // Track global peak for normalization
        var globalPeak: Float = 0

        pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Float.self)

            // Temp buffers
            var windowed = [Float](repeating: 0, count: fftSize)
            var realp = [Float](repeating: 0, count: halfN)
            var imagp = [Float](repeating: 0, count: halfN)

            for frame in 0..<frameCount {
                let center = frame * hopSize
                let start = max(0, center - fftSize / 2)
                let available = min(fftSize, totalSamples - start)

                // Zero-pad if not enough samples
                windowed = [Float](repeating: 0, count: fftSize)
                for i in 0..<available {
                    windowed[i] = samples[start + i]
                }

                // Apply window
                vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

                // Pack into split complex and run FFT
                var binMagnitudes = [Float](repeating: 0, count: halfN)
                realp.withUnsafeMutableBufferPointer { rBuf in
                    imagp.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(
                            realp: rBuf.baseAddress!,
                            imagp: iBuf.baseAddress!
                        )

                        // ctoz: interleaved -> split complex
                        windowed.withUnsafeBufferPointer { windowedBuf in
                            windowedBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexBuf in
                                vDSP_ctoz(complexBuf, 2, &splitComplex, 1, vDSP_Length(halfN))
                            }
                        }

                        // Forward FFT
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                        // Compute magnitudes (squared) for each bin
                        vDSP_zvmags(&splitComplex, 1, &binMagnitudes, 1, vDSP_Length(halfN))
                    }
                }

                // Scale
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(binMagnitudes, 1, &scale, &binMagnitudes, 1, vDSP_Length(halfN))

                // sqrt to get magnitude (not squared)
                var count = Int32(halfN)
                vvsqrtf(&binMagnitudes, binMagnitudes, &count)

                // Accumulate into bands
                var bandSums = [Float](repeating: 0, count: bandCount)
                var bandCounts = [Int](repeating: 0, count: bandCount)

                for bin in 0..<halfN {
                    let band = binToBand[bin]
                    if band >= 0 && band < bandCount {
                        bandSums[band] += binMagnitudes[bin]
                        bandCounts[band] += 1
                    }
                }

                // Average each band
                for band in 0..<bandCount {
                    if bandCounts[band] > 0 {
                        magnitudes[frame][band] = bandSums[band] / Float(bandCounts[band])
                    }
                    globalPeak = max(globalPeak, magnitudes[frame][band])
                }
            }
        }

        // Normalize all magnitudes to 0.0–1.0 relative to global peak
        if globalPeak > 0 {
            for frame in 0..<frameCount {
                for band in 0..<bandCount {
                    magnitudes[frame][band] /= globalPeak
                }
            }
        }

        return magnitudes
    }

    /// Precomputes which FFT bin maps to which frequency band.
    private static func precomputeBinMapping(bandEdges: [Double], bandCount: Int, halfN: Int, binWidth: Double) -> [Int] {
        var mapping = [Int](repeating: -1, count: halfN)
        for bin in 0..<halfN {
            let freq = Double(bin) * binWidth
            for band in 0..<bandCount {
                if freq >= bandEdges[band] && freq < bandEdges[band + 1] {
                    mapping[bin] = band
                    break
                }
            }
        }
        return mapping
    }

    // MARK: - FFmpeg Process

    private static func runFFmpeg(path: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe

            process.terminationHandler = { terminatedProcess in
                if terminatedProcess.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else if terminatedProcess.terminationReason == .uncaughtSignal
                            || terminatedProcess.terminationStatus == 15 {
                    continuation.resume(throwing: CancellationError())
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown ffmpeg error"
                    continuation.resume(throwing: WaveformPCMDecoderError.decodeFailed(
                        message.trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

enum WaveformPCMDecoderError: Error, LocalizedError {
    case noAudioSamples
    case fftSetupFailed
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioSamples:
            return "No audio samples decoded from input file"
        case .fftSetupFailed:
            return "Failed to create FFT setup"
        case .decodeFailed(let message):
            return "FFmpeg decode failed: \(message)"
        }
    }
}
