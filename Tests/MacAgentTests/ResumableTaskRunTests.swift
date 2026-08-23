import Combine
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
    ///
    /// **The `startedAt` half is asserted against a seeded past instant, and that is a fix rather
    /// than decoration** (PR #105 review F7). The first version compared the two values as the run
    /// produced them, and could not fail: the store encodes dates with `.iso8601`, which is
    /// whole-second resolution, and both were written inside the same wall-clock second — so a
    /// mutant that restarted the clock on every resume passed the test whose name promises it
    /// cannot. Moving the first record an hour into the past makes the two answers a measurable
    /// distance apart.
    @Test
    func aTaskInterruptedTwiceStaysOneRecordWithItsOriginalStartTime() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let asWritten = try #require(try fixture.resumableTaskStore.loadAll().first)

        // Back-date the start, leaving `updatedAt` where it is so the record is not idle. This is
        // the interruption having happened an hour ago, which is the ordinary case and the one the
        // same-second comparison could not see.
        var backdated = asWritten
        backdated.startedAt = asWritten.startedAt.addingTimeInterval(-3_600)
        try fixture.resumableTaskStore.save(backdated)
        fixture.viewModel.refreshResumableTasks()

        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(offer.startedAt == backdated.startedAt)

        // Fail again, so the record survives the resume and can be read back.
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        let second = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(second.id == asWritten.id)
        #expect(second.startedAt == backdated.startedAt, "the resumed run inherits the task's start, not its own")
        #expect(second.startedAt < second.updatedAt.addingTimeInterval(-1_800))
        // The plan narrowed to what was left, and there is still exactly one record.
        #expect(second.plan.steps.map(\.id) == ["url"])
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
    }

    /// **F6/M23: the second interruption keeps the file the first run produced.**
    ///
    /// Both carry tests until now passed the offer's own value straight into the dispatch, so
    /// neither exercised that value being written *back* into the record. Without it, a chain
    /// `[draft, open it]` interrupted at the draft's consumer, resumed, and interrupted again leaves
    /// a bare `open_generated_artifact` with no path — and every later Continue dies in `prepare`
    /// with "needs outputPath or a previous chained artifact", so the offer becomes permanently
    /// un-continuable.
    @Test
    func aSecondInterruptionKeepsTheFileTheFirstRunProduced() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.fileOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open them", plan: fixture.draftThenOpenTheDraftPlan)
        let first = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(first.chainedArtifactPath == fixture.draftOutput.path)

        // Continue, and let it fail again — the second interruption.
        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        let second = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(second.chainedArtifactPath == fixture.draftOutput.path, "the carried file survives the resume")

        // And the third attempt still works, which is what the carried value buys.
        fixture.fileOpener.failure = nil
        let secondOffer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(secondOffer))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.fileOpener.opened.last == fixture.draftOutput.path)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
    }

    /// **F6/M30: Continue starts a *widget* task**, asserted through the predicate that depends on
    /// it rather than only through the source scan beside it.
    @Test
    func aResumedRunIsAWidgetTaskSoTheWidgetShowsItsResult() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let offer = try #require(fixture.viewModel.resumeOffer)

        fixture.browserOpener.failure = nil
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.activeTaskOrigin == .widget)
        #expect(!fixture.viewModel.finalSummary.isEmpty)
        #expect(fixture.viewModel.hasVisibleWidgetPanel, "a run started from the widget shows its result there")
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

    /// **The carried file, end to end.** A resumed run's remaining steps name the file an earlier
    /// unit produced nowhere at all — a bare "open it" step has no path of its own and is filled in
    /// from whatever the previous unit wrote. So the record has to carry it, and the resume has to
    /// hand it back to the executor.
    ///
    /// The executor's own half of this is pinned in `RunUnitProgressTests`; what this adds is the
    /// path through the view model, which is where the value is stored and read back.
    @Test
    func aResumeOpensTheFileTheInterruptedRunHadAlreadyWritten() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.fileOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open them", plan: fixture.draftThenOpenTheDraftPlan)

        let record = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(record.completedStepIDs == ["draft"])
        #expect(record.chainedArtifactPath == fixture.draftOutput.path)

        fixture.fileOpener.failure = nil
        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        // The remaining step is a bare "open it" with no path, and it opened the right file — which
        // it can only have got from the record.
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.fileOpener.opened.last == fixture.draftOutput.path)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
    }

    /// **The settle runs above task history's own guards, not below them.**
    ///
    /// Reachable with one switch: task-history memory off and unfinished-tasks memory on.
    /// `recordTaskHistoryIfTerminal` then returns before writing a row — and if the settle sat under
    /// that guard, a completed task's record would survive and Sonny would offer to continue
    /// something that had already finished.
    @Test
    func aFinishedRunClearsItsRecordEvenWhenTaskHistoryMemoryIsOff() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)

        // The premise, guarded: with that switch off, this store is still live and a failed run
        // still records. Otherwise "the record is gone" below says nothing.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty, "task-history memory really is off")

        // Continuing it to completion clears the record — through the same terminal that writes no
        // history row at all.
        fixture.browserOpener.failure = nil
        let offer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(offer))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
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

    /// **F1: answering a clarification continues the task that asked it.**
    ///
    /// Reproduced by the PR #105 reviewer and this is that reproduction: `submitClarification`
    /// re-enters `start()`, `performStart` drops its handle on the checkpoint, and before the fix
    /// the answered run minted a second record and settled only that one. The paused run's record
    /// stayed on disk for the full idle period — so once the task finished, Sonny offered to carry
    /// on with it, and Continue re-asked a question the user had already answered.
    @Test
    func anAnsweredClarificationKeepsOneRecordRatherThanOrphaningTheFirst() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run("Do the ambiguous thing", plan: fixture.clarifyingPlan)
        #expect(fixture.viewModel.clarificationQuestion != nil)
        let paused = try #require(try fixture.resumableTaskStore.loadAll().first)

        // Answering re-plans, so the run that follows is an ordinary two-unit plan that completes.
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Downloads folder"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        // The premise: the answered run really did finish.
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(!fixture.viewModel.finalSummary.isEmpty)

        // One task, one record — and the task finished, so no record at all.
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil, "a finished task is never offered")
        #expect(paused.command == "Do the ambiguous thing")
    }

    /// The same shape at the door the re-enumeration found rather than the review: a retry after a
    /// failure continues the failed attempt's record instead of leaving it behind as a live offer.
    @Test
    func aRetryAfterAFailureContinuesTheSameRecordRatherThanLeavingTheFailedOneBehind() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let failed = try #require(try fixture.resumableTaskStore.loadAll().first)

        // The retry succeeds. Its draft unit writes a fresh file, so the plan is rebuilt with a new
        // output — the retry re-plans from the command, exactly as the product does.
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-retry.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage == nil, "the retry really did succeed")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(failed.stopReason == .failed)
    }

    /// **The fourth door: "Run again" on the failed task's own row in Command Center.**
    ///
    /// Reproduced by PR #105's re-check, and this is that reproduction. `runTaskAgain` takes an
    /// arbitrary historical record rather than whatever is in flight, and it can run after a
    /// relaunch that left `activeResumableTask` nil — so it matches on the durable link the row
    /// carries, `CompletedTaskRecord.resumableTaskID`, and continues that record.
    @Test
    func runningAFailedTaskAgainFromItsOwnRowContinuesThatTasksRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)

        // The row the Tasks page hands back, carrying the link.
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.outcomeStatus == .failed)
        #expect(row.resumableTaskID == outstanding.id, "a failed run's row names the record it left behind")

        // Run it again, and this time it works.
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(fixture.viewModel.runTaskAgain(row))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage == nil, "the re-run really did finish")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil, "a task the user has just re-run is not offered")
    }

    /// **The link survives a relaunch, which is what rules out the in-flight handle.**
    ///
    /// Simulated by clearing everything the app keeps in memory and reloading from disk — the state
    /// a fresh launch is in. `activeResumableTask` is nil there, so a door arming from it would do
    /// nothing; the row and the record are both still on disk, so the durable link still matches.
    @Test
    func theRowsLinkStillFindsTheRecordAfterEverythingInMemoryIsGone() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)

        // **A relaunch, built rather than simulated**: a second view model over the same store
        // files, which is what the next launch really is. Nulling fields on the first one would have
        // been a test asserting against its own idea of a fresh process.
        let relaunched = fixture.makeRelaunchedViewModel()
        relaunched.refreshTaskHistory()
        relaunched.refreshResumableTasks()
        #expect(relaunched.resumeOffer?.id == outstanding.id, "the offer survives a relaunch")

        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(relaunched.runTaskAgain(row))
        try await fixture.waitForIdle(relaunched)

        #expect(relaunched.errorMessage == nil)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(relaunched.resumeOffer == nil)
    }

    /// **A row with no link re-runs as a fresh task, and that is the stated boundary.** Every row
    /// written before the field existed is in this case, and so is one whose record has since been
    /// deleted or gone idle. The control matters: the record left over is a *different* task's, so
    /// this is a claim about the link rather than about the re-run doing nothing.
    @Test
    func aRowWithNoLinkRunsAgainAsAFreshTaskAndLeavesTheOtherRecordAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)
        var row = try #require(fixture.viewModel.taskHistoryRecords.first)

        // A row from before the link existed.
        row.resumableTaskID = nil

        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(fixture.viewModel.runTaskAgain(row))
        try await fixture.waitForIdle()

        // The re-run finished and settled its own record; the unlinked one is untouched.
        #expect(fixture.viewModel.errorMessage == nil)
        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.map(\.id) == [outstanding.id])
        #expect(after.first?.completedStepIDs == ["draft"])
    }

    /// **An arm this door could not spend is dropped, not left for the next dispatch.**
    ///
    /// `dispatch`'s own `isAwaitingApproval` guard returns *before* `start()` runs, and `start()` is
    /// where an arm is spent — so a door with no in-flight guard of its own has to drop it itself.
    /// `runTaskAgain` is that door: unlike `retryLastCommand` it guards nothing, and the Tasks page
    /// offers Run again while a different run sits at an approval prompt.
    @Test
    func anArmTheFourthDoorCouldNotSpendIsNotInheritedByTheNextDispatch() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // A failed task, with its record and its linked row.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.resumableTaskID == outstanding.id)

        // A second run parks at an approval, which is what makes `dispatch` refuse.
        fixture.browserOpener.failure = nil
        try await fixture.run("Overwrite the notes", plan: fixture.approvalNeedingPlan)
        #expect(fixture.viewModel.isAwaitingApproval)

        #expect(!fixture.viewModel.runTaskAgain(row), "dispatch refuses while an approval is pending")

        // End the paused run, then do something unrelated. Under a surviving arm the unrelated run
        // would settle the *failed* task's record instead of its own.
        fixture.viewModel.cancelCurrentRun()
        fixture.draftOutput = fixture.root.appendingPathComponent("other.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        try await fixture.run("A completely different task")

        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.map(\.id) == [outstanding.id], "the failed task's record is untouched")
        #expect(after.first?.completedStepIDs == ["draft"])
    }

    /// **A dangling link matches nothing, not merely the wrong thing** (PR #105 verification, R4).
    ///
    /// Every other test at this door has exactly one record on disk, so `first(where:)` and a bare
    /// `first` are indistinguishable there — the code was right and nothing held that the match was
    /// *exact*. This is the case that separates them: the linked record is deleted, a different task
    /// then fails so the only record on disk belongs to someone else, and Run again is pressed on
    /// the now-dangling row. It has to start fresh and leave the stranger's record exactly where it
    /// is; a bare `first` would arm that stranger and delete its record when the re-run finished.
    @Test
    func aDanglingLinkStartsFreshAndLeavesAnotherTasksRecordAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // Task A fails, and its row carries the link.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let recordA = try #require(try fixture.resumableTaskStore.loadAll().first)
        let rowA = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(rowA.resumableTaskID == recordA.id)

        // The user deletes A from Memory. The row survives and its link now points at nothing.
        fixture.viewModel.deleteMemoryEntry(in: .resumableTasks, at: 0)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // Task B fails. It is now the only record on disk, and it belongs to a different task.
        fixture.draftOutput = fixture.root.appendingPathComponent("other.md")
        try await fixture.run("A completely different task")
        let recordB = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(recordB.id != recordA.id)
        #expect(recordB.command == "A completely different task")

        // Run again on A's dangling row, and let it finish.
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(fixture.viewModel.runTaskAgain(rowA))
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.errorMessage == nil, "the re-run really did finish")

        // B is untouched — same id, same progress, still offered. Under a match that took whatever
        // record happened to be first, the re-run would have continued B and deleted it on success.
        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.map(\.id) == [recordB.id])
        #expect(after.first?.command == "A completely different task")
        #expect(after.first?.completedStepIDs == recordB.completedStepIDs)
        #expect(fixture.viewModel.resumeOffer?.id == recordB.id)
    }

    /// A completed run's row carries no link, because the settle deleted its record at the same
    /// terminal that wrote the row. The ordering inside `recordTaskHistoryIfTerminal` is what makes
    /// that true rather than incidental.
    @Test
    func aFinishedRunsRowNamesNoRecordBecauseThereIsNoneToName() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run("Write notes and open the page")

        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.outcomeStatus == .completed)
        #expect(row.resumableTaskID == nil)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
    }

    /// A run that is *not* a continuation leaves the outstanding record alone — which is the
    /// founder's lifecycle rather than a leak, and the half the two tests above must not break.
    @Test
    func anUnrelatedRunLeavesTheOutstandingRecordExactlyWhereItWas() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)

        // Something else entirely, and it finishes.
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("other.md")
        try await fixture.run("A completely different task")

        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.count == 1)
        #expect(after.first?.id == outstanding.id)
        #expect(after.first?.command == "Write notes and open the page")
        #expect(fixture.viewModel.resumeOffer?.id == outstanding.id)
    }

    /// **A refused dispatch drops the arm rather than leaving it for the next one.**
    ///
    /// `retryLastCommand` arms a restart and then calls `dispatch`, which can refuse — `canSubmit`
    /// also gates on a transcription in flight, which `retryLastCommand`'s own `!isTaskInFlight`
    /// guard does not cover. An arm that survived that refusal would be spent by the *next*
    /// dispatch, and an unrelated command would overwrite the failed task's record.
    @Test
    func anArmDroppedByARefusedDispatchIsNotInheritedByTheNextOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let outstanding = try #require(try fixture.resumableTaskStore.loadAll().first)

        // The retry is refused: a transcription is in flight, which `canSubmit` gates on and
        // `retryLastCommand`'s own guard does not.
        fixture.viewModel.isTranscribingVoice = true
        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()
        #expect(try fixture.resumableTaskStore.loadAll().count == 1, "the refused retry ran nothing")

        // Now something unrelated, which must get a record of its own rather than the arm's. It
        // succeeds, so its own record settles and only the outstanding one is left — which is what
        // makes the count below discriminate: under an inherited arm the unrelated run would have
        // settled the *outstanding* record and the store would be empty.
        fixture.viewModel.isTranscribingVoice = false
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("other.md")
        try await fixture.run("A completely different task")

        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.count == 1, "the unrelated run finished, so only the outstanding record is left")
        #expect(after.first?.id == outstanding.id)
        #expect(after.first?.command == "Write notes and open the page")
        #expect(after.first?.completedStepIDs == ["draft"])
    }

    /// **A restart inherits the task's identity and not a finished unit's file.**
    ///
    /// `chainedArtifactPath` means "what an already-completed unit produced". A resume rejoins such
    /// a chain and carries it; a restart — an answered clarification, or a retry — has completed
    /// nothing, so carrying it would name a file from an attempt whose steps are all going to run
    /// again. Observable when the retry's own plan fails at its *first* unit, which is the case
    /// where no unit boundary overwrites the value.
    @Test
    func aRestartDoesNotInheritTheEarlierAttemptsFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.fileOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open them", plan: fixture.draftThenOpenTheDraftPlan)
        let first = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(first.chainedArtifactPath == fixture.draftOutput.path)

        // The retry re-plans, as the product does, and this time the plan is a single unit that
        // fails — so nothing completes and nothing overwrites the record's carried file.
        fixture.planner.plan = AgentPlan(
            summary: "Open the page.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "url",
                    operation: .openURL,
                    description: "Open the page.",
                    targetURL: "https://example.com/page"
                )
            ]
        )
        fixture.browserOpener.failure = BrowserOutage()
        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()

        let second = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(second.id == first.id, "one task, one record")
        #expect(second.completedStepIDs.isEmpty)
        #expect(second.chainedArtifactPath == nil, "a restart has completed no unit, so it carries no file")
    }

    /// **F2: "Not now" has to repaint the widget.**
    ///
    /// `dismissedResumeOfferIDs` was a plain `private var`, so the model agreed the offer was gone
    /// and nothing told the view: `objectWillChange` fired zero times and the panel sat there until
    /// the six-second collapse took the whole widget instead of the offer.
    @Test
    func dismissingTheOfferPublishesSoTheWidgetRepaints() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)

        var publishedChanges = 0
        let subscription = fixture.viewModel.objectWillChange.sink { _ in publishedChanges += 1 }
        defer { subscription.cancel() }

        fixture.viewModel.dismissResumeOffer()

        #expect(publishedChanges > 0, "SwiftUI never re-evaluates the widget without a published change")
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
    }

    /// **F5: a task whose remaining work could repeat something Sonny must not do twice is not
    /// offered** — with the control that the identical shape with a safe step is.
    ///
    /// The concrete case: a Shortcut with clean history is tier 1, so a repeated one prompts for
    /// nothing. If it sends a message, the message goes twice.
    @Test
    func aTaskWhoseRemainingWorkCouldRepeatAShortcutIsNotOfferedAndASafeOneIs() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run("Write it up and send it", plan: fixture.draftThenShortcutPlan)

        // The record exists — it is only the *offer* that is withheld, so the user can still see and
        // delete the unfinished task under Memory.
        let record = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(record.remainingSteps.map(\.operation).contains(.invokeShortcut))
        #expect(fixture.viewModel.resumableTasks.count == 1)
        #expect(MemoryRowPresentation.row(for: .resumableTasks, viewModel: fixture.viewModel).count == 1)

        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer == nil, "Sonny does not volunteer to re-send")
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
        // And the belt: nothing can dispatch it even holding the record.
        #expect(!fixture.viewModel.continueResumableTask(record))

        // The control, in the same fixture: the same interruption with a safe remaining step *is*
        // offered, so this is a claim about the Shortcut rather than about the fixture.
        fixture.viewModel.deleteResumableTask(record)
        fixture.browserOpener.failure = BrowserOutage()
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-2.md")
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)
    }

    /// **F10: approving a paused run through to completion clears its record.**
    ///
    /// Cancelling at an approval was covered and approving was not — and the clarification door,
    /// covered the same partial way, is where F1 was hiding. `performApproval` does not re-enter
    /// `performStart`, so the checkpoint survives the pause and the completed terminal settles it.
    @Test
    func approvingAPausedRunThroughToCompletionClearsTheRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run("Overwrite the notes", plan: fixture.approvalNeedingPlan)
        #expect(fixture.viewModel.isAwaitingApproval)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)

        fixture.viewModel.start()
        try await fixture.waitForIdle()

        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil, "the approved run really did complete")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// **F6/M28: a run that records nothing must not append its units to the last run's record.**
    ///
    /// Reachable with the category's switch off: `beginResumableTask` returns early, so the new run
    /// has no checkpoint of its own — and without the clear in `performStart` the *previous* run's
    /// checkpoint would still be live for this run's unit boundaries to write into.
    @Test
    func aRunThatRecordsNothingDoesNotAppendItsStepsToTheLastRunsRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let before = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(before.completedStepIDs == ["draft"])

        // A second, unrelated two-unit run with recording switched off for this store.
        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: false)
        fixture.browserOpener.failure = nil
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-2.md")
        try await fixture.run("Something else entirely")

        let after = try fixture.resumableTaskStore.loadAll()
        #expect(after.count == 1)
        #expect(after.first?.id == before.id)
        #expect(after.first?.command == "Write notes and open the page")
        #expect(after.first?.completedStepIDs == ["draft"], "the second run wrote nothing into it")
        #expect(after.first?.updatedAt == before.updatedAt)
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

    /// **Deleting a record must not be undone by the run it belonged to.**
    ///
    /// The reachable shape: a run pauses at an approval, so its record is on disk and its in-memory
    /// checkpoint is still live; the user deletes it from Memory (that delete is not gated on a
    /// paused run, and should not be — the task is not running); they then approve, and the run goes
    /// on to fail. The failure settle writes the checkpoint back — unless the delete cleared it.
    @Test
    func deletingARecordWhileItsRunIsPausedIsNotUndoneByTheRunFinishing() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Overwrite the notes and open the page", plan: fixture.approvalThenFailingPlan)
        #expect(fixture.viewModel.isAwaitingApproval)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)

        fixture.viewModel.deleteMemoryEntry(in: .resumableTasks, at: 0)
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)

        // Approve. The run does its first unit and fails at the second, which is the settle that
        // would otherwise write the deleted record back.
        fixture.viewModel.start()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.errorMessage != nil, "the approved run really did fail")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// **With "Unfinished tasks" memory off, Sonny raises no offer — and the record is untouched.**
    ///
    /// Founder decision, 2026-08-22, from PR #105's review F9. The asymmetry is the decision:
    /// listing an existing record under Memory is the user going to look, and it has to show them or
    /// a store they switched off becomes one they cannot clear; raising a panel on the widget is
    /// Sonny initiating, unasked, from memory the user has just said to stop keeping.
    ///
    /// Every half is asserted, because "no offer" on its own is equally true of a guard that deleted
    /// the record: the record stays on disk, stays in the published list, stays counted by the
    /// Memory row, is still deletable, and the offer comes back when the switch does.
    @Test
    func withUnfinishedTaskMemoryOffThereIsNoOfferAndTheRecordIsUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // A record written while the switch was on — the case the decision names explicitly.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let record = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: false)

        // No offer, and no panel — the widget renders nothing for it.
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)

        // And nothing else changed. The record is still on disk, still published, still counted by
        // the row, and still deletable — a store switched off must not become one nobody can clear.
        #expect(try fixture.resumableTaskStore.loadAll().map(\.id) == [record.id])
        #expect(fixture.viewModel.resumableTasks.map(\.id) == [record.id])
        #expect(MemoryRowPresentation.row(for: .resumableTasks, viewModel: fixture.viewModel).count == 1)
        #expect(MemoryEntryPresentation.entries(for: .resumableTasks, viewModel: fixture.viewModel).count == 1)

        // Switching it back on brings the offer back, from the same record.
        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: true)
        #expect(fixture.viewModel.resumeOffer?.id == record.id)
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
    }

    /// **"Don't save this task" does not withhold the offer, and that is the other half of F9's
    /// guard.** It is a per-run composer switch about the run being *composed* — a pre-dispatch
    /// toggle, rendered only while `!isTaskInFlight`, which is exactly when the offer is evaluated.
    /// Reading it here would make an unfinished task disappear from the widget because of a switch
    /// the user set for the next command, which is a different statement from the standing Memory
    /// switch that F9 decided.
    @Test
    func dontSaveThisTaskDoesNotWithholdAnOfferAboutARecordAlreadyOnDisk() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let record = try #require(fixture.viewModel.resumeOffer)

        // The user flips "Don't save this task" on while composing the *next* command. Nothing has
        // been dispatched, so this is the window the toggle actually lives in.
        fixture.viewModel.taskRecordingPolicy = .suppressTraces

        #expect(fixture.viewModel.resumeOffer?.id == record.id, "the toggle says nothing about records already on disk")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        // And the standing switch still does withhold it, in the same state — so this is a claim
        // about which switch, not about the offer being ungated.
        fixture.viewModel.setMemoryCategoryEnabled(.resumableTasks, to: false)
        #expect(fixture.viewModel.resumeOffer == nil)
    }

    /// The master switch reaches the offer through the same guard — `isMemoryCategoryEnabled` folds
    /// it — so turning memory off wholesale withholds the panel too, with the record equally intact.
    /// And deleting one while the switch is off still works, which is the half that keeps a
    /// switched-off store clearable.
    @Test
    func theMasterMemorySwitchWithholdsTheOfferAndAnEntryIsStillDeletable() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)

        fixture.viewModel.setMemoryEnabled(false)
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(try fixture.resumableTaskStore.loadAll().count == 1)

        fixture.viewModel.deleteMemoryEntry(in: .resumableTasks, at: 0)

        #expect(try fixture.resumableTaskStore.loadAll().isEmpty)
        #expect(fixture.viewModel.resumableTasks.isEmpty)
        #expect(fixture.viewModel.errorMessage == nil, "a successful delete reports nothing")
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

