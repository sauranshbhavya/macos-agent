import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// SONNY-90 as amended 2026-08-14: the Safe | Normal | Power interaction mode — its tri-state
/// persistence, its mapping onto the engine's boolean Safe-mode seam, the data-leaves-device
/// label's relocation into Safe mode alone (E9's founder-ratified §11.3 deviation, with Power
/// explicitly excluded), Power's identical-to-Normal-today contract, and the mode driven through
/// the REAL dispatch path — the mapping-level cross-product pins live in ConsequenceRuleTests;
/// these are the product-wiring halves those pins cannot see.
@Suite(.serialized)
@MainActor
struct InteractionModeTests {
    // MARK: - Persistence

    @Test
    func modeDefaultsToNormalForANewUser() throws {
        let fixture = try makeModeFixture()
        defer { fixture.tearDown() }

        #expect(fixture.viewModel.interactionMode == .normal)
    }

    @Test
    func everyModePersistsAcrossViewModelInstances() throws {
        let fixture = try makeModeFixture()
        defer { fixture.tearDown() }

        // A fresh instance over the same defaults suite is a relaunch as far as the setting is
        // concerned — a posture dial that silently reset on restart would quietly un-dial
        // itself. All three positions round-trip.
        for mode in AgentInteractionMode.allCases {
            fixture.viewModel.interactionMode = mode
            let relaunched = try fixture.makeSiblingViewModel()
            #expect(relaunched.interactionMode == mode, "\(mode) did not survive the relaunch")
        }
    }

    @Test
    func anUnrecognizedPersistedValueFallsToNormal() throws {
        let fixture = try makeModeFixture()
        defer { fixture.tearDown() }

        fixture.userDefaults.set("turbo", forKey: "com.sonny.preferences.interactionMode")
        let relaunched = try fixture.makeSiblingViewModel()
        #expect(relaunched.interactionMode == .normal)
    }

    // MARK: - The label's relocation, all three modes

    @Test
    func onlySafeModeDisclosureCarriesTheDataEgressLine() {
        let request = makeApprovalRequest(dataLeavesDevice: true)

        // E9 (founder-ratified 2026-08-08; C7 2026-08-12): §11.3's "Data leaves device" line is
        // consciously removed from every non-Safe approval surface — even, and especially, when
        // the honest answer would be "yes". Power counts as not-Safe: identical to Normal today,
        // and it must not leak the Safe-only label.
        for mode in AgentInteractionMode.allCases {
            let lines = AgentActivityPresentation.approvalDisclosureLines(
                for: request,
                safeMode: mode == .safe
            )
            if mode == .safe {
                #expect(lines.contains("Data leaves device: yes"))
                #expect(lines.count == 5)
            } else {
                #expect(!lines.joined(separator: "\n").contains("Data leaves device"), "\(mode)")
                #expect(lines.count == 4, "\(mode)")
            }
        }
    }

