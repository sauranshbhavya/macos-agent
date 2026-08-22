import Foundation
import Testing
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
    /// of the seven types had their memory switch verified by reading the shared
    /// `allowsRecording(to:)` rather than by exercising it.
    ///
    /// **Asserted at the seam rather than by dispatching, and that is the correct instrument here,
    /// not a shortcut.** `recentArtifactStoreForThisRun`'s own doc records why: no command the
    /// fixtures can run generates an artifact, so a suppressed run leaves that store untouched
    /// either way and an end-to-end assertion passes for the wrong reason — a mutation battery
    /// caught exactly that. The vision journal is worse: `makeVisionEnvironment` returns nil without
    /// an API key and the vision tests inject their own substrate, so no test in this repository can
    /// execute the live decision at all. Row I built a `nil` store as "run the session, record
    /// nothing", which is what makes asserting the handover the same thing as asserting the
    /// suppression.
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
            newestEntryDate: fixture.viewModel.newestMemoryEntryDate(for: .snippets),
            now: now
        )

        #expect(presentation.title == "Snippets")
        #expect(presentation.count == 2)
        #expect(presentation.isRecording)
        // The newest of the two, not the first written.
        #expect(presentation.detailText == "2 saved · newest Today, \(expectedTime(for: now))")
    }

    @Test
    func anEmptyRowSaysSoWithoutInventingATimestamp() {
        let presentation = MemoryRowPresentation(
            category: .workspaces,
            count: 0,
            isRecording: false,
            canChangeRecording: true,
            newestEntryDate: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(presentation.detailText == "0 saved")
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

    /// **Where "View" leads, for all seven rows** (PR #98 review, F4). Rewiring Task history to open
    /// Insights left the whole suite green, and "each memory type is viewable" is the first clause of
    /// the ticket's acceptance criteria.
    @Test
    func viewLeadsSomewhereSpecificForEveryMemoryType() {
        #expect(MemoryRowDestination.of(.routines) == .page(.routines))
        #expect(MemoryRowDestination.of(.workspaces) == .page(.workspaces))
        #expect(MemoryRowDestination.of(.taskHistory) == .page(.tasks))
        #expect(MemoryRowDestination.of(.recentArtifacts) == .entriesSheet)
        #expect(MemoryRowDestination.of(.clipboardHistory) == .entriesSheet)
        #expect(MemoryRowDestination.of(.snippets) == .entriesSheet)
        #expect(MemoryRowDestination.of(.approvedApps) == .entriesSheet)

        // Every row leads somewhere, and the three page destinations are distinct — a mapping that
        // sent two rows to one page would satisfy a looser check.
        let destinations = MemoryCategory.allCases.map(MemoryRowDestination.of)
        #expect(destinations.count == 7)
        let pages = destinations.compactMap { destination -> CommandCenterDestination? in
            guard case .page(let page) = destination else { return nil }
            return page
        }
        #expect(Set(pages).count == pages.count)
        #expect(!pages.contains(.memory), "a row must not send the user back to the page they are on")

        // Exactly the four types the sheet renders entries for open the sheet, so the two mappings
        // cannot drift apart.
        let sheetTypes = MemoryCategory.allCases.filter { MemoryRowDestination.of($0) == .entriesSheet }
        #expect(Set(sheetTypes) == [.recentArtifacts, .clipboardHistory, .snippets, .approvedApps])
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

        // The sheet's copy exists for the four types it opens for, and deliberately not for the
        // three deleted from their own pages.
        for category in [MemoryCategory.recentArtifacts, .clipboardHistory, .snippets, .approvedApps] {
            #expect(!MemoryDeletionCopy.entryMessage(for: category).isEmpty, "\(category.title)")
            #expect(!MemoryDeletionCopy.emptyMessage(for: category).isEmpty, "\(category.title)")
            #expect(MemoryDeletionCopy.emptyTitle(for: category).hasPrefix("No "), "\(category.title)")
        }
        for category in [MemoryCategory.routines, .workspaces, .taskHistory] {
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
    func theEntriesSheetRendersOnlyTheFourTypesWithoutPagesOfTheirOwn() throws {
        let fixture = try makeMemoryFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "line one\nline two"))
        try fixture.approvedAppStore.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        fixture.viewModel.refreshMemoryEntries()

        let snippets = MemoryEntryPresentation.entries(for: .snippets, viewModel: fixture.viewModel)
        #expect(snippets.map(\.title) == [";sig"])
        // A multi-line expansion is squeezed onto one line rather than claiming the height of
        // whatever was saved.
        #expect(snippets.first?.detail == "line one line two")

        let apps = MemoryEntryPresentation.entries(for: .approvedApps, viewModel: fixture.viewModel)
        #expect(apps.map(\.title) == ["Safari"])
        #expect(try #require(apps.first).detail.contains("com.apple.Safari"))

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
    let clipboardSettingsStore: ClipboardHistorySettingsStore
    let clipboardHistoryStore: ClipboardHistoryStore
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
    /// `deleteLocalData()` deletes nothing. The one test about the wipe emptying the Memory lists
    /// needs it to delete for real, over this fixture's own directory and nothing else.
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
                approvedAppStore.fileURL
            ]
        )
        : LocalDataDeletionService(fileURLs: [])

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
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: pasteboard,
            store: clipboardHistoryStore,
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: deletionService,
        memoryPolicyProvider: policyProvider,
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
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
        clipboardSettingsStore: clipboardSettingsStore,
        clipboardHistoryStore: clipboardHistoryStore,
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
