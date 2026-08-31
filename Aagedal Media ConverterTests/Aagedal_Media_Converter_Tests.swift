//
//  Aagedal_VideoLoop_Converter_2_0Tests.swift
//  Aagedal VideoLoop Converter 2.0Tests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import XCTest
@testable import Aagedal_Media_Converter

final class Aagedal_Media_Converter_Tests: XCTestCase {

    func testParsingDurationSupportsVariableFractionalSecondPrecision() throws {
        XCTAssertEqual(
            try XCTUnwrap(ParsingUtils.parseDuration(from: "Duration: 00:00:01.5")),
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(ParsingUtils.parseDuration(from: "Duration: 01:02:03.123456")),
            3_723.123_456,
            accuracy: 0.000_001
        )
    }

    func testParsingTimeProgressSupportsVariableFractionalSecondPrecision() throws {
        let progress = try XCTUnwrap(
            ParsingUtils.parseTimeProgress(
                from: "frame=1 time=00:00:01.5 speed=1.0x",
                totalDuration: 3
            )
        )

        XCTAssertEqual(progress.0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(progress.1, "00:00:01")
    }

    func testAnamorphicCropReplacesDarDesqueezeWithExplicitSquarePixelNormalization() throws {
        var args = presetVideoArguments()

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: 4.0 / 3.0
        )

        let filterChain = try videoFilter(in: args)
        XCTAssertTrue(filterChain.hasPrefix("crop=810:1080:315:0,scale=1080:1080,setsar=1/1"))
        XCTAssertFalse(filterChain.contains("trunc(ih*dar"))
        XCTAssertTrue(filterChain.hasSuffix("scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"))
    }

    func testSquarePixelCropReplacesRedundantDarDesqueeze() throws {
        var args = presetVideoArguments()
        let crop = CropConfig(normalizedRect: CropRect(x: 0.25, y: 0, width: 0.5, height: 1))

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: crop,
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        let filterChain = try videoFilter(in: args)
        XCTAssertTrue(filterChain.hasPrefix("crop=960:1080:480:0,setsar=1/1"))
        XCTAssertFalse(filterChain.contains("trunc(ih*dar"))
    }

    func testCropPreservesDarDesqueezeWhenPixelAspectRatioIsUnavailable() throws {
        var args = presetVideoArguments()

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: nil
        )