    @Test
    func theWidgetDataEgressCaptionExistsOnlyUnderSafeMode() {
        let leaves = makeApprovalRequest(dataLeavesDevice: true)
        let stays = makeApprovalRequest(dataLeavesDevice: false)

        for mode in AgentInteractionMode.allCases where mode != .safe {
            #expect(AgentActivityPresentation.widgetDataEgressLine(for: leaves, safeMode: mode == .safe) == nil, "\(mode)")
            #expect(AgentActivityPresentation.widgetDataEgressLine(for: stays, safeMode: mode == .safe) == nil, "\(mode)")
        }
        #expect(AgentActivityPresentation.widgetDataEgressLine(for: leaves, safeMode: true)
            == "Data leaves device: yes")
        #expect(AgentActivityPresentation.widgetDataEgressLine(for: stays, safeMode: true)
            == "Data leaves device: no")
    }

    // MARK: - The engine mapping and the settings copy

    /// The one product-to-engine mapping: Safe asks before everything; Normal and Power both run
    /// the consequence rule. Exhaustive over the enum so a fourth mode cannot land unmapped in
    /// the tests even after someone answers the enum's own exhaustive switches.
    @Test
    func onlySafeMapsToTheEngineAskEverythingPosture() {
        for mode in AgentInteractionMode.allCases {
            #expect(mode.asksBeforeEveryAction == (mode == .safe), "\(mode)")
        }
    }

    /// The coordinator's bound on Power, final (PR #49 addendum N3): Power NEVER changes the ask
    /// posture. An assessment carrying a destructive or affects-others escalation asks in all
    /// three modes, at every tier that can run — Power's only delta, now and at row I, is which
    /// capabilities are gated on it, never whether consequences ask.
    @Test
    func destructiveAndAffectsOthersAskInAllThreeModes() {
        for mode in AgentInteractionMode.allCases {
            for tier in CapabilityRiskTier.allCases {
                for classes in [[CapabilityRiskEscalation.Consequence.destructive], [.affectsOthers], [.advisory, .destructive]] {
                    let requirement = RiskApprovalPolicy.default.requirement(
                        for: modeAssessment(tier: tier, classes: classes),
                        context: ApprovalContext(safeMode: mode.asksBeforeEveryAction)
                    )
                    #expect(
                        requirement != .autoRun && requirement != .lightweightConfirmation,
                        "\(mode), tier \(tier), classes \(classes): \(requirement)"
                    )
                }
            }
        }
    }

    /// P1 restated over the whole tri-state, cell by cell: for every tier and class combination,
    /// Safe is never more permissive than Normal, and Normal and Power produce the identical
    /// requirement — the engine cannot tell them apart, which is exactly Power's contract today.
    @Test
    func safeIsNeverMorePermissiveAndPowerIsNormalCellByCell() {
        let combos: [[CapabilityRiskEscalation.Consequence]] = [
            [], [.advisory], [.advisory, .advisory], [.destructive], [.affectsOthers],
            [.advisory, .destructive], [.advisory, .affectsOthers]
        ]
        for tier in CapabilityRiskTier.allCases {
            for classes in combos {
                let assessment = modeAssessment(tier: tier, classes: classes)
                let byMode = Dictionary(uniqueKeysWithValues: AgentInteractionMode.allCases.map { mode in
                    (mode, RiskApprovalPolicy.default.requirement(
                        for: assessment,
                        context: ApprovalContext(safeMode: mode.asksBeforeEveryAction)
                    ))
                })
                #expect(byMode[.normal] == byMode[.power], "tier \(tier), classes \(classes)")
                #expect(
                    byMode[.safe]!.permissivenessRank <= byMode[.normal]!.permissivenessRank,
                    "tier \(tier), classes \(classes): safe \(byMode[.safe]!) vs normal \(byMode[.normal]!)"
                )
            }
        }
    }

    @Test
    func everyModeHasDistinctDisplayNameAndOneLineDescription() {
        #expect(AgentInteractionMode.allCases.map(\.displayName) == ["Safe", "Normal", "Power"])
        #expect(Set(AgentInteractionMode.allCases.map(\.settingsDescription)).count == 3)
        // Power's line must state the identical-today truth, not imply new behavior.
        #expect(AgentInteractionMode.power.settingsDescription.contains("like Normal today"))
    }

    // MARK: - The modes through the real dispatch path

    /// E9's words, driven end to end: "asks before every action ... across all tasks" includes
    /// the instant resolver's tier-0 calculator — the least dangerous task the app can run.
    @Test
    func safeModeMakesEvenATierZeroInstantCommandAsk() async throws {
        let fixture = try makeModeFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.interactionMode = .safe

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

    /// Power is identical to Normal today — row 18's mode landing as a setting first. The same
    /// tier-0 command that Safe gates runs straight through under BOTH other modes, so selecting
    /// Power changes nothing until row I's screen-control features gate on it.
    @Test
    func normalAndPowerRunTheSameCommandWithoutAsking() async throws {
        for mode in [AgentInteractionMode.normal, .power] {
            let fixture = try makeModeFixture()
            defer { fixture.tearDown() }
            fixture.viewModel.interactionMode = mode

            fixture.viewModel.command = "2 + 2"
            fixture.viewModel.start()
            try await waitForQuiescence(fixture.viewModel)

            #expect(fixture.viewModel.approvalRequest == nil, "\(mode)")
            #expect(fixture.viewModel.finalSummary.contains("4"), "\(mode)")
        }
    }

    /// The attended half of the trust-versus-Safe-mode question: a routine the user marked
    /// trusted auto-runs manually in Normal AND Power (SONNY-54), and Safe mode gates exactly
    /// that shortcut — the global caution dial outranks the per-routine convenience grant while
    /// the user is present to answer. (The unattended half — scheduled runs unaffected — is
    /// pinned in ScheduledRoutineRunTests.)
    @Test
    func safeModeGatesTheTrustedRoutineManualRunShortcut() async throws {
        let fixture = try makeModeFixture()
        defer { fixture.tearDown() }
        try fixture.saveTrustedCalculatorRoutine(named: "Morning Math")

        // Normal first, then Power: the trust shortcut auto-runs the manual dispatch in both.
        for mode in [AgentInteractionMode.normal, .power] {
            fixture.viewModel.interactionMode = mode
            fixture.viewModel.command = "Run my Morning Math routine"
            fixture.viewModel.start()
            try await waitForQuiescence(fixture.viewModel)
            #expect(fixture.viewModel.approvalRequest == nil, "\(mode)")
            #expect(fixture.viewModel.errorMessage == nil, "\(mode)")
        }

        // Same dispatch under Safe mode: it asks.
        fixture.viewModel.interactionMode = .safe
        fixture.viewModel.command = "Run my Morning Math routine"
        fixture.viewModel.start()
        try await waitForQuiescence(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
    }
}

// MARK: - Fixture

@MainActor
private struct ModeFixture {
    let viewModel: AgentViewModel
    let root: URL
    let routineStore: RoutineStore
    let userDefaults: UserDefaults
    let defaultsSuiteName: String
    private let build: () throws -> AgentViewModel

    init(
        viewModel: AgentViewModel,
        root: URL,
        routineStore: RoutineStore,
        userDefaults: UserDefaults,
        defaultsSuiteName: String,
        build: @escaping () throws -> AgentViewModel
    ) {
        self.viewModel = viewModel
        self.root = root
        self.routineStore = routineStore
        self.userDefaults = userDefaults
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
private func makeModeFixture() throws -> ModeFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("InteractionModeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let suiteName = "InteractionModeTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
    let build: @MainActor () throws -> AgentViewModel = {
        AgentViewModel(
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
            shortcutCatalog: EmptyModeShortcutCatalog(),
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
    return ModeFixture(
        viewModel: try build(),
        root: root,
        routineStore: routineStore,
        userDefaults: userDefaults,
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

private struct EmptyModeShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] { [] }
}

private func modeAssessment(
    tier: CapabilityRiskTier,
    classes: [CapabilityRiskEscalation.Consequence]
) -> CapabilityRiskAssessment {
    CapabilityRiskAssessment(
        defaultTier: tier,
        effectiveTier: tier,
        escalations: classes.enumerated().map { index, consequence in
            CapabilityRiskEscalation(
                fromTier: tier,
                toTier: tier,
                reason: "Mode-grid escalation \(index).",
                consequence: consequence
            )
        }
    )
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
