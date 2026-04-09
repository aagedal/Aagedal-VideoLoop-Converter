//
//  ExportPreset.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import CoreGraphics

enum ProResProfile: String, CaseIterable, Identifiable {
    case proxy = "Proxy"
    case lt = "LT"
    case standard = "422"
    case hq = "HQ"
    case fourFourFourFour = "4444"
    case fourFourFourFourXQ = "4444 XQ"

    var id: String { rawValue }

    var ffmpegProfileName: String {
        switch self {
        case .proxy: return "proxy"
        case .lt: return "lt"
        case .standard: return "standard"
        case .hq: return "hq"
        case .fourFourFourFour: return "4444"
        case .fourFourFourFourXQ: return "xq"
        }
    }
}

/// Format options for the Animated Still preset
enum AnimatedStillFormat: String, CaseIterable, Identifiable {
    case avif = "AVIF"
    case gif = "GIF"
    case apng = "APNG"
    case jpegXL = "JPEG XL"
    case webp = "WebP"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .avif: return "avif"
        case .gif: return "gif"
        case .apng: return "apng"
        case .jpegXL: return "jxl"
        case .webp: return "webp"
        }
    }

    /// Available formats for the picker (excludes formats not supported by bundled FFMPEG)
    static var availableCases: [AnimatedStillFormat] {
        // WebP is excluded because bundled FFMPEG lacks libwebp encoder
        // JPEG XL is excluded because bundled FFMPEG lacks animated JXL muxer (has encoder but no muxer)
        allCases.filter { $0 != .webp && $0 != .jpegXL }
    }
}

/// Framerate mode options for TV preset
enum TVFramerateMode: String, CaseIterable, Identifiable {
    case source = "Source"
    case p25 = "25p"
    case p50 = "50p"
    case i50 = "50i"
    case p2997 = "29.97p"
    case p5994 = "59.94p"
    case i5994 = "59.94i"

    var id: String { rawValue }

    var ffmpegArgs: [String] {
        switch self {
        case .source:
            return []
        case .p25:
            return ["-r", "25"]
        case .p50:
            return ["-r", "50"]
        case .i50:
            return ["-flags", "+ilme+ildct", "-r", "50", "-vf", "tinterlace=interleave_top,fieldorder=tff"]
        case .p2997:
            return ["-r", "30000/1001"]
        case .p5994:
            return ["-r", "60000/1001"]
        case .i5994:
            return ["-flags", "+ilme+ildct", "-r", "60000/1001", "-vf", "tinterlace=interleave_top,fieldorder=tff"]
        }
    }

    var isInterlaced: Bool {
        switch self {
        case .i50, .i5994:
            return true
        default:
            return false
        }
    }
}

/// Resolution limit options for TV preset
enum TVResolutionLimit: String, CaseIterable, Identifiable {
    case r720 = "720p"
    case r1080 = "1080p"
    case r2160 = "4K (2160p)"
    case unlimited = "Unlimited"

    var id: String { rawValue }

    var maxHeight: Int? {
        switch self {
        case .r720: return 720
        case .r1080: return 1080
        case .r2160: return 2160
        case .unlimited: return nil
        }
    }

    var bitrate: String {
        switch self {
        case .r720: return "8M"
        case .r1080: return "18M"
        case .r2160: return "60M"
        case .unlimited: return "100M"
        }
    }
}

/// AVC-Intra class options for TV AVC-Intra preset
enum AVCIntraClass: String, CaseIterable, Identifiable {
    case class50 = "AVC-Intra 50"
    case class100 = "AVC-Intra 100"
    case class200 = "AVC-Intra 200"

    var id: String { rawValue }

    var bitrate: String {
        switch self {
        case .class50: return "50M"
        case .class100: return "100M"
        case .class200: return "200M"
        }
    }

    /// Returns the appropriate pixel format for each class
    var pixelFormat: String {
        switch self {
        case .class50: return "yuv422p10le"
        case .class100: return "yuv422p10le"
        case .class200: return "yuv422p10le"
        }
    }
}

/// Audio channel count options for AVC-Intra preset
enum AVCIntraAudioChannels: String, CaseIterable, Identifiable {
    case ch4 = "4 Channels"
    case ch8 = "8 Channels"
    case ch16 = "16 Channels"

    var id: String { rawValue }

    var count: Int {
        switch self {
        case .ch4: return 4
        case .ch8: return 8
        case .ch16: return 16
        }
    }
}

/// Container options for Stream Copy preset
enum StreamCopyContainer: String, CaseIterable, Identifiable {
    case keepCurrent = "Keep Current"
    case mov = "MOV"
    case mp4 = "MP4"
    case mkv = "MKV"

    var id: String { rawValue }

    var fileExtension: String? {
        switch self {
        case .keepCurrent: return nil
        case .mov: return "mov"
        case .mp4: return "mp4"
        case .mkv: return "mkv"
        }
    }
}

/// Codec options for Proxy preset
enum ProxyCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC"
    case prores = "ProRes"
    case dnxhd = "DNx"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .hevc: return "mov"
        case .prores: return "mov"
        case .dnxhd: return "mxf"
        }
    }
}

/// Resolution limit options for Proxy preset
enum ProxyResolutionLimit: String, CaseIterable, Identifiable {
    case r480 = "480p"
    case r720 = "720p"
    case r1080 = "1080p"
    case source = "Source"

    var id: String { rawValue }

    var maxHeight: Int? {
        switch self {
        case .r480: return 480
        case .r720: return 720
        case .r1080: return 1080
        case .source: return nil
        }
    }

    var bitrate: String {
        switch self {
        case .r480: return "2M"
        case .r720: return "4M"
        case .r1080: return "6M"
        case .source: return "10M"
        }
    }
}

// MARK: - Codec Preset Enums

/// Encoder type for H.264 preset
enum H264Encoder: String, CaseIterable, Identifiable {
    case hardware = "Hardware (VideoToolbox)"
    case software = "Software (libx264)"

    var id: String { rawValue }

    var ffmpegEncoder: String {
        switch self {
        case .hardware: return "h264_videotoolbox"
        case .software: return "libx264"
        }
    }
}

/// Encoder type for H.265 preset
enum H265Encoder: String, CaseIterable, Identifiable {
    case hardware = "Hardware (VideoToolbox)"
    case software = "Software (libx265)"

    var id: String { rawValue }

    var ffmpegEncoder: String {
        switch self {
        case .hardware: return "hevc_videotoolbox"
        case .software: return "libx265"
        }
    }
}

/// Container format options for codec presets
enum CodecContainer: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case mov = "MOV"
    case mkv = "MKV"

    var id: String { rawValue }

    var fileExtension: String { rawValue.lowercased() }
}

/// Encoding speed/effort presets for software encoders (x264/x265)
enum EncodingSpeed: String, CaseIterable, Identifiable {
    case ultrafast = "Ultrafast"
    case superfast = "Superfast"
    case veryfast = "Veryfast"
    case faster = "Faster"
    case fast = "Fast"
    case medium = "Medium"
    case slow = "Slow"
    case slower = "Slower"
    case veryslow = "Veryslow"

    var id: String { rawValue }

    var ffmpegPreset: String { rawValue.lowercased() }
}

/// Encoding speed for AV1 (SVT-AV1 uses 0-13 scale)
enum AV1EncodingSpeed: Int, CaseIterable, Identifiable {
    case preset0 = 0
    case preset1 = 1
    case preset2 = 2
    case preset3 = 3
    case preset4 = 4
    case preset5 = 5
    case preset6 = 6
    case preset7 = 7
    case preset8 = 8
    case preset9 = 9
    case preset10 = 10
    case preset11 = 11
    case preset12 = 12
    case preset13 = 13

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .preset0: return "0 (Slowest)"
        case .preset6: return "6 (Balanced)"
        case .preset13: return "13 (Fastest)"
        default: return "\(rawValue)"
        }
    }
}

