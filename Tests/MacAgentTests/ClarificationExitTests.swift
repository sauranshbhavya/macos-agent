import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-166 — a clarification can be abandoned.
///
/// Before this, `clarificationQuestion` had exactly three clearing sites: answering it, wiping all
/// local data, and the unconditional reset at the start of the next run (which no dispatch could
/// reach, because `canSubmit` refuses while a question is open). So a user who did not want to
/// answer had three ways out, two of which were "wipe everything" and "quit".
///
/// **Every test here drives the real dispatch path.** A bare `"="` is a command the deterministic
/// fixture genuinely cannot act on, so `AgentActionExecutor.prepare` returns a real
/// `PreparedAgentRun` carrying a real `clarificationQuestion` and `performStart` really pauses on
/// it — the same route a typed command takes. Setting `viewModel.clarificationQuestion` by hand
/// reaches the same published property while leaving `preparedRun`, `pendingTaskHistoryStartedAt`
/// and the recording policy in states the app can never actually be in, and the exit's whole
/// correctness argument is about those.
@Suite
@MainActor
struct ClarificationExitTests {
    /// **The headline acceptance criterion**: out of the question, without answering it, without
    /// wiping local data, and without quitting.
    @Test
    func aClarificationCanBeAbandonedWithoutAnsweringOrWipingOrQuitting() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.clarificationQuestion != nil)
        // The half that made the trap a trap: the composer is shut while the question is open, so
        // there was no typing past it either.
        #expect(viewModel.isTaskInFlight)

        viewModel.cancelCurrentRun()

        #expect(viewModel.clarificationQuestion == nil)
        #expect(viewModel.clarificationAnswer.isEmpty)
        #expect(viewModel.finalSummary == ClarificationPresentation.canceledSummary)
        // The app is usable again without a relaunch: nothing is in flight, and a new command can
        // be submitted through the same gate that was refusing every dispatch a moment ago.
        #expect(!viewModel.isTaskInFlight)
        #expect(!viewModel.isRunning)
        viewModel.command = "= 1 + 1"
        #expect(viewModel.canSubmit)
    }

    /// The ticket's sharpest piece of evidence, inverted into a pin. `canCancel` was
    /// `isAwaitingApproval || (isRunning && currentTask != nil)`, and a clarification pause makes
    /// **both** terms false — so the view model did not merely fail to offer a way out, it reported
    /// that there was none.
    @Test
    func theViewModelNoLongerReportsTheExitUnavailableDuringAClarification() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        #expect(!viewModel.canCancel)

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()

        #expect(viewModel.canCancel)
        // Not "something happens to be true" — the two original terms are still false, so the new
        // term is the only thing carrying the predicate here.
        #expect(!viewModel.isAwaitingApproval)
        #expect(!viewModel.isRunning)

        viewModel.cancelCurrentRun()
        #expect(!viewModel.canCancel)
    }

    /// `canCancel`'s only reader is `CommandCenterRunningIndicator`, and widening the predicate must
    /// not smuggle a second Cancel button onto four Command Center pages.
    ///
    /// All four of that view's call sites are wrapped in `if viewModel.isRunning ||
    /// viewModel.isAwaitingApproval`, so this asserts the condition those sites actually evaluate.
    /// It matters twice: the indicator's label reads "Running: …", which would be a false statement
    /// about a paused task, and the exit belongs on the panel that is asking the question.
    @Test
    func theRunningIndicatorStaysAbsentDuringAClarification() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.clarificationQuestion != nil)

        // The literal gate the four call sites use.
        #expect(!(viewModel.isRunning || viewModel.isAwaitingApproval))
        // While the exit itself is live, on the surfaces that do render the question.
        #expect(viewModel.canCancel)
        #expect(viewModel.hasVisibleWidgetPanel)
    }

    /// **The founder's decision of 2026-08-20**: a `.canceled` row, the same disposition cancelling
    /// at an approval prompt already writes. Read back off disk rather than from published state.
    @Test
    func abandoningAClarificationWritesACanceledTaskHistoryRow() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        // A pause is not terminal, so nothing is written *yet* — the row is the exit's, not the
        // question's.
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)

        viewModel.cancelCurrentRun()

        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.outcomeStatus == .canceled)
        // The text the user actually submitted, preserved across the pause. `start()` clears
        // `command` synchronously the instant it captures it, so without the carry-over this row
        // would have been written from an empty string — or, with no `startedAt` either, not
        // written at all.
        #expect(row.command == "=")
        #expect(row.effectiveTrigger == .manual)
        #expect(row.startedAt <= row.completedAt)
        // And the published list agrees with disk, so the Tasks page shows it without a relaunch.
        #expect(viewModel.taskHistoryRecords.map(\.outcomeStatus) == [.canceled])
    }

    /// "Don't save this task" still suppresses the row, because the exit inherits
    /// `recordTaskHistoryIfTerminal`'s policy check rather than restating it — while the switch
    /// itself goes back off, which is the second half of the ticket's own acceptance criterion.
    @Test
    func abandoningASuppressedClarificationWritesNoRowAndStillPutsTheSwitchBack() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.clarificationQuestion != nil)
        // The guard's positive case: a pause is not settled, so the switch stays on and the run is
        // still suppressed. This is the state SONNY-120 recorded as surviving until relaunch.
        #expect(viewModel.taskRecordingPolicy == .suppressTraces)

        viewModel.cancelCurrentRun()

        #expect(viewModel.taskRecordingPolicy == .record)
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
    }

    /// **The clipboard half, asserted rather than assumed** — the ticket's wording.
    ///
    /// Clipboard history is paused for the whole of a suppressed run and resumed by
    /// `finishRecordingPolicyIfSettled()`, which does two distinct things in order: resynchronise
    /// the monitor so the pause's own copies are dropped rather than recorded on the first poll
    /// back, then restart monitoring from settings. Each reads `changeCount` exactly once, and
    /// nothing else here reads it — so a delta of two is both halves having run, and this is what
    /// fails if the exit is ever rewired around that function.
    ///
    /// What it does not prove, stated rather than implied: the live one-second poll timer never
    /// fires in a test process, so "and it keeps recording a minute later" is a manual-test item.
    /// What is proved here is that the view model restarted the monitor and dropped the pause's
    /// copy, which is the whole of what this path decides.
    @Test
    func abandoningAClarificationResumesClipboardHistoryThroughTheGuardedReset() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        try fixture.clipboardSettingsStore.save(
            ClipboardHistorySettings(noticeDismissed: true, isEnabled: true)
        )
        viewModel.refreshClipboardHistoryNotice()
        #expect(viewModel.clipboardHistoryEnabled)

        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.clarificationQuestion != nil)

        // The user copies something by hand while the unanswered question sits there. Set
        // synchronously immediately before the cancel, so no poll can interleave and the assertions
        // below are about `resynchronize()` rather than about timing.
        fixture.pasteboard.text = "8-digit code from my authenticator"
        fixture.pasteboard.setChangeCount(9)
        let readsBefore = fixture.pasteboard.changeCountReads

        viewModel.cancelCurrentRun()

        #expect(viewModel.taskRecordingPolicy == .record)
        // Read 1: `resynchronize()`. Read 2: the immediate poll inside
        // `startClipboardHistoryMonitoring()`, which is the only thing that polls and only does so
        // when it genuinely restarts the timer.
        #expect(fixture.pasteboard.changeCountReads - readsBefore == 2)
        // Resynchronising is what makes the pause a real pause: the copy made during it is dropped,
        // not recorded late.
        let recorded = try fixture.clipboardHistoryStore.loadAll().map(\.text)
        #expect(!recorded.contains("8-digit code from my authenticator"))
    }

    /// `submitClarification()` sets "Enter an answer before continuing." when Send is pressed on an
    /// empty field, and that error outlives the question it was about. Both surfaces rank `.failure`
    /// above `.result`, so leaving it would show a stale validation nudge exactly where the
    /// cancellation belongs — the user presses the way out and is told to enter an answer.
    @Test
    func abandoningAClarificationClearsTheStaleEmptyAnswerNudge() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()

        // Send pressed with nothing typed — reachable from both panels.
        viewModel.submitClarification()
        #expect(viewModel.errorMessage == "Enter an answer before continuing.")
        // And the question survived it, which is why the error can outlive the pause at all.
        #expect(viewModel.clarificationQuestion != nil)

        viewModel.cancelCurrentRun()

        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.finalSummary == ClarificationPresentation.canceledSummary)
    }

    /// The pause ends rather than resumes, so the boundary it was assessed under dies with it.
    /// A binding surviving into whatever the user types next is the leak the pending-arm lifecycle
    /// and the approval branch's own clears already exist to prevent.
    @Test
    func abandoningAClarificationDropsTheWorkspaceBindingItWasAssessedUnder() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(StoredWorkspace(name: "Alpha", apps: ["Safari"], urls: []))
        viewModel.refreshSavedItems()

        viewModel.command = "="
        viewModel.start(origin: .widget, workspaceBinding: "Alpha", fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.clarificationQuestion != nil)
        #expect(viewModel.boundWorkspaceName == "Alpha")

        viewModel.cancelCurrentRun()

        #expect(viewModel.boundWorkspaceName == nil)
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// **The un-abandoned path is unchanged**, which is the acceptance criterion the exit is most
    /// able to break: the carry-over values it added are the same ones answering relies on.
    @Test
    func answeringAClarificationStillContinuesTheTask() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        let question = try #require(viewModel.clarificationQuestion)

        viewModel.clarificationAnswer = "1 + 1"
        viewModel.submitClarification()
        try await fixture.waitUntilIdle()

        #expect(viewModel.clarificationQuestion == nil)
        // The continuation carries only the Q&A wrapped around the original command, and it is a
        // real re-dispatch rather than the exit's summary.
        #expect(viewModel.lastCommand.contains("Clarification question: \(question)"))
        #expect(viewModel.lastCommand.contains("Clarification answer: 1 + 1"))
        #expect(viewModel.finalSummary != ClarificationPresentation.canceledSummary)
        // The origin survived the pause, which is what `clarificationOrigin` is for — and the exit
        // resets that field, so this fails if the reset ever fires on the answering path.
        #expect(viewModel.activeTaskOrigin == .widget)
    }

    /// The other terminal exit, re-pinned here because this branch moved a value it reads: the
    /// per-task reset now clears `pendingCommandForPriorTaskContext` as well as
    /// `pendingTaskHistoryStartedAt`, and the approval branch is the code that reads the pair.
    @Test
    func cancellingAtAnApprovalPromptStillRecordsItsOwnCanceledRow() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        // A destructive replace: the trigger already exists with different text, so the consequence
        // rule raises a real approval rather than auto-running.
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))

        viewModel.command = "snippet save ;sig = Best, Sonny"
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        #expect(viewModel.isAwaitingApproval)

        viewModel.cancelCurrentRun()

        #expect(viewModel.finalSummary == "Approval canceled. No action was taken.")
        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 1)
        #expect(rows.first?.outcomeStatus == .canceled)
        #expect(rows.first?.command == "snippet save ;sig = Best, Sonny")
    }

    /// **The two surfaces cannot disagree about the exit** —
    /// `.claude/rules/macagent-ui-conventions.md`'s "Approval visibility" rule, which is the one
    /// source of truth for the widget and `CommandCenterAttentionPanel` mirroring each other.
    ///
    /// No SwiftUI inspection harness exists in this repo, so what a view renders is not assertable;
    /// what *is* assertable is that both clarification surfaces route through one view-model entry
    /// point and one copy constant rather than growing a second of either. Two identical literals is
    /// exactly the shape that held until one of them stopped saying anything (SONNY-173).
    ///
    /// Anchored on real code lines rather than line numbers. If either anchor is renamed this fails
    /// loudly with the anchor in the message, which is the intended behaviour: the rename is the
    /// moment to re-check that the mirror still holds.
    ///
    /// **Comments are stripped before any of this is searched** — see `readSource`. The first
    /// version of this test was not, and a mutation battery walked straight through it.
    @Test
    func bothClarificationSurfacesRouteTheirExitThroughOneEntryPointAndOneLabel() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")

        // One label, referenced by name on both surfaces. The widget's control is icon-only, so
        // there it is the VoiceOver name and the tooltip; Command Center shows it.
        #expect(widget.contains("ClarificationPresentation.cancelLabel"))
        #expect(commandCenter.contains("ClarificationPresentation.cancelLabel"))
        #expect(!ClarificationPresentation.cancelLabel.isEmpty)

        // One entry point, inside each surface's own clarification region — not merely somewhere in
        // a 4,000-line file, which both already satisfy via unrelated approval controls.
        let widgetRegion = try MacAgentSource.region(
            of: widget,
            from: "case .clarification(let question):",
            to: "case .permission(let request):"
        )
        #expect(widgetRegion.contains("cancelCurrentRun()"))

        let commandCenterRegion = try MacAgentSource.region(
            of: commandCenter,
            from: "private func clarificationContent(_ question: String) -> some View {",
            to: "private func failureContent(_ message: String) -> some View {"
        )
        // **Paired counts, not `contains` (PR #80 review cycle 2, N1).** A presence check on the
        // cancel token alone is satisfied by a mutant that rewires the button and leaves the old
        // call in a *trailing* line comment — `viewModel.submitClarification() // was
        // viewModel.cancelCurrentRun()`. Trailing comments are deliberately not stripped (see
        // `MacAgentSource`, and the row-C reason it stays that way), so the token is still there and
        // a single-sided count stays at 1. The reviewer's M13 did exactly that and passed the whole
        // suite.
        //
        // Counting *both* sides closes it, because a rewiring is a transfer rather than a deletion:
        // this region holds one cancel — the Cancel button — and two submits, the field's `.onSubmit`
        // and the Send button. Move the cancel to submit and the second number becomes 3 whatever
        // the comment says, because a comment cannot subtract a token it can only add. The widget
        // half below has counted since F2; this is the same technique applied to the half that was
        // still checking presence.
        #expect(MacAgentSource.count(of: "cancelCurrentRun()", inText: commandCenterRegion) == 1)
        #expect(MacAgentSource.count(of: "submitClarification()", inText: commandCenterRegion) == 2)

        // **The widget's own button, and the region above does not reach it (PR #80 review, F2).**
        //
        // `case .clarification` is the *call site* — it proves the panel is handed a closure that
        // cancels. What the panel does with that closure is a file away, and the reviewer's battery
        // proved the gap by rewiring `WidgetClarificationPanel`'s button from `onCancel` to
        // `onSubmit`: all 1425 tests passed, because the call site was untouched and the panel was
        // unscanned. Command Center had no equivalent hole only because its button's action is
        // written inline at the site the region already covered.
        //
        // Counted per token rather than checked for presence, because a swap is symmetrical: after
        // it, `Button(action: onSubmit)` appears twice and `Button(action: onCancel)` not at all, and
        // only a count sees both halves. One each is the whole of what this panel should have.
        let widgetPanel = try MacAgentSource.region(
            of: widget,
            from: "private struct WidgetClarificationPanel: View {",
            to: "private struct WidgetResultPanel: View {"
        )
        #expect(MacAgentSource.count(of: "Button(action: onCancel)", inText: widgetPanel) == 1)
        #expect(MacAgentSource.count(of: "Button(action: onSubmit)", inText: widgetPanel) == 1)
        // And it declares both, so neither can be quietly dropped to make the counts agree.
        #expect(widgetPanel.contains("let onSubmit: () -> Void"))
        #expect(widgetPanel.contains("let onCancel: () -> Void"))
    }

    /// **The founder's own words, pinned as literals once (PR #80 review, F4).**
    ///
    /// Every other assertion in this suite compares against
    /// `ClarificationPresentation.canceledSummary`, which is right — that constant existing is what
    /// stops the two surfaces drifting apart — but it means a mutant that *rewrites the constant*
    /// changes what the product says and passes the whole suite. The reviewer's battery demonstrated
    /// exactly that. The copy is the founder's, given verbatim on 2026-08-20, so it is pinned here
    /// the same way the approval path's is: as the literal, against a run that really produced it.
    ///
    /// Driven rather than declared. Asserting `cancelLabel == "Cancel"` alone would pin the constant
    /// to itself; asserting that a real abandoned run *says* it is what ties the copy to the
    /// behaviour.
    @Test
    func theCancelCopyIsTheFoundersOwnWordsOnBothSurfaces() async throws {
        let fixture = try ClarificationExitFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitUntilIdle()
        viewModel.cancelCurrentRun()

        #expect(viewModel.finalSummary == "Canceled. No action was taken.")
        #expect(ClarificationPresentation.canceledSummary == "Canceled. No action was taken.")
        // Command Center shows this on its button; the widget uses it as the VoiceOver name and the
        // tooltip for its icon-only one.
        #expect(ClarificationPresentation.cancelLabel == "Cancel")
        // The neighbouring exit's wording, asserted beside it because the whole reason this string
        // was chosen over "Never mind" and "Stop" is that Sonny's two exits from a paused run should
        // read as one voice. A change to either alone breaks that, silently, and here.
        #expect(viewModel.finalSummary.hasSuffix("No action was taken."))
    }

    /// **The recording-policy reset depends on nothing else running, and the scheduler guard is what
    /// makes that true (PR #80 review, F1).**
    ///
    /// `finishRecordingPolicyIfSettled()` refuses while `isRunning`. Until this round
    /// `checkScheduledRoutines` guarded only on `isRunning` and `isAwaitingApproval` — both false
    /// during a clarification pause — so a routine could start on top of the paused task, and a user
    /// cancelling their clarification inside that window got no reset at all: "Don't save this task"
    /// stayed on and clipboard history stayed paused until relaunch, which is the exact failure
    /// SONNY-166 exists to end.
    ///
    /// Both halves are asserted, because the positive one alone cannot show the dependency: with a
    /// run in flight the reset really is refused, and that is why the guard is load-bearing rather
    /// than tidy. `aPendingClarificationStopsTheSchedulerFromStartingAnything` pins the guard itself.
    @Test
    func cancellingAClarificationWithNothingElseRunningCompletesTheRecordingPolicyReset() async throws {
        let settled = try ClarificationExitFixture()
        defer { settled.tearDown() }
        settled.viewModel.taskRecordingPolicy = .suppressTraces
        settled.viewModel.command = "="
        settled.viewModel.start(origin: .widget, fromComposer: true)
        try await settled.waitUntilIdle()

        // The precondition the guard now protects, asserted rather than assumed.
        #expect(!settled.viewModel.isRunning)
        settled.viewModel.cancelCurrentRun()
        #expect(settled.viewModel.taskRecordingPolicy == .record)

        // The negative half: the same cancellation, with something running.
        let occupied = try ClarificationExitFixture()
        defer { occupied.tearDown() }
        occupied.viewModel.taskRecordingPolicy = .suppressTraces
        occupied.viewModel.command = "="
        occupied.viewModel.start(origin: .widget, fromComposer: true)
        try await occupied.waitUntilIdle()

        // What a scheduled routine firing during the pause used to do to this state.
        occupied.viewModel.isRunning = true
        occupied.viewModel.cancelCurrentRun()

        // The question is gone — the exit ran — but the reset was refused, so the switch is still on
        // and clipboard history is still paused. Nothing in the app would have put either back.
        #expect(occupied.viewModel.clarificationQuestion == nil)
        #expect(occupied.viewModel.taskRecordingPolicy == .suppressTraces)
    }
}

