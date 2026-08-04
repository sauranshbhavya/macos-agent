import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// Branch 10 checkpoint 3 — the unattended execution path.
///
/// Routine fixtures use `calculate_utility` steps: tier 0, pure arithmetic, and completely inert,
/// so these tests exercise the real tier-2 outer run-routine gate without launching anything. The
/// scheduler's own date math is covered separately in `RoutineSchedulerTests`.
@Suite
@MainActor
struct ScheduledRoutineRunTests {
    @Test
    func aTrustedRoutineRunsUnattendedAndRecordsItsRunEverywhere() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // It really ran, through the real approval gate — and reports on its own channel rather
        // than through `finalSummary`, which belongs to the user's own last task.
        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("2"))
        #expect(notice.contains("Morning"))
        #expect(notice.contains("ran on schedule"))

        // Streak history advanced...
        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.effectiveRecentRunDates == [fixture.nineAM])
        // ...and the catch-up baseline moved past this occurrence.
        #expect(saved.schedule?.lastRunAt == fixture.nineAM)
    }

    /// The occurrence must not be reconsidered on the next tick. Without the baseline advance the
    /// timer would re-run the same routine every 30 seconds, forever.
    @Test
    func aHandledOccurrenceIsNotRunAgainOnTheNextTick() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        fixture.viewModel.scheduledRunNotice = nil

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(60))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.count == 1)
    }

    /// An enabled schedule without the unattended opt-in cannot run: the outer run-routine gate is
    /// tier 2 and nobody is there to approve it. It skips and says so rather than parking at the
    /// approval — pause-and-notify-at-first-approval was considered for this branch and rejected,
    /// because it reduces scheduling to "tell me it's ready and I'll finish it myself".
    @Test
    func anUntrustedRoutineIsSkippedWithAnExplanationRatherThanParkingAtAnApproval() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: false)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.isAwaitingApproval == false)
        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("not set to run unattended"))
        // Skipped, not run — but still resolved, so it does not retry every tick.
        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.effectiveRecentRunDates.isEmpty)
        #expect(saved.schedule?.lastRunAt == fixture.nineAM)
    }

    /// The laptop-shut-all-day case: past the daily catch-up window, so it reports rather than
    /// firing an unattended run at an hour the user has no reason to expect one.
    @Test
    func anOccurrencePastTheCatchUpWindowReportsInsteadOfRunning() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.nineAM.addingTimeInterval(14 * 60 * 60))
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("did not run"))
        #expect(fixture.viewModel.finalSummary.isEmpty)
        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.effectiveRecentRunDates.isEmpty)
        #expect(saved.schedule?.lastRunAt == fixture.nineAM)
    }

    /// The tier-3+ backstop. `AgentRunner` re-assesses at execute time and requires the approved
    /// tier to be at least the effective tier, so the tier-2 unattended approval cannot satisfy a
    /// routine that escalates — the refusal is structural, not a policy check written in the view
    /// model that could drift out of sync with the real gate.
    @Test
    func aRoutineThatEscalatesToTierThreeIsRefusedByTheApprovalGate() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet ;sig.",
                    searchQuery: ";sig",
                    draftContent: "New text"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("paused its schedule"))
        // SONNY-31: the notice now names the actual cause. It previously said only that the run
        // "needs your explicit approval this time", which told the user nothing about *what* — and
        // said it again on every occurrence, forever.
        #expect(notice.contains("Snippet trigger ;sig already exists and would be replaced."))
        // The tier-3 action really did not happen.
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "Old text")
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)

        // ...and the schedule is off, with the reason persisted for the row and detail view.
        let schedule = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(schedule.isEnabled == false)
        #expect(schedule.pausedReason == "Snippet trigger ;sig already exists and would be replaced.")
    }

    /// SONNY-31, H1, end to end through the real scheduler and the real gate — the headline
    /// failure this ticket exists for. A routine that saves a snippet used to run exactly once:
    /// run one created the trigger, and from run two on the plan assessed tier 3, which a
    /// `.approved(.tier2)` unattended run structurally cannot satisfy.
    @Test
    func aScheduledSnippetRoutineStillRunsOnItsSecondOccurrence() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet ;sig.",
                    searchQuery: ";sig",
                    draftContent: "Best, Sonny"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        #expect(try #require(fixture.viewModel.scheduledRunNotice).contains("ran on schedule"))
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "Best, Sonny")
        fixture.viewModel.scheduledRunNotice = nil

        // Second occurrence, one day later — the run that used to be refused forever.
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(24 * 60 * 60))
        try await fixture.waitForIdle()

        #expect(try #require(fixture.viewModel.scheduledRunNotice).contains("ran on schedule"))
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.count == 2)
        // Still enabled, nothing paused: the whole point is that there was nothing to refuse.
        let schedule = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(schedule.isEnabled)
        #expect(schedule.pausedReason == nil)
    }

    /// The other half of the pause: silence afterwards. Before SONNY-31 the schedule stayed on, so
    /// every later occurrence produced the same causeless notice — one notification per day for a
    /// routine that could never run. "Exactly one" is not enforced by a counter; it falls out of
    /// there being no second attempt to report.
    @Test
    func aPausedScheduleMakesNoFurtherAttemptsAndPostsNoFurtherNotices() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet ;sig.",
                    searchQuery: ";sig",
                    draftContent: "New text"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.scheduledRunNotice != nil)
        fixture.viewModel.scheduledRunNotice = nil

        // Two later ticks, one of them a full day on — an occurrence that would have been due.
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(60))
        try await fixture.waitForIdle()
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(24 * 60 * 60))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "Old text")
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    /// Resuming is the existing row toggle, and it must clear the pause *and* re-anchor. Without
    /// the re-anchor, switching a routine paused a fortnight ago back on would read every day in
    /// between as a missed occurrence.
    @Test
    func togglingAPausedScheduleBackOnClearsThePauseAndReAnchorsInsteadOfFiringACatchUp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet ;sig.",
                    searchQuery: ";sig",
                    draftContent: "New text"
                )
            ]
        )
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        fixture.viewModel.scheduledRunNotice = nil

        let paused = try fixture.routineStore.routine(named: "Morning")
        #expect(paused.schedule?.pausedReason != nil)
        fixture.viewModel.setRoutineScheduleEnabled(paused, to: true)

        let resumed = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(resumed.isEnabled)
        #expect(resumed.pausedReason == nil)

        // Re-anchored to the moment of resuming, so nothing between the pause and now is
        // outstanding: a tick right after resuming must not fire a catch-up.
        fixture.viewModel.checkScheduledRoutines(now: Date())
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    /// The Routines row's needs-attention state, asserted through the presentation struct rather
    /// than the view — this repo has no SwiftUI inspection harness, which is why presentation
    /// logic lives in testable structs (the `AgentActivityPresentation` precedent).
    @Test
    func aPausedRoutineRowShowsNeedsAttentionWhileAUserDisabledOneDoesNot() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
        schedule.setEnabled(true, now: now.addingTimeInterval(-86_400))
        let enabled = StoredRoutine(name: "Morning", steps: [], schedule: schedule)

        var pausedSchedule = schedule
        pausedSchedule.pause(reason: "Snippet trigger ;sig already exists and would be replaced.")
        let paused = StoredRoutine(name: "Morning", steps: [], schedule: pausedSchedule)

        var userDisabledSchedule = schedule
        userDisabledSchedule.setEnabled(false, now: now)
        let userDisabled = StoredRoutine(name: "Morning", steps: [], schedule: userDisabledSchedule)

        #expect(RoutineRowPresentation(routine: paused, now: now).isPaused)
        // A schedule the user switched off themselves is not "needs attention" — it is what they
        // asked for, and flagging it would make the real ones unfindable.
        #expect(RoutineRowPresentation(routine: userDisabled, now: now).isPaused == false)
        #expect(RoutineRowPresentation(routine: enabled, now: now).isPaused == false)
        // The paused row's caption takes a slot that is empty anyway: `nextRunText` is nil for any
        // disabled schedule, so nothing the wireframe specifies is displaced.
        #expect(RoutineRowPresentation(routine: paused, now: now).nextRunText == nil)
        #expect(RoutineRowPresentation(routine: enabled, now: now).nextRunText != nil)
    }

    /// A scheduled run must never interrupt or race a task already in flight.
    @Test
    func nothingFiresWhileATaskIsAlreadyRunning() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        fixture.viewModel.isRunning = true

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)

        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.lastRunAt == fixture.enabledAt)
    }

    /// The race `performScheduledRun`'s missing-routine comment describes: `checkScheduledRoutines`
    /// reads the routine, decides `.due`, and spawns the run as a `Task` — a real suspension point
    /// before the run re-resolves the routine *by name*. Deleting it in that window must fail
    /// closed through the same missing-target clarification a planner-invented name takes, not
    /// crash, stall, or partially run.
    ///
    /// The delete below is synchronous, before any `await` — both this test and the spawned task
    /// body run on the main actor, so the deletion is guaranteed to land before the task body's
    /// first line, hitting the window every time rather than sometimes.
    @Test
    func aRoutineDeletedBetweenScheduleFireAndTaskStartBecomesAClarificationInstead() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try fixture.routineStore.delete(routineNamed: "Morning")
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("needed to ask something first"))
        // Failed closed: nothing ran, nothing recorded, nothing left in flight.
        #expect(fixture.viewModel.isRunning == false)
        #expect(fixture.viewModel.isAwaitingApproval == false)
        #expect(try fixture.routineStore.loadAll().isEmpty)
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
    }

    /// Scheduled runs are recorded in task history — a scheduled run that failed has to be
    /// debuggable — but tagged, so Insights can tell them apart from what the user did.
    @Test
    func aScheduledRunIsRecordedInHistoryTaggedAsScheduled() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.effectiveTrigger == .scheduled)
    }

    /// The widget gates its working/result panel on `.widget` origin, so a scheduled run shows no
    /// progress panel there — correct, since nothing about it needs a decision. The states that do
    /// need a human stay ungated, which is what makes an unattended approval reachable at all.
    @Test
    func aScheduledRunDoesNotRaiseTheWidgetsResultPanelButAFailureStillWould() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // Origin is restored once the run finishes, so the user's own prior result — whatever it
        // was — keeps whatever widget visibility it had.
        #expect(fixture.viewModel.activeTaskOrigin == .commandCenter)
        #expect(fixture.viewModel.finalSummary.isEmpty)
        #expect(fixture.viewModel.hasVisibleWidgetPanel == false)

        fixture.viewModel.errorMessage = "Something needs attention."
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
    }

    // MARK: - Isolation from the user's own last task

    /// The follow-up-correction feature (`PriorTaskContext`) is explicitly about correcting *your
    /// own* last action. If a scheduled run became its target, this sequence would silently
    /// redirect the correction: the user finishes a task, a routine fires a minute later, and
    /// "use ~/Downloads instead" lands on the routine — with nothing in the phrasing to reveal
    /// that a background event moved the target.
    @Test
    func aScheduledRunDoesNotBecomeTheFollowUpCorrectionTarget() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.command = "= 2 + 3"
        fixture.viewModel.start()
        try await fixture.waitForIdle()
        let userContext = fixture.viewModel.priorTaskContext

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // Still the user's own task, unchanged by the background run.
        #expect(fixture.viewModel.priorTaskContext == userContext)
        #expect(fixture.viewModel.priorTaskContext?.previousCommand == "= 2 + 3")
    }

    /// `lastCommand` moves with `priorTaskContext` on purpose — it also feeds
    /// `hasRetryableCommand` and `retryLastCommand()`, so a scheduled run claiming it would point
    /// the widget's Retry button at a routine the user never ran.
    @Test
    func aScheduledRunDoesNotBecomeTheRetryTarget() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.command = "= 2 + 3"
        fixture.viewModel.start()
        try await fixture.waitForIdle()

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.runningCommandDisplayText == "= 2 + 3")
        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.finalSummary.contains("5"))
    }

    /// A background event must not erase something the user is still looking at. An unresolved
    /// error or an unacted-on result vanishing because a routine happened to fire is a worse
    /// failure than a scheduled run being under-reported — the user did nothing, so nothing they
    /// were looking at should change.
    @Test
    func aScheduledRunDoesNotWipeTheUsersUnresolvedErrorOrResult() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        fixture.viewModel.errorMessage = "Your last task failed."

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage == "Your last task failed.")
        #expect(fixture.viewModel.scheduledRunNotice != nil)
    }

    /// The notice persists across the user's next task rather than being cleared by it. The whole
    /// premise is that they were not watching when it happened, so their next action is the moment
    /// they are most likely to be about to read it — silently clearing it then would defeat the
    /// feature. It has an explicit Dismiss control instead, same as the storage notice.
    @Test
    func theScheduledRunNoticeSurvivesTheUsersNextTaskUntilDismissed() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        let notice = try #require(fixture.viewModel.scheduledRunNotice)

        fixture.viewModel.command = "= 2 + 3"
        fixture.viewModel.start()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.scheduledRunNotice == notice)
        #expect(fixture.viewModel.finalSummary.contains("5"))

        fixture.viewModel.scheduledRunNotice = nil
        #expect(fixture.viewModel.scheduledRunNotice == nil)
    }

    // MARK: - The Routines row controls

    /// Flipping the row's toggle on must re-anchor the catch-up baseline, not just set a flag.
    /// Turning a 9am routine on at 3pm and having it immediately fire a catch-up run would make
    /// the act of enabling scheduling itself the trigger for an unattended action.
    @Test
    func enablingTheRowToggleReAnchorsTheBaselineInsteadOfFiringACatchUp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        let threePM = fixture.nineAM.addingTimeInterval(6 * 60 * 60)
        let routine = try fixture.routineStore.routine(named: "Morning")
        fixture.viewModel.setRoutineScheduleEnabled(routine, to: false)

        let disabled = try fixture.routineStore.routine(named: "Morning")
        fixture.viewModel.setRoutineScheduleEnabled(disabled, to: true)

        // Re-anchored to roughly now, so this morning's 09:00 no longer looks outstanding.
        let reEnabled = try #require(try fixture.routineStore.routine(named: "Morning").schedule?.lastRunAt)
        #expect(reEnabled > fixture.nineAM)

        fixture.viewModel.checkScheduledRoutines(now: threePM)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    /// The opt-in warns for a routine that could never run unattended, and warns rather than
    /// blocking — refusing the toggle would be the save-time tier gating this branch rejected.
    @Test
    func turningOnUnattendedTrustWarnsButStillAppliesForATierThreeRoutine() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Old text"))
        try fixture.saveRoutine(
            unattendedTrusted: false,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet ;sig.",
                    searchQuery: ";sig",
                    draftContent: "New text"
                )
            ]
        )
        let routine = try fixture.routineStore.routine(named: "Morning")

        let advisory = fixture.viewModel.setRoutineUnattendedTrust(routine, to: true)

        let warning = try #require(advisory)
        #expect(warning.contains("Morning"))
        // Warned, not blocked — the setting really did apply.
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.unattendedTrusted == true)
    }

    @Test
    func turningOnUnattendedTrustForAnOrdinaryRoutineWarnsAboutNothing() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: false)
        let routine = try fixture.routineStore.routine(named: "Morning")

        #expect(fixture.viewModel.setRoutineUnattendedTrust(routine, to: true) == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.unattendedTrusted == true)
    }

    // MARK: - Schedule authoring

    /// The whole point of checkpoint 5: before it, nothing in the app could bring a schedule into
    /// existence, so everything else on this branch was unreachable.
    @Test
    func creatingAScheduleRoundTripsThroughTheStore() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))
        let routine = try fixture.routineStore.routine(named: "Morning")
        #expect(routine.schedule == nil)

        fixture.viewModel.setRoutineSchedule(
            routine,
            to: .newlyCreated(cadence: .weekly, hour: 7, minute: 30, weekday: 2, now: fixture.tenAM)
        )

        let saved = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(saved.cadence == .weekly)
        #expect(saved.hour == 7)
        #expect(saved.minute == 30)
        #expect(saved.weekday == 2)
        #expect(saved.isEnabled)
        #expect(fixture.viewModel.savedRoutines.first?.schedule == saved)
    }

    /// The correctness trap, proven end to end through the real creation path rather than only at
    /// the factory: a schedule created in the afternoon must not treat that morning's occurrence
    /// as outstanding and fire an unattended run seconds after being made.
    @Test
    func aScheduleCreatedAfterItsRunTimeDoesNotImmediatelyFire() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))
        let routine = try fixture.routineStore.routine(named: "Morning")
        let threePM = fixture.nineAM.addingTimeInterval(6 * 60 * 60)

        fixture.viewModel.setRoutineSchedule(
            routine,
            to: .newlyCreated(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true, now: threePM)
        )

        fixture.viewModel.checkScheduledRoutines(now: threePM)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    @Test
    func removingAScheduleClearsItAndLeavesTheRoutineIntact() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        let routine = try fixture.routineStore.routine(named: "Morning")

        fixture.viewModel.setRoutineSchedule(routine, to: nil)

        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.schedule == nil)
        #expect(saved.steps.isEmpty == false)
    }

    /// The two modify-only methods must still work on a schedule that came from the new creation
    /// path, not just on one built in a test fixture.
    @Test
    func theEnabledAndTrustTogglesStillWorkOnACreatedSchedule() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))
        fixture.viewModel.setRoutineSchedule(
            try fixture.routineStore.routine(named: "Morning"),
            to: .newlyCreated(cadence: .daily, hour: 9, minute: 0, now: fixture.tenAM)
        )

        fixture.viewModel.setRoutineScheduleEnabled(try fixture.routineStore.routine(named: "Morning"), to: false)
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.isEnabled == false)

        #expect(
            fixture.viewModel.setRoutineUnattendedTrust(
                try fixture.routineStore.routine(named: "Morning"),
                to: true
            ) == nil
        )
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.unattendedTrusted == true)
    }

    /// The UI is built so these cannot be produced — weekday is only offered for weekly, day only
    /// for monthly, both bounded to the accepted range. `validate()` stays the backstop, and this
    /// pins that it still refuses what the UI is structurally unable to send.
    @Test
    func validationStillRejectsWhatTheAuthoringUIIsUnableToProduce() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))

        #expect(throws: AutomationStoreError.invalidSchedule("A weekly routine needs a weekday.")) {
            try fixture.routineStore.setSchedule(
                routineNamed: "Morning",
                to: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0)
            )
        }
        #expect(throws: AutomationStoreError.invalidSchedule("Run time must be a real time of day.")) {
            try fixture.routineStore.setSchedule(
                routineNamed: "Morning",
                to: RoutineSchedule(cadence: .daily, hour: 25, minute: 0)
            )
        }
        #expect(try fixture.routineStore.routine(named: "Morning").schedule == nil)
    }

    // MARK: - Committing a schedule draft

    /// Editing re-anchors the catch-up baseline, and it has to. Moving a daily routine from 9am to
    /// 7am during the afternoon would otherwise leave yesterday's baseline in place, making *today's*
    /// 07:00 look outstanding — firing a run, or reporting a missed one, for a time the user just
    /// set. Same hazard as creation, reached through a different door.
    @Test
    func committingAnEditedTimeReAnchorsTheBaselineInsteadOfLeavingAStaleOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        let threePM = fixture.nineAM.addingTimeInterval(6 * 60 * 60)

        fixture.viewModel.commitScheduleDraft(
            for: try fixture.routineStore.routine(named: "Morning"),
            cadence: .daily,
            hour: 7,
            minute: 0,
            weekday: 2,
            dayOfMonth: 1,
            now: threePM
        )

        let saved = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(saved.hour == 7)
        #expect(saved.lastRunAt == threePM)

        // Nothing outstanding for the 07:00 that already passed today.
        fixture.viewModel.checkScheduledRoutines(now: threePM)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    /// Neither flag is part of the draft, so committing an edit must carry both across rather than
    /// silently resetting them — losing an unattended opt-in by changing the run time would be a
    /// safety decision undone by an unrelated edit.
    @Test
    func committingAnEditPreservesEnabledStateAndUnattendedTrust() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        fixture.viewModel.setRoutineScheduleEnabled(try fixture.routineStore.routine(named: "Morning"), to: false)

        fixture.viewModel.commitScheduleDraft(
            for: try fixture.routineStore.routine(named: "Morning"),
            cadence: .weekly,
            hour: 8,
            minute: 30,
            weekday: 3,
            dayOfMonth: 1,
            now: fixture.tenAM
        )

        let saved = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(saved.cadence == .weekly)
        #expect(saved.weekday == 3)
        #expect(saved.unattendedTrusted)
        #expect(saved.isEnabled == false)
        // Disabled, so `newlyCreated` leaves no baseline — enabling it later is what anchors it.
        #expect(saved.lastRunAt == nil)
    }

    /// Committing a draft for a routine with no schedule creates one, enabled and untrusted.
    @Test
    func committingADraftForAnUnscheduledRoutineCreatesTheSchedule() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))

        fixture.viewModel.commitScheduleDraft(
            for: try fixture.routineStore.routine(named: "Morning"),
            cadence: .monthly,
            hour: 9,
            minute: 0,
            weekday: 2,
            dayOfMonth: 31,
            now: fixture.tenAM
        )

        let saved = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(saved.cadence == .monthly)
        #expect(saved.dayOfMonth == 31)
        #expect(saved.isEnabled)
        #expect(saved.unattendedTrusted == false)
        #expect(saved.lastRunAt == fixture.tenAM)
    }

    /// Both fields are committed regardless of cadence, so switching back and forth in the draft
    /// does not silently discard a choice the user already made.
    @Test
    func committingCarriesBothCadenceFieldsSoSwitchingBackKeepsTheEarlierChoice() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))

        fixture.viewModel.commitScheduleDraft(
            for: try fixture.routineStore.routine(named: "Morning"),
            cadence: .daily,
            hour: 9,
            minute: 0,
            weekday: 6,
            dayOfMonth: 20,
            now: fixture.tenAM
        )

        let saved = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(saved.cadence == .daily)
        #expect(saved.weekday == 6)
        #expect(saved.dayOfMonth == 20)
    }

    // MARK: - Fixture

    private func makeFixture() throws -> Fixture {
        try Fixture()
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let viewModel: AgentViewModel
        let routineStore: RoutineStore
        let snippetStore: SnippetStore
        let taskHistoryStore: TaskHistoryStore
        let nineAM: Date
        let tenAM: Date
        let enabledAt: Date

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScheduledRoutineRunTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
            nineAM = try #require(
                calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 0))
            )
            tenAM = nineAM.addingTimeInterval(3_600)
            enabledAt = nineAM.addingTimeInterval(-24 * 60 * 60)

            routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
            snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
            taskHistoryStore = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"))

            let suiteName = "ScheduledRoutineRunTests-\(UUID().uuidString)"
            let userDefaults = try #require(UserDefaults(suiteName: suiteName))
            userDefaults.removePersistentDomain(forName: suiteName)

            viewModel = AgentViewModel(
                routineStore: routineStore,
                workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
                snippetStore: snippetStore,
                recentArtifactStore: RecentArtifactStore(
                    fileURL: root.appendingPathComponent("recent-artifacts.json")
                ),
                shortcutCatalog: EmptyShortcutCatalog(),
                shortcutRunHistoryStore: ShortcutRunHistoryStore(
                    fileURL: root.appendingPathComponent("shortcuts-run-history.json")
                ),
                taskHistoryStore: taskHistoryStore,
                clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                ),
                clipboardHistoryMonitor: ClipboardHistoryMonitor(
                    reader: FakePasteboardReader(),
                    store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
                    settingsStore: ClipboardHistorySettingsStore(
                        fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                    )
                ),
                localDataDeletionService: LocalDataDeletionService(fileURLs: []),
                priorTaskContextStore: PriorTaskContextStore(),
                taskUsageRecorder: TaskUsageRecorder(),
                userDefaults: userDefaults
            )
        }

        /// Tier 0, pure arithmetic, touches nothing outside the process.
        var inertStep: AgentStep {
            AgentStep(
                id: "calc",
                operation: .calculateUtility,
                description: "Calculate 1 + 1.",
                searchQuery: "1 + 1"
            )
        }

        func saveRoutine(unattendedTrusted: Bool, steps: [AgentStep]? = nil) throws {
            var schedule = RoutineSchedule(
                cadence: .daily,
                hour: 9,
                minute: 0,
                unattendedTrusted: unattendedTrusted
            )
            schedule.setEnabled(true, now: enabledAt)
            try routineStore.save(
                StoredRoutine(
                    name: "Morning",
                    steps: steps ?? [
                        AgentStep(
                            id: "calc",
                            operation: .calculateUtility,
                            description: "Calculate 1 + 1.",
                            searchQuery: "1 + 1"
                        )
                    ],
                    schedule: schedule
                )
            )
        }

        func waitForIdle() async throws {
            while viewModel.isRunning {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}