/// Tune mode for AV1 (SVT-AV1)
enum AV1TuneMode: String, CaseIterable, Identifiable {
    case vq = "Default"
    case subjective = "Subjective Quality"
    case ssim = "SSIM"
    case psnr = "PSNR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vq: return "Default (VQ)"
        case .subjective: return "Subjective Quality"
        case .ssim: return "SSIM"
        case .psnr: return "PSNR"
        }
    }

    /// SVT-AV1 tune parameter value, nil for default (VQ, tune=0)
    var svtav1Value: Int? {
        switch self {
        case .vq: return nil
        case .psnr: return 1
        case .ssim: return 2
        case .subjective: return 3
        }
    }
}

/// Film grain synthesis level for AV1 (SVT-AV1)
enum AV1FilmGrainLevel: String, CaseIterable, Identifiable {
    case off = "Off"
    case veryLight = "Very Light (4)"
    case light = "Light (8)"
    case medium = "Medium (16)"
    case strong = "Strong (24)"
    case heavy = "Heavy (32)"
    case veryHeavy = "Very Heavy (50)"

    var id: String { rawValue }

    var value: Int {
        switch self {
        case .off: return 0
        case .veryLight: return 4
        case .light: return 8
        case .medium: return 16
        case .strong: return 24
        case .heavy: return 32
        case .veryHeavy: return 50
        }
    }
}

/// Sharpness level for AV1 (SVT-AV1)
enum AV1Sharpness: String, CaseIterable, Identifiable {
    case off = "Off"
    case s1 = "1 (Subtle)"
    case s2 = "2 (Light)"
    case s3 = "3 (Medium)"
    case s4 = "4 (Strong)"

    var id: String { rawValue }

    var value: Int {
        switch self {
        case .off: return 0
        case .s1: return 1
        case .s2: return 2
        case .s3: return 3
        case .s4: return 4
        }
    }
}

/// Variance boost strength for AV1 (SVT-AV1)
enum AV1VarianceBoost: String, CaseIterable, Identifiable {
    case off = "Off"
    case light = "Light (1)"
    case medium = "Medium (2)"
    case strong = "Strong (3)"
    case veryStrong = "Very Strong (4)"

    var id: String { rawValue }

    var value: Int {
        switch self {
        case .off: return 0
        case .light: return 1
        case .medium: return 2
        case .strong: return 3
        case .veryStrong: return 4
        }
    }
}

/// Variance boost curve for AV1 (SVT-AV1)
enum AV1VarianceBoostCurve: String, CaseIterable, Identifiable {
    case linear = "Linear (0)"
    case moderate = "Moderate (1)"
    case aggressive = "Aggressive (2)"

    var id: String { rawValue }

    var value: Int {
        switch self {
        case .linear: return 0
        case .moderate: return 1
        case .aggressive: return 2
        }
    }
}

/// Resolution limit for codec presets
enum CodecResolutionLimit: String, CaseIterable, Identifiable {
    case r720 = "720p"
    case r1080 = "1080p"
    case r1440 = "1440p"
    case r2160 = "4K (2160p)"
    case unlimited = "Unlimited"

    var id: String { rawValue }

    var maxHeight: Int? {
        switch self {
        case .r720: return 720
        case .r1080: return 1080
        case .r1440: return 1440
        case .r2160: return 2160
        case .unlimited: return nil
        }
    }
}

/// Quality level for CRF-based encoding (x264/x265)
enum CodecQualityLevel: String, CaseIterable, Identifiable {
    case nearLossless = "Near Lossless (8)"
    case veryHigh = "Very High (15)"
    case high = "High (18)"
    case aboveGood = "Above Good (20)"
    case good = "Good (23)"
    case belowGood = "Below Good (25)"
    case balanced = "Balanced (28)"
    case medium = "Medium (32)"
    case low = "Low (38)"
    case veryLow = "Very Low (45)"

    var id: String { rawValue }

    var crfValue: Int {
        switch self {
        case .nearLossless: return 8
        case .veryHigh: return 15
        case .high: return 18
        case .aboveGood: return 20
        case .good: return 23
        case .belowGood: return 25
        case .balanced: return 28
        case .medium: return 32
        case .low: return 38
        case .veryLow: return 45
        }
    }
}

/// Quality level for AV1 (0-63 scale)
enum AV1QualityLevel: String, CaseIterable, Identifiable {
    case nearLossless = "Near Lossless (5)"
    case veryHigh = "Very High (15)"
    case high = "High (23)"
    case aboveGood = "Above Good (27)"
    case good = "Good (30)"
    case belowGood = "Below Good (33)"
    case balanced = "Balanced (35)"
    case medium = "Medium (40)"
    case low = "Low (50)"
    case veryLow = "Very Low (58)"

    var id: String { rawValue }

    var crfValue: Int {
        switch self {
        case .nearLossless: return 5
        case .veryHigh: return 15
        case .high: return 23
        case .aboveGood: return 27
        case .good: return 30
        case .belowGood: return 33
        case .balanced: return 35
        case .medium: return 40
        case .low: return 50
        case .veryLow: return 58
        }
    }
}

/// Audio codec options for codec presets
enum CodecAudioFormat: String, CaseIterable, Identifiable {
    case aac = "AAC"
    case pcm16 = "PCM 16-bit"
    case pcm24 = "PCM 24-bit"
    case pcm32 = "PCM 32-bit"
    case opus = "Opus"

    var id: String { rawValue }

    /// Returns available cases based on container format
    static func availableCases(for container: CodecContainer) -> [CodecAudioFormat] {
        switch container {
        case .mkv:
            return [.aac, .pcm16, .pcm24, .pcm32, .opus]
        case .mp4, .mov:
            return [.aac, .pcm16, .pcm24, .pcm32]
        }
    }

    func ffmpegArgs(bitrate: String) -> [String] {
        switch self {
        case .aac:
            // Preserve original channel layout - users can use per-track downmix in Audio Routing if needed
            return ["-c:a", "aac", "-b:a", bitrate]
        case .pcm16:
            return ["-c:a", "pcm_s16le"]
        case .pcm24:
            return ["-c:a", "pcm_s24le"]
        case .pcm32:
            return ["-c:a", "pcm_s32le"]
        case .opus:
            return ["-c:a", "libopus", "-b:a", bitrate]
        }
    }

    var requiresBitrate: Bool {
        switch self {
        case .aac, .opus: return true
        case .pcm16, .pcm24, .pcm32: return false
        }
    }
}

/// AAC/Opus bitrate options
enum AudioBitrate: String, CaseIterable, Identifiable {
    case k96 = "96 kbps"
    case k128 = "128 kbps"
    case k160 = "160 kbps"
    case k192 = "192 kbps"
    case k256 = "256 kbps"
    case k320 = "320 kbps"

    var id: String { rawValue }

    var ffmpegValue: String {
        switch self {
        case .k96: return "96k"
        case .k128: return "128k"
        case .k160: return "160k"
        case .k192: return "192k"
        case .k256: return "256k"
        case .k320: return "320k"
        }
    }
}

/// Output format options for the Audio Only preset
enum AudioOnlyFormat: String, CaseIterable, Identifiable {
    case wav = "WAV"
    case aac = "AAC (M4A)"
    case mp4 = "MP4"
    case flac = "FLAC"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav: return "wav"
        case .aac: return "m4a"
        case .mp4: return "mp4"
        case .flac: return "flac"
        }
    }

    /// WAV and FLAC containers support only a single audio stream
    var supportsSingleStreamOnly: Bool {
        switch self {
        case .wav, .flac: return true
        case .aac, .mp4: return false
        }
    }
}

/// PCM bit depth options for WAV output
enum AudioOnlyBitDepth: String, CaseIterable, Identifiable {
    case pcm16 = "16-bit"
    case pcm24 = "24-bit"
    case pcm32 = "32-bit"

    var id: String { rawValue }

    var ffmpegCodec: String {
        switch self {
        case .pcm16: return "pcm_s16le"
        case .pcm24: return "pcm_s24le"
        case .pcm32: return "pcm_s32le"
        }
    }
}

/// Audio codec options for MP4 audio-only output
enum AudioOnlyMP4Codec: String, CaseIterable, Identifiable {
    case aac = "AAC"
    case pcm16 = "PCM 16-bit"
    case pcm24 = "PCM 24-bit"
    case pcm32 = "PCM 32-bit"

