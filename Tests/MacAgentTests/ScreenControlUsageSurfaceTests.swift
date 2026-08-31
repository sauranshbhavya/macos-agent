import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// **"X runs left", and the one condition it is shown under** (SONNY-214).
///
/// The ticket's second half is a single rule — the figure appears when a *screen-control* task is
/// about to run and never on an ordinary free one — so the tests that matter here drive both kinds
/// of task down the same path, with the same allowance in hand, and read the same property. Anything
/// weaker proves the number can be rendered, which was never in doubt; what is in doubt is whether a
/// free task can render it too.
///
/// **Both runs stop at a Safe-mode approval, and that is deliberate rather than convenient.** Safe
/// mode floors every tier to `.explicitApproval` (`RiskApprovalPolicy.safeModeFloor`), so a
/// calculation and a screen-control session pause in the *identical* state — plan prepared, approval
/// outstanding, nothing executing — and the only difference left between the two cases is the one
/// the rule is about. It is also the literal moment the ticket names: a run about to start, waiting
/// on the person who will start it.
@Suite
@MainActor
struct ScreenControlUsageSurfaceTests {
    // MARK: - The gate, in both directions

    @Test
    func theRunsLeftFigureShowsForAScreenControlRunAndNotForAFreeOne() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 12, runsIncluded: 20)

        await fixture.viewModel.refreshScreenControlAllowance()
        // The figure is in hand for *both* halves below, which is what makes the second half a test
        // of the gate rather than of a failed read.
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 12)

        // A screen-control run, about to start.
        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()

        #expect(fixture.viewModel.isScreenControlTaskInFlight)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == 12)

        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()

        // The same allowance, the same surface, an ordinary free task.
        fixture.viewModel.command = "what is 2 + 2"
        fixture.viewModel.start(prebuiltPlan: Self.freePlan)
        try await fixture.waitForApproval()

        #expect(fixture.viewModel.isScreenControlTaskInFlight == false)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
        // And the figure really is still there to be shown, so the `nil` above is the gate's answer
        // and not a read that expired between the two halves.
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 12)
    }

    @Test
    func aScreenControlRunWhoseReadFailedShowsNoFigureRatherThanAFabricatedOne() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.backend.register { _ in .failure(URLError(.notConnectedToInternet)) }

        await fixture.viewModel.refreshScreenControlAllowance()
        #expect(fixture.viewModel.screenControlAllowance == nil)

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()

        // The run is a screen-control run — the half of the gate that holds — and the line is still
        // absent, because there is no number. `ScreenControlAllowanceService` states why no fallback
        // figure exists: zero locks a user out of what they paid for and any positive number
        // promises runs the server never granted.
        #expect(fixture.viewModel.isScreenControlTaskInFlight)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
    }

    @Test
    func aFigureThatWasReadDoesNotOutliveTheRunItWasShownBeside() async throws {
        let fixture = try makeUsageFixture()
        defer { fixture.tearDown() }
        fixture.serveCredits(runsLeft: 3, runsIncluded: 20)
        await fixture.viewModel.refreshScreenControlAllowance()

        fixture.viewModel.command = "open my reading list in Safari"
        fixture.viewModel.start(prebuiltPlan: Self.screenControlPlan, prebuiltPlanSource: .visionSession)
        try await fixture.waitForApproval()
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == 3)

        fixture.viewModel.cancelCurrentRun()
        try await fixture.waitForIdle()

        // Nothing is in flight, so nothing is shown — the widget's result and idle panels do not
        // inherit the line from the run that has just ended. The allowance itself is untouched,
        // because Command Center goes on showing it.
        #expect(fixture.viewModel.isScreenControlTaskInFlight == false)
        #expect(fixture.viewModel.screenControlRunsLeftForTaskInFlight == nil)
        #expect(try #require(fixture.viewModel.screenControlAllowance).runsLeft == 3)
    }

    // MARK: - The two sentences

    @Test
    func theInTaskLineIsTheNumberAndNothingElse() {
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 12) == "12 runs left")
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 1) == "1 run left")
        #expect(ScreenControlUsagePresentation.inTaskLine(runsLeft: 0) == "0 runs left")
    }

    @Test
    func theUsageLineCarriesTheDenominatorAndThePeriod() {
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 12)) == "12 of 20 runs left this month")
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 1)) == "1 of 20 runs left this month")
        #expect(ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 0)) == "0 of 20 runs left this month")
    }

    /// **The standing rule, held by value** (`CLAUDE.md`: no explanatory or how-it-works copy in the
    /// product). Both sentences are read immediately above; this is the enumeration that a *third*
    /// clause cannot be appended to either of them without a test going red, which is the failure
    /// mode the rule exists for — nobody adds an explanation on purpose, they add it as a helpful
    /// half-sentence on the end of a line that already worked.
    @Test
    func neitherSentenceExplainsAnything() {
        let sentences = [
            ScreenControlUsagePresentation.inTaskLine(runsLeft: 12),
            ScreenControlUsagePresentation.usageLine(Self.allowance(runsLeft: 12))
        ]
        for sentence in sentences {
            #expect(sentence.split(separator: ".").count == 1, "\(sentence) carries a second sentence")
            for word in ["because", "each", "counts", "when you", "screen control uses", "will be"] {
                #expect(!sentence.lowercased().contains(word), "\(sentence) explains itself: \(word)")
            }
        }
    }

    // MARK: - Both surfaces are actually wired to the gate

    /// The widget renders the figure through the one property that carries the rule, and gates it on
    /// nothing else of its own.
    ///
    /// A source scan because this repository has no SwiftUI inspection harness — see
    /// `MacAgentSource` for what that is worth and what it is not. Sliced to the panel's own
    /// container so a match somewhere else in a 2,300-line file cannot stand in for this one.
    @Test
    func theWidgetShowsTheFigureThroughTheGateAndRefreshesWhenAScreenControlRunBegins() throws {
        let source = try MacAgentSource.read("FloatingWidgetView.swift")
        let panel = try MacAgentSource.braceBlock(of: source, openedBy: "private var styledPanel: some View {")
        #expect(MacAgentSource.count(of: "viewModel.screenControlRunsLeftForTaskInFlight", inText: panel) == 1)
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.inTaskLine(", inText: panel) == 1)
        // The Command Center line's denominator form must not leak onto the widget, which is the
        // one way these two surfaces could come to say the same thing in the wrong place.
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.usageLine(", inText: panel) == 0)

        // And the read that fills it is triggered by the run, not by a timer and not at launch.
        let trigger = try MacAgentSource.braceBlock(
            of: source,
            openedBy: ".onChange(of: viewModel.isScreenControlTaskInFlight) {"
        )
        #expect(MacAgentSource.count(of: "viewModel.refreshScreenControlAllowance()", inText: trigger) == 1)
        #expect(MacAgentSource.count(of: "refreshScreenControlAllowance", inText: source) == 1)
    }

    /// Command Center's stats area renders the row, and Insights is the page that asks for the
    /// figure.
    @Test
    func commandCenterShowsTheUsageRowInTheStatsAreaAndAsksForTheFigureThere() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let bento = try MacAgentSource.braceBlock(of: source, openedBy: "private struct InsightsOverviewBento: View {")
        #expect(MacAgentSource.count(of: "ScreenControlUsageRow(allowance:", inText: bento) == 1)

        let row = try MacAgentSource.braceBlock(of: source, openedBy: "private struct ScreenControlUsageRow: View {")
        #expect(MacAgentSource.count(of: "ScreenControlUsagePresentation.usageLine(allowance)", inText: row) == 1)
        // System A, and only System A — the widget's tokens have no business on this page.
        #expect(MacAgentSource.count(of: "WidgetTheme.", inText: row) == 0)
        #expect(MacAgentSource.count(of: "WidgetType.", inText: row) == 0)

        #expect(MacAgentSource.count(of: "refreshScreenControlAllowance", inText: source) == 1)
    }

    // MARK: - Fixtures

    static let screenControlPlan = AgentPlan(
        summary: "Control Safari: open my reading list",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "vision-1",
                operation: .visionSession,
                description: "Control Safari to open my reading list",
                appName: "Safari",
                visionGoal: "open my reading list"
            )
        ]
    )

    static let freePlan = AgentPlan(
        summary: "Add two and two",
        requiresConfirmation: false,
        steps: [
            AgentStep(id: "calc", operation: .calculateUtility, description: "Calculate 2 + 2.", searchQuery: "2 + 2")
        ]
    )

    static func allowance(runsLeft: Int, runsIncluded: Int = 20) -> ScreenControlAllowance {
        ScreenControlAllowance(
            plan: "test-plan-a",
            runsLeft: runsLeft,
            runsIncluded: runsIncluded,
            periodStart: Date(timeIntervalSince1970: 1_753_920_000),
            periodEnd: Date(timeIntervalSince1970: 1_756_598_400)
        )
    }
}

