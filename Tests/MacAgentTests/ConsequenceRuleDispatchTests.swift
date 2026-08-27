import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgent
@testable import MacAgentCore

/// The consequence rule driven through the REAL dispatch path, end to end — typed command in,
/// planner (a fake provider registered through the real registry), `performStart`, the real
/// assessment, the real gate, the real execution, file on disk out.
///
/// This suite exists because of the 2026-08-13 manual-pass finding: row C's relaxation shipped
/// with 950 green tests pinning the mapping *function* while nothing pinned the product's dispatch
/// path into it, and the live app never fired the grant. A mapping-level suite can be green while
/// the product is wrong; these tests are the ones that would have caught it, rebuilt for the rule
/// that replaced the grants. The `AgentViewModel` whitelist and Safe-mode seams these tests use
/// were added for exactly this purpose.
@Suite(.serialized)
@MainActor
struct ConsequenceRuleDispatchTests {
    /// A tier-2 draft inside its own workspace, typed as a command: runs with no prompt, writes
    /// the file, and leaves the ran-without-asking trace.
    @Test
    func anInWorkspaceTierTwoDraftTypedAsACommandAutoRuns() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [fixture.projectFolder.path]
            )
        )
        fixture.viewModel.refreshSavedItems()

        fixture.viewModel.command = "Draft notes in Client Alpha"
        fixture.viewModel.start(workspaceBinding: "Client Alpha")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.lastAssessedScope != .unscoped)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
    }

    /// The identical draft with no workspace bound runs identically — the boundary is data, not a
    /// gate, so its absence must not re-introduce a prompt.
    @Test
    func aPlainUnscopedTierTwoDraftTypedAsACommandAutoRuns() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.lastAssessedScope == .unscoped)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
    }

    /// The overwrite still prompts — the destructive class keeps today's asking exactly — and
    /// approving it is what performs the write. No trace: the prompt was the disclosure.
    @Test
    func anOverwriteStillPromptsThroughTheRealDispatchPathAndApprovingRunsIt() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try "existing draft".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        #expect(request.requirement == .explicitApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) == "existing draft")

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) != "existing draft")
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }

    /// Safe mode makes all three ask — the in-workspace draft, the unscoped draft, and the
    /// overwrite — through the same real path, reading the same stored property SONNY-90 will back
    /// with Settings.
    @Test
    func safeModeMakesAllThreeAskThroughTheRealDispatchPath() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [fixture.projectFolder.path]
            )
        )
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.interactionMode = .safe

        // 1. In-workspace draft.
        fixture.viewModel.command = "Draft notes in Client Alpha"
        fixture.viewModel.start(workspaceBinding: "Client Alpha")
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(!FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        fixture.viewModel.cancelCurrentRun()

        // 2. Unscoped draft.
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(!FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        fixture.viewModel.cancelCurrentRun()

        // 3. The overwrite (asks either way; Safe mode must not make it ask less).
        try "existing draft".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) == "existing draft")
        fixture.viewModel.cancelCurrentRun()
    }

    /// **Power through the real dispatch path, and why this test arrived with a chassis ticket.**
    ///
    /// Until SONNY-142 the engine's posture input was a boolean, so Normal and Power were literally
    /// the same value by the time a requirement was computed — nothing could distinguish them and
    /// nothing needed to. They are distinct enum cases now, reaching the one requirement function as
    /// distinct cells of one switch, and this is the file that would notice if widening the chassis
    /// had quietly changed what Power does.
    ///
    /// **The name is scoped, and the scope is the point** (PR #88 cycle 2, F2). This used to be
    /// called `powerModeBehavesExactlyLikeNormalThroughTheRealDispatchPath`, which stopped being
    /// true on 2026-08-21: Power is now the one mode that skips the per-app control gate. The
    /// assertions were right all along — neither plan here controls an app, so for a *non-vision*
    /// dispatch the two modes really do still answer identically — but the name claimed the general
    /// case. What the per-app difference looks like through a real path is
    /// `powerSkipsThePerAppGateAndStillAsksAboutADestructiveAction` in `VisionSessionRunTests`.
    ///
    /// Both halves are asserted together on purpose. The auto-run half is what "the two agree on a
    /// non-vision plan" means; the overwrite half is the standing rule that survives every mode, and
    /// asserting only the first would let "Power skips a gate" be misread as "Power asks nothing".
    @Test
    func powerAndNormalAgreeOnANonVisionDispatchAndBothStillAskAboutAnOverwrite() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.interactionMode = .power

        // 1. The ordinary tier-2 draft: no prompt, file written, trace left — Normal's answer.
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")

        // 2. The overwrite still asks, in Power. The consequence rule is not a mode setting.
        fixture.viewModel.clearStaleTaskOutcome()
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        fixture.viewModel.cancelCurrentRun()
    }

    // MARK: - The trace's lifetime

    /// PR #48, F1 — the trace must not outlive the run it describes into the one deliberately
    /// destructive thing in the app.
    ///
    /// `deleteLocalData` writes its own `finalSummary`, and `WidgetResultPanel` renders
    /// `ranWithoutAskingTrace` under whatever summary is showing. A trace that survived
    /// `clearInMemoryLocalDataState` therefore put "nothing here is destructive, and it affects no
    /// one else" directly beneath "Deleted N local data files." — asserting the opposite of what the
    /// user had just done, on the one surface the trace exists to be read on.
    @Test
    func deletingAllLocalDataClearsTheRanWithoutAskingTraceItWouldOtherwiseRenderUnder() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start(origin: .widget)
        try await waitForIdle(fixture.viewModel)

        // Premises, guarded rather than assumed: the trace is really set, on a panel that is really
        // on screen. Without both, the assertion after the deletion passes for the wrong reason.
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        fixture.viewModel.deleteLocalData()

        // Still a real render — the deletion result is showing, so an uncleared trace would be
        // visible underneath it rather than merely resident.
        #expect(fixture.viewModel.finalSummary == "Deleted 0 local data files.")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }

    /// The sibling clear. The trace has no lifetime of its own: `WidgetResultPanel` is its only
    /// reader and that panel exists only while `finalSummary` is non-empty, so the widget's
    /// auto-clear timer has to take both. Left behind, the value can never again be shown with the
    /// run it describes — it can only reappear attached to someone else's summary, which is the
    /// shape F1 arrived in.
    @Test
    func clearingAStaleTaskOutcomeTakesTheRanWithoutAskingTraceWithIt() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start(origin: .widget)
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")

        fixture.viewModel.clearStaleTaskOutcome()

        #expect(fixture.viewModel.finalSummary.isEmpty)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }
}