    var id: String { rawValue }

    var requiresBitrate: Bool {
        self == .aac
    }

    var ffmpegCodec: String {
        switch self {
        case .aac: return "aac"
        case .pcm16: return "pcm_s16le"
        case .pcm24: return "pcm_s24le"
        case .pcm32: return "pcm_s32le"
        }
    }
}

enum ExportPreset: String, CaseIterable, Identifiable {
    case videoLoop = "VideoLoop"
    case videoLoopWithSound = "VideoLoop with sound"
    case animatedStill = "Animated Still"
    case h264 = "H.264 / AVC"
    case h265 = "H.265 / HEVC"
    case av1 = "AV1"
    case tvHEVC = "TV (HEVC 10-bit 4:2:2)"
    case tvAVCIntra = "TV (AVC-Intra MXF)"
    case prores = "ProRes"
    case proxy = "Proxy"
    case streamCopy = "Stream Copy"
    case audioOnly = "Audio Only"
    case imageSequence = "Image Sequence"
    case dcp = "DCP (Digital Cinema Package)"
    case custom1 = "Custom"
    case custom2 = "Custom 2"
    case custom3 = "Custom 3"
    case custom4 = "Custom 4"
    case custom5 = "Custom 5"
    case custom6 = "Custom 6"
    case custom7 = "Custom 7"
    case custom8 = "Custom 8"
    case custom9 = "Custom 9"
    case custom10 = "Custom 10"
    
    var id: String { rawValue }
    
