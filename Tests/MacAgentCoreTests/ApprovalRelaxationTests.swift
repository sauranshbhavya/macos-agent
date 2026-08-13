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

    // MARK: - The full cross-product, against the written tables

    /// The grant formula, row by row against `grantTable` — every (verdict, origin, eligibility)
    /// combination, written out rather than derived, so the test cannot share a bug with the
    /// formula it checks. The tier is irrelevant to the grant and held fixed.
    @Test
    func theGrantFormulaMatchesTheWrittenTableRowByRow() {
        for row in grantTable {
            let assessed = assessment(tier: .tier2, verdict: row.verdict, eligibility: row.eligibility)
            let context = ApprovalContext(origin: row.origin, safeMode: false)
            #expect(
                RelaxationGrant.grant(for: assessed, context: context) == row.grant,
                "verdict \(String(describing: row.verdict)), origin \(row.origin), eligibility rawValue \(row.eligibility.rawValue) expected \(row.grant)"
            )
        }
        #expect(grantTable.count == 60)
    }

    /// Every cell of the cross-product — 5 tiers × 5 verdict states × 3 origins × 2 Safe-mode
    /// values × 4 eligibility combinations, 600 cells — asserted against the written tables, never
    /// sampled. The expected value composes two hand-written lookups (`grantTable`, then
    /// `defaultPolicyRequirementTable` or `defaultPolicySafeModeTable`), so no line of this test
    /// re-derives the formula it is pinning.
    ///
    /// The table is also I4's pin: the only `.refuse` cells are tier 4's, in every column — no
    /// grant, and no absence of one, ever refuses something the baseline would have allowed.
    @Test
    func theFullCrossProductMatchesTheWrittenTables() {
        let policy = RiskApprovalPolicy.default
        for tier in CapabilityRiskTier.allCases {
            for row in grantTable {
                for safeMode in [false, true] {
                    let assessed = assessment(tier: tier, verdict: row.verdict, eligibility: row.eligibility)
                    let context = ApprovalContext(origin: row.origin, safeMode: safeMode)
                    let expected = safeMode
                        ? defaultPolicySafeModeTable[tier]!
                        : defaultPolicyRequirementTable[tier]![row.grant]!
                    #expect(
                        policy.requirement(for: assessed, context: context) == expected,
                        "tier \(tier), verdict \(String(describing: row.verdict)), origin \(row.origin), eligibility rawValue \(row.eligibility.rawValue), safeMode \(safeMode) expected \(expected)"
                    )
                }
            }
        }
    }

    /// **P1**: for identical inputs, `safeMode == true` is never more permissive than
    /// `safeMode == false` — over the full cross-product and every policy dial position, on the
    /// stated permissiveness rank. This is the property the `stricter(of:baseline:floor:)` formula
    /// makes structural, pinned so a rewrite of the formula cannot quietly lose it.
    @Test
    func safeModeIsNeverMorePermissiveThanTheSameInputsWithoutIt() {
        for policy in propertyPolicies {
            for tier in CapabilityRiskTier.allCases {
                for row in grantTable {
                    let assessed = assessment(tier: tier, verdict: row.verdict, eligibility: row.eligibility)
                    let safe = policy.requirement(
                        for: assessed,
                        context: ApprovalContext(origin: row.origin, safeMode: true)
                    )
                    let unsafe = policy.requirement(
                        for: assessed,
                        context: ApprovalContext(origin: row.origin, safeMode: false)
                    )
                    #expect(
                        safe.permissivenessRank <= unsafe.permissivenessRank,
                        "tier \(tier), verdict \(String(describing: row.verdict)), origin \(row.origin): safe \(safe) vs \(unsafe)"
                    )
                }
            }
        }
    }

    /// **P2**: a grant is never *less* permissive than `.none` — for every cell, the requirement
    /// with the cell's eligibility is at least as permissive as the same cell with eligibility
    /// emptied (which forces the `.none` column). Relaxation can only ever lighten an ask.
    @Test
    func aGrantIsNeverLessPermissiveThanTheNoneColumn() {
        for policy in propertyPolicies {
            for tier in CapabilityRiskTier.allCases {
                for row in grantTable {
                    for safeMode in [false, true] {
                        let context = ApprovalContext(origin: row.origin, safeMode: safeMode)
                        let granted = policy.requirement(
                            for: assessment(tier: tier, verdict: row.verdict, eligibility: row.eligibility),
                            context: context
                        )
                        let ungranted = policy.requirement(
                            for: assessment(tier: tier, verdict: row.verdict, eligibility: []),
                            context: context
                        )
                        #expect(
                            granted.permissivenessRank >= ungranted.permissivenessRank,
                            "tier \(tier), verdict \(String(describing: row.verdict)), origin \(row.origin), safeMode \(safeMode)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Policy dials (I9)

    /// Relaxation never overrides the user's own tightening preference: a `previewOnly` tier-2 mode
    /// survives both grants. The configuration is unreachable in the shipped app today — nothing in
    /// `Sources/` constructs a non-default policy — and the rule is ratified anyway, so the dead
    /// surface cannot silently defeat the preference the day it comes alive.
    @Test
    func relaxationNeverOverridesAPreviewOnlyTierTwoPolicy() {
        let policy = RiskApprovalPolicy(requireApprovalForTier1: false, tier2Mode: .previewOnly)

        #expect(policy.requirement(
            for: assessment(tier: .tier2, verdict: .inScope, eligibility: .all),
            context: ApprovalContext(origin: .planner, safeMode: false)
        ) == .previewOnly)
        #expect(policy.requirement(
            for: assessment(tier: .tier2, verdict: nil, eligibility: .all),
            context: ApprovalContext(origin: .directUserAction, safeMode: false)
        ) == .previewOnly)
        // The tier-2 dial is a tier-2 dial: the relaxed tier-3 cell is untouched by it.
        #expect(policy.requirement(
            for: assessment(tier: .tier3, verdict: .inScope, eligibility: .all),
            context: ApprovalContext(origin: .planner, safeMode: false)
        ) == .lightweightConfirmation)
    }

    /// The tier-1 row reads the policy in every column: a tightened tier 1 confirms identically
    /// with a grant, without one, and under either grant kind — no grant column reaches below the
    /// policy's own answer for a tier relaxation does not touch.
    @Test
    func aTightenedTierOnePolicyAppliesIdenticallyInEveryGrantColumn() {
        let policy = RiskApprovalPolicy(requireApprovalForTier1: true, tier2Mode: .lightweightConfirmation)
        let columns: [(ScopeVerdict?, PreparedPlanSource)] = [
            (nil, .planner),                 // .none
            (.inScope, .planner),            // .inScopeWorkspace
            (nil, .directUserAction)         // .directUserAuthored
        ]

        for (verdict, origin) in columns {
            #expect(policy.requirement(
                for: assessment(tier: .tier1, verdict: verdict, eligibility: .all),
                context: ApprovalContext(origin: origin, safeMode: false)
            ) == .lightweightConfirmation)
        }
    }

    // MARK: - I1/I2: a grant changes the weight of the ask and nothing else

    /// The origin grant, through the real runner: the same screen-built edit prepared under
    /// `.directUserAction` and under `.planner` produces **byte-identical assessments** — tier,
    /// escalations, copy, verdict, eligibility, all of it — and differs only in the requirement.
    /// The shape row B's `neitherUnscopedNorAnUnconstrainedKindChangesTheAssessment` set: the whole
    /// assessment compared, not the one field a bug would most likely spare.
    @Test
    func theOriginGrantChangesTheWeightOfTheAskAndNothingInTheAssessment() async throws {
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
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root, workspaceStore: workspaceStore))

        let screenBuilt = try runner.prepare(plan: plan, source: .directUserAction)
        let typedShape = try runner.prepare(plan: plan, source: .planner)
        let granted = try runner.approvalRequest(
            for: screenBuilt,
            scope: .unscoped,
            context: ApprovalContext(origin: screenBuilt.source, safeMode: false)
        )
        let ungranted = try runner.approvalRequest(
            for: typedShape,
            scope: .unscoped,
            context: ApprovalContext(origin: typedShape.source, safeMode: false)
        )

        #expect(granted.assessment == ungranted.assessment)
        #expect(granted.assessment.effectiveTier == .tier2)
        #expect(granted.approvalCopy == ungranted.approvalCopy)
        #expect(granted.requirement == .autoRun)
        #expect(granted.relaxationGrant == .directUserAuthored)
        #expect(ungranted.requirement == .lightweightConfirmation)
        #expect(ungranted.relaxationGrant == RelaxationGrant.none)
    }

    /// The workspace grant, through the real runner: an in-scope tier-2 draft auto-runs, its
    /// assessment is byte-identical to the executor's own independent answer, and Safe mode over
    /// the *same* prepared run returns to an explicit ask with no grant reported (I5: the grant is
    /// not computed inside Safe mode, so nothing may claim one applied).
    @Test
    func theWorkspaceGrantAutoRunsAnInScopeTierTwoAndSafeModeStillWins() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let projectFolder = root.appendingPathComponent("ClientAlpha", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
        let workspace = StoredWorkspace(
            name: "Client Alpha",
            apps: [],
            urls: [],
            fileLocations: [projectFolder.path]
        )
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: workspace, whitelist: PathWhitelist(roots: [root]))
        )
        let plan = AgentPlan(
            summary: "Draft notes in Client Alpha.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft notes in Client Alpha.",
                    outputPath: projectFolder.appendingPathComponent("notes.md").path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )
        let executor = makeExecutor(root: root)
        let runner = AgentRunner(planner: UnusedPlanner(), executor: executor)

        let prepared = try runner.prepare(plan: plan)
        let granted = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(origin: prepared.source, safeMode: false)
        )
        let safe = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(origin: prepared.source, safeMode: true)
        )

        #expect(granted.assessment == (try executor.assessRisk(plan: prepared.plan, scope: scope)))
        #expect(granted.assessment.effectiveTier == .tier2)
        #expect(granted.assessment.scopeVerdict == .inScope)
        #expect(granted.assessment.escalations.isEmpty)
        #expect(granted.requirement == .autoRun)
        #expect(granted.relaxationGrant == .inScopeWorkspace)
        #expect(safe.assessment == granted.assessment)
        #expect(safe.requirement == .explicitApproval)
        #expect(safe.relaxationGrant == RelaxationGrant.none)
    }

    // MARK: - The paths that must reach neither grant

    /// **I6, named for the hazard.** The unattended scheduled dispatch reaches neither grant by two
    /// independent call-site choices, not by any type-level guarantee: `source: .instantResolver`
    /// (never the origin grant) and `scope: .unscoped` (no verdict to be `.inScope`). This test
    /// replicates `performScheduledRun`'s exact shape — the same plan factory, the same source, the
    /// same scope — around a saved workspace that *would* cover the routine's steps if the
    /// scheduled path ever assessed with a real scope. Removing either call-site choice is the
    /// change this test exists to catch: in-scope tier-2 steps auto-running unattended, without the
    /// per-routine trust opt-in.
    @Test
    func theScheduledDispatchShapeReachesNeitherGrantEvenWithACoveringWorkspaceSaved() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Setup",
                steps: [
                    AgentStep(id: "open", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com")
                ]
            )
        )
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Work", apps: [], urls: ["https://github.com"]))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore, workspaceStore: workspaceStore)
        )

        let prepared = try runner.prepare(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning Setup"),
            source: .instantResolver
        )
        let request = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(origin: prepared.source, safeMode: false)
        )

        // The tier-2 confirmation the unattended backstop compares against — not an auto-run.
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.relaxationGrant == RelaxationGrant.none)
        // The `.unscoped` choice, visible: no verdict at all, which is not `.unconstrained`.
        #expect(request.assessment.scopeVerdict == nil)
    }

    /// A routine whose nested steps are all in scope still does not earn the workspace grant: the
    /// nested fold reports the verdict honestly (`.inScope` — the forward is working), and
    /// eligibility still blocks, because SONNY-54's per-routine trust toggle is the single door for
    /// skipping a routine's tier-2 prompt. Scope answers "right place", never "right thing".
    @Test
    func aRoutineWhoseNestedStepsAreAllInScopeStillDoesNotEarnTheWorkspaceGrant() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(
            StoredRoutine(
                name: "Morning Setup",
                steps: [
                    AgentStep(id: "open", operation: .openURL, description: "Open GitHub.", targetURL: "https://github.com")
                ]
            )
        )
        let workspace = StoredWorkspace(name: "Work", apps: [], urls: ["https://github.com"])
        let scope = TaskWorkspaceScope.scoped(WorkspaceScope(workspace: workspace))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try runner.prepare(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Morning Setup"),
            source: .instantResolver
        )
        let request = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(origin: prepared.source, safeMode: false)
        )

        #expect(request.assessment.scopeVerdict == .inScope)
        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.relaxationGrant == RelaxationGrant.none)
    }

    /// A chain mixing `edit_workspace` with any other operation, dispatched `.directUserAction`,
    /// never earns `.directUserAuthored` — the intersection roll-up demonstrated at the requirement
    /// level, not asserted: the screen built only part of what runs, so the screen's authority
    /// covers none of it.
    @Test
    func aChainMixingAWorkspaceEditWithAnotherOperationDispatchedFromTheScreenStillPrompts() async throws {
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
            steps: edit.steps + [
                AgentStep(id: "open-app", operation: .openApp, description: "Open Safari.", appName: "Safari")
            ]
        )
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, workspaceStore: workspaceStore)
        )

        let prepared = try runner.prepare(plan: chain, source: .directUserAction)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(origin: prepared.source, safeMode: false)
        )

        #expect(request.requirement == .lightweightConfirmation)
        #expect(request.relaxationGrant == RelaxationGrant.none)
    }

    /// An assessment that never went through the executor's fold carries `nil` eligibility and
    /// grants nothing, even in a maximally granting context — fail closed, never invented.
    @Test
    func anAssessmentThatNeverWentThroughTheExecutorsFoldGrantsNothing() {
        let bare = CapabilityRiskAssessment(defaultTier: .tier2, scopeVerdict: .inScope)
        let context = ApprovalContext(origin: .directUserAction, safeMode: false)

        #expect(RelaxationGrant.grant(for: bare, context: context) == RelaxationGrant.none)
        #expect(RiskApprovalPolicy.default.requirement(for: bare, context: context) == .lightweightConfirmation)
    }

    /// **I10's reachability coincidence, pinned by name.** The sole producer of a `.resolvedApp`
    /// scoped resource — the one resource kind that can still earn `.inScope` through
    /// `WorkspaceScope`'s name-fallback key, for an entry nothing installed answers to — sits at
    /// tier 1, a tier no grant column relaxes. SONNY-84 discharged the imposter gap structurally
    /// (installed apps all key by bundle id), so this coincidence is belt-and-braces; a tier bump
    /// on this adapter is the change that must re-open the I10 argument consciously, and this test
    /// is where that conversation starts.
    @Test
    func theSoleResolvedAppProducerSitsAtATierNoGrantColumnRelaxes() {
        #expect(RunningAppSwitchCapabilityAdapter.metadata.defaultRiskTier == .tier1)
    }

    // MARK: - The removed public paths stay removed

    /// The two removed wrappers (`CapabilityRiskAssessment.approvalRequirement(policy:)` and
    /// `CapabilityRiskTier.approvalRequirement(policy:)`) must not be reintroduced under their old
    /// name anywhere in `Sources/` or `Tests/`. The demotion of the tier-only
    /// `RiskApprovalPolicy.requirement(for:)` to `private` is compiler-enforced and needs no sweep;
    /// this sweep exists because a *new* function under the old name would compile fine and quietly
    /// become a second public path. Comment-stripped, so prose recording what was removed does not
    /// fail the test that pins the removal.
    @Test
    func theRemovedRequirementWrappersNeverReappearInSourcesOrTests() throws {
        // Concatenated so this test's own source cannot match its own sweep.
        let needle = "approvalRequirement" + "("
        let fileManager = FileManager.default
        var scanned = 0
        for directory in ["Sources", "Tests"] {
            let rootURL = packageRoot().appendingPathComponent(directory, isDirectory: true)
            let enumerator = try #require(fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let code = Self.strippingComments(try String(contentsOf: url, encoding: .utf8))
                #expect(!code.contains(needle), "\(url.lastPathComponent) names the removed wrapper.")
                scanned += 1
            }
        }
        #expect(scanned > 100, "The sweep read \(scanned) files — too few to be the real tree.")
    }

    // MARK: - Fixtures

    private func assessment(
        tier: CapabilityRiskTier,
        verdict: ScopeVerdict?,
        eligibility: OperationRelaxation
    ) -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(
            defaultTier: tier,
            effectiveTier: tier,
            scopeVerdict: verdict,
            relaxationEligibility: eligibility
        )
    }

    private func packageRoot() -> URL {
        // <package root>/Tests/MacAgentCoreTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Swift source with `//` and `///` comments removed — the same deliberately line-oriented
    /// shape `InstalledAppResolverTests` uses for its structural sweeps, and sound for the same
    /// reason: the needle is an identifier, and no identifier contains a double slash.
    private static func strippingComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else {
                    return line
                }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

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

// MARK: - The written tables

/// The grant table, written out in full: every (verdict, origin, eligibility) combination — 5
/// verdict states × 3 origins × 4 eligibility subsets, 60 rows — with the grant each one earns.
/// Hand-derived from the ratified §2.1 formula and reviewed as data, so the tests composing on it
/// cannot share a bug with the formula they pin. Notable rows: only `.inScope` ever grants the
/// workspace column (I3 — `nil`, `.unconstrained`, `.outOfScope` and `.opaque` all read `.none`
/// there); the origin grant needs both the `.directUserAction` origin *and* the
/// `byDirectUserOrigin` bit (F2 — per-grant eligibility); and where both grants qualify, the
/// boundary-earned `.inScopeWorkspace` wins.
private let grantTable: [(verdict: ScopeVerdict?, origin: PreparedPlanSource, eligibility: OperationRelaxation, grant: RelaxationGrant)] = [
    // No workspace bound: the origin grant is the only reachable one.
    (nil, .planner, [], .none),
    (nil, .planner, [.byWorkspaceScope], .none),
    (nil, .planner, [.byDirectUserOrigin], .none),
    (nil, .planner, .all, .none),
    (nil, .instantResolver, [], .none),
    (nil, .instantResolver, [.byWorkspaceScope], .none),
    (nil, .instantResolver, [.byDirectUserOrigin], .none),
    (nil, .instantResolver, .all, .none),
    (nil, .directUserAction, [], .none),
    (nil, .directUserAction, [.byWorkspaceScope], .none),
    (nil, .directUserAction, [.byDirectUserOrigin], .directUserAuthored),
    (nil, .directUserAction, .all, .directUserAuthored),
    // In scope: the workspace grant fires wherever its bit is set; the stronger grant wins when
    // both apply.
    (.inScope, .planner, [], .none),
    (.inScope, .planner, [.byWorkspaceScope], .inScopeWorkspace),
    (.inScope, .planner, [.byDirectUserOrigin], .none),
    (.inScope, .planner, .all, .inScopeWorkspace),
    (.inScope, .instantResolver, [], .none),
    (.inScope, .instantResolver, [.byWorkspaceScope], .inScopeWorkspace),
    (.inScope, .instantResolver, [.byDirectUserOrigin], .none),
    (.inScope, .instantResolver, .all, .inScopeWorkspace),
    (.inScope, .directUserAction, [], .none),
    (.inScope, .directUserAction, [.byWorkspaceScope], .inScopeWorkspace),
    (.inScope, .directUserAction, [.byDirectUserOrigin], .directUserAuthored),
    (.inScope, .directUserAction, .all, .inScopeWorkspace),
    // Out of scope: never the workspace grant (I3); the origin grant is verdict-blind by design —
    // the operation allowlist and SONNY-98's narrowing are its containment, not the verdict.
    (.outOfScope, .planner, [], .none),
    (.outOfScope, .planner, [.byWorkspaceScope], .none),
    (.outOfScope, .planner, [.byDirectUserOrigin], .none),
    (.outOfScope, .planner, .all, .none),
    (.outOfScope, .instantResolver, [], .none),
    (.outOfScope, .instantResolver, [.byWorkspaceScope], .none),
    (.outOfScope, .instantResolver, [.byDirectUserOrigin], .none),
    (.outOfScope, .instantResolver, .all, .none),
    (.outOfScope, .directUserAction, [], .none),
    (.outOfScope, .directUserAction, [.byWorkspaceScope], .none),
    (.outOfScope, .directUserAction, [.byDirectUserOrigin], .directUserAuthored),
    (.outOfScope, .directUserAction, .all, .directUserAuthored),
    // Unconstrained: a bound workspace that says nothing about the plan's kinds is not `.inScope`,
    // and must never be collapsed with `nil` above — same answers, different facts.
    (.unconstrained, .planner, [], .none),
    (.unconstrained, .planner, [.byWorkspaceScope], .none),
    (.unconstrained, .planner, [.byDirectUserOrigin], .none),
    (.unconstrained, .planner, .all, .none),
    (.unconstrained, .instantResolver, [], .none),
    (.unconstrained, .instantResolver, [.byWorkspaceScope], .none),
    (.unconstrained, .instantResolver, [.byDirectUserOrigin], .none),
    (.unconstrained, .instantResolver, .all, .none),
    (.unconstrained, .directUserAction, [], .none),
    (.unconstrained, .directUserAction, [.byWorkspaceScope], .none),
    (.unconstrained, .directUserAction, [.byDirectUserOrigin], .directUserAuthored),
    (.unconstrained, .directUserAction, .all, .directUserAuthored),
    // Opaque: poisons the roll-up and never grants the workspace column.
    (.opaque, .planner, [], .none),
    (.opaque, .planner, [.byWorkspaceScope], .none),
    (.opaque, .planner, [.byDirectUserOrigin], .none),
    (.opaque, .planner, .all, .none),
    (.opaque, .instantResolver, [], .none),
    (.opaque, .instantResolver, [.byWorkspaceScope], .none),
    (.opaque, .instantResolver, [.byDirectUserOrigin], .none),
    (.opaque, .instantResolver, .all, .none),
    (.opaque, .directUserAction, [], .none),
    (.opaque, .directUserAction, [.byWorkspaceScope], .none),
    (.opaque, .directUserAction, [.byDirectUserOrigin], .directUserAuthored),
    (.opaque, .directUserAction, .all, .directUserAuthored)
]

/// The ratified 15-cell (tier, grant) requirement table on the **default** policy, written as
/// data. Rows are tiers, columns are grants. The starred cell of the plan's §2.2 — tier-2 grants
/// reading `tier2Mode` — is pinned separately by `relaxationNeverOverridesAPreviewOnlyTierTwoPolicy`.
private let defaultPolicyRequirementTable: [CapabilityRiskTier: [RelaxationGrant: RiskApprovalRequirement]] = [
    .tier0: [.none: .autoRun, .inScopeWorkspace: .autoRun, .directUserAuthored: .autoRun],
    .tier1: [.none: .autoRun, .inScopeWorkspace: .autoRun, .directUserAuthored: .autoRun],
    .tier2: [.none: .lightweightConfirmation, .inScopeWorkspace: .autoRun, .directUserAuthored: .autoRun],
    .tier3: [.none: .explicitApproval, .inScopeWorkspace: .lightweightConfirmation, .directUserAuthored: .lightweightConfirmation],
    .tier4: [.none: .refuse, .inScopeWorkspace: .refuse, .directUserAuthored: .refuse]
]

/// Safe mode on the default policy: `stricter(of: baseline, .explicitApproval)` per tier — every
/// tier that could run now asks explicitly, and tier 4 still refuses. Written out so the formula's
/// output is pinned as concrete values, not re-derived.
private let defaultPolicySafeModeTable: [CapabilityRiskTier: RiskApprovalRequirement] = [
    .tier0: .explicitApproval,
    .tier1: .explicitApproval,
    .tier2: .explicitApproval,
    .tier3: .explicitApproval,
    .tier4: .refuse
]

/// Every position of both policy dials, for the property tests: the default, the tightened tier-1
/// variant, and the preview-only tier-2 variant.
private let propertyPolicies: [RiskApprovalPolicy] = [
    .default,
    RiskApprovalPolicy(requireApprovalForTier1: true, tier2Mode: .lightweightConfirmation),
    RiskApprovalPolicy(requireApprovalForTier1: false, tier2Mode: .previewOnly)
]

/// Never called: every test here prepares its plan directly.
private struct UnusedPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("The planner must not be consulted in this suite.")
        throw AgentExecutionError.invalidPlan("planner should not be called")
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
