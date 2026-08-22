import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// Row 13's unfinished runs, on the real dispatch path (SONNY-210).
///
/// **Every assertion here drives `start()` and reads the store back off disk.** Calling
/// `beginResumableTask` or `settleResumableTask` directly would pin the seam and say nothing about
/// whether the run reaches it — and the write sites for this store live in three places on two paths,
/// which is the exact shape SONNY-208 spent four rounds on. So each test runs a plan, lets it
/// terminate, and looks at the file.
///
/// **Every "nothing was recorded" assertion ships with a control**, for the reason that assertion is
/// equally true of a writer that never writes at all.
@Suite(.serialized)
@MainActor
struct ResumableTaskRunTests {
    // MARK: - The lifecycle, end to end

    /// A run that finishes leaves nothing behind — with the control that proves the record existed
    /// to be cleared. Without the control this passes for a store nothing ever writes to.
    @Test
    func aRunThatFinishesLeavesNoRecordAndOneThatFailsPartwayKeepsWhatItDid() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // A run that finishes: nothing is left behind.
        try await fixture.run("Write notes and open the page")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(!fixture.viewModel.finalSummary.isEmpty)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // **The control, and it is what makes the line above mean anything**: the identical plan,
        // failing at its second unit, records what its first unit finished. Without it, "nothing was
        // left behind" is equally true of a store nothing ever writes to.
        fixture.browserOpener.failure = BrowserOutage()
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        try await fixture.run("Write notes and open the page")