    var fileExtension: String {
        switch self {
        case .videoLoop, .videoLoopWithSound:
            return "mp4"
        case .h264:
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.h264ContainerKey) ?? AppConstants.defaultH264Container
            return CodecContainer(rawValue: containerRaw)?.fileExtension ?? "mp4"
        case .h265:
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.h265ContainerKey) ?? AppConstants.defaultH265Container
            return CodecContainer(rawValue: containerRaw)?.fileExtension ?? "mp4"
        case .av1:
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.av1ContainerKey) ?? AppConstants.defaultAV1Container
            return CodecContainer(rawValue: containerRaw)?.fileExtension ?? "mp4"
        case .prores, .tvHEVC:
            return "mov"
        case .tvAVCIntra:
            return "mxf"
        case .proxy:
            let codecRaw = UserDefaults.standard.string(forKey: AppConstants.proxyCodecKey) ?? AppConstants.defaultProxyCodec
            let codec = ProxyCodec(rawValue: codecRaw) ?? .hevc
            return codec.fileExtension
        case .streamCopy:
            return "mp4"
        case .animatedStill:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.animatedStillFormatKey) ?? AppConstants.defaultAnimatedStillFormat
            let format = AnimatedStillFormat(rawValue: formatRaw) ?? .avif
            return format.fileExtension
        case .audioOnly:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyFormatKey) ?? AppConstants.defaultAudioOnlyFormat
            let format = AudioOnlyFormat(rawValue: formatRaw) ?? .wav
            return format.fileExtension
        case .imageSequence:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceExportFormatKey) ?? AppConstants.defaultImageSequenceExportFormat
            let format = ImageSequenceFormat(rawValue: formatRaw) ?? .png
            return format.primaryExtension
        case .dcp:
            return "mxf"
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = customSlotIndex else { return "mp4" }
            return Self.customFileExtension(for: slot)
        }
    }

    func outputExtension(for sourceURL: URL?) -> String {
        guard self == .streamCopy else {
            return fileExtension
        }

        // Check for manual container override
        let containerRaw = UserDefaults.standard.string(forKey: AppConstants.streamCopyContainerKey) ?? AppConstants.defaultStreamCopyContainer
        let container = StreamCopyContainer(rawValue: containerRaw) ?? .keepCurrent

        if let overrideExtension = container.fileExtension {
            return overrideExtension
        }

        // Keep source extension
        if let ext = sourceURL?.pathExtension, !ext.isEmpty {
            return ext.lowercased()
        }

        return fileExtension
    }
    
    var displayName: String {
        if let slot = customSlotIndex {
            return Self.customDisplayName(for: slot)
        }
        if self == .animatedStill {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.animatedStillFormatKey) ?? AppConstants.defaultAnimatedStillFormat
            let format = AnimatedStillFormat(rawValue: formatRaw) ?? .avif
            return "Animated Still (\(format.rawValue))"
        }
        if self == .imageSequence {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceExportFormatKey) ?? AppConstants.defaultImageSequenceExportFormat
            let format = ImageSequenceFormat(rawValue: formatRaw) ?? .png
            return "Image Sequence (\(format.rawValue))"
        }
        if self == .audioOnly {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyFormatKey) ?? AppConstants.defaultAudioOnlyFormat
            let format = AudioOnlyFormat(rawValue: formatRaw) ?? .wav
            return "Audio Only (\(format.rawValue))"
        }
        return rawValue
    }
    
    var description: String {
        switch self {
        case .videoLoop:
            return NSLocalizedString("PRESET_VIDEO_LOOP_DESCRIPTION", comment: "Description for VideoLoop preset")
        case .videoLoopWithSound:
            return NSLocalizedString("PRESET_VIDEO_LOOP_WITH_SOUND_DESCRIPTION", comment: "Description for VideoLoop with sound preset")
        case .h264:
            return NSLocalizedString("PRESET_H264_DESCRIPTION", comment: "Description for H.264 preset")
        case .h265:
            return NSLocalizedString("PRESET_H265_DESCRIPTION", comment: "Description for H.265 preset")
        case .av1:
            return NSLocalizedString("PRESET_AV1_DESCRIPTION", comment: "Description for AV1 preset")
        case .tvHEVC:
            return NSLocalizedString("PRESET_TV_HEVC_DESCRIPTION", comment: "Description for TV HEVC preset")
        case .tvAVCIntra:
            return NSLocalizedString("PRESET_TV_AVC_INTRA_DESCRIPTION", comment: "Description for TV AVC-Intra preset")
        case .prores:
            return NSLocalizedString("PRESET_PRORES_DESCRIPTION", comment: "Description for ProRes preset")
        case .proxy:
            return NSLocalizedString("PRESET_PROXY_DESCRIPTION", comment: "Description for Proxy preset")
        case .streamCopy:
            return NSLocalizedString("PRESET_STREAM_COPY_DESCRIPTION", comment: "Description for Stream Copy preset")
        case .animatedStill:
            return NSLocalizedString("PRESET_ANIMATED_STILL_DESCRIPTION", comment: "Description for Animated Still preset")
        case .audioOnly:
            return NSLocalizedString("PRESET_AUDIO_ONLY_DESCRIPTION", comment: "Description for Audio Only preset")
        case .imageSequence:
            return NSLocalizedString("PRESET_IMAGE_SEQUENCE_DESCRIPTION", comment: "Description for Image Sequence preset")
        case .dcp:
            return NSLocalizedString("PRESET_DCP_DESCRIPTION", comment: "Description for DCP preset")
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            return NSLocalizedString("PRESET_CUSTOM_DESCRIPTION", comment: "Description for Custom preset")
        }
    }

    var fileSuffix: String {
        switch self {
        case .videoLoop:
            return "_loop"
        case .videoLoopWithSound:
            return "_loop_audio"
        case .h264:
            return "_h264"
        case .h265:
            return "_h265"
        case .av1:
            return "_av1"
        case .tvHEVC:
            return "_tv"
        case .tvAVCIntra:
            return "_avcintra"
        case .prores:
            return "_prores"
        case .proxy:
            return "_proxy"
        case .streamCopy:
            return "_copy"
        case .animatedStill:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.animatedStillFormatKey) ?? AppConstants.defaultAnimatedStillFormat
            let format = AnimatedStillFormat(rawValue: formatRaw) ?? .avif
            return "_\(format.fileExtension)"
        case .audioOnly:
            return "_audio"
        case .imageSequence:
            return "_seq"
        case .dcp:
            return "_dcp"
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = customSlotIndex else { return "_custom" }
            return Self.customFileSuffix(for: slot)
        }
    }
    
    var ffmpegArguments: [String] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        
        let commonArgs = ["-hide_banner"]
        let preserveMetadata = UserDefaults.standard.bool(forKey: AppConstants.preserveMetadataPreferenceKey)
        
        switch self {
        case .videoLoop:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-an",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .videoLoopWithSound:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-c:a", "aac",
                "-b:a", "128k",
                "-map", "0:v:0",
                "-map", "0:a",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .h264:
            // Get encoder setting
            let encoderRaw = UserDefaults.standard.string(forKey: AppConstants.h264EncoderKey) ?? AppConstants.defaultH264Encoder
            let encoder = H264Encoder(rawValue: encoderRaw) ?? .software

            // Get container setting
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.h264ContainerKey) ?? AppConstants.defaultH264Container
            let container = CodecContainer(rawValue: containerRaw) ?? .mp4

            // Get resolution limit
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.h264ResolutionLimitKey) ?? AppConstants.defaultH264ResolutionLimit
            let resolution = CodecResolutionLimit(rawValue: resolutionRaw) ?? .unlimited

            // Get audio settings
            let audioFormatRaw = UserDefaults.standard.string(forKey: AppConstants.h264AudioFormatKey) ?? AppConstants.defaultH264AudioFormat
            var audioFormat = CodecAudioFormat(rawValue: audioFormatRaw) ?? .aac
            // Fallback if Opus selected but container doesn't support it
            if audioFormat == .opus && container != .mkv {
                audioFormat = .aac
            }
            let audioBitrateRaw = UserDefaults.standard.string(forKey: AppConstants.h264AudioBitrateKey) ?? AppConstants.defaultH264AudioBitrate
            let audioBitrate = AudioBitrate(rawValue: audioBitrateRaw) ?? .k192

            // Build scale filter
            let scaleFilter: String
            if let maxHeight = resolution.maxHeight {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),\(maxHeight),-2)':h='if(lte(iw,ih),-2,\(maxHeight))'"
            } else {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
            }

            var args = commonArgs

            switch encoder {
            case .hardware:
                let bitrate = UserDefaults.standard.string(forKey: AppConstants.h264BitrateKey) ?? AppConstants.defaultH264Bitrate
                args += [
                    "-c:v", "h264_videotoolbox",
                    "-b:v", bitrate,
                    "-profile:v", "high",
                    "-pix_fmt", "yuv420p"
                ]
            case .software:
                let qualityRaw = UserDefaults.standard.string(forKey: AppConstants.h264QualityKey) ?? AppConstants.defaultH264Quality
                let quality = CodecQualityLevel(rawValue: qualityRaw) ?? .good
                let speedRaw = UserDefaults.standard.string(forKey: AppConstants.h264SpeedKey) ?? AppConstants.defaultH264Speed
                let speed = EncodingSpeed(rawValue: speedRaw) ?? .medium

                args += [
                    "-c:v", "libx264",
                    "-crf", "\(quality.crfValue)",
                    "-preset", speed.ffmpegPreset,
                    "-profile:v", "high",
                    "-pix_fmt", "yuv420p"
                ]
            }

            // Add movflags for MP4/MOV
            if container != .mkv {
                args += ["-movflags", "+faststart"]
            }

            args += [
                "-vf", scaleFilter,
                "-map", "0:v:0"
            ]
            args += audioFormat.ffmpegArgs(bitrate: audioBitrate.ffmpegValue)
            args += ["-map", "0:a?"]

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .h265:
            // Get encoder setting
            let encoderRaw = UserDefaults.standard.string(forKey: AppConstants.h265EncoderKey) ?? AppConstants.defaultH265Encoder
            let encoder = H265Encoder(rawValue: encoderRaw) ?? .software

            // Get container setting
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.h265ContainerKey) ?? AppConstants.defaultH265Container
            let container = CodecContainer(rawValue: containerRaw) ?? .mp4

            // Get resolution limit
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.h265ResolutionLimitKey) ?? AppConstants.defaultH265ResolutionLimit
            let resolution = CodecResolutionLimit(rawValue: resolutionRaw) ?? .unlimited

            // Get audio settings
            let audioFormatRaw = UserDefaults.standard.string(forKey: AppConstants.h265AudioFormatKey) ?? AppConstants.defaultH265AudioFormat
            var audioFormat = CodecAudioFormat(rawValue: audioFormatRaw) ?? .aac
            // Fallback if Opus selected but container doesn't support it
            if audioFormat == .opus && container != .mkv {
                audioFormat = .aac
            }
            let audioBitrateRaw = UserDefaults.standard.string(forKey: AppConstants.h265AudioBitrateKey) ?? AppConstants.defaultH265AudioBitrate
            let audioBitrate = AudioBitrate(rawValue: audioBitrateRaw) ?? .k192

            // Build scale filter
            let scaleFilter: String
            if let maxHeight = resolution.maxHeight {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),\(maxHeight),-2)':h='if(lte(iw,ih),-2,\(maxHeight))'"
            } else {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
            }

            var args = commonArgs

            switch encoder {
            case .hardware:
                let bitrate = UserDefaults.standard.string(forKey: AppConstants.h265BitrateKey) ?? AppConstants.defaultH265Bitrate
                args += [
                    "-c:v", "hevc_videotoolbox",
                    "-b:v", bitrate,
                    "-tag:v", "hvc1",
                    "-pix_fmt", "p010le"
                ]
            case .software:
                let qualityRaw = UserDefaults.standard.string(forKey: AppConstants.h265QualityKey) ?? AppConstants.defaultH265Quality
                let quality = CodecQualityLevel(rawValue: qualityRaw) ?? .balanced
                let speedRaw = UserDefaults.standard.string(forKey: AppConstants.h265SpeedKey) ?? AppConstants.defaultH265Speed
                let speed = EncodingSpeed(rawValue: speedRaw) ?? .medium

                args += [
                    "-c:v", "libx265",
                    "-crf", "\(quality.crfValue)",
                    "-preset", speed.ffmpegPreset,
                    "-tag:v", "hvc1",
                    "-pix_fmt", "yuv420p10le"
                ]
            }

            // Add movflags for MP4/MOV
            if container != .mkv {
                args += ["-movflags", "+faststart"]
            }

            args += [
                "-vf", scaleFilter,
                "-map", "0:v:0"
            ]
            args += audioFormat.ffmpegArgs(bitrate: audioBitrate.ffmpegValue)
            args += ["-map", "0:a?"]

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .av1:
            // Get container setting
            let containerRaw = UserDefaults.standard.string(forKey: AppConstants.av1ContainerKey) ?? AppConstants.defaultAV1Container
            let container = CodecContainer(rawValue: containerRaw) ?? .mp4

            // Get quality setting
            let qualityRaw = UserDefaults.standard.string(forKey: AppConstants.av1QualityKey) ?? AppConstants.defaultAV1Quality
            let quality = AV1QualityLevel(rawValue: qualityRaw) ?? .good

            // Get speed setting
            let speed = UserDefaults.standard.integer(forKey: AppConstants.av1SpeedKey)
            let presetValue = speed > 0 ? speed : AppConstants.defaultAV1Speed

            // Get tune setting
            let tuneRaw = UserDefaults.standard.string(forKey: AppConstants.av1TuneKey) ?? AppConstants.defaultAV1Tune
            let tune = AV1TuneMode(rawValue: tuneRaw) ?? .vq

            // Get film grain settings
            let filmGrainRaw = UserDefaults.standard.string(forKey: AppConstants.av1FilmGrainKey) ?? AppConstants.defaultAV1FilmGrain
            let filmGrain = AV1FilmGrainLevel(rawValue: filmGrainRaw) ?? .off
            let filmGrainDenoise = UserDefaults.standard.object(forKey: AppConstants.av1FilmGrainDenoiseKey) == nil
                ? true : UserDefaults.standard.bool(forKey: AppConstants.av1FilmGrainDenoiseKey)

            // Get sharpness setting (PSY)
            let sharpnessRaw = UserDefaults.standard.string(forKey: AppConstants.av1SharpnessKey) ?? AppConstants.defaultAV1Sharpness
            let sharpness = AV1Sharpness(rawValue: sharpnessRaw) ?? .off

            // Get fast decode setting
            let fastDecode = UserDefaults.standard.bool(forKey: AppConstants.av1FastDecodeKey)

            // Get variance boost settings (PSY)
            let varianceBoostRaw = UserDefaults.standard.string(forKey: AppConstants.av1VarianceBoostKey) ?? AppConstants.defaultAV1VarianceBoost
            let varianceBoost = AV1VarianceBoost(rawValue: varianceBoostRaw) ?? .off
            let varianceBoostCurveRaw = UserDefaults.standard.string(forKey: AppConstants.av1VarianceBoostCurveKey) ?? AppConstants.defaultAV1VarianceBoostCurve
            let varianceBoostCurve = AV1VarianceBoostCurve(rawValue: varianceBoostCurveRaw) ?? .linear

            // Get resolution limit
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.av1ResolutionLimitKey) ?? AppConstants.defaultAV1ResolutionLimit
            let resolution = CodecResolutionLimit(rawValue: resolutionRaw) ?? .unlimited

            // Get audio settings
            let audioFormatRaw = UserDefaults.standard.string(forKey: AppConstants.av1AudioFormatKey) ?? AppConstants.defaultAV1AudioFormat
            var audioFormat = CodecAudioFormat(rawValue: audioFormatRaw) ?? .aac
            // Fallback if Opus selected but container doesn't support it
            if audioFormat == .opus && container != .mkv {
                audioFormat = .aac
            }
            let audioBitrateRaw = UserDefaults.standard.string(forKey: AppConstants.av1AudioBitrateKey) ?? AppConstants.defaultAV1AudioBitrate
            let audioBitrate = AudioBitrate(rawValue: audioBitrateRaw) ?? .k192

            // Build scale filter
            let scaleFilter: String
            if let maxHeight = resolution.maxHeight {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),\(maxHeight),-2)':h='if(lte(iw,ih),-2,\(maxHeight))'"
            } else {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
            }

            var args = commonArgs + [
                "-c:v", "libsvtav1",
                "-crf", "\(quality.crfValue)",
                "-preset", "\(presetValue)",
                "-pix_fmt", "yuv420p10le",
                "-vf", scaleFilter,
                "-map", "0:v:0"
            ]

            // Build consolidated SVT-AV1 params
            var svtParams: [String] = []
            if let tuneValue = tune.svtav1Value {
                svtParams.append("tune=\(tuneValue)")
            }
            if filmGrain.value > 0 {
                svtParams.append("film-grain=\(filmGrain.value)")
                svtParams.append("film-grain-denoise=\(filmGrainDenoise ? 1 : 0)")
            }
            if sharpness.value > 0 {
                svtParams.append("sharpness=\(sharpness.value)")
            }
            if fastDecode {
                svtParams.append("fast-decode=1")
            }
            if varianceBoost.value > 0 {
                svtParams.append("enable-variance-boost=1")
                svtParams.append("variance-boost-strength=\(varianceBoost.value)")
                svtParams.append("variance-octile=6")
                svtParams.append("variance-boost-curve=\(varianceBoostCurve.value)")
            }
            if !svtParams.isEmpty {
                args += ["-svtav1-params", svtParams.joined(separator: ":")]
            }

            args += audioFormat.ffmpegArgs(bitrate: audioBitrate.ffmpegValue)
            args += ["-map", "0:a?"]

            // Add movflags for MP4/MOV
            if container != .mkv {
                args += ["-movflags", "+faststart"]
            }

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .tvHEVC:
            // Get framerate and resolution settings
            let framerateRaw = UserDefaults.standard.string(forKey: AppConstants.tvFramerateModeKey) ?? AppConstants.defaultTVFramerateMode
            let framerateMode = TVFramerateMode(rawValue: framerateRaw) ?? .p50
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.tvResolutionLimitKey) ?? AppConstants.defaultTVResolutionLimit
            let resolution = TVResolutionLimit(rawValue: resolutionRaw) ?? .r1080

            // Build scale filter based on resolution
            // When a resolution limit is set, force 16:9 aspect ratio with pillarbox/letterbox (matching AVC-Intra)
            // When unlimited, just desqueeze and export at source/cropped resolution
            let scaleFilter: String
            switch resolution {
            case .r720:
                // 1. Desqueeze anamorphic to square pixels
                // 2. Scale to fit within 16:9 frame while preserving aspect ratio
                // 3. Pad to exact 16:9 resolution with black bars (centered)
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:-1:-1:color=black"
            case .r1080:
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:-1:-1:color=black"
            case .r2160:
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=3840:2160:force_original_aspect_ratio=decrease,pad=3840:2160:-1:-1:color=black"
            case .unlimited:
                // No resolution limit: just desqueeze, export at source/cropped resolution
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
            }

            var args = commonArgs + [
                "-pix_fmt", "p210le",
                "-c:v", "hevc_videotoolbox",
                "-b:v", resolution.bitrate,
                "-profile:v", "main42210",
                "-tag:v", "hvc1",
                "-c:a", "pcm_s24le",
                "-map", "0:v:0",
                "-map", "0:a"
            ]

            // Apply framerate settings
            let framerateArgs = framerateMode.ffmpegArgs
            if framerateMode.isInterlaced {
                // For interlaced, combine scale with interlace filter
                if let vfIndex = framerateArgs.firstIndex(of: "-vf"), vfIndex + 1 < framerateArgs.count {
                    let interlaceFilter = framerateArgs[vfIndex + 1]
                    args.append(contentsOf: ["-vf", "\(scaleFilter),\(interlaceFilter)"])
                    // Add non-vf args
                    for (i, arg) in framerateArgs.enumerated() {
                        if arg != "-vf" && (i == 0 || framerateArgs[i - 1] != "-vf") {
                            args.append(arg)
                        }
                    }
                } else {
                    args.append(contentsOf: ["-vf", scaleFilter])
                    args.append(contentsOf: framerateArgs)
                }
            } else {
                args.append(contentsOf: ["-vf", scaleFilter])
                args.append(contentsOf: framerateArgs)
            }

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .tvAVCIntra:
            // Get framerate and resolution settings (same as tvHEVC)
            let framerateRaw = UserDefaults.standard.string(forKey: AppConstants.tvFramerateModeKey) ?? AppConstants.defaultTVFramerateMode
            let framerateMode = TVFramerateMode(rawValue: framerateRaw) ?? .p50
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.tvResolutionLimitKey) ?? AppConstants.defaultTVResolutionLimit
            let resolution = TVResolutionLimit(rawValue: resolutionRaw) ?? .r1080

            // Get AVC-Intra specific settings
            let classRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraClassKey) ?? AppConstants.defaultAVCIntraClass
            let avcClass = AVCIntraClass(rawValue: classRaw) ?? .class100
            let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey) ?? AppConstants.defaultAVCIntraAudioChannels
            let audioChannels = AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8

            // Build scale filter based on resolution
            // Force 16:9 aspect ratio with pillarbox/letterbox for broadcast MXF delivery
            let scaleFilter: String
            let targetWidth: Int
            let targetHeight: Int
            switch resolution {
            case .r720:
                targetWidth = 1280
                targetHeight = 720
            case .r1080:
                targetWidth = 1920
                targetHeight = 1080
            case .r2160:
                targetWidth = 3840
                targetHeight = 2160
            case .unlimited:
                // Default to 1080p for 16:9 enforcement when unlimited
                targetWidth = 1920
                targetHeight = 1080
            }
            // 1. Desqueeze anamorphic to square pixels
            // 2. Scale to fit within 16:9 frame while preserving aspect ratio
            // 3. Pad to exact 16:9 resolution with black bars (centered)
            scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=\(targetWidth):\(targetHeight):force_original_aspect_ratio=decrease,pad=\(targetWidth):\(targetHeight):-1:-1:color=black"

            // Build audio: map all audio streams and output as N mono channels
            // MXF broadcast typically needs a fixed number of mono PCM tracks
            let channelCount = audioChannels.count

            var args = commonArgs + [
                "-pix_fmt", avcClass.pixelFormat,
                "-c:v", "libx264",
                "-b:v", avcClass.bitrate,
                "-g", "1",  // All intra (I-frames only)
                "-bf", "0", // No B-frames
                "-profile:v", "high422",
                "-level:v", "4.1",
                "-map", "0:v:0",
                "-map", "0:a?",  // Map all audio streams (? makes it optional if no audio)
                "-c:a", "pcm_s24le",
                "-ac", "\(channelCount)"  // Force output to N channels, ffmpeg handles mapping
            ]

            // Apply framerate settings
            let framerateArgs = framerateMode.ffmpegArgs
            if framerateMode.isInterlaced {
                // For interlaced, combine scale with interlace filter
                if let vfIndex = framerateArgs.firstIndex(of: "-vf"), vfIndex + 1 < framerateArgs.count {
                    let interlaceFilter = framerateArgs[vfIndex + 1]
                    args.append(contentsOf: ["-vf", "\(scaleFilter),\(interlaceFilter)"])
                    // Add non-vf args
                    for (i, arg) in framerateArgs.enumerated() {
                        if arg != "-vf" && (i == 0 || framerateArgs[i - 1] != "-vf") {
                            args.append(arg)
                        }
                    }
                } else {
                    args.append(contentsOf: ["-vf", scaleFilter])
                    args.append(contentsOf: framerateArgs)
                }
            } else {
                args.append(contentsOf: ["-vf", scaleFilter])
                args.append(contentsOf: framerateArgs)
            }

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .animatedStill:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.animatedStillFormatKey) ?? AppConstants.defaultAnimatedStillFormat
            let format = AnimatedStillFormat(rawValue: formatRaw) ?? .avif
            var args = commonArgs

            switch format {
            case .avif:
                args += [
                    "-pix_fmt", "p010le",
                    "-vcodec", "libsvtav1",
                    "-preset", "6",
                    "-crf", "28",
                    "-an",
                    "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),900,-2)':h='if(lte(iw,ih),-2,900)'"
                ]
            case .gif:
                args += [
                    "-vf", "fps=15,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=256:stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                    "-loop", "0",
                    "-an"
                ]
            case .apng:
                args += [
                    "-plays", "0",
                    "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),900,-2)':h='if(lte(iw,ih),-2,900)'",
                    "-an"
                ]
            case .jpegXL:
                args += [
                    "-c:v", "libjxl_anim",
                    "-distance", "1",
                    "-effort", "7",
                    "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),900,-2)':h='if(lte(iw,ih),-2,900)'",
                    "-an"
                ]
            case .webp:
                args += [
                    "-c:v", "libwebp",
                    "-lossless", "0",
                    "-compression_level", "4",
                    "-q:v", "75",
                    "-loop", "0",
                    "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),900,-2)':h='if(lte(iw,ih),-2,900)'",
                    "-an"
                ]
            }

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .proxy:
            // Get proxy codec and resolution settings
            let codecRaw = UserDefaults.standard.string(forKey: AppConstants.proxyCodecKey) ?? AppConstants.defaultProxyCodec
            let codec = ProxyCodec(rawValue: codecRaw) ?? .hevc
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.proxyResolutionLimitKey) ?? AppConstants.defaultProxyResolutionLimit
            let resolution = ProxyResolutionLimit(rawValue: resolutionRaw) ?? .r1080

            // Build scale filter based on resolution
            let scaleFilter: String
            if let maxHeight = resolution.maxHeight {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),\(maxHeight),-2)':h='if(lte(iw,ih),-2,\(maxHeight))'"
            } else {
                scaleFilter = "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
            }

            var args = commonArgs

            switch codec {
            case .hevc:
                args += [
                    "-pix_fmt", "p010le",
                    "-c:v", "hevc_videotoolbox",
                    "-b:v", resolution.bitrate,
                    "-profile:v", "main10",
                    "-tag:v", "hvc1"
                ]
            case .prores:
                args += [
                    "-pix_fmt", "yuv422p10le",
                    "-vcodec", "prores_videotoolbox",
                    "-profile:v", "proxy"
                ]
            case .dnxhd:
                args += [
                    "-pix_fmt", "yuv422p",
                    "-c:v", "dnxhd",
                    "-profile:v", "dnxhr_lb"  // Low Bandwidth DNxHR for proxy
                ]
            }

            args += [
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-c:a", "pcm_s24le",
                "-map", "0:a"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .prores:
            let profileRaw = UserDefaults.standard.string(forKey: AppConstants.proResProfileKey) ?? ProResProfile.standard.rawValue
            let profile = ProResProfile(rawValue: profileRaw) ?? .standard

            var args = commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "prores_videotoolbox",
                "-profile:v", profile.ffmpegProfileName,
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1",
                "-c:a", "pcm_s24le",
                "-map", "0:v:0",
                "-map", "0:a"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .streamCopy:
            var args = commonArgs + [
                "-map", "0",
                "-c", "copy",
                "-map", "-0:t?",  // Exclude subtitle streams only
                "-copy_unknown"  // Copy unknown stream types (for MXF acquisition metadata)
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .audioOnly:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyFormatKey) ?? AppConstants.defaultAudioOnlyFormat
            let format = AudioOnlyFormat(rawValue: formatRaw) ?? .wav

            var args = commonArgs + ["-vn", "-map", "0:a"]

            switch format {
            case .wav:
                let bitDepthRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyBitDepthKey) ?? AppConstants.defaultAudioOnlyBitDepth
                let bitDepth = AudioOnlyBitDepth(rawValue: bitDepthRaw) ?? .pcm24
                args += ["-rf64", "auto", "-c:a", bitDepth.ffmpegCodec]

            case .aac:
                let bitrateRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyAACBitrateKey) ?? AppConstants.defaultAudioOnlyAACBitrate
                let bitrate = AudioBitrate(rawValue: bitrateRaw) ?? .k192
                args += ["-c:a", "aac", "-b:a", bitrate.ffmpegValue, "-movflags", "+faststart"]

            case .mp4:
                let codecRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyMP4CodecKey) ?? AppConstants.defaultAudioOnlyMP4Codec
                let codec = AudioOnlyMP4Codec(rawValue: codecRaw) ?? .aac
                args += ["-c:a", codec.ffmpegCodec]
                if codec.requiresBitrate {
                    let bitrateRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyMP4BitrateKey) ?? AppConstants.defaultAudioOnlyMP4Bitrate
                    let bitrate = AudioBitrate(rawValue: bitrateRaw) ?? .k192
                    args += ["-b:a", bitrate.ffmpegValue]
                }
                args += ["-movflags", "+faststart"]

            case .flac:
                args += ["-c:a", "flac"]
            }

            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .imageSequence:
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceExportFormatKey) ?? AppConstants.defaultImageSequenceExportFormat
            let format = ImageSequenceFormat(rawValue: formatRaw) ?? .png
            var args = commonArgs + [
                "-c:v", format.ffmpegEncoder,
                "-an"
            ]
            // Add quality setting for JPEG
            if format == .jpeg {
                let quality = UserDefaults.standard.integer(forKey: AppConstants.imageSequenceExportQualityKey)
                let q = quality > 0 ? quality : AppConstants.defaultImageSequenceExportQuality
                args += ["-q:v", "\(q)"]
            }
            return args
        case .dcp:
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.dcpResolutionKey) ?? AppConstants.defaultDCPResolution
            let resolution = DCPResolution(rawValue: resolutionRaw) ?? .twoKFull
            let frameRateRaw = UserDefaults.standard.string(forKey: AppConstants.dcpFrameRateKey) ?? AppConstants.defaultDCPFrameRate
            let frameRate = DCPFrameRate(rawValue: frameRateRaw) ?? .fps24
            let bitrateRaw = UserDefaults.standard.string(forKey: AppConstants.dcpBitrateKey) ?? AppConstants.defaultDCPBitrate
            let bitrate = DCPBitrate(rawValue: bitrateRaw) ?? .high
            let scalingModeRaw = UserDefaults.standard.string(forKey: AppConstants.dcpScalingModeKey) ?? AppConstants.defaultDCPScalingMode
            let scalingMode = DCPScalingMode(rawValue: scalingModeRaw) ?? .fill

            let scaleFilter: String
            switch scalingMode {
            case .fill:
                scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=increase,crop=\(resolution.width):\(resolution.height)"
            case .fit:
                scaleFilter = "scale=iw*sar:ih,setsar=1,scale=\(resolution.width):\(resolution.height):force_original_aspect_ratio=decrease,pad=\(resolution.width):\(resolution.height):-1:-1:color=black"
            }

            var args = commonArgs + [
                "-c:v", "libopenjpeg",
                "-profile", resolution.openjpegProfile,
            ]
            if let cinemaMode = frameRate.cinemaModeFor(resolution: resolution) {
                args += ["-cinema_mode", cinemaMode]
            }
            args += [
                "-pix_fmt", "xyz12le",
                "-b:v", bitrate.ffmpegValue,
                "-r", frameRate.ffmpegValue,
                "-vf", scaleFilter,
                "-map", "0:v:0",
                "-an",
            ]
            // DCP outputs JP2 image sequence (not MXF) — asdcp-wrap creates the final MXF
            // The output path pattern (frame_%06d.jp2) is set by FFMPEGConverter
            return args
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = customSlotIndex else { return commonArgs }
            let customArgs = ExportPreset.parseCustomCommand(ExportPreset.customCommandString(for: slot))
            return commonArgs + customArgs
        }
    }
    
    var customSlotIndex: Int? {
        switch self {
        case .custom1: return 0
        case .custom2: return 1
        case .custom3: return 2
        case .custom4: return 3
        case .custom5: return 4
        case .custom6: return 5
        case .custom7: return 6
        case .custom8: return 7
        case .custom9: return 8
        case .custom10: return 9
        default: return nil
        }
    }
    
    var isCustom: Bool { customSlotIndex != nil }

    var appliesCrop: Bool {
        switch self {
        case .streamCopy:
            return false // Stream copy cannot apply filters like crop
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = customSlotIndex else { return false }
            return Self.customAppliesCrop(for: slot)
        default:
            return true // Built-in presets support crop
        }
    }

    var appliesAudioRouting: Bool {
        switch self {
        case .streamCopy:
            return false // Stream copy cannot apply audio filters
        case .imageSequence:
            return false // Image sequences have no audio
        case .dcp:
            return false // DCP audio is extracted separately as 24-bit PCM MXF
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = customSlotIndex else { return false }
            return Self.customAppliesAudioRouting(for: slot)
        default:
            return true // Built-in presets support audio routing
        }
    }

    private static func customAppliesCrop(for slot: Int) -> Bool {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1ApplyCropKey,
            AppConstants.customPreset2ApplyCropKey,
            AppConstants.customPreset3ApplyCropKey,
            AppConstants.customPreset4ApplyCropKey,
            AppConstants.customPreset5ApplyCropKey,
            AppConstants.customPreset6ApplyCropKey,
            AppConstants.customPreset7ApplyCropKey,
            AppConstants.customPreset8ApplyCropKey,
            AppConstants.customPreset9ApplyCropKey,
            AppConstants.customPreset10ApplyCropKey
        ]
        let key = slot < keys.count ? keys[slot] : nil
        return key.map { defaults.bool(forKey: $0) } ?? false
    }

    private static func customAppliesAudioRouting(for slot: Int) -> Bool {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1ApplyAudioRoutingKey,
            AppConstants.customPreset2ApplyAudioRoutingKey,
            AppConstants.customPreset3ApplyAudioRoutingKey,
            AppConstants.customPreset4ApplyAudioRoutingKey,
            AppConstants.customPreset5ApplyAudioRoutingKey,
            AppConstants.customPreset6ApplyAudioRoutingKey,
            AppConstants.customPreset7ApplyAudioRoutingKey,
            AppConstants.customPreset8ApplyAudioRoutingKey,
            AppConstants.customPreset9ApplyAudioRoutingKey,
            AppConstants.customPreset10ApplyAudioRoutingKey
        ]
        let key = slot < keys.count ? keys[slot] : nil
        return key.map { defaults.bool(forKey: $0) } ?? false
    }

    /// Returns whether the custom preset at the given slot is active (visible in preset picker)
    static func isCustomPresetActive(for slot: Int) -> Bool {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1ActiveKey,
            AppConstants.customPreset2ActiveKey,
            AppConstants.customPreset3ActiveKey,
            AppConstants.customPreset4ActiveKey,
            AppConstants.customPreset5ActiveKey,
            AppConstants.customPreset6ActiveKey,
            AppConstants.customPreset7ActiveKey,
            AppConstants.customPreset8ActiveKey,
            AppConstants.customPreset9ActiveKey,
            AppConstants.customPreset10ActiveKey
        ]
        guard slot >= 0, slot < keys.count else { return false }
        return defaults.bool(forKey: keys[slot])
    }

    /// Returns whether this preset is visible in the preset picker
    /// Custom presets use activation keys, built-in presets use visibility keys (default to visible)
    var isVisible: Bool {
        if let slot = customSlotIndex {
            return ExportPreset.isCustomPresetActive(for: slot)
        }

        let defaults = UserDefaults.standard
        let key: String
        switch self {
        case .videoLoop: key = AppConstants.videoLoopVisibleKey
        case .videoLoopWithSound: key = AppConstants.videoLoopWithSoundVisibleKey
        case .animatedStill: key = AppConstants.animatedStillVisibleKey
        case .h264: key = AppConstants.h264VisibleKey
        case .h265: key = AppConstants.h265VisibleKey
        case .av1: key = AppConstants.av1VisibleKey
        case .tvHEVC: key = AppConstants.tvHEVCVisibleKey
        case .tvAVCIntra: key = AppConstants.tvAVCIntraVisibleKey
        case .prores: key = AppConstants.proresVisibleKey
        case .proxy: key = AppConstants.proxyVisibleKey
        case .streamCopy: key = AppConstants.streamCopyVisibleKey
        case .audioOnly: key = AppConstants.audioOnlyVisibleKey
        case .imageSequence: key = AppConstants.imageSequenceVisibleKey
        case .dcp: key = AppConstants.dcpVisibleKey
        default: return true
        }

        // Built-in presets default to visible (true) when key doesn't exist
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }
}

