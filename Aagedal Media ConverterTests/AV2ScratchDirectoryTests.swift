import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AV2ScratchDirectoryTests: XCTestCase {
    func testAbandonedSegmentPlansDoNotCreateScratchDirectories() async throws {
        let settings: [String: Any] = [
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue
        ]
        let defaults = UserDefaults.standard
        // Override this test process only; a crash must not leave user settings changed.
        let savedArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(savedArguments.merging(settings) { _, testValue in testValue },
                                   forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain) }

        for _ in 0..<2 {
            let built = await AV2CommandBuilder.buildSegments(
                inputURL: URL(fileURLWithPath: "/nonexistent/source.mov"),
                trimStart: nil, trimEnd: nil, cropConfig: nil,
                metadataSource: .resolved(videoMetadata(timecode: nil, frameRate: 24))
            )
            let plan = try XCTUnwrap(built)
            XCTAssertGreaterThan(plan.segments.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.segmentDirectory.path))
        }
    }

    func testConflictingScratchFileFailsBeforeLaunchingAndPreservesFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sentinel = Data("existing user data".utf8)
        try sentinel.write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.errorReason?.contains("Could not create temporary storage for AV2 chunks") == true)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try Data(contentsOf: directory), sentinel)
    }

    func testExistingScratchDirectoryIsNotAdoptedOrRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sentinelURL = directory.appendingPathComponent("keep.txt")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: sentinelURL)
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
    }

    func testMissingScratchParentFailsBeforeLaunching() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("chunks")
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertEqual(runner.launchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testWorkerFailureCleansOwnedScratchDirectory() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runner = ScratchRecordingRunner()
        let result = await execute(directory: directory, runner: runner)
        XCTAssertFalse(result.success)
        XCTAssertGreaterThan(runner.launchCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func execute(directory: URL, runner: ScratchRecordingRunner) async -> FFMPEGConverter.AV2EncodeResult {
        let plan = AV2CommandBuilder.AV2SegmentPlan(
            segments: [.init(index: 0, ffmpegArguments: [], avmencArguments: [],
                             outputURL: directory.appendingPathComponent("segment.ivf"), frameCount: 24)],
            segmentDirectory: directory, outputWidth: 32, outputHeight: 32,
            bitDepth: 8, totalFrames: 24, effectiveDuration: 1, frameRate: 24
        )
        return await FFMPEGConverter(subprocessRunner: runner).runAV2ChunkedConversion(
            plan: plan, outputFileURL: directory.appendingPathComponent("output.ivf"),
            ffmpegPath: "/nonexistent/ffmpeg", avmencPath: "/nonexistent/avmenc",
            progressUpdate: { _, _ in }
        )
    }
    private func videoMetadata(
        timecode: String?,
        frameRate: Double,
        duration: Double? = 60
    ) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
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

}

private final class ScratchRecordingRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var launchCount: Int { lock.withLock { count } }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        lock.withLock { count += 1 }
        throw SubprocessRunnerError.failedToStart(command: request.executableURL.path, underlying: "Injected launch failure")
    }
}
