import Foundation
import Testing
@testable import MacAgentCore

/// The consequence rule (founder directive, 2026-08-13, superseding row C's ratified
/// scope-conditional relaxation): Sonny asks permission only when an action is destructive or
/// affects someone other than the user. Everything else runs without asking, made legible by the
/// ran-without-asking trace.
///
/// What is pinned here: the requirement mapping against written tables (never sampled), the
/// properties the pivot kept (Safe mode never more permissive; advisory never asks; destructive
/// always asks), the consequence class of every escalation construction site (the mutation
/// battery's named targets — a site misclassified in *either* direction must die here), that the
/// scope verdict is data and not a gate, the unattended tier-2 ceiling, and the mid-flight drift
/// re-arm (SONNY-62's chassis applied to what still asks).
///
/// This file replaces `ApprovalRelaxationTests.swift`. The grant machinery it pinned —
/// `OperationRelaxation`, `RelaxationGrant`, the eligibility fold, SONNY-98's boundary-changing
/// narrowing — is deleted, not dormant, so its tests are deleted with it; the closing records on
/// SONNY-97/98/99/100 enumerate exactly which tests died and why.
@Suite
@MainActor
struct ConsequenceRuleTests {
    // MARK: - The mapping, against written tables

    /// Every combination of escalation classes this rule distinguishes. Hand-enumerated so the
    /// tables below are data, not derivation.
    private static let classCombos: [(name: String, classes: [CapabilityRiskEscalation.Consequence])] = [
        ("none", []),
        ("advisoryOnly", [.advisory]),
        ("twoAdvisories", [.advisory, .advisory]),
        ("destructiveOnly", [.destructive]),
        ("affectsOthersOnly", [.affectsOthers]),
        ("advisoryPlusDestructive", [.advisory, .destructive]),
        ("advisoryPlusAffectsOthers", [.advisory, .affectsOthers])
    ]

    /// The whole ordinary-path table, written out: rows are tiers, columns are the class combos
    /// above, on the default policy with Safe mode off. The load-bearing cells: advisory-only
    /// tier 3 auto-runs; an escalation-free tier 3 fails closed to an explicit ask; any combo
    /// containing a destructive or affects-others escalation asks at every tier that can run —
    /// including tiers 0–2, where the arithmetic cannot put one today but the rule, not the
    /// arithmetic, decides; tier 4 refuses in every column.
    private static let ordinaryTable: [CapabilityRiskTier: [String: RiskApprovalRequirement]] = [
        .tier0: [
            "none": .autoRun, "advisoryOnly": .autoRun, "twoAdvisories": .autoRun,
            "destructiveOnly": .explicitApproval, "affectsOthersOnly": .explicitApproval,
            "advisoryPlusDestructive": .explicitApproval, "advisoryPlusAffectsOthers": .explicitApproval
        ],
        .tier1: [
            "none": .autoRun, "advisoryOnly": .autoRun, "twoAdvisories": .autoRun,
            "destructiveOnly": .explicitApproval, "affectsOthersOnly": .explicitApproval,
            "advisoryPlusDestructive": .explicitApproval, "advisoryPlusAffectsOthers": .explicitApproval
        ],
        .tier2: [
            "none": .autoRun, "advisoryOnly": .autoRun, "twoAdvisories": .autoRun,
            "destructiveOnly": .explicitApproval, "affectsOthersOnly": .explicitApproval,
            "advisoryPlusDestructive": .explicitApproval, "advisoryPlusAffectsOthers": .explicitApproval
        ],
        .tier3: [
            "none": .explicitApproval, "advisoryOnly": .autoRun, "twoAdvisories": .autoRun,
            "destructiveOnly": .explicitApproval, "affectsOthersOnly": .explicitApproval,
            "advisoryPlusDestructive": .explicitApproval, "advisoryPlusAffectsOthers": .explicitApproval
        ],
        .tier4: [
            "none": .refuse, "advisoryOnly": .refuse, "twoAdvisories": .refuse,
            "destructiveOnly": .refuse, "affectsOthersOnly": .refuse,
            "advisoryPlusDestructive": .refuse, "advisoryPlusAffectsOthers": .refuse
        ]
    ]

