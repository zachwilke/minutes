import Foundation

enum ShellError: LocalizedError {
    case launchFailed(String, Error)
    case nonZeroExit(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let error):
            return "Could not run \(tool): \(error.localizedDescription)"
        case .nonZeroExit(let tool, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = detail.isEmpty ? "" : "\n\(String(detail.suffix(600)))"
            return "\(tool) exited with status \(status).\(tail)"
        }
    }
}

enum Shell {
    struct Output: Sendable {
        var status: Int32
        var standardOutput: String
        var standardError: String
    }

    /// Runs a subprocess to completion, draining both pipes concurrently so a
    /// chatty tool (Whisper logs heavily to stderr) can never deadlock us.
    /// `onStandardErrorLine` is called as lines arrive, which is how the UI gets
    /// live progress out of Whisper.
    static func run(executable: URL,
                    arguments: [String],
                    standardInput: String? = nil,
                    environment: [String: String]? = nil,
                    currentDirectory: URL? = nil,
                    timeout: TimeInterval? = nil,
                    qualityOfService: QualityOfService = .default,
                    onStandardOutputLine: (@Sendable (String) -> Void)? = nil,
                    onStandardErrorLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let toolName = executable.lastPathComponent
        // A child that exits before reading its input turns our stdin write into
        // SIGPIPE, whose default action kills the whole app. Ignoring it makes
        // the write fail with EPIPE instead, which is handled below.
        _ = ignoreBrokenPipe
        let handle = ProcessHandle()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.qualityOfService = qualityOfService
                    if let environment { process.environment = environment }
                    if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    let inPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe
                    process.standardInput = inPipe

                    let group = DispatchGroup()
                    let collector = OutputCollector()

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave() }
                        // Read incrementally when a line handler is present, so
                        // streaming output (chat replies arriving token by token) can
                        // be surfaced while the process is still running.
                        guard let onStandardOutputLine else {
                            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                            collector.appendStandardOutput(data)
                            return
                        }
                        var pending = Data()
                        while true {
                            let chunk = outPipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            collector.appendStandardOutput(chunk)
                            pending.append(chunk)
                            while let newline = pending.firstIndex(of: 0x0A) {
                                let lineData = pending[pending.startIndex..<newline]
                                pending.removeSubrange(pending.startIndex...newline)
                                if let line = String(data: lineData, encoding: .utf8) {
                                    onStandardOutputLine(line)
                                }
                            }
                        }
                        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
                            onStandardOutputLine(line)
                        }
                    }

                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { group.leave() }
                        // Read incrementally so progress lines surface while the
                        // tool is still working.
                        var pending = Data()
                        while true {
                            let chunk = errPipe.fileHandleForReading.availableData
                            if chunk.isEmpty { break }
                            collector.appendStandardError(chunk)
                            guard let onStandardErrorLine else { continue }
                            pending.append(chunk)
                            while let newline = pending.firstIndex(of: 0x0A) {
                                let lineData = pending[pending.startIndex..<newline]
                                pending.removeSubrange(pending.startIndex...newline)
                                if let line = String(data: lineData, encoding: .utf8) {
                                    onStandardErrorLine(line)
                                }
                            }
                        }
                        if let onStandardErrorLine, !pending.isEmpty,
                           let line = String(data: pending, encoding: .utf8) {
                            onStandardErrorLine(line)
                        }
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: ShellError.launchFailed(toolName, error))
                        return
                    }
                    handle.attach(process)
                    live.insert(handle)
                    defer { live.remove(handle) }

                    // Written on its own queue so the deadline below runs from launch:
                    // a child that never reads would otherwise block us before the
                    // timeout loop even starts. The throwing API matters — the legacy
                    // `write(_:)` raises an Objective-C exception on EPIPE.
                    let writer = inPipe.fileHandleForWriting
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let standardInput {
                            do {
                                try writer.write(contentsOf: Data(standardInput.utf8))
                            } catch {
                                Log.warn("\(toolName) closed its input early: \(error.localizedDescription)")
                            }
                        }
                        try? writer.close()
                    }

                    // Without a deadline a wedged tool blocks this thread — and any
                    // UI waiting on it — indefinitely.
                    if let timeout {
                        let deadline = Date().addingTimeInterval(timeout)
                        while process.isRunning, Date() < deadline {
                            usleep(50_000)
                        }
                        if process.isRunning {
                            Log.warn("\(toolName) exceeded \(Int(timeout))s; terminating")
                            handle.stop()
                        }
                    }

                    process.waitUntilExit()
                    // A grandchild that inherited the pipes keeps them open after
                    // the tool itself has exited, and EOF never arrives. Whatever
                    // was written before the exit is in the pipe by now.
                    if group.wait(timeout: .now() + 5) == .timedOut {
                        Log.warn("\(toolName) exited but its output stayed open; not waiting for it")
                    }

                    if handle.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: Output(status: process.terminationStatus,
                                                         standardOutput: collector.standardOutputString,
                                                         standardError: collector.standardErrorString))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Every child still running, so quitting can take them down too. A child
    /// outlives its parent otherwise: Whisper would go on transcribing a meeting
    /// that the next launch then transcribes again.
    private static let live = LiveProcesses()

    /// Stops every running child. Their `run` calls end in `CancellationError`.
    static func cancelAll() {
        live.cancelAll()
    }

    /// Same as `run`, but treats a non-zero exit as an error.
    static func runChecked(executable: URL,
                           arguments: [String],
                           standardInput: String? = nil,
                           environment: [String: String]? = nil,
                           onStandardErrorLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let output = try await run(executable: executable,
                                   arguments: arguments,
                                   standardInput: standardInput,
                                   environment: environment,
                                   onStandardErrorLine: onStandardErrorLine)
        guard output.status == 0 else {
            throw ShellError.nonZeroExit(executable.lastPathComponent, output.status, output.standardError)
        }
        return output.standardOutput
    }
}

/// Lets task cancellation, which arrives on an arbitrary thread, reach a process
/// that may not have launched yet.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let cancelEarly = cancelled
        lock.unlock()
        if cancelEarly { stop() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        stop()
    }

    /// SIGTERM, then SIGKILL if the tool ignores it — `claude` is a Node
    /// process and does not always exit promptly on TERM.
    func stop() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class LiveProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [ObjectIdentifier: ProcessHandle] = [:]

    func insert(_ handle: ProcessHandle) {
        lock.lock(); handles[ObjectIdentifier(handle)] = handle; lock.unlock()
    }
    func remove(_ handle: ProcessHandle) {
        lock.lock(); handles[ObjectIdentifier(handle)] = nil; lock.unlock()
    }
    func cancelAll() {
        lock.lock(); let all = Array(handles.values); lock.unlock()
        all.forEach { $0.cancel() }
    }
}

/// Thread-safe accumulator for the two pipe readers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendStandardOutput(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendStandardError(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }

    var standardOutputString: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: out, encoding: .utf8) ?? ""
    }
    var standardErrorString: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: err, encoding: .utf8) ?? ""
    }
}