        #expect(fixture.viewModel.errorMessage != nil)
        let afterFailure = try fixture.resumableTaskStore.loadAll()
        #expect(afterFailure.count == 1)
        // `#require`, not a subscript: an `#expect` on the count records an issue and carries on, so
        // indexing an empty array below would crash the test process instead of failing the test —
        // and a crashed process emits no "Test … failed" line for a mutation battery to attribute.
        // Measured: it turned a killed mutant into an aborted run.
        let failed = try #require(afterFailure.first)
        #expect(failed.command == "Write notes and open the page")
        #expect(failed.completedStepIDs == ["draft"])
        #expect(failed.remainingSteps.map(\.id) == ["url"])
        #expect(failed.stopReason == .failed)
    }

    /// **The flagship: an error at the second unit of two, picked up from the second rather than
    /// restarted.**
    ///
    /// The three things this has to show, and all three are asserted: the resumed run executes only
    /// what was left, the finished unit is *not* done twice, and the record is cleared once the task
    /// really finishes.
    @Test
    func continuingAFailedRunExecutesOnlyWhatWasLeft() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))

        // The offer is published without anybody asking for a refresh — the widget reads this
        // straight off the view model.
        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(offer.remainingSteps.map(\.id) == ["url"])

        fixture.browserOpener.failure = nil
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        // Only the remaining step ran.
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["url"])
        #expect(fixture.browserOpener.opened == ["https://example.com/page", "https://example.com/page"])
        // The draft unit did not run a second time. `CreateLocalDraftCapabilityAdapter` bumps a name
        // that is already taken, so a re-run would leave a second file rather than overwrite the
        // first — which is precisely the cost partial resume exists to avoid.
        let written = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("notes") }
        #expect(written == ["notes.md"])
        // Finished, so the record is gone.
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// A resumed run is dispatched as a *resumed* plan and not as something claiming a stronger
    /// origin. `PreparedPlanSource.directUserAction` would be a false statement about how these steps
    /// came to exist.
    @Test
    func aResumedRunSaysItIsResumingRatherThanClaimingTheUserBuiltThePlan() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let offer = try #require(fixture.viewModel.resumeOffer)

        fixture.browserOpener.failure = nil
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.activeTaskPlanSource == .resumedTask)
    }

    /// The record keeps one identity across a resume, so a task interrupted twice is one entry that
    /// began when the user first asked for it rather than a new one each time.
    @Test
    func aTaskInterruptedTwiceStaysOneRecordWithItsOriginalStartTime() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let first = try #require(try fixture.resumableTaskStore.loadAll().first)

        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        let second = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(second.id == first.id)
        #expect(second.startedAt == first.startedAt)
        // The plan narrowed to what was left, and there is still exactly one record.
        #expect(second.plan.steps.map(\.id) == ["url"])
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
    }

    /// **A checkpoint that cannot be written is a storage notice, never a failed task.**
    ///
    /// CLAUDE.md's write-failure rule, on this store's own door: `errorMessage` means "the thing you
    /// asked for did not happen", and the widget picks `.failure` ahead of `.result` — so a
    /// bookkeeping failure routed there replaces the result of a task that ran and succeeded. That
    /// defect has already arrived through two other doors (PR #89's F4 and SONNY-201). This is a
    /// third door, and the run below really does succeed while its checkpoint really does fail.
    ///
    /// The failure is reached through the one refusal this store has that needs no file-system
    /// surgery: a plan over `maxEncodedPlanBytes`, which is refused rather than trimmed because a
    /// trimmed plan would resume a different task from the one the user started.
    @Test
    func aCheckpointThatCannotBeWrittenIsANoticeAndTheTaskStillSucceeds() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let oversized = AgentPlan(
            summary: "Write a very large note.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Write it.",
                    outputPath: fixture.draftOutput.path,
                    draftTitle: "Notes",
                    draftContent: String(repeating: "x", count: ResumableTaskStore.maxEncodedPlanBytes + 1)
                )
            ]
        )
        try await fixture.run("Write a very large note", plan: oversized)

        // The task itself ran and produced its result.
        #expect(fixture.viewModel.errorMessage == nil, "a bookkeeping failure is not a failed task")
        #expect(!fixture.viewModel.finalSummary.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))

        // And the checkpoint's failure was reported on the storage channel, in write wording.
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("partway through"))
        #expect(!notice.contains("decrypted"), "load-failure wording must not be reused for a write")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
    }

    // MARK: - The pauses

    /// The founder's first shape includes "asks something": a question the user walks away from.
    /// Nothing has executed, so the record carries no finished steps and continuing runs the whole
    /// plan.
    @Test
    func aRunPausedOnAClarificationLeavesARecordWithNothingDone() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try await fixture.run("Do the ambiguous thing", plan: fixture.clarifyingPlan)

        #expect(fixture.viewModel.clarificationQuestion != nil)
        let records = try fixture.resumableTaskStore.loadAll()
        #expect(records.count == 1)
        let paused = try #require(records.first)
        #expect(paused.completedStepIDs.isEmpty)
        #expect(paused.stopReason == .interrupted)
        // And it is not offered while the question is still on screen — that task is live.
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// Cancelling a clarification ends the task, so the record goes with it. Offering to continue
    /// what the user just stopped would be the product arguing with them.
    @Test
    func cancellingAClarificationClearsTheRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try await fixture.run("Do the ambiguous thing", plan: fixture.clarifyingPlan)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)

        fixture.viewModel.cancelCurrentRun()

        #expect(fixture.viewModel.clarificationQuestion == nil)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// The other cancel door, which is a different branch of `cancelCurrentRun` entirely.
    @Test
    func cancellingAtAnApprovalPromptClearsTheRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try await fixture.run("Overwrite the notes", plan: fixture.approvalNeedingPlan)
        #expect(fixture.viewModel.isAwaitingApproval)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)

        fixture.viewModel.cancelCurrentRun()

        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
    }

    // MARK: - The switches, on both paths

    /// "Don't save this task" reaches this store, because it is classified `.trace` — so a suppressed
    /// run raises no offer to carry on with itself. With the control, because the assertion is
    /// otherwise true of a store nothing writes to.
    @Test
    func dontSaveThisTaskLeavesNoRecordAndTheControlWritesOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.browserOpener.failure = BrowserOutage()

        fixture.viewModel.taskRecordingPolicy = .suppressTraces
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // The control: the identical run with the switch off records one.
        #expect(fixture.viewModel.taskRecordingPolicy == .record, "the policy resets at every terminal state")
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-2.md")
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
    }

    /// The per-type Memory switch, and the master switch, each on their own — with the same control.
    @Test
    func memorySwitchedOffLeavesNoRecordAndTheControlWritesOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.browserOpener.failure = BrowserOutage()

        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: false)
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: true)
        fixture.viewModel.setMemoryEnabled(false)
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-2.md")
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // The control, with both switches back on.
        fixture.viewModel.setMemoryEnabled(true)
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-3.md")
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
    }

    /// **A scheduled routine writes no record here, and that is a decision rather than a gap.**
    ///
    /// Two reasons, both on `beginResumableTask`: `performScheduledRun`'s own contract is that nothing
    /// the user reads as "your last task" is touched by a run they never started, and this offer is
    /// exactly such a surface; and a scheduled run prepares a one-step `run_routine` plan, so there
    /// is no unit boundary inside it for a resume to start from — "continue" could only mean "run the
    /// whole routine again", which the next occurrence already does.
    ///
    /// The control is a foreground run in the same fixture, so this is a claim about the path rather
    /// than about the fixture.
    @Test
    func aScheduledRoutineRunLeavesNoRecordWhileAForegroundRunInTheSameFixtureDoes() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try fixture.saveScheduledRoutine()

        fixture.viewModel.checkScheduledRoutines(now: ResumableTaskRunTests.tenAM)
        try await fixture.waitForIdle()

        // The routine really ran — otherwise "no record" says nothing about the scheduled path.
        #expect(fixture.viewModel.scheduledRunNotice?.contains("Morning") == true)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // The control.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
    }

    // MARK: - The offer

    /// Where the offer sits in the widget's precedence: below every state that describes the task the
    /// user is doing now.
    @Test
    func aFailureAndAResultBothOutrankTheOffer() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")

        // A failure is showing, and it is this run's own — the offer must not take its place, because
        // the panel would then say "carry on?" with the reason hidden.
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(WidgetPanelPrecedence.of(fixture.viewModel) == .failure)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        // Clearing the outcome hands the slot to the offer, and the record was there all along.
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(WidgetPanelPrecedence.of(fixture.viewModel) == .resumeOffer)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        // And a result outranks it too: a finished task's answer is never displaced by an older
        // task's question. Written directly, because reaching this state through a second run would
        // settle the very record under test.
        fixture.viewModel.finalSummary = "A later task finished."
        #expect(WidgetPanelPrecedence.of(fixture.viewModel) == .result)
    }

    /// Dismissing is "not now", not a delete: the record survives, stays listed under Memory, and
    /// comes back at the next launch.
    @Test
    func dismissingTheOfferKeepsTheRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)

        fixture.viewModel.dismissResumeOffer()

        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
        #expect(fixture.viewModel.resumableTasks.count == 1)
        #expect(MemoryRowPresentation.row(for: .resumableTasks, viewModel: fixture.viewModel).count == 1)
    }

    /// A record past its idle period is neither offered nor listed. The control is the same record
    /// inside the period.
    @Test
    func anIdleRecordIsNeitherOfferedNorListed() throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let plan = AgentPlan(
            summary: "Open a page.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "url", operation: .openURL, description: "Open.", targetURL: "https://example.com/page")]
        )
        let stale = ResumableTask(
            command: "Something from a month ago",
            plan: plan,
            startedAt: Date(timeIntervalSinceNow: -40 * 24 * 60 * 60),
            updatedAt: Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        )
        try fixture.resumableTaskStore.save(stale)
        fixture.viewModel.refreshResumableTasks()

        #expect(fixture.viewModel.resumableTasks.isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)

        // The control: the same record, still inside the period.
        let recent = ResumableTask(
            command: "Something from yesterday",
            plan: plan,
            startedAt: Date(timeIntervalSinceNow: -24 * 60 * 60),
            updatedAt: Date(timeIntervalSinceNow: -24 * 60 * 60)
        )
        try fixture.resumableTaskStore.save(recent)
        fixture.viewModel.refreshResumableTasks()

        #expect(fixture.viewModel.resumableTasks.map(\.command) == ["Something from yesterday"])
        #expect(fixture.viewModel.resumeOffer?.command == "Something from yesterday")
    }

    // MARK: - The Memory row

    @Test
    func theMemoryRowShowsWhatStoppedAndHowMuchIsLeft() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")

        let row = MemoryRowPresentation.row(for: .resumableTasks, viewModel: fixture.viewModel)
        #expect(row.title == "Unfinished tasks")
        #expect(row.count == 1)
        #expect(row.detailText.hasPrefix("1 saved · newest "))

        let entries = MemoryEntryPresentation.entries(for: .resumableTasks, viewModel: fixture.viewModel)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.title == "Write notes and open the page")
        #expect(entry.detail.hasPrefix("Stopped by an error · 1 of 2 steps left · "))
    }

    @Test
    func deletingOneUnfinishedTaskFromTheMemorySheetRemovesItAndStopsTheOffer() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)

        fixture.viewModel.deleteMemoryEntry(in: .resumableTasks, at: 0)

        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumableTasks.isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(fixture.viewModel.errorMessage == nil, "a successful delete reports nothing")
    }

    @Test
    func deletingTheWholeCategoryEmptiesTheStore() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()

        fixture.viewModel.deleteMemory(in: .resumableTasks)

        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumableTasks.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage?.contains("unfinished tasks") == true)
    }

    // MARK: - Fixture

    static let nineAM: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 0))
            ?? Date(timeIntervalSince1970: 1_700_000_000)
    }()

    static var tenAM: Date { nineAM.addingTimeInterval(3_600) }
}