extension ExportPreset {
    /// Indicates whether this preset is expected to output a video track even if the source lacks one.
    var outputsVideoTrack: Bool {
        switch self {
        case .audioOnly:
            return false
        case .imageSequence:
            return false // Output is individual image files, not a video container
        case .streamCopy:
            return true  // Stream copy preserves video if present, and timecode metadata works with -c copy
        default:
            return true
        }
    }

    /// Indicates whether this preset is expected to output an audio track.
    var outputsAudioTrack: Bool {
        switch self {
        case .videoLoop, .animatedStill:
            return false
        case .imageSequence:
            return false // Image sequences have no audio
        case .dcp:
            return false // DCP audio is in a separate MXF file
        case .videoLoopWithSound:
            return true
        case .audioOnly:
            return true
        case .streamCopy:
            return true
        default:
            return true
        }
    }

    /// Optional per-preset override for waveform/padded video resolution.
    var waveformResolutionOverride: CGSize? {
        switch self {
        case .tvHEVC, .tvAVCIntra:
            // Use resolution based on current setting
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.tvResolutionLimitKey) ?? AppConstants.defaultTVResolutionLimit
            let resolution = TVResolutionLimit(rawValue: resolutionRaw) ?? .r1080
            switch resolution {
            case .r720: return CGSize(width: 1280, height: 720)
            case .r1080: return CGSize(width: 1920, height: 1080)
            case .r2160: return CGSize(width: 3840, height: 2160)
            case .unlimited: return CGSize(width: 1920, height: 1080) // Default to 1080p for unlimited
            }
        case .dcp:
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.dcpResolutionKey) ?? AppConstants.defaultDCPResolution
            let resolution = DCPResolution(rawValue: resolutionRaw) ?? .twoKFull
            return CGSize(width: resolution.width, height: resolution.height)
        case .proxy:
            // Use resolution based on current proxy setting
            let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.proxyResolutionLimitKey) ?? AppConstants.defaultProxyResolutionLimit
            let resolution = ProxyResolutionLimit(rawValue: resolutionRaw) ?? .r1080
            switch resolution {
            case .r480: return CGSize(width: 854, height: 480)
            case .r720: return CGSize(width: 1280, height: 720)
            case .r1080: return CGSize(width: 1920, height: 1080)
            case .source: return CGSize(width: 1920, height: 1080) // Default to 1080p for source
            }
        default:
            return nil
        }
    }

    func resolvedWaveformResolution(defaultResolution: CGSize) -> CGSize {
        waveformResolutionOverride ?? defaultResolution
    }
}

