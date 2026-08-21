import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// "Run again" — re-ask Sonny with the same words, never replay the plan (row E, SONNY-149).
///
/// **Every test here drives the real dispatch path.** The fixture wires a planner it can read back,
/// so "the plan is produced fresh" is asserted by watching the planner be called rather than by
/// watching a run happen — a run happening is exactly what a replay would also look like.
@Suite
@MainActor
struct RunTaskAgainTests {
    /// **The criterion that separates re-asking from replaying.** The planner is called, with this
    /// record's own command, and it is called on this dispatch rather than having been called once
    /// long ago — the count moves from zero to one.
    @Test
    func runningAgainSendsTheRecordsCommandBackThroughThePlanner() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        let record = makeRecord(command: "summarize my week")

        #expect(fixture.planner.commands.isEmpty, "nothing has planned yet")
        let accepted = fixture.viewModel.runTaskAgain(record)
        try await fixture.waitForIdle()

        #expect(accepted)
        #expect(fixture.planner.commands == ["summarize my week"])
        // And it really ran: a new row for the same command, on top of the one seeded below it.
        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.map(\.command) == ["summarize my week"])
        #expect(rows.last?.outcomeStatus == .completed)
    }

    /// A stored *plan* is never the thing that runs. Nothing in the codebase can even express that
    /// today, which is why this asserts the positive: the plan this run executed is the one the
    /// planner just returned, not the one the record's own detail store holds.
    @Test
    func runningAgainExecutesThePlanThePlannerJustReturnedAndNotTheStoredOne() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        let record = makeRecord(command: "summarize my week")
        let recordID = try #require(record.id)
        // A stored plan from the first run, deliberately different from what the planner returns
        // now. If anything ever replayed it, this summary would be the one that came back.
        try fixture.taskPlanDetailStore.save(
            StoredTaskPlanDetail(
                taskID: recordID,
                completedAt: record.completedAt,
                planSummary: "The plan from the first run",
                steps: [PriorTaskStepContext(operation: .openApp, description: "Open Safari.", details: [])]
            )
        )

        fixture.viewModel.runTaskAgain(record)
        try await fixture.waitForIdle()

        #expect(fixture.planner.commands == ["summarize my week"])
        let plan = try #require(fixture.viewModel.plan)
        #expect(plan.summary == RunAgainRecordingPlanner.planSummary)
        #expect(plan.steps.map(\.operation) == [.calculateUtility])
        // The stored plan is untouched: re-asking reads nothing from it.
        let stored = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: recordID))
        #expect(stored.planSummary == "The plan from the first run")
    }

    /// A record whose workspace still exists runs bound to it.
    @Test
    func runningAgainCarriesTheRecordsWorkspaceWhenItStillExists() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: [], urls: []))
        fixture.viewModel.refreshSavedItems()

        fixture.viewModel.runTaskAgain(makeRecord(command: "summarize my week", workspaceName: "Research"))
        try await fixture.waitForIdle()

        guard case .scoped(let scope) = fixture.viewModel.lastAssessedScope else {
            Issue.record("Expected a scoped run, got \(fixture.viewModel.lastAssessedScope)")
            return
        }
        #expect(scope.workspaceName == "Research")
        #expect(fixture.viewModel.errorMessage == nil)
        // The command deliberately never says "Research". That is what makes this a test of the
        // binding rather than of `WorkspaceTaskTagging`, which would have found the name in the
        // command text on its own and bound the same scope for a different reason.
        #expect(!fixture.planner.commands.contains { $0.localizedCaseInsensitiveContains("research") })
        // **The new row is not tagged, and that is pre-existing rather than this ticket's doing.**
        // `recordTaskHistoryIfTerminal` derives the tag from `WorkspaceTaskTagging`, which reads the
        // command and the plan and never the explicit binding — so any dispatch that binds a
        // workspace the command does not name writes an untagged row, the workspace card's "New task
        // in …" flow included. Asserted rather than left silent so a later reader does not read the
        // absence as something run-again broke. Filed as SONNY-195.
        #expect(try fixture.taskHistoryStore.loadAll().last?.workspaceName == nil)
    }

    /// A record whose workspace has since been deleted runs **unscoped** and does not error —
    /// `resolveTaskScope`'s recorded behaviour, relied on here rather than re-implemented.
    @Test
    func runningAgainAWorkspaceThatIsGoneRunsUnscopedWithoutErroring() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        // No workspace saved at all: the name on the record resolves to nothing.

        let accepted = fixture.viewModel.runTaskAgain(
            makeRecord(command: "summarize my week", workspaceName: "Deleted Workspace")
        )
        try await fixture.waitForIdle()

        #expect(accepted)
        #expect(fixture.viewModel.lastAssessedScope == .unscoped)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.localStorageNotice == nil, "a workspace that is gone is not a store failure")
        #expect(try fixture.taskHistoryStore.loadAll().last?.workspaceName == nil)
    }

    /// **The origin is stated, not inherited.** Asserted against a run that really did set a
    /// different one first, because `.commandCenter` is also the property's initial value and an
    /// assertion made from a fresh view model would pass on a method that set nothing at all.
    @Test
    func runningAgainStatesItsOwnOriginRatherThanInheritingTheLastRuns() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }

        fixture.viewModel.command = "something from the widget"
        fixture.viewModel.start(origin: .widget)
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.activeTaskOrigin == .widget, "the fixture really did set another origin first")

        fixture.viewModel.runTaskAgain(makeRecord(command: "summarize my week"))
        try await fixture.waitForIdle()

        #expect(fixture.viewModel.activeTaskOrigin == .commandCenter)
    }

    /// Refused while a task is in flight — and the refusal leaves the choke point's own trace rather
    /// than a second message of its own. The clarification case is used because it is the in-flight
    /// state that looks idle: `isRunning` is false throughout it.
    @Test
    func runningAgainIsRefusedDuringAClarificationAndLeavesTheChokePointTrace() throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.clarificationQuestion = "Which folder should Sonny use?"
        #expect(fixture.viewModel.isTaskInFlight)

        let accepted = fixture.viewModel.runTaskAgain(makeRecord(command: "summarize my week"))

        #expect(!accepted)
        #expect(fixture.planner.commands.isEmpty, "nothing was planned")
        #expect(
            fixture.viewModel.logStore.events.contains {
                $0.message == "Not started: Sonny was not ready to begin another task."
            },
            "the refusal is traced at the dispatch choke point"
        )
        // The invariant `dispatch` exists to keep: a refused dispatch leaves no text behind, so a
        // clarification answered afterwards interpolates only the question and the answer.
        #expect(fixture.viewModel.command.isEmpty)
    }

    /// The other two in-flight states refuse as well — an approval waiting, and a run under way.
    @Test
    func runningAgainIsRefusedWhileAnApprovalIsWaiting() async throws {
        let fixture = try makeRunAgainFixture()
        defer { fixture.cleanUp() }
        try fixture.snippetStore.save(StoredSnippet(trigger: ";run-again", expansion: "Old text"))
        fixture.viewModel.command = "snippet save ;run-again = Hello"
        fixture.viewModel.start()
        try await fixture.waitForIdle()
        #expect(fixture.viewModel.isAwaitingApproval)
        let plannedBefore = fixture.planner.commands.count

        let accepted = fixture.viewModel.runTaskAgain(makeRecord(command: "summarize my week"))

        #expect(!accepted)
        #expect(fixture.planner.commands.count == plannedBefore)
        #expect(fixture.viewModel.isAwaitingApproval, "the waiting approval is untouched")
    }

    /// Offered for every terminal outcome, failed most of all.
    @Test
    func runAgainIsOfferedForCompletedFailedAndCanceledAlike() {
        for status in [PriorTaskOutcomeStatus.completed, .failed, .canceled] {
            var record = makeRecord(command: "summarize my week")
            record.outcomeStatus = status
            #expect(TaskDetailPresentation.showsRunAgain(for: record), "\(status) should offer Run again")
        }
    }

    /// And withheld for the one record it could not work on: a command that is empty, which
    /// `canSubmit` would refuse anyway. Offering a control that cannot work is worse than not
    /// offering it.
    @Test
    func runAgainIsWithheldForARecordWithNothingToRun() {
        #expect(!TaskDetailPresentation.showsRunAgain(for: makeRecord(command: "")))
        #expect(!TaskDetailPresentation.showsRunAgain(for: makeRecord(command: "   ")))
    }

    /// **No stored-plan door was opened.** `runTaskAgain` reaches `dispatch`, which reaches `start`,
    /// which reaches `performStart` — the same three doors a typed command uses. Pinned on the source
    /// because the alternative it must never become is a second execution path, and a second path is
    /// a thing you can only see by looking at what the method calls.
    @Test
    func runTaskAgainReachesTheSameDispatchChokePointATypedCommandDoes() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let body = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "func runTaskAgain(_ record: CompletedTaskRecord) -> Bool {"
        )

        #expect(body.contains("dispatch("))
        #expect(body.contains("origin: .commandCenter"))
        #expect(body.contains("workspaceBinding: record.workspaceName"))
        // Nothing that would be a second execution path or a stored-plan read.
        #expect(!body.contains("prebuiltPlan"))
        #expect(!body.contains("taskPlanDetailStore"))
        #expect(!body.contains("runner"))
        #expect(!body.contains("executor"))
    }

    // MARK: - Fixtures

    private func makeRecord(
        command: String,
        workspaceName: String? = nil
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_030),
            outcomeStatus: .completed,
            workspaceName: workspaceName,
            result: .codeAuthored("1 + 1 = 2")
        )
    }
}

