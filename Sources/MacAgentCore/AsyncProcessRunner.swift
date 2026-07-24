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
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isLaunched = false
        private var cancelled = false

        /// Launches `process` unless cancellation already landed — atomically with respect to
        /// `cancel()`, since `process.run()` itself happens while holding the same lock `cancel()`
        /// uses to decide whether terminating is safe. That closes the race the previous
        /// set()-then-run() split had: `cancel()` could see a stored `process` and call
        /// `.terminate()` on it before `run()` had actually been called, and Foundation's
        /// `Process.terminate()` on an unlaunched process throws an uncatchable NSException
        /// (`-[NSConcreteTask terminate]: task not launched`) that crashes the whole process, not a
        /// catchable Swift error. Returns false (without ever calling `.run()`) if cancellation
        /// already landed, so the caller can throw a clean `CancellationError` instead.
        func launchIfNotCancelled(_ process: Process) throws -> Bool {
            lock.lock()
            defer { lock.unlock() }

            self.process = process
            guard !cancelled else {
                return false
            }
            try process.run()
            isLaunched = true
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let shouldTerminate = isLaunched
            let process = process
            lock.unlock()

            if shouldTerminate {
                process?.terminate()
            }
        }

        var isCancelled: Bool {
            lock.lock()
            let value = cancelled
            lock.unlock()
            return value
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

                guard try box.launchIfNotCancelled(process) else {
                    throw CancellationError()
                }

                process.waitUntilExit()

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
