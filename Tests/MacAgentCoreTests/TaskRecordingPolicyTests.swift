import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// "Don't save this task" — the rule, and the leak that pausing alone does not close.
struct TaskRecordingPolicyTests {
    /// The reach is read off the classification, so this asserts the rule rather than a list. Any
    /// store added later is judged by the same three lines.
    @Test
    func suppressionWithholdsEveryTraceAndNothingElse() {
        for store in LocalStore.allCases {
            switch store.kind {
            case .trace:
                #expect(!TaskRecordingPolicy.suppressTraces.allowsWriting(to: store), "\(store) should be withheld")
            case .artifact, .notWrittenByTasks:
                #expect(TaskRecordingPolicy.suppressTraces.allowsWriting(to: store), "\(store) should not be withheld")
            }
            // Recording is unconditional, whatever the store is.
            #expect(TaskRecordingPolicy.record.allowsWriting(to: store))
        }
    }

    /// Named explicitly as well, so a reclassification that silently changes what the switch reaches
    /// fails here and not only in the classification's own test. The withheld set is the founder's
    /// five plus row E's plan details (SONNY-147), a trace for the same reason the row it hangs off
    /// is, row 13's output locations (SONNY-209), a trace because nobody asked Sonny to remember
    /// which folder a file went into, and row 13's unfinished runs (SONNY-210), a trace for the same
    /// reason again — so a suppressed run raises no offer to carry on with itself. The kept set
    /// gained row J's approved-apps store, an `.artifact` because a grant is the user's own answer
    /// rather than a record of what happened (SONNY-140).
    ///
    /// **No count in the name, deliberately** (the SONNY-209 lesson, applied at the moment it would
    /// otherwise have gone stale again — and it would have, twice, in the two days between these two
    /// stores landing): this name has been wrong before, and a renamed test takes every doc comment
    /// that cited it with it. The numbers live in the assertions below, where the suite disagrees
    /// with a wrong one.
    @Test
    func theWithheldStoresAreTheTracesAndTheKeptOnesAreEverythingElse() {
        let withheld = Set(LocalStore.allCases.filter { !TaskRecordingPolicy.suppressTraces.allowsWriting(to: $0) })
        #expect(withheld == [
            .clipboardHistory,
            .recentArtifacts,
            .outputLocations,
            .resumableTasks,
            .shortcutRunHistory,
            .taskHistory,
            .taskPlanDetails,
            .visionSessionJournal
        ])
        let kept = Set(LocalStore.allCases.filter { TaskRecordingPolicy.suppressTraces.allowsWriting(to: $0) })
        #expect(kept == [
            .routines,
            .workspaces,
            .snippets,
            .clipboardHistorySettings,
            .approvedApps,
            // Task deletions this Mac owes the gateway (SONNY-333) — kept, and this is the one
            // entry here whose *reason* is a live defect rather than a classification preference.
            // No task writes it, so there is nothing to withhold; and withholding it anyway would
            // let a run with "Don't save this task" on stop a deletion the user pressed for from
            // ever reaching the server.
            .pendingServerDeletions
        ])
        // The two sets partition the whole population, which is what makes naming them a claim about
        // every store rather than about the ones somebody remembered.
        #expect(withheld.count + kept.count == LocalStore.allCases.count)
    }

    @Test
    func suppressesTracesAgreesWithTheCaseItReports() {
        #expect(TaskRecordingPolicy.suppressTraces.suppressesTraces)
        #expect(!TaskRecordingPolicy.record.suppressesTraces)
        #expect(TaskRecordingPolicy.allCases.count == 2)
    }

    /// **The default is load-bearing and was asserted by nothing** (PR #67 review, F6, replacing
    /// `#expect(CapabilityExecutionContext.self is Any.Type)` — trivially true and pinning nothing).
    ///
    /// `.record` is what makes every pre-existing construction site and every existing test keep its
    /// old behaviour when the policy was threaded through. If either default flipped, suppression
    /// would become the norm silently: traces would stop being written for runs nobody opted out of,
    /// in the safe direction and therefore quietly.
    @Test
    @MainActor
    func aContextAndAnExecutorBuiltWithoutAPolicyBothRecord() {
        // The context's own default, read off a context built the way every non-suppressing caller
        // builds one.
        let context = VisionTestContext.make(installed: [])
        #expect(context.recordingPolicy == .record)
        #expect(!context.recordingPolicy.suppressesTraces)

        // The executor's default parameter, taken rather than passed.
        #expect(!AgentActionExecutor(
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
        ).suppressesTracesForTests)
        #expect(AgentActionExecutor(
            recordingPolicy: .suppressTraces,
            routineStore: UnreachableLocalStores.routines(),
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
            resumableTaskStore: UnreachableLocalStores.resumableTasks(),
        ).suppressesTracesForTests)
    }

    /// **The leak pausing alone does not close, pinned as a regression.**
    ///
    /// `poll()` records whenever the pasteboard's change count differs from the last one it saw, and
    /// that counter survives a pause. So a run that stops the timer, lets the user copy something,
    /// and restarts it records exactly the text the pause existed to withhold — measured before
    /// `resynchronize()` existed, and it did.
    @Test
    @MainActor
    func resynchronisingOnResumeIsWhatKeepsAPausedRunFromRecordingWhatWasCopied() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let store = ClipboardHistoryStore(
            fileURL: root.appendingPathComponent("clipboard-history.json"), encryption: encryption
        )
        let settings = ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"), encryption: encryption
        )
        try settings.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        // One clock for the monitor and every read below. `ClipboardHistoryStore` ages records out
        // after seven days, so recording at a fixed 2023 instant and reading at `Date()` empties the
        // store for a reason that has nothing to do with what is under test.
        let clock = Date()
        let reader = StubPasteboardReader(changeCount: 1, string: "before the task")
        let monitor = ClipboardHistoryMonitor(
            reader: reader, store: store, settingsStore: settings, now: { clock }
        )

        _ = try monitor.poll()
        #expect(try store.loadAll(now: clock).map(\.text) == ["before the task"])

        // The suppressed run: the timer is stopped, so nothing polls, and the user copies.
        reader.changeCount = 2
        reader.string = "typed during the suppressed task"

        // The run ends. Resynchronise *before* polling resumes — this is the whole fix.
        monitor.resynchronize()
        _ = try monitor.poll()

        #expect(try store.loadAll(now: clock).map(\.text) == ["before the task"])

        // And normal recording resumes for the next copy, so the pause is a pause and not an off
        // switch.
        reader.changeCount = 3
        reader.string = "after the task"
        _ = try monitor.poll()
        #expect(try store.loadAll(now: clock).map(\.text).contains("after the task"))
    }
}

@MainActor
private final class StubPasteboardReader: PasteboardReading {
    var changeCount: Int
    var string: String?

    init(changeCount: Int, string: String?) {
        self.changeCount = changeCount
        self.string = string
    }

    func typeIdentifiers() -> [String] { [] }
    func stringValue() -> String? { string }
}
