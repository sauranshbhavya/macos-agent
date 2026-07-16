import Foundation

public struct ProcessResult: Sendable, Equatable {
    public var terminationStatus: Int32
    public var output: String

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        self.output = output
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

    public static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil
    ) async throws -> ProcessResult {
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.currentDirectoryURL = currentDirectoryURL
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                guard box.register(process) else {
                    throw CancellationError()
                }

                try process.run()
                if box.confirmLaunched() {
                    process.terminate()
                }

                process.waitUntilExit()
                box.confirmFinished()

                if box.isCancelled {
                    throw CancellationError()
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? "<unreadable process output>"
                return ProcessResult(terminationStatus: process.terminationStatus, output: output)
            }.value
        } onCancel: {
            box.cancel()
        }
    }
}