/// SONNY-248 — answering a clarification keeps the thing the user asked for.
///
/// **The founder's symptom was a label and the defect was the command itself.** After answering a
/// question and quitting mid-run, the widget offered to carry on with *"Clarification question: What
/// should the note say, and which…"* — Sonny naming its own question back. `start()` clears
/// `command` centrally the moment it captures a dispatch, and `submitClarification` then wrapped the
/// question and answer around that now-empty field, so the request was gone from the planner's
/// prompt, from `lastCommand` and from the record behind the offer. It survived because the one
/// question anyone had answered restated the whole task.
///
/// **These live in this file for its fixture**, which is the only one in the target with a planner
/// whose prompts can be read back, a plan that really pauses on a question, and a relaunch over the
/// same store files. The format's own unit tests are `ClarifiedCommandTests`, in the core target.
@Suite(.serialized)
@MainActor
struct ClarificationKeepsTheRequestTests {
    private static let request = "Zip my three largest files"
    private static let question = "Which folder should I scan?"

    /// **The prompt, which is the half that is not a label.** A question that does not restate the
    /// request — this one names no files, no zipping and no count — left the planner with an answer
    /// and nothing to apply it to.
    @Test
    func answeringAClarificationPlansFromTheRequestRatherThanFromTheQuestion() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        #expect(fixture.viewModel.clarificationQuestion == Self.question)
        // The premise, and the control for every "the planner received" assertion below: this run
        // really did reach the planner, with exactly what the user typed.
        #expect(fixture.planner.receivedCommands == [Self.request])

        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands.count == 2)
        let continued = try #require(fixture.planner.receivedCommands.last)
        #expect(continued.hasPrefix(Self.request))
        #expect(continued.contains("Clarification question: \(Self.question)"))
        #expect(continued.contains("Clarification answer: The Desktop"))
        // The defect itself, inverted: the prompt used to *begin* with the question, because the
        // empty `command` was interpolated in front of it.
        #expect(!continued.hasPrefix(ClarifiedCommand.questionLabel))
    }

    /// `lastCommand` is two things at once and they no longer disagree: the text a retry resubmits,
    /// which needs the exchange, and the text Command Center's running indicator shows, which does
    /// not.
    @Test
    func theRetryPayloadKeepsTheExchangeAndTheRunningLabelShowsTheRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        // The retry payload: whole, so retrying a clarified task does not re-ask the question.
        #expect(fixture.viewModel.lastCommand.hasPrefix(Self.request))
        #expect(fixture.viewModel.lastCommand.contains("Clarification answer: The Desktop"))
        // The label: the request alone. Before SONNY-248 this read "Running: Clarification
        // question: …"; the exchange behind it is the planner's business, not a sentence to read.
        #expect(fixture.viewModel.runningCommandDisplayText == Self.request)
    }

    /// **The founder's own repro, end to end**: answer a question, get interrupted, come back, read
    /// the offer. The relaunch is built rather than simulated — a second view model over the same
    /// store files, which is what the next launch is.
    @Test
    func theOfferToCarryOnNamesTheRequestRatherThanTheQuestionSonnyAsked() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        // The interruption: the answered run's second unit fails, so its record is kept.
        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        let relaunched = fixture.makeRelaunchedViewModel()
        relaunched.refreshResumableTasks()
        let offer = try #require(relaunched.resumeOffer)

        #expect(offer.command == Self.request)
        // The literal sentence the widget renders, because the record being right is only half of
        // it — the offer squeezes a command onto one line and cuts it to sixty characters, which is
        // where a short request would otherwise leave room for the exchange to show through.
        #expect(
            ResumeOfferPresentation.message(command: offer.command)
                == "You were partway through \u{201C}\(Self.request)\u{201D}."
        )
        #expect(!ResumeOfferPresentation.message(command: offer.command).contains("Clarification"))
    }

    /// The Tasks list, the follow-up chip and "Run again" all read the history row's command, so it
    /// is the request too — and a row that shows the request re-runs the request rather than a
    /// longer string it never showed.
    @Test
    func theHistoryRowForAClarifiedTaskRecordsTheRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.command == Self.request)
        #expect(fixture.viewModel.priorTaskContext?.previousCommand == Self.request)
    }

    /// **The other overload of the same seam, which nothing held** (PR #109 review F2).
    ///
    /// `recordPriorTaskContext` has two: one for a run that reached a plan and one for a run that did
    /// not. Every other test here reaches the first, because a clarified run that gets as far as a
    /// plan has a `preparedRun` — so reverting the second to the raw command passed the whole suite.
    /// It is reached from `performStart`'s catch when the re-plan itself throws, which is an offline
    /// planner or a missing key, and it wrote the whole prompt into the row and the context.
    @Test
    func aClarifiedRunThatFailsBeforeItPlansStillRecordsTheRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))

        // The re-plan throws: the fixture's planner has no plan to give, so `prepare` fails before
        // `preparedRun` is ever set — the exact state that selects the no-plan overload.
        fixture.planner.plan = nil
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        // The premise: it really did fail, and it really did fail before planning.
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(fixture.viewModel.plan == nil)

        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.command == Self.request)
        #expect(!row.command.contains(ClarifiedCommand.questionLabel))
        #expect(fixture.viewModel.priorTaskContext?.previousCommand == Self.request)
    }

    /// **F1's decision, pinned so the next reader knows it was chosen** (PR #109 review).
    ///
    /// The history row is a label and a payload at once, so the control on that row submits the
    /// thing the row shows. Asserted as the equality rather than as two separate facts, because the
    /// property is that the two agree — a row displaying one string while Run again sends a longer
    /// one is the failure this rules out.
    @Test
    func runningAClarifiedTaskAgainSubmitsExactlyWhatItsRowShows() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        // The run again writes a fresh draft rather than bumping the first one's name.
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(fixture.viewModel.runTaskAgain(row))

        #expect(fixture.viewModel.lastCommand == row.command)
        #expect(fixture.viewModel.lastCommand == Self.request)
        // And the answer is not smuggled along behind the label.
        #expect(!fixture.viewModel.lastCommand.contains("The Desktop"))
        try await fixture.waitForIdle()
    }

    /// **The two-question case, which is the one a naive fix still gets wrong.** `lastCommand` holds
    /// the request after the first `start()` and looks like a source to compose from — but the
    /// clarification's own `start()` overwrites it with what *that* dispatch submitted, so composing
    /// from it would lose the request one level deeper instead of at the first question.
    @Test
    func aTaskClarifiedTwiceKeepsTheRequestAndBothAnswers() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))

        fixture.planner.plan = fixture.clarifyingPlan(question: "Zip them where?")
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "Zip them where?")

        // Paused a second time, and the record behind the offer still names the request — not the
        // request plus one exchange, and not the first question.
        let pausedTwice = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(pausedTwice.command == Self.request)

        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "Into Downloads"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands.count == 3)
        let continued = try #require(fixture.planner.receivedCommands.last)
        #expect(continued.hasPrefix(Self.request))
        #expect(continued.contains("Clarification answer: The Desktop"))
        #expect(continued.contains("Clarification answer: Into Downloads"))
        // Both pairs, in the order the conversation happened — accumulated, not overwritten.
        let first = try #require(continued.range(of: Self.question))
        let second = try #require(continued.range(of: "Zip them where?"))
        #expect(first.lowerBound < second.lowerBound)
    }

    /// **The founder's symptom, reached by a second route — a question that wraps onto two lines**
    /// (PR #109 re-check).
    ///
    /// A planner writes the question and `AgentActionExecutor` only end-trims it, so an interior line
    /// break reaches `composed` intact. Until the fold, that split the question from its answer, the
    /// pair rule stopped matching, and every label went back to carrying the whole prompt — the
    /// original report, arrived at from the other side of the same ticket.
    ///
    /// **What is end-to-end here and what is at the seam, stated rather than blurred.** The labels
    /// are end-to-end: a real run pauses on a wrapped question, a real answer goes through `start()`,
    /// and the record is read back off disk. The resolver half is asserted at the seam
    /// `performStart` actually gates on, because it is not reachable end-to-end — the resolver's own
    /// clarifications are fixed single-line constants, and a command it matches never reaches a
    /// planner that could wrap one.
    @Test
    func aQuestionThatWrapsOntoTwoLinesStillLeavesEveryLabelNamingTheRequest() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let wrapped = "Which folder should I scan?\nDesktop, or Downloads?"

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: wrapped))
        #expect(fixture.viewModel.clarificationQuestion == wrapped, "premise: the question really wraps")

        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        // The running label and the history row.
        #expect(fixture.viewModel.runningCommandDisplayText == Self.request)
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.command == Self.request)

        // The offer, off disk, through a relaunch — the founder's own repro.
        let relaunched = fixture.makeRelaunchedViewModel()
        relaunched.refreshResumableTasks()
        let offer = try #require(relaunched.resumeOffer)
        #expect(offer.command == Self.request)
        #expect(!ResumeOfferPresentation.message(command: offer.command).contains("Clarification"))

        // The seam the resolver term reads, and the planner still got the whole question.
        #expect(ClarifiedCommand.carriesExchange(fixture.viewModel.lastCommand))
        let continued = try #require(fixture.planner.receivedCommands.last)
        #expect(continued.contains("Which folder should I scan?"))
        #expect(continued.contains("Desktop, or Downloads?"))
    }

    /// **A clarified command is not an instant command, and restoring the request is what made that
    /// true.** `InstantCommandResolver` matches on prefixes and raises several of these questions
    /// itself: `=` with nothing after it asks what to calculate. With the request back at the front
    /// of the continuation, the resolver matches its own prefix a second time and would answer with
    /// a calculator plan whose expression is the transcript of the conversation about it.
    ///
    /// Both halves are asserted, because the second one alone cannot show the resolver was ever
    /// involved: the first pause reaches the planner not at all.
    @Test
    func answeringAQuestionTheResolverRaisedGoesToThePlannerRatherThanBackThroughTheResolver() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")
        // The resolver answered this one locally, so the planner was never asked.
        #expect(fixture.planner.receivedCommands.isEmpty)

        fixture.viewModel.clarificationAnswer = "2 + 2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        let continued = try #require(fixture.planner.receivedCommands.last)
        #expect(continued.hasPrefix("="))
        #expect(continued.contains("Clarification answer: 2 + 2"))
        // And the run that followed is the planner's plan, not a calculator plan the resolver built
        // out of the exchange.
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["draft", "url"])
    }

    /// The abandoned-question exit takes the held request with it: nothing is going to resume, so a
    /// request surviving into the next run would be the leak the pause's other carried values are
    /// cleared to prevent.
    @Test
    func abandoningAQuestionDoesNotLeaveTheRequestBehindForTheNextOne() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.viewModel.cancelCurrentRun()
        #expect(fixture.viewModel.clarificationQuestion == nil)

        // A different task, clarified by hand rather than by a run — so nothing sets the held
        // request, and the abandoned one is the only thing that could supply a prefix.
        fixture.viewModel.clarificationQuestion = "Which of these did you mean?"
        fixture.viewModel.clarificationAnswer = "The second one"
        fixture.viewModel.submitClarification()

        #expect(!fixture.viewModel.lastCommand.contains(Self.request))
        #expect(fixture.viewModel.lastCommand.hasPrefix(ClarifiedCommand.questionLabel))
    }

    /// The same clear, on the door that *answers* rather than abandons (PR #109 review F6, R2).
    ///
    /// `submitClarification` clears the held request before re-entering `start()`, and that line
    /// could be deleted with the suite green: the answered run's own pause would overwrite the field
    /// and the abandon path clears it, so nothing read a stale value on a live path. It is
    /// defence-in-depth, and this is what holds it — the field belongs to the pause that set it and
    /// must not reach a second one.
    ///
    /// **Stated plainly: the second question here is set by hand.** A question raised without a run
    /// behind it is a test construction, the same device the clarification-gate suites use. What is
    /// pinned is the clear, not the reachability of the state that exposes it.
    @Test
    func answeringAQuestionDoesNotLeaveTheRequestBehindForTheNextOneEither() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run(Self.request, plan: fixture.clarifyingPlan(question: Self.question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.lastCommand.hasPrefix(Self.request), "premise: the answered run carried it")

        fixture.viewModel.clarificationQuestion = "Which of these did you mean?"
        fixture.viewModel.clarificationAnswer = "The second one"
        fixture.viewModel.submitClarification()

        #expect(!fixture.viewModel.lastCommand.contains(Self.request))
        #expect(fixture.viewModel.lastCommand.hasPrefix(ClarifiedCommand.questionLabel))
        try await fixture.waitForIdle()
    }
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
private final class FailableFileOpener: FileOpening {
    var failure: (any Error)?
    private(set) var opened: [String] = []

