import Combine
import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgent
// `@testable` since SONNY-94: the belt's test needs `RoutineStore.saveBypassingStepValidation`,
// the module-internal sanctioned door for writing a routine `save` would refuse. Nothing else
// in this file depends on internal access.
@testable import MacAgentCore

/// Branch 10 checkpoint 3 — the unattended execution path.
///
/// Routine fixtures use `calculate_utility` steps: tier 0, pure arithmetic, and completely inert,
/// so these tests exercise the real tier-2 outer run-routine gate without launching anything. The
/// scheduler's own date math is covered separately in `RoutineSchedulerTests`.
@Suite
@MainActor
struct ScheduledRoutineRunTests {
    /// AC5 (SONNY-38) — a scheduled run's assessment is unaffected by any saved workspace.
    ///
    /// Scheduled runs pass `.unscoped` on purpose rather than by omission: a stored routine can
    /// never name a workspace (`SaveRoutineCapabilityAdapter.validateRoutineSteps` rejects both
    /// `create_workspace` and `open_workspace` as routine steps), there is no command text a user
    /// typed, and no dispatch named one — so there is no binding available to resolve. This pins
    /// that a workspace sitting in the store cannot change that: it runs identically, with no scope
    /// escalation anywhere in its trace.
    @Test
    func aScheduledRunIsUnaffectedByAnySavedWorkspace() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // A workspace narrow enough that what this routine touches falls outside it — and a routine
        // step that actually *carries* a scoped resource. The default fixture routine is a single
        // `calculate_utility` step, which `PlanScopedResources` groups with the operations
        // contributing no resources at all, so a scoped assessment of it is identical to an unscoped
        // one and the assertion below could not fail whatever the scheduled path did.
        try WorkspaceStore(fileURL: fixture.root.appendingPathComponent("workspaces.json"))
            .save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"]))
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "foreign",
                    operation: .openURL,
                    description: "Open a domain the workspace does not list.",
                    targetURL: "https://example.com/page"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("ran on schedule"))
        // No scope escalation reached the trace, and none reached the notice.
        #expect(fixture.viewModel.logStore.events.allSatisfy { !$0.message.contains("is not part of the") })
        #expect(!notice.contains("is not part of the"))
        // And the run left no binding behind on the shared view model.
        #expect(fixture.viewModel.activeTaskScope == .unscoped)
    }

    // MARK: - Unattended vision: never (SONNY-94, the belt)

    /// **The belt: an explicit refusal that names the reason.**
    ///
    /// The other two layers would each stop this on their own — a routine cannot legally carry a
    /// vision step, and the `.approved(.tier2)` ceiling cannot cover a tier-3 assessment — which is
    /// exactly why this test has to reach past them with the sanctioned bypass to exercise the belt
    /// at all. What the belt adds is *legibility*: the ceiling produces "approval required" and the
    /// store produces "unsafe routine step", and neither tells a user that screen control is a thing
    /// Sonny will not do while they are away.
    @Test
    func aScheduledRoutineCarryingAVisionStepIsRefusedAndItsScheduleIsPaused() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutineBypassingValidation(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "vision",
                    operation: .visionSession,
                    description: "Control Safari",
                    appName: "Safari",
                    visionGoal: "do a thing"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        // The reason is named, in the user's terms.
        #expect(notice.contains("control an app on screen"))
        #expect(notice.contains("while you are here"))
        // SONNY-31's notify-and-pause semantics, not a silent skip that repeats forever: the
        // schedule is off, so the user hears this once rather than every occurrence.
        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.schedule?.isEnabled == false)
        // And nothing ran: no approval was raised for nobody to answer, and no session started.
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.visionSessionProgress == nil)
    }

    /// **The trust toggle is not a grant for screen control**, and neither setting of it runs one.
    ///
    /// The two settings refuse for *different* reasons and that is worth pinning rather than
    /// flattening: untrusted is refused before the run is even attempted (it is not set to run
    /// unattended at all), trusted gets as far as the belt and is refused by it. What matters is
    /// that no setting of this toggle reaches a session — a future reading of "trusted" as "run
    /// anything" fails on the second half.
    @Test
    func neitherSettingOfTheTrustToggleUnbarsScheduledScreenControl() async throws {
        let visionStep = AgentStep(
            id: "vision",
            operation: .visionSession,
            description: "Control Safari",
            appName: "Safari",
            visionGoal: "do a thing"
        )

        let untrusted = try makeFixture()
        defer { untrusted.cleanUp() }
        try untrusted.saveRoutineBypassingValidation(unattendedTrusted: false, steps: [visionStep])
        untrusted.viewModel.checkScheduledRoutines(now: untrusted.tenAM)
        try await untrusted.waitForIdle()
        let untrustedNotice = try #require(untrusted.viewModel.scheduledRunNotice)
        #expect(untrustedNotice.contains("not set to run unattended"))
        #expect(untrusted.viewModel.visionSessionProgress == nil)

        let trusted = try makeFixture()
        defer { trusted.cleanUp() }
        try trusted.saveRoutineBypassingValidation(unattendedTrusted: true, steps: [visionStep])
        trusted.viewModel.checkScheduledRoutines(now: trusted.tenAM)
        try await trusted.waitForIdle()
        let trustedNotice = try #require(trusted.viewModel.scheduledRunNotice)
        #expect(trustedNotice.contains("control an app on screen"))
        #expect(trusted.viewModel.visionSessionProgress == nil)
    }

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

    /// **A scheduled run stores what it produced and the plan it ran** (row E, SONNY-147).
    ///
    /// This path dropped the result until now while the very next line used `result.summary` for its
    /// notice, so it is the write path most likely to be missed — and it is a separate function from
    /// the manual one, not a shared helper, so a manual-path test says nothing about it.
    @Test
    func aScheduledRunStoresWhatItProducedAndThePlanItRan() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.trigger == .scheduled)
        #expect(record.outcomeStatus == .completed)
        let result = try #require(record.result)
        #expect(result.text.contains("Ran routine Morning."))
        #expect(result.text.contains("2"))
        #expect(result.provenance == .codeAuthored)
        // The notice the user sees and the row both carry the same text.
        #expect(try #require(fixture.viewModel.scheduledRunNotice).contains(result.text))

        let taskID = try #require(record.id)
        let detail = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: taskID))
        // The one-step `run_routine` plan this path prepares, which is what a follow-up on a
        // scheduled run gets to correct against.
        #expect(detail.steps.map(\.operation) == [.runRoutine])
        #expect(detail.completedAt == record.completedAt)
    }

    /// A scheduled run that fails keeps the failure text rather than an empty field, and stores no
    /// plan — that catch is reachable before `prepare` returns as well as after it.
    @Test
    func aFailedScheduledRunStoresItsFailureTextAndNoPlan() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // A calculator step the calculator cannot evaluate: the run prepares, executes and throws.
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "calc",
                    operation: .calculateUtility,
                    description: "Calculate apples.",
                    searchQuery: "apples"
                )
            ]
        )

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .failed)
        let result = try #require(record.result)
        #expect(!result.text.isEmpty)
        #expect(try #require(fixture.viewModel.scheduledRunNotice).contains(result.text))
        #expect(try fixture.taskPlanDetailStore.loadAll().isEmpty)
    }

    /// **The scheduled path's own plan-less eviction branch** (PR #89 review, M6s), which is the
    /// mirror of `ProductShellTests.aRowWithNoPlanStillDropsThePlanOfTheRowItEvicted` and needs its
    /// own test because this is a separate function with its own copy of the branch — not a shared
    /// helper. `recordScheduledTaskHistory` deliberately does not reuse `recordTaskPlanDetail`,
    /// because that one asks the recording policy and a scheduled run is never suppressed.
    ///
    /// A failing scheduled run writes a row and no plan, so it takes the `else` branch. At a cap of
    /// two, its row displaces the oldest — and the oldest's plan has to go with it, or the plan
    /// store outlives the rows it hangs off and the founder's "same cap, same eviction" condition
    /// stops holding on exactly the runs that fail.
    @Test
    func aFailedScheduledRunWithNoPlanStillDropsThePlanOfTheRowItEvicted() async throws {
        let fixture = try makeFixture(taskHistoryMaxItems: 2)
        defer { fixture.cleanUp() }
        // Two rows already at the cap, each with a plan, seeded through the real stores.
        var seededIDs: [String] = []
        for index in 0..<2 {
            let record = CompletedTaskRecord(
                command: "seeded \(index)",
                startedAt: Date(timeInterval: Double(index), since: fixture.nineAM),
                completedAt: Date(timeInterval: Double(index) + 1, since: fixture.nineAM),
                outcomeStatus: .completed,
                trigger: .scheduled,
                result: .codeAuthored("done \(index)")
            )
            let id = try #require(record.id)
            seededIDs.append(id)
            try fixture.taskHistoryStore.record(record)
            try fixture.taskPlanDetailStore.save(
                StoredTaskPlanDetail(
                    taskID: id,
                    completedAt: record.completedAt,
                    planSummary: "plan \(index)",
                    steps: []
                )
            )
        }
        #expect(try fixture.taskPlanDetailStore.loadAll().count == 2)

        // A scheduled routine whose only step the calculator cannot evaluate: it runs, it throws,
        // and its history row is written with no plan.
        try fixture.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "calc",
                    operation: .calculateUtility,
                    description: "Calculate apples.",
                    searchQuery: "apples"
                )
            ]
        )
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 2, "the cap held")
        #expect(rows.last?.outcomeStatus == .failed)
        let failedID = try #require(rows.last?.id)
        // It really stored no plan, or this test drives the other branch.
        #expect(try fixture.taskPlanDetailStore.detail(forTaskID: failedID) == nil)
        // And the displaced row's plan went with it.
        #expect(try fixture.taskPlanDetailStore.detail(forTaskID: seededIDs[0]) == nil)
        #expect(try fixture.taskPlanDetailStore.loadAll().map(\.taskID) == [seededIDs[1]])
    }

    /// **A plan write that fails after the row landed says so, and does not swallow the row** (PR
    /// #89 review).
    ///
    /// One `do` covered both writes, so a failure in the second reported "could not save this
    /// scheduled run to task history" — false, the row was on disk — and skipped
    /// `refreshTaskHistory()`, leaving the row that *did* land missing from the published list until
    /// something else refreshed it. Two failures with different consequences and different
    /// recoveries need two messages.
    @Test(.requiresUnprivilegedProcess)
    func aPlanWriteFailureKeepsTheScheduledRowAndSaysWhatActuallyFailed() async throws {
        let planRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScheduledPlanFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: planRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planRoot.path)
            try? FileManager.default.removeItem(at: planRoot)
        }
        let fixture = try makeFixture(planDetailRoot: planRoot)
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        // Read-only: task history sits elsewhere and stays writable, so only the plan write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: planRoot.path)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // The row landed, and it kept everything it was supposed to.
        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.trigger == .scheduled)
        #expect(record.result?.text.contains("Ran routine Morning.") == true)
        // The published list agrees with the file rather than being one refresh behind.
        #expect(fixture.viewModel.taskHistoryRecords.map(\.id) == [record.id])
        // The message names what actually failed, and it is write wording rather than the
        // load-failure banner's "could not be decrypted or decoded".
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not save what this scheduled run planned: "))
        #expect(!notice.contains("to task history"))
        #expect(!notice.contains("decrypted or decoded"))
        // And the run itself still reported success on its own channel — the plan store is not the
        // routine.
        #expect(fixture.viewModel.scheduledRunNotice?.contains("ran on schedule") == true)
    }

    /// **The row write's own failure, on this path, pinned** (SONNY-201).
    ///
    /// This path already answered correctly — `recordScheduledTaskHistory` has used
    /// `recordLocalStorageWriteFailure` since it was written — and nothing exercised it, so the
    /// property that made it the reference for the foreground fix was itself only a reading of the
    /// source. Its foreground twin is
    /// `ProductShellTests.aRowWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed`,
    /// which is this test with one directory changed, as the pair above already is for the plan
    /// write.
    ///
    /// The half that matters here is the last assertion: the routine really ran, and its own notice
    /// still says so. A lost row must not turn a scheduled run that worked into one the user is told
    /// failed, any more than it may on the attended path.
    @Test(.requiresUnprivilegedProcess)
    func aRowWriteFailureIsAStorageNoticeRatherThanAFailedScheduledRun() async throws {
        let historyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScheduledRowFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyRoot.path)
            try? FileManager.default.removeItem(at: historyRoot)
        }
        let fixture = try makeFixture(taskHistoryRoot: historyRoot)
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        // Read-only: the plan store sits under the fixture root and stays writable, so the row write
        // is the only one that fails — the reverse of the pair above.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyRoot.path)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // The row did not land, and nothing was written beside it either: the plan write is guarded
        // by the row's own `return`, which is `recordScheduledTaskHistory`'s two-catch shape.
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
        #expect(try fixture.taskPlanDetailStore.loadAll().isEmpty)

        // Write wording naming this failure, not the plan write's and not the load banner's.
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not save this scheduled run to task history: "))
        #expect(!notice.contains("what this scheduled run planned"))
        #expect(!notice.contains("decrypted or decoded"))

        // And the routine itself ran and still reports that it did.
        #expect(fixture.viewModel.errorMessage == nil, "a lost row is not the routine failing")
        #expect(fixture.viewModel.scheduledRunNotice?.contains("ran on schedule") == true)
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

    /// SONNY-90's unattended clause, pinned on the real scheduled path: Safe mode creates no new
    /// unattended prompt class, and a schedule Safe mode silently suspended would be one — so a
    /// benign trusted scheduled run under Safe mode runs exactly as it does without it. The
    /// standing tier-2 grant answers Safe mode's requirement the way it answers any requirement
    /// at or below its ceiling; what a scheduled run cannot satisfy (tier 3+) still pauses via
    /// SONNY-31's existing notify-and-pause, Safe mode or not. The *attended* trust shortcut is
    /// the half Safe mode does gate — pinned in InteractionModeTests, not here.
    @Test
    func aBenignTrustedScheduledRunUnderSafeModeStillRunsWithoutPromptOrPause() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        fixture.viewModel.interactionMode = .safe

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        let notice = try #require(fixture.viewModel.scheduledRunNotice)
        #expect(notice.contains("ran on schedule"))
        #expect(fixture.viewModel.approvalRequest == nil)
        let schedule = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(schedule.isEnabled)
        #expect(schedule.pausedReason == nil)
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
        // The occurrence `resolveOccurrence` advanced past before the run survives the pause write.
        // `RoutineStore.pauseSchedule` does its read-modify-write inside the store precisely so a
        // caller-held copy taken before `try await runner.execute` cannot revert this across that
        // suspension point; the store-level test pins the same fact, this is the only thing that
        // pins it on the real path the view model takes.
        #expect(schedule.lastRunAt == fixture.nineAM)
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

        // Counted across the attempt, not merely observed at the end: "exactly one notification"
        // is the whole promise, and a single non-nil read cannot tell one notice from three
        // overwriting each other. `AppDelegate` posts one notification per non-nil emission, so
        // emissions are the thing that has to be one.
        var notices: [String] = []
        let subscription = fixture.viewModel.$scheduledRunNotice
            .compactMap { $0 }
            .sink { notices.append($0) }
        defer { subscription.cancel() }

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()
        #expect(notices.count == 1)
        #expect(fixture.viewModel.scheduledRunNotice != nil)
        fixture.viewModel.scheduledRunNotice = nil

        // Two later ticks, one of them a full day on — an occurrence that would have been due.
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(60))
        try await fixture.waitForIdle()
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM.addingTimeInterval(24 * 60 * 60))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.scheduledRunNotice == nil)
        // Still one, a full day and two ticks later.
        #expect(notices.count == 1)
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
        // A fortnight later, on the injected clock rather than the wall clock — the re-anchor is
        // the thing under test, so the instant it anchors to has to be nameable.
        let resumedAt = fixture.tenAM.addingTimeInterval(14 * 24 * 60 * 60)
        fixture.viewModel.setRoutineScheduleEnabled(paused, to: true, now: resumedAt)

        let resumed = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(resumed.isEnabled)
        #expect(resumed.pausedReason == nil)
        #expect(resumed.lastRunAt == resumedAt)

        // Re-anchored to the moment of resuming, so none of the fortnight it spent paused is
        // outstanding: a tick right after resuming must not fire a catch-up.
        fixture.viewModel.checkScheduledRoutines(now: resumedAt.addingTimeInterval(60))
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
    }

    /// PR #27 review finding F1 — the defect, not a hardening. Editing a schedule rebuilds it
    /// through `RoutineSchedule.newlyCreated`, which had no `pausedReason` parameter, so changing a
    /// paused routine's run time silently dropped both the caption and the explanation: the
    /// routine stayed switched off with nothing anywhere saying why. That is precisely the
    /// unexplained-dead-routine state H2 exists to end, reached through the editor door instead of
    /// the scheduler's.
    @Test
    func editingAPausedRoutinesRunTimeKeepsItPausedWithItsReason() async throws {
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
        let paused = try fixture.routineStore.routine(named: "Morning")
        #expect(paused.schedule?.pausedReason != nil)

        // Move it from 9:00 to 7:00 — the routine's own detail-view edit path.
        fixture.viewModel.commitScheduleDraft(
            for: paused,
            cadence: .daily,
            hour: 7,
            minute: 0,
            weekday: 2,
            dayOfMonth: 1,
            now: fixture.tenAM
        )

        let edited = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(edited.hour == 7)
        #expect(edited.isEnabled == false)
        #expect(edited.pausedReason == "Snippet trigger ;sig already exists and would be replaced.")
        #expect(RoutineRowPresentation(routine: StoredRoutine(name: "Morning", steps: [], schedule: edited), now: fixture.tenAM).isPaused)
    }

    /// The other direction, so the carry-over cannot degrade into "a pause can never be cleared":
    /// once a routine is resumed, editing it does not drag the old reason back in.
    ///
    /// Renamed per PR #27 review finding F9. It previously claimed to pin "an edit that also
    /// switches the schedule back on clears the pause", which is not what it does and not
    /// reachable from here: resuming happens first, so `commitScheduleDraft` sees a schedule whose
    /// reason is already nil, and the enabled-plus-reason combination the old name described never
    /// occurs on this path. The ordering inside `newlyCreated` that actually decides that case is
    /// pinned where it lives, by `newlyCreatedClearsAPassedPauseReasonWhenItBuildsAnEnabledSchedule`
    /// in `RoutineScheduleTests`. Resume-then-edit is still worth pinning on its own account — it
    /// is the sequence a user fixing a paused routine actually performs.
    @Test
    func editingARoutineAfterResumingItDoesNotBringItsOldPauseBack() async throws {
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

        // Resume first, then edit — the order a user actually takes when fixing a paused routine.
        let paused = try fixture.routineStore.routine(named: "Morning")
        fixture.viewModel.setRoutineScheduleEnabled(paused, to: true, now: fixture.tenAM)
        let resumed = try fixture.routineStore.routine(named: "Morning")
        fixture.viewModel.commitScheduleDraft(
            for: resumed,
            cadence: .daily,
            hour: 7,
            minute: 0,
            weekday: 2,
            dayOfMonth: 1,
            now: fixture.tenAM
        )

        let edited = try #require(fixture.routineStore.routine(named: "Morning").schedule)
        #expect(edited.hour == 7)
        #expect(edited.isEnabled)
        #expect(edited.pausedReason == nil)
        #expect(edited.unattendedTrusted)
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

    // MARK: - Manual runs and the trust toggle (SONNY-54, under the consequence rule)
    //
    // The consequence rule (2026-08-13) subsumed the toggle's *manual* half: a tier-2 routine
    // runs by hand without asking whether or not it is trusted, because nothing tier-2 asks
    // anymore. What the toggle still governs is the unattended path (a schedule fires only under
    // it) and nothing else — its manual-run door closed because every manual tier-2 door did.
    // The trust *ceiling* is untouched and still observable: a destructive routine step prompts
    // by hand, trusted or not (`aTrustedTierThreeRoutineStillPromptsWhenRunByHand` below).

    /// A tier-2 routine run by hand completes with no prompt — through the ordinary consequence-
    /// rule auto-run, not through the trust decision — and none of the *scheduled* run's
    /// bookkeeping moves. A manual run is the user's own task: it reports through `finalSummary`,
    /// never through `scheduledRunNotice`, and it must not advance the streak history or the
    /// catch-up baseline that belong to the schedule.
    @Test
    func aTierTwoRoutineRunByHandRunsWithoutAskingTrustedOrNot() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)
        let routine = try fixture.routineStore.routine(named: "Morning")

        fixture.viewModel.runRoutineWidget(routine)
        try await fixture.waitForIdle()

        // No pause at the approval, and the run really completed.
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.isAwaitingApproval == false)
        #expect(fixture.viewModel.finalSummary.contains("Ran routine Morning"))
        #expect(fixture.viewModel.errorMessage == nil)
        // The ordinary auto-run, not the trust decision: nothing tier-2 asks, so the trust check
        // never authorizes anything on the manual path anymore.
        #expect(!fixture.viewModel.logStore.events.contains {
            $0.message == "Manual run approved by this routine's trust setting"
        })
        // No approval UI was involved, so the first-approval education state is untouched.
        #expect(fixture.viewModel.hasCompletedFirstApproval == false)
        // And nothing scheduled-side moved: no notice, no streak entry, no baseline advance —
        // and the fifth scheduled-side write surface, task history, holds a manual record only.
        // (`recordScheduledTaskHistory` is structurally unreachable from this path — gated on
        // `scheduledRunDisplayCommand`, which only `performScheduledRun` sets — so this pins the
        // enumeration rather than trusting it; PR #34 review, cycle 2, F3.)
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        let saved = try fixture.routineStore.routine(named: "Morning")
        #expect(saved.effectiveRecentRunDates.isEmpty)
        #expect(saved.schedule?.lastRunAt == fixture.enabledAt)
        let history = try fixture.taskHistoryStore.loadAll()
        #expect(history.count == 1)
        #expect(history.allSatisfy { $0.effectiveTrigger == .manual })
        #expect(history.first?.command == "Run my Morning routine")
        #expect(history.first?.outcomeStatus == .completed)
    }

    /// The prompt-then-approve flow on the manual routine path, kept on what still asks: an
    /// untrusted routine whose step would *replace* an existing snippet pauses at the destructive
    /// prompt, and approving it runs the routine. (Before the consequence rule this flow was
    /// exercised by the plain tier-2 confirmation, which no longer exists.)
    @Test
    func anUntrustedRoutineWithADestructiveStepPromptsWhenRunByHandAndApprovingRunsIt() async throws {
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

        fixture.viewModel.runRoutineWidget(routine)
        try await fixture.waitForIdle()

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        #expect(fixture.viewModel.finalSummary == "Approval needed before Sonny can act.")
        #expect(!fixture.viewModel.logStore.events.contains {
            $0.message == "Manual run approved by this routine's trust setting"
        })

        fixture.viewModel.start()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary.contains("Ran routine Morning"))
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "New text")
    }

    /// A routine with no schedule — and therefore nowhere for a trust grant to live — runs by
    /// hand exactly like every other tier-2 routine: without asking. Pins that the manual path
    /// needs no schedule record at all.
    @Test
    func aRoutineWithoutAScheduleRunsByHandWithoutAsking() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [fixture.inertStep]))
        let routine = try fixture.routineStore.routine(named: "Morning")

        fixture.viewModel.runRoutineWidget(routine)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary.contains("Ran routine Morning"))
    }

    /// The schedule's enabled state and the trust toggle no longer change a manual tier-2 run in
    /// either direction — disabled-and-trusted runs, and revoking trust with the schedule still
    /// off runs too. This deliberately supersedes the manual half of the F4 coordinator ruling
    /// (PR #34 review cycle 2, 2026-08-07: "a disabled schedule with trust still on covers manual
    /// runs"): under the consequence rule nothing tier-2 asks, so there is no manual prompt left
    /// for trust to cover or its revocation to restore. The toggle's remaining door is the
    /// unattended one, pinned by the scheduled-run tests above.
    @Test
    func neitherScheduleStateNorTrustChangesAManualTierTwoRunAnymore() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        // Disabled by the user (the initializer's default activation), trusted.
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [fixture.inertStep],
                schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
            )
        )
        let routine = try fixture.routineStore.routine(named: "Morning")
        // The premise, guarded rather than assumed.
        #expect(routine.schedule?.isEnabled == false)
        #expect(routine.schedule?.unattendedTrusted == true)

        fixture.viewModel.runRoutineWidget(routine)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary.contains("Ran routine Morning"))

        // Revoking trust changes nothing manual either, schedule still off.
        fixture.viewModel.setRoutineUnattendedTrust(routine, to: false)
        let revoked = try fixture.routineStore.routine(named: "Morning")
        #expect(revoked.schedule?.isEnabled == false)
        #expect(revoked.schedule?.unattendedTrusted == false)

        fixture.viewModel.runRoutineWidget(revoked)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary.contains("Ran routine Morning"))
    }

    /// The tier-3+ backstop on the manual path, end to end: trust never covers an escalated
    /// routine, so the run pauses at the explicit-approval prompt exactly as an untrusted one
    /// would — and, unlike the scheduled path, it does *not* pause the schedule: SONNY-31's pause
    /// is the answer to "nobody is present to approve", and somebody is. Approving then runs it.
    @Test
    func aTrustedTierThreeRoutineStillPromptsWhenRunByHand() async throws {
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
        let routine = try fixture.routineStore.routine(named: "Morning")

        fixture.viewModel.runRoutineWidget(routine)
        try await fixture.waitForIdle()

        // Paused at the prompt, at the escalated tier — the trust grant did not stretch.
        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.assessment.effectiveTier == .tier3)
        // The tier-3 action really did not happen yet.
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "Old text")
        // And the manual prompt is not the unattended refusal: the schedule stays on, un-paused,
        // with no scheduled-run notice posted.
        let schedule = try #require(try fixture.routineStore.routine(named: "Morning").schedule)
        #expect(schedule.isEnabled)
        #expect(schedule.pausedReason == nil)
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        // Exactly one "Approval required" event: the view-model comparison paused before
        // execution was ever attempted, rather than proceeding into `AgentRunner`'s gate and
        // re-arming through the drift catch — that path logs the same line twice (the gate at
        // refusal, the catch at re-arm). Pins the clean-pause property the changelog names as
        // the comparison's purpose, and kills battery mutant M4 (PR #34 review, cycle 2, F1).
        #expect(fixture.viewModel.logStore.events.filter { $0.message.hasPrefix("Approval required") }.count == 1)

        fixture.viewModel.start()
        try await fixture.waitForIdle()

        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "New text")
    }

    /// The trust decision's own shape rules, pinned directly — the planner is not injectable at
    /// this level, so a mixed plan cannot be produced end to end. The grant covers exactly the
    /// canonical single-step run-routine plan and nothing broader: wrap the routine beside any
    /// other step and the full prompt stays, because those steps were never what the user trusted.
    @Test
    func theTrustDecisionCoversOnlyTheCanonicalSingleStepRunRoutinePlan() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        let canonical = RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning")
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: canonical) == .approved(.tier2))

        // The same lookup the adapter performs at execute time: normalized, so case differences
        // in a planner-written name cannot make the check and the execution disagree.
        let differentCase = RunRoutineCapabilityAdapter.plan(forRoutineNamed: "mOrNiNg")
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: differentCase) == .approved(.tier2))

        let mixed = AgentPlan(
            summary: "Run routine Morning, then calculate.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run saved routine Morning.",
                    routineName: "Morning"
                ),
                fixture.inertStep
            ]
        )
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: mixed) == .notRequested)
    }

    /// Every unresolvable case fails closed to `.notRequested` — a trust check that cannot be
    /// completed relaxes nothing.
    @Test
    func theTrustDecisionFailsClosedWhenTheRoutineCannotBeResolvedOrIsUntrusted() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: false)

        // Saved but untrusted.
        let untrusted = RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning")
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: untrusted) == .notRequested)

        // No such routine.
        let ghost = RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Ghost")
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: ghost) == .notRequested)

        // A run-routine step carrying no name at all.
        let nameless = AgentPlan(
            summary: "Run a routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run a saved routine."
                )
            ]
        )
        #expect(fixture.viewModel.manualRoutineTrustDecision(for: nameless) == .notRequested)
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

    // MARK: - The outcome actually reaching the user (SONNY-113)

    /// **Every notice the scheduler can write names the routine it is about.**
    ///
    /// This became load-bearing when the notice grew two surfaces it did not have: a system
    /// notification (the gate that suppressed every one of them was replaced by SONNY-56) and the
    /// widget's own strip. On both, the text is all the user gets — there is no row, no page and no
    /// context around it — so a notice that does not say which routine it means is a banner that
    /// tells someone with four routines nothing they can act on.
    ///
    /// **The population is read out of the source rather than listed from memory**, because a claim
    /// about "every" writer is exactly the kind this repository has got wrong by enumerating one
    /// path and generalising. If a seventh writer is added, the count below fails and whoever added
    /// it comes here to drive it.
    @Test
    func everyScheduledNoticeTheSchedulerCanWriteNamesItsRoutine() async throws {
        let writers = try MacAgentSource.occurrences(
            of: "scheduledRunNotice = \"",
            in: "AgentViewModel.swift"
        )
        #expect(writers == 6, "A scheduled-notice writer was added or removed; drive it below.")

        // 1. Skipped because the schedule is not trusted for unattended running.
        let untrusted = try makeFixture()
        defer { untrusted.cleanUp() }
        try untrusted.saveRoutine(unattendedTrusted: false)
        untrusted.viewModel.checkScheduledRoutines(now: untrusted.tenAM)
        try await untrusted.waitForIdle()
        #expect(try #require(untrusted.viewModel.scheduledRunNotice).contains("Morning"))

        // 2. Missed — past the catch-up window, the laptop-shut-all-day case.
        let missed = try makeFixture()
        defer { missed.cleanUp() }
        try missed.saveRoutine(unattendedTrusted: true)
        missed.viewModel.checkScheduledRoutines(now: missed.nineAM.addingTimeInterval(14 * 60 * 60))
        try await missed.waitForIdle()
        #expect(try #require(missed.viewModel.scheduledRunNotice).contains("Morning"))

        // 3. A clarification nobody is present to answer — the routine deleted inside the window
        //    between the schedule firing and the task body's first line.
        let clarified = try makeFixture()
        defer { clarified.cleanUp() }
        try clarified.saveRoutine(unattendedTrusted: true)
        clarified.viewModel.checkScheduledRoutines(now: clarified.tenAM)
        try clarified.routineStore.delete(routineNamed: "Morning")
        try await clarified.waitForIdle()
        #expect(try #require(clarified.viewModel.scheduledRunNotice).contains("Morning"))

        // 4. It ran.
        let ran = try makeFixture()
        defer { ran.cleanUp() }
        try ran.saveRoutine(unattendedTrusted: true)
        ran.viewModel.checkScheduledRoutines(now: ran.tenAM)
        try await ran.waitForIdle()
        #expect(try #require(ran.viewModel.scheduledRunNotice).contains("Morning"))

        // 5. It failed — a step that throws at execute time rather than at plan time, so this lands
        //    in the generic catch rather than in any of the branches above it.
        let failed = try makeFixture()
        defer { failed.cleanUp() }
        try failed.saveRoutine(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "calc",
                    operation: .calculateUtility,
                    description: "Calculate apples.",
                    searchQuery: "apples"
                )
            ]
        )
        failed.viewModel.checkScheduledRoutines(now: failed.tenAM)
        try await failed.waitForIdle()
        let failureNotice = try #require(failed.viewModel.scheduledRunNotice)
        #expect(failureNotice.contains("Morning"))
        #expect(failureNotice.contains("failed on its scheduled run"))

        // 6. Sonny paused the schedule — the worst case this ticket names, because the routine is
        //    now switched off and will not run again.
        let paused = try makeFixture()
        defer { paused.cleanUp() }
        try paused.saveRoutineBypassingValidation(
            unattendedTrusted: true,
            steps: [
                AgentStep(
                    id: "vision",
                    operation: .visionSession,
                    description: "Control Notes.",
                    appName: "Notes",
                    // Without a goal `prepare` throws first and the run lands in the *failure*
                    // branch instead — measured while writing this, and the reason case 5 and case 6
                    // are genuinely different paths rather than the same one twice.
                    visionGoal: "do a thing"
                )
            ]
        )
        paused.viewModel.checkScheduledRoutines(now: paused.tenAM)
        try await paused.waitForIdle()
        let pausedNotice = try #require(paused.viewModel.scheduledRunNotice)
        #expect(pausedNotice.contains("Morning"))
        #expect(pausedNotice.contains("paused its schedule"))
        #expect(try paused.routineStore.routine(named: "Morning").schedule?.isEnabled == false)
    }

    /// **The scheduled notice no longer posts through the failure category (SONNY-113).**
    ///
    /// It did, and that carried a Retry button, which is wired to `retryLastCommand()` — and
    /// `aScheduledRunDoesNotBecomeTheRetryTarget` in this same suite demonstrates what that button
    /// would have done: re-dispatch the user's own last submitted command, a task with no
    /// relationship to the routine the banner is about. It also meant a routine that ran fine
    /// arrived in the category Sonny reserves for failures.
    ///
    /// Asserted by reading the wiring because it cannot be asserted by running it:
    /// `SonnyNotificationService.init?` returns nil without bundle identity, and
    /// `UNUserNotificationCenter.current()` aborts the process rather than throwing when there is
    /// none — so the subscription this pins does not exist in a test run at all. See
    /// `MacAgentSource` for why a scan is the honest tool here and what makes this one sound.
    @Test
    func theScheduledNoticePostsThroughItsOwnActionlessCategory() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let subscription = try MacAgentSource.region(
            of: delegate,
            from: "viewModel.$scheduledRunNotice",
            to: ".store(in: &cancellables)"
        )
        #expect(subscription.contains("postScheduledRunNotification"))
        #expect(!subscription.contains("postErrorNotification"))

        // And the category it posts into offers nothing to press. The two neighbours that do carry
        // actions are checked alongside it, so this fails if the empty array is ever filled in by
        // copying one of them.
        let service = try MacAgentSource.read("SonnyNotificationService.swift")
        let scheduledCategory = try MacAgentSource.region(
            of: service,
            from: "identifier: SonnyNotificationCategory.scheduled,",
            to: ")"
        )
        #expect(scheduledCategory.contains("actions: [],"))
        #expect(!scheduledCategory.contains("retryAction"))
        #expect(!scheduledCategory.contains("allowAction"))

        // The click goes to Command Center, not the widget: the notice strip renders there and the
        // Routines page is where a paused schedule is switched back on.
        #expect(service.contains("case SonnyNotificationCategory.scheduled:"))
        #expect(service.contains("self?.onOpenScheduledRun()"))
        let wiring = try MacAgentSource.region(
            of: delegate,
            from: "onOpenScheduledRun: { [weak self] in",
            to: "}"
        )
        #expect(wiring.contains("showCommandCenter()"))
    }

    /// **The widget carries the notice too, and does not shrink away from it (SONNY-113, founder
    /// decision 2026-08-20).**
    ///
    /// The notification only fires when the user is *not* working in Sonny. When they are — Command
    /// Center open behind a routine-detail, workspace-detail or Settings sheet, all three of which
    /// cover the four pages that render this notice, or typing into the widget with Command Center
    /// closed — nothing fired and nothing rendered. The widget strip closes that, but only if the
    /// widget is expanded: every strip lives in the `else` branch of `if isCompact`, and compact is
    /// the widget's steady state when nobody is using Sonny, which is exactly the state a routine
    /// fires in. So the collapse refusal is not a nicety attached to the strip — without it the
    /// strip would have been added to a surface the user cannot see.
    @Test
    func theWidgetRendersTheScheduledNoticeAndStaysExpandedWhileItIsSet() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")

        // The strip itself, not merely a mention of the property somewhere in a 1,600-line file.
        let strip = try MacAgentSource.region(
            of: widget,
            from: "if let notice = viewModel.scheduledRunNotice {",
            to: "if let notice = viewModel.localStorageNotice {"
        )
        #expect(strip.contains("WidgetNoticeStrip("))
        #expect(strip.contains("Dismiss scheduled run notice"))
        // **The tint, pinned (PR #80 review, F4).** `WidgetNoticeStrip.tint` defaults to the error
        // red its two older callers ship, so a mutant deleting this one argument silently reports a
        // routine that ran fine in Sonny's failure colour — the same mistake as posting it in the
        // failure notification category, one surface further in, and the whole reason the parameter
        // exists. The default being the *wrong* value for this caller is what makes an omission
        // invisible without this line.
        #expect(strip.contains("tint: WidgetTheme.primaryAction"))
        // Same glyph Command Center shows for the same notice, so one event does not read as two
        // different kinds of thing depending on which surface the user happens to be looking at.
        #expect(strip.contains("clock.arrow.circlepath"))

        let collapseRule = try MacAgentSource.region(
            of: widget,
            from: "private var isCollapsible: Bool {",
            to: "private var shouldClearOutcomeOnDismiss: Bool {"
        )
        #expect(collapseRule.contains("viewModel.scheduledRunNotice == nil"))

        // And an arriving notice re-runs that decision rather than waiting for something else to
        // change, so a routine firing at an already-compact widget expands it there and then.
        #expect(widget.contains(".onChange(of: viewModel.scheduledRunNotice)"))
    }

    /// **A scheduled routine does not fire while a clarification is waiting (PR #80 review, F1,
    /// founder decision 2026-08-20).**
    ///
    /// `checkScheduledRoutines` guarded only on `isRunning` and `isAwaitingApproval`, and a
    /// clarification pause makes both false — `performStart`'s defer has already set `isRunning`
    /// false and a clarification never writes `approvalRequest`. So a routine could start on top of
    /// a user's half-finished task.
    ///
    /// The cost was specific rather than aesthetic: `finishRecordingPolicyIfSettled()` refuses while
    /// `isRunning`, so a user cancelling their clarification inside that window got no reset — "Don't
    /// save this task" stayed on and clipboard history stayed paused until relaunch. See
    /// `ClarificationExitTests.cancellingAClarificationWithNothingElseRunningCompletesTheRecordingPolicyReset`,
    /// which asserts both halves of that dependency.
    ///
    /// **The second half of this test is the part that matters**: the occurrence is only *delayed*.
    /// Nothing here resolves it, so the very next tick runs it once the question is gone. A guard
    /// that dropped the run instead would have traded one silent failure for another.
    @Test
    func aPendingClarificationStopsTheSchedulerFromStartingAnything() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        try fixture.saveRoutine(unattendedTrusted: true)

        // A real clarification through the real dispatch path — a bare "=" is a command the
        // deterministic fixture genuinely cannot act on.
        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget, fromComposer: true)
        try await fixture.waitForIdle()
        let question = try #require(fixture.viewModel.clarificationQuestion)
        // The window: the two older terms are both false, which is why they could not close it.
        #expect(fixture.viewModel.isRunning == false)
        #expect(fixture.viewModel.isAwaitingApproval == false)

        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        // Nothing started, nothing was reported, and the user's question is untouched.
        #expect(fixture.viewModel.scheduledRunNotice == nil)
        #expect(fixture.viewModel.clarificationQuestion == question)
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
        // The occurrence is still outstanding — the baseline is exactly where enabling the schedule
        // left it, never advanced to the occurrence, so this is a deferral rather than a skip.
        // `resolveOccurrence` is what would have consumed it, and it runs on every outcome
        // including the skips, so an unmoved baseline is the one thing that distinguishes "not
        // started" from "handled and reported".
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.lastRunAt == fixture.enabledAt)

        // Delay, not loss: with the question answered away, the same tick runs it.
        fixture.viewModel.cancelCurrentRun()
        fixture.viewModel.checkScheduledRoutines(now: fixture.tenAM)
        try await fixture.waitForIdle()

        #expect(try #require(fixture.viewModel.scheduledRunNotice).contains("ran on schedule"))
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty == false)
        // And the baseline moved this time, so the two halves are distinguishable by the same field.
        #expect(try fixture.routineStore.routine(named: "Morning").schedule?.lastRunAt == fixture.nineAM)
    }

    private func makeFixture(
        taskHistoryMaxItems: Int = TaskHistoryStore.defaultMaxItems,
        planDetailRoot: URL? = nil,
        taskHistoryRoot: URL? = nil
    ) throws -> Fixture {
        try Fixture(
            taskHistoryMaxItems: taskHistoryMaxItems,
            planDetailRoot: planDetailRoot,
            taskHistoryRoot: taskHistoryRoot
        )
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let viewModel: AgentViewModel
        /// Records what the scheduled run actually opened, so the fixture's hermeticity is
        /// assertable rather than assumed.
        let browserOpener: HermeticBrowserOpener
        let appOpener: HermeticAppOpener
        let routineStore: RoutineStore
        let snippetStore: SnippetStore
        let taskHistoryStore: TaskHistoryStore
        let taskPlanDetailStore: TaskPlanDetailStore
        let nineAM: Date
        let tenAM: Date
        let enabledAt: Date

        /// `taskHistoryMaxItems` is injected only so a test can drive eviction without ten thousand
        /// records — the seam `TaskHistoryStore.maxItems`'s own doc comment exists for.
        ///
        /// `planDetailRoot` exists for the one test that has to make the plan store unwritable while
        /// task history stays writable, the same shape `AgentViewModelLocalStorageTests` uses for its
        /// delete-ordering test. Everything else leaves it under `root`.
        init(
            taskHistoryMaxItems: Int = TaskHistoryStore.defaultMaxItems,
            planDetailRoot: URL? = nil,
            /// The mirror of `planDetailRoot`, for the test that has to fail the *row* write while
            /// the plan store stays writable (SONNY-201).
            taskHistoryRoot: URL? = nil
        ) throws {
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
            taskHistoryStore = TaskHistoryStore(
                fileURL: (taskHistoryRoot ?? root).appendingPathComponent("task-history.json"),
                maxItems: taskHistoryMaxItems
            )
            taskPlanDetailStore = TaskPlanDetailStore(
                fileURL: (planDetailRoot ?? root).appendingPathComponent("task-plan-details.json")
            )

            browserOpener = HermeticBrowserOpener()
            appOpener = HermeticAppOpener()
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
                // Hermetic seams (fakes defined in ProductShellTests.swift, same test target).
                // This fixture executes real routine plans — since SONNY-38's AC5 test its routine
                // opens a URL — so without these the scheduler drives the user's real browser.
                browserOpener: browserOpener,
                appOpener: appOpener,
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
                taskHistoryStore: taskHistoryStore,
                taskPlanDetailStore: taskPlanDetailStore,
                clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                ),
                approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
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

        /// Save a routine the store's own step validation would refuse.
        ///
        /// The single sanctioned bypass (`RoutineStore.saveBypassingStepValidation`, internal to
        /// `MacAgentCore` and documented there as a deliberate greppable door). Needed because
        /// SONNY-94's belt is a check on a state the *other two layers make unreachable* — a routine
        /// carrying a vision step cannot be authored legally — and a belt whose test cannot reach it
        /// is a belt nobody can tell is buckled.
        func saveRoutineBypassingValidation(unattendedTrusted: Bool, steps: [AgentStep]) throws {
            var schedule = RoutineSchedule(
                cadence: .daily,
                hour: 9,
                minute: 0,
                unattendedTrusted: unattendedTrusted
            )
            schedule.setEnabled(true, now: enabledAt)
            try routineStore.saveBypassingStepValidation(
                StoredRoutine(name: "Morning", steps: steps, schedule: schedule)
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
