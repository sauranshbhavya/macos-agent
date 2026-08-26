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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
        try await fixture.waitForIdle()

        let second = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(second.chainedArtifactPath == fixture.draftOutput.path, "the carried file survives the resume")

        // And the third attempt still works, which is what the carried value buys.
        fixture.fileOpener.failure = nil
        let secondOffer = try #require(fixture.viewModel.resumeOffer)
        #expect(fixture.viewModel.continueResumableTask(secondOffer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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
        #expect(fixture.viewModel.continueResumableTask(offer, origin: .widget))
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

    /// **F2: the cross has to repaint the widget.**
    ///
    /// `declinedResumeOfferIDs` (then `dismissedResumeOfferIDs`) was a plain `private var`, so the
    /// model agreed the offer was gone and nothing told the view: `objectWillChange` fired zero
    /// times and the panel sat there until the six-second collapse took the whole widget instead of
    /// the offer.
    @Test
    func decliningTheOfferPublishesSoTheWidgetRepaints() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        #expect(fixture.viewModel.resumeOffer != nil)

        var publishedChanges = 0
        let subscription = fixture.viewModel.objectWillChange.sink { _ in publishedChanges += 1 }
        defer { subscription.cancel() }

        fixture.viewModel.declineResumeOffer()

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
        #expect(!fixture.viewModel.continueResumableTask(record, origin: .widget))

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

    /// **The cross stops the offer for good and deletes nothing** (SONNY-282, founder decision
    /// 2026-08-25).
    ///
    /// The defect, as the founder met it: cross, relaunch, cross, relaunch, cross — the offer came
    /// back every time, because a dismissal was session-scoped by design. So the assertion that
    /// matters here is the one over three relaunches, each a fresh view model over the same file
    /// with no session state at all. Everything the founder explicitly kept is asserted beside it:
    /// the record is on disk, its idle clock is untouched (a decline is not activity on the task),
    /// it is still listed under Memory with the state on its row, and the row still offers to
    /// continue it.
    @Test
    func decliningTheOfferKeepsTheRecordAndTheOfferStaysGoneAcrossRelaunches() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        // Back-date the idle clock an hour, leaving the record inside its idle period, for the
        // reason `aTaskInterruptedTwiceStaysOneRecordWithItsOriginalStartTime` gives: the store
        // encodes dates at whole-second resolution, so a decline that *did* bump `updatedAt` inside
        // the same second as the run's own write would be invisible to a same-value comparison.
        let asWritten = try #require(try fixture.resumableTaskStore.loadAll().first)
        var backdated = asWritten
        backdated.updatedAt = asWritten.updatedAt.addingTimeInterval(-3_600)
        try fixture.resumableTaskStore.save(backdated)
        fixture.viewModel.refreshResumableTasks()
        let offered = try #require(fixture.viewModel.resumeOffer)
        #expect(!offered.isDeclined)
        #expect(offered.updatedAt == backdated.updatedAt)

        fixture.viewModel.declineResumeOffer()

        // This launch.
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.errorMessage == nil, "the write succeeded, so there is nothing to say")

        // The record: kept, declined, otherwise exactly as it was.
        let onDisk = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(onDisk.id == offered.id)
        #expect(onDisk.isDeclined)
        #expect(onDisk.updatedAt == backdated.updatedAt, "declining is not activity on the task and buys it no idle period")
        #expect(onDisk.declinedAt.map { $0 > backdated.updatedAt } == true, "the decline carries its own, later, date")
        #expect(onDisk.completedStepIDs == offered.completedStepIDs)
        #expect(onDisk.stopReason == offered.stopReason)

        // Memory: still listed, still counted, the state on the row, and a Continue beside Delete.
        #expect(fixture.viewModel.resumableTasks.map(\.id) == [offered.id])
        #expect(MemoryRowPresentation.row(for: .resumableTasks, viewModel: fixture.viewModel).count == 1)
        let entry = try #require(MemoryEntryPresentation.entries(for: .resumableTasks, viewModel: fixture.viewModel).first)
        #expect(entry.detail.hasPrefix("Stopped by an error · 1 of 2 steps left · Declined · "))
        #expect(entry.canContinue)

        // The launches after it — the whole of what the founder asked for.
        for launch in 1...3 {
            let relaunched = fixture.makeRelaunchedViewModel()
            relaunched.refreshResumableTasks()
            #expect(relaunched.resumeOffer == nil, "launch \(launch): the offer must not return")
            #expect(!relaunched.hasVisibleWidgetPanel, "launch \(launch)")
            #expect(relaunched.resumableTasks.map(\.id) == [offered.id], "launch \(launch): the record is still there")
        }
    }

    /// **A declined task is continued from Memory — the door the decision needs, and one that did
    /// not exist before SONNY-282** (the sheet only deleted). It runs only what was left, the record
    /// is cleared when it finishes, and the origin is Command Center's. The refusals beside it: an
    /// index past the list, and a record Sonny must not finish on its own, whose row offers no
    /// Continue at all.
    @Test
    func aDeclinedTaskIsContinuedFromMemoryAndRunsOnlyWhatWasLeft() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        fixture.viewModel.declineResumeOffer()
        #expect(fixture.viewModel.resumeOffer == nil)
        #expect(try #require(try fixture.resumableTaskStore.loadAll().first).isDeclined)

        // Out of range is a refusal, not a crash.
        #expect(!fixture.viewModel.continueUnfinishedTask(at: 5))

        fixture.browserOpener.failure = nil
        #expect(fixture.viewModel.continueUnfinishedTask(at: 0))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.activeTaskOrigin == .commandCenter, "pressed in Command Center, so that is its origin")
        #expect(fixture.viewModel.activeTaskPlanSource == .resumedTask)
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["url"], "only the remaining step ran")
        #expect(fixture.browserOpener.opened == ["https://example.com/page", "https://example.com/page"])
        let written = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix("notes") }
        #expect(written == ["notes.md"], "the finished unit did not run again")
        #expect(try fixture.resumableTaskStore.loadAll().isEmpty, "finished, so the record is gone")
        #expect(fixture.viewModel.resumeOffer == nil)

        // The row's Continue follows the safety rule the offer does: a remainder Sonny must not
        // repeat on its own gets no Continue, and the door refuses it if asked anyway.
        try await fixture.run("Write it up and send it", plan: fixture.draftThenShortcutPlan)
        let withheld = try #require(MemoryEntryPresentation.entries(for: .resumableTasks, viewModel: fixture.viewModel).first)
        #expect(!withheld.canContinue)
        #expect(!fixture.viewModel.continueUnfinishedTask(at: 0))
    }

    /// **A declined task the user picks up again and that stops again is offered again.** Declining
    /// answers the offer for the task as it stood; continuing it from Memory is the user
    /// re-engaging, and `beginResumableTask` writes the record afresh with no decline on it — so
    /// the session set has to drop the id too, or the disk and the widget disagree until the next
    /// launch. The control is the same task left alone, which stays declined.
    @Test
    func aDeclinedTaskContinuedAndInterruptedAgainIsOfferedAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let offered = try #require(fixture.viewModel.resumeOffer)
        fixture.viewModel.declineResumeOffer()
        #expect(fixture.viewModel.resumeOffer == nil)

        // Continued with the browser still down: the remaining unit fails again.
        #expect(fixture.viewModel.continueUnfinishedTask(at: 0))
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.errorMessage != nil, "the continued run really did fail again")
        fixture.viewModel.clearStaleTaskOutcome()

        let again = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(again.id == offered.id, "one task, one record")
        #expect(!again.isDeclined, "re-engaging with the task starts its record afresh")
        #expect(fixture.viewModel.resumeOffer?.id == offered.id, "and the widget offers it again this session")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
    }

    /// **PR #119 review, F2 — the two restart doors spend the decline too, so this session's widget
    /// and the disk agree whichever door was used.** `continueResumableTask` used to be the only
    /// site that dropped the id from the session set, while `retryLastCommand` and `runTaskAgain`
    /// reached `beginResumableTask` directly — which wrote the record back undeclined and left the
    /// widget silent until the next launch. The remove now lives in `beginResumableTask`, the one
    /// site that writes a record afresh. Tested through the two doors that were wrong, not the one
    /// that already worked.
    @Test
    func aDeclinedTaskRetriedOrRunAgainAndFailingAgainIsOfferedAgainThisSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let offered = try #require(fixture.viewModel.resumeOffer)
        fixture.viewModel.declineResumeOffer()
        #expect(fixture.viewModel.resumeOffer == nil)

        // The failure panel's Retry, with the browser still down.
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-retry.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.errorMessage != nil, "the retry really did fail again")
        fixture.viewModel.clearStaleTaskOutcome()

        let afterRetry = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(afterRetry.id == offered.id, "one task, one record")
        #expect(!afterRetry.isDeclined, "the disk says offer it")
        #expect(fixture.viewModel.resumeOffer?.id == offered.id, "and so does this session — the defect was silence here")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        // Decline again, then Run again from the task's own Tasks row.
        fixture.viewModel.declineResumeOffer()
        #expect(fixture.viewModel.resumeOffer == nil)
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.resumableTaskID == offered.id, "the row links to the declined record")
        fixture.draftOutput = fixture.root.appendingPathComponent("notes-again.md")
        fixture.planner.plan = fixture.draftThenOpenPlan
        #expect(fixture.viewModel.runTaskAgain(row))
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.errorMessage != nil, "and failed again")
        fixture.viewModel.clearStaleTaskOutcome()

        let afterRunAgain = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(afterRunAgain.id == offered.id)
        #expect(!afterRunAgain.isDeclined)
        #expect(fixture.viewModel.resumeOffer?.id == offered.id)
    }

    /// **When the decline cannot be written, the offer still leaves for this session, the user is
    /// told it may return, and it does return at the next launch** — the honest degradation, and
    /// the reason the session set survives alongside the persisted flag. Made real by taking write
    /// permission off the store's directory, so the atomic write fails where the product's would.
    @Test
    func aDeclineThatCannotBeSavedStillHidesTheOfferThisSessionAndSaysSo() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let offered = try #require(fixture.viewModel.resumeOffer)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path) }

        fixture.viewModel.declineResumeOffer()

        #expect(fixture.viewModel.resumeOffer == nil, "the press is honoured for this session whatever the disk did")
        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message.contains("could not save that you declined this task"))
        #expect(message.contains("after a relaunch"))
        #expect(!fixture.viewModel.errorIsPersistent, "a failed save is not a configuration problem")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        let onDisk = try #require(try fixture.resumableTaskStore.loadAll().first)
        #expect(onDisk.id == offered.id)
        #expect(!onDisk.isDeclined, "nothing reached the disk")

        // And the consequence the message warned about is real: the next launch offers it.
        let relaunched = fixture.makeRelaunchedViewModel()
        relaunched.refreshResumableTasks()
        #expect(relaunched.resumeOffer?.id == offered.id)
    }

    /// **Declining picks the next record, not no record.** Two unfinished tasks, the newer one
    /// declined: the offer moves to the older one rather than going silent while an offerable task
    /// sits on disk.
    @Test
    func decliningOneOfferMovesToTheNextUnfinishedTask() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        fixture.browserOpener.failure = BrowserOutage()
        try await fixture.run("Write notes and open the page")
        let first = try #require(try fixture.resumableTaskStore.loadAll().first)
        // Age the first one so the second is unambiguously the newer, whatever the clock does.
        var older = first
        older.updatedAt = first.updatedAt.addingTimeInterval(-3_600)
        try fixture.resumableTaskStore.save(older)

        fixture.draftOutput = fixture.root.appendingPathComponent("notes-second.md")
        try await fixture.run("Write different notes and open the page")
        fixture.viewModel.clearStaleTaskOutcome()
        let newer = try #require(fixture.viewModel.resumeOffer)
        #expect(newer.command == "Write different notes and open the page")

        fixture.viewModel.declineResumeOffer()

        #expect(fixture.viewModel.resumeOffer?.id == first.id, "the older unfinished task is offered next")
        #expect(fixture.viewModel.resumableTasks.count == 2, "both are still listed")
        #expect(fixture.viewModel.resumableTasks.filter(\.isDeclined).map(\.id) == [newer.id])
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

