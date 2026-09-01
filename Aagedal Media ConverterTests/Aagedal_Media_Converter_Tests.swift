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

    func testMetadataStrategyEitherMapsSourceMetadataOrStripsItDeterministically() throws {
        try withPresetSettings([AppConstants.preserveMetadataPreferenceKey: true]) {
            let arguments = ExportPreset.h264.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map_metadata", "0"))
            XCTAssertTrue(arguments.containsAdjacent("-map_chapters", "0"))
            XCTAssertFalse(arguments.containsAdjacent("-fflags", "+bitexact"))
            XCTAssertFalse(arguments.containsAdjacent("-metadata:s:v:0", "encoder="))
            XCTAssertFalse(arguments.containsAdjacent("-metadata:s:a:0", "encoder="))
        }

        try withPresetSettings([AppConstants.preserveMetadataPreferenceKey: false]) {
            let arguments = ExportPreset.h264.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map_metadata", "-1"))
            XCTAssertTrue(arguments.containsAdjacent("-map_chapters", "-1"))
            XCTAssertTrue(arguments.containsAdjacent("-fflags", "+bitexact"))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:v:0", "encoder="))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:a:0", "encoder="))
        }
    }

    func testManualTimecodeReplacesPresetTimecodeMetadata() async {
        var arguments = [
            "-metadata", "title=Example",
            "-metadata", "timecode=01:00:00:00",
            "-c:v", "libx264"
        ]

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .manual("10:20:30:12")),
            sourceMetadata: videoMetadata(timecode: "02:00:00:00", frameRate: 24),
            trimStart: nil
        )

        XCTAssertEqual(arguments.adjacentPairCount("-metadata", "timecode=10:20:30:12"), 1)
        XCTAssertEqual(arguments.adjacentPairCount("-metadata:s:v:0", "timecode=10:20:30:12"), 1)
        XCTAssertFalse(arguments.containsAdjacent("-metadata", "timecode=01:00:00:00"))
        XCTAssertTrue(arguments.containsAdjacent("-metadata", "title=Example"))
    }

    func testManualTimecodeDoesNotRequireSourceMetadata() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .manual("10:20:30:12")),
            sourceMetadata: nil,
            trimStart: nil
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=10:20:30:12"))
    }

    func testDisabledItemTimecodeClearsMappedMetadataWithoutReloadingGlobalDefault() async throws {
        try await withPresetSettingsAsync([
            AppConstants.defaultTimecodeModeKey: "manual",
            AppConstants.defaultTimecodeValueKey: "09:08:07:06"
        ]) {
            var arguments: [String] = []

            await FFMPEGCommandBuilder.applyConfiguredTimecode(
                &arguments,
                preset: .h264,
                inputURL: URL(fileURLWithPath: "/tmp/missing-source.mov"),
                timecodeConfig: nil,
                trimStart: nil
            )

            XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode="))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:v:0", "timecode="))
            XCTAssertFalse(arguments.contains("timecode=09:08:07:06"))
        }
    }

    func testGeneratedStreamCopyMOVPreservesReplacesAndRemovesTimecodeTracks() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterTimecodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let sourceTimecode = "01:02:03:04"
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:s=32x32:r=24:d=1",
            "-c:v", "libx264",
            "-metadata", "timecode=\(sourceTimecode)",
            sourceURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.preserveMetadataPreferenceKey: true
        ]) {
            let preservedURL = temporaryDirectory.appendingPathComponent("preserved.mov")
            let preservedCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: preservedURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: TimecodeConfig(mode: .preserveSource),
                sourceMetadata: videoMetadata(timecode: sourceTimecode, frameRate: 24)
            )
            try runFFmpeg(preservedCommand.arguments)

            let preservedInspection = try inspectMedia(at: preservedURL)
            XCTAssertTrue(preservedInspection.contains("tmcd"), preservedInspection)
            XCTAssertTrue(preservedInspection.contains(sourceTimecode), preservedInspection)

            let manualURL = temporaryDirectory.appendingPathComponent("manual.mov")
            let manualTimecode = "10:20:30:12"
            let manualCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: manualURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: TimecodeConfig(mode: .manual(manualTimecode))
            )
            try runFFmpeg(manualCommand.arguments)

            let manualInspection = try inspectMedia(at: manualURL)
            XCTAssertTrue(manualInspection.contains("tmcd"), manualInspection)
            XCTAssertTrue(manualInspection.contains(manualTimecode), manualInspection)
            XCTAssertFalse(manualInspection.contains(sourceTimecode), manualInspection)

            let disabledURL = temporaryDirectory.appendingPathComponent("disabled.mov")
            let disabledCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: disabledURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: nil
            )
            try runFFmpeg(disabledCommand.arguments)

            let disabledInspection = try inspectMedia(at: disabledURL)
            XCTAssertFalse(disabledInspection.contains("tmcd"), disabledInspection)
            XCTAssertFalse(disabledInspection.contains(sourceTimecode), disabledInspection)
        }
    }

    func testPreservedTimecodeOffsetsByTrimAtSourceFrameRate() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "01:02:03:12", frameRate: 24),
            trimStart: 1.5
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=01:02:05:00"))
    }

    func testPreservedDropFrameTimecodeSkipsInvalidMinuteLabels() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:59;29", frameRate: 30_000.0 / 1_001.0),
            trimStart: 1_001.0 / 30_000.0
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=00:01:00;02"))
    }

    func testPreservedDropFrameTimecodeSupports5994AndTenMinuteBoundary() async {
        var minuteBoundaryArguments: [String] = []
        await FFMPEGCommandBuilder.applyTimecode(
            &minuteBoundaryArguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:59;59", frameRate: 60_000.0 / 1_001.0),
            trimStart: 1_001.0 / 60_000.0
        )
        XCTAssertTrue(minuteBoundaryArguments.containsAdjacent("-metadata", "timecode=00:01:00;04"))

        var tenMinuteBoundaryArguments: [String] = []
        await FFMPEGCommandBuilder.applyTimecode(
            &tenMinuteBoundaryArguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:09:59;29", frameRate: 30_000.0 / 1_001.0),
            trimStart: 1_001.0 / 30_000.0
        )
        XCTAssertTrue(tenMinuteBoundaryArguments.containsAdjacent("-metadata", "timecode=00:10:00;00"))
    }

    func testTimecodeOffsetAtVeryLowFrameRateReturnsOriginalInsteadOfDividingByZero() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:00:00", frameRate: 0.25),
            trimStart: 1
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=00:00:00:00"))
    }

    func testImageSequenceInputArgumentsIncludeFrameRangeAndOptionalAudio() {
        let directory = URL(fileURLWithPath: "/tmp/frames", isDirectory: true)
        let audioURL = URL(fileURLWithPath: "/tmp/guide.wav")
        let config = ImageSequenceConfig(
            pattern: "shot_%04d.exr",
            directory: directory,
            startNumber: 1001,
            endNumber: 1048,
            frameRate: 24,
            imageFormat: .exr,
            associatedAudioURL: audioURL
        )

        XCTAssertEqual(config.frameCount, 48)
        XCTAssertEqual(config.durationSeconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(config.firstFrameURL.path, "/tmp/frames/shot_1001.exr")
        var percentPrefixConfig = config
        percentPrefixConfig.pattern = "shot%done_%04d.exr"
        percentPrefixConfig.startNumber = 7
        XCTAssertEqual(percentPrefixConfig.firstFrameURL.path, "/tmp/frames/shot%done_0007.exr")
        XCTAssertEqual(
            config.ffmpegInputArguments,
            [
                "-framerate", "24.000",
                "-start_number", "1001",
                "-i", "/tmp/frames/shot_%04d.exr",
                "-i", "/tmp/guide.wav"
            ]
        )
    }

    func testImageSequenceJPEGExportAppliesSelectedEncoderAndQuality() throws {
        try withPresetSettings([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.jpeg.rawValue,
            AppConstants.imageSequenceExportQualityKey: 7
        ]) {
            let arguments = ExportPreset.imageSequence.ffmpegArguments

            XCTAssertEqual(ExportPreset.imageSequence.outputExtension(for: nil), "jpg")
            XCTAssertEqual(videoCodec(in: arguments), "mjpeg")
            XCTAssertTrue(arguments.containsAdjacent("-q:v", "7"))
            XCTAssertTrue(arguments.contains("-an"))
            XCTAssertFalse(arguments.contains("-map_metadata"))
        }
    }

    func testGeneratedImageSequenceExportRetainsEncoderAndAppliesCrop() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterImageSequenceCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputPatternURL = temporaryDirectory.appendingPathComponent("frame_%03d.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=red:s=64x32:r=1,drawbox=x=32:y=0:w=32:h=32:c=lime:t=fill",
            "-frames:v", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", fixtureURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.png.rawValue
        ]) {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: fixtureURL,
                outputFileURL: outputPatternURL,
                preset: .imageSequence,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: CropConfig(
                    normalizedRect: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                )
            )

            XCTAssertTrue(command.arguments.containsAdjacent("-c:v", "png"))
            XCTAssertEqual(try videoFilter(in: command.arguments), "crop=32:32:32:0")
            try runFFmpeg(command.arguments)
        }

        let outputURL = temporaryDirectory.appendingPathComponent("frame_001.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let rawURL = temporaryDirectory.appendingPathComponent("cropped.rgb")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", rawURL.path
        ])

        let pixels = try Data(contentsOf: rawURL)
        XCTAssertEqual(pixels.count, 32 * 32 * 3)
        let centerPixelOffset = ((16 * 32) + 16) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testGeneratedImageSequenceInputUsesFirstFrameGeometryForCrop() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterImageSequenceInputCropTests-\(UUID().uuidString)", isDirectory: true)
        let inputDirectory = temporaryDirectory.appendingPathComponent("input", isDirectory: true)
        let outputDirectory = temporaryDirectory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputPatternURL = inputDirectory.appendingPathComponent("source_%04d.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=red:s=64x32:r=1:d=2,drawbox=x=32:y=0:w=32:h=32:c=lime:t=fill",
            "-frames:v", "2", "-start_number", "1001", inputPatternURL.path
        ])

        let config = ImageSequenceConfig(
            pattern: "source_%04d.png",
            directory: inputDirectory,
            startNumber: 1001,
            endNumber: 1002,
            frameRate: 1,
            imageFormat: .png
        )
        let outputPatternURL = outputDirectory.appendingPathComponent("cropped_%03d.png")

        try await withPresetSettingsAsync([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.png.rawValue
        ]) {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: inputDirectory,
                outputFileURL: outputPatternURL,
                preset: .imageSequence,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: CropConfig(
                    normalizedRect: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                ),
                visualSourceURL: config.firstFrameURL,
                customInputArguments: config.ffmpegInputArguments,
                additionalOutputArguments: ["-frames:v", "1"]
            )

            XCTAssertEqual(try videoFilter(in: command.arguments), "crop=32:32:32:0")
            try runFFmpeg(command.arguments)
        }

        let outputURL = outputDirectory.appendingPathComponent("cropped_001.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let rawURL = temporaryDirectory.appendingPathComponent("cropped.rgb")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", rawURL.path
        ])

        let pixels = try Data(contentsOf: rawURL)
        XCTAssertEqual(pixels.count, 32 * 32 * 3)
        let centerPixelOffset = ((16 * 32) + 16) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testDCPCommandUsesSelectedCinemaProfileRateAndFitGeometry() throws {
        try withPresetSettings([
            AppConstants.dcpResolutionKey: DCPResolution.fourKFull.rawValue,
            AppConstants.dcpFrameRateKey: DCPFrameRate.fps24.rawValue,
            AppConstants.dcpBitrateKey: DCPBitrate.max.rawValue,
            AppConstants.dcpScalingModeKey: DCPScalingMode.fit.rawValue
        ]) {
            let arguments = ExportPreset.dcp.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-profile", "cinema4k"))
            XCTAssertTrue(arguments.containsAdjacent("-cinema_mode", "4k_24"))
            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "xyz12le"))
            XCTAssertTrue(arguments.containsAdjacent("-b:v", "250M"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "24"))
            XCTAssertTrue(arguments.containsAdjacent(
                "-vf",
                "scale=iw*sar:ih,setsar=1,scale=4096:2160:force_original_aspect_ratio=decrease,pad=4096:2160:-1:-1:color=black"
            ))
        }
    }

    func testPackageAudioExtractionUsesEntireConcatSource() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterConcatAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstAudioURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondAudioURL = temporaryDirectory.appendingPathComponent("second.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-c:a", "pcm_s16le", firstAudioURL.path
        ])
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=0.5",
            "-c:a", "pcm_s16le", secondAudioURL.path
        ])

        let listURL = temporaryDirectory.appendingPathComponent("inputs.ffconcat")
        let list = "file '\(firstAudioURL.path)'\nfile '\(secondAudioURL.path)'\n"
        try Data(list.utf8).write(to: listURL)

        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: firstAudioURL,
            customInputArguments: ["-f", "concat", "-safe", "0", "-i", listURL.path],
            outputFolder: temporaryDirectory,
            ffmpegPath: ffmpegExecutableURL.path,
            trimStart: nil,
            trimEnd: nil
        )

        let outputURL: URL
        switch result {
        case .extracted(let url):
            outputURL = url
        case .noAudioInSource:
            return XCTFail("Concat source was incorrectly treated as silent")
        case .failed(let reason):
            return XCTFail("Concat audio extraction failed: \(reason)")
        }

        let duration = try XCTUnwrap(ParsingUtils.parseDuration(from: inspectMedia(at: outputURL)))
        XCTAssertEqual(duration, 1.0, accuracy: 0.02)
    }

    func testPackageAudioExtractionUsesImageSequenceCompanionAudio() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSequenceAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("sequence.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=0.75",
            "-c:a", "pcm_s24le", audioURL.path
        ])

        let config = ImageSequenceConfig(
            pattern: "frame_%04d.png",
            directory: temporaryDirectory,
            startNumber: 1,
            endNumber: 18,
            frameRate: 24,
            imageFormat: .png,
            associatedAudioURL: audioURL
        )
        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: temporaryDirectory,
            customInputArguments: config.ffmpegInputArguments,
            outputFolder: temporaryDirectory,
            ffmpegPath: ffmpegExecutableURL.path,
            trimStart: nil,
            trimEnd: nil
        )

        let outputURL: URL
        switch result {
        case .extracted(let url):
            outputURL = url
        case .noAudioInSource:
            return XCTFail("Image-sequence companion audio was incorrectly treated as missing")
        case .failed(let reason):
            return XCTFail("Image-sequence audio extraction failed: \(reason)")
        }

        let duration = try XCTUnwrap(ParsingUtils.parseDuration(from: inspectMedia(at: outputURL)))
        XCTAssertEqual(duration, 0.75, accuracy: 0.02)
    }

    func testDCPManifestAssemblyMovesDummyEssencesAndBuildsConsistentAssets() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterDCPManifestTests-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = temporaryDirectory.appendingPathComponent("Package & Delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoSource = temporaryDirectory.appendingPathComponent("picture.mxf")
        let audioSource = temporaryDirectory.appendingPathComponent("sound.mxf")
        let videoData = Data("dummy DCP picture essence".utf8)
        let audioData = Data("dummy DCP sound essence".utf8)
        try videoData.write(to: videoSource)
        try audioData.write(to: audioSource)

        let assembled = await DCPService.shared.assembleDCP(
            videoMXFURL: videoSource,
            audioMXFURL: audioSource,
            outputDirectoryURL: packageDirectory,
            title: "Feature & <Trailer>",
            resolution: .twoKFlat,
            frameRate: .fps24,
            frameCount: 48,
            itemMetadata: DCPItemMetadata(
                contentKind: .trailer,
                annotationText: "QC & mastering <approved>",
                ratingLabel: "PG & 12",
                audioLanguage: "nb"
            ),
            progress: { _ in }
        )

        XCTAssertTrue(assembled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioSource.path))

        let files = try FileManager.default.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: nil
        )
        let videoURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("j2c_") })
        let audioURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("pcm_") })
        let cplURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("cpl_") })
        let pklURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("pkl_") })
        let assetMapURL = packageDirectory.appendingPathComponent("ASSETMAP.xml")

        XCTAssertEqual(try Data(contentsOf: videoURL), videoData)
        XCTAssertEqual(try Data(contentsOf: audioURL), audioData)
        try assertPackingList(
            at: pklURL,
            describes: [cplURL, videoURL, audioURL]
        )
        try assertAssetMap(
            at: assetMapURL,
            describes: [pklURL, cplURL, videoURL, audioURL]
        )

        XCTAssertEqual(try xmlTexts(named: "ContentTitleText", at: cplURL), ["Feature & <Trailer>"])
        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: cplURL).first, "QC & mastering <approved>")
        XCTAssertEqual(try xmlTexts(named: "ContentKind", at: cplURL), [DCPContentKind.trailer.rawValue])
        XCTAssertEqual(try xmlTexts(named: "Language", at: cplURL), ["nb"])
        XCTAssertEqual(try xmlTexts(named: "IntrinsicDuration", at: cplURL), ["48", "48", "48"])
        XCTAssertTrue(try xmlTexts(named: "EditRate", at: cplURL).allSatisfy { $0 == "24 1" })
        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: pklURL).first, "QC & mastering <approved>")
    }

    func testIMFManifestAssemblyMovesDummyEssencesAndRoundTripsPackage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterIMFManifestTests-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = temporaryDirectory.appendingPathComponent("IMP Package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoSource = temporaryDirectory.appendingPathComponent("picture.mxf")
        let audioSource = temporaryDirectory.appendingPathComponent("sound.mxf")
        let videoData = Data("dummy IMF picture essence".utf8)
        let audioData = Data("dummy IMF sound essence".utf8)
        try videoData.write(to: videoSource)
        try audioData.write(to: audioSource)

        let assembled = await IMFManifestWriter.shared.assembleIMP(
            videoMXFURL: videoSource,
            audioMXFURL: audioSource,
            outputDirectoryURL: packageDirectory,
            title: "Episode & <Special>",
            application: .app2e,
            editRateNumerator: 30_000,
            editRateDenominator: 1_001,
            frameCount: 90,
            itemMetadata: IMFItemMetadata(
                contentKind: .episode,
                annotationText: "Archive & delivery <master>",
                audioLanguage: "nb"
            ),
            progress: { _ in }
        )

        XCTAssertTrue(assembled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioSource.path))

        let files = try FileManager.default.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: nil
        )
        let videoURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("video_") })
        let audioURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("audio_") })
        let cplURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("CPL_") })
        let pklURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("PKL_") })
        let assetMapURL = packageDirectory.appendingPathComponent("ASSETMAP.xml")

        XCTAssertEqual(try Data(contentsOf: videoURL), videoData)
        XCTAssertEqual(try Data(contentsOf: audioURL), audioData)
        try assertPackingList(
            at: pklURL,
            describes: [cplURL, videoURL, audioURL]
        )
        try assertAssetMap(
            at: assetMapURL,
            describes: [pklURL, cplURL, videoURL, audioURL]
        )

        let parsed = try IMFPackageParser.parsePackage(folder: packageDirectory)
        XCTAssertEqual(parsed.contentTitle, "Episode & <Special>")
        XCTAssertEqual(parsed.essences.map(\.kind), [.mainImage, .mainAudio])
        XCTAssertEqual(
            parsed.essences.map { $0.mxfURL.resolvingSymlinksInPath().path },
            [videoURL, audioURL].map { $0.resolvingSymlinksInPath().path }
        )
        XCTAssertEqual(try Data(contentsOf: parsed.essences[0].mxfURL), videoData)
        XCTAssertEqual(try Data(contentsOf: parsed.essences[1].mxfURL), audioData)

        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: cplURL).first, "Archive & delivery <master>")
        XCTAssertEqual(try xmlTexts(named: "ContentKind", at: cplURL), [IMFContentKind.episode.rawValue])
        XCTAssertEqual(try xmlTexts(named: "EditRate", at: cplURL), ["30000 1001"])
        XCTAssertEqual(try xmlTexts(named: "IntrinsicDuration", at: cplURL), ["90", "90"])
        XCTAssertEqual(try xmlTexts(named: "SourceDuration", at: cplURL), ["90", "90"])
    }

    func testPackageManifestAssemblyOmitsAudioAssetsWhenSourceHasNoAudio() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSilentPackageTests-\(UUID().uuidString)", isDirectory: true)
        let dcpDirectory = temporaryDirectory.appendingPathComponent("DCP", isDirectory: true)
        let imfDirectory = temporaryDirectory.appendingPathComponent("IMF", isDirectory: true)
        try FileManager.default.createDirectory(at: dcpDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imfDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let dcpVideoSource = temporaryDirectory.appendingPathComponent("dcp-picture.mxf")
        let imfVideoSource = temporaryDirectory.appendingPathComponent("imf-picture.mxf")
        try Data("silent DCP picture essence".utf8).write(to: dcpVideoSource)
        try Data("silent IMF picture essence".utf8).write(to: imfVideoSource)

        let dcpAssembled = await DCPService.shared.assembleDCP(
            videoMXFURL: dcpVideoSource,
            audioMXFURL: nil,
            outputDirectoryURL: dcpDirectory,
            title: "Silent DCP",
            resolution: .twoKFlat,
            frameRate: .fps24,
            frameCount: 24,
            progress: { _ in }
        )
        let imfAssembled = await IMFManifestWriter.shared.assembleIMP(
            videoMXFURL: imfVideoSource,
            audioMXFURL: nil,
            outputDirectoryURL: imfDirectory,
            title: "Silent IMF",
            application: .app5,
            editRateNumerator: 24,
            editRateDenominator: 1,
            frameCount: 24,
            progress: { _ in }
        )
        XCTAssertTrue(dcpAssembled)
        XCTAssertTrue(imfAssembled)

        let dcpFiles = try FileManager.default.contentsOfDirectory(at: dcpDirectory, includingPropertiesForKeys: nil)
        let dcpVideoURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("j2c_") })
        let dcpCPLURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("cpl_") })
        let dcpPKLURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("pkl_") })
        XCTAssertFalse(dcpFiles.contains { $0.lastPathComponent.hasPrefix("pcm_") })
        XCTAssertTrue(try xmlTexts(named: "MainSound", at: dcpCPLURL).isEmpty)
        try assertPackingList(at: dcpPKLURL, describes: [dcpCPLURL, dcpVideoURL])
        try assertAssetMap(
            at: dcpDirectory.appendingPathComponent("ASSETMAP.xml"),
            describes: [dcpPKLURL, dcpCPLURL, dcpVideoURL]
        )

        let imfFiles = try FileManager.default.contentsOfDirectory(at: imfDirectory, includingPropertiesForKeys: nil)
        let imfVideoURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("video_") })
        let imfCPLURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("CPL_") })
        let imfPKLURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("PKL_") })
        XCTAssertFalse(imfFiles.contains { $0.lastPathComponent.hasPrefix("audio_") })
        XCTAssertTrue(try xmlTexts(named: "MainAudioSequence", at: imfCPLURL).isEmpty)
        try assertPackingList(at: imfPKLURL, describes: [imfCPLURL, imfVideoURL])
        try assertAssetMap(
            at: imfDirectory.appendingPathComponent("ASSETMAP.xml"),
            describes: [imfPKLURL, imfCPLURL, imfVideoURL]
        )
        XCTAssertEqual(try IMFPackageParser.parsePackage(folder: imfDirectory).essences.map(\.kind), [.mainImage])
    }

    func testIMFJ2KCommandUsesRationalRateHDRTagsAndFillGeometry() throws {
        try withPresetSettings([
            AppConstants.imfResolutionKey: IMFResolution.uhd2160.rawValue,
            AppConstants.imfFrameRateKey: IMFFrameRate.fps29_97.rawValue,
            AppConstants.imfScalingModeKey: IMFScalingMode.fill.rawValue,
            AppConstants.imfJ2KColorEncodingKey: IMFColorEncoding.rec2020PQ.rawValue,
            AppConstants.imfJ2KBitrateKey: DCPBitrate.high.rawValue
        ]) {
            let arguments = ExportPreset.imfJ2K.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "yuv422p10le"))
            XCTAssertTrue(arguments.containsAdjacent("-color_primaries", "bt2020"))
            XCTAssertTrue(arguments.containsAdjacent("-color_trc", "smpte2084"))
            XCTAssertTrue(arguments.containsAdjacent("-colorspace", "bt2020nc"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "30000/1001"))
            XCTAssertTrue(arguments.containsAdjacent(
                "-vf",
                "scale=iw*sar:ih,setsar=1,scale=3840:2160:force_original_aspect_ratio=increase,crop=3840:2160"
            ))
            XCTAssertFalse(arguments.contains("-cinema_mode"))
        }
    }

    func testIMFPictureFrameCountPrefersProducedFramesAndFallsBackToDuration() {
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: 48,
                duration: 1.1,
                editRateNumerator: 24,
                editRateDenominator: 1
            ),
            48
        )
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: nil,
                duration: 10,
                editRateNumerator: 30_000,
                editRateDenominator: 1_001
            ),
            300
        )
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: nil,
                duration: nil,
                editRateNumerator: 24,
                editRateDenominator: 1
            ),
            0
        )
    }

    func testIMFProResCommandUsesSelectedProfileAndHLGTags() throws {
        try withPresetSettings([
            AppConstants.imfResolutionKey: IMFResolution.uhd2160.rawValue,
            AppConstants.imfFrameRateKey: IMFFrameRate.fps59_94.rawValue,
            AppConstants.imfScalingModeKey: IMFScalingMode.fit.rawValue,
            AppConstants.imfJ2KColorEncodingKey: IMFColorEncoding.rec2020HLG.rawValue,
            AppConstants.imfProResProfileKey: IMFProResProfile.proRes4444XQ.rawValue
        ]) {
            let arguments = ExportPreset.imfProRes.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-profile:v", "5"))
            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "yuva444p10le"))
            XCTAssertTrue(arguments.containsAdjacent("-color_primaries", "bt2020"))
            XCTAssertTrue(arguments.containsAdjacent("-color_trc", "arib-std-b67"))
            XCTAssertTrue(arguments.containsAdjacent("-colorspace", "bt2020nc"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "60000/1001"))
        }
    }

    func testAV2ChunkPlanningRespectsRateControlAndMinimumChunkSize() {
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 240, hint: 8, rateMode: .targetBitrate),
            1
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 47, hint: 8, rateMode: .constantQuality),
            1
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 48, hint: 8, rateMode: .constantQuality),
            2
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 240, hint: 8, rateMode: .constantQuality),
            8
        )
    }

    func testAV2EffectiveDurationHandlesEveryTrimShape() {
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: nil,
                trimEnd: nil
            ),
            10
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 2.5,
                trimEnd: nil
            ),
            7.5
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: nil,
                trimEnd: 4
            ),
            4
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 2,
                trimEnd: 6
            ),
            4
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 8,
                trimEnd: 20
            ),
            2
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 12,
                trimEnd: nil
            ),
            0
        )
    }

    func testGeneratedAV2StartOnlyTrimPlansOnlyRemainingFrames() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2TrimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=32x32:rate=24:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            fixtureURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue
        ]) {
            let builtPlan = await AV2CommandBuilder.buildSegments(
                inputURL: fixtureURL,
                trimStart: 1.5,
                trimEnd: nil,
                cropConfig: nil
            )
            let plan = try XCTUnwrap(builtPlan)
            defer { try? FileManager.default.removeItem(at: plan.segmentDirectory) }

            XCTAssertEqual(plan.effectiveDuration ?? -1, 2.5, accuracy: 0.02)
            XCTAssertEqual(plan.frameRate ?? -1, 24, accuracy: 0.01)
            XCTAssertEqual(plan.totalFrames, 60)
            XCTAssertEqual(plan.segments.map(\.frameCount).reduce(0, +), plan.totalFrames)
            XCTAssertEqual(plan.segments.count, 2)
            XCTAssertTrue(plan.segments[0].ffmpegArguments.containsAdjacent("-ss", "1.500000"))
            XCTAssertTrue(plan.segments[1].ffmpegArguments.containsAdjacent("-ss", "2.750000"))
            XCTAssertEqual(plan.segments.last?.frameCount, 30)
        }
    }

    func testAudioRoutingPreservesSelectionOrderAndDuplicateTracks() {
        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 1)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-map", "0:a:1", "-map", "0:a:0", "-map", "0:a:1"]
        )
    }

    func testAudioRoutingSupportsRemovingAllTracks() {
        let config = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2)],
            outputTracks: []
        )

        XCTAssertEqual(AudioRoutingService.buildFFmpegMapArguments(config: config), [])
    }

    func testAudioRoutingBuildsMixedDownmixAndPassThroughFilters() {
        let tracks = [audioTrack(index: 0, channels: 6), audioTrack(index: 1, channels: 2)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 0, downmixToStereo: true),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            [
                "-filter_complex",
                "[0:a:0]aresample=ochl=stereo[aout0];[0:a:1]anull[aout1]",
                "-map", "[aout0]",
                "-map", "[aout1]"
            ]
        )
    }

    func testAudioRoutingBuildsChannelOperationMatrix() {
        let tracks = [
            audioTrack(index: 0, channels: 1, layout: "mono"),
            audioTrack(index: 1, channels: 1, layout: "mono"),
            audioTrack(index: 2, channels: 2, layout: "stereo"),
            audioTrack(index: 3, channels: 6, layout: "5.1")
        ]
        var config = AudioRoutingConfig(inputTracks: tracks)

        config.setChannelOperation(.mergeToStereo(trackIndices: [0, 1]))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:0][0:a:1]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[aout]", "-map", "[aout]"]
        )

        config.setChannelOperation(.splitToMono(trackIndex: 2))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:2]channelsplit=channel_layout=stereo[L][R]", "-map", "[L]", "-map", "[R]"]
        )

        config.setChannelOperation(.swapChannels(trackIndex: 2))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:2]pan=stereo|c0=c1|c1=c0[aout]", "-map", "[aout]"]
        )

        config.setChannelOperation(.extractChannel(trackIndex: 3, channelIndex: 4, channelName: "Ls"))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:3]pan=mono|c0=c4[aout]", "-map", "[aout]"]
        )
    }

    func testInvalidChannelOperationFallsBackToSelectedTracks() {
        let tracks = [audioTrack(index: 0, channels: 1), audioTrack(index: 1, channels: 2)]
        var config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [OutputTrack(streamIndex: 1)]
        )
        config.setChannelOperation(.splitToMono(trackIndex: 0))

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-map", "0:a:1"]
        )
    }

    func testApplyingAudioRoutingReusesVideoMapWhenAudioMapComesFirst() {
        var arguments = [
            "-map", "0:a",
            "-map", "0:v:0",
            "-c:v", "libx264",
            "-c:a", "aac"
        ]
        let config = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 1)],
            outputTracks: [OutputTrack(streamIndex: 1)]
        )

        FFMPEGCommandBuilder.applyAudioRouting(config: config, to: &arguments)

        XCTAssertEqual(arguments.adjacentPairCount("-map", "0:v:0"), 1)
        XCTAssertEqual(arguments.adjacentPairCount("-map", "0:a:1"), 1)
        XCTAssertFalse(arguments.containsAdjacent("-map", "0:a"))
    }

    func testSubtitleMappingOnlyTargetsSupportedContainers() {
        XCTAssertEqual(
            FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: "MKV"),
            ["-map", "0:s?", "-c:s", "copy"]
        )
        for outputExtension in ["mp4", "mov"] {
            XCTAssertEqual(
                FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: outputExtension),
                ["-map", "0:s?", "-c:s", "mov_text"],
                outputExtension
            )
        }
        for outputExtension in ["png", "avif", "mxf", "ivf", "wav"] {
            XCTAssertTrue(
                FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: outputExtension).isEmpty,
                outputExtension
            )
        }
        XCTAssertTrue(
            FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: false, outputExtension: "mkv").isEmpty
        )
    }

    func testAVCIntraMCALabelOverrideLabelsSourceChannelsButNotPadding() throws {
        try withDefaultPresetSettings {
            let content = try XCTUnwrap(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 2, channelLayout: "stereo", sampleRate: 48_000)
                ],
                inputMCALabels: [],
                overrides: [
                    0: MCALabelOverride(soundfield: .stereo, audioElement: .mainProgram)
                ],
                outputTrackCount: 4
            ))

            XCTAssertTrue(content.contains("0\nchL\nsgST, id=sg1\nggMPg, id=gosg1"), content)
            XCTAssertTrue(content.contains("1\nchR\nsgST, id=sg1, repeat=false\nggMPg, id=gosg1, repeat=false"), content)
            XCTAssertFalse(content.contains("\n2\n"), content)
        }
    }

    func testAVCIntraMCALabelsPreserveMatchingInputDualMonoLayout() throws {
        try withDefaultPresetSettings {
            let content = try XCTUnwrap(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 2, channelLayout: "stereo", sampleRate: 48_000)
                ],
                inputMCALabels: [
                    AudioTrackMCALabels(
                        trackNumber: 1,
                        channelCount: 2,
                        sampleRate: 48_000,
                        soundfieldGroup: "Dual Mono",
                        audioElement: nil,
                        channelLabels: ["M1", "M2"]
                    )
                ],
                outputTrackCount: 2
            ))

            XCTAssertTrue(content.contains("chM1"), content)
            XCTAssertTrue(content.contains("chM2"), content)
            XCTAssertTrue(content.contains("sgDM"), content)
            XCTAssertFalse(content.contains("gg"), content)
        }
    }

    func testAVCIntraMCALabelsOmitUnknownLayouts() throws {
        try withDefaultPresetSettings {
            XCTAssertNil(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 3, channelLayout: "3.0", sampleRate: 48_000)
                ],
                inputMCALabels: [],
                outputTrackCount: 4
            ))
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

    private func audioTrack(index: Int, channels: Int, layout: String? = nil) -> AudioTrackInfo {
        AudioTrackInfo(
            streamIndex: index,
            channels: channels,
            channelLayout: layout,
            codec: "pcm_s24le",
            codecLongName: nil,
            sampleRate: 48_000
        )
    }

    private func videoMetadata(timecode: String?, frameRate: Double) -> VideoMetadata {
        VideoMetadata(
            duration: 60,
            formatName: "mov",
            containerLongName: "QuickTime / MOV",
            sizeBytes: nil,
            bitRate: nil,
            comment: nil,
            timecode: timecode,
            timecodes: [],
            frameCount: nil,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [
                VideoMetadata.VideoStream(
                    codec: "h264",
                    codecLongName: nil,
                    profile: nil,
                    width: 1920,
                    height: 1080,
                    pixelFormat: "yuv420p",
                    hasAlpha: false,
                    pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: frameRate),
                    bitDepth: 8,
                    bitRate: nil,
                    duration: 60,
                    chromaSubsampling: "4:2:0",
                    colorPrimaries: nil,
                    colorTransfer: nil,
                    colorSpace: nil,
                    colorRange: nil,
                    chromaLocation: nil,
                    fieldOrder: nil,
                    isInterlaced: false,
                    title: nil,
                    isDefault: true,
                    isForced: false
                )
            ],
            audioStreams: [],
            subtitleStreams: []
        )
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

    private func withPresetSettingsAsync(
        _ overrides: [String: Any],
        _ body: () async throws -> Void
    ) async throws {
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

        try await body()
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
            AppConstants.avcIntraDefaultMCASoundfield1ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield2ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield6ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield8ChKey: "",
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
        let executableURL = ffmpegExecutableURL

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

    private var ffmpegExecutableURL: URL {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceBinary = sourceRoot
            .appendingPathComponent("Aagedal Media Converter", isDirectory: true)
            .appendingPathComponent("Binaries", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        return Bundle.main.url(forResource: "ffmpeg", withExtension: nil) ?? sourceBinary
    }

    private func inspectMedia(at url: URL) throws -> String {
        try runFFmpeg([
            "-hide_banner", "-i", url.path,
            "-map", "0", "-c", "copy",
            "-f", "null", "-"
        ])
    }

    private func assertPackingList(
        at packingListURL: URL,
        describes expectedFiles: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let assets = try xmlAssets(at: packingListURL)
        XCTAssertEqual(assets.count, expectedFiles.count, file: file, line: line)
        XCTAssertEqual(Set(assets.compactMap(\.id)).count, expectedFiles.count, file: file, line: line)

        for expectedFile in expectedFiles {
            let asset = try XCTUnwrap(
                assets.first { $0.originalFileName == expectedFile.lastPathComponent },
                "Missing PKL asset for \(expectedFile.lastPathComponent)",
                file: file,
                line: line
            )
            XCTAssertEqual(asset.size, SMPTEPackageUtils.fileSize(at: expectedFile), file: file, line: line)
            let expectedHash = try XCTUnwrap(
                SMPTEPackageUtils.computeSHA1(for: expectedFile),
                file: file,
                line: line
            )
            XCTAssertEqual(
                asset.hash,
                SMPTEPackageUtils.base64SHA1(hex: expectedHash),
                file: file,
                line: line
            )
        }
    }

    private func assertAssetMap(
        at assetMapURL: URL,
        describes expectedFiles: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let assets = try xmlAssets(at: assetMapURL)
        XCTAssertEqual(assets.count, expectedFiles.count, file: file, line: line)
        XCTAssertEqual(Set(assets.compactMap(\.id)).count, expectedFiles.count, file: file, line: line)

        for expectedFile in expectedFiles {
            let asset = try XCTUnwrap(
                assets.first { $0.path == expectedFile.lastPathComponent },
                "Missing ASSETMAP asset for \(expectedFile.lastPathComponent)",
                file: file,
                line: line
            )
            XCTAssertEqual(asset.size, SMPTEPackageUtils.fileSize(at: expectedFile), file: file, line: line)
        }

        XCTAssertEqual(
            assets.filter(\.isPackingList).map(\.path),
            [expectedFiles[0].lastPathComponent],
            file: file,
            line: line
        )

        let packingListAssets = try xmlAssets(at: expectedFiles[0])
        for expectedFile in expectedFiles.dropFirst() {
            let packingListID = packingListAssets.first {
                $0.originalFileName == expectedFile.lastPathComponent
            }?.id
            let assetMapID = assets.first { $0.path == expectedFile.lastPathComponent }?.id
            XCTAssertNotNil(packingListID, file: file, line: line)
            XCTAssertEqual(assetMapID, packingListID, file: file, line: line)
        }
    }

    private func xmlAssets(at url: URL) throws -> [ManifestAsset] {
        let document = try XMLDocument(contentsOf: url, options: [])
        return try document.nodes(forXPath: "//*[local-name()='Asset']").map { node in
            let sizeText = xmlText(named: "Size", below: node) ?? xmlText(named: "Length", below: node)
            return ManifestAsset(
                id: xmlText(named: "Id", below: node),
                hash: xmlText(named: "Hash", below: node),
                size: sizeText.flatMap(Int64.init),
                originalFileName: xmlText(named: "OriginalFileName", below: node),
                path: xmlText(named: "Path", below: node),
                isPackingList: xmlText(named: "PackingList", below: node) == "true"
            )
        }
    }

    private func xmlTexts(named name: String, at url: URL) throws -> [String] {
        let document = try XMLDocument(contentsOf: url, options: [])
        return try document.nodes(forXPath: "//*[local-name()='\(name)']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func xmlText(named name: String, below node: XMLNode) -> String? {
        guard let element = node as? XMLElement,
              let match = (try? element.nodes(forXPath: ".//*[local-name()='\(name)']"))?.first else {
            return nil
        }
        return match.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private extension Array where Element == String {
    func containsAdjacent(_ first: String, _ second: String) -> Bool {
        adjacentPairCount(first, second) > 0
    }

    func adjacentPairCount(_ first: String, _ second: String) -> Int {
        indices.reduce(into: 0) { count, index in
            if self[index] == first,
               indices.contains(index + 1),
               self[index + 1] == second {
                count += 1
            }
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

private struct ManifestAsset {
    let id: String?
    let hash: String?
    let size: Int64?
    let originalFileName: String?
    let path: String?
    let isPackingList: Bool
}
