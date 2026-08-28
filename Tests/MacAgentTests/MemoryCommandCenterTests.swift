import Combine
import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgent
@testable import MacAgentCore

/// Command Center's Memory section (SONNY-208), pinned where it can actually go wrong.
///
/// **Every switch here is asserted through a real dispatch, not by reading the value back.** A
/// `MemoryRecordingSettings` that answers "no" proves nothing about whether the routine save, the
/// history row, or the clipboard timer ever asks it — and the writing sites live in five separate
/// layers, which is the exact shape `TaskRecordingPolicy`'s own doc names as how a switch quietly
/// stops being true. So each test dispatches a plan through `start(prebuiltPlan:)`, lets the run
/// terminate, and reads the store back off disk.
@Suite(.serialized)
@MainActor
struct MemoryCommandCenterTests {
    // MARK: - The per-type switches, on the real dispatch path

    @Test
    func savingARoutineWithRoutinesMemoryOnWritesItToTheStore() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()

        // The control for the test below: without it, a refusal test passes for a fixture that could
        // never have saved a routine in the first place.
        #expect(try fixture.routineStore.findRoutine(named: "Morning") != nil)
        #expect(fixture.viewModel.errorMessage == nil)
    }

    @Test
    func savingARoutineWithRoutinesMemoryOffLeavesTheStoreEmptyAndSaysWhy() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryCategoryEnabled(.routines, to: false)

        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()

        #expect(try fixture.routineStore.loadAll().isEmpty)
        // Refused out loud: a save the user asked for by name must not report success it did not have.
        let message = try #require(fixture.viewModel.errorMessage)
        #expect(message.contains("Routines memory is off"))
        // And only routines — the switch is per type, which a shared guard would quietly break.
        #expect(fixture.viewModel.isMemoryCategoryEnabled(.snippets))
    }

    @Test
    func savingASnippetWithSnippetsMemoryOffLeavesTheStoreEmpty() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryCategoryEnabled(.snippets, to: false)

        fixture.viewModel.command = "save a snippet ;sig"
        fixture.viewModel.start(prebuiltPlan: planSavingSnippet(trigger: ";sig", expansion: "signature"))
        try await fixture.waitUntilIdle()

        #expect(try fixture.snippetStore.loadAll().isEmpty)
        #expect(try #require(fixture.viewModel.errorMessage).contains("Snippets memory is off"))
    }

    @Test
    func creatingAWorkspaceWithWorkspacesMemoryOffLeavesTheStoreEmpty() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryCategoryEnabled(.workspaces, to: false)

        fixture.viewModel.command = "create a workspace called Research"
        fixture.viewModel.start(prebuiltPlan: planCreatingWorkspace(named: "Research"))
        try await fixture.waitUntilIdle()

        #expect(try fixture.workspaceStore.loadAll().isEmpty)
        #expect(try #require(fixture.viewModel.errorMessage).contains("Workspaces memory is off"))
    }

    /// The trace half of the same rule, and it is deliberately silent: nobody asked for a history
    /// row, so withholding one is not a failure to report. The run itself still succeeds, which is
    /// the assertion that separates "did not record" from "did not run".
    @Test
    func taskHistoryMemoryOffLeavesNoRowForARunThatSucceeded() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary.contains("4"))
    }

    @Test
    func turningTaskHistoryMemoryBackOnRestoresRecording() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)

        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: true)
        fixture.viewModel.command = "add three and three"
        fixture.viewModel.start(prebuiltPlan: planCalculating("3 + 3"))
        try await fixture.waitUntilIdle()

        let records = try fixture.taskHistoryStore.loadAll()
        #expect(records.count == 1)
        // The second run only. Turning memory back on records what happens next; it does not
        // reconstruct what was withheld.
        #expect(records.first?.command == "add three and three")
    }

    // MARK: - The scheduled path, which is where the switches were being bypassed

    /// The control for the four tests below: with memory on, a scheduled routine really does write
    /// a row and a plan detail. Without it, "nothing was recorded" is equally true of a fixture
    /// whose scheduler never fired.
    @Test
    func aScheduledRoutineRecordsARowAndAPlanDetailWithMemoryOn() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
        #expect(try fixture.taskHistoryStore.loadAll().first?.effectiveTrigger == .scheduled)
        #expect(FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
    }

    /// **The defect PR #98's review reproduced** (F1). `recordScheduledTaskHistory` guarded neither
    /// of its two writes, so a user who switched memory off and let a morning routine fire got new
    /// rows written into the encrypted store while the switch on screen read off. Driven through the
    /// real scheduler door, `checkScheduledRoutines(now:)`, not through the seam — the seam is
    /// exactly what this path routed around.
    @Test
    func aScheduledRoutineWritesNoRowAndNoPlanDetailWithTheMasterSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.setMemoryEnabled(false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path),
            "the scheduled run wrote what it planned with memory off"
        )
        // The run itself still happened — this withholds the record, it does not cancel the routine.
        #expect(fixture.viewModel.scheduledRunNotice != nil)
    }

    @Test
    func aScheduledRoutineWritesNoRowWithTheTaskHistorySwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
        // Per type, not wholesale: a different row's switch does not withhold this one.
        #expect(fixture.viewModel.isMemoryCategoryEnabled(.snippets))
    }

    /// **A per-type switch for a different row must not withhold task history**, or the test above
    /// would pass over a scheduled guard that consulted the master switch alone.
    @Test
    func aScheduledRoutineStillRecordsWhenSomeOtherTypesSwitchIsOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.setMemoryCategoryEnabled(.snippets, to: false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
    }

    /// **The fourth write, and the last one the enumeration of the scheduled path found**
    /// (PR #98 round-4 pass, F1; founder decision 2026-08-22). A routine firing on its schedule
    /// appended a dated entry to `routines.json` — the file the Routines memory row governs, and the
    /// dates the streak badge is computed from — with every switch off and nothing able to stop it.
    ///
    /// Driven through the real door and read back off the store, not off the published array: the
    /// defect was a write, so the file is what has to be checked.
    @Test
    func aScheduledRoutineRecordsNoRunDateWithTheMasterSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.setMemoryEnabled(false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        let routine = try #require(try fixture.routineStore.findRoutine(named: "Morning"))
        #expect(
            routine.effectiveRecentRunDates.isEmpty,
            "the scheduled run logged a date with memory off — the badge would show a streak"
        )
    }

    @Test
    func aScheduledRoutineRecordsNoRunDateWithTheRoutinesSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.setMemoryCategoryEnabled(.routines, to: false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        let routine = try #require(try fixture.routineStore.findRoutine(named: "Morning"))
        #expect(routine.effectiveRecentRunDates.isEmpty)
    }

    /// The control, and it carries the operational half of the founder's decision too: guarding the
    /// run date costs nothing, because nothing in the scheduling path reads `recentRunDates` — the
    /// due-check runs off the schedule and the clock. So with memory **on** the date lands, and in
    /// both tests above the run still happened and the schedule still advanced.
    @Test
    func aScheduledRoutineRecordsItsRunDateWithMemoryOnAndRunsEitherWay() async throws {
        let recording = try makeMemoryFixture()
        defer { recording.cleanUp() }
        try recording.saveScheduledRoutine()

        recording.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await recording.waitUntilIdle()

        let recorded = try #require(try recording.routineStore.findRoutine(named: "Morning"))
        #expect(recorded.effectiveRecentRunDates.count == 1)

        // Memory off: no date, but the routine still ran and its schedule still moved on, so the
        // guard withholds a record rather than cancelling the automation.
        let silent = try makeMemoryFixture()
        defer { silent.cleanUp() }
        try silent.saveScheduledRoutine()
        silent.viewModel.setMemoryEnabled(false)

        silent.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await silent.waitUntilIdle()

        #expect(silent.viewModel.scheduledRunNotice != nil, "the routine did not run at all")
        let quiet = try #require(try silent.routineStore.findRoutine(named: "Morning"))
        #expect(quiet.effectiveRecentRunDates.isEmpty)
        #expect(
            quiet.schedule?.isEnabled == true,
            "the schedule was disturbed by withholding a run date"
        )
        #expect(
            quiet.schedule?.lastRunAt != nil,
            "the schedule's own baseline did not advance, so the occurrence would fire again"
        )
    }

    /// **The plan-detail guard must not take `refreshTaskHistory()` with it** (PR #98 round-4 pass,
    /// F3). Unreachable while both stores share the `.taskHistory` row, so this asserts the shape
    /// rather than the behaviour: the guard lives in its own function, exactly as the foreground
    /// twin's does, so its `return` is local. Written as a scan because there is no way to reach the
    /// branch at runtime — and because the day it becomes reachable is the day nobody is looking.
    @Test
    func theScheduledPlanDetailGuardCannotSkipTheHistoryRefresh() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        // The whole signature is the anchor, because `braceBlock` looks for the opening brace
        // *inside* the anchor text and these signatures wrap across lines.
        let writer = try MacAgentSource.braceBlock(
            of: source,
            openedBy: """
            private func recordScheduledTaskHistory(
                    status: PriorTaskOutcomeStatus,
                    startedAt: Date,
                    result: StoredTaskResult,
                    plan: AgentPlan?
                ) {
            """
        )

        // The refresh is in the function that writes the row, and the plan guard is not.
        #expect(writer.contains("refreshTaskHistory()"))
        #expect(!writer.contains("allowsScheduledRecording(to: .taskPlanDetails)"))
        #expect(writer.contains("recordScheduledTaskPlanDetail("))

        let planWriter = try MacAgentSource.braceBlock(
            of: source,
            openedBy: """
            private func recordScheduledTaskPlanDetail(
                    for record: CompletedTaskRecord,
                    plan: AgentPlan?,
                    evictedTaskIDs: [String]
                ) {
            """
        )
        #expect(planWriter.contains("allowsScheduledRecording(to: .taskPlanDetails)"))
        #expect(
            !planWriter.contains("refreshTaskHistory()"),
            "the refresh moved into the function whose guard can skip it"
        )
    }

    /// **The composer switch must stay out of the scheduled path** (PR #67's F2, which the fix for
    /// F1 could have undone by copying the foreground guard verbatim).
    ///
    /// A foreground run paused at a clarification leaves `isRunning` false with
    /// `taskRecordingPolicy == .suppressTraces`, and `checkScheduledRoutines` only guards on
    /// `isRunning` and `isAwaitingApproval` — so a routine firing in that window must still record.
    /// Had the fix used `allowsRecording(to:)` rather than `allowsScheduledRecording(to:)`, this
    /// would be red.
    @Test
    func aScheduledRoutineStillRecordsWhileAForegroundRunHasSuppressionLeftOn() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.saveScheduledRoutine()
        fixture.viewModel.taskRecordingPolicy = .suppressTraces

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
    }

    /// **F2: the same path handed `AgentRunner` the raw recent-artifacts store**, so a scheduled
    /// routine that wrote a file recorded a note naming its full path with memory off. Asserted at
    /// the scheduled seam for the reason `recentArtifactStoreForThisRun`'s doc gives — no command the
    /// fixtures can run generates an artifact — and paired with a scan below proving the scheduled
    /// runner actually reads this property rather than the raw store it used to.
    @Test
    func theScheduledRecentArtifactHandoverIsWithheldByTheMemorySwitchesAndNotByTheComposerSwitch() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.viewModel.recentArtifactStoreForScheduledRun != nil)

        fixture.viewModel.setMemoryCategoryEnabled(.recentArtifacts, to: false)
        #expect(fixture.viewModel.recentArtifactStoreForScheduledRun == nil)

        fixture.viewModel.setMemoryCategoryEnabled(.recentArtifacts, to: true)
        fixture.viewModel.setMemoryEnabled(false)
        #expect(fixture.viewModel.recentArtifactStoreForScheduledRun == nil)

        // And the composer switch is deliberately *not* read here, unlike the foreground seam —
        // PR #67's F2 again, from the other side.
        fixture.viewModel.setMemoryEnabled(true)
        fixture.viewModel.taskRecordingPolicy = .suppressTraces
        #expect(fixture.viewModel.recentArtifactStoreForScheduledRun != nil)
        #expect(
            fixture.viewModel.recentArtifactStoreForThisRun == nil,
            "the foreground seam must still read the composer switch"
        )
    }

    // MARK: - Output locations, the twelfth store (SONNY-209)

    /// **The control, and it is the one that has to exist.** "Nothing was recorded" is equally true
    /// of a store nothing ever writes to, so the switched-off tests below mean nothing without a
    /// run that really does record — through `checkScheduledRoutines(now:)`, the real scheduler door,
    /// with a routine that writes a real file into a real folder.
    @Test
    func aScheduledRoutineThatWritesAFileRecordsTheFolderItLandedIn() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        // The routine really ran and really wrote the file — without this the store assertion below
        // could pass over a run that never happened.
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
        let stored = try fixture.outputLocationStore.loadAll()
        #expect(stored.map(\.path) == [reports.path])
        #expect(stored.first?.useCount == 1)
        #expect(stored.first?.name == "Reports")
    }

    @Test
    func aScheduledRoutineRecordsNoOutputLocationWithTheMasterSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.setMemoryEnabled(false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().isEmpty)
        // The run still happened and the user still has their file. This withholds the note about
        // where it went; it does not cancel the routine or move the output.
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
    }

    @Test
    func aScheduledRoutineRecordsNoOutputLocationWithTheOutputLocationsSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.setMemoryCategoryEnabled(.outputLocations, to: false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().isEmpty)
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
    }

    /// **Per type, not wholesale.** Turning off the neighbouring row — recent artifacts, the store
    /// this one is most likely to be confused with — must leave output locations recording. Without
    /// this, the test above would pass over a guard that read the master switch or the wrong row.
    @Test
    func aScheduledRoutineStillRecordsItsOutputLocationWhenTheRecentArtifactsSwitchIsOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.setMemoryCategoryEnabled(.recentArtifacts, to: false)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().map(\.path) == [reports.path])
    }

    /// **The scheduled path drops the composer switch, and this is that decision driven end to end**
    /// (PR #98's F1/F2 shape, one store later). "Don't save this task" is a pre-dispatch toggle: a
    /// person flips it on while composing a command they have not sent, all three of
    /// `checkScheduledRoutines`' guards still pass, and a routine fires. Reading the policy on that
    /// path would silently stop Sonny learning the folder a Monday-morning routine files into,
    /// because of a switch set for a different task.
    @Test
    func aScheduledRoutineStillRecordsItsOutputLocationWhileAForegroundRunHasSuppressionLeftOn() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.taskRecordingPolicy = .suppressTraces

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().map(\.path) == [reports.path])
    }

    /// The foreground path, through `start(prebuiltPlan:)` and a real lightweight confirmation.
    ///
    /// Its own end-to-end test rather than a seam assertion, because the foreground and scheduled
    /// paths build their runners at four and one construction sites respectively and read *different*
    /// seams — a handover correct on one says nothing about the other.
    @Test
    func aForegroundRunThatWritesAFileRecordsTheFolderItLandedIn() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
        #expect(try fixture.outputLocationStore.loadAll().map(\.path) == [reports.path])
        #expect(fixture.viewModel.errorMessage == nil)
    }

    @Test
    func aForegroundRunRecordsNoOutputLocationWithTheOutputLocationsSwitchOff() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        fixture.viewModel.setMemoryCategoryEnabled(.outputLocations, to: false)

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().isEmpty)
        // The file the user asked for is still there — a trace switch withholds the note, never the
        // output.
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
    }

    /// The other half of the foreground conjunction: "Don't save this task", which the *foreground*
    /// path does read, with every memory switch on.
    @Test
    func aSuppressedForegroundRunRecordsNoOutputLocation() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        #expect(fixture.viewModel.memorySettings.isRecording)
        fixture.viewModel.taskRecordingPolicy = .suppressTraces

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        #expect(try fixture.outputLocationStore.loadAll().isEmpty)
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
    }

    /// Both seams as values, so each switch's effect on each path is asserted directly rather than
    /// only through the dispatch tests above — the same belt `theRecentArtifactAndVisionJournalHandoversAreWithheldByTheMemorySwitchesToo`
    /// provides for its two stores.
    @Test
    func theOutputLocationHandoversAreWithheldByTheMemorySwitchesOnBothPaths() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.viewModel.outputLocationStoreForThisRun != nil)
        #expect(fixture.viewModel.outputLocationStoreForScheduledRun != nil)

        fixture.viewModel.setMemoryCategoryEnabled(.outputLocations, to: false)
        #expect(fixture.viewModel.outputLocationStoreForThisRun == nil)
        #expect(fixture.viewModel.outputLocationStoreForScheduledRun == nil)
        // Only this row — the neighbouring store's seams are untouched, which is what fails if the
        // two rows were ever wired to one flag.
        #expect(fixture.viewModel.recentArtifactStoreForThisRun != nil)
        #expect(fixture.viewModel.recentArtifactStoreForScheduledRun != nil)

        fixture.viewModel.setMemoryCategoryEnabled(.outputLocations, to: true)
        fixture.viewModel.setMemoryEnabled(false)
        #expect(fixture.viewModel.outputLocationStoreForThisRun == nil)
        #expect(fixture.viewModel.outputLocationStoreForScheduledRun == nil)

        // And the composer switch parts the two paths, in the direction each is supposed to go.
        fixture.viewModel.setMemoryEnabled(true)
        fixture.viewModel.taskRecordingPolicy = .suppressTraces
        #expect(fixture.viewModel.outputLocationStoreForThisRun == nil)
        #expect(
            fixture.viewModel.outputLocationStoreForScheduledRun != nil,
            "the scheduled seam must not read the composer switch"
        )
    }

    /// The scheduled runner is handed the *scheduled* output-location seam, scanned for the same
    /// reason its recent-artifact twin below is scanned: `AgentRunner` stores the handover privately,
    /// so no runtime assertion can read which of the two properties reached it.
    @Test
    func theScheduledRunnerIsHandedTheScheduledOutputLocationSeam() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let scheduledRun = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func performScheduledRun(_ routine: StoredRoutine, occurrence: Date) async {"
        )

        #expect(scheduledRun.contains("outputLocationStore: outputLocationStoreForScheduledRun"))

        // Same shape as the assertion below it: the sanctioned handover is removed first, because
        // `outputLocationStore: outputLocationStore` is a substring of the correct line and
        // asserting its absence directly would fail on correct code.
        let withoutTheSanctionedHandover = scheduledRun.replacingOccurrences(
            of: "outputLocationStore: outputLocationStoreForScheduledRun",
            with: ""
        )
        #expect(!withoutTheSanctionedHandover.contains("outputLocationStore"))
    }

    /// **The foreground counterpart of the scan above, and the asymmetry it closes is what let three
    /// of four sites go unheld** (PR #101 review, F1).
    ///
    /// The scheduled path had this instrument and the foreground path did not, so at `335ddce` three
    /// mutants passed the whole suite: `performStart`'s planner branch and `makeDelegationRunner()`
    /// each wired to the *scheduled* seam, and `performStart`'s instant-resolver branch with the
    /// argument deleted outright. The first is the one that matters — the planner branch is the path
    /// most real commands take, the scheduled seam is `allowsScheduledRecording(to:)`, and wiring one
    /// to the other drops `taskRecordingPolicy` out of the conjunction. A person turns on "Don't save
    /// this task", Sonny drafts a file into their Documents folder, and the folder is recorded anyway,
    /// with 1743 tests green.
    ///
    /// **Counts per block rather than a bare `contains`**, for the reason `MacAgentSource`'s own doc
    /// gives: a trailing line comment can add a token but never remove one, so a count is sound where
    /// a presence check is not. One sanctioned handover per `AgentRunner(` in the block, then the
    /// sanctioned text is removed and the bare store token must be gone — which catches the scheduled
    /// seam and a raw store alike, and is the same two-step the scan above uses because
    /// `outputLocationStore: outputLocationStore` is a prefix of the correct line.
    ///
    /// **It covers `recentArtifactStore` too, and that is a fix rather than a bonus.** The reviewer
    /// mutated that store's handover on the same line and it also survived, so the hole predates this
    /// branch. Covering it here is one array element, no production change — all four sites already
    /// read the right seam — so it is closed rather than filed.
    @Test
    func everyForegroundRunnerIsHandedTheForegroundSeams() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        // Anchored on real code rather than line numbers. `performStart`'s signature spans seven
        // lines, so the anchor carries its last parameter and the brace; a rename fails this loudly,
        // which is the moment to re-check that the property still holds. It did exactly that when
        // SONNY-210 added `continuing:` after `prebuiltPlanSource:` — the anchor moved, the property
        // was re-checked against the real body, and both runners still take the foreground seams.
        let blocks: [(name: String, anchor: String)] = [
            (
                "performStart",
                """
                        continuing: ResumableTaskContinuation? = nil
                    ) async {
                """
            ),
            ("makeDelegationRunner", "func makeDelegationRunner() -> AgentRunner {")
        ]

        var runnersSeen = 0
        for block in blocks {
            let body = try MacAgentSource.braceBlock(of: source, openedBy: block.anchor)
            let runners = MacAgentSource.count(of: "AgentRunner(", inText: body)
            #expect(runners > 0, "\(block.name) builds no AgentRunner — the anchor no longer matches")
            runnersSeen += runners

            for store in ["outputLocationStore", "recentArtifactStore"] {
                let sanctioned = "\(store): \(store)ForThisRun"
                #expect(
                    MacAgentSource.count(of: sanctioned, inText: body) == runners,
                    """
                    \(block.name) builds \(runners) AgentRunner(s) but hands over \(sanctioned) \
                    \(MacAgentSource.count(of: sanctioned, inText: body)) time(s). Every foreground \
                    runner takes the foreground seam, which is the conjunction of the memory switches \
                    and "Don't save this task".
                    """
                )
                let withoutTheSanctionedHandovers = body.replacingOccurrences(of: sanctioned, with: "")
                #expect(
                    !withoutTheSanctionedHandovers.contains(store),
                    "\(block.name) reaches \(store) by some other name — the scheduled seam, or the raw store"
                )
            }
        }

        // The population, pinned so a fifth foreground construction site cannot arrive unexamined.
        // Three in `performStart` (prebuilt plan, instant resolver, planner) and one in
        // `makeDelegationRunner()`; the fifth `AgentRunner(` in this file is the scheduled one, which
        // the scan above owns.
        #expect(runnersSeen == 4, "expected four foreground AgentRunner sites, scanned \(runnersSeen)")
        #expect(MacAgentSource.count(of: "AgentRunner(", inText: source) == runnersSeen + 1)
    }

    /// **A bookkeeping write failure is a storage notice, never a task error** — CLAUDE.md's
    /// write-failure channel rule, on the path that has to get it right without anybody watching.
    /// `errorMessage` means "the task you asked for did not happen", and the widget picks `.failure`
    /// ahead of `.result`; a lost note about a folder must not turn a routine that ran and wrote its
    /// file into one the user is told failed.
    ///
    /// The failure is induced by leaving unreadable bytes in the store's own file rather than by
    /// locking a directory, so this needs no `.requiresUnprivilegedProcess` gate: `recordOutputs`
    /// reads before it writes, and a file that will not decode makes the write throw.
    ///
    /// **Read across the whole attempt rather than at the end, and that changed with SONNY-246.**
    /// The run now reloads the Memory lists when it terminates, so the same unreadable file is read
    /// again a moment later and the load banner — which names the store *and* the control that
    /// clears it — is the last thing on the channel. A single read at the end would therefore pin
    /// only the second of the two notices and would have nothing to say about the first, which is
    /// the one this test was written for. Both are asserted, in order.
    ///
    /// **This is not a new competition between the two channels, it is an existing one reaching a
    /// tenth store.** `refreshSavedItems()` has probed snippets, recent artifacts, clipboard history
    /// and allowed apps for readability after every successful run since row J, through
    /// `refreshSilentlyReadStoreHealth`, and has always been able to overwrite a write notice the
    /// same way. Output locations was simply outside that probe.
    @Test
    func aScheduledRunsOutputLocationWriteFailureIsANoticeRatherThanAFailedRun() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        try Data("not a store".utf8).write(to: fixture.outputLocationStore.fileURL, options: .atomic)

        var notices: [String] = []
        let subscription = fixture.viewModel.$localStorageNotice
            .compactMap { $0 }
            .sink { notices.append($0) }
        defer { subscription.cancel() }

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        // The write, named as a write: this store's own wording, never the load banner's, and never
        // another store's.
        #expect(
            notices.contains { $0.hasPrefix("Sonny could not update its list of output locations") },
            "no notice named this write: \(notices)"
        )
        // And the last word points at the repair (SONNY-239), because the file is still unreadable
        // after the run and will be at the next launch too.
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("where your outputs usually go"))
        #expect(notice.hasSuffix("Open Memory in Command Center to clear it."))
        // The property this test is named for, and the one that must never move.
        #expect(fixture.viewModel.errorMessage == nil)
        // The routine really ran and the user really has their file — only the note was lost.
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
        #expect(fixture.viewModel.scheduledRunNotice != nil)
    }

    /// The foreground twin, which is a different handover in a different function.
    @Test
    func aForegroundRunsOutputLocationWriteFailureIsANoticeRatherThanAFailedRun() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        try Data("not a store".utf8).write(to: fixture.outputLocationStore.fileURL, options: .atomic)

        var notices: [String] = []
        let subscription = fixture.viewModel.$localStorageNotice
            .compactMap { $0 }
            .sink { notices.append($0) }
        defer { subscription.cancel() }

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        #expect(
            notices.contains { $0.hasPrefix("Sonny could not update its list of output locations") },
            "no notice named this write: \(notices)"
        )
        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("where your outputs usually go"))
        #expect(notice.hasSuffix("Open Memory in Command Center to clear it."))
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
    }

    /// The row's count and its "newest" line come from the real store, and "newest" means the most
    /// recent *use* — every other row's newest line means the most recent thing recorded, and
    /// `firstUsedAt` would make this one mean something different from all of them.
    @Test
    func theOutputLocationRowsCountAndNewestLineComeFromTheRealStore() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = try fixture.makeOutputFolder("Reports")
        let invoices = try fixture.makeOutputFolder("Invoices")
        // Two uses each, with the windows deliberately interleaved: Reports was used *first* but
        // Invoices was used *last*. So `max(firstUsedAt)` and `max(lastUsedAt)` are different dates,
        // and a row that reached for the wrong one cannot pass by coincidence.
        for offset in [-2.0, -1.0] {
            try fixture.outputLocationStore.recordOutputs(
                atPaths: [reports.appendingPathComponent("a.md").path],
                recordedAt: now.addingTimeInterval(offset * 86_400)
            )
        }
        try fixture.outputLocationStore.recordOutputs(
            atPaths: [invoices.appendingPathComponent("b.md").path],
            recordedAt: now.addingTimeInterval(-3 * 86_400)
        )
        try fixture.outputLocationStore.recordOutputs(
            atPaths: [invoices.appendingPathComponent("c.md").path],
            recordedAt: now
        )
        fixture.viewModel.refreshMemoryEntries()

        let presentation = MemoryRowPresentation(
            category: .outputLocations,
            count: fixture.viewModel.memoryEntryCount(for: .outputLocations),
            isRecording: fixture.viewModel.isMemoryCategoryEnabled(.outputLocations),
            canChangeRecording: fixture.viewModel.memorySettings.isRecording,
            readability: MemoryRowReadability.of(.outputLocations, viewModel: fixture.viewModel),
            newestEntryDate: fixture.viewModel.newestMemoryEntryDate(for: .outputLocations),
            now: now
        )

        #expect(presentation.title == "Output locations")
        #expect(presentation.count == 2)
        #expect(presentation.isRecording)
        #expect(presentation.detailText == "2 folders · newest Today, \(expectedTime(for: now))")
        // The published list is the store's ranked order, so the sheet's first row is the folder
        // Sonny would actually suggest first.
        #expect(fixture.viewModel.outputLocations.map(\.name) == ["Invoices", "Reports"])
    }

    /// **The row and its sheet name different units, so neither number reads as an answer to the
    /// other** (SONNY-243).
    ///
    /// This is the pair the founder reported on 2026-08-23: the row said `1 saved` and the sheet
    /// said `Desktop · ~/Desktop · 2 times`, and the only reading available was that one of them
    /// was wrong. Both were right and always will be — the row counts folders, the sheet's number
    /// counts one folder's uses — so the fix is words, not arithmetic, and this is the assertion
    /// that the words are there. It also pins the invariant that made "1 versus 2" misread in the
    /// first place: the row's count *is* the number of rows the sheet lists, on this row exactly as
    /// on every other one.
    @Test
    func theOutputLocationsRowCountsFoldersWhileItsSheetSaysHowOftenEachWasUsed() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let desktop = try fixture.makeOutputFolder("Desktop")
        // One folder, written into twice — the founder's exact case.
        for name in ["a.md", "b.md"] {
            try fixture.outputLocationStore.recordOutputs(
                atPaths: [desktop.appendingPathComponent(name).path],
                recordedAt: now
            )
        }
        fixture.viewModel.refreshMemoryEntries()

        let row = MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel, now: now)
        let entries = MemoryEntryPresentation.entries(for: .outputLocations, viewModel: fixture.viewModel, now: now)

        #expect(row.detailText == "1 folder · newest Today, \(expectedTime(for: now))")
        #expect(row.count == 1)
        // The pattern the rest of the page establishes, holding here too: the headline number is
        // the number of things the sheet then lists.
        #expect(entries.count == row.count)

        let detail = try #require(entries.first).detail
        #expect(detail.contains("used 2 times"), "\(detail)")
        // The bare form is what made the pair read as a contradiction; a use count with no verb in
        // front of it sits in the same shape as an entry count.
        #expect(!detail.contains("· 2 times"), "\(detail)")
    }

    /// **Every row's detail names its unit, checked over the whole population** (SONNY-243).
    ///
    /// The row the founder reported is one of the page's rows, and the sentence they all share is
    /// built in one place — so what this guards against is a tenth row, or a row wired to something other than
    /// `MemoryCategory.countedEntries(_:)`. Asserted on the empty fixture because the empty detail
    /// is the count and nothing else, which is the whole of what is under test here; the populated
    /// forms are pinned by the tests around it.
    @Test
    func everyMemoryRowsDetailNamesWhatItCounts() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for category in MemoryCategory.allCases {
            let row = MemoryRowPresentation.row(for: category, viewModel: fixture.viewModel, now: now)
            #expect(row.count == 0, "\(category.title)")
            #expect(row.detailText == "0 \(category.pluralNoun)", "\(category.title)")
            #expect(!row.detailText.contains("saved"), "\(category.title) still infers its unit")
        }
    }

    @Test
    func deletingOutputLocationMemoryLeavesEveryOtherTypeAlone() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        // A real file, so the "the folder and its contents are untouched" assertion below is about
        // something that exists — the store records a folder without needing the file to.
        let output = reports.appendingPathComponent("a.md")
        try Data("draft".utf8).write(to: output, options: .atomic)
        try fixture.outputLocationStore.recordOutputs(atPaths: [output.path])
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.memoryEntryCount(for: .outputLocations) == 1)

        fixture.viewModel.deleteMemory(in: .outputLocations)

        #expect(try fixture.outputLocationStore.loadAll().isEmpty)
        #expect(fixture.viewModel.memoryEntryCount(for: .outputLocations) == 0)
        #expect(try fixture.snippetStore.loadAll().count == 1)
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage).hasPrefix("Deleted output locations")
        )
        // The folder and its contents are untouched — this store only ever held a note about them.
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(FileManager.default.fileExists(atPath: reports.path))
    }

    @Test
    func aPerEntryDeleteRemovesOneOutputLocationAndRepublishesTheList() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reports = try fixture.makeOutputFolder("Reports")
        let invoices = try fixture.makeOutputFolder("Invoices")
        try fixture.outputLocationStore.recordOutputs(
            atPaths: [reports.appendingPathComponent("a.md").path],
            recordedAt: now.addingTimeInterval(-86_400)
        )
        try fixture.outputLocationStore.recordOutputs(
            atPaths: [invoices.appendingPathComponent("b.md").path],
            recordedAt: now
        )
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.outputLocations.map(\.name) == ["Invoices", "Reports"])

        // By position into the published array the sheet enumerated, which is what the sheet passes.
        fixture.viewModel.deleteMemoryEntry(in: .outputLocations, at: 0)

        #expect(fixture.viewModel.outputLocations.map(\.name) == ["Reports"])
        #expect(try fixture.outputLocationStore.loadAll().map(\.name) == ["Reports"])
        #expect(fixture.viewModel.errorMessage == nil)
        // Out of range is a no-op rather than a crash: the array can shrink under an open sheet.
        fixture.viewModel.deleteMemoryEntry(in: .outputLocations, at: 7)
        #expect(fixture.viewModel.outputLocations.count == 1)
        // And the store is still encrypted after a per-entry delete — the rewrite goes through the
        // same door the record did.
        let raw = try Data(contentsOf: fixture.outputLocationStore.fileURL)
        #expect(raw.starts(with: LocalStorageEncryption.fileHeader))
    }

    @Test
    func aWholeDataWipeEmptiesTheOutputLocationsList() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.outputLocations.count == 1)

        fixture.viewModel.deleteLocalData()

        #expect(fixture.viewModel.outputLocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.outputLocationStore.fileURL.path))
    }

    /// The scheduled runner reads the scheduled seam, which no runtime assertion in this repository
    /// can reach: `AgentRunner` stores the handed-over store privately and a scheduled run that
    /// generates an artifact would write a real file into a whitelisted directory. So the wiring is
    /// scanned, in the shape `MacAgentSource` exists for.
    @Test
    func theScheduledRunnerIsHandedTheScheduledRecentArtifactSeam() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let scheduledRun = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func performScheduledRun(_ routine: StoredRoutine, occurrence: Date) async {"
        )

        #expect(scheduledRun.contains("recentArtifactStore: recentArtifactStoreForScheduledRun"))

        // **Not a second `contains` for the wrong store, because the right string contains the wrong
        // one as a prefix** — `recentArtifactStore: recentArtifactStore` is a substring of the line
        // above, so asserting its absence fails on correct code. Removing the one sanctioned
        // handover first and asserting the token appears nowhere in what remains says what was
        // meant: no other store reaches this runner. Comment-immune, because `MacAgentSource.read`
        // strips both comment syntaxes before this sees the text.
        let withoutTheSanctionedHandover = scheduledRun.replacingOccurrences(
            of: "recentArtifactStore: recentArtifactStoreForScheduledRun",
            with: ""
        )
        #expect(!withoutTheSanctionedHandover.contains("recentArtifactStore"))
    }

    // MARK: - The master switch

    @Test
    func theMasterSwitchOffStopsEveryTypeAtOnce() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryEnabled(false)

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()

        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()

        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(try fixture.routineStore.loadAll().isEmpty)
        for category in MemoryCategory.allCases {
            #expect(!fixture.viewModel.isMemoryCategoryEnabled(category), "\(category.title) still on")
        }
    }

    /// The founder's requirement, verbatim: the master switch stops new recording and leaves what is
    /// already stored alone.
    @Test
    func theMasterSwitchLeavesExistingEntriesInPlace() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        #expect(try fixture.taskHistoryStore.loadAll().count == 1)

        fixture.viewModel.setMemoryEnabled(false)

        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
        fixture.viewModel.refreshTaskHistory()
        #expect(fixture.viewModel.taskHistoryRecords.count == 1)
    }

    /// A wipe deletes every store file; it must not also switch memory back on for the person who
    /// reached for the most privacy-minded control in the app.
    @Test
    func theMemorySwitchesSurviveALocalDataWipe() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.setMemoryEnabled(false)

        fixture.viewModel.deleteLocalData()

        #expect(!fixture.viewModel.memorySettings.isRecording)
        // And a fresh view model over the same defaults reads the same answer, so this is the store's
        // durability rather than one instance's memory of it.
        let reopened = try makeMemoryFixture(reusing: fixture)
        #expect(!reopened.viewModel.memorySettings.isRecording)
    }

    // MARK: - The enterprise hook

    @Test
    func anAdministratorsPolicyStopsRecordingAndTakesTheSwitchAwayFromTheUser() async throws {
        let fixture = try makeMemoryFixture(
            policyProvider: StubMemoryPolicyProvider(
                policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: true)
            )
        )
        defer { fixture.cleanUp() }

        #expect(fixture.viewModel.memorySettings.isDisabledByPolicy)
        #expect(!fixture.viewModel.memorySettings.isRecording)

        // The user's own switch does not move the effective value. **What this does not check is
        // whether it was stored** — `isRecording` folds the policy in on the read side, so it
        // answers false whether the setter refused or wrote and was overridden. That half is
        // `anAdministratorsPolicyStopsTheSwitchesBeingStoredAtAll` below, and it exists because this
        // test's own wording used to claim it (PR #98 review, F1).
        fixture.viewModel.setMemoryEnabled(true)
        #expect(!fixture.viewModel.memorySettings.isRecording)
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: true)
        #expect(!fixture.viewModel.isMemoryCategoryEnabled(.taskHistory))

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
    }

    /// **The write guards, checked where a read cannot see them** (PR #98 review, F1).
    ///
    /// `setMemoryEnabled` and `setMemoryCategoryEnabled` both open with
    /// `guard !memorySettings.isDisabledByPolicy else { return }`, and the doc comment above them
    /// calls that guard load-bearing: a stored value nothing can honour is a switch that springs
    /// back the moment the policy lifts. **Removing both guards left the whole suite at exit 0.**
    /// The reason it hid is the shape worth remembering: the read side folds the policy in
    /// independently (`isRecording == isEnabledByUser && !isDisabledByPolicy`), so a broken write
    /// guard is masked by a correct read path, and every assertion phrased against the composed
    /// value passes for a reason unrelated to what it is named for.
    ///
    /// The only place the difference is visible is *after the policy lifts*, so this reopens a view
    /// model over the same `UserDefaults` with an unmanaged provider — the pattern
    /// `theMemorySwitchesSurviveALocalDataWipe` already establishes — and asks what was stored.
    @Test
    func anAdministratorsPolicyStopsTheSwitchesBeingStoredAtAll() throws {
        let managed = try makeMemoryFixture(
            policyProvider: StubMemoryPolicyProvider(
                policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: true)
            )
        )
        defer { managed.cleanUp() }
        #expect(managed.viewModel.memorySettings.isDisabledByPolicy)

        // Both setters, in the direction that would leave a visible mark: off. Under the policy they
        // must write nothing at all.
        managed.viewModel.setMemoryEnabled(false)
        managed.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)

        let unmanaged = try makeMemoryFixture(reusing: managed)

        #expect(
            unmanaged.viewModel.memorySettings.isRecording,
            "the master switch was stored under a policy that could not honour it, so it springs back off"
        )
        #expect(
            unmanaged.viewModel.memorySettings.allowsRecording(in: .taskHistory),
            "a per-type switch was stored under a policy that could not honour it"
        )
        #expect(unmanaged.viewModel.memorySettings.categoriesDisabledByUser.isEmpty)
    }

    /// **The control for the test above, and it is not optional.** "Nothing was stored" is equally
    /// true of setters that never store anything, which is the failure mode this whole pair exists
    /// to close. Same reopen, no policy: both setters must leave a mark that outlives the view model
    /// that made it.
    @Test
    func aSwitchTheUserSetsIsStoredAndOutlivesTheViewModelThatSetIt() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.setMemoryEnabled(false)
        fixture.viewModel.setMemoryCategoryEnabled(.snippets, to: false)

        let reopened = try makeMemoryFixture(reusing: fixture)

        #expect(!reopened.viewModel.memorySettings.isEnabledByUser)
        #expect(reopened.viewModel.memorySettings.categoriesDisabledByUser == [.snippets])
    }

    /// The hook is inert as it ships: the default provider restricts nothing, so a fixture that does
    /// not inject one records exactly as it always did.
    @Test
    func theShippedPolicyProviderLeavesEveryTypeRecording() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        #expect(!fixture.viewModel.memorySettings.isDisabledByPolicy)
        #expect(!fixture.viewModel.memorySettings.policy.isManaged)
        for category in MemoryCategory.allCases {
            #expect(fixture.viewModel.isMemoryCategoryEnabled(category))
        }
    }

    // MARK: - The two stores withheld by handing over nothing

    /// **Recent artifacts and the vision journal, on the memory half of the conjunction** (PR #98
    /// review, F2). `ProductShellTests.aSuppressedRunIsHandedNoRecentArtifactStore` and
    /// `aSuppressedRunIsHandedNoVisionSessionJournal` flip only `taskRecordingPolicy`, so these two
    /// types had their memory switch verified by reading the shared `allowsRecording(to:)` rather
    /// than by exercising it.
    ///
    /// **Asserted at the seam rather than by dispatching, and that is the correct instrument here,
    /// not a shortcut.** `recentArtifactStoreForThisRun`'s own doc records why: no command the
    /// fixtures can run generates an artifact, so a suppressed run leaves that store untouched
    /// either way and an end-to-end assertion passes for the wrong reason — a mutation battery
    /// caught exactly that. The vision journal is worse: the vision tests inject their own
    /// substrate, so no test in this repository can execute the live decision at all. (This used to
    /// say `makeVisionEnvironment` returns nil without an API key as well — SONNY-131 made it
    /// non-Optional and SONNY-136 deleted the key, so the injection is the whole reason now.) Row I built a `nil` store as "run the session, record
    /// nothing", which is what makes asserting the handover the same thing as asserting the
    /// suppression.
    ///
    /// **The first half of that premise stopped being true in this file** (SONNY-209). `planDrafting`
    /// below runs a real `create_local_draft`, which writes a real file, and `.createLocalDraft` is on
    /// `RecentArtifactStore.shouldRecordPreviewWrites`' operation list — so a dispatch here really
    /// would reach the recent-artifacts store now. The seam assertion is kept anyway: it is the
    /// stronger instrument for a decision that has to hold on paths this suite cannot dispatch, and
    /// the vision half is unreachable end to end either way. Recorded rather than acted on, because
    /// rewriting this test is that store's work and not this ticket's.
    @Test
    func theRecentArtifactAndVisionJournalHandoversAreWithheldByTheMemorySwitchesToo() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        // Control: nothing switched off, both stores handed over.
        #expect(fixture.viewModel.recentArtifactStoreForThisRun != nil)
        #expect(fixture.viewModel.visionSessionJournalStoreForThisRun != nil)

        // Recent artifacts is its own row, so its switch withholds its store and only its store.
        fixture.viewModel.setMemoryCategoryEnabled(.recentArtifacts, to: false)
        #expect(fixture.viewModel.recentArtifactStoreForThisRun == nil)
        #expect(
            fixture.viewModel.visionSessionJournalStoreForThisRun != nil,
            "the vision journal belongs to task history, not to recent artifacts"
        )

        // The journal is one of task history's four files, so that row's switch is what withholds it.
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: false)
        #expect(fixture.viewModel.visionSessionJournalStoreForThisRun == nil)

        // Both back on, so the master switch below is measured against a live handover rather than
        // against two already-withheld stores.
        fixture.viewModel.setMemoryCategoryEnabled(.recentArtifacts, to: true)
        fixture.viewModel.setMemoryCategoryEnabled(.taskHistory, to: true)
        #expect(fixture.viewModel.recentArtifactStoreForThisRun != nil)
        #expect(fixture.viewModel.visionSessionJournalStoreForThisRun != nil)

        fixture.viewModel.setMemoryEnabled(false)
        #expect(fixture.viewModel.recentArtifactStoreForThisRun == nil)
        #expect(fixture.viewModel.visionSessionJournalStoreForThisRun == nil)
    }

    /// The other half of the conjunction still works, unchanged — a suppressed *run* withholds both
    /// stores with every memory switch on. Without this the test above could pass over a build where
    /// `allowsRecording(to:)` had quietly dropped the `taskRecordingPolicy` term.
    @Test
    func aSuppressedRunStillWithholdsBothStoresWithEveryMemorySwitchOn() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.viewModel.memorySettings.isRecording)

        fixture.viewModel.taskRecordingPolicy = .suppressTraces

        #expect(fixture.viewModel.recentArtifactStoreForThisRun == nil)
        #expect(fixture.viewModel.visionSessionJournalStoreForThisRun == nil)
    }

    // MARK: - Clipboard history, the one type whose switch already existed

    @Test
    func theClipboardRowDrivesTheSettingItAlreadyHadRatherThanASecondFlag() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.setMemoryCategoryEnabled(.clipboardHistory, to: false)

        // The existing encrypted setting is what changed — not a new preference beside it.
        #expect(try fixture.clipboardSettingsStore.load().isEnabled == false)
        #expect(!fixture.viewModel.isMemoryCategoryEnabled(.clipboardHistory))
        // The master switch is untouched, so this really was the per-type control.
        #expect(fixture.viewModel.memorySettings.isRecording)

        fixture.viewModel.setMemoryCategoryEnabled(.clipboardHistory, to: true)
        #expect(try fixture.clipboardSettingsStore.load().isEnabled)
        #expect(fixture.viewModel.isMemoryCategoryEnabled(.clipboardHistory))
    }

    /// With memory off wholesale, clipboard history reads off even though its own setting still says
    /// on — the surface reporting what is actually happening rather than what was last chosen.
    @Test
    func theMasterSwitchOffMakesTheClipboardRowReadOffWithoutRewritingItsSetting() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.setMemoryEnabled(false)

        #expect(!fixture.viewModel.isMemoryCategoryEnabled(.clipboardHistory))
        #expect(try fixture.clipboardSettingsStore.load().isEnabled, "the user's own choice was rewritten")
    }

    /// The control for the test below, and it is not optional: without it, "nothing was recorded"
    /// is equally true of a fixture whose monitor could never have recorded anything.
    @Test
    func theClipboardMonitorRecordsWhileMemoryIsOn() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.clipboardSettingsStore.save(
            ClipboardHistorySettings(noticeDismissed: true, isEnabled: true)
        )
        fixture.pasteboard.text = "something copied"
        fixture.pasteboard.changeCount = 1

        fixture.viewModel.refreshClipboardHistoryNotice()

        #expect(try fixture.clipboardHistoryStore.loadAll().map(\.text) == ["something copied"])
    }

    /// **The master switch has to stop the clipboard *timer*, not merely answer a question.**
    ///
    /// Every other type is withheld by a guard consulted at write time; clipboard history is a 1s
    /// poll that records on its own, so a switch that only changed what a row displayed would leave
    /// it recording.
    ///
    /// **Memory is switched off before monitoring has ever started, and that ordering is the whole
    /// test.** `startClipboardHistoryMonitoring` returns early when a timer already exists, so a
    /// version of this that switched off *after* the control had started one would pass with the
    /// guard deleted — nothing polls, nothing records, and the assertion holds for the wrong reason.
    /// Measured: written that way, mutant M5 (the guard removed) survived the whole suite. From a
    /// stopped start, `setMemoryEnabled(false)`'s own `refreshClipboardHistoryNotice()` reaches a nil
    /// timer, so without the guard it starts monitoring and its first poll records — and the mutant
    /// dies.
    @Test
    func theMasterSwitchStopsTheClipboardMonitorRatherThanJustTheRowItRenders() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.clipboardSettingsStore.save(
            ClipboardHistorySettings(noticeDismissed: true, isEnabled: true)
        )
        fixture.pasteboard.text = "copied while memory was off"
        fixture.pasteboard.changeCount = 1

        fixture.viewModel.setMemoryEnabled(false)

        #expect(try fixture.clipboardHistoryStore.loadAll().isEmpty)
        // Asked again, from the surface that starts monitoring at every other opportunity.
        fixture.viewModel.refreshClipboardHistoryNotice()
        #expect(try fixture.clipboardHistoryStore.loadAll().isEmpty)
        // And the user's own clipboard setting was not rewritten to achieve any of it.
        #expect(try fixture.clipboardSettingsStore.load().isEnabled)
    }

    // MARK: - Allowed apps

    @Test
    func allowedAppsMemoryOffRefusesToKeepANewGrant() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        #expect(fixture.viewModel.rememberAppControlGrant(bundleIdentifier: "com.apple.Safari", displayName: "Safari"))
        #expect(try fixture.approvedAppStore.loadAll().count == 1)

        fixture.viewModel.setMemoryCategoryEnabled(.approvedApps, to: false)

        // `false` is what ends the session at `VisionSessionRunner.resolveAppControl` — never running
        // on a grant that does not exist.
        #expect(!fixture.viewModel.rememberAppControlGrant(bundleIdentifier: "com.apple.Notes", displayName: "Notes"))
        #expect(try fixture.approvedAppStore.loadAll().map(\.bundleIdentifier) == ["com.apple.Safari"])
    }

    // MARK: - Delete

    @Test
    func deletingOneMemoryTypeLeavesEveryOtherTypeAlone() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.memoryEntryCount(for: .snippets) == 1)

        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(try fixture.snippetStore.loadAll().isEmpty)
        #expect(fixture.viewModel.memoryEntryCount(for: .snippets) == 0)
        #expect(try fixture.routineStore.findRoutine(named: "Morning") != nil)
        #expect(fixture.viewModel.memoryEntryCount(for: .routines) == 1)
        #expect(try #require(fixture.viewModel.memoryDeletionStatusMessage).hasPrefix("Deleted snippets"))
    }

    /// Deleting task-history memory takes the records that hang off a row with it. A delete that left
    /// the plan of every task and every screen record behind would be the row's own delete-ordering
    /// rule broken one level up.
    @Test
    func deletingTaskHistoryMemoryTakesThePlanDetailsAndScreenRecordsWithIt() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: fixture.taskHistoryStore.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))

        fixture.viewModel.deleteMemory(in: .taskHistory)

        #expect(!FileManager.default.fileExists(atPath: fixture.taskHistoryStore.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
        #expect(fixture.viewModel.taskHistoryRecords.isEmpty)
    }

    /// Both halves of the guard, and the approval half is the one that matters: a run paused at its
    /// approval has `isRunning == false` and is about to write into the very file this deletes.
    @Test
    func deletingAMemoryTypeIsRefusedWhileATaskIsInFlight() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        fixture.viewModel.isRunning = true

        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(try fixture.snippetStore.loadAll().count == 1)
        #expect(try #require(fixture.viewModel.errorMessage).contains("Finish or stop the current task"))

        fixture.viewModel.isRunning = false
        fixture.viewModel.errorMessage = nil
        fixture.viewModel.approvalRequest = RiskApprovalRequest(
            assessment: CapabilityRiskAssessment(defaultTier: .tier3),
            requirement: .explicitApproval
        )
        #expect(fixture.viewModel.isAwaitingApproval)

        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(try fixture.snippetStore.loadAll().count == 1)
        #expect(try #require(fixture.viewModel.errorMessage).contains("Finish or stop the current task"))
    }

    @Test
    func aPerEntryDeleteRemovesOneRecordAndRepublishesTheList() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        try fixture.snippetStore.save(StoredSnippet(trigger: ";addr", expansion: "address"))
        try fixture.approvedAppStore.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        try fixture.approvedAppStore.approve(bundleIdentifier: "com.apple.Notes", displayName: "Notes")
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.savedSnippets.count == 2)

        // Through the sheet's own entry point — by position into the list it rendered.
        fixture.viewModel.deleteMemoryEntry(in: .snippets, at: 0)
        fixture.viewModel.deleteMemoryEntry(in: .approvedApps, at: 0)

        #expect(fixture.viewModel.savedSnippets.map(\.trigger) == [";sig"])
        #expect(try fixture.snippetStore.loadAll().keys.sorted() == [";sig"])
        #expect(fixture.viewModel.approvedApps.count == 1)
        #expect(try fixture.approvedAppStore.loadAll().count == 1)

        // Out of range is a no-op — the array can shrink under a sheet that is still on screen.
        fixture.viewModel.deleteMemoryEntry(in: .snippets, at: 7)
        #expect(fixture.viewModel.savedSnippets.count == 1)
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// The three types with pages of their own never reach the sheet's delete, and asking it to
    /// delete one of them does nothing rather than something surprising.
    @Test
    func theSheetsDeleteDoesNothingForTheTypesThatHaveTheirOwnPages() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()

        fixture.viewModel.deleteMemoryEntry(in: .routines, at: 0)
        fixture.viewModel.deleteMemoryEntry(in: .taskHistory, at: 0)

        #expect(try fixture.routineStore.findRoutine(named: "Morning") != nil)
        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
    }

    @Test
    func aWholeDataWipeEmptiesTheMemorySectionsOwnLists() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        try fixture.approvedAppStore.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.savedSnippets.count == 1)
        #expect(fixture.viewModel.approvedApps.count == 1)

        fixture.viewModel.deleteLocalData()

        // Without `refreshMemoryEntries()` inside the wipe these lists keep rendering entries whose
        // files were just erased.
        #expect(fixture.viewModel.savedSnippets.isEmpty)
        #expect(fixture.viewModel.approvedApps.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == nil)
    }

    // MARK: - SONNY-239: a store whose file will not read

    /// **The state the founder met on 2026-08-23, and the three things that were wrong with it.**
    ///
    /// `output-locations.json` held bytes written under another key. The row said `0 saved`, which is
    /// what a store nobody has ever used says; Delete was greyed out, which reads as "there is
    /// nothing here to remove"; and the only recovery anywhere in the product was Settings' wipe of
    /// all thirteen stores. The count really is zero — `loadMemoryEntries` empties the list rather
    /// than leaving it stale — so a fix gated on entries existing reproduces the dead end exactly.
    @Test
    func anUnreadableRowSaysSoInsteadOfACountOfZeroAndKeepsItsDeleteLive() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)

        fixture.memoryPageAppears()

        let row = MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel)
        #expect(row.readability == .unreadable)
        #expect(row.count == 0, "the count is zero, which is the whole difficulty")
        #expect(row.detailText == "Can't be read")
        #expect(row.canDelete, "Delete must be live at a count of zero, or the dead end is intact")

        // The control, in both directions: a genuinely empty row is still an empty row.
        let empty = MemoryRowPresentation.row(for: .snippets, viewModel: fixture.viewModel)
        #expect(empty.readability == .readable)
        #expect(empty.detailText == "0 snippets")
        #expect(!empty.canDelete)
    }

    /// The repair, end to end, from the count of zero the row reports.
    @Test
    func deletingAnUnreadableRowMovesTheFileAsideAndTheRowReadsAgain() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.localStorageNotice != nil)

        fixture.viewModel.deleteMemory(in: .outputLocations)

        // The store works again, which is what "starts over" has to mean.
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        #expect(try fixture.outputLocationStore.loadAll().count == 1)

        // The row and the banner both stop saying it is broken.
        #expect(!fixture.viewModel.unreadableStores.contains(.outputLocations))
        #expect(fixture.viewModel.localStorageNotice == nil)
        #expect(MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel).readability == .readable)

        // And nothing was destroyed (founder decision, 2026-08-23; SONNY-253 is why).
        let setAside = LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL)
        #expect(setAside.count == 1)
        #expect(try Data(contentsOf: try #require(setAside.first)) == original)
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage)
                == "Output locations starts over. The file Sonny could not read is still on your Mac."
        )
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// **A readable row is still deleted, and that is not a detail.** Every sentence in
    /// `MemoryDeletionCopy.message(for:)` promises removal — "This deletes every copied item Sonny
    /// has recorded" — and a Delete that quietly renamed the file instead would make each of them
    /// false while leaving the bytes on disk. Moving aside is the answer to "Sonny cannot tell
    /// whether this is garbage", which does not arise when the file reads.
    @Test
    func deletingAReadableRowStillRemovesItsFileWithNothingLeftBehind() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.memoryEntryCount(for: .outputLocations) == 1)

        fixture.viewModel.deleteMemory(in: .outputLocations)

        #expect(!FileManager.default.fileExists(atPath: fixture.outputLocationStore.fileURL.path))
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).isEmpty)
        // The wording is the one this page has always used, unchanged for a row with nothing wrong.
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage) == "Deleted output locations — 1 file."
        )
    }

    /// **Per store, not per row** — the case a row-level answer gets wrong.
    ///
    /// Task history covers four files. With one of them unreadable, keeping all four would leave the
    /// user's actual command history on disk after they pressed a control whose confirmation says it
    /// deletes every task Sonny has recorded; deleting all four would destroy the one file Sonny
    /// cannot prove is garbage. The split is decided per file, from the load failures the view model
    /// is actually holding.
    @Test
    func aRowWithOneUnreadableFileAmongSeveralDeletesTheOnesThatRead() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        // A real run, so task history and its plan detail both exist on disk.
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        #expect(try fixture.taskHistoryStore.loadAll().count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))

        // Now break only the plan-detail half, and let the view model discover it the way opening a
        // task's detail would.
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        // `followUpOnTask` is the real product path that reads this store — it is what the Tasks
        // page's follow-up does — and it routes a failure to the same load-failure channel.
        let record = try #require(fixture.viewModel.taskHistoryRecords.first)
        _ = fixture.viewModel.followUpOnTask(record)
        fixture.viewModel.refreshStoreReadability()
        #expect(fixture.viewModel.unreadableStores == [.taskPlanDetails])

        fixture.viewModel.deleteMemory(in: .taskHistory)

        // The file that read is gone, with nothing set aside from it.
        #expect(!FileManager.default.fileExists(atPath: fixture.taskHistoryStore.fileURL.path))
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.taskHistoryStore.fileURL).isEmpty)
        // The file that did not is kept, under its own name.
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.taskPlanDetailStore.fileURL).count == 1)
        // And the row recovers, which needs the plan-detail source cleared — nothing in
        // `refreshMemorySurfaces()` reloads that store.
        #expect(fixture.viewModel.unreadableStores.isEmpty)
        #expect(fixture.viewModel.localStorageNotice == nil)
    }

    /// The banner names the control that repairs this, rather than stopping at an accurate sentence
    /// the reader can do nothing with (founder decision, 2026-08-23).
    @Test
    func theBannerForAnUnreadableStoreNamesTheWayOut() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)

        fixture.viewModel.refreshMemoryEntries()

        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not load encrypted local data."))
        #expect(notice.contains("where your outputs usually go"))
        #expect(notice.hasSuffix(" Open Memory in Command Center to clear it."))

        // Once, not twice, however many stores are broken — the sentence is appended to the banner
        // rather than to each store's detail. And it counts: the founder's own case was two broken
        // files, where a singular pronoun covered both (PR #110 review).
        try fixture.writeUnreadableFile(at: fixture.snippetStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()
        let both = try #require(fixture.viewModel.localStorageNotice)
        #expect(both.components(separatedBy: "Open Memory in Command Center").count - 1 == 1)
        #expect(both.hasSuffix(" Open Memory in Command Center to clear them."))
    }

    /// The confirmation is honest about the two things Sonny cannot otherwise be honest about here:
    /// it does not know what is in the file, and it is keeping it.
    @Test
    func theConfirmationForAnUnreadableRowAdmitsWhatSonnyCannotSeeAndSaysTheFileIsKept() {
        let readable = MemoryDeletionCopy.message(for: .outputLocations)
        let unreadable = MemoryDeletionCopy.unreadableMessage(for: .outputLocations)

        #expect(unreadable != readable)
        #expect(unreadable.contains("can't read this"))
        #expect(unreadable.contains("can't tell you what's in it"))
        #expect(unreadable.contains("keeps the file"))
        #expect(unreadable.contains("Output locations starts over"))
        // The readable sentence still promises removal, which is what makes the two different.
        #expect(readable.contains("This deletes"))
        #expect(!readable.contains("keeps the file"))
    }

    /// The sheet a user opens *because* the row said zero must not then tell them the store is empty
    /// and offer them the command that fills it.
    ///
    /// **Asserted through `emptyStateTitle`/`emptyStateMessage`, which is what the sheet calls**
    /// (PR #110 fix round). The first version read the two leaf strings directly, so a mutant that
    /// made the dispatcher return the empty-state wording for *both* readabilities survived the
    /// whole suite — the same shape as the defect F7 is about, one function along.
    @Test
    func theSheetForAnUnreadableRowDoesNotClaimTheStoreIsEmpty() {
        let readable = MemoryDeletionCopy.emptyStateMessage(for: .outputLocations, readability: .readable)
        #expect(readable == "Ask Sonny to save a file somewhere, and the folder will appear here.")
        #expect(MemoryDeletionCopy.emptyStateTitle(for: .outputLocations, readability: .readable) == "No output locations yet")
        #expect(MemoryDeletionCopy.emptyStateSystemImage(for: .readable) == "tray")

        #expect(
            MemoryDeletionCopy.emptyStateTitle(for: .outputLocations, readability: .unreadable)
                == "Sonny can't read your output locations"
        )
        let message = MemoryDeletionCopy.emptyStateMessage(for: .outputLocations, readability: .unreadable)
        // Paired with the command that ends the state, exactly as the empty states are — except the
        // command is a control on the page behind this sheet.
        #expect(message.contains("Press Delete on the output locations row"))
        #expect(message.contains("The file stays on your Mac."))
        #expect(MemoryDeletionCopy.emptyStateSystemImage(for: .unreadable) != "tray")
    }

    // MARK: - PR #110 review: what the first round got wrong

    /// **F1 — a damaged store must not turn every copy into a notification.**
    ///
    /// `recordLocalStorageLoadFailure` reassigned `localStorageNotice` unconditionally, which was
    /// harmless while its only callers were a page appearing and two deletes the user pressed.
    /// SONNY-246 gave it one that fires on every recorded clipboard item — up to once a second — and
    /// `AppDelegate` sinks that publisher with no `removeDuplicates()` into a notification whose
    /// identifier is a fresh `UUID()`, so nothing replaces anything. With the founder's two broken
    /// files that was two Notification Center banners per copy, and the widget's own notice back the
    /// moment after he dismissed it.
    ///
    /// Emissions are the thing that has to be zero, not the final value: `AppDelegate` posts one
    /// notification per non-nil emission, so a banner that is reassigned to the same string is still
    /// a second notification.
    @Test
    func anUnchangedLoadFailureRepublishesNothingAndLeavesADismissedBannerDismissed() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.clipboardSettingsStore.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)

        var emissions = 0
        let subscription = fixture.viewModel.$localStorageNotice
            .dropFirst()
            .sink { _ in emissions += 1 }
        defer { subscription.cancel() }

        fixture.memoryPageAppears()
        #expect(emissions == 1, "the first discovery must publish")
        #expect(fixture.viewModel.localStorageNotice != nil)

        // The user dismisses it, exactly as the widget's Dismiss does.
        fixture.viewModel.localStorageNotice = nil
        let afterDismissal = emissions

        // Three copies, which is three seconds of ordinary work with the page open.
        for index in 0..<3 {
            fixture.pasteboard.text = "copied \(index)"
            fixture.pasteboard.changeCount += 1
            #expect(fixture.viewModel.pollClipboardHistory())
        }

        #expect(emissions == afterDismissal, "a copy republished the notice \(emissions - afterDismissal) time(s)")
        #expect(fixture.viewModel.localStorageNotice == nil, "the dismissed banner came back")
        // The row still says so, which is where an ongoing condition belongs — the banner is for
        // news, the row is for state. Probed here rather than assumed: the clipboard poll reloads
        // the lists, not the readability set, so this is the answer from the page's own appearance.
        #expect(fixture.viewModel.unreadableStores.contains(.outputLocations))
        // And the copies really were recorded, so the silence above is the guard rather than a
        // clipboard monitor that never ran.
        #expect(fixture.viewModel.clipboardHistoryItems.count == 3)
    }

    /// A genuinely new failure still publishes, which is what stops the guard above from being a mute.
    @Test
    func aSecondStoreBreakingIsNewsAndStillPublishes() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()
        fixture.viewModel.localStorageNotice = nil

        try fixture.writeUnreadableFile(at: fixture.snippetStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()

        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("where your outputs usually go"))
        #expect(notice.contains("snippets"))
    }

    /// **F2 — an ordinary Delete must not destroy the file the previous press promised to keep.**
    ///
    /// The per-row Delete used to call `deleteAllLocalData()`, which sweeps every set-aside sibling
    /// of the files it is given. So: repair a broken row, use it for weeks, then delete it for the
    /// ordinary reason, and the bytes SONNY-253 exists to rescue were unlinked — reported inside a
    /// count of files the user cannot see, and contradicting `LocalDataQuarantine`'s own doc comment.
    @Test
    func anOrdinaryDeleteOnARowThatRecoveredKeepsTheFileTheEarlierRepairSetAside() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let quarantine = LocalDataQuarantine()

        // 1. The file will not read, and the user clears it.
        let original = try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(quarantine.quarantinedSiblings(of: fixture.outputLocationStore.fileURL).count == 1)

        // 2. The store works again and the row fills up.
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        fixture.viewModel.refreshMemoryEntries()
        #expect(MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel).readability == .readable)

        // 3. Weeks later, an ordinary Delete for the ordinary reason.
        fixture.viewModel.deleteMemory(in: .outputLocations)

        #expect(!FileManager.default.fileExists(atPath: fixture.outputLocationStore.fileURL.path))
        let setAside = quarantine.quarantinedSiblings(of: fixture.outputLocationStore.fileURL)
        #expect(setAside.count == 1, "the kept file was destroyed by an ordinary Delete")
        #expect(try Data(contentsOf: try #require(setAside.first)) == original)
        // And the figure the user is shown counts only what they can see.
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage) == "Deleted output locations — 1 file."
        )
    }

    /// The other half of F2: Settings' whole wipe is still the one door that takes them, so keeping
    /// them out of the per-row Delete does not leave a privacy hole.
    @Test
    func settingsWholeWipeStillTakesASetAsideFile() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.viewModel.refreshMemoryEntries()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).count == 1)

        fixture.viewModel.deleteLocalData()

        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).isEmpty)
    }

    // MARK: - SONNY-266: the set-aside files have a line and a control on Settings' Data page

    /// **The per-row Delete that keeps a file is the one press that adds to Settings' count, and the
    /// count follows that press rather than waiting for the Data page to appear.** The user was told
    /// the file was kept and never how many or how much space; this is the number and the size.
    @Test
    func aPerRowDeleteThatKeepsAFileIsCountedAndSizedForTheDataPage() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
        let original = try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()

        fixture.viewModel.deleteMemory(in: .outputLocations)

        #expect(
            fixture.viewModel.setAsideFilesSummary
                == SetAsideFilesSummary(fileCount: 1, byteCount: Int64(original.count))
        )
        #expect(!fixture.viewModel.setAsideFilesSummary.isEmpty)
    }

    /// A file set aside before this launch — by a previous run of the app, or moved there by hand —
    /// is found by looking, which is what the Data page's appearance does.
    @Test
    func theDataPageFindsAFileSetAsideBeforeThisLaunch() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        let bytes = Data("from a previous launch".utf8)
        try bytes.write(to: fixture.snippetStore.fileURL, options: .atomic)
        _ = try LocalDataQuarantine().moveAside(fixture.snippetStore.fileURL)
        #expect(fixture.viewModel.setAsideFilesSummary == .none, "nothing has looked yet")

        fixture.viewModel.refreshSetAsideFiles()

        #expect(
            fixture.viewModel.setAsideFilesSummary
                == SetAsideFilesSummary(fileCount: 1, byteCount: Int64(bytes.count))
        )
    }

    /// **The control removes exactly the set-aside files, reports it on the Data page's own slot,
    /// and leaves every live store alone** — the one that was set aside and is in use again, and one
    /// that was never broken.
    @Test
    func deletingTheSetAsideFilesFromSettingsRemovesThemAndLeavesEveryStoreAlone() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "calc",
                        operation: .calculateUtility,
                        description: "Calculate 1 + 1.",
                        searchQuery: "1 + 1"
                    )
                ]
            )
        )
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 1)
        // Stale on purpose, so the success branch's clearing of it is pinned rather than inherited
        // from a fixture that starts at `nil` (PR #117 review, R8).
        fixture.viewModel.errorMessage = "an earlier failure"

        fixture.viewModel.deleteSetAsideFiles()

        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).isEmpty)
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
        #expect(try fixture.outputLocationStore.loadAll().count == 1, "the live store was touched")
        #expect(try fixture.routineStore.loadAll().count == 1, "an unrelated store was touched")
        #expect(fixture.viewModel.localDataDeletionStatusMessage == "Deleted 1 file Sonny could not read.")
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// **The Memory page's sentence about a kept file, and the Reveal control beside it, go when the
    /// file does.** "The file Sonny could not read is still on your Mac." was true until this press;
    /// a control offering to show a file that is gone is the same stale surface the wipe already
    /// clears.
    @Test
    func deletingTheSetAsideFilesRetiresTheMemoryPagesSentenceAboutThem() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 1)
        #expect(try #require(fixture.viewModel.memoryDeletionStatusMessage).contains("still on your Mac"))

        fixture.viewModel.deleteSetAsideFiles()

        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == nil)
    }

    /// And a sentence about a delete that kept nothing is still true after this press, so it stays —
    /// the retirement above is evidence-based, not a blanket clear.
    @Test
    func deletingTheSetAsideFilesLeavesAReadableDeletesSentenceStanding() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        // Set aside earlier, from a store other than the one about to be deleted for the ordinary
        // reason.
        try Data("kept".utf8).write(to: fixture.snippetStore.fileURL, options: .atomic)
        _ = try LocalDataQuarantine().moveAside(fixture.snippetStore.fileURL)
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(atPaths: [reports.appendingPathComponent("a.md").path])
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == "Deleted output locations — 1 file.")
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 1)

        fixture.viewModel.deleteSetAsideFiles()

        #expect(fixture.viewModel.memoryDeletionStatusMessage == "Deleted output locations — 1 file.")
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
    }

    /// The whole wipe sweeps these files itself, so the line goes to nothing with it.
    @Test
    func theWholeWipeBringsTheDataPagesCountToNothing() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 1)

        fixture.viewModel.deleteLocalData()

        #expect(fixture.viewModel.setAsideFilesSummary == .none)
    }

    /// **The control refuses during a run, by founder decision (PR #117 review, F3).** The first
    /// version carried no guard, on the argument that nothing this deletes can change under a run —
    /// which is still true, and is the second half asserted here. The reason for the guard is the
    /// other channel: a failure goes to `errorMessage`, which is suppressed while `isRunning` and
    /// outranks the task's result once it ends, so a control that could fail mid-run would report a
    /// task that succeeded as its own failure. The wipe's guard, the wipe's condition.
    @Test
    func theSetAsideFilesCannotBeDeletedWhileATaskIsRunning() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        let before = fixture.viewModel.setAsideFilesSummary
        #expect(before.fileCount == 1)
        fixture.viewModel.isRunning = true
        defer { fixture.viewModel.isRunning = false }

        fixture.viewModel.deleteSetAsideFiles()

        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).count == 1)
        #expect(fixture.viewModel.setAsideFilesSummary == before)
        #expect(fixture.viewModel.errorMessage == "Stop the current run before deleting the files Sonny could not read.")
        #expect(fixture.viewModel.localDataDeletionStatusMessage == nil)
        // A refused press leaves the Memory page's sentence and its control exactly as they were.
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 1)

        // The population half, still true: nothing can add to these files while a task runs.
        try fixture.writeUnreadableFile(at: fixture.snippetStore.fileURL)
        fixture.viewModel.deleteMemory(in: .snippets)
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.snippetStore.fileURL).isEmpty)
        #expect(fixture.viewModel.errorMessage?.contains("Finish or stop the current task") == true)
    }

    /// Nothing was there by the time the control was pressed — the files went by hand, or with the
    /// wipe in another window. The line says so rather than reporting "Deleted 0 files".
    @Test
    func pressingTheControlAfterTheFilesAlreadyWentSaysSo() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        let setAside = try #require(
            LocalDataQuarantine().quarantinedSiblings(of: fixture.outputLocationStore.fileURL).first
        )
        try FileManager.default.removeItem(at: setAside)

        fixture.viewModel.deleteSetAsideFiles()

        #expect(
            fixture.viewModel.localDataDeletionStatusMessage
                == "The files Sonny could not read were already gone."
        )
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
        #expect(fixture.viewModel.errorMessage == nil)
        // The Memory page's sentence was about a file that is gone, whoever removed it.
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == nil)
    }

    // MARK: - PR #117 review, F1: a partial removal follows the files, at both doors, at n ≥ 2

    /// Sets or clears the user-immutable flag on one file, so an unlink of exactly that file is
    /// refused (`EPERM`) while its neighbours delete normally — the only way to make one press
    /// remove some of the files it was asked for and fail on the rest. Locking the directory
    /// refuses every unlink in it, which is a different case. Owner and root are both refused while
    /// the flag is set, so these tests need no privilege gate; the flag is cleared before the fixture
    /// is removed.
    private static func setImmutable(_ isImmutable: Bool, at fileURL: URL) throws {
        try FileManager.default.setAttributes([.immutable: isImmutable], ofItemAtPath: fileURL.path)
    }

    /// Two files kept by one press — the Task history row covers four stores — as the founder's
    /// replaced-Keychain case produces them. Returns the two set-aside files in the order the
    /// service's listing walks them.
    private static func keepTwoFilesFromOnePress(in fixture: MemoryFixture) throws -> (first: URL, second: URL) {
        try fixture.writeUnreadableFile(at: fixture.taskHistoryStore.fileURL)
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .taskHistory)
        let quarantine = LocalDataQuarantine()
        let first = try #require(quarantine.quarantinedSiblings(of: fixture.taskHistoryStore.fileURL).first)
        let second = try #require(quarantine.quarantinedSiblings(of: fixture.taskPlanDetailStore.fileURL).first)
        #expect(Set(fixture.viewModel.setAsideFilesFromLastDelete) == [first, second])
        #expect(
            fixture.viewModel.memoryDeletionStatusMessage
                == "Task history starts over. The 2 files Sonny could not read are still on your Mac."
        )
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 2)
        return (first, second)
    }

    /// **The Data page's control removes one of two kept files and fails on the other: the Memory
    /// page's sentence follows the files, and its Reveal control still names the one on disk.**
    ///
    /// The first version cleared the whole record when *any* named file was gone, so this press
    /// retired "The 2 files … are still on your Mac" and the control beside it while a file that
    /// sentence names was still there — and Reveal is the one surface that names it. Mutants that
    /// read "any" for "every", or prune only on success, all survived because every test kept
    /// exactly one file.
    @Test
    func aPartialRemovalFromTheDataPageKeepsTheMemoryPagesSentenceForTheFileStillOnDisk() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        let kept = try Self.keepTwoFilesFromOnePress(in: fixture)
        defer {
            try? Self.setImmutable(false, at: kept.second)
            fixture.cleanUp()
        }
        try Self.setImmutable(true, at: kept.second)

        fixture.viewModel.deleteSetAsideFiles()

        // The premise: one went, one did not.
        #expect(!FileManager.default.fileExists(atPath: kept.first.path))
        #expect(FileManager.default.fileExists(atPath: kept.second.path))
        // The Data page's own report, composed from what happened (F4), and the line still counting.
        let report = try #require(fixture.viewModel.localDataDeletionStatusMessage)
        #expect(report.hasPrefix("Could not delete 1 of the 2 files Sonny could not read: task-plan-details.json.unreadable-"))
        #expect(fixture.viewModel.errorMessage == report)
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 1)
        // The Memory page: the survivor still named, the sentence re-derived for one.
        #expect(fixture.viewModel.setAsideFilesFromLastDelete == [kept.second])
        #expect(
            fixture.viewModel.memoryDeletionStatusMessage
                == "Task history starts over. The file Sonny could not read is still on your Mac."
        )
    }

    /// The same press with nothing in its way: both go, and the sentence and the control go with
    /// them — "every named file gone" at n = 2, which the one-file tests could not tell from "any".
    @Test
    func removingBothKeptFilesFromTheDataPageRetiresTheSentenceAndTheControlTogether() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }
        _ = try Self.keepTwoFilesFromOnePress(in: fixture)

        fixture.viewModel.deleteSetAsideFiles()

        #expect(fixture.viewModel.localDataDeletionStatusMessage == "Deleted 2 files Sonny could not read.")
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == nil)
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
    }

    /// **The whole wipe is the other door, and a wipe that fails part-way never reaches the wipe's
    /// own clearing** — so its failure branch has to prune the record the same way, or the Memory
    /// page keeps naming a file the wipe removed.
    @Test
    func aPartialWipeKeepsTheMemoryPagesSentenceForTheFileStillOnDisk() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        let kept = try Self.keepTwoFilesFromOnePress(in: fixture)
        defer {
            try? Self.setImmutable(false, at: kept.second)
            fixture.cleanUp()
        }
        try Self.setImmutable(true, at: kept.second)

        fixture.viewModel.deleteLocalData()

        #expect(!FileManager.default.fileExists(atPath: kept.first.path))
        #expect(FileManager.default.fileExists(atPath: kept.second.path))
        #expect(try #require(fixture.viewModel.localDataDeletionStatusMessage).hasPrefix("Could not delete local data:"))
        #expect(fixture.viewModel.setAsideFilesSummary.fileCount == 1)
        #expect(fixture.viewModel.setAsideFilesFromLastDelete == [kept.second])
        #expect(
            fixture.viewModel.memoryDeletionStatusMessage
                == "Task history starts over. The file Sonny could not read is still on your Mac."
        )
    }

    /// **A failure sentence is about the step that failed, not the kept files, so a prune leaves it
    /// standing** — while the Reveal control, which is about the files, still goes when they do.
    ///
    /// The per-row press here fails its readable half (the live task-history file is immutable) and
    /// keeps its unreadable half; the Data page's control then removes the kept file.
    @Test
    func pruningLeavesAPerRowFailureSentenceStandingWhileItsControlGoes() async throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer {
            try? Self.setImmutable(false, at: fixture.taskHistoryStore.fileURL)
            fixture.cleanUp()
        }
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        try Self.setImmutable(true, at: fixture.taskHistoryStore.fileURL)
        fixture.memoryPageAppears()

        fixture.viewModel.deleteMemory(in: .taskHistory)

        let failure = try #require(fixture.viewModel.memoryDeletionStatusMessage)
        #expect(failure.hasPrefix("Could not delete task history:"))
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 1)

        fixture.viewModel.deleteSetAsideFiles()

        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
        #expect(fixture.viewModel.memoryDeletionStatusMessage == failure)
        #expect(fixture.viewModel.setAsideFilesSummary == .none)
    }

    /// **The prune rewrites the Memory page's sentence without reading it, and this is what makes
    /// that safe**: the sentence has exactly one writer besides the prune and the wipe's clearing —
    /// `deleteMemory(in:)`, which replaces the record in the same breath — so the sentence on screen
    /// is always the current record's. A second writer would make the prune overwrite a sentence
    /// about something else, and this scan is where that arrives as a red test.
    @Test
    func theMemoryPagesSentenceHasOneWriterBesidesThePrune() throws {
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")
        var writers: [String: Int] = [:]
        for owner in [
            "func deleteMemory(in category: MemoryCategory) {",
            "private func pruneLastPerRowDeleteToFilesStillOnDisk() {",
            "private func clearInMemoryLocalDataState() {"
        ] {
            let body = try MacAgentSource.braceBlock(of: viewModel, openedBy: owner)
            writers[owner] = MacAgentSource.count(of: "memoryDeletionStatusMessage = ", inText: body)
        }
        #expect(writers["func deleteMemory(in category: MemoryCategory) {"] == 1)
        #expect(writers["private func pruneLastPerRowDeleteToFilesStillOnDisk() {"] == 1)
        #expect(writers["private func clearInMemoryLocalDataState() {"] == 1)
        // And nowhere else in the target.
        var total = 0
        for file in try MacAgentSource.appSourceFiles() {
            total += MacAgentSource.count(of: "memoryDeletionStatusMessage = ", inText: try MacAgentSource.read(file))
        }
        #expect(total == 3, "memoryDeletionStatusMessage has \(total) writers; the prune assumes three")
    }

    /// **Each of the service's three doors is called exactly once in the app target, from the method
    /// that owns it** (PR #117 review, F5). A fourth caller of `deleteAllLocalData()` — PR #110's F2
    /// in a new place — failed nothing until now: the row's own scan pins only the button's action.
    /// The door names are unambiguous by construction: `deleteSetAsideFilesOnly()` was renamed
    /// beside `deleteStoreFilesOnly()` so this scan can tell it from the view model's
    /// `deleteSetAsideFiles()`.
    @Test
    func everyDeletionDoorIsCalledOnceFromTheMethodThatOwnsIt() throws {
        let doors: [(door: String, owner: String)] = [
            (".deleteAllLocalData()", "func deleteLocalData() {"),
            (".deleteStoreFilesOnly()", "func deleteMemory(in category: MemoryCategory) {"),
            (".deleteSetAsideFilesOnly()", "func deleteSetAsideFiles() {")
        ]
        let viewModel = try MacAgentSource.read("AgentViewModel.swift")
        var total: [String: Int] = [:]
        for file in try MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(file)
            for (door, _) in doors {
                total[door, default: 0] += MacAgentSource.count(of: door, inText: source)
            }
        }
        for (door, owner) in doors {
            #expect(total[door] == 1, "\(door) is called \(total[door] ?? 0) time(s) across Sources/MacAgent — one door, one caller")
            let body = try MacAgentSource.braceBlock(of: viewModel, openedBy: owner)
            #expect(MacAgentSource.count(of: door, inText: body) == 1, "\(door) is not called from \(owner)")
        }
    }

    /// **A file the control cannot delete stays counted and is named, rather than vanishing from
    /// the line because the control was pressed.** The Memory page's sentence about it is still
    /// true, so that stays too.
    ///
    /// Locking the directory is what makes the unlink fail, so this needs the unprivileged gate.
    @Test(.requiresUnprivilegedProcess)
    func aSetAsideFileTheControlCannotDeleteStaysOnTheLineAndIsNamed() throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
            fixture.cleanUp()
        }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        let before = fixture.viewModel.setAsideFilesSummary
        #expect(before.fileCount == 1)
        // Read and execute stay, so the listing and the size still work; only the unlink is refused.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.root.path
        )

        fixture.viewModel.deleteSetAsideFiles()

        #expect(fixture.viewModel.setAsideFilesSummary == before)
        let message = try #require(fixture.viewModel.localDataDeletionStatusMessage)
        // The sentence is composed from the error's fields — nothing deleted, one failed — and never
        // carries the wipe's "local data files" (PR #117 review, F4).
        #expect(message.hasPrefix("Could not delete the file Sonny could not read: output-locations.json.unreadable-"))
        #expect(!message.contains("local data file"))
        #expect(fixture.viewModel.errorMessage == message)
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 1)
        #expect(try #require(fixture.viewModel.memoryDeletionStatusMessage).contains("still on your Mac"))
    }

    /// The copy, singular and plural, and the size in Finder's unit. Every sentence is on
    /// `MemoryDeletionCopy` because a view body is where a swapped branch leaves the suite green.
    @Test
    func theSetAsideCopyAgreesWithItselfOnOneFileAndOnSeveral() {
        #expect(MemoryDeletionCopy.setAsideFilesTitle(fileCount: 1) == "1 file Sonny could not read")
        #expect(MemoryDeletionCopy.setAsideFilesTitle(fileCount: 3) == "3 files Sonny could not read")
        #expect(
            MemoryDeletionCopy.setAsideFilesConfirmationTitle(fileCount: 1)
                == "Delete the file Sonny could not read?"
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesConfirmationTitle(fileCount: 3)
                == "Delete the 3 files Sonny could not read?"
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesConfirmation(fileCount: 1)
                == "This deletes the file Sonny could not read. Everything else stays."
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesConfirmation(fileCount: 3)
                == "This deletes the 3 files Sonny could not read. Everything else stays."
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesDeleteAccessibilityLabel(fileCount: 1)
                == "Delete the file Sonny could not read"
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesDeleteAccessibilityLabel(fileCount: 3)
                == "Delete the 3 files Sonny could not read"
        )
        #expect(MemoryDeletionCopy.setAsideFilesOutcome(deletedFileCount: 1) == "Deleted 1 file Sonny could not read.")
        #expect(MemoryDeletionCopy.setAsideFilesOutcome(deletedFileCount: 2) == "Deleted 2 files Sonny could not read.")
        #expect(
            MemoryDeletionCopy.setAsideFilesOutcome(deletedFileCount: 0)
                == "The files Sonny could not read were already gone."
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesFailure(describing: "x")
                == "Could not delete the files Sonny could not read: x"
        )
        // F4: composed from the error's fields — what failed, how many went first — and never the
        // wipe's "local data files".
        let reason = ["You don't have permission."]
        #expect(
            MemoryDeletionCopy.setAsideFilesFailure(LocalDataDeletionError(
                result: LocalDataDeletionResult(deletedFileCount: 0, missingFileCount: 0, failedFilePaths: ["/x/a.json.unreadable-1"]),
                underlyingDescriptions: reason
            )) == "Could not delete the file Sonny could not read: a.json.unreadable-1. (You don't have permission.)"
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesFailure(LocalDataDeletionError(
                result: LocalDataDeletionResult(deletedFileCount: 1, missingFileCount: 0, failedFilePaths: ["/x/b.json.unreadable-2"]),
                underlyingDescriptions: reason
            )) == "Could not delete 1 of the 2 files Sonny could not read: b.json.unreadable-2. (You don't have permission.)"
        )
        #expect(
            MemoryDeletionCopy.setAsideFilesFailure(LocalDataDeletionError(
                result: LocalDataDeletionResult(deletedFileCount: 0, missingFileCount: 0, failedFilePaths: ["/x/a.json.unreadable-1", "/x/b.json.unreadable-2"]),
                underlyingDescriptions: []
            )) == "Could not delete the 2 files Sonny could not read: a.json.unreadable-1, b.json.unreadable-2."
        )
        #expect(MemoryDeletionCopy.setAsideFilesRunGuard == "Stop the current run before deleting the files Sonny could not read.")
        // F1: the per-row report follows the record it is derived from.
        let kept = [URL(fileURLWithPath: "/x/a"), URL(fileURLWithPath: "/x/b")]
        #expect(
            MemoryDeletionCopy.perRowDeleteReport(LastPerRowDelete(category: .taskHistory, deletedFileCount: 2, keptFileURLs: kept, failure: nil))
                == "Task history starts over. The 2 files Sonny could not read are still on your Mac."
        )
        #expect(
            MemoryDeletionCopy.perRowDeleteReport(LastPerRowDelete(category: .taskHistory, deletedFileCount: 2, keptFileURLs: [kept[0]], failure: nil))
                == "Task history starts over. The file Sonny could not read is still on your Mac."
        )
        #expect(
            MemoryDeletionCopy.perRowDeleteReport(LastPerRowDelete(category: .taskHistory, deletedFileCount: 3, keptFileURLs: [], failure: nil))
                == "Deleted task history — 3 files."
        )
        #expect(
            MemoryDeletionCopy.perRowDeleteReport(LastPerRowDelete(category: .taskHistory, deletedFileCount: 0, keptFileURLs: kept, failure: "boom"))
                == "Could not delete task history: boom"
        )
        // Finder's unit — decimal, not binary — pinned against a formatter built independently,
        // which holds in any locale where a literal "1.5 MB" would not; and the two styles are
        // checked to differ at this size, so the first assertion cannot pass vacuously.
        #expect(
            MemoryDeletionCopy.setAsideFilesDetail(byteCount: 1_500_000)
                == ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file)
        )
        #expect(
            ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file)
                != ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .memory)
        )
    }

    /// The Data page's wiring no assertion can reach, in the shape `MacAgentSource` exists for: the
    /// row is gated on the summary's own `isEmpty` rather than a count spelled out in the view, its
    /// words are `MemoryDeletionCopy`'s, its control's action is the narrower delete and not the
    /// wipe's — counted on both sides, so a swap is a red test — and the page re-lists when it
    /// appears.
    @Test
    func theDataPagesSetAsideRowIsPinnedWhereNoAssertionCanReach() throws {
        let view = try MacAgentSource.read("CommandCenterView.swift")
        let page = try MacAgentSource.braceBlock(of: view, openedBy: "private struct SettingsDataPage: View {")

        let row = try MacAgentSource.braceBlock(of: page, openedBy: "if !viewModel.setAsideFilesSummary.isEmpty {")
        for words in [
            "MemoryDeletionCopy.setAsideFilesTitle(",
            "MemoryDeletionCopy.setAsideFilesDetail(",
            "MemoryDeletionCopy.setAsideFilesConfirmationTitle(",
            "MemoryDeletionCopy.setAsideFilesConfirmation(",
            "MemoryDeletionCopy.setAsideFilesDeleteAccessibilityLabel("
        ] {
            #expect(row.contains(words), "\(words)")
        }
        #expect(MacAgentSource.count(of: "viewModel.deleteSetAsideFiles()", inText: row) == 1)
        #expect(MacAgentSource.count(of: "viewModel.deleteLocalData()", inText: row) == 0)
        #expect(MacAgentSource.count(of: "viewModel.deleteSetAsideFiles()", inText: page) == 1)
        // Both controls disable under the wipe's condition — the wipe's as it always was, the row's by
        // founder decision (PR #117 review, F3) — so the view-model guard is the backstop.
        #expect(MacAgentSource.count(of: ".disabled(viewModel.isRunning)", inText: page) == 2)

        let onAppear = try MacAgentSource.braceBlock(of: page, openedBy: ".onAppear {")
        #expect(onAppear.contains("viewModel.refreshSetAsideFiles()"))
    }

    /// **Both surfaces that say what the wipe takes read one derived sentence** (SONNY-233).
    ///
    /// They held hand-written lists and both were false by omission — Settings' detail line named
    /// ten of the thirteen stores the wipe deleted then and the confirmation dialog named nine, so the
    /// two surfaces describing one irreversible press disagreed with each other as well as with the
    /// wipe. `LocalDataDeletionCopy.everythingItTakes` is derived from `LocalStore.allCases` through
    /// an exhaustive switch, and `LocalStorageSecurityTests.theWipesOwnSentenceNamesEveryStoreItDeletes`
    /// pins that it is complete. What this scan holds is the other half, which no assertion can
    /// reach: that these two views actually read it, and that neither has quietly grown a literal of
    /// its own again.
    @Test
    func bothSurfacesDescribingTheWipeReadOneDerivedSentence() throws {
        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        let contentView = try MacAgentSource.read("ContentView.swift")
        let page = try MacAgentSource.braceBlock(of: commandCenter, openedBy: "private struct SettingsDataPage: View {")

        #expect(MacAgentSource.count(of: "LocalDataDeletionCopy.everythingItTakes", inText: page) == 1)
        #expect(MacAgentSource.count(of: "LocalDataDeletionCopy.everythingItTakes", inText: contentView) == 1)

        // No hand-written store name survives on either surface. Counted on both sides rather than
        // checked for absence in one: a literal that came back would raise a count here, and a
        // comment cannot talk one back down — `MacAgentSource`'s own doc records why a scan leans on
        // counts rather than on a token being missing.
        for name in LocalStore.allCases.map(\.deletionCopyName) {
            // The list form, "<name>," — what a hand-written enumeration looks like on either
            // surface, and what both of these literals looked like before this ticket.
            #expect(MacAgentSource.count(of: "\(name),", inText: page) == 0, "\(name) is written out again")
            #expect(MacAgentSource.count(of: "\(name),", inText: contentView) == 0, "\(name) is written out again")
        }

        // What the dialog says that the page does not, and which is nobody else's to derive.
        #expect(contentView.contains("Generated files and API keys are not deleted."))
    }

    /// **F3 — the whole wipe must not leave a row saying "Can't be read" about a file it just deleted.**
    ///
    /// `clearInMemoryLocalDataState`'s four refreshes reach ten of the eleven load-failure sources.
    /// The one they never reach is `.taskPlanDetails`, recorded only by `storedPlanDetail(for:)` —
    /// so a user who had pressed Follow up on a task with a broken plan-detail file, and then wiped
    /// everything, was told "Deleted 13 local data files." beside a Task history row that still read
    /// as damaged and a banner still telling them to go and clear it.
    @Test
    func theWholeWipeClearsARowMarkedUnreadableByAFileItJustDeleted() async throws {
        let fixture = try makeMemoryFixture(wipesRealStoreFiles: true)
        defer { fixture.cleanUp() }

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        _ = fixture.viewModel.followUpOnTask(try #require(fixture.viewModel.taskHistoryRecords.first))
        fixture.memoryPageAppears()
        #expect(fixture.viewModel.unreadableStores.contains(.taskPlanDetails))

        fixture.viewModel.deleteLocalData()

        #expect(fixture.viewModel.unreadableStores.isEmpty)
        #expect(fixture.viewModel.localStorageNotice == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
    }

    /// **F4 — a row with readable entries keeps its count, and its confirmation still names them.**
    ///
    /// Task history is the one row over several stores. With `task-plan-details.json` broken and
    /// twelve readable tasks behind it, the row read "Can't be read" while View listed all twelve —
    /// two surfaces disagreeing on one screen — and the confirmation dropped from naming everything
    /// the press destroys to the vaguer cannot-see-inside sentence, at the press that does the most.
    @Test
    func aPartlyUnreadableRowKeepsItsCountAndItsConfirmationStillNamesWhatGoes() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        for expression in ["2 + 2", "3 + 3"] {
            fixture.viewModel.command = "add \(expression)"
            fixture.viewModel.start(prebuiltPlan: planCalculating(expression))
            try await fixture.waitUntilIdle()
        }
        #expect(fixture.viewModel.memoryEntryCount(for: .taskHistory) == 2)

        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        _ = fixture.viewModel.followUpOnTask(try #require(fixture.viewModel.taskHistoryRecords.first))
        fixture.memoryPageAppears()

        let row = MemoryRowPresentation.row(for: .taskHistory, viewModel: fixture.viewModel)
        #expect(row.readability == .partlyUnreadable)
        #expect(row.count == 2, "the tasks are readable and the row must still say so")
        #expect(row.detailText == "2 tasks · part can't be read")
        #expect(row.canDelete)

        // The confirmation keeps the sentence that names what goes, and adds the one that names
        // what stays. Neither replaces the other.
        let confirmation = MemoryDeletionCopy.confirmation(for: .taskHistory, readability: .partlyUnreadable)
        #expect(confirmation.hasPrefix(MemoryDeletionCopy.message(for: .taskHistory)))
        #expect(confirmation.contains("Part of this can't be read"))
        #expect(confirmation.contains("keeps that file instead of deleting it"))
    }

    /// **F5 — a file nothing has tried to load is still protected.**
    ///
    /// `unreadableStores(in:)` used to read `localStorageLoadFailures`, which holds what something
    /// happened to load and fail on. `.taskPlanDetails` is recorded only when the user opens a task's
    /// detail or presses Follow up; in the ordinary case they have not, so a broken plan-detail file
    /// was classified readable and unlinked. Of the four files under this row, exactly one was
    /// reliably covered by "never destroy what you cannot prove is garbage".
    @Test
    func aDeleteSetsAsideAnUnreadableFileNothingHasEverTriedToLoad() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        let original = try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)

        // Deliberately no `followUpOnTask` here — nothing in this run has loaded that store, so
        // nothing has recorded a failure for it, and the banner is silent. That is the ordinary
        // case, and it is what used to leave the file unprotected.
        #expect(fixture.viewModel.localStorageNotice == nil)
        // The probe knows anyway, which is the fix: the row's words and the delete's action now come
        // from the same answer rather than from what something happened to have recorded.
        fixture.memoryPageAppears()
        #expect(fixture.viewModel.unreadableStores == [.taskPlanDetails])
        #expect(MemoryRowReadability.of(.taskHistory, viewModel: fixture.viewModel) == .partlyUnreadable)

        fixture.viewModel.deleteMemory(in: .taskHistory)

        let setAside = LocalDataQuarantine().quarantinedSiblings(of: fixture.taskPlanDetailStore.fileURL)
        #expect(setAside.count == 1, "an unreadable file nobody had opened was unlinked")
        #expect(try Data(contentsOf: try #require(setAside.first)) == original)
        // And the readable file beside it really was deleted, so this is the split working rather
        // than a delete that kept everything.
        #expect(!FileManager.default.fileExists(atPath: fixture.taskHistoryStore.fileURL.path))
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.taskHistoryStore.fileURL).isEmpty)
    }

    // MARK: - PR #110 fix-round review: one source of truth, and the two stores it rescued

    /// **The escalated finding: the founder's dead end still existed, for two stores of thirteen.**
    ///
    /// `LocalStorageLoadFailureSource` has eleven cases; the vision journal and Shortcut run history
    /// have none. While the row's damaged state was derived from that dictionary, those two could
    /// never put the Task history row into a damaged state, `canDelete` collapsed to `count > 0`,
    /// and an empty task history beside an unreadable `shortcuts-run-history.json` was exactly the
    /// screenshot this ticket was filed from — inside the branch fixing it.
    @Test
    func anUnreadableShortcutHistoryMakesAnEmptyTaskHistoryRowClearable() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let original = try fixture.writeUnreadableFile(at: fixture.shortcutRunHistoryStore.fileURL)

        fixture.memoryPageAppears()

        // Nothing has recorded a load failure and nothing can: that store has no source at all.
        #expect(fixture.viewModel.localStorageNotice == nil)
        #expect(fixture.viewModel.memoryEntryCount(for: .taskHistory) == 0)

        let row = MemoryRowPresentation.row(for: .taskHistory, viewModel: fixture.viewModel)
        #expect(row.readability == .unreadable)
        #expect(row.detailText == "Can't be read")
        #expect(row.canDelete, "the founder's dead end, surviving for this store")

        fixture.viewModel.deleteMemory(in: .taskHistory)

        let setAside = LocalDataQuarantine().quarantinedSiblings(of: fixture.shortcutRunHistoryStore.fileURL)
        #expect(setAside.count == 1)
        #expect(try Data(contentsOf: try #require(setAside.first)) == original)
        #expect(MemoryRowPresentation.row(for: .taskHistory, viewModel: fixture.viewModel).readability == .readable)
    }

    /// The vision journal is the other sourceless store, and it reaches the same row.
    @Test
    func anUnreadableVisionJournalAlsoMakesTheTaskHistoryRowClearable() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.visionSessionJournalStore.fileURL)

        fixture.memoryPageAppears()

        #expect(fixture.viewModel.unreadableStores == [.visionSessionJournal])
        #expect(MemoryRowPresentation.row(for: .taskHistory, viewModel: fixture.viewModel).canDelete)
    }

    /// **The words and the action come from one answer, checked in the direction that used to fail.**
    ///
    /// The confirmation was derived from the recorded-failure set and the delete from a probe, so a
    /// row could promise to delete a file the press then kept. `.taskPlanDetails` is the case that
    /// demonstrated it — nothing records it until the user opens a task's detail.
    @Test
    func theConfirmationAndTheDeleteAgreeAboutAFileNothingHasLoaded() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)

        fixture.memoryPageAppears()

        // The words the user is about to read.
        let readability = MemoryRowReadability.of(.taskHistory, viewModel: fixture.viewModel)
        #expect(readability == .partlyUnreadable)
        let confirmation = MemoryDeletionCopy.confirmation(for: .taskHistory, readability: readability)
        #expect(confirmation.contains("keeps that file instead of deleting it"))

        fixture.viewModel.deleteMemory(in: .taskHistory)

        // And the press did what they said. Before this round the confirmation would have promised
        // deletion while the press kept the file.
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fixture.taskPlanDetailStore.fileURL).count == 1)
        #expect(try #require(fixture.viewModel.memoryDeletionStatusMessage).contains("still on your Mac"))
    }

    /// The fixture's stand-in for the Memory page appearing has to stay the calls the page makes.
    ///
    /// A source scan rather than a comment, because the page's `onAppear` has gained a call twice and
    /// the fixture had to follow it both times — and a fixture that drifts behind it makes every
    /// readability assertion in this suite a test of something the app never does.
    @Test
    func theMemoryPageAppearanceRefreshesEverythingThisFixtureDoes() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        for call in ["viewModel.refreshMemorySettings()", "viewModel.refreshMemoryEntries()", "viewModel.refreshStoreReadability()"] {
            #expect(
                MacAgentSource.count(of: call, inText: source) >= 1,
                "MemoryView's onAppear no longer calls \(call) — update `memoryPageAppears()` with it"
            )
        }
    }

    // MARK: - PR #110 fix-round review: the guards nothing could see

    /// **A run paused at its approval must not reload the Memory rows.**
    ///
    /// `if status.endsTheRun` was unpinned: deleting it passed the whole suite. It is load-bearing
    /// well beyond the preview-only exit — `performStart` records `.approvalNeeded` the moment it
    /// raises the prompt, so without the guard eight encrypted reads run on the main actor, able to
    /// raise a storage banner, while an approval panel is on screen waiting for the user.
    ///
    /// Observed through a store written behind the view model's back: if a refresh happened at the
    /// pause, the snippet would be published there.
    @Test
    func aRunPausedAtItsApprovalDoesNotReloadTheMemoryRows() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.memoryPageAppears()
        #expect(fixture.viewModel.savedSnippets.isEmpty)

        // **On disk before the run starts, and that ordering is the whole test** — the first version
        // wrote it after the pause had already been reached, so the mutant's refresh had happened
        // before there was anything for it to pick up and the test passed against a broken guard.
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        #expect(fixture.viewModel.savedSnippets.isEmpty, "nothing has refreshed yet")

        fixture.viewModel.command = "overwrite the notes"
        fixture.viewModel.start(prebuiltPlan: try fixture.planNeedingApproval())
        let deadline = Date().addingTimeInterval(30)
        while !fixture.viewModel.isAwaitingApproval {
            #expect(Date() < deadline, "the run never reached its approval")
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(fixture.viewModel.savedSnippets.isEmpty, "the pause reloaded the Memory rows")

        // The control: the same write is picked up the moment the run actually ends, so the silence
        // above is the guard rather than a refresh that never works.
        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitUntilIdle()
        #expect(fixture.viewModel.savedSnippets.map(\.trigger) == [";sig"])
    }

    /// **A store that breaks while the page is open says so without the user navigating away.**
    ///
    /// This is SONNY-239 and SONNY-246 meeting each other: the row's damaged state comes from a probe,
    /// and a probe that only ran on `onAppear` would leave the page reading a count of zero with a greyed
    /// Delete for the whole of a session — which is the founder's screenshot, arrived at from the
    /// staleness side.
    @Test
    func aStoreThatBreaksDuringARunMarksItsRowWithoutRevisitingThePage() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.memoryPageAppears()
        #expect(MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel).readability == .readable)

        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()

        // No second `memoryPageAppears()` here, deliberately — that is the navigation the user
        // should not have to perform.
        let row = MemoryRowPresentation.row(for: .outputLocations, viewModel: fixture.viewModel)
        #expect(row.readability == .unreadable)
        #expect(row.canDelete)
    }

    /// **The banner never instructs someone to press a control that is not there.**
    ///
    /// Untested and reachable: the clipboard switch's own settings file is the one source with no
    /// `memoryCategory`, so when it is the only failure the way-out sentence must not appear.
    @Test
    func aBannerAboutAStoreWithNoMemoryRowDoesNotTellTheUserToOpenMemory() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.clipboardSettingsStore.fileURL)

        fixture.viewModel.refreshClipboardHistoryNotice()

        let notice = try #require(fixture.viewModel.localStorageNotice)
        #expect(notice.contains("clipboard history settings"))
        #expect(!notice.contains("Open Memory in Command Center"), "there is no row to press: \(notice)")

        // The control, so this is the gate rather than a banner that never carries the sentence: a
        // store that *does* have a row still gets it.
        try fixture.writeUnreadableFile(at: fixture.snippetStore.fileURL)
        fixture.memoryPageAppears()
        #expect(try #require(fixture.viewModel.localStorageNotice).contains("Open Memory in Command Center"))
    }

    /// The same source failing with a *different* message is news and must republish — the other
    /// direction of F1's guard, which compares the whole detail string rather than the source alone.
    @Test
    func aSourceFailingForADifferentReasonRepublishesTheNotice() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.snippetStore.fileURL)
        fixture.memoryPageAppears()
        let decodeFailure = try #require(fixture.viewModel.localStorageNotice)

        var emissions = 0
        let subscription = fixture.viewModel.$localStorageNotice
            .dropFirst()
            .sink { _ in emissions += 1 }
        defer { subscription.cancel() }

        // A directory where the file was: still unreadable, and a different sentence about why.
        try FileManager.default.removeItem(at: fixture.snippetStore.fileURL)
        try FileManager.default.createDirectory(at: fixture.snippetStore.fileURL, withIntermediateDirectories: true)
        fixture.viewModel.refreshMemoryEntries()

        #expect(emissions == 1, "a different failure on the same store said nothing")
        #expect(fixture.viewModel.localStorageNotice != decodeFailure)
        #expect(try #require(fixture.viewModel.localStorageNotice).contains("snippets"))
    }

    /// The plural half of the kept-file wording, which had no test.
    @Test
    func theDeleteResultCountsTheFilesItKept() {
        #expect(
            MemoryDeletionCopy.outcome(for: .taskHistory, deletedFileCount: 2, keptFileCount: 1)
                == "Task history starts over. The file Sonny could not read is still on your Mac."
        )
        #expect(
            MemoryDeletionCopy.outcome(for: .taskHistory, deletedFileCount: 1, keptFileCount: 2)
                == "Task history starts over. The 2 files Sonny could not read are still on your Mac."
        )
        // Nothing kept keeps the sentence this page has always used.
        #expect(
            MemoryDeletionCopy.outcome(for: .snippets, deletedFileCount: 1, keptFileCount: 0)
                == "Deleted snippets — 1 file."
        )
    }

    // MARK: - PR #110 fix-round review: the pages that contradicted their own row

    /// **The three `MemoryRowDestination.page` rows kept the empty-state copy the sheet had replaced.**
    ///
    /// With `routines.json` unreadable the Memory row correctly reads "Can't be read", and pressing
    /// View opened a page saying "No routines yet · Ask Sonny to save a repeatable sequence". These
    /// are two of the three stores `LocalDataQuarantine` names as things a person made by hand, so
    /// being told they have none is worst here.
    @Test
    func aPageDestinationRowsEmptyStateSaysTheFileCannotBeReadAndNamesTheControl() {
        for category in MemoryCategory.allCases {
            guard case .page = MemoryRowDestination.of(category) else { continue }
            let title = MemoryDeletionCopy.emptyStateTitle(for: category, readability: .unreadable)
            let message = MemoryDeletionCopy.emptyStateMessage(for: category, readability: .unreadable)
            #expect(title == "Sonny can't read your \(category.title.lowercased())")
            // A page away from the Memory row, so the sentence has to name where the control is —
            // unlike the sheet, which opens over it.
            #expect(message.hasPrefix("Open Memory in Command Center and press Delete"), "\(category.title): \(message)")
            #expect(message.contains("The file stays on your Mac."))
        }

        // The sheet rows keep the shorter sentence, since the row is directly behind them.
        #expect(
            MemoryDeletionCopy.emptyStateMessage(for: .snippets, readability: .unreadable)
                .hasPrefix("Press Delete on the snippets row")
        )
    }

    /// And the readable half is unchanged, so the pages say exactly what they said before.
    @Test
    func aPageDestinationRowsReadableEmptyStateIsTheSentenceThatPageAlreadyUsed() {
        #expect(
            MemoryDeletionCopy.emptyStateMessage(for: .routines, readability: .readable)
                == "Ask Sonny to save a repeatable sequence, then it will appear here."
        )
        #expect(
            MemoryDeletionCopy.emptyStateMessage(for: .workspaces, readability: .readable)
                == "Ask Sonny to group apps and safe URLs for one-click opening."
        )
        #expect(
            MemoryDeletionCopy.emptyStateMessage(for: .taskHistory, readability: .readable)
                == TaskSearchPresentation.neverRanAnything.detail
        )
        #expect(MemoryDeletionCopy.emptyStateTitle(for: .routines, readability: .readable) == "No routines yet")
        #expect(MemoryDeletionCopy.emptyStateTitle(for: .workspaces, readability: .readable) == "No workspaces yet")
    }

    // MARK: - The founder's Reveal in Finder control

    /// **Telling the user where the kept file is, with a control rather than a path** (founder
    /// decision, 2026-08-23). Every file the delete kept, not the first, because the message beside
    /// it already branches on how many there were.
    @Test
    func revealingSetAsideFilesShowsEveryOneTheDeleteKept() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        // Two files under one row, both unreadable, so one press keeps two.
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        try fixture.writeUnreadableFile(at: fixture.shortcutRunHistoryStore.fileURL)
        fixture.memoryPageAppears()

        fixture.viewModel.deleteMemory(in: .taskHistory)

        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 2)
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage)
                .contains("The 2 files Sonny could not read are still on your Mac.")
        )

        fixture.viewModel.revealSetAsideFilesInFinder()

        let revealed = try #require(fixture.finderReveals.revealed.last)
        #expect(revealed.count == 2, "the control showed \(revealed.count) of 2 kept files")
        #expect(Set(revealed) == Set(fixture.viewModel.setAsideFilesFromLastDelete))
        #expect(revealed.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// A delete that kept nothing leaves no control and no stale list behind it.
    @Test
    func adeleteThatKeptNothingOffersNothingToReveal() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        fixture.memoryPageAppears()

        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
        fixture.viewModel.revealSetAsideFilesInFinder()
        #expect(fixture.finderReveals.revealed.isEmpty, "a delete that kept nothing opened Finder")
    }

    /// The list does not outlive the delete that filled it — a second, clean delete clears it, so the
    /// control cannot sit beside a message that says nothing was kept.
    @Test
    func aLaterCleanDeleteClearsWhatTheEarlierOneKept() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.writeUnreadableFile(at: fixture.outputLocationStore.fileURL)
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .outputLocations)
        #expect(fixture.viewModel.setAsideFilesFromLastDelete.count == 1)

        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "signature"))
        fixture.memoryPageAppears()
        fixture.viewModel.deleteMemory(in: .snippets)

        #expect(fixture.viewModel.setAsideFilesFromLastDelete.isEmpty)
    }

    /// The seam also makes the reveal that was already there testable, which is why it was worth
    /// adding rather than reaching for a source scan.
    @Test
    func aRunSuggestionsRevealGoesThroughTheSameSeam() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let file = fixture.root.appendingPathComponent("artifact.md")
        try Data("x".utf8).write(to: file, options: .atomic)

        fixture.viewModel.runSuggestion(
            RunSuggestion(title: "Reveal in Finder", kind: .revealInFinder, value: file.path)
        )

        #expect(fixture.finderReveals.revealed == [[file]])
    }

    /// What a screen reader is told, which agrees with the message's own singular and plural.
    @Test
    func theRevealControlsAccessibilityLabelSaysWhatWillBeShown() {
        #expect(
            MemoryDeletionCopy.revealAccessibilityLabel(fileCount: 1)
                == "Reveal the file Sonny could not read in Finder"
        )
        #expect(
            MemoryDeletionCopy.revealAccessibilityLabel(fileCount: 3)
                == "Reveal the 3 files Sonny could not read in Finder"
        )
    }

    // MARK: - SONNY-246: the lists reload while the page is open

    /// **The founder's A4, reproduced.** With Memory open, a task wrote a note into a folder and the
    /// row did not change until he navigated away and back.
    ///
    /// The test stands in for "the page is already on screen" by loading the lists once — which is
    /// what `.onAppear` does — and then never refreshing them again. Everything asserted afterwards
    /// is therefore something the run itself published.
    @Test
    func aRunPublishesWhatItRecordedWithoutTheMemoryPageBeingRevisited() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")

        // The page appears. Nothing recorded yet, which is the control: without it, "the row shows
        // Reports" is equally true of a fixture that had it all along.
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.outputLocations.isEmpty)
        #expect(fixture.viewModel.recentArtifacts.isEmpty)

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        // No second `refreshMemoryEntries()` here, deliberately — that is the navigation the founder
        // had to perform, and the whole point is that it is no longer needed.
        #expect(fixture.viewModel.outputLocations.map(\.name) == ["Reports"])
        #expect(fixture.viewModel.memoryEntryCount(for: .outputLocations) == 1)
        #expect(fixture.viewModel.recentArtifacts.count == 1)
        #expect(fixture.viewModel.newestMemoryEntryDate(for: .outputLocations) != nil)
    }

    /// The same for a row whose entries the user asked for by name, on the same one dispatch.
    @Test
    func aRunThatSavesASnippetPublishesItToTheMemoryRowImmediately() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.savedSnippets.isEmpty)

        fixture.viewModel.command = "save a snippet ;sig"
        fixture.viewModel.start(prebuiltPlan: planSavingSnippet(trigger: ";sig", expansion: "signature"))
        try await fixture.waitUntilIdle()

        #expect(fixture.viewModel.savedSnippets.map(\.trigger) == [";sig"])
        #expect(fixture.viewModel.memoryEntryCount(for: .snippets) == 1)
    }

    /// **The two exceptions the ticket asked to be checked rather than assumed.**
    ///
    /// SONNY-246's description lists Task history and Unfinished tasks among the rows that "all load
    /// through the same call". They do not, and both were already fresh before this fix: task
    /// history is published by `refreshTaskHistory()`, called by `recordTaskHistoryIfTerminal` on
    /// every terminal outcome, and unfinished tasks by `refreshResumableTasks()`, called after every
    /// write the view model makes to that store. This test is the record of that, so a future change
    /// that made either of them depend on the Memory page's `.onAppear` would be caught here rather
    /// than found in another manual pass.
    @Test
    func taskHistoryWasAlreadyFreshWithoutTheMemoryPagesOwnRefresh() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()

        #expect(fixture.viewModel.memoryEntryCount(for: .taskHistory) == 1)
        #expect(fixture.viewModel.taskHistoryRecords.first?.command == "add two and two")
    }

    /// **A copy republishes the clipboard row, and a tick that recorded nothing does not.**
    ///
    /// The poll runs once a second. Refreshing on every tick would decrypt five files sixty times a
    /// minute on the main actor for a pasteboard nobody touched, so the refresh hangs off `poll()`
    /// returning a recorded item — which is exactly the case the row is stale for.
    @Test
    func aCopyRepublishesTheClipboardRowAndAnIdleTickDoesNot() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.clipboardSettingsStore.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        fixture.viewModel.refreshClipboardHistoryNotice()
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.clipboardHistoryItems.isEmpty)

        fixture.pasteboard.text = "copied while the page was open"
        fixture.pasteboard.changeCount += 1
        #expect(fixture.viewModel.pollClipboardHistory())

        #expect(fixture.viewModel.clipboardHistoryItems.map(\.text) == ["copied while the page was open"])
        #expect(fixture.viewModel.memoryEntryCount(for: .clipboardHistory) == 1)

        // A tick with an unchanged pasteboard records nothing, so it reloads nothing — the negative
        // half of the rule, and the reason the refresh hangs off `poll()`'s answer rather than off
        // the tick.
        #expect(!fixture.viewModel.pollClipboardHistory())
    }

    /// A routine that fires with nobody watching writes to the same stores a typed command does, and
    /// Command Center can be open the whole time. The scheduled path never reaches
    /// `recordTaskHistoryIfTerminal`, so it needs — and has — its own refresh.
    @Test
    func aScheduledRunPublishesWhatItRecordedWithoutTheMemoryPageBeingRevisited() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.refreshMemoryEntries()
        #expect(fixture.viewModel.outputLocations.isEmpty)

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(FileManager.default.fileExists(atPath: reports.appendingPathComponent("morning.md").path))
        #expect(fixture.viewModel.outputLocations.map(\.name) == ["Reports"])
        #expect(fixture.viewModel.recentArtifacts.count == 1)
    }

    /// **A tick that recorded nothing reloads nothing**, counted rather than inferred.
    ///
    /// The poll runs once a second. The refresh hangs off `poll()` returning an item precisely so a
    /// pasteboard nobody touched does not decrypt five files sixty times a minute on the main actor,
    /// and the only way to see that from outside is to count what the view model published — a
    /// reload assigns every one of those `@Published` arrays whether or not their contents changed.
    @Test
    func anIdleClipboardTickPublishesNothingAtAll() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.clipboardSettingsStore.save(ClipboardHistorySettings(noticeDismissed: true, isEnabled: true))
        fixture.viewModel.refreshClipboardHistoryNotice()

        var publishedChanges = 0
        let subscription = fixture.viewModel.objectWillChange.sink { _ in publishedChanges += 1 }
        defer { subscription.cancel() }

        #expect(!fixture.viewModel.pollClipboardHistory())
        #expect(publishedChanges == 0, "an idle tick republished \(publishedChanges) time(s)")

        // The control: a tick that *did* record publishes, so zero above is the guard working
        // rather than a subscription that never fires.
        fixture.pasteboard.text = "copied"
        fixture.pasteboard.changeCount += 1
        #expect(fixture.viewModel.pollClipboardHistory())
        #expect(publishedChanges > 0)
    }

    /// **F6 — Routines and Workspaces are Memory rows too, and `refreshMemoryEntries()` does not
    /// load them.**
    ///
    /// They are published by `refreshSavedItems()`, which the first round of SONNY-246 left where it
    /// was: on the success branches only, and nowhere on the scheduled path. So a run that saved a
    /// routine or created a workspace and then failed left the row showing the old count — the exact
    /// symptom this ticket was filed for, on two of the nine rows, unmentioned in its own
    /// classification of which rows were stale.
    ///
    /// The workspace is written behind the view model's back on purpose: what is under test is that
    /// a *failed* run reloads those rows at all, not that this particular plan creates one.
    @Test
    func aFailedRunStillReloadsTheRoutinesAndWorkspacesRows() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.refreshMemoryEntries()
        fixture.viewModel.refreshSavedItems()
        #expect(fixture.viewModel.savedWorkspaces.isEmpty)

        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))

        fixture.viewModel.command = "add apples"
        fixture.viewModel.start(prebuiltPlan: planCalculating("apples"))
        try await fixture.waitUntilIdle()

        // The control: this really was a failure, so the assertion below is about the failure path.
        #expect(fixture.viewModel.errorMessage != nil)
        #expect(fixture.viewModel.savedWorkspaces.map(\.name) == ["Research"])
        #expect(fixture.viewModel.memoryEntryCount(for: .workspaces) == 1)
    }

    /// The scheduled half of F6, which had no refresh for these two rows at all.
    @Test
    func aScheduledRunReloadsTheRoutinesAndWorkspacesRows() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        _ = try fixture.saveScheduledDraftRoutine()
        fixture.viewModel.refreshMemoryEntries()
        fixture.viewModel.refreshSavedItems()
        #expect(fixture.viewModel.savedWorkspaces.isEmpty)

        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))

        fixture.viewModel.checkScheduledRoutines(now: MemoryFixture.tenAM)
        try await fixture.waitUntilIdle()

        #expect(fixture.viewModel.savedWorkspaces.map(\.name) == ["Research"])
    }

    /// **F8 — a Delete that could not happen must leave the row saying so.**
    ///
    /// `clearLoadFailuresForStoresWhoseFileIsGone` asks the file system whether the file really went
    /// before forgetting its failure. Deleting that guard survived the reviewer's battery, and the
    /// first attempt at this test did not kill it either — which is the interesting part and the
    /// reason this uses plan details rather than the obvious store.
    ///
    /// **The guard is only observable for a source nothing re-probes.** With `.outputLocations`, the
    /// `refreshMemorySurfaces()` at the end of `deleteMemory` re-reads the file, fails again, and
    /// records the failure a second time — so a wrongly-cleared banner is restored within the same
    /// call and the mutant hides behind the repair. `.taskPlanDetails` is read by
    /// `storedPlanDetail(for:)` and by nothing else, so nothing puts it back. That is the same
    /// property F3 turns on, seen from the other side: the one source the refreshes cannot reach is
    /// the one the evidence check actually protects.
    ///
    /// Locking the directory is what makes both the unlink and the rename fail, so this needs the
    /// unprivileged gate.
    @Test(.requiresUnprivilegedProcess)
    func aDeleteThatCouldNotHappenLeavesTheRowSayingItCannotBeRead() async throws {
        let fixture = try makeMemoryFixture()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
            fixture.cleanUp()
        }

        fixture.viewModel.command = "add two and two"
        fixture.viewModel.start(prebuiltPlan: planCalculating("2 + 2"))
        try await fixture.waitUntilIdle()
        try fixture.writeUnreadableFile(at: fixture.taskPlanDetailStore.fileURL)
        _ = fixture.viewModel.followUpOnTask(try #require(fixture.viewModel.taskHistoryRecords.first))
        fixture.memoryPageAppears()
        #expect(fixture.viewModel.unreadableStores.contains(.taskPlanDetails))

        // Read and execute stay, so every load below still works; only the rename and the unlink
        // are refused.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.root.path
        )
        fixture.viewModel.deleteMemory(in: .taskHistory)

        // The premise: the file really is still there, which is what makes the row's claim true.
        #expect(FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
        #expect(fixture.viewModel.unreadableStores.contains(.taskPlanDetails))
        #expect(try #require(fixture.viewModel.localStorageNotice).contains("what past tasks planned"))
        #expect(
            try #require(fixture.viewModel.memoryDeletionStatusMessage)
                .hasPrefix("Could not delete task history")
        )
    }

    /// **The ticket's second question, answered: the sheet cannot disagree with the row.**
    ///
    /// It asked whether an open entries sheet has the same staleness as the row behind it, since a
    /// sheet that read on open would be fresh while the row was not — two numbers disagreeing on one
    /// screen. It does not read on open: `MemoryEntriesSheet.entries` computes from
    /// `MemoryEntryPresentation.entries(for:viewModel:)`, which reads the same published arrays the
    /// row's count reads. So the two share one source, go stale together, and refresh together —
    /// which is why this asserts they agree both before and after a run rather than asserting a
    /// staleness that never existed.
    @Test
    func theEntriesSheetAndTheRowCountReadOneSourceSoTheyCannotDisagree() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let reports = try fixture.makeOutputFolder("Reports")
        fixture.viewModel.refreshMemoryEntries()
        #expect(
            MemoryEntryPresentation.entries(for: .outputLocations, viewModel: fixture.viewModel).count
                == fixture.viewModel.memoryEntryCount(for: .outputLocations)
        )

        fixture.viewModel.command = "draft the morning note"
        fixture.viewModel.start(prebuiltPlan: planDrafting(into: reports))
        try await fixture.waitUntilIdle()

        let entries = MemoryEntryPresentation.entries(for: .outputLocations, viewModel: fixture.viewModel)
        #expect(entries.count == fixture.viewModel.memoryEntryCount(for: .outputLocations))
        #expect(entries.count == 1)
        #expect(try #require(entries.first).title == "Reports")
    }

    // MARK: - What the rows say

    @Test
    func aRowsCountAndNewestLineComeFromTheRealStores() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try fixture.snippetStore.save(
            StoredSnippet(trigger: ";sig", expansion: "signature", updatedAt: now.addingTimeInterval(-3600))
        )
        try fixture.snippetStore.save(
            StoredSnippet(trigger: ";addr", expansion: "address", updatedAt: now)
        )
        fixture.viewModel.refreshMemoryEntries()

        let presentation = MemoryRowPresentation(
            category: .snippets,
            count: fixture.viewModel.memoryEntryCount(for: .snippets),
            isRecording: fixture.viewModel.isMemoryCategoryEnabled(.snippets),
            canChangeRecording: fixture.viewModel.memorySettings.isRecording,
            readability: MemoryRowReadability.of(.snippets, viewModel: fixture.viewModel),
            newestEntryDate: fixture.viewModel.newestMemoryEntryDate(for: .snippets),
            now: now
        )

        #expect(presentation.title == "Snippets")
        #expect(presentation.count == 2)
        #expect(presentation.isRecording)
        // The newest of the two, not the first written.
        #expect(presentation.detailText == "2 snippets · newest Today, \(expectedTime(for: now))")
    }

    @Test
    func anEmptyRowSaysSoWithoutInventingATimestamp() {
        let presentation = MemoryRowPresentation(
            category: .workspaces,
            count: 0,
            isRecording: false,
            canChangeRecording: true,
            readability: .readable,
            newestEntryDate: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(presentation.detailText == "0 workspaces")
        #expect(!presentation.isRecording)
    }

    /// **The row switch is dead while the master switch is off, and live otherwise** — asserted on
    /// the row's own presentation, which is the answer the control reads.
    ///
    /// **This test used to assert `memorySettings.isRecording` instead** and was therefore green
    /// against a `canChangeRecording` hardwired to `true` (PR #98 review, F3): a plain value-type
    /// property already covered by `MemorySettingsTests`, so it passed for a reason unrelated to its
    /// name. `MemoryRowPresentation.row(for:viewModel:)` is where the expression under test lives,
    /// and it needs no SwiftUI harness to call.
    @Test
    func aRowsSwitchCannotBeMovedWhileTheMasterSwitchOrAPolicyHasMemoryOff() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        // Live to begin with, for every row — the control without which "cannot be moved" is
        // equally true of a build where it never could.
        for category in MemoryCategory.allCases {
            let row = MemoryRowPresentation.row(for: category, viewModel: fixture.viewModel)
            #expect(row.canChangeRecording, "\(category.title) started locked")
        }

        fixture.viewModel.setMemoryEnabled(false)
        for category in MemoryCategory.allCases {
            let row = MemoryRowPresentation.row(for: category, viewModel: fixture.viewModel)
            #expect(!row.canChangeRecording, "\(category.title) stayed movable with memory off")
            // And it reads off, so the control never shows "on" beside something recording nothing.
            #expect(!row.isRecording, "\(category.title)")
        }

        fixture.viewModel.setMemoryEnabled(true)
        #expect(MemoryRowPresentation.row(for: .snippets, viewModel: fixture.viewModel).canChangeRecording)

        // A policy is the second, separate cause of the same lock.
        let managed = try makeMemoryFixture(
            policyProvider: StubMemoryPolicyProvider(
                policy: MemoryEnterprisePolicy(isManaged: true, disablesMemory: true)
            )
        )
        defer { managed.cleanUp() }
        for category in MemoryCategory.allCases {
            #expect(!MemoryRowPresentation.row(for: category, viewModel: managed.viewModel).canChangeRecording)
        }
    }

    /// A single per-type switch must not lock the *row* — only the master switch and the policy do.
    /// Without this, `canChangeRecording` could be wired to `isMemoryCategoryEnabled` and every
    /// assertion above would still hold, while every row locked itself the moment it was turned off.
    @Test
    func turningOneTypeOffLeavesItsOwnSwitchStillMovable() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.setMemoryCategoryEnabled(.snippets, to: false)

        let row = MemoryRowPresentation.row(for: .snippets, viewModel: fixture.viewModel)
        #expect(!row.isRecording)
        #expect(row.canChangeRecording, "a type switched off could never be switched back on")
    }

    /// **Where "View" leads, for every row** (PR #98 review, F4). Rewiring Task history to open
    /// Insights left the whole suite green, and "each memory type is viewable" is the first clause of
    /// the ticket's acceptance criteria.
    ///
    /// **The population pin is the half that keeps the table honest, and it was briefly a tautology**
    /// (PR #101 review, F4). Row 13 replaced `destinations.count == 7` with
    /// `destinations.count == MemoryCategory.allCases.count`, which `map` makes true for any n. The
    /// literal it replaced was the thing that made a new row break this test — and so the thing that
    /// forced whoever added the row to state where it leads. What replaces it now is a table of every
    /// row's destination checked against `allCases` in both directions: a ninth row fails this by
    /// name rather than by a number, and the explicit `#expect` list the table subsumes is gone
    /// rather than kept as a second copy of the same eight facts.
    @Test
    func viewLeadsSomewhereSpecificForEveryMemoryType() {
        // Every row's destination, stated once. The keys are checked against the whole population
        // below, which is what makes a tenth row fail here rather than pass with nine covered.
        let expected: [MemoryCategory: MemoryRowDestination] = [
            .routines: .page(.routines),
            .workspaces: .page(.workspaces),
            .taskHistory: .page(.tasks),
            .recentArtifacts: .entriesSheet,
            .outputLocations: .entriesSheet,
            .clipboardHistory: .entriesSheet,
            .snippets: .entriesSheet,
            .approvedApps: .entriesSheet,
            // Row 13's unfinished runs (SONNY-210) open the sheet, and it is the one type where that
            // is a decision rather than an absence: an unfinished run has no task-history row to
            // open, because a row is written when a run terminates.
            .resumableTasks: .entriesSheet
        ]
        #expect(
            Set(expected.keys) == Set(MemoryCategory.allCases),
            "not every memory row has a stated destination: \(Set(MemoryCategory.allCases).subtracting(expected.keys))"
        )
        for category in MemoryCategory.allCases {
            #expect(MemoryRowDestination.of(category) == expected[category], "\(category.title)")
        }

        // Every row leads somewhere, and the three page destinations are distinct — a mapping that
        // sent two rows to one page would satisfy a looser check.
        let destinations = MemoryCategory.allCases.map(MemoryRowDestination.of)
        let pages = destinations.compactMap { destination -> CommandCenterDestination? in
            guard case .page(let page) = destination else { return nil }
            return page
        }
        #expect(Set(pages).count == pages.count)
        #expect(!pages.contains(.memory), "a row must not send the user back to the page they are on")

        // Exactly the types the sheet renders entries for open the sheet, so the two mappings cannot
        // drift apart.
        let sheetTypes = MemoryCategory.allCases.filter { MemoryRowDestination.of($0) == .entriesSheet }
        #expect(
            Set(sheetTypes)
                == [.recentArtifacts, .outputLocations, .clipboardHistory, .snippets, .approvedApps, .resumableTasks]
        )
    }

    /// The three wirings no runtime assertion in this repository can reach, scanned in the shape
    /// `MacAgentSource` exists for — a SwiftUI modifier, a construction site, and a call ordering.
    ///
    /// Each corresponds to a mutant that survived the whole suite at `51e345f`: the row switch never
    /// disabled at all (F3/M2), the presentation built inline so the factory above holds nothing
    /// (F3/M1's escape hatch), and the clipboard delete no longer stopping the poll timer first
    /// (F5/M8). `MacAgentSource.read` strips both comment syntaxes, so none of these can be
    /// satisfied by a comment.
    @Test
    func theMemoryPagesUnrenderableWiringIsPinnedWhereNoAssertionCanReach() throws {
        let view = try MacAgentSource.read("CommandCenterView.swift")

        let row = try MacAgentSource.braceBlock(of: view, openedBy: "private struct MemoryRow: View {")
        #expect(row.contains(".disabled(!presentation.canChangeRecording)"))

        // The page builds its rows through the factory, so the factory's own test is a test of what
        // ships rather than of a function nothing calls.
        let page = try MacAgentSource.braceBlock(of: view, openedBy: "private struct MemoryView: View {")
        #expect(page.contains("MemoryRowPresentation.row(for: category, viewModel: viewModel)"))
        #expect(!page.contains("MemoryRowPresentation("), "the page constructs a presentation directly")
        #expect(page.contains("MemoryRowDestination.of(category)"))

        // F5: the clipboard delete stops the 1s poll before deleting, so the timer cannot write a new
        // entry between the delete and the refresh. Only reachable in a real one-second window, which
        // is exactly why the suite cannot assert it by running it.
        let deleteMemory = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("AgentViewModel.swift"),
            openedBy: "func deleteMemory(in category: MemoryCategory) {"
        )
        let clipboardBranch = try MacAgentSource.braceBlock(
            of: deleteMemory,
            openedBy: "if category == .clipboardHistory {"
        )
        #expect(clipboardBranch.contains("stopClipboardHistoryMonitoring()"))
    }

    /// The two groups the collection renders, and that between them they cover every row exactly
    /// once — a category added later must land in a group rather than vanish from the page.
    @Test
    func theCollectionsTwoGroupsCoverEveryMemoryTypeExactlyOnce() {
        let grouped = MemorySection.all.flatMap(\.categories)

        #expect(Set(grouped) == Set(MemoryCategory.allCases))
        #expect(grouped.count == MemoryCategory.allCases.count, "a type appeared in both groups")
        #expect(MemorySection.all.map(\.title) == ["Saved by you", "Recorded as Sonny works"])
        #expect(MemorySection.all.allSatisfy { !$0.categories.isEmpty })
        // The split is the store classification, not a reading invented for the page.
        for section in MemorySection.all {
            #expect(section.categories.allSatisfy { $0.storeKind == section.kind }, "\(section.title)")
        }
    }

    /// Every destructive confirmation on this page says what it takes, the way the app's other four
    /// do. An empty message is the failure this catches — it renders as a dialog that asks a
    /// question and answers nothing.
    @Test
    func everyDestructiveConfirmationAndEmptyStateHasRealWords() {
        for category in MemoryCategory.allCases {
            #expect(!MemoryDeletionCopy.message(for: category).isEmpty, "\(category.title)")
        }

        // **Both loops are derived from `MemoryRowDestination`, not written out** (PR #101 review,
        // F3). Row 13 added a fifth entries-sheet type and updated one of the two hardcoded lists in
        // this file — the sibling 66 lines above — and not this one, so `.outputLocations` had no
        // copy assertion at all: its `entryMessage` and its `emptyMessage` could each be blanked
        // with the whole suite green, which is precisely the failure this test's own comment says it
        // exists to catch. Deriving both sides from the destination mapping means a ninth row is
        // covered by arriving rather than by being remembered here.
        let sheetTypes = MemoryCategory.allCases.filter { MemoryRowDestination.of($0) == .entriesSheet }
        let pageTypes = MemoryCategory.allCases.filter { MemoryRowDestination.of($0) != .entriesSheet }
        #expect(!sheetTypes.isEmpty)
        #expect(!pageTypes.isEmpty)
        #expect(sheetTypes.count + pageTypes.count == MemoryCategory.allCases.count)

        // The sheet's copy exists for every type it opens for, and deliberately not for the ones
        // deleted from their own pages.
        for category in sheetTypes {
            #expect(!MemoryDeletionCopy.entryMessage(for: category).isEmpty, "\(category.title)")
            #expect(!MemoryDeletionCopy.emptyMessage(for: category).isEmpty, "\(category.title)")
            #expect(MemoryDeletionCopy.emptyTitle(for: category).hasPrefix("No "), "\(category.title)")
        }
        for category in pageTypes {
            #expect(MemoryDeletionCopy.entryMessage(for: category).isEmpty, "\(category.title)")
        }

        // The two that promise something is *kept* are the two where a reader would most reasonably
        // fear otherwise, so the promise is pinned rather than left to the wording surviving an edit.
        #expect(MemoryDeletionCopy.message(for: .recentArtifacts).contains("files themselves are not deleted"))
        #expect(MemoryDeletionCopy.message(for: .taskHistory).contains("Files those tasks created are not deleted"))
    }

    @Test
    func routinesAndWorkspacesCarryNoNewestTimestampBecauseNeitherRecordHasOne() async throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.command = "teach sonny a routine called morning"
        fixture.viewModel.start(prebuiltPlan: planSavingRoutine(named: "Morning"))
        try await fixture.waitUntilIdle()

        #expect(fixture.viewModel.memoryEntryCount(for: .routines) == 1)
        #expect(fixture.viewModel.newestMemoryEntryDate(for: .routines) == nil)
        #expect(fixture.viewModel.newestMemoryEntryDate(for: .workspaces) == nil)
        // Task history does carry one, so the `nil` above is a property of those two rows rather
        // than of the method.
        #expect(fixture.viewModel.newestMemoryEntryDate(for: .taskHistory) != nil)
    }

    @Test
    func theEntriesSheetRendersOnlyTheTypesWithoutPagesOfTheirOwn() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "line one\nline two"))
        try fixture.approvedAppStore.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        let reports = try fixture.makeOutputFolder("Reports")
        try fixture.outputLocationStore.recordOutputs(
            atPaths: [reports.appendingPathComponent("a.md").path]
        )
        fixture.viewModel.refreshMemoryEntries()

        let snippets = MemoryEntryPresentation.entries(for: .snippets, viewModel: fixture.viewModel)
        #expect(snippets.map(\.title) == [";sig"])
        // A multi-line expansion is squeezed onto one line rather than claiming the height of
        // whatever was saved.
        #expect(snippets.first?.detail == "line one line two")

        let apps = MemoryEntryPresentation.entries(for: .approvedApps, viewModel: fixture.viewModel)
        #expect(apps.map(\.title) == ["Safari"])
        #expect(try #require(apps.first).detail.contains("com.apple.Safari"))

        // The row is titled with the folder's own name and detailed with the path, the count and the
        // last use — the three things that answer "why is Sonny offering me this folder".
        let locations = MemoryEntryPresentation.entries(for: .outputLocations, viewModel: fixture.viewModel)
        #expect(locations.map(\.title) == ["Reports"])
        let detail = try #require(locations.first).detail
        #expect(detail.contains(reports.path) || detail.contains((reports.path as NSString).abbreviatingWithTildeInPath))
        #expect(detail.contains("1 time"))
        // Keyed by the folder, which is what `AgentViewModel.forgetOutputLocation` deletes by.
        #expect(locations.first?.id == reports.path)

        for category in [MemoryCategory.routines, .workspaces, .taskHistory] {
            #expect(
                MemoryEntryPresentation.entries(for: category, viewModel: fixture.viewModel).isEmpty,
                "\(category.title) has a page of its own and must not be listed in the sheet"
            )
        }
    }

    // MARK: - The shared Command Center surfaces

    /// **Every Command Center page carries the shared surfaces, checked over the whole population.**
    ///
    /// This is the SONNY-180 defect class: a page that omits them shows nothing for a run started
    /// from it and renders no approval it raises. Read rather than run, because this repository has
    /// no way to drive SwiftUI — and read as a population, because the failure is a *new* page, which
    /// is exactly what a per-page test written today would not cover.
    ///
    /// The Tasks page is the one exception and it is named rather than excused: it renders its
    /// running state as the `InProgressTaskGroup` the wireframe specifies instead of the compact
    /// indicator, under the same guard.
    @Test
    func everyCommandCenterPageRendersTheSharedAttentionAndStorageSurfaces() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let pages: [(destination: CommandCenterDestination, type: String, runningSurface: String)] = [
            (.tasks, "TasksFoundationView", "InProgressTaskGroup("),
            (.insights, "InsightsView", "CommandCenterRunningIndicator("),
            (.routines, "RoutinesView", "CommandCenterRunningIndicator("),
            (.workspaces, "WorkspacesView", "CommandCenterRunningIndicator("),
            (.memory, "MemoryView", "CommandCenterRunningIndicator(")
        ]
        // The population is the enum, so a destination added without a row here fails rather than
        // going unchecked.
        #expect(Set(pages.map(\.destination)) == Set(CommandCenterDestination.allCases))

        for page in pages {
            let body = try MacAgentSource.braceBlock(of: source, openedBy: "private struct \(page.type): View {")
            #expect(body.contains("CommandCenterAttentionPanel(viewModel: viewModel)"), "\(page.type)")
            #expect(body.contains("CommandCenterStorageNotice(viewModel: viewModel"), "\(page.type)")

            // The two self-gating surfaces must not sit inside the running guard. Nesting a
            // self-gating strip inside `if isRunning` was a real shipped bug on the storage notice,
            // and it is invisible to a check that only counts the token.
            let guarded = try MacAgentSource.braceBlock(
                of: body,
                openedBy: "if viewModel.isRunning || viewModel.isAwaitingApproval {"
            )
            #expect(!guarded.contains("CommandCenterAttentionPanel"), "\(page.type) hid its attention panel")
            #expect(!guarded.contains("CommandCenterStorageNotice"), "\(page.type) hid its storage notice")
            #expect(guarded.contains(page.runningSurface), "\(page.type) shows nothing while a run is in flight")
        }
    }
}