/// Which door a clarification answer goes through, and the capture that settled it (SONNY-281).
///
/// The founder's report was three inputs with three outcomes on the packaged app: `2 + 2` answered
/// `4`; `2 + 2 =` refused as "unsupported by the registered local tools"; `=` alone, answered
/// `2 + 2` when Sonny asked what to calculate, refused the same way. The ticket's first question was
/// whether a clarified command reaches the planner in a different shape from the same text typed
/// directly, and it asked for the prompts to be **captured rather than reasoned about**.
/// `ResumableFixturePlanner.receivedCommands` is that capture: every prompt the planner was handed,
/// verbatim, and an empty list when the resolver answered locally and the planner was never asked.
///
/// **What the capture showed.** Typed directly, `2 + 2` never reaches a planner at all — the
/// resolver's bare-arithmetic rule answers it, and the planner cannot: `CalculatorCapabilityAdapter`
/// declares `plannerTools: []`, so the calculator is not among the registered tools the planner is
/// told about, and "unsupported by the registered local tools" is the planner complying with its
/// own rules about a request it was never meant to see. Both refusals were therefore the same
/// defect — a calculation routed to the planner — reached by two routing rules: the trailing `=`
/// fell outside the bare-arithmetic rule's character set, and a clarified command skipped the
/// resolver entirely, by SONNY-248's design, whichever surface had asked the question.
///
/// **The fix is at the doors, not in the planner.** A trailing `=` is part of what a sum looks
/// like (`CalculatorService.withoutTrailingEqualsOrQuestionMark`), and an answer to a question the
/// *resolver* asked first completes the command the resolver was missing (`ClarifiedCommand.completed`)
/// — dispatched as a plain command, through the same door typed text goes through, when the
/// resolver answers the completed command with a plan and the executor's dry run prepares it. A
/// question the *planner* asked still goes to the planner with the request and the exchange, which
/// `ClarificationKeepsTheRequestTests` holds. PR #118's review moved the gate off the run's
/// `PreparedPlanSource` and onto the question itself (F1, the Continue door) and put the joined
/// reading ahead of the restatement (F2, the Writer case); both are pinned below.
@Suite(.serialized)
@MainActor
struct ClarificationAnswerRoutingTests {
    /// **The two prompts, captured.** Typed directly, the planner receives the text itself and
    /// nothing else. Answered to a question the *planner* asked, it receives the request followed
    /// by the exchange — `ClarifiedCommand.composed`'s output, asserted as equality against the
    /// composer so that the difference between the two prompts is exactly the exchange and nothing
    /// else. That difference is SONNY-248's design and is not the defect: the planner has to read
    /// its own question and the answer, and the request is whole at the front of both.
    @Test
    func typedDirectlyThePlannerGetsTheTextAndAnsweredItGetsTheTextThenTheExchange() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        let request = "Zip my three largest files"
        let question = "Which folder should I scan?"

