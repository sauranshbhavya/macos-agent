import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// V2 Milestone A through the view model's real dispatch path (SONNY-544): a typed command, the
/// planner's `interact_with_app` plan, the new runtime in place of `runner.execute`, and the result,
/// failure or refusal landing where every other run's does.
@MainActor
struct AppInteractionDispatchTests {
    @Test
    func aDraftPlanRunsOnTheNewRuntimeAndLandsAsAResult() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Dad", "Mom"]))
        let fixture = try makeFixture(plan: draftPlan())
        defer { fixture.tearDown() }
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(app, chooser: FindAndTypeChooser()) }

        fixture.viewModel.command = "draft a WhatsApp to Mom saying running late"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.finalSummary == "The message is in the Mom chat in Chat, not sent: \"Running late\"")
        let state = await app.state
        #expect(state.drafts == ["Mom": "Running late"])
        #expect(state.sentMessages.isEmpty)
    }

    @Test
    func aRefusedStepReachesThePersonAsTheFailureItIs() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.exposesHeader = false
        let app = FakeChatAppAccessibility(state: state)
        let fixture = try makeFixture(plan: draftPlan())
        defer { fixture.tearDown() }
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(app, chooser: PressesSendChooser()) }

        fixture.viewModel.command = "draft a WhatsApp to Mom saying running late"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.errorMessage == AppInteractionFailure.stepNotAllowed("Chat", "Send").userMessage)
        #expect(await app.state.sentMessages.isEmpty)
    }

    /// PR #289 review, F8: a Stop after Sonny typed says the text is still there.
    @Test
    func stoppingAfterTypingSaysTheTextIsStillThere() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Dad"]))
        let fixture = try makeFixture(plan: draftPlan())
        defer { fixture.tearDown() }
        let hangs = TypesThenHangs()
        fixture.viewModel.appInteractionRuntimeOverride = { _ in runtime(app, chooser: hangs) }

        fixture.viewModel.command = "draft a WhatsApp to Mom saying running late"
        fixture.viewModel.start()
        await hangs.waitUntilHanging()
        fixture.viewModel.cancelCurrentRun()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.finalSummary == "Stopped. Anything I typed is still in Chat, unsent.")
        #expect(fixture.viewModel.errorMessage == nil)
    }

    @Test
    func theStepMixedWithAnotherIsRefusedAndTheRuntimeIsNeverBuilt() async throws {
        let mixed = AgentPlan(
            summary: "Open Notes, then draft.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open", operation: .openApp, description: "Open Notes", appName: "Notes"),
                draftPlan().steps[0],
            ]
        )
        let fixture = try makeFixture(plan: mixed)
        defer { fixture.tearDown() }
        var built = false
        fixture.viewModel.appInteractionRuntimeOverride = { _ in
            built = true
            return runtime(FakeChatAppAccessibility(state: FakeChatAppState(chats: [])), chooser: FindAndTypeChooser())
        }

        fixture.viewModel.command = "open Notes and draft a WhatsApp to Mom"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        // Asked before anything runs, so Notes never opens (PR #289 review, F9).
        #expect(!built)
        #expect(fixture.viewModel.clarificationQuestion == AppInteractionCapabilityAdapter.aloneQuestion)
        #expect(fixture.viewModel.errorMessage == nil)
    }
}

// MARK: - Doubles

/// The model's part, played by rules: search if needed, open the target's row, then type the text
/// into the message box once the chat's name is showing.
private struct FindAndTypeChooser: AppInteractionStepChoosing {
    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let target = goal.target ?? ""
        if screen.context.contains(target), let box = screen.candidates.first(where: { $0.kind == "text area" }) {
            return .step(.enterText, ref: box.ref)
        }
        if let row = screen.candidates.first(where: { $0.kind == "row" && $0.label == target }) {
            return .step(.press, ref: row.ref)
        }
        return .giveUp("no row for \(target)")
    }
}

private struct PressesSendChooser: AppInteractionStepChoosing {
    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        guard let send = screen.candidates.first(where: { $0.label == "Send" }) else { return .giveUp("no send") }
        return .step(.press, ref: send.ref)
    }
}

/// Types the name into search, then waits until it is cancelled, signalling when it starts waiting.
private final class TypesThenHangs: AppInteractionStepChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (signal, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func waitUntilHanging() async {
        for await _ in signal { return }
    }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let call = lock.withLock { () -> Int in calls += 1; return calls }
        if call == 1, let search = screen.candidates.first(where: { $0.kind == "search field" }) {
            return .step(.enterTarget, ref: search.ref)
        }
        continuation.yield()
        // A hang backstop, not a bet on a window: only a failure to cancel ever reaches it.
        try await Task.sleep(for: .seconds(3_600))
        return .giveUp("unreachable")
    }
}

private struct ChatAppOnly: AppInteractionAppOpening {
    func resolve(_ name: String) -> InstalledApp? {
        InstalledApp(displayName: "Chat", bundleIdentifier: "com.example.chat", applicationURL: URL(fileURLWithPath: "/Applications/Chat.app"))
    }

    func open(bundleIdentifier: String) async throws -> pid_t { 4242 }
}

private func runtime(_ app: FakeChatAppAccessibility, chooser: any AppInteractionStepChoosing) -> AppInteractionRuntime {
    AppInteractionRuntime(
        accessibility: app,
        chooser: chooser,
        apps: ChatAppOnly(),
        appControl: { _ in .allowed },
        redact: { $0 },
        // The fake chat app stands in for WhatsApp.
        supportedApps: ["com.example.chat"],
        sleep: { _ in }
    )
}

private func draftPlan() -> AgentPlan {
    AgentPlan(
        summary: "Draft to Mom.",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "draft",
                operation: .interactWithApp,
                description: "Draft to Mom",
                appName: "WhatsApp",
                interactionGoal: "Open the chat with Mom and leave the message unsent",
                interactionTarget: "Mom",
                interactionText: "Running late"
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

/// A hang backstop, not a timing assertion: it is reached only when the run never ends.
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