// MARK: - Fixture

/// Hermetic, and with the two seams this suite actually reads back: the task-history store on disk
/// and a pasteboard reader that counts how often the view model looked at it.
@MainActor
private struct ClarificationExitFixture {
    let viewModel: AgentViewModel
    let root: URL
    let taskHistoryStore: TaskHistoryStore
    let taskPlanDetailStore: TaskPlanDetailStore
    let workspaceStore: WorkspaceStore
    let snippetStore: SnippetStore
    let clipboardSettingsStore: ClipboardHistorySettingsStore
    let clipboardHistoryStore: ClipboardHistoryStore
    let pasteboard: CountingPasteboardReader
    private let userDefaultsSuiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClarificationExitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        userDefaultsSuiteName = "ClarificationExitTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)

        taskHistoryStore = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"))
        taskPlanDetailStore = TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json")
        )
        workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        clipboardSettingsStore = ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        )
        clipboardHistoryStore = ClipboardHistoryStore(
            fileURL: root.appendingPathComponent("clipboard-history.json")
        )
        pasteboard = CountingPasteboardReader()

        viewModel = AgentViewModel(
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore,
            snippetStore: snippetStore,
            recentArtifactStore: RecentArtifactStore(
                fileURL: root.appendingPathComponent("recent-artifacts.json")
            ),
            shortcutCatalog: ClarificationExitEmptyShortcutCatalog(),
            // Hermetic seams (the fakes live in ProductShellTests.swift, same target) — these tests
            // execute real plans, and without these the suite opens real apps and real URLs.
            browserOpener: HermeticBrowserOpener(),
            appOpener: HermeticAppOpener(),
            fileOpener: HermeticFileOpener(),
            finderRevealer: hermeticFinderRevealer,
            mediaOpener: HermeticMediaOpener(),
            runningAppSwitcher: HermeticRunningAppSwitcher(),
            shortcutInvoker: HermeticShortcutInvoker(),
            finderContextReader: HermeticFinderContextReader(),
            documentConverter: HermeticDocumentConverter(),
            zipArchiver: HermeticZipArchiver(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-run-history.json")
            ),
            taskHistoryStore: taskHistoryStore,
            taskPlanDetailStore: taskPlanDetailStore,
            visionSessionJournalStore: VisionSessionJournalStore(
                fileURL: root.appendingPathComponent("vision-sessions.json")
            ),
            clipboardHistorySettingsStore: clipboardSettingsStore,
            approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
            outputLocationStore: OutputLocationStore(
                fileURL: root.appendingPathComponent("output-locations.json"),
                // The same roots this fixture hands the view model, so the store answers
                // "is this an output location" against the folders the run really used.
                whitelist: PathWhitelist(roots: [root])
            ),
            resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: pasteboard,
                store: clipboardHistoryStore,
                settingsStore: clipboardSettingsStore
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
    }

    func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: userDefaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Deadlock backstop, not a timing assertion — the 30 s and the reasoning are
    /// `ProductShellTests`'.
    func waitUntilIdle(timeout: TimeInterval = 30) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while viewModel.isRunning {
            if Date() > deadline {
                Issue.record("View model did not become idle before timeout — treat as genuinely stuck.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

/// Counts what the view model asked, so "monitoring was restarted" is a measurement rather than an
/// inference. `text` and `changeCount` are settable so a test can stage a copy made during a pause.
@MainActor
private final class CountingPasteboardReader: PasteboardReading {
    var text: String?
    private(set) var changeCountReads = 0
    private var storedChangeCount = 0

    var changeCount: Int {
        changeCountReads += 1
        return storedChangeCount
    }

    func setChangeCount(_ value: Int) {
        storedChangeCount = value
    }

    func typeIdentifiers() -> [String] {
        ["public.utf8-plain-text"]
    }

    func stringValue() -> String? {
        text
    }
}

private struct ClarificationExitEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}
