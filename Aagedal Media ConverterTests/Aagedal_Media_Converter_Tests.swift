//
//  Aagedal_VideoLoop_Converter_2_0Tests.swift
//  Aagedal VideoLoop Converter 2.0Tests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import Darwin
import XCTest
@testable import Aagedal_Media_Converter

final class Aagedal_Media_Converter_Tests: XCTestCase {

    func testSubprocessRunnerCapturesOutputAndStructuredExit() async throws {
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'hello'; printf 'warning' >&2"]
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.standardOutputText, "hello")
        XCTAssertEqual(result.standardErrorText, "warning")
        XCTAssertEqual(result.discardedStandardOutputBytes, 0)
        XCTAssertEqual(result.discardedStandardErrorBytes, 0)
    }

    func testSubprocessRunnerReturnsNonzeroExitAsResult() async throws {
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'diagnostic' >&2; exit 23"]
            )
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.terminationStatus, 23)
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.standardErrorText, "diagnostic")
    }

    func testSubprocessRunnerWritesStandardInput() async throws {
        let input = Data("secret supplied over stdin\n".utf8)
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                standardInput: input
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, input)
    }

    func testSubprocessRunnerDeliversEveryCapturedByteToIncrementalHandler() async throws {
        let recorder = SubprocessChunkRecorder()
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do printf '%04d\\n' $i; i=$((i + 1)); done"]
            )
        ) { chunk in
            recorder.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(recorder.standardOutput, result.standardOutput)
        XCTAssertEqual(recorder.standardError, result.standardError)
    }

    func testSubprocessRunnerDrainsBothStreamsAndBoundsCapturedTails() async throws {
        let script = """
        i=0
        while [ "$i" -lt 3000 ]; do
          printf 'out-%04d-abcdefghijklmnop\n' "$i"
          printf 'err-%04d-abcdefghijklmnop\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                standardOutputCaptureLimit: 4096,
                standardErrorCaptureLimit: 4096
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.discardedStandardOutputBytes, 0)
        XCTAssertGreaterThan(result.discardedStandardErrorBytes, 0)
        XCTAssertLessThanOrEqual(result.standardOutput.count, 4096)
        XCTAssertLessThanOrEqual(result.standardError.count, 4096)
        XCTAssertTrue(result.standardOutputText.contains("out-2999"))
        XCTAssertTrue(result.standardErrorText.contains("err-2999"))
    }

    func testSubprocessRunnerDoesNotWaitForPipeInheritedByExitedChildDescendant() async throws {
        let start = ContinuousClock.now
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5 & child=$!; printf '%s\\n' \"$child\"; exit 0"]
            )
        )
        let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childText))
        defer { _ = Darwin.kill(childPID, SIGKILL) }

        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testSubprocessRunnerTimeoutTerminatesDescendant() async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(100)
        )
        let start = ContinuousClock.now

        do {
            _ = try await SubprocessRunner().run(request)
            XCTFail("Expected the subprocess to time out")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(_, result) = error else {
                return XCTFail("Expected a timeout error, got \(error)")
            }
            let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try XCTUnwrap(pid_t(childText))
            let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while Darwin.kill(childPID, 0) == 0, ContinuousClock.now < reapDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The descendant process was still running")
            XCTAssertEqual(errno, ESRCH)
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSubprocessRunnerEscalatesForTermIgnoringDescendantAfterWrapperExits() async throws {
        let script = """
        (trap '' TERM
         while :; do sleep 1; done) &
        child=$!
        printf '%s\n' "$child"
        wait "$child"
        """
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(100)
        )

        do {
            _ = try await SubprocessRunner().run(request)
            XCTFail("Expected the subprocess to time out")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(_, result) = error else {
                return XCTFail("Expected a timeout error, got \(error)")
            }
            let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try XCTUnwrap(pid_t(childText))
            let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while Darwin.kill(childPID, 0) == 0, ContinuousClock.now < reapDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The TERM-ignoring descendant survived escalation")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testSubprocessRunnerCancellationStopsPromptly() async throws {
        let ready = expectation(description: "Subprocess became ready")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & child=$!; printf 'ready\\n'; wait \"$child\""],
            terminationGracePeriod: .milliseconds(100)
        )
        let task = Task {
            try await SubprocessRunner().run(request) { chunk in
                if chunk.stream == .standardOutput,
                   String(decoding: chunk.data, as: UTF8.self).contains("ready") {
                    ready.fulfill()
                }
            }
        }
        await fulfillment(of: [ready], timeout: 2)

        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }

    func testSubprocessRequestRedactsURLsAndSensitiveArguments() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            arguments: [
                "--cookies-from-browser", "Safari:Personal",
                "--token=top-secret",
                "https://example.com/watch?v=private"
            ],
            sensitiveArgumentNames: ["--cookies-from-browser", "--token"]
        )

        let description = request.redactedCommandDescription
        XCTAssertFalse(description.contains("Safari:Personal"))
        XCTAssertFalse(description.contains("top-secret"))
        XCTAssertFalse(description.contains("example.com"))
        XCTAssertTrue(description.contains("--cookies-from-browser"))
        XCTAssertTrue(description.contains("--token=<redacted>"))
        XCTAssertTrue(description.contains("<url>"))
    }

    func testSubprocessRequestRedactsSensitiveValuesAndURLsFromDiagnostics() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            arguments: [
                "--cookies-from-browser", "Safari:Personal",
                "https://user:password@example.com/watch?signed=private"
            ],
            sensitiveArgumentNames: ["--cookies-from-browser"],
            sensitiveValues: ["environment-secret"]
        )

        let diagnostic = request.redactedDiagnostic(
            "Failed Safari:Personal environment-secret while reading https://user:password@example.com/watch?signed=private"
        )
        XCTAssertEqual(diagnostic, "Failed <redacted> <redacted> while reading <url>")
    }

    func testSubprocessRequestRedactsOverlappingSensitiveValuesLongestFirst() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            sensitiveValues: ["ABC", "ABCDEF"]
        )

        let diagnostic = request.redactedDiagnostic("keys ABCDEF and ABC")

        XCTAssertEqual(diagnostic, "keys <redacted> and <redacted>")
        XCTAssertFalse(diagnostic.contains("DEF"))
    }

    func testRcloneEnvironmentDropsInheritedRemoteConfiguration() {
        let environment = RcloneService.sanitizedEnvironment(
            base: [
                "PATH": "/usr/bin",
                "RCLONE_CONFIG": "/private/config",
                "RCLONE_CONFIG_UPLOAD_PASS": "inherited-secret",
                "RCLONE_CONFIG_OTHER_TYPE": "s3"
            ],
            overrides: [
                "RCLONE_CONFIG_UPLOAD_TYPE": "sftp",
                "RCLONE_CONFIG_UPLOAD_HOST": "media.example"
            ]
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["RCLONE_CONFIG"], "/dev/null")
        XCTAssertEqual(environment["RCLONE_CONFIG_UPLOAD_TYPE"], "sftp")
        XCTAssertEqual(environment["RCLONE_CONFIG_UPLOAD_HOST"], "media.example")
        XCTAssertNil(environment["RCLONE_CONFIG_UPLOAD_PASS"])
        XCTAssertNil(environment["RCLONE_CONFIG_OTHER_TYPE"])
    }

    func testRcloneUploadUsesRunnerAndParsesSplitAndFinalProgressLines() async throws {
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("Transferred: 1 MiB / 2 MiB, 50%, 4 MiB/s, ".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("ETA 1s\n".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardOutput,
                    data: Data("Transferred: 2 MiB / 2 MiB, 100%, 5 MiB/s, ETA 0s".utf8)
                )
            )
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(3)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let callbacks = RcloneCallbackRecorder()
        let localURL = URL(fileURLWithPath: "/private/tmp/Secret Clip.mov")
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        let result = try await service.upload(
            localFile: localURL,
            config: config,
            progress: { value, speed in callbacks.record(value: value, speed: speed) }
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.remotePath, "/deliveries/Secret Clip.mov")
        XCTAssertEqual(result.bytesTransferred, 2 * 1024 * 1024)
        XCTAssertEqual(result.duration, 3, accuracy: 0.001)
        XCTAssertTrue(callbacks.values.contains(0.5))
        XCTAssertEqual(callbacks.values.last, 1.0)

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/rclone-fixture")
        XCTAssertEqual(request.timeout, .seconds(6 * 60 * 60))
        XCTAssertTrue(request.arguments.containsAdjacent("copy", localURL.path))
        XCTAssertEqual(request.environment?["RCLONE_CONFIG_UPLOAD_TYPE"], "sftp")
        XCTAssertEqual(request.environment?["RCLONE_CONFIG_UPLOAD_KEY_FILE"], "/private/keys/upload-key")
        XCTAssertEqual(request.environment?["RCLONE_CONFIG"], "/dev/null")
        XCTAssertFalse(request.redactedCommandDescription.contains(localURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains("upload:/deliveries"))
        XCTAssertFalse(request.redactedDiagnostic("leaked /private/keys/upload-key").contains("upload-key"))
    }

    func testRcloneUploadRedactsConnectionFailureDetails() async throws {
        let localURL = URL(fileURLWithPath: "/private/tmp/Secret.mov")
        let diagnostic = "Failed: connection refused at sftp://user:password@example.com/private for \(localURL.path)\n"
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(stream: .standardError, data: Data(diagnostic.utf8))
            )
            return SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        do {
            _ = try await service.upload(localFile: localURL, config: config, progress: { _, _ in })
            XCTFail("Expected connection failure")
        } catch let error as UploadError {
            guard case let .connectionFailed(message) = error else {
                return XCTFail("Expected connectionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("<url>"))
            XCTAssertTrue(message.contains("<redacted>"))
            XCTAssertFalse(message.contains("example.com"))
            XCTAssertFalse(message.contains("password"))
            XCTAssertFalse(message.contains(localURL.path))
        }
    }

    func testRcloneObscureUsesRunnerStdinAndRedactsPassword() async throws {
        let password = "correct horse battery staple"
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("obscured-value\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )

        let obscured = try await service.obscurePassword(password, rclonePath: "/usr/bin/rclone-fixture")

        XCTAssertEqual(obscured, "obscured-value")
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments, ["obscure", "-"])
        XCTAssertEqual(request.standardInput, Data((password + "\n").utf8))
        XCTAssertEqual(request.timeout, .seconds(5))
        XCTAssertFalse(request.redactedDiagnostic("echoed \(password)").contains(password))
        XCTAssertFalse(request.redactedCommandDescription.contains(password))
    }

    func testRcloneObscureMapsRunnerTimeout() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGTERM,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(5)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )

        do {
            _ = try await service.obscurePassword("secret", rclonePath: "/usr/bin/rclone-fixture")
            XCTFail("Expected timeout")
        } catch let error as UploadError {
            guard case let .uploadFailed(message) = error else {
                return XCTFail("Expected uploadFailed, got \(error)")
            }
            XCTAssertEqual(message, "Failed to obscure password: timed out")
        }
    }

    func testRcloneConnectionTestUsesRunnerDeadlineAndMapsAuthentication() async throws {
        let diagnostic = "530 Login incorrect\n"
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        do {
            _ = try await service.testConnection(config: config)
            XCTFail("Expected authentication failure")
        } catch let error as UploadError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments.first, "lsd")
        XCTAssertEqual(request.timeout, .seconds(60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
    }

    func testConcurrentRcloneUploadsCancelOnlyTheirOwnRunnerInvocation() async throws {
        let runner = SelectiveRcloneRunner()
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )
        let cancelledURL = URL(fileURLWithPath: "/private/tmp/cancel.mov")
        let completedURL = URL(fileURLWithPath: "/private/tmp/complete.mov")
        let cancelledTask = Task {
            try await service.upload(localFile: cancelledURL, config: config, progress: { _, _ in })
        }
        let completedTask = Task {
            try await service.upload(localFile: completedURL, config: config, progress: { _, _ in })
        }

        await runner.waitUntilStarted(count: 2)
        cancelledTask.cancel()

        let completedResult = try await completedTask.value
        XCTAssertTrue(completedResult.success)
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected the selected upload to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(runner.cancelledPaths, [cancelledURL.path])
    }

    func testYTDLPDownloadUsesRunnerAndParsesSplitProgressAndOutputLines() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTDLPServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("Great Clip.mp4")
        let runner = RecordingSubprocessRunner { request, outputHandler in
            try Data("fixture".utf8).write(to: outputURL)
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("[download] Destination: Great ".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("Clip.mp4\n[download]  42.5% of 10MiB at 2MiB/s\n".utf8)
                )
            )
            let pathData = Data((outputURL.path + "\n").utf8)
            let splitIndex = pathData.index(pathData.startIndex, offsetBy: pathData.count / 2)
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: pathData[..<splitIndex])
            )
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: pathData[splitIndex...])
            )
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let callbacks = YTDLPCallbackRecorder()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )

        let result = try await service.download(
            url: "https://example.com/watch?v=private",
            outputFolder: temporaryDirectory,
            progress: { value, _, _ in callbacks.recordProgress(value) },
            titleUpdate: { callbacks.recordTitle($0) }
        )

        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertEqual(result.title, "Great Clip")
        XCTAssertEqual(callbacks.titles, ["Great Clip"])
        XCTAssertEqual(callbacks.progressValues.first ?? 0, 0.425, accuracy: 0.0001)
        XCTAssertEqual(callbacks.progressValues.last, 1.0)

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.currentDirectoryURL, temporaryDirectory)
        XCTAssertTrue(request.arguments.containsAdjacent("--", "https://example.com/watch?v=private"))
        XCTAssertFalse(request.redactedCommandDescription.contains("example.com"))
    }

    func testYTDLPDownloadControlMapsUserCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let control = YTDLPDownloadControl()
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/watch?v=private",
                outputFolder: FileManager.default.temporaryDirectory,
                control: control,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        XCTAssertTrue(control.cancel())

        do {
            _ = try await downloadTask.value
            XCTFail("Expected user cancellation")
        } catch let error as YTDLPError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
    }

    func testYTDLPDownloadRedactsURLFromFailureDiagnostic() async throws {
        let diagnostic = "ERROR: failed while requesting https://example.com/watch?signed=private\n"
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(stream: .standardError, data: Data(diagnostic.utf8))
            )
            return SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )

        do {
            _ = try await service.download(
                url: "https://example.com/watch?signed=private",
                outputFolder: FileManager.default.temporaryDirectory,
                progress: { _, _, _ in }
            )
            XCTFail("Expected a download failure")
        } catch let error as YTDLPError {
            guard case let .downloadFailed(message) = error else {
                return XCTFail("Expected downloadFailed, got \(error)")
            }
            XCTAssertEqual(message, "failed while requesting <url>")
            XCTAssertFalse(message.contains("example.com"))
        }
    }

    func testYTDLPDownloadMapsParentTaskCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/watch?v=private",
                outputFolder: FileManager.default.temporaryDirectory,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        downloadTask.cancel()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected parent-task cancellation")
        } catch let error as YTDLPError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
    }

    func testYTDLPDownloadControlPreservesLiveStopReason() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let control = YTDLPDownloadControl()
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/live",
                outputFolder: FileManager.default.temporaryDirectory,
                liveFromStart: true,
                control: control,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        XCTAssertTrue(control.stopLiveRecording())

        do {
            _ = try await downloadTask.value
            XCTFail("Expected live recording stop")
        } catch let error as YTDLPError {
            guard case .liveRecordingStopped = error else {
                return XCTFail("Expected liveRecordingStopped, got \(error)")
            }
        }
    }

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

    func testGeneratedVideoAudioFixtureRunsCoreConverterAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCoreConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le",
            fixtureURL.path
        ])

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }
        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")

        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan((try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)

        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: outputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
        XCTAssertEqual(streams.audioStreamCount, 1)

        let info = try await VideoMetadataService.shared.fetchEssentialInfo(for: outputURL)
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 48)
        XCTAssertEqual(info.duration, 1, accuracy: 0.15)
    }

    func testGeneratedMultichannelFixtureDownmixesThroughCoreConverter() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMultichannelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("surround-source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i",
            "aevalsrc=0.1*sin(2*PI*300*t)|0.1*sin(2*PI*400*t)|0.1*sin(2*PI*500*t)|0.1*sin(2*PI*600*t)|0.1*sin(2*PI*700*t)|0.1*sin(2*PI*800*t):s=48000:d=1:c=5.1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le",
            fixtureURL.path
        ])

        let probedFixtureStreams = await FFMPEGProbeService.fetchAudioStreams(for: fixtureURL)
        let fixtureStreams = try XCTUnwrap(probedFixtureStreams)
        XCTAssertEqual(fixtureStreams.count, 1)
        XCTAssertEqual(fixtureStreams.first?.channels, 6)
        XCTAssertEqual(fixtureStreams.first?.channelLayout, "5.1")

        let surroundTrack = AudioTrackInfo(
            streamIndex: 0,
            channels: 6,
            channelLayout: "5.1",
            codec: "pcm_s16le",
            codecLongName: nil,
            sampleRate: 48_000
        )
        var routing = AudioRoutingConfig(inputTracks: [surroundTrack])
        routing.outputTracks = [OutputTrack(streamIndex: 0, downmixToStereo: true)]

        let outputBaseURL = temporaryDirectory.appendingPathComponent("downmixed")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1,
                audioRoutingConfig: routing
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        let probedStreams = await FFMPEGProbeService.fetchAudioStreams(for: outputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?.channels, 2)
        XCTAssertEqual(streams.first?.channelLayout?.lowercased(), "stereo")
    }

    func testGeneratedSubtitleFixtureIsPreservedThroughCoreConverter() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSubtitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let subtitleURL = temporaryDirectory.appendingPathComponent("fixture.srt")
        try Data("1\n00:00:00,100 --> 00:00:00,800\nFixture subtitle\n".utf8).write(to: subtitleURL)

        let fixtureURL = temporaryDirectory.appendingPathComponent("subtitle-source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1",
            "-f", "srt", "-i", subtitleURL.path,
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-c:s", "srt",
            "-metadata:s:s:0", "language=nor",
            fixtureURL.path
        ])

        let outputBaseURL = temporaryDirectory.appendingPathComponent("subtitled")
        let result = try await withPresetSettingsAsync([
            AppConstants.keepSubtitlesKey: true
        ]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        let inspection = try inspectMedia(at: outputURL)
        XCTAssertTrue(inspection.contains("Subtitle: mov_text"), inspection)

        let extractedSubtitleURL = temporaryDirectory.appendingPathComponent("extracted.srt")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-map", "0:s:0", "-c:s", "srt", extractedSubtitleURL.path
        ])
        let extractedSubtitle = try String(contentsOf: extractedSubtitleURL, encoding: .utf8)
        XCTAssertTrue(extractedSubtitle.contains("Fixture subtitle"), extractedSubtitle)
    }

    func testCoreConverterPreservesExistingOutputAndChoosesUniqueName() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterExistingOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideoFixture(at: fixtureURL)

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let existingOutputURL = outputBaseURL.appendingPathExtension("mp4")
        let sentinel = Data("existing output must remain unchanged".utf8)
        try sentinel.write(to: existingOutputURL)

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        XCTAssertEqual(try Data(contentsOf: existingOutputURL), sentinel)

        let uniqueOutputURL = temporaryDirectory.appendingPathComponent("converted_1.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uniqueOutputURL.path))
        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: uniqueOutputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
    }

    func testCoreConverterNeverOverwritesSourceWhenOutputResolvesToSamePath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSourceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mp4")
        try makeVideoFixture(at: fixtureURL)
        let originalSource = try Data(contentsOf: fixtureURL)

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: fixtureURL.deletingPathExtension(),
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        XCTAssertEqual(try Data(contentsOf: fixtureURL), originalSource)

        let safeOutputURL = temporaryDirectory.appendingPathComponent("source_encoded.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeOutputURL.path))
        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: safeOutputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
    }

    func testCoreConverterReportsMalformedInputFailureWithoutOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMalformedInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("malformed.mov")
        try Data("this is not media".utf8).write(to: fixtureURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertFalse((result.errorReason ?? "").isEmpty)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterReportsMissingSelectedFFmpegBeforeCreatingOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMissingBinaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([
            AppConstants.ffmpegBinarySourceKey: BinarySourceSelection.custom.rawValue,
            AppConstants.customFFmpegPathKey: temporaryDirectory.appendingPathComponent("missing-ffmpeg").path
        ]) {
            await runConversion(ConversionRequest(
                inputURL: temporaryDirectory.appendingPathComponent("source.mov"),
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "FFmpeg binary not found")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterUnsupportedAV2GeneratedVideoRevokesOutputRegistration() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2RejectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .av2,
                includeDateTag: false,
                synthesizedVideoRequest: SynthesizedVideoRequest(
                    width: 64,
                    height: 48,
                    backgroundHex: "000000",
                    frameRate: 24,
                    includeAudio: true
                )
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "AV2 export does not yet support generated video from audio-only sources")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.av2.outputExtension(for: inputURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterCancellationStopsRunningFFmpeg() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputBaseURL = temporaryDirectory.appendingPathComponent("cancelled")
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("virtual-source.mkv"),
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false,
            expectedDuration: 30,
            customInputArguments: [
                "-re", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=30:duration=30"
            ]
        )

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(request, cancellingAfter: 300_000_000)
        }

        XCTAssertFalse(result.success)
        XCTAssertFalse((result.errorReason ?? "").isEmpty)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
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

    func testAV2BuildUsesConcatInputAndKnownVirtualSourceDuration() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ConcatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=32x32:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            fixtureURL.path
        ])
        let listURL = temporaryDirectory.appendingPathComponent("inputs.ffconcat")
        try "file '\(fixtureURL.path)'\nfile '\(fixtureURL.path)'\n".write(
            to: listURL,
            atomically: true,
            encoding: .utf8
        )
        let customInputs = ["-f", "concat", "-safe", "0", "-i", listURL.path]

        try await withPresetSettingsAsync([AppConstants.av2ParallelChunksKey: 2]) {
            let outputURL = temporaryDirectory.appendingPathComponent("output.ivf")
            let builtCommand = await AV2CommandBuilder.build(
                inputURL: fixtureURL,
                outputURL: outputURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                customInputArguments: customInputs,
                expectedDuration: 2,
                videoFrameRate: 24
            )
            let command = try XCTUnwrap(builtCommand)

            XCTAssertEqual(command.effectiveDuration ?? -1, 2, accuracy: 0.001)
            XCTAssertEqual(command.frameRate ?? -1, 24, accuracy: 0.001)
            XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-i", listURL.path))
            XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-f", "concat"))
            XCTAssertFalse(command.ffmpegArguments.containsAdjacent("-i", fixtureURL.path))

            let chunkPlan = await AV2CommandBuilder.buildSegments(
                inputURL: fixtureURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                customInputArguments: customInputs,
                expectedDuration: 2,
                videoFrameRate: 24
            )
            XCTAssertNil(chunkPlan, "Virtual inputs must use the validated single-process path")
        }
    }

    func testAV2BuildUsesImageSequenceInputAndConcreteVisualSource() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ImageSequenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstFrameURL = temporaryDirectory.appendingPathComponent("frame_0001.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:size=40x24",
            "-frames:v", "1",
            firstFrameURL.path
        ])
        let patternURL = temporaryDirectory.appendingPathComponent("frame_%04d.png")
        let customInputs = [
            "-framerate", "12.000",
            "-start_number", "1",
            "-i", patternURL.path
        ]
        let outputURL = temporaryDirectory.appendingPathComponent("output.ivf")

        let builtCommand = await AV2CommandBuilder.build(
            inputURL: temporaryDirectory,
            outputURL: outputURL,
            trimStart: nil,
            trimEnd: nil,
            cropConfig: nil,
            visualSourceURL: firstFrameURL,
            customInputArguments: customInputs,
            expectedDuration: 1
        )
        let command = try XCTUnwrap(builtCommand)

        XCTAssertEqual(command.outputWidth, 40)
        XCTAssertEqual(command.outputHeight, 24)
        XCTAssertEqual(command.effectiveDuration ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(command.frameRate ?? -1, 12, accuracy: 0.001)
        XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-i", patternURL.path))
        XCTAssertFalse(command.ffmpegArguments.containsAdjacent("-i", temporaryDirectory.path))
        XCTAssertTrue(command.avmencArguments.contains("--fps=12000/1000"))
    }

    func testAV2MatroskaAudioUsesVirtualSourceAndHonorsMute() {
        let primaryURL = URL(fileURLWithPath: "/tmp/primary.mov")
        let concatURL = URL(fileURLWithPath: "/tmp/inputs.ffconcat")
        let concatArguments = ["-f", "concat", "-safe", "0", "-i", concatURL.path]

        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: primaryURL,
                customInputArguments: concatArguments,
                isMuted: false
            ),
            FFMPEGConverter.PackageAudioInput(
                arguments: concatArguments,
                probeURL: primaryURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: false
            )
        )

        let companionAudioURL = URL(fileURLWithPath: "/tmp/sequence.wav")
        let imageSequenceArguments = [
            "-framerate", "24",
            "-i", "/tmp/frame_%04d.png",
            "-i", companionAudioURL.path
        ]
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: URL(fileURLWithPath: "/tmp/sequence"),
                customInputArguments: imageSequenceArguments,
                isMuted: false
            ),
            FFMPEGConverter.PackageAudioInput(
                arguments: ["-i", companionAudioURL.path],
                probeURL: companionAudioURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: true
            )
        )

        XCTAssertNil(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: primaryURL,
                customInputArguments: concatArguments,
                isMuted: true
            )
        )
    }

    func testAV2MatroskaCapabilitiesFollowSelectedContainer() throws {
        try withPresetSettings([AppConstants.av2ContainerKey: AV2Container.ivf.rawValue]) {
            XCTAssertFalse(ExportPreset.av2.outputsAudioTrack)
            XCTAssertFalse(ExportPreset.av2.appliesAudioRouting)
        }
        try withPresetSettings([AppConstants.av2ContainerKey: AV2Container.mkv.rawValue]) {
            XCTAssertTrue(ExportPreset.av2.outputsAudioTrack)
            XCTAssertTrue(ExportPreset.av2.appliesAudioRouting)
        }
    }

    func testAV2AudioRoutingArgumentsPreserveOrderDuplicatesAndFilters() {
        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 6)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1, downmixToStereo: true),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 2,
                audioRoutingConfig: config,
                defaultAudioStreamIndices: [99]
            ),
            [
                "-filter_complex",
                "[2:a:1]aresample=ochl=stereo[aout0];[2:a:0]anull[aout1];[2:a:1]anull[aout2]",
                "-map", "[aout0]",
                "-map", "[aout1]",
                "-map", "[aout2]"
            ]
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 1,
                audioRoutingConfig: nil,
                defaultAudioStreamIndices: [0, 2]
            ),
            ["-map", "1:a:0", "-map", "1:a:2"]
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 0,
                audioRoutingConfig: AudioRoutingConfig(inputTracks: tracks, outputTracks: []),
                defaultAudioStreamIndices: [0, 1]
            ),
            []
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 10,
                audioRoutingConfig: config,
                defaultAudioStreamIndices: []
            ),
            [
                "-filter_complex",
                "[10:a:1]aresample=ochl=stereo[aout0];[10:a:0]anull[aout1];[10:a:1]anull[aout2]",
                "-map", "[aout0]",
                "-map", "[aout1]",
                "-map", "[aout2]"
            ]
        )
    }

    func testADTSChannelConfigurationMappingRejectsUnsupportedLayouts() {
        XCTAssertNil(FFMPEGConverter.adtsChannelCount(forConfiguration: 0))
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 1), 1)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 2), 2)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 6), 6)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 7), 8)
        XCTAssertNil(FFMPEGConverter.adtsChannelCount(forConfiguration: 8))
    }

    func testGeneratedAV2AudioRoutingProducesOrderedTracksForAACAndOpus() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2AudioRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=24:d=0.25",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=0.25",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1:d=0.25",
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0",
            "-c:v", "ffv1", "-c:a", "pcm_s16le", sourceURL.path
        ])

        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 6)]
        let routing = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1, downmixToStereo: true),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", sourceURL.path],
            probeURL: sourceURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )

        for codec in [AV2AudioCodec.aac, .opus] {
            let result = try await withPresetSettingsAsync([
                AppConstants.av2AudioCodecKey: codec.rawValue,
                AppConstants.av2AudioBitrateKey: AppConstants.defaultAV2AudioBitrate
            ]) {
                await FFMPEGConverter().extractAudioTracksForAV2Mux(
                    source: source,
                    audioRoutingConfig: routing,
                    trimStart: nil,
                    trimEnd: nil,
                    ffmpegPath: ffmpegExecutableURL.path
                )
            }

            guard case .tracks(let extractedTracks) = result else {
                XCTFail("AV2 \(codec.rawValue) routing did not produce audio tracks")
                continue
            }
            XCTAssertEqual(extractedTracks.count, 3, codec.rawValue)
            XCTAssertEqual(extractedTracks.map(\.info.channels), [2, 2, 6], codec.rawValue)
            XCTAssertEqual(extractedTracks.map(\.info.codecID), Array(repeating: codec.matroskaCodecID, count: 3))
            XCTAssertTrue(extractedTracks.allSatisfy { !$0.frames.isEmpty }, codec.rawValue)
        }

        let defaultResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: nil,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let defaultTracks) = defaultResult else {
            return XCTFail("Default AV2 routing did not preserve every decodable audio track")
        }
        XCTAssertEqual(defaultTracks.map(\.info.channels), [2, 6])

        var splitRouting = AudioRoutingConfig(inputTracks: tracks)
        splitRouting.setChannelOperation(.splitToMono(trackIndex: 0))
        let splitResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: splitRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let splitTracks) = splitResult else {
            return XCTFail("AV2 split-to-mono routing did not survive audio staging")
        }
        XCTAssertEqual(splitTracks.map(\.info.channels), [1, 1])

        var extractRouting = AudioRoutingConfig(inputTracks: tracks)
        extractRouting.setChannelOperation(.extractChannel(trackIndex: 1, channelIndex: 4, channelName: "Ls"))
        let extractResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: extractRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let extractTracks) = extractResult else {
            return XCTFail("AV2 extract-channel routing did not survive audio staging")
        }
        XCTAssertEqual(extractTracks.map(\.info.channels), [1])

        let invalidRouting = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [OutputTrack(streamIndex: 99)]
        )
        let invalidResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: invalidRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .failed(let reason) = invalidResult else {
            return XCTFail("Invalid selected AV2 audio was silently discarded")
        }
        XCTAssertFalse(reason.isEmpty)

        let unreadableURL = temporaryDirectory.appendingPathComponent("unreadable.mkv")
        try Data("not a Matroska file".utf8).write(to: unreadableURL)
        let unreadableSource = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", unreadableURL.path],
            probeURL: unreadableURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )
        let unreadableResult = await FFMPEGConverter().extractAudioTracksForAV2Mux(
            source: unreadableSource,
            audioRoutingConfig: nil,
            trimStart: nil,
            trimEnd: nil,
            ffmpegPath: ffmpegExecutableURL.path
        )
        guard case .failed(let probeReason) = unreadableResult else {
            return XCTFail("Unreadable default AV2 audio was treated as a silent source")
        }
        XCTAssertTrue(probeReason.contains("inspect"))
    }

    func testAV2MatroskaMetadataUsesSharedCommentAndTimecodePolicy() throws {
        try withPresetSettings([
            AppConstants.commentPrefixKey: "Prefix",
            AppConstants.commentSuffixKey: "Suffix",
            AppConstants.commentSeparatorKey: " | ",
            AppConstants.commentDateFormatKey: "yyyy-MM-dd",
            AppConstants.dateTagPrefixKey: "Date"
        ]) {
            let comment = try XCTUnwrap(FFMPEGCommandBuilder.commentMetadataValue(
                comment: "Hei fra AV2 🎬",
                includeDateTag: true,
                date: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(comment, "Date: 1970-01-01 | Prefix | Hei fra AV2 🎬 | Suffix")

            let timecode = try XCTUnwrap(FFMPEGCommandBuilder.resolvedTimecode(
                timecodeConfig: TimecodeConfig(mode: .preserveSource),
                sourceMetadata: videoMetadata(timecode: "01:02:03:12", frameRate: 24),
                trimStart: 2
            ))
            XCTAssertEqual(timecode, "01:02:05:12")

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AagedalMediaConverterMatroskaMetadataTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let outputURL = temporaryDirectory.appendingPathComponent("metadata.mkv")
            try MatroskaMuxer.write(
                to: outputURL,
                video: MatroskaMuxer.VideoTrackInfo(
                    codecPrivate: nil,
                    width: 16,
                    height: 16,
                    fpsNumerator: 24,
                    fpsDenominator: 1
                ),
                videoFrames: [MatroskaMuxer.VideoFrame(data: Data([0x12, 0x34]), isKeyframe: true)],
                audio: nil,
                audioFrames: [],
                metadata: MatroskaMuxer.Metadata(comment: comment, timecode: timecode)
            )

            let data = try Data(contentsOf: outputURL)
            XCTAssertNotNil(data.range(of: Data("COMMENT".utf8)))
            XCTAssertNotNil(data.range(of: Data(comment.utf8)))
            XCTAssertNotNil(data.range(of: Data(timecode.utf8)))
            let firstTimecodeTag = try XCTUnwrap(data.range(of: Data("TIMECODE".utf8)))
            XCTAssertNotNil(data[firstTimecodeTag.upperBound...].range(of: Data("TIMECODE".utf8)))
            XCTAssertNotNil(data.range(of: Data([0x63, 0xC0, 0x80])))
            XCTAssertNotNil(data.range(of: Data([0x63, 0xC5, 0x81, 0x01])))
        }
    }

    func testMatroskaMuxerWritesOrderedMultipleAudioTracksAndBlocks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMatroskaAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("multi-audio.mkv")
        let audioTracks = [
            MatroskaMuxer.AudioTrack(
                info: MatroskaMuxer.AudioTrackInfo(
                    codecID: "A_AAC", codecPrivate: Data([0x12, 0x10]), sampleRate: 48_000, channels: 2
                ),
                frames: [MatroskaMuxer.AudioFrame(data: Data([0xA1]), durationSamples: 1_024)]
            ),
            MatroskaMuxer.AudioTrack(
                info: MatroskaMuxer.AudioTrackInfo(
                    codecID: "A_OPUS", codecPrivate: Data("OpusHead".utf8), sampleRate: 48_000, channels: 1
                ),
                frames: [MatroskaMuxer.AudioFrame(data: Data([0xB2]), durationSamples: 960)]
            )
        ]
        try MatroskaMuxer.write(
            to: outputURL,
            video: MatroskaMuxer.VideoTrackInfo(
                codecPrivate: nil,
                width: 16,
                height: 16,
                fpsNumerator: 24,
                fpsDenominator: 1
            ),
            videoFrames: [MatroskaMuxer.VideoFrame(data: Data([0x12, 0x34]), isKeyframe: true)],
            audioTracks: audioTracks
        )

        let data = try Data(contentsOf: outputURL)
        let aacCodec = try XCTUnwrap(data.range(of: Data("A_AAC".utf8)))
        let opusCodec = try XCTUnwrap(data.range(of: Data("A_OPUS".utf8)))
        XCTAssertLessThan(aacCodec.lowerBound, opusCodec.lowerBound)
        XCTAssertNotNil(data.range(of: Data([0xD7, 0x81, 0x02])))
        XCTAssertNotNil(data.range(of: Data([0xD7, 0x81, 0x03])))
        XCTAssertNotNil(data.range(of: Data([0x88, 0x81, 0x01])))
        XCTAssertNotNil(data.range(of: Data([0x88, 0x81, 0x00])))
        XCTAssertNotNil(data.range(of: Data([0x82, 0x00, 0x00, 0x80, 0xA1])))
        XCTAssertNotNil(data.range(of: Data([0x83, 0x00, 0x00, 0x80, 0xB2])))
    }

    func testAV2RejectsAdditionalFFmpegOutputArgumentsInsteadOfIgnoringThem() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ArgumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.mov")
        try Data([0]).write(to: inputURL)
        let result = await runConversion(ConversionRequest(
            inputURL: inputURL,
            outputURL: temporaryDirectory.appendingPathComponent("output"),
            preset: .av2,
            additionalOutputArguments: ["-metadata", "title=Must not be ignored"]
        ))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "AV2 export does not support additional FFmpeg output arguments")
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
            [
                "-filter_complex",
                "[0:a:2]channelsplit=channel_layout=stereo[splitL][splitR];[splitL]aformat=channel_layouts=mono[L];[splitR]aformat=channel_layouts=mono[R]",
                "-map", "[L]", "-map", "[R]"
            ]
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

    private func withPresetSettingsAsync<Result>(
        _ overrides: [String: Any],
        _ body: () async throws -> Result
    ) async throws -> Result {
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

        return try await body()
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

    private func makeVideoFixture(at url: URL) throws {
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            url.path
        ])
    }

    private func runConversion(
        _ request: ConversionRequest
    ) async -> (success: Bool, errorReason: String?) {
        let converter = FFMPEGConverter()
        return await withCheckedContinuation { continuation in
            Task {
                await converter.convert(
                    request: request,
                    progressUpdate: { _, _ in },
                    completion: { success, errorReason in
                        continuation.resume(returning: (success, errorReason))
                    }
                )
            }
        }
    }

    private func runConversion(
        _ request: ConversionRequest,
        cancellingAfter delayNanoseconds: UInt64
    ) async -> (success: Bool, errorReason: String?) {
        let converter = FFMPEGConverter()
        return await withCheckedContinuation { continuation in
            Task {
                await converter.convert(
                    request: request,
                    progressUpdate: { _, _ in },
                    completion: { success, errorReason in
                        continuation.resume(returning: (success, errorReason))
                    }
                )
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                await converter.cancelConversion()
            }
        }
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

private struct StubYTDLPUpdateService: YTDLPUpdating {
    let path: String?

    func resolveYTDLPPath() async -> String? {
        path
    }

    func ensureDenoInstalled() async -> String? {
        nil
    }
}

private struct StubRcloneUpdateService: RcloneUpdating {
    let path: String?

    func resolveRclonePath() async -> String? {
        path
    }
}

private final class RecordingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    typealias Operation = @Sendable (
        SubprocessRequest,
        (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult

    private let lock = NSLock()
    private let operation: Operation
    private var recordedRequest: SubprocessRequest?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    var lastRequest: SubprocessRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        lock.withLock {
            recordedRequest = request
        }
        return try await operation(request, outputHandler)
    }
}

private final class BlockingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }

        try await Task.sleep(for: .seconds(30))
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .seconds(30)
        )
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private final class SelectiveRcloneRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var recordedCancelledPaths: [String] = []

    var cancelledPaths: [String] {
        lock.withLock { recordedCancelledPaths }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let localPath = request.arguments.count > 1 ? request.arguments[1] : ""
        signalStarted()

        if localPath.contains("cancel") {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                lock.withLock {
                    recordedCancelledPaths.append(localPath)
                }
                throw error
            }
        }

        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .seconds(1)
        )
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if startedCount >= count {
                    return true
                }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func signalStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startedCount += 1
            let ready = startWaiters.filter { startedCount >= $0.count }
            startWaiters.removeAll { startedCount >= $0.count }
            return ready.map(\.continuation)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class RcloneCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []
    private var recordedSpeeds: [String?] = []

    var values: [Double] {
        lock.withLock { recordedValues }
    }

    func record(value: Double, speed: String?) {
        lock.withLock {
            recordedValues.append(value)
            recordedSpeeds.append(speed)
        }
    }
}

private final class YTDLPCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProgressValues: [Double] = []
    private var recordedTitles: [String] = []

    var progressValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProgressValues
    }

    var titles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTitles
    }

    func recordProgress(_ value: Double) {
        lock.lock()
        recordedProgressValues.append(value)
        lock.unlock()
    }

    func recordTitle(_ title: String) {
        lock.lock()
        recordedTitles.append(title)
        lock.unlock()
    }
}

private final class SubprocessChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    var standardOutput: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    var standardError: Data {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func append(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        switch chunk.stream {
        case .standardOutput:
            output.append(chunk.data)
        case .standardError:
            error.append(chunk.data)
        }
        lock.unlock()
    }
}
