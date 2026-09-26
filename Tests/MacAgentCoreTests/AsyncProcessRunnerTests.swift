import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// `AsyncProcessRunner` runs the zip, Word conversion and Shortcuts children. Stopping a task has
/// to stop its child, whether the stop lands after the child started or in the moment before.
///
/// These tests lived in `AgentActionExecutorTests` and went with the V1 executor in phase 7,
/// although the runner is still used; they are restored here, where the runner is the subject.
@Suite
@MainActor
struct AsyncProcessRunnerTests {
    @Test
    func capturesRealStdout() async throws {
        let result = try await AsyncProcessRunner.run(executablePath: "/bin/echo", arguments: ["hello"])
        #expect(result.terminationStatus == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    /// A cancel that reaches a child which is really running throws `CancellationError`. The child
    /// says when it has started, so no sleep decides whether the cancel lands in time; `exec` makes
    /// the long sleep the only process holding the output pipe.
    @Test
    func cancellingARunningChildThrowsCancellation() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launched = root.appendingPathComponent("launched")
        let task = Task {
            try await AsyncProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf running > \"$1\"; exec sleep 300", "sonny-cancel-test", launched.path]
            )
        }
        guard try await launchSignal(at: launched) else {
            task.cancel()
            return
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// Cancelling kills the child, not just the wait. The child traps `TERM` and writes a sentinel,
    /// and only the runner sends that signal, so the sentinel is the child's own report that it was
    /// terminated. The background sleep writes to /dev/null so the shell alone holds the pipe.
    @Test
    func cancellingTerminatesTheChild() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launched = root.appendingPathComponent("launched")
        let terminated = root.appendingPathComponent("terminated")
        let pidFile = root.appendingPathComponent("pid")
        let script = """
        trap 'kill "$SLEEP_PID" 2>/dev/null; printf terminated > "$2"; exit 0' TERM
        printf %d "$$" > "$3"
        printf running > "$1"
        sleep 300 >/dev/null 2>&1 &
        SLEEP_PID=$!
        wait "$SLEEP_PID"
        """
        let task = Task {
            try await AsyncProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", script, "sonny-terminate-test", launched.path, terminated.path, pidFile.path]
            )
        }
        guard try await launchSignal(at: launched) else {
            task.cancel()
            return
        }
        task.cancel()

        let signalled = try await HangBackstop.waitRecordingAStuckWait(
            for: "the cancelled child to report that it was signalled",
            stuck: "The runner did not terminate the child: it was cancelled after it started, and its TERM trap never ran."
        ) {
            (try? String(contentsOf: terminated, encoding: .utf8)) == "terminated"
        }
        guard signalled else {
            // Send the signal the runner didn't, so the child doesn't outlive the test.
            if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(pid_t.init) {
                kill(pid, SIGTERM)
            }
            return
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    /// A cancel that lands while the child is launching still stops it once it has (SONNY-342).
    /// The runner calls `beforeLaunch` in exactly that gap, and the test cancels there. The child
    /// sleeps five minutes: a runner that stopped it finishes at once, and one that didn't is still
    /// waiting on the child when the backstop gives up. No clock is party to it, so a busy main actor
    /// only delays the answer.
    @Test
    func aCancelThatLandsWhileTheChildLaunchesStillStopsIt() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let registered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let task = Task {
            try await AsyncProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "printf %d \"$$\" > \"$1\"; exec sleep 300", "sonny-launch-cancel-test", pidFile.path],
                currentDirectoryURL: nil,
                beforeLaunch: {
                    registered.signal()
                    proceed.wait()
                }
            )
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                registered.wait()
                done.resume()
            }
        }
        // The cancel reaches the runner at once; the launch goes ahead only afterwards.
        task.cancel()
        proceed.signal()

        let finished = Shared(false)
        let outcome = Task {
            defer { finished.value = true }
            _ = try await task.value
        }
        let ended = try await HangBackstop.waitRecordingAStuckWait(
            for: "the cancelled run to finish",
            stuck: "The runner did not stop a child whose cancel landed while it was launching: the run is still waiting on it."
        ) {
            finished.value
        }
        guard ended else {
            // Stop the child the runner didn't, so it doesn't outlive the test.
            if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(pid_t.init) {
                kill(pid, SIGKILL)
            }
            return
        }
        await #expect(throws: CancellationError.self) { try await outcome.value }
    }

    // MARK: Helpers

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsyncProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Waits for the child's own "I'm running" file. False if it never came.
    private func launchSignal(at url: URL) async throws -> Bool {
        try await HangBackstop.waitRecordingAStuckWait(
            for: "the child to signal that it launched",
            stuck: "The child never signalled that it had launched, so /bin/sh could not be started."
        ) {
            FileManager.default.fileExists(atPath: url.path)
        }
    }
}