/// The widget's panel precedence, as a value a test can hold.
///
/// `FloatingWidgetView.state` is private to a SwiftUI view this repository has no way to drive, so
/// this re-expresses the branches the offer had to be slotted between — and reads them off
/// `AgentViewModel` exactly as that view does. It is not a second source of truth: it asserts *order*
/// only, and the properties it reads are the ones the view reads.
enum WidgetPanelPrecedence: Equatable {
    case permission
    case clarification
    case failure
    case working
    case result
    case resumeOffer
    case idle

    @MainActor
    static func of(_ viewModel: AgentViewModel) -> WidgetPanelPrecedence {
        if viewModel.approvalRequest != nil { return .permission }
        if viewModel.clarificationQuestion != nil { return .clarification }
        if viewModel.errorMessage != nil && !viewModel.isRunning { return .failure }
        if viewModel.isRunning { return .working }
        if !viewModel.finalSummary.isEmpty { return .result }
        if viewModel.resumeOffer != nil { return .resumeOffer }
        return .idle
    }
}

private struct BrowserOutage: Error, LocalizedError {
    var errorDescription: String? { "The browser could not be reached." }
}

@MainActor
private final class FailableBrowserOpener: BrowserOpening {
    var failure: (any Error)?
    private(set) var opened: [String] = []

