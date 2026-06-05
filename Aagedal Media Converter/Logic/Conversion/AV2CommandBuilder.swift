// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// Builds the command pair for the experimental AV2 export path.
///
/// AV2 is not supported by FFmpeg, so encoding runs as a two-process pipe:
///   ffmpeg (decode → y4m on stdout)  │  avmenc (y4m on stdin → .ivf)
///
/// `avmenc` requires the frame dimensions up front (it does not parse the y4m
/// header when reading from a pipe), so the final output width/height are
/// computed here and baked into an explicit `scale=W:H` on the ffmpeg side.
/// Because ffmpeg is forced to emit exactly those dimensions, the number handed
/// to `avmenc -w/-h` is guaranteed to match the frames it receives.
enum AV2CommandBuilder {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AV2CommandBuilder")

    struct AV2Command: Sendable {
        /// ffmpeg arguments that decode/trim/scale the source and write y4m to stdout (`pipe:1`).
        let ffmpegArguments: [String]
        /// avmenc arguments that read y4m from stdin (`-`) and write the `.ivf` output.
        let avmencArguments: [String]
        let outputWidth: Int
        let outputHeight: Int
        /// Trim-aware duration used to drive the progress parser. nil if unknown.
        let effectiveDuration: Double?
        /// Source frame rate used by the progress parser. nil if unknown.
        let frameRate: Double?
    }

    /// Builds the AV2 command pair. Returns nil if the source dimensions cannot be
    /// determined (in which case avmenc cannot be configured and the caller should fail).
    static func build(
        inputURL: URL,
        outputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?
    ) async -> AV2Command? {
        // MARK: Probe source

        guard let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL),
              let stream = metadata.primaryVideoStream,
              let srcW = stream.width, let srcH = stream.height,
              srcW > 0, srcH > 0 else {
            logger.error("AV2: could not determine source dimensions for \(inputURL.lastPathComponent, privacy: .public)")
            return nil
        }

        let dar = stream.displayAspectRatio?.doubleValue
        let par = stream.pixelAspectRatio?.doubleValue
        let frameRate = stream.frameRate?.value

        // MARK: Effective PAR (mirrors FFMPEGCommandBuilder's DAR-priority logic)

        let effectivePAR: Double
        if let dar, dar > 0 {
            let resolutionAspect = Double(srcW) / Double(srcH)
            let derivedPAR = dar / resolutionAspect
            if let par, par > 0 {
                effectivePAR = abs(derivedPAR - par) < 0.05 ? par : derivedPAR
            } else {
                effectivePAR = derivedPAR
            }
        } else if let par, par > 0 {
            effectivePAR = par
        } else {
            effectivePAR = 1.0
        }

        // MARK: Compute final (square-pixel) output dimensions

        // Pre-cap display-pixel dimensions: start from the (optionally cropped) coded
        // size, then desqueeze the width by the effective PAR so output pixels are square.
        let cropActive = (cropConfig?.isActive ?? false)
        let basePxW: Int
        let basePxH: Int
        if cropActive, let cropConfig {
            let rect = cropConfig.pixelRect(sourceWidth: srcW, sourceHeight: srcH).evenDimensions()
            basePxW = rect.width
            basePxH = rect.height
        } else {
            basePxW = srcW
            basePxH = srcH
        }

        var finalW = evenDimension(Double(basePxW) * effectivePAR)
        var finalH = evenDimension(Double(basePxH))