        try await fixture.run(request)
        #expect(fixture.planner.receivedCommands == [request])

        try await fixture.run(request, plan: fixture.clarifyingPlan(question: question))
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "The Desktop"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands == [
            request,
            request,
            ClarifiedCommand.composed(request: request, question: question, answer: "The Desktop")
        ])
    }

    /// **The founder's first two inputs, side by side.** `2 + 2` is answered by the local calculator
    /// and the planner is never asked; `2 + 2 =` is the same sum with the sign a person types at the
    /// end of one, and it gets the same answer from the same place. It used to fall off the
    /// bare-arithmetic rule on that one character and reach a planner with no calculator to offer.
    @Test
    func arithmeticWithATrailingEqualsSignIsAnsweredLocallyLikeTheSameArithmeticWithoutIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        try await fixture.run("2 + 2")
        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        #expect(fixture.planner.receivedCommands.isEmpty)

        try await fixture.run("2 + 2 =")
        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        // Captured, not inferred: the planner was handed nothing for either.
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **The founder's third input, and the ticket's own case.** `=` alone makes the resolver ask
    /// what to calculate. The answer completes the command the resolver was missing — `= 2 + 2` —
    /// and the resolver answers it, exactly as if that had been typed. Before this the answer was
    /// composed into an exchange the resolver is not allowed to read (SONNY-248's rule, and still
    /// the rule for a question the *planner* asked) and sent to a planner that cannot calculate.
    @Test
    func answeringWhatToCalculateCompletesTheCommandAndTheCalculatorAnswersIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")
        #expect(fixture.planner.receivedCommands.isEmpty)

        fixture.viewModel.clarificationAnswer = "2 + 2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.planner.receivedCommands == [])
        // The command that ran is the completed one — a plain command with no exchange in it — so
        // the retry payload, the running label and the history row are one string and all say it.
        #expect(fixture.viewModel.lastCommand == "= 2 + 2")
        #expect(!ClarifiedCommand.carriesExchange(fixture.viewModel.lastCommand))
        #expect(fixture.viewModel.runningCommandDisplayText == "= 2 + 2")
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)
        #expect(row.command == "= 2 + 2")
        #expect(row.outcomeStatus == .completed)
    }

    /// The other doors resubmit the completed command and get the same answer: Run again on the
    /// history row, and the retry control. Neither knows the command was ever a question and an
    /// answer, which is the point of completing it into a plain string.
    @Test
    func runningACompletedCalculationAgainIsTheCalculationAgain() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        fixture.viewModel.clarificationAnswer = "2 + 2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()
        let row = try #require(fixture.viewModel.taskHistoryRecords.first)

        #expect(fixture.viewModel.runTaskAgain(row))
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.lastCommand == "= 2 + 2")
        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        #expect(fixture.viewModel.clarificationQuestion == nil)

        fixture.viewModel.retryLastCommand()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        #expect(fixture.planner.receivedCommands == [])
    }

    /// An answer that writes the whole command out is taken as the whole command. The resolver's
    /// questions are raised on a bare prefix, so a user who answers `calc` with `Calc 2 + 2` has
    /// restated the prefix, not asked for `calc Calc 2 + 2` — which is tried first (PR #118 review
    /// F2), resolves to a calculator plan, and fails the dry run's evaluation, so the answer alone
    /// is what runs.
    @Test
    func anAnswerThatRestatesTheCommandIsTakenAsTheWholeCommand() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "calc"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")

        fixture.viewModel.clarificationAnswer = "Calc 2 + 2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.")
        #expect(fixture.viewModel.lastCommand == "Calc 2 + 2")
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **Not every resolver question asks for the rest of the command, and the completion is
    /// checked rather than assumed.** "I could not find a Shortcut named Foo. Which Shortcut should
    /// I run?" wants a replacement, not a suffix: `run shortcut Foo Send Report` names no Shortcut
    /// either, so the completion does not resolve to a plan, and the answer goes where it went
    /// before — to the planner, with the request and the exchange, where a question that needs
    /// reading gets read.
    @Test
    func aResolverQuestionWhoseAnswerDoesNotCompleteTheCommandStillReachesThePlannerWithTheExchange() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "run shortcut Foo"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        let question = try #require(fixture.viewModel.clarificationQuestion)
        #expect(question.hasPrefix("I could not find a Shortcut named Foo."))
        #expect(fixture.planner.receivedCommands.isEmpty)

        fixture.viewModel.clarificationAnswer = "Send Report"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands == [
            ClarifiedCommand.composed(request: "run shortcut Foo", question: question, answer: "Send Report")
        ])
        // And the run that followed is the planner's plan.
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["draft", "url"])
    }

    /// **A question the planner asked is the planner's to read, even when the answer would complete
    /// something local.** A routine saved as "morning routine", a request of "morning" the planner
    /// asked about, an answer of "routine": stitched together they name the routine exactly, and a
    /// bare saved name is an instant command. Running it would act on a guess about what a planner's
    /// question meant. So the completion is offered only when the resolver, asked again about the
    /// request, raises the pending question — and it raises none about "morning" — so this exchange
    /// reaches the planner whole.
    @Test
    func aPlannerQuestionIsNeverCompletedLocallyEvenWhenTheCompletionWouldResolve() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        try fixture.routineStore.save(
            StoredRoutine(
                name: "morning routine",
                steps: [
                    AgentStep(id: "calc", operation: .calculateUtility, description: "Add them up.", searchQuery: "2 + 2")
                ]
            )
        )
        // The premise: stitched together, the request and the answer are an instant command.
        guard case .plan? = fixture.viewModel.makeInstantCommandResolver().resolve(command: "morning routine") else {
            Issue.record("premise: \"morning routine\" should resolve locally to the saved routine")
            return
        }

        let question = "What would you like to do this morning?"
        try await fixture.run("morning", plan: fixture.clarifyingPlan(question: question))
        #expect(fixture.viewModel.clarificationQuestion == question)
        // The premise the gate reads: the resolver has no question of its own about "morning".
        #expect(fixture.viewModel.makeInstantCommandResolver().resolve(command: "morning") == nil)
        #expect(fixture.planner.receivedCommands == ["morning"])

        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.viewModel.clarificationAnswer = "routine"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands == [
            "morning",
            ClarifiedCommand.composed(request: "morning", question: question, answer: "routine")
        ])
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["draft", "url"])
    }
    /// **The founder's repro, one door over** (PR #118 review, F1). Quit while Sonny is asking
    /// what to calculate, relaunch, press Continue, answer `2 + 2`. The Continue door replays the
    /// paused plan under `.resumedTask`, so a gate reading `activeTaskPlanSource == .instantResolver`
    /// sent this answer down the planner path — the original refusal, reproduced at runtime. The
    /// gate reads the question now: `=` resolved again asks exactly this, so the answer is the
    /// resolver's whichever door re-asked it. The relaunch is built rather than simulated — a second
    /// view model over the same store files, which is what the next launch is.
    @Test
    func answeringAfterQuitAndContinueStillCompletesTheCommandForTheResolver() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")

        // The quit: nothing is settled, so the record is still on disk for the next launch.
        let relaunched = fixture.makeRelaunchedViewModel()
        relaunched.refreshResumableTasks()
        let offer = try #require(relaunched.resumeOffer)
        #expect(offer.command == "=")
        #expect(relaunched.continueResumableTask(offer, origin: .widget))
        try await fixture.waitForIdle(relaunched)
        #expect(relaunched.clarificationQuestion == "What would you like me to calculate?")
        // The premise the first gate got wrong: this pause was raised by a resumed plan.
        #expect(relaunched.activeTaskPlanSource == .resumedTask)

        relaunched.clarificationAnswer = "2 + 2"
        relaunched.submitClarification()
        try await fixture.waitForIdle(relaunched)

        #expect(relaunched.finalSummary == "2 + 2 = 4.")
        #expect(relaunched.lastCommand == "= 2 + 2")
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **An answer that merely begins with the request is read as the operand first** (PR #118
    /// review, F2). `focus` answered `Focus Writer` passes a restatement test by coincidence, and
    /// read that way Sonny switches to an app called Writer, which nobody named. Both apps are
    /// running here, so the wrong reading would have worked — the join is tried first because it is
    /// the reading that acts on what the user named, and it is taken when it prepares.
    @Test
    func anAnswerThatOnlyLooksLikeARestatementIsReadAsTheOperandFirst() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.runningAppSwitcher.apps = [
            RunningApp(displayName: "Writer", bundleIdentifier: "com.example.writer", processIdentifier: 101),
            RunningApp(displayName: "Focus Writer", bundleIdentifier: "com.example.focuswriter", processIdentifier: 102)
        ]

        fixture.viewModel.command = "focus"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "Which running app should I switch to?")

        fixture.viewModel.clarificationAnswer = "Focus Writer"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.lastCommand == "focus Focus Writer")
        #expect(fixture.runningAppSwitcher.activated == ["com.example.focuswriter"])
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **The restatement is the fallback, and it is reached through `prepare`, not through
    /// resolution** (PR #118 review, F2). `=` answered `=2+2` joins to `= =2+2`, which the resolver
    /// happily plans — it builds a calculator plan for any non-empty expression — and which the
    /// executor's dry run refuses, because previewing a calculation evaluates it. Only then is the
    /// answer taken whole, and it answers 4. A check on resolution alone would have dispatched the
    /// join and shown the user a parse error.
    @Test
    func anAnswerThatRestatesTheCommandIsTakenWholeWhenTheJoinResolvesButDoesNotPrepare() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        // The premise: the join really does resolve, so resolution cannot be what rejects it.
        guard case .plan? = fixture.viewModel.makeInstantCommandResolver().resolve(command: "= =2+2") else {
            Issue.record("premise: \"= =2+2\" should resolve to a calculator plan")
            return
        }

        fixture.viewModel.clarificationAnswer = "=2+2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.finalSummary == "2+2 = 4.")
        #expect(fixture.viewModel.lastCommand == "=2+2")
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **A spoken answer to a question the resolver asked runs end to end: SONNY-283's routing into
    /// SONNY-281's completion** (PR #119 review's rebase note — the gap neither branch's suite
    /// covered, owed by the branch that merged second). The resolver asks what to calculate; the
    /// transcript is recorded for *that* question, delivered to the answer field rather than
    /// dispatched, Send comes back, and `submitClarification` hands the field's text to
    /// `locallyCompletedCommand` — so the calculator answers it and the planner is never asked.
    /// Both of #118's candidate readings are driven: spoken as the operand, the join `= 2 + 2`
    /// prepares and runs; spoken as a restatement with the sign in it, the join `= = 2 + 2`
    /// resolves and fails the dry run, so the answer is taken whole and runs.
    @Test
    func aSpokenAnswerToWhatToCalculateIsCompletedLocallyAndTheCalculatorAnswersIt() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        for spoken in ["2 + 2", "= 2 + 2"] {
            fixture.viewModel.command = "="
            fixture.viewModel.start(origin: .widget)
            try await fixture.waitForIdle()
            let question = try #require(fixture.viewModel.clarificationQuestion)
            #expect(question == "What would you like me to calculate?")
            #expect(fixture.viewModel.clarificationAnswer.isEmpty)

            // The transcript, recorded for the resolver's own question and delivered through the
            // router — fed, not sent.
            fixture.viewModel.deliverTranscript(
                spoken,
                recordedFor: .clarificationAnswer(question: question),
                origin: .widget
            )
            #expect(fixture.viewModel.clarificationAnswer == spoken, "\(spoken): landed in the field")
            #expect(fixture.viewModel.clarificationQuestion == question, "\(spoken): not sent by landing")
            #expect(fixture.viewModel.lastCommand == "=", "\(spoken): nothing dispatched by landing")
            #expect(fixture.viewModel.canSendClarificationAnswer, "\(spoken): Send is live once the transcript is in")

            fixture.viewModel.submitClarification()
            try await fixture.waitForIdle()

            #expect(fixture.viewModel.clarificationQuestion == nil, "\(spoken)")
            #expect(fixture.viewModel.finalSummary == "2 + 2 = 4.", "\(spoken): the calculator answered")
            #expect(fixture.viewModel.lastCommand == "= 2 + 2", "\(spoken): the completed command is what ran")
            #expect(fixture.viewModel.errorMessage == nil, "\(spoken)")
            #expect(fixture.viewModel.activeTaskOrigin == .widget, "\(spoken): the origin survived the pause")
            // Captured, not inferred: the planner was never asked, so the answer went through
            // SONNY-281's completion and not into an exchange.
            #expect(fixture.planner.receivedCommands == [], "\(spoken)")
            // The task finished, so the pause's record settled: nothing left to offer.
            #expect(try fixture.resumableTaskStore.loadAll().isEmpty, "\(spoken)")
            #expect(fixture.viewModel.resumeOffer == nil, "\(spoken)")
        }
    }

    /// The snippet question asks for the body alone now, and the body joins onto the prefix: the
    /// plan carries the trigger the user typed, and the save runs — a new snippet is tier 2, which
    /// the consequence rule auto-runs.
    @Test
    func aSnippetBodyJoinsOntoItsPrefix() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "snippet save"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "Use the format ;trigger = expansion.")

        fixture.viewModel.clarificationAnswer = ";sig = Best, Sonny"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.finalSummary == "Saved snippet ;sig.")
        #expect(fixture.viewModel.lastCommand == "snippet save ;sig = Best, Sonny")
        #expect(fixture.viewModel.plan?.steps.first?.searchQuery == ";sig")
        #expect(fixture.viewModel.plan?.steps.first?.draftContent == "Best, Sonny")
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **The stated residual, pinned so it is a record rather than a surprise.** A user who retypes
    /// the whole command joins the prefix onto itself, and `snippet save snippet save ;sig = hello`
    /// is a workable command — the store allows spaces in a trigger — so the join wins and a snippet
    /// is **saved** under a trigger nobody meant, with no card first: a new snippet is tier 2 and the
    /// consequence rule auto-runs it. (This test was first written expecting an approval pause, and
    /// it is what showed there is none.) It is visible and deletable on the Memory page. The join has
    /// to win this trade: the alternative is `anAnswerThatOnlyLooksLikeARestatementIsReadAsTheOperandFirst`,
    /// a wrong action with nothing to delete, and nothing at the string level separates the two.
    @Test
    func retypingTheWholeSnippetCommandJoinsThePrefixOntoItselfAndSavesThatTrigger() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "snippet save"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()

        fixture.viewModel.clarificationAnswer = "snippet save ;sig = hello"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.finalSummary == "Saved snippet snippet save ;sig.")
        #expect(fixture.viewModel.plan?.steps.first?.searchQuery == "snippet save ;sig")
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **The gate is the question, not the request alone.** A request the resolver would ask about,
    /// paused under a different question, is not the resolver's to complete — the answer belongs to
    /// whoever asked. **Stated plainly: the second question here is set by hand**, the same device
    /// the clarification-gate suites use; what is pinned is that the pending question is compared,
    /// not the reachability of the state that exposes it.
    @Test
    func aQuestionThatIsNotTheResolversForThisRequestIsNotCompleted() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        fixture.viewModel.command = "="
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")

        fixture.viewModel.clarificationQuestion = "Which of these did you mean?"
        fixture.viewModel.clarificationAnswer = "2 + 2"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.planner.receivedCommands == [
            ClarifiedCommand.composed(request: "=", question: "Which of these did you mean?", answer: "2 + 2")
        ])
        #expect(fixture.viewModel.plan?.steps.map(\.id) == ["draft", "url"])
    }

    /// **A calculation that resolves and does not evaluate is dispatched, so the calculator's own
    /// error shows** (PR #118 re-check, R-b). `calc` answered `banana` joins to `calc banana`, which
    /// resolves and fails the dry run and has no restatement to fall back to; composing the exchange
    /// there sent it to a planner with no calculator — this ticket's own symptom, one door over. The
    /// honest answer is the one typing `calc banana` gets. Two inputs, because the class is every
    /// expression the parser refuses, not one example.
    @Test
    func aCalculationThatResolvesButDoesNotEvaluateIsDispatchedSoTheCalculatorsOwnErrorShows() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan

        for (request, answer, expected) in [
            ("calc", "banana", "calc banana"),
            ("=", "2 +", "= 2 +")
        ] {
            fixture.viewModel.command = request
            fixture.viewModel.start(origin: .widget)
            try await fixture.waitForIdle()
            #expect(fixture.viewModel.clarificationQuestion == "What would you like me to calculate?")

            fixture.viewModel.clarificationAnswer = answer
            fixture.viewModel.submitClarification()
            try await fixture.waitForIdle()

            #expect(fixture.viewModel.lastCommand == expected)
            let error = try #require(fixture.viewModel.errorMessage)
            #expect(error.hasPrefix("Could not calculate that expression"))
            #expect(fixture.viewModel.clarificationQuestion == nil)
        }
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **R-a's neighbour, which R-b does change — said rather than left to drift.** With neither
    /// Writer nor Focus Writer running, the join and the restatement both resolve and neither
    /// prepares, so the join is dispatched and fails naming the app the user named; before R-b the
    /// exchange went to the planner. Same rule as the calculator case, same reason.
    @Test
    func withNeitherAppRunningTheJoinIsDispatchedAndFailsNamingTheAppTheUserNamed() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.runningAppSwitcher.apps = []

        fixture.viewModel.command = "focus"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        fixture.viewModel.clarificationAnswer = "Focus Writer"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.lastCommand == "focus Focus Writer")
        #expect(fixture.viewModel.errorMessage == "No running app matched Focus Writer.")
        #expect(fixture.runningAppSwitcher.activated == [])
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **R-a, recorded and not closed (founder decision, 2026-08-26), pinned so any drift is seen.**
    /// With only Writer running, the join `focus Focus Writer` fails prepare, the restatement
    /// `Focus Writer` reads as `focus` + `Writer` and prepares, and Sonny switches to Writer — where
    /// typing `focus Focus Writer` would say no running app matched. R-b does not reach this: a
    /// candidate prepared. Closing it needs a per-operation preference this branch does not add.
    @Test
    func withOnlyWriterRunningTheRestatementPreparesAndSonnySwitchesToWriterAsRecorded() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.runningAppSwitcher.apps = [
            RunningApp(displayName: "Writer", bundleIdentifier: "com.example.writer", processIdentifier: 101)
        ]

        fixture.viewModel.command = "focus"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        fixture.viewModel.clarificationAnswer = "Focus Writer"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.lastCommand == "Focus Writer")
        #expect(fixture.runningAppSwitcher.activated == ["com.example.writer"])
        #expect(fixture.planner.receivedCommands == [])
    }

    /// **R-c decides something, and this is the state in which it does** (PR #118 round-three
    /// re-check). The dry run refuses a prepare that came back with a clarification, and that can
    /// happen only when a source answers the resolver's read and the executor's read differently
    /// inside one synchronous call. The routine and workspace stores cannot — they key by the same
    /// `normalized()` the resolver uses — but the Shortcuts catalog is a process read that
    /// `InvokeShortcutCapabilityAdapter.resolveDefaultOutputs` re-resolves, and this fixture's
    /// catalog answers its first read `["Shortcut X", "X"]` and `["X"]` after. So the join
    /// `shortcut Shortcut X` resolves on read 1, its prepare clarifies on read 2, and the restatement
    /// `Shortcut X` resolves and prepares on reads 3 and 4 — the real code passes over the join and
    /// dispatches the restatement, where a guard that took the clarifying prepare as workable would
    /// dispatch the join and re-ask. "Dispatched either way" was true only of a sole or last
    /// resolved candidate, which is why the mutant that removes the guard was first reported as
    /// equivalent and is not.
    @Test
    func aCandidateWhosePrepareClarifiesIsPassedOverForOneThatPrepares() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }
        fixture.planner.plan = fixture.draftThenOpenPlan
        fixture.shortcutCatalog.firstAnswer = ["Shortcut X", "X"]
        fixture.shortcutCatalog.thenAnswer = ["X"]

        fixture.viewModel.command = "shortcut"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.clarificationQuestion == "Which Shortcut should I run?")
        // The premise: nothing so far has read the catalog, so the join's resolution is read 1.
        #expect(fixture.shortcutCatalog.reads == 0)

        fixture.viewModel.clarificationAnswer = "Shortcut X"
        fixture.viewModel.submitClarification()
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.lastCommand == "Shortcut X")
        #expect(fixture.viewModel.clarificationQuestion == nil)
        #expect(fixture.planner.receivedCommands == [])
        // Read 1 fed the join's resolution, read 2 its clarifying prepare, 3 and 4 the restatement.
        #expect(fixture.shortcutCatalog.reads >= 4)
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
///
/// **And, when a test says so, a catalog that answers its first read differently from every read
/// after** (SONNY-281, PR #118 round-three re-check): the one source `InvokeShortcutCapabilityAdapter`
/// re-resolves at prepare, and so the one way a resolver plan's prepare can clarify inside a
/// synchronous call. Counts its reads so a test can state which read fed which step.
private final class ScriptedShortcutCatalog: ShortcutCatalogProviding, @unchecked Sendable {
    var firstAnswer: [String]?
    var thenAnswer: [String] = ["Send Report"]
    private(set) var reads = 0
    func shortcutNames() throws -> [String] {
        reads += 1
        if reads == 1, let firstAnswer {
            return firstAnswer
        }
        return thenAnswer
    }
}