    func open(_ url: URL, using browser: MacApp?) async throws {
        opened.append(url.absoluteString)
        if let failure {
            throw failure
        }
    }
}

@MainActor
private final class ResumableFixturePlanner: Planning {
    var plan: AgentPlan?

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        guard let plan else {
            throw PlannerError.missingAPIKey
        }
        return plan
    }
}

private struct NoShortcutsForResumeTests: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

@MainActor
private final class ResumableFixture {
    let viewModel: AgentViewModel
    let root: URL
    let resumableTaskStore: ResumableTaskStore
    let routineStore: RoutineStore
    let planner: ResumableFixturePlanner
    let browserOpener: FailableBrowserOpener
    let userDefaults: UserDefaults
    let suiteName: String
    /// Where the next draft unit writes. Reassigned between runs in a test that runs the same plan
    /// twice, so the second run's first unit is a fresh write rather than a bumped name.
    var draftOutput: URL

    init(
        viewModel: AgentViewModel,
        root: URL,
        resumableTaskStore: ResumableTaskStore,
        routineStore: RoutineStore,
        planner: ResumableFixturePlanner,
        browserOpener: FailableBrowserOpener,
        userDefaults: UserDefaults,
        suiteName: String,
        draftOutput: URL
    ) {
        self.viewModel = viewModel
        self.root = root
        self.resumableTaskStore = resumableTaskStore
        self.routineStore = routineStore
        self.planner = planner
        self.browserOpener = browserOpener
        self.userDefaults = userDefaults
        self.suiteName = suiteName
        self.draftOutput = draftOutput
    }