    func openFile(_ url: URL) async throws {
        opened.append(url.path)
        if let failure {
            throw failure
        }
    }
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
    /// Every prompt this planner was handed, in order.
    ///
    /// SONNY-248's: the defect was that a clarified run reached the planner with the user's request
    /// missing, and the planner's own prompt is the only place that is directly observable. It is
    /// also the control for the instant resolver — a command the resolver answers locally arrives
    /// here not at all, so an empty list is a measurement rather than an absence.
    private(set) var receivedCommands: [String] = []

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        receivedCommands.append(command)
        guard let plan else {
            throw PlannerError.missingAPIKey
        }
        return plan
    }
}

/// Names exactly the one Shortcut the F5 test's plan invokes, so that plan reaches the Shortcut unit
/// rather than being converted into a "which Shortcut did you mean?" clarification by
/// `AgentActionExecutor.prepare`. Measured: with an empty catalog the stored plan is a one-step
/// `clarify` and the test asserts nothing about a Shortcut at all.
private struct OneShortcutForResumeTests: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { ["Send Report"] }
}

/// Fails the Shortcut unit so the run stops there — the interruption the offer is asked about. The
/// Shortcut is never really run: this suite must not shell out to the developer's own Shortcuts.
@MainActor
private final class FailableShortcutInvoker: ShortcutInvoking {
    nonisolated func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        throw BrowserOutage()
    }
}

