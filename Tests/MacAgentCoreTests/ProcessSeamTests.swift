import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct ProcessSeamTests {
    /// Reproduces the pipe deadlock: `/bin/cat` writes far more than the OS pipe buffer holds,
    /// so waiting for exit before draining the pipe blocks both sides forever. Raced against a
    /// timeout so a regression fails the suite instead of hanging it.
    @Test
    func asyncProcessRunnerCapturesOutputLargerThanThePipeBuffer() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = String(repeating: "sonny-process-output-line\n", count: 20_000)
        let file = root.appendingPathComponent("large.txt")
        try payload.write(to: file, atomically: true, encoding: .utf8)

        let result = await withTaskGroup(of: ProcessResult?.self, returning: ProcessResult?.self) { group in
            group.addTask {
                try? await AsyncProcessRunner.run(
                    executablePath: "/bin/cat",
                    arguments: [file.path]
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        let processResult = try #require(result, "AsyncProcessRunner deadlocked on large output")
        #expect(processResult.terminationStatus == 0)
        #expect(processResult.output.count == payload.count)
    }

    @Test
    func asyncProcessRunnerReportsNonZeroExitWithOutput() async throws {
        let result = try await AsyncProcessRunner.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo failure-detail >&2; exit 3"]
        )

        #expect(result.terminationStatus == 3)
        #expect(result.output.contains("failure-detail"))
    }

    @Test
    func finderAutomationDenialIsDistinguishedFromOtherAppleScriptFailures() {
        let denied = FinderContextError.from(
            output: "execution error: Not authorized to send Apple events to Finder. (-1743)"
        )
        #expect(denied == .automationPermissionDenied("execution error: Not authorized to send Apple events to Finder. (-1743)"))
        #expect(denied.errorDescription?.contains("System Settings") == true)

        let other = FinderContextError.from(output: "execution error: Finder got an error: (-1728)")
        guard case .appleScriptFailed = other else {
            Issue.record("Expected a non-authorization osascript failure to stay generic, got \(other).")
            return
        }
    }

    // `WorkspaceBrowserOpener`'s seam tests moved to `WorkspaceBrowserOpenerTests` when the opener
    // got its own file (SONNY-9).

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-process-seam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
