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
        #expect(notice.contains("needs your explicit approval"))
        // The tier-3 action really did not happen.
        #expect(try fixture.snippetStore.snippet(matchingTrigger: ";sig").expansion == "Old text")
        #expect(try fixture.routineStore.routine(named: "Morning").effectiveRecentRunDates.isEmpty)
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