@MainActor
private final class ResumableFixture {
    let viewModel: AgentViewModel
    /// Builds another view model over this fixture's *same* store files — a relaunch, as far as
    /// anything on disk is concerned. Held as a closure so the construction lives once, beside the
    /// original, rather than being copied into a test.
    let makeRelaunchedViewModel: @MainActor () -> AgentViewModel
    let root: URL
    let resumableTaskStore: ResumableTaskStore
    let routineStore: RoutineStore
    let planner: ResumableFixturePlanner
    let browserOpener: FailableBrowserOpener
    let fileOpener: FailableFileOpener
    let userDefaults: UserDefaults
    let suiteName: String
    /// Where the next draft unit writes. Reassigned between runs in a test that runs the same plan
    /// twice, so the second run's first unit is a fresh write rather than a bumped name.
    var draftOutput: URL

    init(
        viewModel: AgentViewModel,
        makeRelaunchedViewModel: @escaping @MainActor () -> AgentViewModel,
        root: URL,
        resumableTaskStore: ResumableTaskStore,
        routineStore: RoutineStore,
        planner: ResumableFixturePlanner,
        browserOpener: FailableBrowserOpener,
        fileOpener: FailableFileOpener,
        userDefaults: UserDefaults,
        suiteName: String,
        draftOutput: URL
    ) {
        self.viewModel = viewModel
        self.makeRelaunchedViewModel = makeRelaunchedViewModel
        self.root = root
        self.resumableTaskStore = resumableTaskStore
        self.routineStore = routineStore
        self.planner = planner
        self.browserOpener = browserOpener
        self.fileOpener = fileOpener
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

    /// Two units where the second *consumes* what the first wrote: the draft, then opening it with
    /// no path of its own. The chain fills that path in from the previous unit — which is the one
    /// thing a resumed run cannot re-derive from the steps it has left.
    var draftThenOpenTheDraftPlan: AgentPlan {
        AgentPlan(
            summary: "Write notes, then open them.",
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
                AgentStep(id: "open", operation: .openGeneratedArtifact, description: "Open them.")
            ]
        )
    }

