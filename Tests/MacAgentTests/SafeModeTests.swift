import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// SONNY-90: the Safe-mode setting, its persistence, the data-leaves-device label's relocation
/// into it (E9's founder-ratified §11.3 deviation), and Safe mode driven through the REAL
/// dispatch path — the mapping-level cross-product pins live in ConsequenceRuleTests; these are
/// the product-wiring halves those pins cannot see.
@Suite(.serialized)
@MainActor
struct SafeModeTests {
    // MARK: - Persistence

    @Test
    func safeModeDefaultsOffForANewUser() throws {
        let fixture = try makeSafeModeFixture()
        defer { fixture.tearDown() }

        #expect(!fixture.viewModel.safeModeEnabled)
    }

    @Test
    func safeModePersistsAcrossViewModelInstances() throws {
        let fixture = try makeSafeModeFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.safeModeEnabled = true

        // A fresh instance over the same defaults suite is a relaunch as far as the setting is
        // concerned — a caution dial that silently reset to Normal on restart would be a caution
        // dial that quietly un-dials itself.
        let relaunched = try fixture.makeSiblingViewModel()
        #expect(relaunched.safeModeEnabled)

        relaunched.safeModeEnabled = false
        let third = try fixture.makeSiblingViewModel()
        #expect(!third.safeModeEnabled)
    }

    // MARK: - The label's relocation, both directions

    @Test
    func normalModeDisclosureCarriesNoDataEgressLine() {
        let request = makeApprovalRequest(dataLeavesDevice: true)

        let lines = AgentActivityPresentation.approvalDisclosureLines(for: request, safeModeEnabled: false)

        // E9 (founder-ratified 2026-08-08; C7 2026-08-12): §11.3's "Data leaves device" line is
        // consciously removed from every normal approval surface — even, and especially, when
        // the honest answer would be "yes".
        #expect(!lines.joined(separator: "\n").contains("Data leaves device"))
        #expect(lines.count == 4)
    }

    @Test
    func safeModeDisclosureRestoresTheDataEgressLine() {
        let request = makeApprovalRequest(dataLeavesDevice: true)

        let lines = AgentActivityPresentation.approvalDisclosureLines(for: request, safeModeEnabled: true)

        #expect(lines.contains("Data leaves device: yes"))
        #expect(lines.count == 5)
    }

