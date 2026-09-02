// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum SubprocessOutputStream: Sendable {
    case standardOutput
    case standardError
}

struct SubprocessOutputChunk: Sendable {
    let stream: SubprocessOutputStream
    let data: Data
}

enum SubprocessTermination: Sendable, Equatable {
    case exited
    case uncaughtSignal
}

struct SubprocessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let termination: SubprocessTermination
    let standardOutput: Data
    let standardError: Data
    let discardedStandardOutputBytes: Int
    let discardedStandardErrorBytes: Int
    let duration: Duration

    var succeeded: Bool {
        termination == .exited && terminationStatus == 0
    }

    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

struct SubprocessRequest: Sendable {
    static let defaultCaptureLimit = 256 * 1024

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let currentDirectoryURL: URL?
    let standardInput: Data?
    let timeout: Duration?
    let terminationGracePeriod: Duration
    let standardOutputCaptureLimit: Int
    let standardErrorCaptureLimit: Int
    let sensitiveArgumentNames: Set<String>
    let sensitiveValues: Set<String>
    let redactURLs: Bool

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = nil,
        terminationGracePeriod: Duration = .seconds(2),
        standardOutputCaptureLimit: Int = SubprocessRequest.defaultCaptureLimit,
        standardErrorCaptureLimit: Int = SubprocessRequest.defaultCaptureLimit,
        sensitiveArgumentNames: Set<String> = [],
        sensitiveValues: Set<String> = [],
        redactURLs: Bool = true
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.standardOutputCaptureLimit = max(standardOutputCaptureLimit, 0)
        self.standardErrorCaptureLimit = max(standardErrorCaptureLimit, 0)
        self.sensitiveArgumentNames = sensitiveArgumentNames
        self.sensitiveValues = sensitiveValues
        self.redactURLs = redactURLs
    }

    /// A log-safe command representation. Callers can add tool-specific option names whose
    /// following value is sensitive; URL arguments are redacted by default.
    var redactedCommandDescription: String {
        var redactNext = false
        let redactedArguments = arguments.map { argument -> String in
            if redactNext {
                redactNext = false
                return "<redacted>"
            }

            if sensitiveValues.contains(argument) {
                return "<redacted>"
            }

            if sensitiveArgumentNames.contains(argument) {
                redactNext = true
                return argument
            }

            for option in sensitiveArgumentNames {
                let prefix = option + "="
                if argument.hasPrefix(prefix) {
                    return prefix + "<redacted>"
                }
            }

            if redactURLs, let url = URL(string: argument), url.scheme != nil {
                return "<url>"
            }
            return argument
        }

        let executableDescription = sensitiveValues.contains(executableURL.path)
            ? "<redacted-executable>"
            : executableURL.path
        return ([executableDescription] + redactedArguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    /// Redacts values known to be sensitive for this request, as well as URLs that a
    /// command may echo to stderr. The retained tail is intentionally small enough for
    /// logs and user-facing errors while preserving the most recent diagnostic context.
    func redactedDiagnostic(_ diagnostic: String, limit: Int = 8 * 1024) -> String {
        var redacted = diagnostic
        var redactNext = false

        for value in sensitiveValues.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
        }

        for argument in arguments {
            if redactNext {
                if !argument.isEmpty {
                    redacted = redacted.replacingOccurrences(of: argument, with: "<redacted>")
                }
                redactNext = false
                continue
            }

            if sensitiveArgumentNames.contains(argument) {
                redactNext = true
                continue
            }

            for option in sensitiveArgumentNames {
                let prefix = option + "="
                if argument.hasPrefix(prefix) {
                    let value = String(argument.dropFirst(prefix.count))
                    if !value.isEmpty {
                        redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
                    }
                }
            }
        }

        if redactURLs {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = Self.urlExpression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "<url>"
            )
        }

        guard limit > 0 else { return "" }
        guard redacted.count > limit else { return redacted }
        return "…" + redacted.suffix(limit)
    }

    private static let urlExpression = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#
    )

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SubprocessRunnerError: Error, LocalizedError {
    case failedToStart(command: String, underlying: String)
    case timedOut(command: String, result: SubprocessResult)

    var errorDescription: String? {
        switch self {
        case let .failedToStart(command, underlying):
            return "Failed to start \(command): \(underlying)"
        case let .timedOut(command, _):
            return "Timed out while running \(command)"
        }
    }
}

protocol SubprocessRunning: Sendable {
    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult
}