    /// An overwrite of a file that already exists — tier 3, so it pauses at an approval — followed by
    /// a second unit the browser can be made to fail. Approving it therefore runs one unit and stops
    /// at the next.
    var approvalThenFailingPlan: AgentPlan {
        let occupied = root.appendingPathComponent("already-there.md")
        try? Data("existing".utf8).write(to: occupied, options: .atomic)
        return AgentPlan(
            summary: "Overwrite the notes, then open the page.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Overwrite them.",
                    outputPath: occupied.path,
                    draftTitle: "Notes",
                    draftContent: "Replacement."
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

    /// Two units where the second is something Sonny cannot see inside — the review's own
    /// counterexample. The Shortcut is never invoked in these tests: the fixture's catalog is empty,
    /// so the run fails at that unit, which is exactly the interruption the offer is asked about.
    var draftThenShortcutPlan: AgentPlan {
        AgentPlan(
            summary: "Write it up, then send it.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Write it up.",
                    outputPath: draftOutput.path,
                    draftTitle: "Notes",
                    draftContent: "Body."
                ),
                AgentStep(
                    id: "send",
                    operation: .invokeShortcut,
                    description: "Send it.",
                    shortcutName: "Send Report"
                )
            ]
        )
    }

    var clarifyingPlan: AgentPlan {
        clarifyingPlan(question: "Which folder did you mean?")
    }