        let filterChain = try videoFilter(in: args)
        let cropRange = try XCTUnwrap(filterChain.range(of: "crop=810:1080:315:0"))
        let desqueezeRange = try XCTUnwrap(filterChain.range(of: "scale='trunc(ih*dar"))
        XCTAssertLessThan(cropRange.lowerBound, desqueezeRange.lowerBound)
    }

    func testInactiveCropDoesNotAddVideoFilter() {
        var args = ["-c:v", "libx264"]

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: CropConfig(normalizedRect: .fullFrame),
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        XCTAssertEqual(args, ["-c:v", "libx264"])
    }

    func testStreamCopyDoesNotApplyCrop() {
        var args = ["-c:v", "copy"]
        let originalArgs = args

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: CropConfig(normalizedRect: CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        XCTAssertEqual(args, originalArgs)
    }

    func testOddCropDimensionsAreRoundedToCodecSafeEvenValues() throws {
        var args: [String] = []
        let crop = CropConfig(normalizedRect: CropRect(x: 0.1, y: 0.1, width: 0.501, height: 0.501))

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: crop,
            sourceWidth: 1919,
            sourceHeight: 1079,
            pixelAspectRatio: 1.5
        )

        XCTAssertEqual(
            try videoFilter(in: args),
            "crop=960:540:192:108,scale=1440:540,setsar=1/1"
        )
    }

    func testGeneratedAnamorphicFixtureProducesSquarePixelsAndExpectedCrop() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("anamorphic-fixture.nut")
        let outputURL = temporaryDirectory.appendingPathComponent("cropped.rgb")

        // Red and blue guard bands surround the green crop target. The stored frame is
        // 1440x1080 SAR 4:3, so the centered 810x1080 crop is a 1:1 display region.
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=black:s=1440x1080:r=1,drawbox=x=0:y=0:w=315:h=1080:c=red:t=fill,drawbox=x=315:y=0:w=810:h=1080:c=lime:t=fill,drawbox=x=1125:y=0:w=315:h=1080:c=blue:t=fill,setsar=4/3",
            "-frames:v", "1", "-c:v", "ffv1", fixtureURL.path
        ])

        var args = presetVideoArguments()
        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: 4.0 / 3.0
        )
        let filterChain = try videoFilter(in: args)

        let conversionLog = try runFFmpeg([
            "-hide_banner", "-loglevel", "info", "-y", "-i", fixtureURL.path,
            "-vf", "\(filterChain),showinfo", "-frames:v", "1",
            "-pix_fmt", "rgb24", "-f", "rawvideo", outputURL.path
        ])

        XCTAssertTrue(conversionLog.contains("sar:1/1 s:1080x1080"), conversionLog)
        XCTAssertTrue(conversionLog.contains("[SAR 1:1 DAR 1:1]"), conversionLog)

        let pixels = try Data(contentsOf: outputURL)
        XCTAssertEqual(pixels.count, 1080 * 1080 * 3)

        let centerPixelOffset = ((540 * 1080) + 540) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testCustomCommandTokenizationPreservesExplicitlyEmptyQuotedArguments() {
        XCTAssertEqual(
            ExportPreset.parseCustomCommand(#"-vf "" -metadata title='' -c:v libx264"#),
            ["-vf", "", "-metadata", "title=", "-c:v", "libx264"]
        )
    }

    func testCustomCommandTokenizationPreservesQuotedAndEscapedWhitespace() {
        XCTAssertEqual(
            ExportPreset.parseCustomCommand(
                #"-metadata "title=My Clip" -metadata artist=Jane\ Doe -vf 'scale=1280:-2'"#
            ),
            ["-metadata", "title=My Clip", "-metadata", "artist=Jane Doe", "-vf", "scale=1280:-2"]
        )
    }

    func testDefaultFFmpegPresetContainerAndCodecMatrix() throws {
        try withDefaultPresetSettings {
            let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
            let expectations: [PresetCommandExpectation] = [
                .init(.videoLoop, extension: "mp4", videoCodec: "libx264", audioCodec: nil, media: .videoOnly),
                .init(.videoLoopWithSound, extension: "mp4", videoCodec: "libx264", audioCodec: "aac", media: .videoAndAudio),
                .init(.animatedStill, extension: "avif", videoCodec: "libsvtav1", audioCodec: nil, media: .videoOnly),
                .init(.h264, extension: "mp4", videoCodec: "libx264", audioCodec: "aac", media: .videoAndAudio),
                .init(.h265, extension: "mp4", videoCodec: "libx265", audioCodec: "aac", media: .videoAndAudio),
                .init(.av1, extension: "mp4", videoCodec: "libsvtav1", audioCodec: "aac", media: .videoAndAudio),
                .init(.tvHEVC, extension: "mov", videoCodec: "hevc_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.tvAVCIntra, extension: "mxf", videoCodec: "libx264", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.prores, extension: "mov", videoCodec: "prores_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.proxy, extension: "mov", videoCodec: "hevc_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.streamCopy, extension: "mov", videoCodec: "copy", audioCodec: "copy", media: .streamCopy),
                .init(.audioOnly, extension: "wav", videoCodec: nil, audioCodec: "pcm_s24le", media: .audioOnly),
                .init(.imageSequence, extension: "png", videoCodec: "png", audioCodec: nil, media: .videoOnly),
                .init(.dcp, extension: "mxf", videoCodec: "libopenjpeg", audioCodec: nil, media: .videoOnly),
                .init(.imfJ2K, extension: "mxf", videoCodec: "libopenjpeg", audioCodec: nil, media: .videoOnly),
                .init(.imfProRes, extension: "mxf", videoCodec: "prores_ks", audioCodec: nil, media: .videoOnly)
            ]

            let ffmpegBuiltIns = ExportPreset.allCases.filter { !$0.isCustom && $0 != .av2 }
            XCTAssertEqual(
                Set(expectations.map(\.preset)),
                Set(ffmpegBuiltIns),
                "Update the default command matrix whenever a built-in FFmpeg preset is added or removed."
            )

            for expectation in expectations {
                let arguments = expectation.preset.ffmpegArguments
                let presetName = expectation.preset.rawValue

                XCTAssertEqual(
                    expectation.preset.outputExtension(for: sourceURL),
                    expectation.outputExtension,
                    presetName
                )
                XCTAssertEqual(videoCodec(in: arguments), expectation.videoCodec, presetName)
                XCTAssertEqual(audioCodec(in: arguments), expectation.audioCodec, presetName)

                switch expectation.media {
                case .videoOnly:
                    XCTAssertTrue(arguments.contains("-an"), presetName)
                    XCTAssertFalse(arguments.contains("-vn"), presetName)
                case .audioOnly:
                    XCTAssertTrue(arguments.contains("-vn"), presetName)
                    XCTAssertFalse(arguments.contains("-an"), presetName)
                case .videoAndAudio, .streamCopy:
                    XCTAssertFalse(arguments.contains("-an"), presetName)
                    XCTAssertFalse(arguments.contains("-vn"), presetName)
                }
            }
        }
    }

    func testStreamCopyExcludesSubtitlesButPreservesAudioAndVideoMappings() throws {
        try withDefaultPresetSettings {
            let arguments = ExportPreset.streamCopy.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map", "0"))
            XCTAssertTrue(arguments.containsAdjacent("-map", "-0:s?"))
            XCTAssertFalse(arguments.contains("-0:t?"))
            XCTAssertEqual(videoCodec(in: arguments), "copy")
            XCTAssertEqual(audioCodec(in: arguments), "copy")
        }
    }

    func testCodecPresetsRespectContainerAndOpusCompatibility() throws {
        let presets: [(preset: ExportPreset, containerKey: String, audioKey: String)] = [
            (.h264, AppConstants.h264ContainerKey, AppConstants.h264AudioFormatKey),
            (.h265, AppConstants.h265ContainerKey, AppConstants.h265AudioFormatKey),
            (.av1, AppConstants.av1ContainerKey, AppConstants.av1AudioFormatKey)
        ]
        let containers: [(container: CodecContainer, audioCodec: String, usesFastStart: Bool)] = [
            (.mp4, "aac", true),
            (.mov, "aac", true),
            (.mkv, "libopus", false)
        ]

        for preset in presets {
            for expectation in containers {
                try withPresetSettings([
                    preset.containerKey: expectation.container.rawValue,
                    preset.audioKey: CodecAudioFormat.opus.rawValue
                ]) {
                    let arguments = preset.preset.ffmpegArguments
                    let context = "\(preset.preset.rawValue) / \(expectation.container.rawValue)"

                    XCTAssertEqual(
                        preset.preset.outputExtension(for: nil),
                        expectation.container.fileExtension,
                        context
                    )
                    XCTAssertEqual(audioCodec(in: arguments), expectation.audioCodec, context)
                    XCTAssertEqual(
                        arguments.containsAdjacent("-movflags", "+faststart"),
                        expectation.usesFastStart,
                        context
                    )
                }
            }
        }
    }

    func testAV2UsesDedicatedEncoderRouteInsteadOfFFmpegCodecArguments() throws {
        try withDefaultPresetSettings {
            XCTAssertEqual(ExportPreset.av2.outputExtension(for: nil), "ivf")
            XCTAssertEqual(ExportPreset.av2.ffmpegArguments, ["-hide_banner"])
            XCTAssertNil(videoCodec(in: ExportPreset.av2.ffmpegArguments))
            XCTAssertNil(audioCodec(in: ExportPreset.av2.ffmpegArguments))
        }
    }

    private func presetVideoArguments() -> [String] {
        [
            "-vf",
            "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
        ]
    }

    private func centeredSquareCropForAnamorphicHD() -> CropConfig {
        let cropWidth = 1080.0 / 1920.0
        return CropConfig(
            normalizedRect: CropRect(x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1)
        )
    }

    private func videoFilter(in args: [String]) throws -> String {
        let index = try XCTUnwrap(args.firstIndex(of: "-vf"))
        return try XCTUnwrap(args.indices.contains(index + 1) ? args[index + 1] : nil)
    }

    private func videoCodec(in arguments: [String]) -> String? {
        optionValue(in: arguments, options: ["-c:v", "-vcodec", "-c"])
    }

    private func audioCodec(in arguments: [String]) -> String? {
        optionValue(in: arguments, options: ["-c:a", "-acodec", "-c"])
    }

    private func optionValue(in arguments: [String], options: [String]) -> String? {
        for option in options {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
                continue
            }
            return arguments[index + 1]
        }
        return nil
    }

    private func withDefaultPresetSettings(_ body: () throws -> Void) throws {
        try withPresetSettings([:], body)
    }

    private func withPresetSettings(_ overrides: [String: Any], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let argumentDomain = "NSArgumentDomain"
        let originalArguments = defaults.volatileDomain(forName: argumentDomain)
        var testArguments = originalArguments
        testArguments.merge(defaultPresetSettings) { _, testValue in testValue }
        testArguments.merge(overrides) { _, testValue in testValue }

        defaults.removeVolatileDomain(forName: argumentDomain)
        defaults.setVolatileDomain(testArguments, forName: argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: argumentDomain)
            defaults.setVolatileDomain(originalArguments, forName: argumentDomain)
        }

        try body()
    }

    private var defaultPresetSettings: [String: Any] {
        [
            AppConstants.preserveMetadataPreferenceKey: false,
            AppConstants.animatedStillFormatKey: AppConstants.defaultAnimatedStillFormat,
            AppConstants.h264EncoderKey: AppConstants.defaultH264Encoder,
            AppConstants.h264ContainerKey: AppConstants.defaultH264Container,
            AppConstants.h264AudioFormatKey: AppConstants.defaultH264AudioFormat,
            AppConstants.h265EncoderKey: AppConstants.defaultH265Encoder,
            AppConstants.h265ContainerKey: AppConstants.defaultH265Container,
            AppConstants.h265AudioFormatKey: AppConstants.defaultH265AudioFormat,
            AppConstants.av1ContainerKey: AppConstants.defaultAV1Container,
            AppConstants.av1AudioFormatKey: AppConstants.defaultAV1AudioFormat,
            AppConstants.tvFramerateModeKey: AppConstants.defaultTVFramerateMode,
            AppConstants.tvResolutionLimitKey: AppConstants.defaultTVResolutionLimit,
            AppConstants.avcIntraClassKey: AppConstants.defaultAVCIntraClass,
            AppConstants.avcIntraAudioChannelsKey: AppConstants.defaultAVCIntraAudioChannels,
            AppConstants.proResProfileKey: ProResProfile.standard.rawValue,
            AppConstants.proxyCodecKey: AppConstants.defaultProxyCodec,
            AppConstants.proxyResolutionLimitKey: AppConstants.defaultProxyResolutionLimit,
            AppConstants.streamCopyContainerKey: AppConstants.defaultStreamCopyContainer,
            AppConstants.audioOnlyFormatKey: AppConstants.defaultAudioOnlyFormat,
            AppConstants.audioOnlyBitDepthKey: AppConstants.defaultAudioOnlyBitDepth,
            AppConstants.imageSequenceExportFormatKey: AppConstants.defaultImageSequenceExportFormat,
            AppConstants.dcpResolutionKey: AppConstants.defaultDCPResolution,
            AppConstants.dcpFrameRateKey: AppConstants.defaultDCPFrameRate,
            AppConstants.dcpBitrateKey: AppConstants.defaultDCPBitrate,
            AppConstants.dcpScalingModeKey: AppConstants.defaultDCPScalingMode,
            AppConstants.imfResolutionKey: AppConstants.defaultIMFResolution,
            AppConstants.imfFrameRateKey: AppConstants.defaultIMFFrameRate,
            AppConstants.imfScalingModeKey: AppConstants.defaultIMFScalingMode,
            AppConstants.imfJ2KColorEncodingKey: AppConstants.defaultIMFJ2KColorEncoding,
            AppConstants.imfJ2KBitrateKey: AppConstants.defaultIMFJ2KBitrate,
            AppConstants.imfProResProfileKey: AppConstants.defaultIMFProResProfile,
            AppConstants.av2ContainerKey: AppConstants.defaultAV2Container
        ]
    }

    @discardableResult
    private func runFFmpeg(_ arguments: [String]) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceBinary = sourceRoot
            .appendingPathComponent("Aagedal Media Converter", isDirectory: true)
            .appendingPathComponent("Binaries", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        let executableURL = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) ?? sourceBinary

        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(decoding: errorData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, log)
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "AagedalMediaConverterTests.FFmpeg",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: log]
            )
        }
        return log
    }

}

private extension Array where Element == String {
    func containsAdjacent(_ first: String, _ second: String) -> Bool {
        indices.contains { index in
            self[index] == first && indices.contains(index + 1) && self[index + 1] == second
        }
    }
}

private struct PresetCommandExpectation {
    enum Media {
        case videoOnly
        case audioOnly
        case videoAndAudio
        case streamCopy
    }

    let preset: ExportPreset
    let outputExtension: String
    let videoCodec: String?
    let audioCodec: String?
    let media: Media

    init(
        _ preset: ExportPreset,
        extension outputExtension: String,
        videoCodec: String?,
        audioCodec: String?,
        media: Media
    ) {
        self.preset = preset
        self.outputExtension = outputExtension
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.media = media
    }
}
