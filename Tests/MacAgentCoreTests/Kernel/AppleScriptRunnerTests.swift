import Darwin
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// `OsascriptRunner` against the real `/usr/bin/osascript`, and Mail's send over it. The scripts talk
/// to no app, so they need no Automation permission: a long `delay` stands in for an app that never
/// answers, and `error … number -1712` for one whose Apple Event timed out.
///
/// Every wait for a run to end is a hang backstop, never a clock: the hanging script lasts five
/// minutes, so a run that ends inside the backstop was ended by the runner, not by the script.
@Suite
@MainActor
struct AppleScriptRunnerTests {
    /// Writes osascript's own pid to the file named in its first argument, then never answers.
    static let hangingScript = """
    on run argv
      do shell script "printf %d $PPID > " & quoted form of (item 2 of argv)
      delay 300
    end run
    """

    static let eventTimeoutScript = #"error "Mail got an error: AppleEvent timed out." number -1712"#

    @Test
    func aScriptPastItsDeadlineIsStoppedAndReportedAsTimedOut() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let finished = Shared(false)
        let run = Task {
            defer { finished.value = true }
            _ = try await OsascriptRunner().run(Self.hangingScript, arguments: [pidFile.path], timeout: 2)
        }
        guard try await waitForEnd(pidFile: pidFile, stuck: "The runner kept waiting for a script that ran past its deadline.", until: { finished.value }) else { return }
        await #expect(throws: AppleScriptRunError.timedOut) { try await run.value }
        // A script stopped before it got as far as writing its pid has already been shown to be gone:
        // the run only ends once the child has exited.
        if let pid = Self.pid(in: pidFile) {
            #expect(!Self.isRunning(pid), "The script was left running after its deadline.")
        }
    }

    @Test
    func stoppingTheTaskStopsTheScript() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let finished = Shared(false)
        let run = Task {
            defer { finished.value = true }
            _ = try await OsascriptRunner().run(Self.hangingScript, arguments: [pidFile.path], timeout: 300)
        }
        guard let pid = try await waitForScript(pidFile: pidFile) else {
            run.cancel()
            return
        }
        run.cancel()
        guard try await waitForEnd(pidFile: pidFile, stuck: "Stopping the task left the runner waiting on its script.", until: { finished.value }) else { return }
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(!Self.isRunning(pid), "The script was left running after the task was stopped.")
    }

    @Test
    func anAppleEventThatTimedOutIsReportedAsTimedOut() async throws {
        await #expect(throws: AppleScriptRunError.timedOut) {
            _ = try await OsascriptRunner().run(Self.eventTimeoutScript, arguments: [], timeout: 60)
        }
    }

    /// What the script writes to standard error (here a `log` line) stays out of its reply, and an
    /// ordinary script error is still a plain failure.
    @Test
    func theReplyIsTheScriptsResultAloneAndOtherErrorsStayFailures() async throws {
        let reply = try await OsascriptRunner().run("""
        on run argv
          log "chatter on standard error"
          return item 2 of argv
        end run
        """, arguments: ["-not an option"], timeout: 60)
        #expect(reply == "-not an option")

        do {
            _ = try await OsascriptRunner().run(#"error "Can't get outgoing message." number -1728"#, arguments: [], timeout: 60)
            Issue.record("A script error was reported as success.")
        } catch AppleScriptRunError.failed(let message) {
            #expect(message.contains("-1728"))
        }
    }

    // MARK: Mail's send

    @Test
    func aSendWhoseAppleEventTimedOutIsUnknownNotFailed() async throws {
        let outcome = await send(over: ScriptedSend(script: Self.eventTimeoutScript, arguments: [], timeout: 60))
        #expect(outcome.status == .outcomeUnknown)
    }

    @Test
    func aSendPastItsDeadlineIsUnknownNotFailed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let outcome = Shared<CapabilityOutcome?>(nil)
        Task {
            outcome.value = await send(over: ScriptedSend(script: Self.hangingScript, arguments: [pidFile.path], timeout: 2))
        }
        guard try await waitForEnd(pidFile: pidFile, stuck: "A send past its deadline was still waiting on Mail.", until: { outcome.value != nil }) else { return }
        #expect(outcome.value?.status == .outcomeUnknown)
    }

    @Test
    func aSendStoppedMidwayIsUnknownNotFailed() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let outcome = Shared<CapabilityOutcome?>(nil)
        let sending = Task {
            outcome.value = await send(over: ScriptedSend(script: Self.hangingScript, arguments: [pidFile.path], timeout: 300))
        }
        guard try await waitForScript(pidFile: pidFile) != nil else {
            sending.cancel()
            return
        }
        sending.cancel()
        guard try await waitForEnd(pidFile: pidFile, stuck: "Stopping a send left it waiting on Mail.", until: { outcome.value != nil }) else { return }
        #expect(outcome.value?.status == .outcomeUnknown)
    }

    // MARK: Helpers

    /// Mail as `send_mail` sees it: draft 42 reads back, and the send runs `script` on the real runner.
    struct ScriptedSend: AppleScriptRunning {
        let script: String
        let arguments: [String]
        let timeout: TimeInterval

        func run(_ template: String, arguments: [String], timeout: TimeInterval) async throws -> String {
            if template == MailCapabilities.readScript {
                return ["Lunch", "Friday?", "sam@example.com", ""].joined(separator: MailCapabilities.separator)
            }
            return try await OsascriptRunner().run(script, arguments: self.arguments, timeout: self.timeout)
        }
    }

    private func send(over runner: ScriptedSend) async -> CapabilityOutcome {
        let capability = SendMailCapability(runner: runner)
        guard let prepared = try? await capability.prepare(actionID: ActionID(), args: ["draft": .string("42")]) else {
            return .failed(.executionError, "prepare failed")
        }
        return await capability.execute(prepared)
    }

    private func waitForScript(pidFile: URL) async throws -> pid_t? {
        let started = try await HangBackstop.waitRecordingAStuckWait(
            for: "the script to write its pid",
            stuck: "osascript never wrote its pid, so the script could not be started."
        ) {
            Self.pid(in: pidFile) != nil
        }
        return started ? Self.pid(in: pidFile) : nil
    }

    /// False when the run never ended; the script is then killed here so it doesn't outlive the test.
    private func waitForEnd(pidFile: URL, stuck: String, until ended: @MainActor () -> Bool) async throws -> Bool {
        let done = try await HangBackstop.waitRecordingAStuckWait(for: "the run to end", stuck: stuck, until: ended)
        if !done, let pid = Self.pid(in: pidFile) {
            kill(pid, SIGKILL)
        }
        return done
    }

    private static func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8)).flatMap { pid_t($0) }
    }

    /// Signal 0 checks the process exists without touching it.
    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppleScriptRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