@MainActor
private struct UsageFixture {
    let viewModel: AgentViewModel
    let backend: SignedInBackendFixture
    let root: URL
    let defaultsSuiteName: String

    /// The gateway's own body shape, field for field — `ScreenControlAllowanceTests` in the core
    /// target carries the same one, and contract §5.4 is where it comes from.
    func serveCredits(runsLeft: Int, runsIncluded: Int) {
        backend.register { _ in
            .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "plan": "test-plan-a",
                    "period_start": "2026-08-01T00:00:00.000Z",
                    "period_end": "2026-09-01T00:00:00.000Z",
                    "screen_control_runs_left": runsLeft,
                    "screen_control_runs_included": runsIncluded,
                    "credits": ["allowance": 200, "drawn": 80, "remaining": 120, "per_run": 10]
                ])
            )
        }
    }

    /// Waits for the run to park on its approval. The assertions that follow every call read
    /// concrete values, so a wait that gave up leaves a failing value expectation rather than a
    /// timeout standing in for one.
    func waitForApproval(timeout: TimeInterval = 30) async throws {
        try await wait(timeout: timeout) { viewModel.isAwaitingApproval }
    }

    func waitForIdle(timeout: TimeInterval = 30) async throws {
        try await wait(timeout: timeout) { !viewModel.isRunning && !viewModel.isAwaitingApproval }
    }

    private func wait(timeout: TimeInterval, until condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition() {
            if Date() > deadline {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func tearDown() {
        backend.unregister()
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

/// Safe mode throughout, for the reason the suite's own doc gives: it is what puts a free task and a
/// screen-control task into the same pause, so the only difference the gate can be reading is the
/// one it claims to read.
@MainActor
private func makeUsageFixture() throws -> UsageFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreenControlUsageSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "ScreenControlUsageSurfaceTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let backend = SignedInBackendFixture()
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: NoUsageShortcuts(),
        finderRevealer: hermeticFinderRevealer,
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
            whitelist: PathWhitelist(roots: [root])
        ),
        resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: HermeticPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings-monitor.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // The signed-in stub client, because this suite's subject is a figure read over the wire.
        backendClient: backend.client,
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        // Every run here carries a pre-built plan, so reaching a planner would be a test bug.
        makePlanner: { _, _ in UnreachableUsagePlanner() },
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    viewModel.interactionMode = .safe
    return UsageFixture(viewModel: viewModel, backend: backend, root: root, defaultsSuiteName: suiteName)
}

private struct UnreachableUsagePlanner: Planning {
    struct ReachedThePlanner: Error {}

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw ReachedThePlanner()
    }
}

private struct NoUsageShortcuts: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}
