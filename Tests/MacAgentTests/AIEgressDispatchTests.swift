import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The Data-Sent-to-AI ledger driven through the REAL dispatch path — typed command in,
/// registry-selected planner, `performStart`, ledger record on disk out. Store- and wrapper-level
/// suites pin the pieces; these pin the product wiring those suites cannot see: that the view
/// model actually constructs a per-run recorder, that the ledger's `runStartedAt` is the same
/// instant the task-history record carries (the task-detail join), that a planner-free run
/// leaves no record at all, and that a ledger write failure is visible without failing the run.
@Suite(.serialized)
@MainActor
struct AIEgressDispatchTests {
    @Test
    func aPlannerRunWritesOneLedgerEntryJoinedToItsTaskHistoryRecord() async throws {
        let fixture = try makeEgressDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitUntilIdle(fixture.viewModel)

        let records = try fixture.egressStore.loadAll()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.entries.count == 1)
        let entry = try #require(record.entries.first)
        #expect(entry.kind == .plannerPrompt)
        #expect(entry.providerID == "draft-stub")
        #expect(entry.providerName == "Draft Stub")
        #expect(entry.model == "draft-model")
        #expect(entry.contextSources.contains("command"))

        // The join is by id, exactly: the completed-task record names this ledger record, and
        // reading back through the store's join API lands on it. (The shared instant is kept on
        // the ledger record for display, but ISO8601's whole-second persistence makes a date a
        // fragile join key — the id is the one that binds.)
        let taskRecords = try fixture.taskHistoryStore.loadAll()
        #expect(taskRecords.count == 1)
        let egressRunID = try #require(taskRecords.first?.egressRunID)
        #expect(egressRunID == record.runID)
        #expect(try fixture.egressStore.record(forRunID: egressRunID)?.entries.count == 1)
        #expect(taskRecords.first?.startedAt == record.runStartedAt)
    }

    @Test
    func twoPlannerRunsProduceTwoRecordsWithOneEntryEach() async throws {
        let fixture = try makeEgressDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitUntilIdle(fixture.viewModel)
        try? FileManager.default.removeItem(at: fixture.draftOutput)
        fixture.viewModel.command = "Draft notes again"
        fixture.viewModel.start()
        try await waitUntilIdle(fixture.viewModel)

        let records = try fixture.egressStore.loadAll()
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.entries.count == 1 })
        #expect(Set(records.map(\.runID)).count == 2)
    }

    /// The honestly-empty half of the acceptance criterion: a run the instant resolver handles
    /// never constructs a planner, sends nothing, and therefore has no ledger record — absence,
    /// not an empty placeholder.
    @Test
    func aPlannerFreeRunLeavesNoLedgerRecord() async throws {
        let fixture = try makeEgressDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "2 + 2"
        fixture.viewModel.start()
        try await waitUntilIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary.contains("4"))
        #expect(try fixture.egressStore.loadAll().isEmpty)
        // The run itself is real and recorded in task history — with no phantom ledger join.
        let taskRecords = try fixture.taskHistoryStore.loadAll()
        #expect(taskRecords.count == 1)
        #expect(taskRecords.first?.egressRunID == nil)
    }

    @Test
    func aLedgerWriteFailureIsVisibleButDoesNotFailTheRun() async throws {
        let fixture = try makeEgressDispatchFixture(blockLedgerFile: true)
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitUntilIdle(fixture.viewModel)

        // The prompt still went out, the plan still ran, the draft exists.
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        // And the failure to record it is visible, in write-failure wording.
        #expect(fixture.viewModel.errorMessage?.contains("Data-Sent-to-AI") == true)
        #expect(fixture.viewModel.errorMessage?.contains("could not be decrypted or decoded") != true)
    }
}

// MARK: - Fixture

@MainActor
private struct EgressDispatchFixture {
    let viewModel: AgentViewModel
    let root: URL
    let draftOutput: URL
    let egressStore: AIEgressStore
    let taskHistoryStore: TaskHistoryStore
    let defaultsSuiteName: String

    func tearDown() {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeEgressDispatchFixture(blockLedgerFile: Bool = false) throws -> EgressDispatchFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AIEgressDispatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let draftOutput = root.appendingPathComponent("notes.md")

    let suiteName = "AIEgressDispatchTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let ledgerURL = root.appendingPathComponent("ai-egress-ledger.json")
    if blockLedgerFile {
        // A directory where the ledger file should be makes every append fail.
        try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: true)
    }
    let egressStore = AIEgressStore(fileURL: ledgerURL)
    let taskHistoryStore = TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json"))

    let registry = PlannerProviderRegistry(
        defaultProvider: PlannerProvider(id: "draft-stub", displayName: "Draft Stub") { _ in
            EgressDraftPlanner(output: draftOutput)
        }
    )
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: EmptyEgressShortcutCatalog(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: taskHistoryStore,
        aiEgressStore: egressStore,
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: registry,
        plannerSelection: nil,
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    return EgressDispatchFixture(
        viewModel: viewModel,
        root: root,
        draftOutput: draftOutput,
        egressStore: egressStore,
        taskHistoryStore: taskHistoryStore,
        defaultsSuiteName: suiteName
    )
}

@MainActor
private func waitUntilIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 2) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not become idle before timeout.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Returns the same tier-2 draft plan for every command — a hosted-planner stand-in that states
/// a model identifier, minus the network.
private struct EgressDraftPlanner: Planning {
    let output: URL

    var plannerModelIdentifier: String? { "draft-model" }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Draft notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft notes.",
                    outputPath: output.path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )
    }
}

private struct EmptyEgressShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
