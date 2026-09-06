import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ConversionDependencyPreflightTests: XCTestCase {
    func testEachSpecialExportRequiresOnlyItsPictureHelper() {
        let cases: [(ExportPreset, ConversionDependencyPreflight.Helper)] = [
            (.dcp, .asdcpWrap), (.imfJ2K, .raw2bmx),
            (.imfProRes, .bmxtranswrap), (.av2, .avmenc)
        ]
        for (preset, helper) in cases {
            let available = ConversionDependencyPreflight { $0 == helper ? "/bin/sh" : nil }
            XCTAssertNil(available.failure(for: preset))
            let missing = ConversionDependencyPreflight { $0 == helper ? nil : "/bin/sh" }
            XCTAssertTrue(missing.failure(for: preset)?.contains(helper.rawValue) == true)
        }
    }

    func testIMFAudioRequiresWrapperOnlyWhenAudioIsKnownPresent() {
        let preflight = ConversionDependencyPreflight { $0 == .asdcpWrap ? nil : "/bin/sh" }
        for preset in [ExportPreset.imfJ2K, .imfProRes] {
            XCTAssertNil(preflight.failure(for: preset, sourceAudioKnownPresent: false))
            XCTAssertTrue(preflight.failure(for: preset, sourceAudioKnownPresent: true)?.contains("asdcp-wrap") == true)
        }
        XCTAssertNil(preflight.failure(for: .h264, sourceAudioKnownPresent: true))
    }

    func testAV2SourceRequiresDecoderBeforeCreatingOutputDirectories() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.ivf")
        // Valid 32-byte AV2 IVF header: 16×16, 24 fps, one frame. No decoder is launched.
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.replaceSubrange(0..<4, with: Array("DKIF".utf8))
        bytes[6] = 32
        bytes.replaceSubrange(8..<12, with: Array("AV02".utf8))
        bytes[12] = 16; bytes[14] = 16; bytes[16] = 24; bytes[20] = 1; bytes[24] = 1
        try Data(bytes).write(to: source)
        let outputDirectory = directory.appendingPathComponent("output")
        let converter = FFMPEGConverter(ffmpegPathProvider: { "/bin/sh" }, avmdecPathProvider: { nil })
        let completed = expectation(description: "Missing AV2 decoder")
        completed.assertForOverFulfill = true
        await converter.convert(
            request: ConversionRequest(inputURL: source, outputURL: outputDirectory.appendingPathComponent("converted"), preset: .h264),
            progressUpdate: { _, _ in XCTFail("No conversion should start") },
            completion: { success, reason in
                XCTAssertFalse(success)
                XCTAssertTrue(reason?.contains("avmdec") == true)
                completed.fulfill()
            }
        )
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testOrdinaryExportDoesNotRequireOptionalHelpers() {
        let preflight = ConversionDependencyPreflight { _ in
            XCTFail("Ordinary exports must not resolve optional helpers")
            return nil
        }
        XCTAssertNil(preflight.failure(for: .h264))
        XCTAssertNil(preflight.failure(for: .prores))
    }

    func testRejectsMissingNonExecutableAndDirectoryPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("helper")
        try Data("not executable".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for path in [directory.path, file.path, directory.appendingPathComponent("absent").path] {
            XCTAssertNotNil(ConversionDependencyPreflight { _ in path }.failure(for: .dcp))
        }
    }

    func testConverterRejectsMissingHelpersBeforeCreatingOutputDirectories() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for preset in [ExportPreset.dcp, .imfJ2K, .imfProRes, .av2] {
            let converter = FFMPEGConverter(
                ffmpegPathProvider: { "/bin/sh" },
                dependencyPreflight: ConversionDependencyPreflight { _ in nil }
            )
            let completed = expectation(description: "Missing dependency reported for \(preset)")
            completed.assertForOverFulfill = true
            await converter.convert(
                request: ConversionRequest(
                    inputURL: directory.appendingPathComponent("missing.mov"),
                    outputURL: directory.appendingPathComponent("output"), preset: preset
                ),
                progressUpdate: { _, _ in XCTFail("No conversion should start") },
                completion: { success, reason in
                    XCTAssertFalse(success)
                    XCTAssertTrue(reason?.contains("Export requires the bundled") == true)
                    completed.fulfill()
                }
            )
            await fulfillment(of: [completed], timeout: 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
}