/// Records what it was asked to plan, and answers with a plan that executes hermetically.
///
/// The calculator is the answer because it touches nothing: no file, no app, no network. What is
/// being asserted is that the planner was *reached*, not what it produced.
final class RunAgainRecordingPlanner: Planning, @unchecked Sendable {
    static let planSummary = "Freshly planned by the planner."

    private(set) var commands: [String] = []
    private(set) var contextTexts: [String?] = []

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        commands.append(command)
        contextTexts.append(priorTaskContext?.plannerContextText)
        return AgentPlan(
            summary: Self.planSummary,
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "calc", operation: .calculateUtility, description: "Calculate", searchQuery: "1 + 1")
            ]
        )
    }
}

@MainActor
private struct RunAgainFixture {
    let viewModel: AgentViewModel
    let planner: RunAgainRecordingPlanner
    let root: URL
    let taskHistoryStore: TaskHistoryStore
    let taskPlanDetailStore: TaskPlanDetailStore
    let workspaceStore: WorkspaceStore
    let snippetStore: SnippetStore

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

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeRunAgainFixture() throws -> RunAgainFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunTaskAgainTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "RunTaskAgainTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let planner = RunAgainRecordingPlanner()
    let taskHistoryStore = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"))
    let taskPlanDetailStore = TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json"))
    let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
    let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))

    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: workspaceStore,
        snippetStore: snippetStore,
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: RunAgainEmptyShortcutCatalog(),
        // Hermetic seams (the fakes live in ProductShellTests.swift, same target). These tests
        // execute real plans; the fixture's planner answers with a calculator step that touches
        // nothing, but the seams are injected so that stays a property of the fixture rather than
        // of the command that happens to be under test.
        browserOpener: HermeticBrowserOpener(),
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
        taskHistoryStore: taskHistoryStore,
        taskPlanDetailStore: taskPlanDetailStore,
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "run-again-stub", displayName: "Run Again Stub") { _ in planner }
        ),
        plannerSelection: nil,
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )

    return RunAgainFixture(
        viewModel: viewModel,
        planner: planner,
        root: root,
        taskHistoryStore: taskHistoryStore,
        taskPlanDetailStore: taskPlanDetailStore,
        workspaceStore: workspaceStore,
        snippetStore: snippetStore
    )
}

private struct RunAgainEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
