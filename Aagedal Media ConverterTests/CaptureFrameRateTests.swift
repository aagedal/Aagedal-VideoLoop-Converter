import AVFoundation
import XCTest
import ScreenCaptureKit
@testable import Aagedal_Media_Converter

final class CaptureFrameRateTests: XCTestCase {
    func testPersistedOptionsKeepExistingValuesAndExposeExactRates() {
        XCTAssertNil(CaptureFrameRateOption.auto.fixedValue)
        XCTAssertEqual(CaptureFrameRateOption(rawValue: "fps50")?.fixedValue, CaptureFrameRate(50))
        XCTAssertEqual(CaptureFrameRateOption(rawValue: "fps60")?.fixedValue, CaptureFrameRate(60))
        XCTAssertEqual(CaptureFrameRateOption.fps25.fixedValue, CaptureFrameRate(25))
        XCTAssertEqual(CaptureFrameRateOption.fps2997.fixedValue, CaptureFrameRate(30000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRateOption.fps5994.fixedValue, CaptureFrameRate(60000, denominator: 1001))
    }

    func testRationalCadenceDoesNotAccumulateTimestampRounding() {
        for rate in [CaptureFrameRate(30000, denominator: 1001), CaptureFrameRate(60000, denominator: 1001)] {
            let index = 10_000_000
            let start = rate.presentationOffset(frameIndex: index)
            let next = rate.presentationOffset(frameIndex: index + 1)
            XCTAssertEqual(CMTimeCompare(CMTimeSubtract(next, start), rate.frameDuration), 0)
            XCTAssertEqual(start.value, Int64(index) * 1001)
            XCTAssertEqual(start.timescale, rate.numerator)
        }
    }

    func testDropFrameMinuteAndTenMinuteBoundaries() {
        for rate in [CaptureFrameRate(30000, denominator: 1001), CaptureFrameRate(60000, denominator: 1001)] {
            let multiplier = rate.nominalRate / 30
            XCTAssertEqual(rate.timecodeFrame(hour: 0, minute: 1, second: 0), 1800 * multiplier)
            XCTAssertEqual(rate.timecodeFrame(hour: 0, minute: 10, second: 0), 17982 * multiplier)
            XCTAssertEqual(rate.timecodeFrame(hour: 1, minute: 0, second: 0), 107892 * multiplier)
            XCTAssertNotEqual(rate.timecodeFlags & kCMTimeCodeFlag_DropFrame, 0)
        }
    }

    func testMidnightWrapsForDropFrameAndIntegerRates() {
        for rate in CaptureFrameRateOption.allCases.compactMap(\.fixedValue) {
            let last = rate.timecodeFrame(hour: 23, minute: 59, second: 59, nanosecond: 999_999_999)
            XCTAssertEqual(last, rate.framesPerTimecodeDay - 1)
            XCTAssertEqual(rate.wrappedTimecodeFrame(start: last, frameIndex: 1), 0)
            XCTAssertEqual(rate.wrappedTimecodeFrame(start: last, frameIndex: 2), 1)
            XCTAssertNotEqual(rate.timecodeFlags & kCMTimeCodeFlag_24HourMax, 0)
            if rate.denominator == 1 {
                XCTAssertEqual(rate.timecodeFlags & kCMTimeCodeFlag_DropFrame, 0)
            }
        }
    }

    func testGeneratedGrowingRecordingPersistsRationalCadenceAndTimecode() async throws {
        for rate in CaptureFrameRateOption.allCases.compactMap(\.fixedValue) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try ScreenCaptureWriter(
                outputURL: url, fileType: .mov,
                videoSettings: CapturePreset.avcGrowing.videoSettings(width: 64, height: 64, frameRate: rate),
                audioSettings: CapturePreset.avcGrowing.audioSettings,
                dynamicRange: .sdr, includeMicrophone: false, isGrowing: true, frameRate: rate
            )
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            var format: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
            var timing = CMSampleTimingInfo(duration: rate.frameDuration,
                                            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                                   formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            writer.append(sampleBuffer: try XCTUnwrap(sample), type: .screen)
            // A single static screen frame must produce a CFR sequence via the real pump.
            try await Task.sleep(for: .milliseconds(350))
            try await writer.finish()
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let video = try XCTUnwrap(videoTracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var timestamps: [CMTime] = []
            var durations: [CMTime] = []
            while let sample = output.copyNextSampleBuffer() {
                // AssetReader also returns zero-sample boundary/empty-edit markers.
                // Only encoded video samples describe the persisted frame cadence.
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
                XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
                XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sample).isNumeric)
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
                durations.append(CMSampleBufferGetDuration(sample))
            }
            XCTAssertGreaterThan(timestamps.count, 2)
            for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
                XCTAssertEqual(CMTimeCompare(CMTimeSubtract(next, previous), rate.frameDuration), 0, "Rate \(rate), previous \(previous), next \(next), delta \(CMTimeSubtract(next, previous))")
            }
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(durations.last), rate.frameDuration), 0, "Last frame duration at \(rate): \(durations)")
            let videoRange = try await video.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(videoRange.duration, rate.presentationOffset(frameIndex: timestamps.count)), 0, "Video duration at \(rate): \(videoRange), frame count \(timestamps.count)")
            let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
            let timecode = try XCTUnwrap(timecodeTracks.first)
            let descriptions = try await timecode.load(.formatDescriptions)
            let timecodeFormat = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(timecodeFormat), rate.frameDuration), 0)
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(timecodeFormat), UInt32(rate.nominalRate))
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(timecodeFormat), rate.timecodeFlags)
        }
    }

    func testCoreMediaTimecodeDescriptionRetainsExactDurationAndFlags() throws {
        for rate in CaptureFrameRateOption.allCases.compactMap(\.fixedValue) {
            var format: CMTimeCodeFormatDescription?
            let status = CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: rate.frameDuration, frameQuanta: UInt32(rate.nominalRate),
                flags: rate.timecodeFlags, extensions: nil, formatDescriptionOut: &format
            )
            XCTAssertEqual(status, noErr)
            let description = try XCTUnwrap(format)
            XCTAssertEqual(CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(description), rate.frameDuration), 0)
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(description), UInt32(rate.nominalRate))
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(description), rate.timecodeFlags)
        }
    }
}