extension SubprocessRunning {
    func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        try await run(request, outputHandler: nil)
    }
}

/// Shared process-launch boundary. It drains both output streams while the child runs,
/// bounds retained diagnostics, participates in Swift task cancellation, and terminates
/// descendants before the direct child so wrapper tools do not leave encoders behind.
final class SubprocessRunner: SubprocessRunning, @unchecked Sendable {
    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)? = nil
    ) async throws -> SubprocessResult {
        try Task.checkCancellation()

        let execution = SubprocessExecution(
            request: request,
            outputHandler: outputHandler
        )

        return try await withTaskCancellationHandler {
            do {
                try execution.start()
            } catch {
                throw SubprocessRunnerError.failedToStart(
                    command: request.redactedCommandDescription,
                    underlying: error.localizedDescription
                )
            }

            if Task.isCancelled {
                execution.terminate(cause: .cancelled)
            }

            let timeoutTask = request.timeout.map { timeout in
                Task {
                    do {
                        try await Task.sleep(for: timeout)
                        execution.terminate(cause: .timedOut)
                    } catch {
                        // Normal when the process exits before its deadline.
                    }
                }
            }

            await execution.waitForExit()
            await execution.waitForTerminationCleanup()
            timeoutTask?.cancel()

            let result = execution.finish()
            switch execution.terminationCause {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw SubprocessRunnerError.timedOut(
                    command: request.redactedCommandDescription,
                    result: result
                )
            case nil:
                return result
            }
        } onCancel: {
            execution.terminate(cause: .cancelled)
        }
    }
}

private enum SubprocessTerminationCause: Sendable {
    case cancelled
    case timedOut
}

private final class SubprocessExecution: @unchecked Sendable {
    private let request: SubprocessRequest
    private let outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdoutCollector: BoundedDataCollector
    private let stderrCollector: BoundedDataCollector
    private let lock = NSLock()
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()
    private let startInstant = ContinuousClock.now

    private var hasStarted = false
    private var hasExited = false
    private var pendingTermination = false
    private var terminationStarted = false
    private var cause: SubprocessTerminationCause?
    private var terminationCleanupTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stdoutReadsFinished = false
    private var stderrReadsFinished = false

    init(
        request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) {
        self.request = request
        self.outputHandler = outputHandler
        stdinPipe = request.standardInput == nil ? nil : Pipe()
        stdoutCollector = BoundedDataCollector(limit: request.standardOutputCaptureLimit)
        stderrCollector = BoundedDataCollector(limit: request.standardErrorCaptureLimit)
    }

    var terminationCause: SubprocessTerminationCause? {
        lock.withLock { cause }
    }

    func start() throws {
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe ?? FileHandle.nullDevice

        installReadabilityHandler(
            on: stdoutPipe.fileHandleForReading,
            stream: .standardOutput,
            collector: stdoutCollector,
            readLock: stdoutReadLock
        )
        installReadabilityHandler(
            on: stderrPipe.fileHandleForReading,
            stream: .standardError,
            collector: stderrCollector,
            readLock: stderrReadLock
        )

        process.terminationHandler = { [weak self] _ in
            self?.didExit()
        }

        do {
            try process.run()
        } catch {
            removeReadabilityHandlers()
            throw error
        }

        // The child inherited duplicates of these descriptors. Closing the parent's writer
        // copies ensures the readers observe EOF as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        let shouldTerminate = lock.withLock { () -> Bool in
            hasStarted = true
            guard pendingTermination, !terminationStarted else { return false }
            terminationStarted = true
            return true
        }