// MARK: - Plans

/// One-step plans that terminate hermetically. `calculate_utility` needs nothing from the machine;
/// the three save plans write only into Sonny's own stores, which the fixture points at a temporary
/// directory.
private func planCalculating(_ expression: String) -> AgentPlan {
    AgentPlan(
        summary: "Calculate \(expression).",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "calculate",
                operation: .calculateUtility,
                description: "Calculate \(expression).",
                searchQuery: expression
            )
        ]
    )
}

private func planSavingRoutine(named name: String) -> AgentPlan {
    AgentPlan(
        summary: "Save routine \(name).",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "save-routine",
                operation: .saveRoutine,
                description: "Save routine \(name).",
                routineName: name,
                routineSteps: [
                    AgentStep(
                        id: "calculate",
                        operation: .calculateUtility,
                        description: "Calculate 1 + 1.",
                        searchQuery: "1 + 1"
                    )
                ]
            )
        ]
    )
}

private func planSavingSnippet(trigger: String, expansion: String) -> AgentPlan {
    AgentPlan(
        summary: "Save snippet \(trigger).",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "save-snippet",
                operation: .saveSnippet,
                description: "Save snippet \(trigger).",
                searchQuery: trigger,
                draftContent: expansion
            )
        ]
    )
}

/// A plan that writes one real Markdown file into `folder` (SONNY-209).
///
/// `create_local_draft` is the only capability these deterministic fixtures can run that produces a
/// user-facing file — no network, no Shortcuts, no app. The step names its own `outputPath` so the
/// folder under test is a named subdirectory and an assertion can say which folder was recorded.
///
/// **It auto-runs rather than pausing, and that is the consequence rule rather than a shortcut.**
/// The capability's default tier is 2, but since 2026-08-13 the requirement comes from what an
/// action *does*: `CreateLocalDraftCapabilityAdapter` escalates only when its destination already
/// exists, so a fresh draft carries no escalation, `asksFirst` is false, and
/// `consequenceRuleRequirement` answers `.autoRun` at tier 2. Nothing here reaches past an approval
/// gate — there is none to reach past. The approval path is covered anyway: `performStart` and
/// `performApproval` both execute through the same `executePreparedRun`, which is the one place a
/// foreground run's runner is asked to execute.
private func planDrafting(into folder: URL) -> AgentPlan {
    AgentPlan(
        summary: "Write the morning note.",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "draft",
                operation: .createLocalDraft,
                description: "Write the morning note.",
                outputPath: folder.appendingPathComponent("morning.md").path,
                draftTitle: "Morning",
                draftContent: "Good morning."
            )
        ]
    )
}

