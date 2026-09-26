import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var terminationStatus: Int32
    public var output: String
    /// Standard error, for a run that kept it apart from `output`. Otherwise it is part of `output`
    /// and this is empty.
    public var errorOutput: String

    public init(terminationStatus: Int32, output: String, errorOutput: String = "") {
        self.terminationStatus = terminationStatus
        self.output = output
        self.errorOutput = errorOutput
    }
}

public enum ProcessOutputCapture {
    /// Drains `pipe` to EOF and *only then* waits for exit. The opposite order deadlocks any
    /// child that writes more than the OS pipe buffer holds (~64KB): the child blocks in
    /// `write()` waiting for a reader while the parent blocks in `waitUntilExit()` waiting for
    /// the child, and neither side can ever proceed. Every combined-output `Process` call in
    /// this package goes through here so the ordering can't regress site by site.
    public static func drainThenWait(process: Process, pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? "<unreadable process output>"
    }
}

public enum AsyncProcessRunner {
    /// Tracks a `Process` alongside cancellation so `terminate()` is only ever called on an
    /// instance that has actually completed `run()`. `Process.terminate()` raises an uncaught
    /// `NSException` ("task not launched") if called before launch completes, and cancellation
    /// can arrive at any point relative to launch because the runner executes on a detached task
    /// that does not inherit structured-concurrency cancellation. `phase` and `cancelled` are
    /// only ever read/written together under `lock`, so exactly one of `cancel()` or
    /// `confirmLaunched()` ends up responsible for terminating a given process — never both,
    /// and never before `run()` has returned successfully.
    private final class ProcessBox: @unchecked Sendable {
        private enum Phase {
            case notLaunched
            case launched
            case finished
        }

        private let lock = NSLock()
        private var process: Process?
        private var phase: Phase = .notLaunched
        private var cancelled = false

        /// Registers the process. Returns `false` if cancellation already happened, in which
        /// case the caller must skip calling `run()` entirely.
        func register(_ process: Process) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            self.process = process
            return !cancelled
        }

        /// Call immediately after `process.run()` returns successfully. Returns `true` if the
        /// caller must terminate the process itself because cancellation raced in before it
        /// could be observed as launched.
        func confirmLaunched() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            phase = .launched
            return cancelled
        }

        /// Call immediately after `process.waitUntilExit()` returns.
        func confirmFinished() {
            lock.lock()
            phase = .finished
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let processToTerminate = phase == .launched ? process : nil
            lock.unlock()

            processToTerminate?.terminate()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    /// With `separatingErrorOutput`, standard error goes to `errorOutput` instead of `output`, for a
    /// caller whose child can write diagnostics on success that must not end up in its reply.
    public static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        separatingErrorOutput: Bool = false
    ) async throws -> ProcessResult {
        try await run(
            executablePath: executablePath,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            separatingErrorOutput: separatingErrorOutput,
            beforeLaunch: {}
        )
    }

    /// `beforeLaunch` runs after the process is registered for cancellation and before it launches.
    /// Only tests pass one: a cancel landing in that gap is the one path a test can't otherwise
    /// reach, because a launch takes less time than a cancel does to arrive (SONNY-342).
    static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        separatingErrorOutput: Bool = false,
        beforeLaunch: @escaping @Sendable () -> Void
    ) async throws -> ProcessResult {
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.currentDirectoryURL = currentDirectoryURL
                process.arguments = arguments

                let pipe = Pipe()
                let errorPipe = separatingErrorOutput ? Pipe() : pipe
                process.standardOutput = pipe
                process.standardError = errorPipe

                guard box.register(process) else {
                    throw CancellationError()
                }

                beforeLaunch()
                try process.run()
                if box.confirmLaunched() {
                    process.terminate()
                }

                // Standard error drains alongside the output, so neither pipe can fill and block
                // the child.
                let errors = separatingErrorOutput ? Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() } : nil
                let output = ProcessOutputCapture.drainThenWait(process: process, pipe: pipe)
                box.confirmFinished()
                var errorOutput = ""
                if let errors {
                    errorOutput = String(decoding: await errors.value, as: UTF8.self)
                }

                if box.isCancelled {
                    throw CancellationError()
                }

                return ProcessResult(terminationStatus: process.terminationStatus, output: output, errorOutput: errorOutput)
            }.value
        } onCancel: {
            box.cancel()
        }
    }
}