// MARK: - Helpers

extension ExportPreset {
    static func applyMetadataStrategy(to args: inout [String], preserveMetadata: Bool, defaultMap: String = "-1") {
        removeArgumentPair("-map_metadata", from: &args)
        removeArgumentPair("-map_chapters", from: &args)
        removeFflagsArgument("+bitexact", from: &args)
        removeArgumentPair("-metadata:s:v:0", value: "encoder=", from: &args)
        removeArgumentPair("-metadata:s:a:0", value: "encoder=", from: &args)
        
        if preserveMetadata {
            if defaultMap != "-1" {
                appendArgumentPair("-map_metadata", value: defaultMap, to: &args)
                appendArgumentPair("-map_chapters", value: defaultMap, to: &args)
            }
        } else {
            appendArgumentPair("-map_metadata", value: "-1", to: &args)
            appendArgumentPair("-map_chapters", value: "-1", to: &args)
            // Use -fflags +bitexact to prevent muxer from writing encoder/writing_application metadata
            appendFflagsArgument("+bitexact", to: &args)
            // Clear stream-level encoder tags (writing_library) for video and audio streams
            appendArgumentPair("-metadata:s:v:0", value: "encoder=", to: &args)
            appendArgumentPair("-metadata:s:a:0", value: "encoder=", to: &args)
        }
    }
    