private func planCreatingWorkspace(named name: String) -> AgentPlan {
    AgentPlan(
        summary: "Create workspace \(name).",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "create-workspace",
                operation: .createWorkspace,
                description: "Create workspace \(name).",
                workspaceName: name,
                workspaceApps: ["Safari"]
            )
        ]
    )
}

private func expectedTime(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
}

// MARK: - Fixture

private struct StubMemoryPolicyProvider: MemoryPolicyProviding {
    let policy: MemoryEnterprisePolicy

    func currentPolicy() -> MemoryEnterprisePolicy { policy }
}

@MainActor
private struct MemoryFixture {
    let viewModel: AgentViewModel
    let root: URL
    let routineStore: RoutineStore
    let workspaceStore: WorkspaceStore
    let snippetStore: SnippetStore
    let taskHistoryStore: TaskHistoryStore
    let taskPlanDetailStore: TaskPlanDetailStore
    let approvedAppStore: ApprovedAppStore
    let resumableTaskStore: ResumableTaskStore
    let shortcutRunHistoryStore: ShortcutRunHistoryStore
    let visionSessionJournalStore: VisionSessionJournalStore
    let finderReveals: MemoryFixtureFinderRevealer
    let clipboardSettingsStore: ClipboardHistorySettingsStore
    let clipboardHistoryStore: ClipboardHistoryStore
    let outputLocationStore: OutputLocationStore
    /// The whitelist's single root, and deliberately **not** `root` (SONNY-209).
    ///
    /// In production Sonny's own stores live under Application Support and the user's outputs never
    /// do, which is the whole basis on which `OutputLocationStore` tells the two apart. A fixture
    /// that put both in one directory would record `routines.json`'s folder as an output location
    /// and could not tell a correct store from a broken one.
    let outputsRoot: URL
    let pasteboard: MemoryFixturePasteboardReader
    let userDefaults: UserDefaults
    let userDefaultsSuiteName: String
    let removesRoot: Bool

