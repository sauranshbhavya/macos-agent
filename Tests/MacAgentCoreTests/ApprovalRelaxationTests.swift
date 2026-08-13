import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-97 (row C): the relaxation-eligibility mechanism.
///
/// Eligibility is the fail-closed containment for the grants the requirement mapping applies —
/// most load-bearingly for the origin grant, which bypasses the scope machinery entirely. What is
/// pinned here: the static per-operation classification as a written table, the plan roll-up as an
/// intersection across every step, and the rule that an adapter may narrow its own eligibility and
/// can never widen it.
@Suite
@MainActor
struct ApprovalRelaxationTests {
    // MARK: - The static classification, as a written table

    /// Every operation's classification, written out — not derived. A new `AgentOperation` case
    /// fails this test until someone classifies it here *and* in
    /// `OperationRelaxation.relaxation(for:)`, which is the compile-plus-test pincer the
    /// no-`default:` rule exists for.
    ///
    /// The two empty rows are founder decisions, not gaps: `.runRoutine` because SONNY-54 made the
    /// per-routine trust toggle the *single* door for skipping a routine's tier-2 prompt, and
    /// `.invokeShortcut` because a Shortcut's internals are invisible — belt-and-braces on the
    /// verdict axis (already `.opaque`), load-bearing on the origin axis, which never consults the
    /// verdict. `.editWorkspace` is the sole `byDirectUserOrigin` carrier: the one operation a
    /// screen builds field by field today.
    @Test
    func everyOperationsClassificationMatchesTheWrittenTable() {
        let table: [AgentOperation: OperationRelaxation] = [
            .scanSelectLargestFiles: [.byWorkspaceScope],
            .createZip: [.byWorkspaceScope],
            .scanDocx: [.byWorkspaceScope],
            .convertDocxToPDF: [.byWorkspaceScope],
            .openHackerNews: [.byWorkspaceScope],
            .fetchHNHeadlines: [.byWorkspaceScope],
            .writeMarkdown: [.byWorkspaceScope],
            .webToMarkdown: [.byWorkspaceScope],
            .openApp: [.byWorkspaceScope],
            .openAppSearchURL: [.byWorkspaceScope],
            .openURL: [.byWorkspaceScope],
            .playMedia: [.byWorkspaceScope],
            .getFinderSelection: [.byWorkspaceScope],
            .revealInFinder: [.byWorkspaceScope],
            .showPermissionReadiness: [.byWorkspaceScope],
            .saveRoutine: [.byWorkspaceScope],
            .runRoutine: [],
            .createWorkspace: [.byWorkspaceScope],
            .editWorkspace: [.byWorkspaceScope, .byDirectUserOrigin],
            .openWorkspace: [.byWorkspaceScope],
            .openGeneratedArtifact: [.byWorkspaceScope],
            .createLocalDraft: [.byWorkspaceScope],
            .calculateUtility: [.byWorkspaceScope],
            .lookupClipboardHistory: [.byWorkspaceScope],
            .expandSnippet: [.byWorkspaceScope],
            .saveSnippet: [.byWorkspaceScope],
            .switchRunningApp: [.byWorkspaceScope],
            .lookupRecentArtifacts: [.byWorkspaceScope],
            .invokeShortcut: [],
            .clarify: [.byWorkspaceScope],
            .unsupported: [.byWorkspaceScope]
        ]

        for operation in AgentOperation.allCases {
            let expected = table[operation]
            #expect(expected != nil, "\(operation) is not classified in this test's table.")
            #expect(
                OperationRelaxation.relaxation(for: operation) == expected,
                "\(operation) classifies as \(OperationRelaxation.relaxation(for: operation)), table says \(String(describing: expected))."
            )
        }
        #expect(table.count == AgentOperation.allCases.count)
    }

    // MARK: - The plan roll-up

    @Test
    func aSingleStepPlanRollsUpItsOperationsOwnClassification() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let assessment = try makeExecutor(root: root).assessRisk(plan: openAppPlan(), scope: .unscoped)

        #expect(assessment.relaxationEligibility == [.byWorkspaceScope])
    }

    @Test
    func aWorkspaceEditPlanAloneCarriesBothEligibilityBits() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Slack",
                action: .add
            )
        )
        let assessment = try makeExecutor(root: root, workspaceStore: workspaceStore)
            .assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.relaxationEligibility == [.byWorkspaceScope, .byDirectUserOrigin])
    }

    /// The roll-up is an intersection across every step, so mixing a workspace edit with any other
    /// operation drops `byDirectUserOrigin` for the whole plan — the chain shape SONNY-97's
    /// acceptance criteria name, demonstrated at the eligibility layer.
    @Test
    func aChainMixingAWorkspaceEditWithAnotherOperationLosesTheOriginBit() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))

        let edit = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Slack",
                action: .add
            )
        )
        let chain = AgentPlan(
            summary: "Edit the workspace, then open Safari.",
            requiresConfirmation: true,
            steps: edit.steps + openAppPlan().steps
        )
        let assessment = try makeExecutor(root: root, workspaceStore: workspaceStore)
            .assessRisk(plan: chain, scope: .unscoped)

        #expect(assessment.relaxationEligibility == [.byWorkspaceScope])
    }

    /// A plan containing `run_routine` rolls up to no eligibility at all: the routine's own trust
    /// toggle stays the single door (SONNY-54), and the intersection makes that hold for the whole
    /// plan, not just the routine step.
    @Test
    func aPlanContainingARoutineRollsUpToNoEligibilityAtAll() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Morning Setup", steps: openAppPlan().steps))

        let assessment = try makeExecutor(root: root, routineStore: routineStore).assessRisk(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning Setup"),
            scope: .unscoped
        )

        #expect(assessment.relaxationEligibility == [])
    }

    @Test
    func aPlanContainingAShortcutRollsUpToNoEligibilityAtAll() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let plan = AgentPlan(
            summary: "Invoke the Morning Report shortcut.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "invoke",
                    operation: .invokeShortcut,
                    description: "Invoke the Morning Report shortcut.",
                    shortcutName: "Morning Report"
                )
            ]
        )
        let assessment = try makeExecutor(root: root).assessRisk(plan: plan, scope: .unscoped)

        #expect(assessment.relaxationEligibility == [])
    }

    // MARK: - Adapter narrowing

    /// An adapter may narrow its own assessment's eligibility, and the executor's fold honours it —
    /// the mechanism SONNY-98's boundary-changing-edit rule is built on.
    @Test
    func anAdapterDeclaredNarrowingIsHonouredByTheFold() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try CapabilityRegistry(
            adapters: [FixedEligibilityAdapter(declared: [])]
        )

        let assessment = try makeExecutor(root: root, capabilityRegistry: registry)
            .assessRisk(plan: openAppPlan(), scope: .unscoped)

        #expect(assessment.relaxationEligibility == [])
    }

    /// The other direction cannot exist: the fold is an intersection, so an adapter declaring more
    /// than the static classification allows changes nothing. Without this test, the narrowing test
    /// above would pass just as happily against a fold that simply *replaced* the static answer
    /// with the adapter's.
    @Test
    func anAdapterCannotWidenEligibilityPastTheStaticClassification() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try CapabilityRegistry(
            adapters: [FixedEligibilityAdapter(declared: .all)]
        )

        let assessment = try makeExecutor(root: root, capabilityRegistry: registry)
            .assessRisk(plan: openAppPlan(), scope: .unscoped)

        // `.openApp` statically carries `byWorkspaceScope` alone; the adapter's `.all` must not add
        // `byDirectUserOrigin` to the roll-up.
        #expect(assessment.relaxationEligibility == [.byWorkspaceScope])
    }

    /// An adapter that declares nothing (`nil`, the default every existing adapter compiles with)
    /// leaves the static classification untouched — `nil` is "no opinion", not "no eligibility".
    @Test
    func anAdapterDeclaringNothingLeavesTheStaticClassificationUntouched() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try CapabilityRegistry(
            adapters: [FixedEligibilityAdapter(declared: nil)]
        )

        let assessment = try makeExecutor(root: root, capabilityRegistry: registry)
            .assessRisk(plan: openAppPlan(), scope: .unscoped)

        #expect(assessment.relaxationEligibility == [.byWorkspaceScope])
    }

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApprovalRelaxationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutor(
        root: URL,
        routineStore: RoutineStore? = nil,
        workspaceStore: WorkspaceStore? = nil,
        capabilityRegistry: CapabilityRegistry = .default
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            appOpener: UnusedAppOpener(),
            fileOpener: UnusedFileOpener(),
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            shortcutCatalog: FixedShortcutCatalog(names: ["Morning Report"]),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-history.json")
            ),
            capabilityRegistry: capabilityRegistry
        )
    }

    private func openAppPlan() -> AgentPlan {
        AgentPlan(
            summary: "Open Safari.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open-app", operation: .openApp, description: "Open Safari.", appName: "Safari")
            ]
        )
    }
}

/// Registered for `.openApp` in the narrowing tests: assesses at the operation's ordinary tier and
/// declares exactly the eligibility the test hands it, so the fold's treatment of a declared value
/// (and of `nil`) is observable in isolation.
private struct FixedEligibilityAdapter: CapabilityAdapter {
    let declared: OperationRelaxation?

    var metadata: CapabilityMetadata {
        CapabilityMetadata(
            id: "test.relaxation.fixed-eligibility",
            displayName: "Fixed-eligibility app opener",
            description: "Declares a fixed relaxation eligibility for the fold tests.",
            operations: [.openApp],
            plannerTools: [],
            requiredPermissions: [],
            defaultRiskTier: .tier1
        )
    }

    func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(defaultTier: .tier1, relaxationEligibility: declared)
    }
}

private struct FixedShortcutCatalog: ShortcutCatalogProviding {
    let names: [String]

    func shortcutNames() throws -> [String] {
        names
    }
}

private struct UnusedAppOpener: AppOpening {
    func open(bundleIdentifier: String) async throws {
        Issue.record("No test here opens an app.")
    }
}

private struct UnusedFileOpener: FileOpening {
    func openFile(_ url: URL) async throws {
        Issue.record("No test here opens a file.")
    }
}