        if let input = request.standardInput, let stdinPipe {
            DispatchQueue.global(qos: .utility).async {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        if shouldTerminate {
            terminateProcessTree()
        }
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if hasExited {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func terminate(cause newCause: SubprocessTerminationCause) {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !hasExited else { return false }
            if hasStarted, !process.isRunning {
                return false
            }
            if cause == nil {
                cause = newCause
            }
            if !hasStarted {
                pendingTermination = true
                return false
            }
            guard !terminationStarted else { return false }
            terminationStarted = true
            return true
        }

        if shouldTerminate {
            terminateProcessTree()
        }
    }

    func finish() -> SubprocessResult {
        removeReadabilityHandlers()

        // Collect bytes that arrived between the last readability callback and termination.
        // A descendant could still hold an inherited pipe open, so the final drain is
        // deliberately nonblocking and cannot strand the caller after the direct child exits.
        stdoutReadLock.withLock {
            stdoutReadsFinished = true
            appendRemainingData(
                from: stdoutPipe.fileHandleForReading,
                stream: .standardOutput,
                to: stdoutCollector
            )
        }
        stderrReadLock.withLock {
            stderrReadsFinished = true
            appendRemainingData(
                from: stderrPipe.fileHandleForReading,
                stream: .standardError,
                to: stderrCollector
            )
        }
        let stdout = stdoutCollector.snapshot()
        let stderr = stderrCollector.snapshot()
        let reason: SubprocessTermination = process.terminationReason == .exit
            ? .exited
            : .uncaughtSignal
        return SubprocessResult(
            terminationStatus: process.terminationStatus,
            termination: reason,
            standardOutput: stdout.data,
            standardError: stderr.data,
            discardedStandardOutputBytes: stdout.discardedByteCount,
            discardedStandardErrorBytes: stderr.discardedByteCount,
            duration: startInstant.duration(to: .now)
        )
    }

    private func installReadabilityHandler(
        on handle: FileHandle,
        stream: SubprocessOutputStream,
        collector: BoundedDataCollector,
        readLock: NSLock
    ) {
        handle.readabilityHandler = { [outputHandler] fileHandle in
            readLock.withLock {
                switch stream {
                case .standardOutput where self.stdoutReadsFinished:
                    return
                case .standardError where self.stderrReadsFinished:
                    return
                default:
                    break
                }

                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                collector.append(data)
                outputHandler?(SubprocessOutputChunk(stream: stream, data: data))
            }
        }
    }

    private func removeReadabilityHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func appendRemainingData(
        from handle: FileHandle,
        stream: SubprocessOutputStream,
        to collector: BoundedDataCollector
    ) {
        let descriptor = handle.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
        }

        while true {
            do {
                guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else {
                    break
                }
                collector.append(data)
                outputHandler?(SubprocessOutputChunk(stream: stream, data: data))
            } catch {
                break
            }
        }
        try? handle.close()
    }

    private func didExit() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !hasExited else { return [] }
            hasExited = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func terminateProcessTree() {
        guard process.isRunning else { return }
        let processID = process.processIdentifier
        let initialDescendants = Self.descendantProcessIDs(of: processID)
        let gracePeriod = request.terminationGracePeriod
        let cleanupTask = Task.detached(priority: .utility) { [process] in
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }

            var remainingDescendants = initialDescendants
            if process.isRunning {
                remainingDescendants.append(contentsOf: Self.descendantProcessIDs(of: processID))
            }
            for childID in Set(remainingDescendants) {
                _ = Darwin.kill(childID, SIGKILL)
            }
            if process.isRunning {
                _ = Darwin.kill(processID, SIGKILL)
            }
        }
        lock.withLock {
            terminationCleanupTask = cleanupTask
        }

        for childID in initialDescendants.reversed() {
            _ = Darwin.kill(childID, SIGTERM)
        }
        process.terminate()
    }

    func waitForTerminationCleanup() async {
        let cleanupTask = lock.withLock { terminationCleanupTask }
        if let cleanupTask {
            await cleanupTask.value
        }
    }

    private static func descendantProcessIDs(of processID: pid_t) -> [pid_t] {
        childProcessIDs(of: processID).flatMap { childID in
            [childID] + descendantProcessIDs(of: childID)
        }
    }

    private static func childProcessIDs(of processID: pid_t) -> [pid_t] {
        let requiredBytes = proc_listchildpids(processID, nil, 0)
        guard requiredBytes > 0 else { return [] }

        let capacity = Int(requiredBytes) / MemoryLayout<pid_t>.stride
        var processIDs = [pid_t](repeating: 0, count: capacity)
        let writtenCount = processIDs.withUnsafeMutableBytes { buffer in
            proc_listchildpids(processID, buffer.baseAddress, Int32(buffer.count))
        }
        guard writtenCount > 0 else { return [] }

        // Unlike proc_listpids, proc_listchildpids returns a PID count when a buffer is supplied.
        let count = min(Int(writtenCount), processIDs.count)
        return Array(processIDs.prefix(count)).filter { $0 > 0 }
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var discardedByteCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        lock.withLock {
            guard limit > 0 else {
                discardedByteCount += newData.count
                return
            }

            data.append(newData)
            if data.count > limit {
                let excess = data.count - limit
                data.removeFirst(excess)
                discardedByteCount += excess
            }
        }
    }

    func snapshot() -> (data: Data, discardedByteCount: Int) {
        lock.withLock { (data, discardedByteCount) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