// MARK: - Fixture

@MainActor
private struct DispatchFixture {
    let viewModel: AgentViewModel
    let root: URL
    let projectFolder: URL
    let draftOutput: URL
    let workspaceStore: WorkspaceStore

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The real view model with three substitutions, each named: a fake planner provider registered
/// through the real registry (so the typed-command branch of `performStart` runs without a network
/// key), the fixture root as the whitelist (so the draft is writable hermetically), and the
/// hermetic side-effect seams every view-model suite injects.
@MainActor
private func makeDispatchFixture() throws -> DispatchFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConsequenceRuleDispatchTests-\(UUID().uuidString)", isDirectory: true)
    let projectFolder = root.appendingPathComponent("ClientAlpha", isDirectory: true)
    try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
    let draftOutput = projectFolder.appendingPathComponent("notes.md")

    let suiteName = "ConsequenceRuleDispatchTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
    let registry = PlannerProviderRegistry(
        defaultProvider: PlannerProvider(id: "draft-stub", displayName: "Draft Stub") { _ in
            DraftPlanner(output: draftOutput)
        }
    )
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: workspaceStore,
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: EmptyDispatchShortcutCatalog(),
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: hermeticFinderRevealer,
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
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            // The same roots this fixture hands the view model, so the store answers
            // "is this an output location" against the folders the run really used.
            whitelist: PathWhitelist(roots: [root])
        ),
        resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: HermeticPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: registry,
        plannerSelection: nil,
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    return DispatchFixture(
        viewModel: viewModel,
        root: root,
        projectFolder: projectFolder,
        draftOutput: draftOutput,
        workspaceStore: workspaceStore
    )
}

/// The 30 seconds is a deadlock backstop, not a timing assertion (SONNY-159/160/161): this target is
/// `@MainActor` and Swift Testing interleaves its suites on one actor, so the previous 2 s fired when a
/// neighbouring test was busy rather than when anything was wrong. Full reasoning and the measurements
/// are on `VisionSessionRunTests.hangBackstop`.
@MainActor
private func waitForIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 30) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not become idle before timeout. Waited 30s, which at this length means genuinely stuck rather than merely busy — treat it as a real failure.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Returns the same tier-2 draft plan for every command — the planner half of the manual-pass
/// scenario, minus the network.
private struct DraftPlanner: Planning {
    let output: URL

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

private struct EmptyDispatchShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}