    /// Safe mode on the default policy: every tier that could run asks explicitly, whatever the
    /// escalations say, and tier 4 still refuses. `stricter(of: baseline, .explicitApproval)`
    /// written out as concrete values, not re-derived.
    private static let safeModeTable: [CapabilityRiskTier: RiskApprovalRequirement] = [
        .tier0: .explicitApproval,
        .tier1: .explicitApproval,
        .tier2: .explicitApproval,
        .tier3: .explicitApproval,
        .tier4: .refuse
    ]

    @Test
    func theOrdinaryPathMatchesTheWrittenTableCellByCell() {
        let policy = RiskApprovalPolicy.default
        for tier in CapabilityRiskTier.allCases {
            for combo in Self.classCombos {
                let expected = Self.ordinaryTable[tier]![combo.name]!
                #expect(
                    policy.requirement(
                        for: assessment(tier: tier, classes: combo.classes),
                        context: ApprovalContext(safeMode: false)
                    ) == expected,
                    "tier \(tier), combo \(combo.name) expected \(expected)"
                )
            }
        }
        #expect(Self.ordinaryTable.count == CapabilityRiskTier.allCases.count)
        #expect(Self.ordinaryTable.values.allSatisfy { $0.count == Self.classCombos.count })
    }

    @Test
    func safeModeMatchesItsWrittenTableWhateverTheEscalationsSay() {
        let policy = RiskApprovalPolicy.default
        for tier in CapabilityRiskTier.allCases {
            for combo in Self.classCombos {
                #expect(
                    policy.requirement(
                        for: assessment(tier: tier, classes: combo.classes),
                        context: ApprovalContext(safeMode: true)
                    ) == Self.safeModeTable[tier]!,
                    "tier \(tier), combo \(combo.name)"
                )
            }
        }
    }

    /// The `asksFirst` classification itself, as a written table over `allCases` — a new
    /// consequence class fails this test until someone classifies it here too, the same
    /// compile-plus-test pincer the exhaustive `switch` starts.
    @Test
    func theAsksFirstClassificationMatchesTheWrittenTable() {
        let table: [CapabilityRiskEscalation.Consequence: Bool] = [
            .destructive: true,
            .affectsOthers: true,
            .advisory: false
        ]
        for consequence in CapabilityRiskEscalation.Consequence.allCases {
            #expect(table[consequence] == consequence.asksFirst, "\(consequence)")
        }
        #expect(table.count == CapabilityRiskEscalation.Consequence.allCases.count)
    }

    // MARK: - The properties the pivot kept

    /// **Safe mode is never more permissive than the same inputs without it** — over every policy
    /// dial position, every tier, every class combination, on the stated permissiveness rank. The
    /// `stricter(of:_:)` formula makes this structural; the property pins it against a rewrite.
    @Test
    func safeModeIsNeverMorePermissiveThanTheSameInputsWithoutIt() {
        for policy in propertyPolicies {
            for tier in CapabilityRiskTier.allCases {
                for combo in Self.classCombos {
                    let assessed = assessment(tier: tier, classes: combo.classes)
                    let safe = policy.requirement(for: assessed, context: ApprovalContext(safeMode: true))
                    let unsafe = policy.requirement(for: assessed, context: ApprovalContext(safeMode: false))
                    #expect(
                        safe.permissivenessRank <= unsafe.permissivenessRank,
                        "tier \(tier), combo \(combo.name): safe \(safe) vs \(unsafe)"
                    )
                }
            }
        }
    }

    /// **Advisory never asks**: an assessment whose escalations are all advisory never yields a
    /// requirement that waits on a human — outside Safe mode, whose entire point is that
    /// everything does.
    @Test
    func anAllAdvisoryAssessmentNeverAsksOutsideSafeMode() {
        for policy in propertyPolicies {
            for tier in CapabilityRiskTier.allCases {
                for combo in Self.classCombos where !combo.classes.isEmpty
                    && combo.classes.allSatisfy({ $0 == .advisory }) {
                    let requirement = policy.requirement(
                        for: assessment(tier: tier, classes: combo.classes),
                        context: ApprovalContext(safeMode: false)
                    )
                    #expect(
                        !requirement.requiresUserApproval,
                        "tier \(tier), combo \(combo.name): \(requirement)"
                    )
                }
            }
        }
    }

    /// **Destructive (and affects-others) always asks**: any assessment carrying one never
    /// auto-runs, at any tier, under any policy, with Safe mode on or off. At tier 4 the answer is
    /// `refuse`, which is stricter than asking; everywhere else it is an explicit ask.
    @Test
    func anAssessmentCarryingADestructiveOrAffectsOthersEscalationNeverAutoRuns() {
        for policy in propertyPolicies {
            for tier in CapabilityRiskTier.allCases {
                for combo in Self.classCombos where combo.classes.contains(where: \.asksFirst) {
                    for safeMode in [false, true] {
                        let requirement = policy.requirement(
                            for: assessment(tier: tier, classes: combo.classes),
                            context: ApprovalContext(safeMode: safeMode)
                        )
                        #expect(
                            requirement != .autoRun && requirement != .lightweightConfirmation,
                            "tier \(tier), combo \(combo.name), safeMode \(safeMode): \(requirement)"
                        )
                    }
                }
            }
        }
    }

    /// The defense-in-depth cell by name: a destructive escalation asks even when the tier
    /// arithmetic left the effective tier at 2 — a state no adapter can produce today (every
    /// escalation targets tier 3, and `effectiveTier` is a max-fold over the targets), pinned so
    /// the day an escalation targets tier 2 it asks without anyone remembering to make it.
    @Test
    func aDestructiveEscalationAsksEvenWhenTheTierArithmeticStaysAtTierTwo() {
        let forced = CapabilityRiskAssessment(
            defaultTier: .tier2,
            effectiveTier: .tier2,
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier2,
                    reason: "A future tier-2 destructive escalation.",
                    consequence: .destructive
                )
            ]
        )
        #expect(
            RiskApprovalPolicy.default.requirement(
                for: forced,
                context: ApprovalContext(safeMode: false)
            ) == .explicitApproval
        )
    }

    /// An escalation-free tier 3 fails closed: no adapter can produce it (no static tier reaches
    /// 3), so there is nothing classified to run silently on, and the answer is the ask.
    @Test
    func anEscalationFreeTierThreeFailsClosedToAnExplicitAsk() {
        let bare = CapabilityRiskAssessment(defaultTier: .tier2, effectiveTier: .tier3)
        #expect(
            RiskApprovalPolicy.default.requirement(
                for: bare,
                context: ApprovalContext(safeMode: false)
            ) == .explicitApproval
        )
    }

    /// **The scope verdict is data, not a gate**: for every tier and class combination, every
    /// verdict state — `nil`, in scope, out of scope, unconstrained, opaque — produces the
    /// identical requirement. Row B's boundary survives as information (the chips, the trace, the
    /// future vision cage); it buys and costs nothing at the approval gate.
    @Test
    func theScopeVerdictNeverChangesTheRequirement() {
        let verdicts: [ScopeVerdict?] = [nil, .inScope, .outOfScope, .unconstrained, .opaque]
        for tier in CapabilityRiskTier.allCases {
            for combo in Self.classCombos {
                for safeMode in [false, true] {
                    let context = ApprovalContext(safeMode: safeMode)
                    let baseline = RiskApprovalPolicy.default.requirement(
                        for: assessment(tier: tier, classes: combo.classes, verdict: nil),
                        context: context
                    )
                    for verdict in verdicts {
                        #expect(
                            RiskApprovalPolicy.default.requirement(
                                for: assessment(tier: tier, classes: combo.classes, verdict: verdict),
                                context: context
                            ) == baseline,
                            "tier \(tier), combo \(combo.name), verdict \(String(describing: verdict))"
                        )
                    }
                }
            }
        }
    }

    /// The policy dials no longer gate the ordinary path: a tightened tier 1 and a preview-only
    /// tier 2 both auto-run under the consequence rule. Inside Safe mode the *stricter* dial still
    /// shows — a preview-only tier-2 policy stays preview-only there, because the formula takes
    /// the stricter of baseline and floor. `requireApprovalForTier1` now has no observable effect
    /// anywhere; whether both dials should be deleted outright is flagged for the founder in the
    /// pivot's records, not decided here.
    @Test
    func thePolicyDialsNoLongerGateTheOrdinaryPathAndSurviveOnlyInsideSafeMode() {
        let tightened = RiskApprovalPolicy(requireApprovalForTier1: true, tier2Mode: .previewOnly)

        #expect(tightened.requirement(
            for: assessment(tier: .tier1, classes: []),
            context: ApprovalContext(safeMode: false)
        ) == .autoRun)
        #expect(tightened.requirement(
            for: assessment(tier: .tier2, classes: []),
            context: ApprovalContext(safeMode: false)
        ) == .autoRun)
        #expect(tightened.requirement(
            for: assessment(tier: .tier2, classes: []),
            context: ApprovalContext(safeMode: true)
        ) == .previewOnly)
        #expect(tightened.requirement(
            for: assessment(tier: .tier1, classes: []),
            context: ApprovalContext(safeMode: true)
        ) == .explicitApproval)
    }

    // MARK: - The rule through the real dispatch machinery

    /// A tier-2 draft inside its own workspace runs without asking — and the identical plan with
    /// no workspace bound runs without asking too, with byte-identical assessments except for the
    /// verdict data. The boundary changes what Sonny *knows*, never whether it asks.
    @Test
    func aTierTwoDraftAutoRunsScopedAndUnscopedAlike() async throws {
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
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root))

        let prepared = try runner.prepare(plan: plan)
        let scoped = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(safeMode: false)
        )
        let unscoped = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )

        #expect(scoped.assessment.effectiveTier == .tier2)
        #expect(scoped.assessment.escalations.isEmpty)
        #expect(scoped.assessment.scopeVerdict == .inScope)
        #expect(scoped.requirement == .autoRun)
        #expect(unscoped.requirement == .autoRun)
        #expect(unscoped.assessment.scopeVerdict == nil)
        var scopedStripped = scoped.assessment
        scopedStripped.scopeVerdict = nil
        #expect(scopedStripped == unscoped.assessment)
    }

    /// Safe mode over the same prepared run returns to an explicit ask, with the assessment
    /// untouched — the mapping bends, the facts do not.
    @Test
    func safeModeMakesTheSameTierTwoDraftAskWithAnUntouchedAssessment() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("notes.md")
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root))
        let prepared = try runner.prepare(plan: draftPlan(output: output))

        let ordinary = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )
        let safe = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(safeMode: true)
        )

        #expect(ordinary.requirement == .autoRun)
        #expect(safe.requirement == .explicitApproval)
        #expect(safe.assessment == ordinary.assessment)
        #expect(safe.approvalCopy == ordinary.approvalCopy)
    }

    /// An out-of-scope plan auto-runs, and the fact travels: the escalation is still raised, still
    /// tier 3, still carries the exact sentence row B specified — classified advisory, so it lands
    /// on the ran-without-asking trace instead of a prompt. Safe mode still asks about it.
    @Test
    func anOutOfScopePlanAutoRunsWithTheAdvisoryFactRecordedAndSafeModeStillAsks() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root))
        let scope = TaskWorkspaceScope.scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"]))
        )
        let plan = AgentPlan(
            summary: "Open a site.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "open",
                    operation: .openURL,
                    description: "Open an unrelated site.",
                    targetURL: "https://example.com/page"
                )
            ]
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(safeMode: false)
        )
        let safe = try runner.approvalRequest(
            for: prepared,
            scope: scope,
            context: ApprovalContext(safeMode: true)
        )

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.scopeVerdict == .outOfScope)
        #expect(request.assessment.escalations.map(\.reason) == [
            "example.com is not part of the Research workspace."
        ])
        #expect(request.assessment.escalations.map(\.consequence) == [.advisory])
        #expect(request.requirement == .autoRun)
        #expect(safe.requirement == .explicitApproval)
    }

    // MARK: - Every construction site's class, by name
    //
    // The mutation battery's targets: flip any one site's class and exactly these tests go red —
    // a destructive site flipped to advisory dies on its `.explicitApproval`/`.destructive`
    // assertions (a prompt the founder kept would vanish), and an advisory site flipped to
    // destructive dies on its `.autoRun`/`.advisory` assertions (a prompt the founder killed
    // would resurrect).

    @Test
    func everyReplaceOnSaveEscalationIsDestructiveAndStillAsks() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Morning Setup", steps: openAppPlan().steps))
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: []))
        let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        try snippetStore.save(StoredSnippet(trigger: ";sig", expansion: "Best, Sonny"))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(
                root: root,
                routineStore: routineStore,
                workspaceStore: workspaceStore,
                snippetStore: snippetStore
            )
        )

        let cases: [(plan: AgentPlan, reason: String)] = [
            (
                saveRoutinePlan(name: "Morning Setup"),
                "Routine named Morning Setup already exists and would be replaced."
            ),
            (
                createWorkspacePlan(name: "Client Alpha"),
                "Workspace named Client Alpha already exists and would be replaced."
            ),
            (
                saveSnippetPlan(trigger: ";sig", expansion: "Different expansion"),
                "Snippet trigger ;sig already exists and would be replaced."
            )
        ]
        for testCase in cases {
            let prepared = try runner.prepare(plan: testCase.plan, source: .instantResolver)
            let request = try runner.approvalRequest(
                for: prepared,
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
            #expect(request.assessment.effectiveTier == .tier3, "\(testCase.reason)")
            #expect(request.assessment.escalations.map(\.reason) == [testCase.reason])
            #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
            #expect(request.requirement == .explicitApproval)
        }
    }

    @Test
    func everyOutputCollisionEscalationIsDestructiveAndStillAsks() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try "small".write(to: root.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 2048)
            .write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root))

        let zipOutput = root.appendingPathComponent("largest.zip")
        let markdownOutput = root.appendingPathComponent("web.md")
        let draftOutput = root.appendingPathComponent("draft.md")
        for output in [zipOutput, markdownOutput, draftOutput] {
            try "existing".write(to: output, atomically: true, encoding: .utf8)
        }

        let cases: [(plan: AgentPlan, reason: String)] = [
            (largestPlan(root: root, output: zipOutput), "Zip output already exists at \(zipOutput.path)."),
            (webMarkdownPlan(output: markdownOutput), "Markdown output already exists at \(markdownOutput.path)."),
            (draftPlan(output: draftOutput), "Draft output already exists at \(draftOutput.path).")
        ]
        for testCase in cases {
            let prepared = try runner.prepare(plan: testCase.plan, source: .instantResolver)
            let request = try runner.approvalRequest(
                for: prepared,
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
            #expect(request.assessment.effectiveTier == .tier3, "\(testCase.reason)")
            #expect(request.assessment.escalations.map(\.reason) == [testCase.reason])
            #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
            #expect(request.requirement == .explicitApproval)
        }
    }

    /// Both removal wordings — one-of-several and dimension-emptying — are advisory and auto-run.
    /// The sentences themselves are unchanged from row B, exactly: they are what the trace names,
    /// and the dimension-emptying variant in particular still states the real consent (the
    /// workspace stops restricting that kind at all) even though nobody is prompted with it
    /// anymore. This consciously supersedes the Q4 ratification (emptying removals kept explicit
    /// approval) — a recorded coordinator call, founder-vetoable.
    @Test
    func workspaceEntryRemovalEscalationsAreAdvisoryAndAutoRunInBothWordings() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: []))
        try workspaceStore.save(StoredWorkspace(name: "Solo", apps: ["Safari"], urls: ["https://github.com"]))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, workspaceStore: workspaceStore)
        )

        let oneOfSeveral = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(workspaceName: "Client Alpha", kind: .app, value: "Notes", action: .remove)
        )
        let emptying = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(workspaceName: "Solo", kind: .app, value: "Safari", action: .remove)
        )

        let cases: [(plan: AgentPlan, reason: String)] = [
            (
                oneOfSeveral,
                "Removes Notes from workspace Client Alpha's apps. "
                    + "What is removed stops counting as part of this workspace."
            ),
            (
                emptying,
                "Workspace Solo will no longer restrict apps at all: "
                    + "this removes the last entry from its apps list."
            )
        ]
        for testCase in cases {
            let prepared = try runner.prepare(plan: testCase.plan, source: .directUserAction)
            let request = try runner.approvalRequest(
                for: prepared,
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
            #expect(request.assessment.effectiveTier == .tier3, "\(testCase.reason)")
            #expect(request.assessment.escalations.map(\.reason) == [testCase.reason])
            #expect(request.assessment.escalations.map(\.consequence) == [.advisory])
            #expect(request.requirement == .autoRun)
        }
    }

    /// The whitelist-root widening keeps its consequence-naming sentence and its tier — and runs,
    /// because widening a boundary destroys nothing and reaches nobody. This consciously
    /// supersedes SONNY-98's shipped prompting for the same edit — a recorded coordinator call,
    /// founder-vetoable — and it holds for a *typed* root add too, not only the sheet's: the
    /// classification is origin-blind.
    @Test
    func theWhitelistRootWideningEscalationIsAdvisoryAndAutoRuns() async throws {
        let rootA = try makeDirectory()
        let rootB = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let insideA = rootA.appendingPathComponent("ClientAlpha", isDirectory: true)
        try FileManager.default.createDirectory(at: insideA, withIntermediateDirectories: true)
        let workspaceStore = WorkspaceStore(fileURL: rootA.appendingPathComponent("workspaces.json"))
        try workspaceStore.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [insideA.resolvingSymlinksInPath().path]
            )
        )
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(
                root: rootA,
                workspaceStore: workspaceStore,
                whitelist: PathWhitelist(roots: [rootA, rootB])
            )
        )
        let rootBPath = rootB.resolvingSymlinksInPath().path
        let plan = EditWorkspaceCapabilityAdapter.plan(
            for: WorkspaceScopeEditRequest(
                workspaceName: "Client Alpha",
                kind: .fileLocation,
                value: rootBPath,
                action: .add
            )
        )

        let prepared = try runner.prepare(plan: plan, source: .planner)
        let request = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )

        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.consequence) == [.advisory])
        #expect(request.assessment.escalations.map(\.reason) == [
            "Adds \(rootBPath) itself — not a folder inside it — to workspace Client Alpha's "
                + "file locations. Everything Sonny may touch under \(rootBPath) would count as part of "
                + "this workspace, so this one entry turns that whole territory into the workspace's "
                + "boundary."
        ])
        #expect(request.requirement == .autoRun)
    }

    // MARK: - The unattended ceiling

    /// A clean tier-2 routine still runs unattended — the same outcome as before the rule, reached
    /// through `.autoRun` instead of a standing-grant-authorized confirmation.
    @Test
    func aCleanTierTwoRoutineStillRunsUnattended() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("notes.md")
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Draft Notes", steps: draftPlan(output: output).steps))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try runner.prepare(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Draft Notes"),
            source: .instantResolver
        )
        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(.tier2),
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    /// **The unattended ceiling holds.** Every tier-3 an unattended run can actually reach is
    /// destructive (a scheduled run is `.unscoped`, so no out-of-scope advisory exists, and
    /// `StoredRoutine.forbiddenStepOperations` rejects `edit_workspace`, so no removal or widening
    /// advisory exists either — the second half asserted here on the real forbidden list), it
    /// still asks, and the scheduled path's `.approved(.tier2)` standing grant still refuses it —
    /// the same pause-the-schedule outcome as before the rule.
    @Test
    func theUnattendedCeilingStillRefusesEveryTierThreeItCanReach() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("notes.md")
        try "existing draft".write(to: output, atomically: true, encoding: .utf8)
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        try routineStore.save(StoredRoutine(name: "Draft Notes", steps: draftPlan(output: output).steps))
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root, routineStore: routineStore)
        )

        let prepared = try runner.prepare(
            plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: "Draft Notes"),
            source: .instantResolver
        )
        await #expect(throws: RiskApprovalError.self) {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
        }

        #expect(try String(contentsOf: output, encoding: .utf8) == "existing draft")
        // The reachability half: the one advisory-producing adapter is unreachable from a stored
        // routine, so "advisory tier 3 auto-runs" cannot leak into the unattended path.
        #expect(StoredRoutine.forbiddenStepOperations.contains(.editWorkspace))
    }

    // MARK: - Drift re-arms (SONNY-62's chassis, applied to what still asks)

    /// An auto-run that turns destructive mid-flight re-arms instead of executing: the draft's
    /// output appears between the assessment that said `.autoRun` and `execute`'s own fresh
    /// re-assessment, which now finds a destructive escalation and throws the pending approval.
    /// No `risk.rearmed` event — a `.notRequested` dispatch reaching the gate is the ordinary
    /// "this needs approval" path, not a broken consent (SONNY-62, M9).
    @Test
    func anAutoRunThatTurnsDestructiveMidFlightReArmsWithoutAFalseReArmTrace() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("notes.md")
        let logStore = AgentLogStore()
        let runner = AgentRunner(
            planner: UnusedPlanner(),
            executor: makeExecutor(root: root),
            logStore: logStore
        )
        let prepared = try runner.prepare(plan: draftPlan(output: output))

        let before = try runner.approvalRequest(
            for: prepared,
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )
        #expect(before.requirement == .autoRun)

        try "existing draft".write(to: output, atomically: true, encoding: .utf8)

        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .notRequested,
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
            Issue.record("Expected the drifted destructive escalation to stop the run.")
        } catch RiskApprovalError.approvalRequired(let rearmed) {
            #expect(rearmed.requirement == .explicitApproval)
            #expect(rearmed.assessment.escalations.map(\.consequence) == [.destructive])
        }

        #expect(try String(contentsOf: output, encoding: .utf8) == "existing draft")
        #expect(!logStore.events.contains { $0.message.hasPrefix("risk.rearmed") })
    }

    /// The re-arm is one extra question, not a loop: answering the re-armed prompt executes, and
    /// the consent recorded from it covers the destructive reason it named.
    @Test
    func answeringTheReArmedPromptExecutes() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("notes.md")
        let runner = AgentRunner(planner: UnusedPlanner(), executor: makeExecutor(root: root))
        let prepared = try runner.prepare(plan: draftPlan(output: output))
        try "existing draft".write(to: output, atomically: true, encoding: .utf8)

        var rearmed: RiskApprovalRequest?
        do {
            _ = try await runner.execute(
                prepared,
                approvalDecision: .notRequested,
                scope: .unscoped,
                context: ApprovalContext(safeMode: false)
            )
            Issue.record("Expected the destructive escalation to stop the run.")
        } catch RiskApprovalError.approvalRequired(let request) {
            rearmed = request
        }

        let answered = try #require(rearmed)
        _ = try await runner.execute(
            prepared,
            approvalDecision: .approved(answering: answered),
            scope: .unscoped,
            context: ApprovalContext(safeMode: false)
        )

        #expect(try String(contentsOf: output, encoding: .utf8) != "existing draft")
    }

    // MARK: - The removed public paths stay removed

    /// The two wrappers SONNY-97 removed (`CapabilityRiskAssessment.approvalRequirement(policy:)`
    /// and `CapabilityRiskTier.approvalRequirement(policy:)`) must not be reintroduced under their
    /// old name anywhere in `Sources/` or `Tests/`. The demotion of the tier-only
    /// `RiskApprovalPolicy.requirement(for:)` to `private` is compiler-enforced and needs no
    /// sweep; this sweep exists because a *new* function under the old name would compile fine and
    /// quietly become a second public path. Comment-stripped, so prose recording what was removed
    /// does not fail the test that pins the removal.
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
        classes: [CapabilityRiskEscalation.Consequence],
        verdict: ScopeVerdict? = nil
    ) -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(
            defaultTier: tier,
            // Forced, so a case can pin a (tier, classes) combination the derivation would not
            // produce on its own — the defense-in-depth cells are exactly those.
            effectiveTier: tier,
            escalations: classes.enumerated().map { index, consequence in
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier3,
                    reason: "Reason \(index).",
                    consequence: consequence
                )
            },
            scopeVerdict: verdict
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
            .appendingPathComponent("ConsequenceRuleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutor(
        root: URL,
        routineStore: RoutineStore? = nil,
        workspaceStore: WorkspaceStore? = nil,
        snippetStore: SnippetStore? = nil,
        whitelist: PathWhitelist? = nil
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: whitelist ?? PathWhitelist(roots: [root]),
            appOpener: UnusedAppOpener(),
            fileOpener: UnusedFileOpener(),
            routineStore: routineStore ?? RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: workspaceStore ?? WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            snippetStore: snippetStore ?? SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-history.json")
            )
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

    private func draftPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Create local draft.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Create draft.",
                    outputPath: output.path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )
    }

    private func largestPlan(root: URL, output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Zip largest files.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "scan",
                    operation: .scanSelectLargestFiles,
                    description: "Scan files.",
                    inputPath: root.path,
                    count: 3
                ),
                AgentStep(
                    id: "zip",
                    operation: .createZip,
                    description: "Zip files.",
                    inputPath: root.path,
                    outputPath: output.path,
                    count: 3
                )
            ]
        )
    }

    private func webMarkdownPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Summarize web article as Markdown.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "web",
                    operation: .webToMarkdown,
                    description: "Create web Markdown.",
                    outputPath: output.path,
                    targetURL: "https://example.com/article"
                )
            ]
        )
    }

    private func saveRoutinePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: name,
                    routineSteps: openAppPlan().steps
                )
            ]
        )
    }

    private func createWorkspacePlan(name: String) -> AgentPlan {
        AgentPlan(
            summary: "Create workspace.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "create-workspace",
                    operation: .createWorkspace,
                    description: "Create workspace.",
                    workspaceName: name,
                    workspaceApps: ["Safari"],
                    workspaceURLs: ["https://github.com"]
                )
            ]
        )
    }

    private func saveSnippetPlan(trigger: String, expansion: String) -> AgentPlan {
        AgentPlan(
            summary: "Save snippet \(trigger).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "snippet",
                    operation: .saveSnippet,
                    description: "Save snippet \(trigger).",
                    searchQuery: trigger,
                    draftContent: expansion
                )
            ]
        )
    }
}

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