    /// Two units: a draft that writes a file, then a page that the browser opener can be made to
    /// fail. Rebuilt per run so `draftOutput` is read at dispatch time.
    var draftThenOpenPlan: AgentPlan {
        AgentPlan(
            summary: "Write notes, then open the page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Write the notes.",
                    outputPath: draftOutput.path,
                    draftTitle: "Notes",
                    draftContent: "Body."
                ),
                AgentStep(
                    id: "url",
                    operation: .openURL,
                    description: "Open the page.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
    }

    var clarifyingPlan: AgentPlan {
        AgentPlan(
            summary: "Ask first.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "ask",
                    operation: .clarify,
                    description: "Ask.",
                    question: "Which folder did you mean?"
                )
            ]
        )
    }

    /// A destructive overwrite of a file that already exists — tier 3 under the consequence rule, so
    /// the run pauses at an approval the test can cancel.
    var approvalNeedingPlan: AgentPlan {
        let occupied = root.appendingPathComponent("already-there.md")
        try? Data("existing".utf8).write(to: occupied, options: .atomic)
        return AgentPlan(
            summary: "Overwrite the notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Overwrite them.",
                    outputPath: occupied.path,
                    draftTitle: "Notes",
                    draftContent: "Replacement."
                )
            ]
        )
    }

    /// Runs `plan`, or the two-unit draft-then-open plan when a test does not name one. The plan is
    /// assigned at dispatch time rather than at fixture build time, so a test that moves
    /// `draftOutput` between runs gets the new path.
    func run(_ command: String, plan: AgentPlan? = nil) async throws {
        planner.plan = plan ?? draftThenOpenPlan
        viewModel.command = command
        viewModel.start(origin: .widget)
        try await waitForIdle()
    }

    /// The 30 seconds is a deadlock backstop, not a timing assertion — the reasoning is on
    /// `VisionSessionRunTests.hangBackstop`, and this target interleaves its suites on one actor.
    func waitForIdle(timeout: TimeInterval = 30) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while viewModel.isRunning {
            if Date() > deadline {
                Issue.record("View model did not become idle before timeout.")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A daily 9am routine, enabled a day earlier so a check at 10am finds an occurrence, and
    /// unattended-trusted so the run is not paused for approval. Same shape
    /// `MemoryCommandCenterTests` uses, so a scheduled run here fires for the reason it does there.
    func saveScheduledRoutine() throws {
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
        schedule.setEnabled(true, now: ResumableTaskRunTests.nineAM.addingTimeInterval(-24 * 60 * 60))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "calc",
                        operation: .calculateUtility,
                        description: "Add them up.",
                        searchQuery: "2 + 2"
                    )
                ],
                schedule: schedule
            )
        )
        viewModel.refreshSavedItems()
    }

    func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeFixture() throws -> ResumableFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResumableTaskRunTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "ResumableTaskRunTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let planner = ResumableFixturePlanner()
    let browserOpener = FailableBrowserOpener()
    let resumableTaskStore = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json")
    )
    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

    let viewModel = AgentViewModel(
        routineStore: routineStore,
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: NoShortcutsForResumeTests(),
        // Hermetic seams, defined in ProductShellTests.swift in this same target — except the browser,
        // which is this suite's own failure switch.
        browserOpener: browserOpener,
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        resumableTaskStore: resumableTaskStore,
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "resume-stub", displayName: "Resume Stub") { _ in
                planner
            }
        ),
        plannerSelection: nil,
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )

    return ResumableFixture(
        viewModel: viewModel,
        root: root,
        resumableTaskStore: resumableTaskStore,
        routineStore: routineStore,
        planner: planner,
        browserOpener: browserOpener,
        userDefaults: userDefaults,
        suiteName: suiteName,
        draftOutput: root.appendingPathComponent("notes.md")
    )
}
