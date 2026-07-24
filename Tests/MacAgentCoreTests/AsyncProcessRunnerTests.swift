import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct AsyncProcessRunnerTests {
    @Test
    func runsAProcessAndCapturesOutput() async throws {
        let result = try await AsyncProcessRunner.run(executablePath: "/bin/echo", arguments: ["hello"])
        #expect(result.terminationStatus == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    /// Regression test for a real crash: cancelling the wrapping `Task` could race
    /// `Process.run()` such that `.terminate()` landed on a process that hadn't been launched yet,
    /// which throws an uncatchable NSException (`-[NSConcreteTask terminate]: task not launched`)
    /// and takes down the whole process — not something a Swift `catch` can recover from, so a
    /// regression here would crash this test binary outright rather than fail this assertion
    /// gracefully. Repeats across many iterations against a real short-lived process specifically to
    /// vary the OS scheduling enough to hit "cancel before launch," "cancel during launch," and
    /// "cancel during waitUntilExit" — the fix makes launch-vs-terminate atomic, so every outcome
    /// here should be either a clean `CancellationError` or a genuine successful result, never a
    /// crash.
    @Test
    func rapidCancellationNeverCrashesRegardlessOfTiming() async throws {
        for _ in 0..<200 {
            let task = Task {
                try await AsyncProcessRunner.run(executablePath: "/bin/sleep", arguments: ["0.05"])
            }
            task.cancel()

            do {
                _ = try await task.value
            } catch is CancellationError {
                continue
            }
        }
    }
}