        // Orientation-aware short-edge cap, matching ExportPreset.desqueezeFilter(maxShortEdge:).
        let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.av2ResolutionLimitKey) ?? AppConstants.defaultAV2ResolutionLimit
        if let maxShortEdge = CodecResolutionLimit(rawValue: resolutionRaw)?.maxHeight {
            let shortEdge = min(finalW, finalH)
            if shortEdge > maxShortEdge {
                let factor = Double(maxShortEdge) / Double(shortEdge)
                finalW = evenDimension(Double(finalW) * factor)
                finalH = evenDimension(Double(finalH) * factor)
            }
        }

        // MARK: Resolve settings

        let bitDepthRaw = UserDefaults.standard.string(forKey: AppConstants.av2BitDepthKey) ?? AppConstants.defaultAV2BitDepth
        let bitDepth = (AV2BitDepthOption(rawValue: bitDepthRaw) ?? .auto).resolved(sourceBitDepth: stream.bitDepth)

        let rateModeRaw = UserDefaults.standard.string(forKey: AppConstants.av2RateControlModeKey) ?? AppConstants.defaultAV2RateControlMode
        let rateMode = AV2RateControlMode(rawValue: rateModeRaw) ?? .constantQuality

        let qp = intSetting(AppConstants.av2QualityKey, default: AppConstants.defaultAV2Quality)
        let targetBitrate = intSetting(AppConstants.av2TargetBitrateKey, default: AppConstants.defaultAV2TargetBitrate)
        // cpu-used 0 is a valid (slowest) value, so distinguish "unset" from 0 explicitly.
        let speed = intSetting(AppConstants.av2SpeedKey, default: AppConstants.defaultAV2Speed)
        let tileColumns = intSetting(AppConstants.av2TileColumnsKey, default: AppConstants.defaultAV2TileColumns)
        let tileRows = intSetting(AppConstants.av2TileRowsKey, default: AppConstants.defaultAV2TileRows)
        let threadsSetting = intSetting(AppConstants.av2ThreadsKey, default: AppConstants.defaultAV2Threads)
        let threads = threadsSetting > 0 ? threadsSetting : ProcessInfo.processInfo.activeProcessorCount

        // MARK: Effective duration (trim-aware) for progress

        let effectiveDuration: Double?
        if let trimStart, let trimEnd, trimEnd > trimStart {
            effectiveDuration = trimEnd - trimStart
        } else if let trimEnd, trimEnd > 0, trimStart == nil {
            effectiveDuration = trimEnd
        } else if let streamDuration = stream.duration {
            effectiveDuration = streamDuration
        } else {
            effectiveDuration = await FFMPEGProbeService.getVideoDuration(for: inputURL)
        }

        // MARK: ffmpeg decode → y4m

        var ffmpeg: [String] = ["-y", "-nostdin", "-progress", "pipe:2", "-hide_banner"]
        if let trimStart, trimStart > 0 {
            ffmpeg += ["-ss", String(format: "%.6f", trimStart)]
        }
        ffmpeg += ["-i", inputURL.path]
        if let trimStart, let trimEnd, trimEnd > trimStart {
            ffmpeg += ["-t", String(format: "%.6f", trimEnd - trimStart)]
        } else if let trimEnd, trimEnd > 0, trimStart == nil {
            ffmpeg += ["-t", String(format: "%.6f", trimEnd)]
        }

        // Video filter chain: crop (optional) then an explicit forced scale so the emitted
        // frame size exactly equals avmenc's -w/-h.
        var filterChain = "scale=\(finalW):\(finalH),setsar=1"
        if cropActive, let cropConfig,
           let cropFilter = CropService.buildCropFilter(config: cropConfig, sourceWidth: srcW, sourceHeight: srcH) {
            filterChain = "\(cropFilter),scale=\(finalW):\(finalH),setsar=1"
        }

        ffmpeg += ["-map", "0:v:0", "-an", "-sn", "-dn"]
        ffmpeg += ["-vf", filterChain]
        ffmpeg += ["-pix_fmt", bitDepth >= 10 ? "yuv420p10le" : "yuv420p"]
        ffmpeg += ["-f", "yuv4mpegpipe", "-strict", "-1", "pipe:1"]

        // MARK: avmenc encode

        var avmenc: [String] = ["--ivf", "-w", "\(finalW)", "-h", "\(finalH)"]
        avmenc += ["-b", "\(bitDepth)", "--input-bit-depth=\(bitDepth)", "--i420"]
        if let fr = stream.frameRate, fr.numerator > 0, fr.denominator > 0 {
            // y4m carries fps, but avmenc won't read the header from a pipe — pass it explicitly
            // so the IVF timebase/framerate is correct.
            avmenc += ["--fps=\(fr.numerator)/\(fr.denominator)"]
        }
        switch rateMode {
        case .constantQuality:
            avmenc += ["--end-usage=q", "--qp=\(clampQP(qp))"]
        case .targetBitrate:
            avmenc += ["--end-usage=vbr", "--target-bitrate=\(max(1, targetBitrate))"]
        }
        avmenc += ["--cpu-used=\(min(max(speed, 0), 9))"]
        avmenc += ["-t", "\(max(1, threads))"]
        // AVM only parallelizes across tiles, so an untiled encode is effectively single-threaded
        // no matter how many threads are allowed. When the user leaves tiling on "auto" (0), pick
        // tile counts from the frame size to spread work across cores — the dominant speed lever
        // (measured ~30% faster on this hardware). Explicit user values are respected as-is.
        let effectiveTileColumns = tileColumns > 0 ? tileColumns : autoTileLog2(finalW, maxLog2: 3)
        let effectiveTileRows = tileRows > 0 ? tileRows : autoTileLog2(finalH, maxLog2: 2)
        if effectiveTileColumns > 0 { avmenc += ["--tile-columns=\(effectiveTileColumns)"] }
        if effectiveTileRows > 0 { avmenc += ["--tile-rows=\(effectiveTileRows)"] }
        avmenc += ["-o", outputURL.path, "-"]

        logger.info("AV2 dims \(finalW)x\(finalH), \(bitDepth)-bit, mode=\(rateMode.rawValue, privacy: .public)")

        return AV2Command(
            ffmpegArguments: ffmpeg,
            avmencArguments: avmenc,
            outputWidth: finalW,
            outputHeight: finalH,
            effectiveDuration: effectiveDuration,
            frameRate: frameRate
        )
    }

    // MARK: - Helpers

    /// Rounds to the nearest even integer (codec requirement), with a floor of 2.
    private static func evenDimension(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        let even = (rounded / 2) * 2
        return max(2, even)
    }

    /// Chooses an automatic tile count (as a log2 exponent) for one axis, large enough to
    /// spread work across cores while keeping each tile at least ~256 px on that axis so
    /// compression efficiency isn't wrecked by over-fragmentation. Capped at `maxLog2`.
    /// Examples (columns, maxLog2 3): 640→1 (2 cols), 1280→2 (4), 1920→2 (4), 3840→3 (8).
    private static func autoTileLog2(_ dimension: Int, maxLog2: Int) -> Int {
        var log2 = 0
        while log2 < maxLog2 && (dimension >> (log2 + 1)) >= 256 {
            log2 += 1
        }
        return log2
    }

    /// avmenc `--qp` accepts [0, 255] for 8-bit input; keep the user value in range.
    private static func clampQP(_ qp: Int) -> Int {
        min(max(qp, 0), 255)
    }

    /// Reads an Int setting, returning `def` when the key has never been written
    /// (so a legitimate stored value of 0 is preserved, unlike `UserDefaults.integer`).
    private static func intSetting(_ key: String, default def: Int) -> Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil ? def : defaults.integer(forKey: key)
    }
}