    @Test
    func widgetDataEgressCaptionExistsOnlyUnderSafeMode() {
        let leaves = makeApprovalRequest(dataLeavesDevice: true)
        let stays = makeApprovalRequest(dataLeavesDevice: false)

        #expect(AgentActivityPresentation.widgetDataEgressLine(for: leaves, safeModeEnabled: false) == nil)
        #expect(AgentActivityPresentation.widgetDataEgressLine(for: stays, safeModeEnabled: false) == nil)
        #expect(AgentActivityPresentation.widgetDataEgressLine(for: leaves, safeModeEnabled: true)
            == "Data leaves device: yes")
        #expect(AgentActivityPresentation.widgetDataEgressLine(for: stays, safeModeEnabled: true)
            == "Data leaves device: no")
    }

    // MARK: - Safe mode through the real dispatch path

    /// E9's words, driven end to end: "asks before every action ... across all tasks" includes
    /// the instant resolver's tier-0 calculator — the least dangerous task the app can run.
    @Test
    func safeModeMakesEvenATierZeroInstantCommandAsk() async throws {
        let fixture = try makeSafeModeFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.safeModeEnabled = true

        fixture.viewModel.command = "2 + 2"
        fixture.viewModel.start()
        try await waitForQuiescence(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        #expect(fixture.viewModel.finalSummary.contains("4") == false)

        // Answering the ask is all it takes — Safe mode is friction, never a lockout.
        fixture.viewModel.start()
        try await waitForQuiescence(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.finalSummary.contains("4"))
    }

    /// The attended half of the trust-versus-Safe-mode question: a routine the user marked
    /// trusted auto-runs manually in Normal mode (SONNY-54), and Safe mode gates exactly that
    /// shortcut — the global caution dial outranks the per-routine convenience grant while the
    /// user is present to answer. (The unattended half — scheduled runs unaffected — is pinned
    /// in ScheduledRoutineRunTests.)
    @Test
    func safeModeGatesTheTrustedRoutineManualRunShortcut() async throws {
        let fixture = try makeSafeModeFixture()
        defer { fixture.tearDown() }
        try fixture.saveTrustedCalculatorRoutine(named: "Morning Math")

        // Normal mode first: the trust shortcut auto-runs the manual dispatch.
        fixture.viewModel.command = "Run my Morning Math routine"
        fixture.viewModel.start()
        try await waitForQuiescence(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(fixture.viewModel.errorMessage == nil)

        // Same dispatch under Safe mode: it asks.
        fixture.viewModel.safeModeEnabled = true
        fixture.viewModel.command = "Run my Morning Math routine"
        fixture.viewModel.start()
        try await waitForQuiescence(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
    }
}

// MARK: - Fixture

@MainActor
private struct SafeModeFixture {
    let viewModel: AgentViewModel
    let root: URL
    let routineStore: RoutineStore
    let defaultsSuiteName: String
    private let build: () throws -> AgentViewModel

    init(
        viewModel: AgentViewModel,
        root: URL,
        routineStore: RoutineStore,
        defaultsSuiteName: String,
        build: @escaping () throws -> AgentViewModel
    ) {
        self.viewModel = viewModel
        self.root = root
        self.routineStore = routineStore
        self.defaultsSuiteName = defaultsSuiteName
        self.build = build
    }

    func makeSiblingViewModel() throws -> AgentViewModel {
        try build()
    }

    func saveTrustedCalculatorRoutine(named name: String) throws {
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, unattendedTrusted: true)
        schedule.setEnabled(false, now: Date(timeIntervalSince1970: 0))
        try routineStore.save(
            StoredRoutine(
                name: name,
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

    func tearDown() {
        UserDefaults(suiteName: defaultsSuiteName)?.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeSafeModeFixture() throws -> SafeModeFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SafeModeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "SafeModeTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
    let build: @MainActor () throws -> AgentViewModel = {
        AgentViewModel(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
            shortcutCatalog: EmptySafeModeShortcutCatalog(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-run-history.json")
            ),
            taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
            clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            ),
            localDataDeletionService: LocalDataDeletionService(fileURLs: []),
            priorTaskContextStore: PriorTaskContextStore(),
            taskUsageRecorder: TaskUsageRecorder(),
            plannerProviderRegistry: PlannerProviderRegistry(
                defaultProvider: PlannerProvider(id: "unused-stub", displayName: "Unused Stub") { _ in
                    UnreachablePlanner()
                }
            ),
            plannerSelection: nil,
            userDefaults: userDefaults,
            whitelist: PathWhitelist(roots: [root])
        )
    }
    return SafeModeFixture(
        viewModel: try build(),
        root: root,
        routineStore: routineStore,
        defaultsSuiteName: suiteName,
        build: build
    )
}

/// Waits until the run is neither executing nor mid-transition — an approval pause counts as
/// quiescent (isRunning is false while a request waits).
@MainActor
private func waitForQuiescence(_ viewModel: AgentViewModel, timeout: TimeInterval = 2) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not settle before timeout.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Every command these tests dispatch resolves locally; a planner call would be a test bug.
private struct UnreachablePlanner: Planning {
    struct ReachedThePlanner: Error {}

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw ReachedThePlanner()
    }
}

private struct EmptySafeModeShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

private func makeApprovalRequest(dataLeavesDevice: Bool) -> RiskApprovalRequest {
    RiskApprovalRequest(
        assessment: CapabilityRiskAssessment(
            defaultTier: .tier2,
            approvalCopy: RiskApprovalCopy(
                actionDescription: "Save a research note",
                riskReason: "This writes a new file",
                involvedResource: "/Users/test/Desktop/note.md",
                dataLeavesDevice: dataLeavesDevice,
                undoDescription: "Delete the note"
            )
        ),
        requirement: .explicitApproval
    )
}