    /// The same plan with a question of the test's choosing, so a task can be clarified twice and
    /// the two pauses told apart (SONNY-248).
    func clarifyingPlan(question: String) -> AgentPlan {
        AgentPlan(
            summary: "Ask first.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "ask",
                    operation: .clarify,
                    description: "Ask.",
                    question: question
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
    func waitForIdle(_ target: AgentViewModel? = nil, timeout: TimeInterval = 30) async throws {
        let waited = target ?? viewModel
        let deadline = Date(timeIntervalSinceNow: timeout)
        while waited.isRunning {
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
    let fileOpener = FailableFileOpener()
    let resumableTaskStore = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json")
    )
    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

    // One construction, called twice: once for this fixture's own view model and again by
    // `makeRelaunchedViewModel()` when a test needs the next launch over the same files.
    let build: @MainActor () -> AgentViewModel = {
        AgentViewModel(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
            shortcutCatalog: OneShortcutForResumeTests(),
            // Hermetic seams, defined in ProductShellTests.swift in this same target — except the browser,
            // which is this suite's own failure switch.
            browserOpener: browserOpener,
            appOpener: HermeticAppOpener(),
            fileOpener: fileOpener,
            mediaOpener: HermeticMediaOpener(),
            runningAppSwitcher: HermeticRunningAppSwitcher(),
            shortcutInvoker: FailableShortcutInvoker(),
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
            // SONNY-209's store, at this fixture's own root, and with the same whitelist the view
            // model gets so the store answers "is this an output location" against the folders the
            // run really used. Omitting it is no longer possible — SONNY-240 removed every store
            // default from the initializer — but naming no `fileURL` still writes to the real
            // ~/Library path with a key the packaged app cannot read, which is what
            // `LocalStoreInjectionScanTests` covers.
            outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            whitelist: PathWhitelist(roots: [root])
            ),
            resumableTaskStore: resumableTaskStore,
            clipboardHistoryMonitor: ClipboardHistoryMonitor(
                reader: HermeticPasteboardReader(),
                store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
                settingsStore: ClipboardHistorySettingsStore(
                    fileURL: root.appendingPathComponent("clipboard-history-settings.json")
                )
            ),
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
    }

    return ResumableFixture(
        viewModel: build(),
        makeRelaunchedViewModel: build,
        root: root,
        resumableTaskStore: resumableTaskStore,
        routineStore: routineStore,
        planner: planner,
        browserOpener: browserOpener,
        fileOpener: fileOpener,
        userDefaults: userDefaults,
        suiteName: suiteName,
        draftOutput: root.appendingPathComponent("notes.md")
    )
}
