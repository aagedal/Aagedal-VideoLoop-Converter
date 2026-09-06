import AVFoundation
import XCTest
import ScreenCaptureKit
import os
@testable import Aagedal_Media_Converter

final class CaptureFrameRateTests: XCTestCase {
    @MainActor
    func testMicrophonePermissionReturnsActualGrantAndDenial() async throws {
        let request = CaptureMicrophonePermissionRequest()
        let granted = try await request.request { $0(true) }
        XCTAssertTrue(granted)
        let denied = try await request.request { $0(false) }
        XCTAssertFalse(denied)
    }

    @MainActor
    func testMicrophonePermissionTimeoutDoesNotWaitForLateResponse() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Permission deadline returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request(timeout: .milliseconds(50)) { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected timeout")
            } catch NonJoiningTaskDeadlineError.timedOut {
                // Expected even while the system prompt is unanswered.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered, finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    @MainActor
    func testMicrophonePermissionSupersessionRejectsLateGrant() async throws {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "First permission requested")
        let finished = expectation(description: "Superseded request cancelled")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let first = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected supersession cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        let denied = try await request.request { $0(false) }
        XCTAssertFalse(denied)
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await first.value
    }

    @MainActor
    func testMicrophonePermissionParentCancellationReturnsBeforeCallback() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Cancelled request returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected parent cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    @MainActor
    func testMicrophonePermissionExplicitStopReturnsBeforeCallback() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Cancelled request returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected stop cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        request.cancel()
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    func testScreenCaptureDiscoveryReturnsSnapshot() async throws {
        let snapshot = try await ScreenCaptureContentDiscovery.discover {
            ["display", "window"]
        }
        XCTAssertEqual(snapshot, ["display", "window"])
    }