    func cleanUp() {
        // Stops the 1s clipboard timer if a test started one — it is the only thing in this fixture
        // that outlives the test, and a live timer polling a torn-down directory is a leak into
        // whichever suite runs next.
        viewModel.setMemoryEnabled(false)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        if removesRoot {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// 9am on a fixed day in a fixed zone, and the hour after it — the same shape
    /// `ScheduledRoutineRunTests` uses, so a scheduled run here fires for the same reason it does
    /// there rather than for one this file invented.
    static let nineAM: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 9, minute: 0))
            ?? Date(timeIntervalSince1970: 1_700_000_000)
    }()

    static var tenAM: Date { nineAM.addingTimeInterval(3_600) }

    /// A daily 9am routine, enabled a day earlier so `checkScheduledRoutines(now: tenAM)` finds an
    /// occurrence to run, and unattended-trusted so the run is not paused for approval.
    func saveScheduledRoutine() throws {
        var schedule = RoutineSchedule(
            cadence: .daily,
            hour: 9,
            minute: 0,
            unattendedTrusted: true
        )
        schedule.setEnabled(true, now: Self.nineAM.addingTimeInterval(-24 * 60 * 60))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
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
        viewModel.refreshSavedItems()
    }

    /// The same daily 9am routine as `saveScheduledRoutine`, whose one step writes a real Markdown
    /// file into a real folder inside the whitelist (SONNY-209).
    ///
    /// `create_local_draft` is the only capability the deterministic fixtures can run that actually
    /// produces a user-facing file: it needs no network, no Shortcuts and no app, and it resolves its
    /// destination through the whitelist exactly as the other three output-writing adapters do. It is
    /// not on `StoredRoutine.forbiddenStepOperations`, and its tier-2 assessment passes the scheduled
    /// path's fixed `.approved(.tier2)` ceiling — so a scheduled run really executes it unattended,
    /// which is what makes an end-to-end assertion on the scheduled path possible at all.
    ///
    /// The step names its own `outputPath` so the folder under test is a named subdirectory rather
    /// than the whitelist root, and an assertion can say *which* folder was recorded.
    @discardableResult
    func saveScheduledDraftRoutine(intoFolderNamed folderName: String = "Reports") throws -> URL {
        let folder = outputsRoot.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var schedule = RoutineSchedule(
            cadence: .daily,
            hour: 9,
            minute: 0,
            unattendedTrusted: true
        )
        schedule.setEnabled(true, now: Self.nineAM.addingTimeInterval(-24 * 60 * 60))
        try routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "draft",
                        operation: .createLocalDraft,
                        description: "Write the morning note.",
                        outputPath: folder.appendingPathComponent("morning.md").path,
                        draftTitle: "Morning",
                        draftContent: "Good morning."
                    )
                ],
                schedule: schedule
            )
        )
        viewModel.refreshSavedItems()
        return PathWhitelist.canonicalURL(folder.path)
    }

    /// Valid ciphertext under a key this fixture's stores do not have.
    ///
    /// **The founder's failure of 2026-08-23 reproduced, rather than a malformed-bytes stand-in.**
    /// SONNY-240's fixtures wrote real store files under the deterministic test key and the packaged
    /// app then could not open them; a Keychain item replaced by a restore or a migration does the
    /// same thing to all thirteen at once. Bytes that merely fail to parse would exercise the JSON
    /// half of `LocalStorageEncryption.decode` and say nothing about the decrypt half, which is the
    /// half that actually happened.
    ///
    /// Returns the bytes, so a test can prove the set-aside file is the same file.
    @discardableResult
    func writeUnreadableFile(at fileURL: URL) throws -> Data {
        let bytes = try Self.foreignEncryption.encode(["placeholder": UUID().uuidString])
        // The premise: this is a well-formed store file, so what fails is the decrypt.
        #expect(bytes.starts(with: LocalStorageEncryption.fileHeader))
        try bytes.write(to: fileURL, options: .atomic)
        return bytes
    }

    /// A key no store in this fixture holds — the fixture's own is `0x42`.
    static let foreignEncryption = LocalStorageEncryption(
        keyManager: MemoryFixtureKeyManager(bytes: Data(repeating: 0x99, count: 32))
    )

    /// A plan that stops for an approval: it overwrites a file that already exists, which is what
    /// the consequence rule escalates. Same shape `ResumableTaskRunTests` uses.
    func planNeedingApproval() throws -> AgentPlan {
        let folder = try makeOutputFolder("Reports")
        let occupied = folder.appendingPathComponent("notes.md")
        try Data("existing".utf8).write(to: occupied, options: .atomic)
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

    /// Everything `MemoryView`'s `.onAppear` does, in one call.
    ///
    /// **Named for the moment rather than for the calls**, because which calls it is has changed
    /// twice and every test that listed them had to change with it. It also stops a test asserting a
    /// damaged row after `refreshMemoryEntries()` alone, which no surface in the app ever does:
    /// readability comes from `refreshStoreReadability()`, and the page runs both.
    /// `theMemoryPageAppearanceRefreshesEverythingThisFixtureDoes` pins that this stays the same
    /// three calls the view makes.
    func memoryPageAppears() {
        viewModel.refreshMemorySettings()
        viewModel.refreshMemoryEntries()
        viewModel.refreshStoreReadability()
    }

    /// A real folder inside the whitelist, returned in the form the store records it in — the
    /// temporary directory is a symlink on macOS, so a test comparing the unresolved path against a
    /// stored one would compare two spellings of one place.
    ///
    /// (These three lines spent one round stranded above `writeUnreadableFile`, which was inserted
    /// between them and the function they describe — PR #110 review.)
    func makeOutputFolder(_ name: String) throws -> URL {
        let folder = outputsRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return PathWhitelist.canonicalURL(folder.path)
    }

    /// The same 30-second deadlock backstop the other dispatch suites use — a bound on a hang, not a
    /// timing assertion.
    func waitUntilIdle() async throws {
        let deadline = Date().addingTimeInterval(30)
        while viewModel.isRunning || viewModel.isAwaitingApproval {
            #expect(Date() < deadline, "the run never finished")
            guard Date() < deadline else { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

}

/// A second view model over the *same* directory and the same `UserDefaults` suite, for asserting
/// that a preference outlived the instance that wrote it.
@MainActor
private func makeMemoryFixture(reusing fixture: MemoryFixture) throws -> MemoryFixture {
    try makeMemoryFixture(
        root: fixture.root,
        userDefaults: fixture.userDefaults,
        userDefaultsSuiteName: fixture.userDefaultsSuiteName,
        removesRoot: false
    )
}

@MainActor
private func makeMemoryFixture(
    policyProvider: any MemoryPolicyProviding = UnmanagedMemoryPolicyProvider(),
    /// `LocalDataDeletionService(fileURLs: [])` is the hermetic default every other fixture uses, so
    /// `deleteLocalData()` deletes nothing and, since SONNY-266, `setAsideFilesSummary` counts
    /// nothing. The tests about the wipe emptying the Memory lists, and the ones about Settings'
    /// set-aside line, need it pointed at this fixture's own directory and nothing else.
    wipesRealStoreFiles: Bool = false
) throws -> MemoryFixture {
    let suiteName = "MemoryCommandCenterTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MemoryCommandCenterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try makeMemoryFixture(
        root: root,
        userDefaults: userDefaults,
        userDefaultsSuiteName: suiteName,
        policyProvider: policyProvider,
        wipesRealStoreFiles: wipesRealStoreFiles,
        removesRoot: true
    )
}

@MainActor
private func makeMemoryFixture(
    root: URL,
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String,
    policyProvider: any MemoryPolicyProviding = UnmanagedMemoryPolicyProvider(),
    wipesRealStoreFiles: Bool = false,
    removesRoot: Bool
) throws -> MemoryFixture {
    let encryption = LocalStorageEncryption(
        keyManager: MemoryFixtureKeyManager(bytes: Data(repeating: 0x42, count: 32))
    )
    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption)
    let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption)
    let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption)
    let recentArtifactStore = RecentArtifactStore(
        fileURL: root.appendingPathComponent("recent-artifacts.json"),
        encryption: encryption
    )
    let shortcutRunHistoryStore = ShortcutRunHistoryStore(
        fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
        encryption: encryption
    )
    let taskHistoryStore = TaskHistoryStore(
        fileURL: root.appendingPathComponent("task-history.json"),
        encryption: encryption
    )
    let taskPlanDetailStore = TaskPlanDetailStore(
        fileURL: root.appendingPathComponent("task-plan-details.json"),
        encryption: encryption
    )
    let visionSessionJournalStore = VisionSessionJournalStore(
        fileURL: root.appendingPathComponent("vision-sessions.json"),
        encryption: encryption
    )
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let clipboardHistoryStore = ClipboardHistoryStore(
        fileURL: root.appendingPathComponent("clipboard-history.json"),
        encryption: encryption
    )
    let pasteboard = MemoryFixturePasteboardReader()
    let approvedAppStore = ApprovedAppStore(
        fileURL: root.appendingPathComponent("approved-apps.json"),
        encryption: encryption
    )
    // The whitelist root is a subdirectory, not `root` itself, so the fixture reproduces production's
    // separation between where Sonny keeps its own files and where the user's outputs go. See
    // `MemoryFixture.outputsRoot`.
    let outputsRoot = root.appendingPathComponent("Outputs", isDirectory: true)
    try FileManager.default.createDirectory(at: outputsRoot, withIntermediateDirectories: true)
    let outputLocationStore = OutputLocationStore(
        fileURL: root.appendingPathComponent("output-locations.json"),
        encryption: encryption,
        whitelist: PathWhitelist(roots: [outputsRoot])
    )
    let resumableTaskStore = ResumableTaskStore(
        fileURL: root.appendingPathComponent("resumable-tasks.json"),
        encryption: encryption
    )
    let deletionService = wipesRealStoreFiles
        ? LocalDataDeletionService(
            fileURLs: [
                routineStore.fileURL,
                workspaceStore.fileURL,
                snippetStore.fileURL,
                recentArtifactStore.fileURL,
                shortcutRunHistoryStore.fileURL,
                taskHistoryStore.fileURL,
                taskPlanDetailStore.fileURL,
                visionSessionJournalStore.fileURL,
                clipboardSettingsStore.fileURL,
                clipboardHistoryStore.fileURL,
                approvedAppStore.fileURL,
                outputLocationStore.fileURL,
                resumableTaskStore.fileURL
            ]
        )
        : LocalDataDeletionService(fileURLs: [])

    let finderReveals = MemoryFixtureFinderRevealer()
    let viewModel = AgentViewModel(
        routineStore: routineStore,
        workspaceStore: workspaceStore,
        snippetStore: snippetStore,
        recentArtifactStore: recentArtifactStore,
        shortcutCatalog: MemoryFixtureShortcutCatalog(),
        // Hermetic seams, defined in ProductShellTests.swift in this same target. Injected rather
        // than defaulted so hermeticity is structural: these tests execute real plans, and a plan
        // gaining a URL step later must not start opening the developer's browser.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        // A test that reached the live implementation would open Finder on the developer's machine.
        finderRevealer: { finderReveals.record($0) },
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: shortcutRunHistoryStore,
        taskHistoryStore: taskHistoryStore,
        taskPlanDetailStore: taskPlanDetailStore,
        visionSessionJournalStore: visionSessionJournalStore,
        clipboardHistorySettingsStore: clipboardSettingsStore,
        approvedAppStore: approvedAppStore,
        outputLocationStore: outputLocationStore,
        resumableTaskStore: resumableTaskStore,
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: pasteboard,
            store: clipboardHistoryStore,
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: deletionService,
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        memoryPolicyProvider: policyProvider,
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [outputsRoot])
    )

    return MemoryFixture(
        viewModel: viewModel,
        root: root,
        routineStore: routineStore,
        workspaceStore: workspaceStore,
        snippetStore: snippetStore,
        taskHistoryStore: taskHistoryStore,
        taskPlanDetailStore: taskPlanDetailStore,
        approvedAppStore: approvedAppStore,
        resumableTaskStore: resumableTaskStore,
        shortcutRunHistoryStore: shortcutRunHistoryStore,
        visionSessionJournalStore: visionSessionJournalStore,
        finderReveals: finderReveals,
        clipboardSettingsStore: clipboardSettingsStore,
        clipboardHistoryStore: clipboardHistoryStore,
        outputLocationStore: outputLocationStore,
        outputsRoot: outputsRoot,
        pasteboard: pasteboard,
        userDefaults: userDefaults,
        userDefaultsSuiteName: userDefaultsSuiteName,
        removesRoot: removesRoot
    )
}

private struct MemoryFixtureKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data { bytes }
}

/// Records what `revealSetAsideFilesInFinder()` and `runSuggestion(.revealInFinder)` would have
/// shown, since no agent can watch Finder open (SONNY-239, founder decision 2026-08-23).
final class MemoryFixtureFinderRevealer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[URL]] = []

    func record(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(urls)
    }

    var revealed: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private struct MemoryFixtureShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

/// Returns nothing by default, so no test records a clipboard entry by accident. The one test that
/// needs the monitor to actually record sets `text` and bumps `changeCount`, which is what `poll()`
/// reads to decide the pasteboard changed.
@MainActor
private final class MemoryFixturePasteboardReader: PasteboardReading {
    var changeCount = 0
    var text: String?

    func typeIdentifiers() -> [String] { [] }

    func stringValue() -> String? { text }
}
