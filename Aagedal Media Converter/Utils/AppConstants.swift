// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

enum AppConstants {
    // Default output directory for encoded exports
    static let defaultOutputDirectory: URL = {
        let defaultDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoLoopExports")

        // Create the directory if it doesn't exist
        try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
        return defaultDir
    }()

    // Default download directory (Downloads)
    static let defaultDownloadDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let downloadFolderKey = "downloadFolder"

    static let defaultScreenshotDirectory: URL = {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let defaultCaptureDirectory: URL = {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        let base = movies ?? fallback
        let directory = base.appendingPathComponent("ScreenCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static let captureDisplayIDKey = "captureDisplayID"
    static let captureHideCursorKey = "captureHideCursor"
    static let captureExcludeCurrentAppKey = "captureExcludeCurrentApp"
    static let captureFrameRateKey = "captureFrameRate"
    static let captureDynamicRangeKey = "captureDynamicRange"
    static let captureIncludeMicrophoneKey = "captureIncludeMicrophone"
    static let captureMicrophoneDeviceIDKey = "captureMicrophoneDeviceID"
    static let defaultCaptureHideCursor = false
    static let defaultCaptureExcludeCurrentApp = true
    static let defaultCaptureFrameRate = "auto"
    static let defaultCaptureDynamicRange = "sdr"
    static let defaultCaptureIncludeMicrophone = false
    static let defaultCaptureMicrophoneDeviceID = ""
    
    // Directory for cached preview assets (thumbnails, waveforms, etc.)
    static let previewCacheDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("PreviewAssets", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()
    
    // Supported media file extensions (lowercase)
    static let supportedVideoExtensions: Set<String> = [
        "3g2", "3gp", "3gp2", "3gpp",
        "aac", "aif", "aiff", "alac", "amv",
        "asf", "avi", "apv", "avs", "drc",
        "dv", "f4v", "flac", "flv", "gxf",
        "ismv", "m1v", "m2p", "m2t", "m2ts",
        "m2v", "m4a", "m4b", "m4v", "mk3d",
        "mkv", "mod", "mov", "mp2", "mp2v",
        "mp3", "mp4", "mp4v", "mpe", "mpeg",
        "mpg", "mpv", "mts", "mxf", "oga",
        "ogg", "ogm", "ogv", "opus", "qt",
        "rm", "rmvb", "roq", "svi", "tod",
        "trp", "ts", "vob", "wav", "webm",
        "wma", "wmv", "wtv", "y4m"
    ]
    
    // Supported UTType identifiers for file picker
    static let supportedVideoTypes: [String] = [
        "public.movie",
        "public.video",
        "public.mpeg-4",
        "com.apple.quicktime-movie",
        "com.apple.m4v-video",
        "public.avi",
        "com.apple.m4v-video",
        "public.mpeg-4-audio",
        "public.audio",
        "com.apple.coreaudio-format",
        "com.microsoft.waveform-audio",
        "com.apple.protected-mpeg-4-audio"
    ]

    // Audio waveform rendering defaults
    static let audioWaveformVideoDefaultEnabledKey = "audioWaveformVideoDefaultEnabled"
    static let audioWaveformResolutionKey = "audioWaveformResolution"
    static let audioWaveformBackgroundColorKey = "audioWaveformBackgroundColor"
    static let audioWaveformForegroundColorKey = "audioWaveformForegroundColor"
    static let audioWaveformNormalizeKey = "audioWaveformNormalize"
    static let audioWaveformStyleKey = "audioWaveformStyle"
    static let defaultAudioWaveformStyleRaw = "fisheye"
    static let audioWaveformFrameRateKey = "audioWaveformFrameRate"
    static let defaultAudioWaveformFrameRate: Double = 25
    static let audioWaveformLineThicknessKey = "audioWaveformLineThickness"
    static let audioWaveformDetailLevelKey = "audioWaveformDetailLevel"
    static let defaultAudioWaveformLineThickness = 2.0
    static let defaultAudioWaveformDetailLevel = 1.0
    static let audioWaveformAspectRatioKey = "audioWaveformAspectRatio"
    static let audioWaveformShortEdgeKey = "audioWaveformShortEdge"
    static let defaultAudioWaveformAspectRatio = "ratio16_9"
    static let defaultAudioWaveformShortEdge = 1080
    
    // Maximum thumbnail dimensions
    static let maxThumbnailSize = CGSize(width: 320, height: 320)
    static let includeDateTagPreferenceKey = "includeDateTagByDefault"
    static let preserveMetadataPreferenceKey = "preserveMetadataByDefault"
    static let commentPrefixKey = "commentPrefix"
    static let commentSuffixKey = "commentSuffix"
    static let commentSeparatorKey = "commentSeparator"
    static let defaultCommentSeparator = " | "
    static let commentDateFormatKey = "commentDateFormat"
    static let defaultCommentDateFormat = "yyyyMMdd"
    static let dateTagPrefixKey = "dateTagPrefix"
    static let defaultDateTagPrefix = "Date generated"
    static let showCommentFieldKey = "showCommentField"
    static let showDateTagButtonKey = "showDateTagButton"
    static let enableFileNameProcessingKey = "enableFileNameProcessing"
    static let fileNameReplaceSpacesKey = "fileNameReplaceSpaces"
    static let fileNameReplaceScandinavianCharsKey = "fileNameReplaceScandinavianChars"
    static let fileNameRemoveSpecialCharsKey = "fileNameRemoveSpecialChars"
    static let fileNameIncludePresetSuffixKey = "fileNameIncludePresetSuffix"
    static let defaultFileNameReplaceSpaces = true
    static let defaultFileNameReplaceScandinavianChars = true
    static let defaultFileNameRemoveSpecialChars = true
    static let defaultFileNameIncludePresetSuffix = true
    static let customPresetCommandKey = "customPresetFFmpegCommand"
    static let customPresetSuffixKey = "customPresetFileSuffix"
    static let customPresetExtensionKey = "customPresetFileExtension"
    static let customPreset1NameKey = "customPreset1DisplayName"
    static let customPreset2NameKey = "customPreset2DisplayName"
    static let customPreset3NameKey = "customPreset3DisplayName"
    static let customPreset1CommandKey = customPresetCommandKey
    static let customPreset1SuffixKey = customPresetSuffixKey
    static let customPreset1ExtensionKey = customPresetExtensionKey
    static let customPreset2CommandKey = "customPreset2FFmpegCommand"
    static let customPreset2SuffixKey = "customPreset2FileSuffix"
    static let customPreset2ExtensionKey = "customPreset2FileExtension"
    static let customPreset3CommandKey = "customPreset3FFmpegCommand"
    static let customPreset3SuffixKey = "customPreset3FileSuffix"
    static let customPreset3ExtensionKey = "customPreset3FileExtension"
    static let defaultPresetKey = "defaultExportPreset"
    static let watchFolderModeKey = "watchFolderModeEnabled"
    static let watchFolderPathKey = "watchFolderPath"
    static let watchFolderIgnoreOlderThan24hKey = "watchFolderIgnoreOlderThan24h"
    static let watchFolderAutoDeleteOlderThanWeekKey = "watchFolderAutoDeleteOlderThanWeek"
    static let watchFolderIgnoreDurationValueKey = "watchFolderIgnoreDurationValue"
    static let watchFolderIgnoreDurationUnitKey = "watchFolderIgnoreDurationUnit"
    static let watchFolderDeleteDurationValueKey = "watchFolderDeleteDurationValue"
    static let watchFolderDeleteDurationUnitKey = "watchFolderDeleteDurationUnit"
    static let previewCacheCleanupPolicyKey = "previewCacheCleanupPolicy"
    static let defaultPreviewCacheCleanupPolicyRaw = PreviewCacheCleanupPolicy.purgeOnLaunch.rawValue
    static let watchFolderDurationValues: [Int] = [1, 3, 5, 7, 10, 14, 24, 31]
    static let defaultWatchFolderIgnoreDurationValue = 24
    static let defaultWatchFolderIgnoreDurationUnitRaw = WatchFolderDurationUnit.hours.rawValue
    static let defaultWatchFolderDeleteDurationValue = 7
    static let defaultWatchFolderDeleteDurationUnitRaw = WatchFolderDurationUnit.days.rawValue
    static let customPresetPrefixes = ["C1:", "C2:", "C3:", "C4:", "C5:", "C6:", "C7:", "C8:", "C9:", "C10:"]
    static let defaultCustomPresetDisplayNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset",
        "C4: Custom Preset",
        "C5: Custom Preset",
        "C6: Custom Preset",
        "C7: Custom Preset",
        "C8: Custom Preset",
        "C9: Custom Preset",
        "C10: Custom Preset"
    ]
    static let defaultCustomPresetNameSuffixes = [
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset",
        "Custom Preset"
    ]
    static let defaultCustomPresetFullNames = [
        "C1: Custom Preset",
        "C2: Custom Preset",
        "C3: Custom Preset",
        "C4: Custom Preset",
        "C5: Custom Preset",
        "C6: Custom Preset",
        "C7: Custom Preset",
        "C8: Custom Preset",
        "C9: Custom Preset",
        "C10: Custom Preset"
    ]
    static let defaultCustomPresetCommands = ["-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy", "-c copy"]
    static let defaultCustomPresetSuffixes = ["_c1", "_c2", "_c3", "_c4", "_c5", "_c6", "_c7", "_c8", "_c9", "_c10"]
    static let defaultCustomPresetExtensions = ["mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4", "mp4"]
    // Default activation states: all custom presets inactive by default
    static let defaultCustomPresetActive = [false, false, false, false, false, false, false, false, false, false]

    static let screenshotDirectoryKey = "screenshotDirectory"
    static let screenshot8BitFormatKey = "screenshot8BitFormat"
    static let screenshot10BitFormatKey = "screenshot10BitFormat"
    static let screenshotHighBitFormatKey = "screenshotHighBitFormat"
    static let defaultScreenshotFormat = "JPEG XL" // Default to JPEG XL for all bit depths (must match ScreenshotFormat.jpegXL.rawValue)
    static let screenshotAlphaHandlingKey = "screenshotAlphaHandling"
    static let defaultScreenshotAlphaHandling = "auto" // auto, useSelectedFormat
    static let captureDirectoryKey = "captureDirectory"
    static let capturePresetKey = "capturePreset"
    static let proResProfileKey = "proResProfile"
    
    // Update checking
    static let checkForUpdatesKey = "checkForUpdates"
    static let updateCheckFrequencyKey = "updateCheckFrequency"
    static let lastUpdateCheckDateKey = "lastUpdateCheckDate"

    // Timecode defaults
    static let defaultTimecodeModeKey = "defaultTimecodeMode"
    static let defaultTimecodeValueKey = "defaultTimecodeValue"
    static let defaultTimecodeModeRaw = "preserveSource" // preserveSource, manual, disabled
    static let defaultTimecodeValue = "00:00:00:00"

    // Custom preset feature toggles
    static let customPreset1ApplyCropKey = "customPreset1ApplyCrop"
    static let customPreset1ApplyAudioRoutingKey = "customPreset1ApplyAudioRouting"
    static let customPreset2ApplyCropKey = "customPreset2ApplyCrop"
    static let customPreset2ApplyAudioRoutingKey = "customPreset2ApplyAudioRouting"
    static let customPreset3ApplyCropKey = "customPreset3ApplyCrop"
    static let customPreset3ApplyAudioRoutingKey = "customPreset3ApplyAudioRouting"
    static let customPreset4ApplyCropKey = "customPreset4ApplyCrop"
    static let customPreset4ApplyAudioRoutingKey = "customPreset4ApplyAudioRouting"
    static let customPreset5ApplyCropKey = "customPreset5ApplyCrop"
    static let customPreset5ApplyAudioRoutingKey = "customPreset5ApplyAudioRouting"
    static let customPreset6ApplyCropKey = "customPreset6ApplyCrop"
    static let customPreset6ApplyAudioRoutingKey = "customPreset6ApplyAudioRouting"
    static let customPreset7ApplyCropKey = "customPreset7ApplyCrop"
    static let customPreset7ApplyAudioRoutingKey = "customPreset7ApplyAudioRouting"
    static let customPreset8ApplyCropKey = "customPreset8ApplyCrop"
    static let customPreset8ApplyAudioRoutingKey = "customPreset8ApplyAudioRouting"
    static let customPreset9ApplyCropKey = "customPreset9ApplyCrop"
    static let customPreset9ApplyAudioRoutingKey = "customPreset9ApplyAudioRouting"
    static let customPreset10ApplyCropKey = "customPreset10ApplyCrop"
    static let customPreset10ApplyAudioRoutingKey = "customPreset10ApplyAudioRouting"

    // Custom preset 4-10 individual keys
    static let customPreset4NameKey = "customPreset4DisplayName"
    static let customPreset4CommandKey = "customPreset4FFmpegCommand"
    static let customPreset4SuffixKey = "customPreset4FileSuffix"
    static let customPreset4ExtensionKey = "customPreset4FileExtension"
    static let customPreset4ActiveKey = "customPreset4Active"

    static let customPreset5NameKey = "customPreset5DisplayName"
    static let customPreset5CommandKey = "customPreset5FFmpegCommand"
    static let customPreset5SuffixKey = "customPreset5FileSuffix"
    static let customPreset5ExtensionKey = "customPreset5FileExtension"
    static let customPreset5ActiveKey = "customPreset5Active"

    static let customPreset6NameKey = "customPreset6DisplayName"
    static let customPreset6CommandKey = "customPreset6FFmpegCommand"
    static let customPreset6SuffixKey = "customPreset6FileSuffix"
    static let customPreset6ExtensionKey = "customPreset6FileExtension"
    static let customPreset6ActiveKey = "customPreset6Active"

    static let customPreset7NameKey = "customPreset7DisplayName"
    static let customPreset7CommandKey = "customPreset7FFmpegCommand"
    static let customPreset7SuffixKey = "customPreset7FileSuffix"
    static let customPreset7ExtensionKey = "customPreset7FileExtension"
    static let customPreset7ActiveKey = "customPreset7Active"

    static let customPreset8NameKey = "customPreset8DisplayName"
    static let customPreset8CommandKey = "customPreset8FFmpegCommand"
    static let customPreset8SuffixKey = "customPreset8FileSuffix"
    static let customPreset8ExtensionKey = "customPreset8FileExtension"
    static let customPreset8ActiveKey = "customPreset8Active"

    static let customPreset9NameKey = "customPreset9DisplayName"
    static let customPreset9CommandKey = "customPreset9FFmpegCommand"
    static let customPreset9SuffixKey = "customPreset9FileSuffix"
    static let customPreset9ExtensionKey = "customPreset9FileExtension"
    static let customPreset9ActiveKey = "customPreset9Active"

    static let customPreset10NameKey = "customPreset10DisplayName"
    static let customPreset10CommandKey = "customPreset10FFmpegCommand"
    static let customPreset10SuffixKey = "customPreset10FileSuffix"
    static let customPreset10ExtensionKey = "customPreset10FileExtension"
    static let customPreset10ActiveKey = "customPreset10Active"

    // Custom preset activation keys
    static let customPreset1ActiveKey = "customPreset1Active"
    static let customPreset2ActiveKey = "customPreset2Active"
    static let customPreset3ActiveKey = "customPreset3Active"

    // Animated Still preset settings
    static let animatedStillFormatKey = "animatedStillFormat"
    static let defaultAnimatedStillFormat = "AVIF"

    // TV preset settings
    static let tvFramerateModeKey = "tvFramerateMode"
    static let defaultTVFramerateMode = "50p"
    static let tvResolutionLimitKey = "tvResolutionLimit"
    static let defaultTVResolutionLimit = "1080p"

    // AVC-Intra preset settings
    static let avcIntraClassKey = "avcIntraClass"
    static let defaultAVCIntraClass = "AVC-Intra 100"
    static let avcIntraAudioChannelsKey = "avcIntraAudioChannels"
    static let defaultAVCIntraAudioChannels = "8 Channels"

    // Stream Copy container settings
    static let streamCopyContainerKey = "streamCopyContainer"
    static let defaultStreamCopyContainer = "Keep Current"

    // Proxy preset settings
    static let proxyCodecKey = "proxyCodec"
    static let defaultProxyCodec = "HEVC"
    static let proxyResolutionLimitKey = "proxyResolutionLimit"
    static let defaultProxyResolutionLimit = "1080p"

    // H.264 preset settings
    static let h264EncoderKey = "h264Encoder"
    static let defaultH264Encoder = "Software (libx264)"
    static let h264ContainerKey = "h264Container"
    static let defaultH264Container = "MP4"
    static let h264QualityKey = "h264Quality"
    static let defaultH264Quality = "Good (23)"
    static let h264SpeedKey = "h264Speed"
    static let defaultH264Speed = "Medium"
    static let h264ResolutionLimitKey = "h264ResolutionLimit"
    static let defaultH264ResolutionLimit = "Unlimited"
    static let h264BitrateKey = "h264Bitrate"
    static let defaultH264Bitrate = "10M"
    static let h264AudioFormatKey = "h264AudioFormat"
    static let defaultH264AudioFormat = "AAC"
    static let h264AudioBitrateKey = "h264AudioBitrate"
    static let defaultH264AudioBitrate = "192 kbps"

    // H.265 preset settings
    static let h265EncoderKey = "h265Encoder"
    static let defaultH265Encoder = "Software (libx265)"
    static let h265ContainerKey = "h265Container"
    static let defaultH265Container = "MP4"
    static let h265QualityKey = "h265Quality"
    static let defaultH265Quality = "Balanced (28)"
    static let h265SpeedKey = "h265Speed"
    static let defaultH265Speed = "Medium"
    static let h265ResolutionLimitKey = "h265ResolutionLimit"
    static let defaultH265ResolutionLimit = "Unlimited"
    static let h265BitrateKey = "h265Bitrate"
    static let defaultH265Bitrate = "8M"
    static let h265AudioFormatKey = "h265AudioFormat"
    static let defaultH265AudioFormat = "AAC"
    static let h265AudioBitrateKey = "h265AudioBitrate"
    static let defaultH265AudioBitrate = "192 kbps"

    // AV1 preset settings
    static let av1ContainerKey = "av1Container"
    static let defaultAV1Container = "MP4"
    static let av1QualityKey = "av1Quality"
    static let defaultAV1Quality = "Good (30)"
    static let av1SpeedKey = "av1Speed"
    static let defaultAV1Speed = 6
    static let av1ResolutionLimitKey = "av1ResolutionLimit"
    static let defaultAV1ResolutionLimit = "Unlimited"
    static let av1AudioFormatKey = "av1AudioFormat"
    static let defaultAV1AudioFormat = "AAC"
    static let av1AudioBitrateKey = "av1AudioBitrate"
    static let defaultAV1AudioBitrate = "192 kbps"

    // VideoLoop mute settings
    static let videoLoopDefaultMutedKey = "videoLoopDefaultMuted"
    static let defaultVideoLoopMuted = true

    // Built-in preset visibility keys (all visible by default)
    static let videoLoopVisibleKey = "videoLoopVisible"
    static let videoLoopWithSoundVisibleKey = "videoLoopWithSoundVisible"
    static let animatedStillVisibleKey = "animatedStillVisible"
    static let h264VisibleKey = "h264Visible"
    static let h265VisibleKey = "h265Visible"
    static let av1VisibleKey = "av1Visible"
    static let tvHEVCVisibleKey = "tvHEVCVisible"
    static let tvAVCIntraVisibleKey = "tvAVCIntraVisible"
    static let proresVisibleKey = "proresVisible"
    static let proxyVisibleKey = "proxyVisible"
    static let streamCopyVisibleKey = "streamCopyVisible"
    static let audioWAVVisibleKey = "audioWAVVisible"
    static let audioAACVisibleKey = "audioAACVisible"

    // Reset behavior
    static let resetClearsSettingsKey = "resetClearsSettings"
    static let defaultResetClearsSettings = false // false = only reset status, true = also clear trim/crop/audio routing

    // Queue display settings
    static let queueViewModeKey = "queueViewMode"
    static let defaultQueueViewMode = "standard" // "standard" or "compact"

    // Sound settings
    static let playSoundOnSuccessKey = "playSoundOnSuccess"
    static let playSoundOnErrorKey = "playSoundOnError"
    static let defaultPlaySoundOnSuccess = true
    static let defaultPlaySoundOnError = true

    // Timecode display settings
    static let preferredTimecodeDisplayModeKey = "preferredTimecodeDisplayMode"
    static let defaultPreferredTimecodeDisplayMode = "relative" // relative, source, frames

    // yt-dlp settings
    static let ytdlpToolsDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let toolsDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: toolsDir, withIntermediateDirectories: true)
        return toolsDir
    }()
    static let ytdlpCacheDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let cacheDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("yt-dlp-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()

    static let ytdlpVersionKey = "ytdlpInstalledVersion"
    static let ytdlpLastUpdateCheckKey = "ytdlpLastUpdateCheck"
    static let ytdlpGitHubReleasesURL = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
    static let ytdlpMacOSAssetName = "yt-dlp_macos"
    static let ytdlpBinarySourceKey = "ytdlpBinarySource"

    static let denoVersionKey = "denoInstalledVersion"
    static let denoLastUpdateCheckKey = "denoLastUpdateCheck"
    static let denoGitHubReleasesURL = "https://api.github.com/repos/denoland/deno/releases/latest"
    static let denoBinarySourceKey = "denoBinarySource"
    static let denoCustomPathKey = "denoCustomPath"

    // Custom binary paths (no longer need security-scoped bookmarks without sandbox)
    static let ytdlpCustomPathKey = "ytdlpCustomPath"
    static let ffmpegBinarySourceKey = "ffmpegBinarySource"
    static let customFFmpegPathKey = "customFFmpegPath"
    static let customFFprobePathKey = "customFFprobePath"

    // Legacy keys (for migration)
    static let ytdlpUserPathBookmarkKey = "ytdlpUserPathBookmark"
    static let ytdlpUserPathKey = "ytdlpUserPath"

    // Download history
    static let downloadHistoryKey = "downloadHistory"
    static let downloadHistoryMaxItems = 10

    // Download automation defaults
    static let autoEncodeAfterDownloadKey = "autoEncodeAfterDownload"
    static let autoUploadAfterDownloadKey = "autoUploadAfterDownload"

    // yt-dlp authentication
    static let ytdlpCookiesBrowserKey = "ytdlpCookiesBrowser"
    static let ytdlpLiveFromStartKey = "ytdlpLiveFromStart"

    // MARK: - Upload Settings

    // FTP/Upload configuration
    static let uploadServerKey = "uploadServer"
    static let uploadPortKey = "uploadPort"
    static let uploadUsernameKey = "uploadUsername"
    static let uploadRemotePathKey = "uploadRemotePath"
    static let uploadUseFTPSKey = "uploadUseFTPS"
    static let uploadDefaultEnabledKey = "uploadDefaultEnabled"
    static let uploadRetryCountKey = "uploadRetryCount"
    static let uploadFTPProfilesKey = "uploadFTPProfiles"
    static let uploadFTPSelectedProfileIDKey = "uploadFTPSelectedProfileID"
    static let uploadSFTPProfilesKey = "uploadSFTPProfiles"
    static let uploadSFTPSelectedProfileIDKey = "uploadSFTPSelectedProfileID"
    static let uploadSMBProfilesKey = "uploadSMBProfiles"
    static let uploadSMBSelectedProfileIDKey = "uploadSMBSelectedProfileID"
    static let uploadS3ProfilesKey = "uploadS3Profiles"
    static let uploadS3SelectedProfileIDKey = "uploadS3SelectedProfileID"
    static let defaultUploadPort = 21
    static let defaultUploadRetryCount = 3

    // rclone binary management
    static let rcloneVersionKey = "rcloneInstalledVersion"
    static let rcloneLastUpdateCheckKey = "rcloneLastUpdateCheck"
    static let rcloneGitHubReleasesURL = "https://api.github.com/repos/rclone/rclone/releases/latest"
    static let rcloneCustomPathKey = "rcloneCustomPath"

    // ExifTool binary management
    static let exiftoolVersionKey = "exiftoolInstalledVersion"
    static let exiftoolLastUpdateCheckKey = "exiftoolLastUpdateCheck"
    static let exiftoolCustomPathKey = "exiftoolCustomPath"
    static let exiftoolDownloadBaseURL = "https://exiftool.org/"
    static let exiftoolVersionURL = "https://exiftool.org/ver.txt"

    // C2PA (Content Authenticity) settings
    static let c2paCheckEnabledKey = "c2paCheckEnabled"
    static let defaultC2PACheckEnabled = true

    // Backend type selection
    static let uploadBackendTypeKey = "uploadBackendType"

    // SFTP-specific settings
    static let uploadSFTPKeyFileKey = "uploadSFTPKeyFile"
    static let uploadSFTPKeyFileBookmarkKey = "uploadSFTPKeyFileBookmark"
    static let defaultSFTPPort = 22

    // SMB-specific settings
    static let uploadSMBShareKey = "uploadSMBShare"
    static let uploadSMBDomainKey = "uploadSMBDomain"
    static let defaultSMBPort = 445

    // S3-specific settings
    static let uploadS3BucketKey = "uploadS3Bucket"
    static let uploadS3RegionKey = "uploadS3Region"
    static let uploadS3EndpointKey = "uploadS3Endpoint"
    static let uploadS3AccessKeyKey = "uploadS3AccessKey"

    // Output location settings
    static let saveNextToOriginalKey = "saveNextToOriginal"
    static let saveNextToOriginalSubfolderKey = "saveNextToOriginalSubfolder"
    static let saveNextToOriginalSubfolderModeKey = "saveNextToOriginalSubfolderMode" // "custom" or "presetSuffix"
    static let saveNextToOriginalSubfolderNameKey = "saveNextToOriginalSubfolderName"
    static let defaultSaveNextToOriginal = false
    static let defaultSaveNextToOriginalSubfolder = false
    static let defaultSaveNextToOriginalSubfolderMode = "custom" // "custom" or "presetSuffix"
    static let defaultSaveNextToOriginalSubfolderName = "Encoded"

    // MARK: - Whisper Settings

    // Whisper binary management
    static let whisperVersionKey = "whisperInstalledVersion"
    static let whisperLastUpdateCheckKey = "whisperLastUpdateCheck"
    static let whisperGitHubReleasesURL = "https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest"
    static let whisperCustomPathKey = "whisperCustomPath"

    // Whisper model management
    static let whisperModelKey = "whisperSelectedModel"
    static let whisperCustomModelPathKey = "whisperCustomModelPath"
    static let whisperModelsDirectory: URL = {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = supportDir
            .appendingPathComponent("AagedalMediaConverter", isDirectory: true)
            .appendingPathComponent("whisper-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }()
    static let defaultWhisperModel = "base"

    // Whisper generation settings
    static let whisperDefaultEnabledKey = "whisperDefaultEnabled"
    static let whisperLanguageKey = "whisperLanguage"
    static let defaultWhisperLanguage = "auto"
    static let whisperMaxLineLengthKey = "whisperMaxLineLength"
    static let defaultWhisperMaxLineLength = 42  // Characters per subtitle line
}
