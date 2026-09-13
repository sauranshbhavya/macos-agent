import Foundation
import MacAgentTestSupport
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
        // the honest answer would be "yes". Power counts as not-Safe — which is the only thing
        // this line needs, and is still true now that Power and Normal differ over the per-app gate:
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
    /// three modes, at every tier that can run.
    ///
    /// Row I is where that bound stopped being theoretical and became the whole design. This
    /// comment used to add "Power's only delta, now and at row I, is which capabilities are gated
    /// on it" — the founder removed even that on 2026-08-14: screen control runs in all three
    /// modes, Power gates nothing, and the consequence rule keeps asking mid-loop in every one of
    /// them.
    @Test
    func destructiveAndAffectsOthersAskInAllThreeModes() {
        for mode in AgentInteractionMode.allCases {
            for tier in CapabilityRiskTier.allCases {
                for classes in [[CapabilityRiskEscalation.Consequence.destructive], [.affectsOthers], [.advisory, .destructive]] {
                    let requirement = RiskApprovalPolicy.default.requirement(
                        for: modeAssessment(tier: tier, classes: classes),
                        context: ApprovalContext(mode: mode, appControl: .notApplicable)
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
                        context: ApprovalContext(mode: mode, appControl: .notApplicable)
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

    /// **The three mode descriptions, pinned on the strings** (SONNY-143 rewrote all of them).
    ///
    /// Each assertion below has a positive half and a negative half, and the negative halves are the
    /// point: they name the exact sentence that was true before row J's per-app gate shipped and is
    /// false after it. A test that only checked the new copy would pass against a build that had
    /// added the new sentence and left the old one beside it.
    @Test
    func everyModeHasDistinctDisplayNameAndOneLineDescription() {
        #expect(AgentInteractionMode.allCases.map(\.displayName) == ["Safe", "Normal", "Power"])
        #expect(Set(AgentInteractionMode.allCases.map(\.settingsDescription)).count == 3)

        // Power stopped being Normal-identical on 2026-08-20: it is the one mode that skips the
        // per-app gate. "Runs exactly like Normal today" is the sentence that became false.
        let power = AgentInteractionMode.power.settingsDescription
        #expect(!power.contains("like Normal today"), "Power is no longer Normal-identical")
        #expect(!power.contains("Reserved for more advanced controls"))
        #expect(power.contains("never asks which apps"))
        // And it must not read as "Power asks nothing" — the consequence rule is untouched, and the
        // copy says so in the same breath for exactly that reason.
        #expect(power.contains("destructive"))

        // Safe asks about apps too now, not only about actions.
        let safe = AgentInteractionMode.safe.settingsDescription
        #expect(safe.contains("before controlling any app"))
        #expect(safe.contains("before every action"))

        // Normal's "asks *only* when an action is destructive" became false the same day: it also
        // asks about an app outside the starter list that the user has not allowed.
        let normal = AgentInteractionMode.normal.settingsDescription
        #expect(!normal.contains("asks only when"), "Normal asks about unknown apps too")
        #expect(normal.contains("has not been allowed to control"))
        #expect(normal.contains("destructive"))
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

    /// Power and Normal answer the same for a tier-0 instant command, which is what this test is
    /// about. **It is no longer true that Power is identical to Normal** — row J made it the one
    /// mode that skips the per-app gate (2026-08-21) — and this command controls no app, so the two
    /// still agree here. The same
    /// tier-0 command that Safe gates runs straight through under BOTH other modes, so selecting
    /// Power changes nothing. Row I did not change that either: this comment used to end "until row
    /// I's screen-control features gate on it", and screen control ended up gated on no mode at all
    /// (founder, 2026-08-14).
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
                // The same roots this fixture hands the view model, so the store answers
                // "is this an output location" against the folders the run really used.
                whitelist: PathWhitelist(roots: [root])
            ),
            resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
            pendingServerDeletionStore: PendingServerDeletionStore(
                fileURL: root.appendingPathComponent("pending-server-deletions.json")
            ),
            skillSelectionStore: SkillSelectionStore(
                fileURL: root.appendingPathComponent("added-skills.json")
            ),
            standingWatcherObserver: UnreachableStandingWatcherObserver(),
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
            makePlanner: { _, _ in UnreachablePlanner() },
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
/// The 30 seconds is a deadlock backstop, not a timing assertion (SONNY-159/160/161): this target is
/// `@MainActor` and Swift Testing interleaves its suites on one actor, so the previous 2 s fired when a
/// neighbouring test was busy rather than when anything was wrong. Full reasoning and the measurements
/// are on `VisionSessionRunTests.hangBackstop`.
@MainActor
private func waitForQuiescence(_ viewModel: AgentViewModel, timeout: TimeInterval = 30) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not settle before timeout. Waited 30s, which at this length means genuinely stuck rather than merely busy — treat it as a real failure.")
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