/// Lists whatever a test says is running and records what was activated, never touching the real
/// workspace (SONNY-281, PR #118 review F2): the Writer case needs two apps running whose names
/// overlap, and `HermeticRunningAppSwitcher` lists none.
private final class ListingRunningAppSwitcher: RunningAppSwitching {
    var apps: [RunningApp] = []
    private(set) var activated: [String] = []
    func runningApps() -> [RunningApp] { apps }
    func activate(bundleIdentifier: String) async throws { activated.append(bundleIdentifier) }
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
    let runningAppSwitcher: ListingRunningAppSwitcher
    let shortcutCatalog: ScriptedShortcutCatalog
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
        runningAppSwitcher: ListingRunningAppSwitcher,
        shortcutCatalog: ScriptedShortcutCatalog,
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
        self.runningAppSwitcher = runningAppSwitcher
        self.shortcutCatalog = shortcutCatalog
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
    let runningAppSwitcher = ListingRunningAppSwitcher()
    let shortcutCatalog = ScriptedShortcutCatalog()
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
            shortcutCatalog: shortcutCatalog,
            // Hermetic seams, defined in ProductShellTests.swift in this same target — except the browser,
            // which is this suite's own failure switch.
            browserOpener: browserOpener,
            appOpener: HermeticAppOpener(),
            fileOpener: fileOpener,
            finderRevealer: hermeticFinderRevealer,
            mediaOpener: HermeticMediaOpener(),
            runningAppSwitcher: runningAppSwitcher,
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
        runningAppSwitcher: runningAppSwitcher,
        shortcutCatalog: shortcutCatalog,
        userDefaults: userDefaults,
        suiteName: suiteName,
        draftOutput: root.appendingPathComponent("notes.md")
    )
}