    /// Removes a specific flag from an existing -fflags argument, or removes the entire -fflags argument if it only contains that flag.
    private static func removeFflagsArgument(_ flag: String, from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == "-fflags" && index + 1 < args.count {
                var value = args[index + 1]
                if value == flag {
                    // Remove both -fflags and its value
                    args.remove(at: index)
                    args.remove(at: index)
                    continue
                } else if value.contains(flag) {
                    // Remove the specific flag from the value
                    value = value.replacingOccurrences(of: flag, with: "")
                    if value.isEmpty || value == "+" {
                        args.remove(at: index)
                        args.remove(at: index)
                    } else {
                        args[index + 1] = value
                        index += 2
                    }
                    continue
                }
            }
            index += 1
        }
    }
    
    /// Appends a flag to an existing -fflags argument, or adds a new -fflags argument if none exists.
    private static func appendFflagsArgument(_ flag: String, to args: inout [String]) {
        // Check if -fflags already exists
        for i in 0..<args.count {
            if args[i] == "-fflags" && i + 1 < args.count {
                // Check if the flag is already present
                if args[i + 1].contains(flag) {
                    return
                }
                // Append to existing fflags
                args[i + 1] = args[i + 1] + flag
                return
            }
        }
        // No -fflags found, add new one
        args.append(contentsOf: ["-fflags", flag])
    }
    
    private static func removeArgumentPair(_ key: String, value: String? = nil, from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == key {
                if let value {
                    if index + 1 < args.count, args[index + 1] == value {
                        args.remove(at: index)
                        args.remove(at: index)
                        continue
                    }
                } else {
                    args.remove(at: index)
                    if index < args.count {
                        args.remove(at: index)
                    }
                    continue
                }
            }
            index += 1
        }
    }
    
    private static func appendArgumentPair(_ key: String, value: String, to args: inout [String]) {
        var index = 0
        while index < args.count - 1 {
            if args[index] == key && args[index + 1] == value {
                return
            }
            index += 1
        }
        args.append(contentsOf: [key, value])
    }
    
    private static func customDisplayName(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let nameKeys = [
            AppConstants.customPreset1NameKey,
            AppConstants.customPreset2NameKey,
            AppConstants.customPreset3NameKey,
            AppConstants.customPreset4NameKey,
            AppConstants.customPreset5NameKey,
            AppConstants.customPreset6NameKey,
            AppConstants.customPreset7NameKey,
            AppConstants.customPreset8NameKey,
            AppConstants.customPreset9NameKey,
            AppConstants.customPreset10NameKey
        ]
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = slot < prefixes.count ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = slot < fallbackSuffixes.count ? fallbackSuffixes[slot] : "Custom Preset"
        let nameKey = slot < nameKeys.count ? nameKeys[slot] : nil
        let storedSuffix = nameKey.flatMap { defaults.string(forKey: $0) }
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }

    private static func sanitizeCustomNameSuffix(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        // Check for any Cx: prefix pattern
        for i in 1...10 {
            if trimPrefixIfPresent(trimmed, prefix: "C\(i):") {
                let noPrefix = trimmed
                    .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                    .last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return noPrefix.isEmpty ? fallback : noPrefix
            }
        }
        return trimmed
    }
    
    private static func trimPrefixIfPresent(_ value: String, prefix: String) -> Bool {
        value.lowercased().hasPrefix(prefix.lowercased())
    }
    
    private static func customFileSuffix(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1SuffixKey,
            AppConstants.customPreset2SuffixKey,
            AppConstants.customPreset3SuffixKey,
            AppConstants.customPreset4SuffixKey,
            AppConstants.customPreset5SuffixKey,
            AppConstants.customPreset6SuffixKey,
            AppConstants.customPreset7SuffixKey,
            AppConstants.customPreset8SuffixKey,
            AppConstants.customPreset9SuffixKey,
            AppConstants.customPreset10SuffixKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetSuffixes.count ? AppConstants.defaultCustomPresetSuffixes[slot] : "_c\(slot + 1)"
        let key = slot < keys.count ? keys[slot] : nil
        let stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : (trimmed.hasPrefix("_") ? trimmed : "_" + trimmed)
    }
    
    private static func customFileExtension(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1ExtensionKey,
            AppConstants.customPreset2ExtensionKey,
            AppConstants.customPreset3ExtensionKey,
            AppConstants.customPreset4ExtensionKey,
            AppConstants.customPreset5ExtensionKey,
            AppConstants.customPreset6ExtensionKey,
            AppConstants.customPreset7ExtensionKey,
            AppConstants.customPreset8ExtensionKey,
            AppConstants.customPreset9ExtensionKey,
            AppConstants.customPreset10ExtensionKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetExtensions.count ? AppConstants.defaultCustomPresetExtensions[slot] : "mp4"
        let key = slot < keys.count ? keys[slot] : nil
        var stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.hasPrefix(".") {
            stored.removeFirst()
        }
        stored = stored.replacingOccurrences(of: " ", with: "")
        return stored.isEmpty ? fallback : stored.lowercased()
    }
    
    private static func customCommandString(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1CommandKey,
            AppConstants.customPreset2CommandKey,
            AppConstants.customPreset3CommandKey,
            AppConstants.customPreset4CommandKey,
            AppConstants.customPreset5CommandKey,
            AppConstants.customPreset6CommandKey,
            AppConstants.customPreset7CommandKey,
            AppConstants.customPreset8CommandKey,
            AppConstants.customPreset9CommandKey,
            AppConstants.customPreset10CommandKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetCommands.count ? AppConstants.defaultCustomPresetCommands[slot] : "-c copy"
        let key = slot < keys.count ? keys[slot] : nil
        let stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
    
    private static func parseCustomCommand(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        
        for char in command {
            if isEscaping {
                current.append(char)
                isEscaping = false
                continue
            }
            
            if char == "\\" {
                isEscaping = true
                continue
            }
            
            if char == "\"" || char == "'" {
                if quote == char {
                    quote = nil
                } else if quote == nil {
                    quote = char
                } else {
                    current.append(char)
                }
                continue
            }
            
            if char.isWhitespace && quote == nil {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.isEmpty {
            args.append(current)
        }
        
        return args
    }

}

