import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// V2 Milestone A through the view model's real dispatch path (SONNY-544): a typed command, the
/// planner's `interact_with_app` plan, the new runtime on cua-driver in place of `runner.execute`,
/// and the result, failure or refusal landing where every other run's does.
@MainActor
struct AppInteractionDispatchTests {
    @Test
    func aNotePlanRunsOnTheNewRuntimeAndLandsAsAResult() async throws {
        let notes = FakeCuaNotes()
        let fixture = try makeFixture(plan: notePlan())
        defer { fixture.tearDown() }
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(notes, chooser: WritesIntoTheEditorOnce()) }

        fixture.viewModel.command = "make a note in Notes saying buy milk"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary == #"I made a new note in Notes: "Buy milk""#)
        #expect(await notes.state.notes.last == "Buy milk")
    }

    @Test
    func aRefusedStepReachesThePersonAsTheFailureItIs() async throws {
        var state = FakeCuaNotesState()
        state.newNoteEnabled = false
        let notes = FakeCuaNotes(state: state)
        let fixture = try makeFixture(plan: notePlan())
        defer { fixture.tearDown() }
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(notes, chooser: WritesIntoTheEditorOnce()) }

        fixture.viewModel.command = "make a note in Notes saying buy milk"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.errorMessage == AppInteractionFailure.couldNotStartItem("Notes", "note").userMessage)
        #expect(await notes.state.notes == ["Groceries for Sunday", "Mom's birthday ideas"])
    }

    /// PR #289 review, F8: a Stop after Sonny changed something says what is still there.
    @Test
    func stoppingAfterTheNoteStartedSaysSo() async throws {
        let notes = FakeCuaNotes()
        let fixture = try makeFixture(plan: notePlan())
        defer { fixture.tearDown() }
        let hangs = HangsOnceStarted()
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(notes, chooser: hangs) }

        fixture.viewModel.command = "make a note in Notes saying buy milk"
        fixture.viewModel.start()
        await hangs.waitUntilHanging()
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary == "Stopped. I had already started a new note in Notes.")
        #expect(fixture.viewModel.errorMessage == nil)
    }

    @Test
    func theStepMixedWithAnotherIsRefusedAndTheRuntimeIsNeverBuilt() async throws {
        let mixed = AgentPlan(
            summary: "Open Safari, then make a note.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open", operation: .openApp, description: "Open Safari", appName: "Safari"),
                notePlan().steps[0],
            ]
        )
        let fixture = try makeFixture(plan: mixed)
        defer { fixture.tearDown() }
        var built = false
        fixture.viewModel.appInteractionRuntimeOverride = { _ in
            built = true
            return runtime(FakeCuaNotes(), chooser: WritesIntoTheEditorOnce())
        }

        fixture.viewModel.command = "open Safari and make a note in Notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        // Asked before anything runs, so Safari never opens (PR #289 review, F9).
        #expect(!built)
        #expect(fixture.viewModel.clarificationQuestion == AppInteractionCapabilityAdapter.aloneQuestion)
        #expect(fixture.viewModel.errorMessage == nil)
    }
}

// MARK: - Doubles

/// The model's part, played by rule: put the text in the editor, then say finished.
private final class WritesIntoTheEditorOnce: AppInteractionStepChoosing, @unchecked Sendable {
    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        if history.last?.did.hasPrefix("enter_text") == true { return .finished }
        guard let editor = screen.candidates.first(where: { $0.kind == "text area" }) else { return .giveUp("no editor") }
        return .step(.enterText, ref: editor.ref)
    }
}

/// Waits until it is cancelled, signalling when it starts waiting.
private final class HangsOnceStarted: AppInteractionStepChoosing, @unchecked Sendable {
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (signal, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func waitUntilHanging() async {
        for await _ in signal { return }
    }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        continuation.yield()
        // A hang backstop, not a bet on a window: only a failure to cancel ever reaches it.
        try await Task.sleep(for: .seconds(3_600))
        return .giveUp("unreachable")
    }
}

private struct NotesOnly: AppInteractionAppOpening {
    func resolve(_ name: String) -> InstalledApp? {
        InstalledApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
    }

    func open(bundleIdentifier: String) async throws -> pid_t { 4242 }
}

private func runtime(_ notes: FakeCuaNotes, chooser: any AppInteractionStepChoosing) -> AppInteractionRuntime {
    AppInteractionRuntime(
        driver: CuaDriverClient(invoker: notes),
        chooser: chooser,
        apps: NotesOnly(),
        appControl: { _ in .allowed },
        redact: { $0 },
        sleep: { _ in await Task.yield() }
    )
}

private func notePlan() -> AgentPlan {
    AgentPlan(
        summary: "New note.",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "note",
                operation: .interactWithApp,
                description: "New note in Notes",
                appName: "Notes",
                interactionGoal: "A new note that says buy milk",
                interactionTarget: nil,
                interactionText: "Buy milk"
            ),
        ]
    )
}

private struct FixedPlanner: Planning {
    let plan: AgentPlan

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan { plan }
}

private struct NoShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

private struct Fixture {
    let viewModel: AgentViewModel
    let root: URL

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeFixture(plan: AgentPlan) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AppInteractionDispatchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suiteName = "AppInteractionDispatchTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let file = { (name: String) in root.appendingPathComponent(name) }

    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: file("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: file("workspaces.json")),
        snippetStore: SnippetStore(fileURL: file("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: file("recent-artifacts.json")),
        shortcutCatalog: NoShortcuts(),
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: { _ in },
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: file("shortcuts-run-history.json")),
        taskHistoryStore: TaskHistoryStore(fileURL: file("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: file("task-plan-details.json")),
        visionSessionJournalStore: VisionSessionJournalStore(fileURL: file("vision-sessions.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(fileURL: file("clipboard-history-settings.json")),
        approvedAppStore: ApprovedAppStore(fileURL: file("approved-apps.json")),
        outputLocationStore: OutputLocationStore(fileURL: file("output-locations.json"), whitelist: PathWhitelist(roots: [root])),
        resumableTaskStore: ResumableTaskStore(fileURL: file("resumable-tasks.json")),
        pendingServerDeletionStore: PendingServerDeletionStore(fileURL: file("pending-server-deletions.json")),
        skillSelectionStore: SkillSelectionStore(fileURL: file("added-skills.json")),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: HermeticPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: file("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(fileURL: file("clipboard-history-settings.json"))
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        makePlanner: { _, _ in FixedPlanner(plan: plan) },
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    return Fixture(viewModel: viewModel, root: root)
}

/// Waits for the run to end through the shared backstop, which tells a stuck run from a busy
/// machine by how often it got to look: the full suite saturates the main actor, and a plain
/// thirty-second wall clock failed these tests there while each run was merely queued.
@MainActor
private func waitForIdle(_ viewModel: AgentViewModel) async throws {
    try await HangBackstop.waitOrAbandon(for: "the interaction run to finish") { !viewModel.isRunning }
}