    func testScreenCaptureDiscoveryTimesOutWithoutJoiningLateCallback() async {
        let registered = expectation(description: "Discovery started")
        let completed = expectation(description: "Discovery returned on deadline")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<String, Never>?>(initialState: nil)
        let task = Task {
            do {
                _ = try await ScreenCaptureContentDiscovery.discover(timeout: .milliseconds(50)) {
                    await withCheckedContinuation { continuation in
                        callback.withLock { $0 = continuation }
                        registered.fulfill()
                    }
                }
                XCTFail("Expected discovery timeout")
            } catch ScreenCaptureContentDiscoveryError.timedOut {
                // Expected; the framework operation remains suspended.
            } catch {
                XCTFail("Unexpected discovery failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [registered, completed], timeout: 2)
        let lateCallback = callback.withLock { value in
            defer { value = nil }
            return value
        }
        lateCallback?.resume(returning: "late display")
        await task.value
    }

    func testScreenCaptureDiscoveryCancellationDoesNotWaitForFramework() async {
        let registered = expectation(description: "Discovery started")
        let completed = expectation(description: "Discovery returned on cancellation")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<String, Never>?>(initialState: nil)
        let task = Task {
            do {
                _ = try await ScreenCaptureContentDiscovery.discover(timeout: .seconds(30)) {
                    await withCheckedContinuation { continuation in
                        callback.withLock { $0 = continuation }
                        registered.fulfill()
                    }
                }
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Cancellation remains distinct from a capture-service timeout.
            } catch {
                XCTFail("Unexpected discovery failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        let lateCallback = callback.withLock { value in
            defer { value = nil }
            return value
        }
        lateCallback?.resume(returning: "late display")
        await task.value
    }

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
        let rates = CaptureFrameRateOption.allCases.compactMap(\.fixedValue)
        let scenarios = rates.map { ($0, Duration.milliseconds(350)) } + rates.map { ($0, Duration.zero) }
        for (rate, captureDuration) in scenarios {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let sourceTime = CMClockGetTime(CMClockGetHostTimeClock())
            let writer = try ScreenCaptureWriter(
                outputURL: url, fileType: .mov,
                videoSettings: CapturePreset.avcGrowing.videoSettings(width: 64, height: 64, frameRate: rate),
                audioSettings: CapturePreset.avcGrowing.audioSettings,
                dynamicRange: .sdr, includeMicrophone: false, isGrowing: true, frameRate: rate,
                currentTime: {
                    captureDuration == .zero ? sourceTime : CMClockGetTime(CMClockGetHostTimeClock())
                }
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
                                            presentationTimeStamp: sourceTime, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                                   formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            writer.append(sampleBuffer: try XCTUnwrap(sample), type: .screen)
            // A single static screen frame must produce a CFR sequence via the real pump.
            // Immediate stop must flush the captured frame even before the first
            // timer tick; longer recordings exercise duplicate-frame pumping.
            if captureDuration > .zero { try await Task.sleep(for: captureDuration) }
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
            if captureDuration > .zero {
                XCTAssertGreaterThan(timestamps.count, 2)
            } else {
                XCTAssertEqual(timestamps.count, 1, "A frozen stop clock must produce exactly one frame at \(rate)")
            }
            for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
                XCTAssertEqual(CMTimeCompare(CMTimeSubtract(next, previous), rate.frameDuration), 0, "Rate \(rate), previous \(previous), next \(next), delta \(CMTimeSubtract(next, previous))")
            }
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(durations.last), rate.frameDuration), 0, "Last frame duration at \(rate): \(durations)")
            let videoRange = try await video.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(videoRange.duration, rate.presentationOffset(frameIndex: timestamps.count)), 0, "Video duration at \(rate): \(videoRange), frame count \(timestamps.count)")
            let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
            let timecode = try XCTUnwrap(timecodeTracks.first)
            let timecodeReader = try AVAssetReader(asset: asset)
            let timecodeOutput = AVAssetReaderTrackOutput(track: timecode, outputSettings: nil)
            timecodeReader.add(timecodeOutput)
            XCTAssertTrue(timecodeReader.startReading())
            var timecodeTimestamps: [CMTime] = []
            while let sample = timecodeOutput.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                timecodeTimestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
            XCTAssertEqual(timecodeTimestamps.count, timestamps.count)
            for (videoPTS, timecodePTS) in zip(timestamps, timecodeTimestamps) {
                XCTAssertEqual(CMTimeCompare(videoPTS, timecodePTS), 0)
            }
            let descriptions = try await timecode.load(.formatDescriptions)
            let timecodeFormat = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(timecodeFormat), rate.frameDuration), 0)
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(timecodeFormat), UInt32(rate.nominalRate))
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(timecodeFormat), rate.timecodeFlags)
        }
    }

    func testContinuouslyReadyBacklogYieldsBetweenBoundedPasses() throws {
        var emitted = 0
        let drained = try CaptureFrameEmission.drain(
            remainingFrameCount: 1_000_000, checkDeadline: {},
            emit: { emitted += 1; return true }
        )
        XCTAssertFalse(drained)
        XCTAssertEqual(emitted, 32)
    }

    func testDeadlineInterruptsAReadyBacklogInsideTheEmissionPass() {
        enum Failure: Error { case deadline }
        var emitted = 0
        XCTAssertThrowsError(try CaptureFrameEmission.drain(
            remainingFrameCount: 1_000_000,
            checkDeadline: { if emitted == 3 { throw Failure.deadline } },
            emit: { emitted += 1; return true }
        )) { XCTAssertEqual($0 as? Failure, .deadline) }
        XCTAssertEqual(emitted, 3)
    }

    func testTimecodeBackpressureDefersBothTracksUntilRetry() throws {
        var videoFrames = 0
        var timecodeFrames = 0
        for ready in [false, false, true] {
            let emitted = try CaptureFrameEmission.append(
                videoReady: true, timecodeReady: ready,
                appendVideo: { videoFrames += 1 },
                appendTimecode: { timecodeFrames += 1 }
            )
            XCTAssertEqual(emitted, ready)
            XCTAssertEqual(videoFrames, ready ? 1 : 0)
            XCTAssertEqual(timecodeFrames, videoFrames)
        }
    }

    func testVideoBackpressureDoesNotAdvanceTimecode() throws {
        let emitted = try CaptureFrameEmission.append(
            videoReady: false, timecodeReady: true,
            appendVideo: { XCTFail("Blocked video must not be appended") },
            appendTimecode: { XCTFail("Timecode must wait for video") }
        )
        XCTAssertFalse(emitted)
    }

    func testTrackAppendErrorsPropagateInsteadOfReportingACompletedFrame() {
        enum Failure: Error { case video, timecode }
        XCTAssertThrowsError(try CaptureFrameEmission.append(
            videoReady: true, timecodeReady: true,
            appendVideo: { throw Failure.video },
            appendTimecode: { XCTFail("Timecode must not advance after failed video") }
        )) { XCTAssertEqual($0 as? Failure, .video) }
        var videoAppended = false
        XCTAssertThrowsError(try CaptureFrameEmission.append(
            videoReady: true, timecodeReady: true,
            appendVideo: { videoAppended = true },
            appendTimecode: { throw Failure.timecode }
        )) { XCTAssertEqual($0 as? Failure, .timecode) }
        XCTAssertTrue(videoAppended)
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
