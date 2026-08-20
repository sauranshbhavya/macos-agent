import Foundation

public struct SaveRoutineCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.routines.save",
        displayName: "Teach Sonny a routine",
        description: "Save a named declarative routine made from registered Sonny tools.",
        operations: [.saveRoutine],
        plannerTools: [
            AgentTool(
                operation: .saveRoutine,
                name: "Teach Sonny a routine",
                description: "Save a named routine made from nested registered routineSteps. Routines are declarative local plans, not scripts.",
                requiredFields: ["routineName", "routineSteps"],
                sideEffects: ["write local routine file"],
                dryRunBehavior: "Show the routine name and nested steps without saving.",
                examples: ["Teach Sonny a routine called morning setup that opens Safari and Notes"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try routineSaveSpec(plan, context: context)
        let nestedPreview = try context.previewNestedPlan(spec.routine.plan)
        return [
            ActionPreview(
                title: "Save routine \(spec.routine.name)",
                details: ["Steps: \(spec.routine.steps.count)"] + nestedPreview.map { "Will include: \($0.title)" },
                writes: [context.routineStore.fileURL.path]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try routineSaveSpec(plan, context: context)
        // `.unscoped`, deliberately, and this is the whole of the decision: **saving a routine is
        // scope-neutral.** Saving touches one file inside Sonny's own store; the routine's steps are
        // scoped when it actually runs, which is what `PlanScopedResources`' `.saveRoutine` case
        // already says and why that classifier reports no resources for the operation. Forwarding
        // the caller's scope here reintroduced exactly what the classifier declined, one layer up:
        // "teach Sonny a routine that opens example.com" inside a workspace escalated to tier 3 and
        // prompted about a URL nothing in the plan would open — a prompt with no action behind it,
        // which is the kind that trains people to click through the ones that matter.
        //
        // The nested assessment is still needed for tier and escalations (a routine that would
        // overwrite an existing file still raises the save), so it is the *scope* that is dropped
        // here, not the assessment. Because it is unscoped, `nested.scopeVerdict` is `nil` and the
        // rebuilt assessment below cannot ship a roll-up that contradicts its own escalations.
        let nested = try context.assessNestedPlan(spec.routine.plan, .unscoped)
        let defaultTier = highestTier(metadata.defaultRiskTier, nested.defaultTier)

        var escalations = nested.escalations.map(Self.reframedAsWhenRunAdvisory)
        var effectiveTier = highestTier(defaultTier, nested.effectiveTier)
        // Plain `try`, never `try?` — see `CreateWorkspaceCapabilityAdapter.assessRisk` for the full
        // reasoning. In short: `try?` made an unreadable store answer the same as an empty one, which
        // suppressed this tier-3 escalation for exactly the user who most needed it, and
        // `RoutineStore.save` loads before it writes so the save being gated could not have succeeded
        // either way (SONNY-30).
        if try context.routineStore.findRoutine(named: spec.routine.name) != nil {
            escalations.append(
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Routine named \(spec.routine.name) already exists and would be replaced.",
                    // Replace-on-save destroys the routine the user already built.
                    consequence: .destructive
                )
            )
            effectiveTier = highestTier(effectiveTier, .tier3)
        }

        return CapabilityRiskAssessment(
            defaultTier: defaultTier,
            effectiveTier: effectiveTier,
            escalations: escalations
        )
    }

    /// A folded escalation, reframed as the forward-looking advisory it always was (SONNY-33,
    /// founder decision 2026-08-04 — option (a) of three, with keep-the-fold-as-is and
    /// drop-the-signal both declined).
    ///
    /// The fold is true at assessment time and wrongly attributed. A nested plan's escalations
    /// describe what the *routine* will do the next time it runs; a save writes one file, the
    /// routine store's own. So "teach Sonny a routine that zips my largest files" raised a panel
    /// reading "Zip output already exists at …" about a zip this save will never write — a
    /// sentence about a consequence the button under it does not have. The signal stays because it
    /// is the only save-time warning that exists, and the tier math stays with it (the advisory has
    /// teeth: `effectiveTier` above still folds `nested.effectiveTier`, and the escalation keeps its
    /// `.destructive` class, so the panel still appears). Only the frame changes.
    ///
    /// **A generic wrapper, not a rewrite of each nested sentence.** Four adapters can reach this
    /// fold today — `SnippetSaveCapabilityAdapter`, `CreateLocalDraftCapabilityAdapter`,
    /// `LargestFilesZipCapabilityAdapter`, `WebResearchMarkdownCapabilityAdapter` — and a save
    /// adapter that knew all four sentence shapes would be a second copy of their copy, free to
    /// drift from it the way the planner's routine-exclusion sentence drifted from the store's own
    /// list (SONNY-74). The nested sentence is carried through verbatim after a colon for the same
    /// reason: lower-casing it into a "because …" clause would mean editing another adapter's words.
    ///
    /// **Applied per escalation rather than once per panel.** A save's escalations reach exactly two
    /// surfaces — `WidgetPermissionPanel` and `CommandCenterAttentionPanel` — and both join every
    /// reason into one paragraph, so a single header sentence would read better for the rare
    /// two-collision routine. It would also be a claim about those two call sites rather than about
    /// the value, false the first time anything renders one escalation on its own.
    /// (`AgentViewModel.scheduledRunPauseCause` is the third reader of escalation reasons and is
    /// *not* one of them: a scheduled occurrence prepares `RunRoutineCapabilityAdapter.plan(forRoutineNamed:)`,
    /// so nothing on that path ever reaches this adapter.)
    ///
    /// Only the *nested* escalations pass through here. The routine-name collision `assessRisk`
    /// appends is the save's own risk, correctly attributed already, and must keep its own frame.
    private static func reframedAsWhenRunAdvisory(
        _ escalation: CapabilityRiskEscalation
    ) -> CapabilityRiskEscalation {
        var reframed = escalation
        reframed.reason = "When run, this routine will need approval: \(escalation.reason)"
        return reframed
    }

    private func highestTier(_ first: CapabilityRiskTier, _ second: CapabilityRiskTier) -> CapabilityRiskTier {
        first.rawValue >= second.rawValue ? first : second
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try routineSaveSpec(plan, context: context)
        log(.act, "Saving routine \(spec.routine.name)")
        try context.routineStore.save(spec.routine)
        log(.summarize, "Saved routine")
        let summary = "Saved routine \(spec.routine.name) with \(spec.routine.steps.count) step(s)."
        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    private struct RoutineSaveSpec {
        var routine: StoredRoutine
    }

    @MainActor
    private func routineSaveSpec(_ plan: AgentPlan, context: CapabilityExecutionContext) throws -> RoutineSaveSpec {
        guard let step = plan.steps.first(where: { $0.operation == .saveRoutine }) else {
            throw AgentExecutionError.invalidPlan("save_routine step is missing.")
        }
        guard let name = step.routineName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AutomationStoreError.missingName("Routine")
        }
        guard let routineSteps = step.routineSteps, !routineSteps.isEmpty else {
            throw AutomationStoreError.emptyRoutine
        }

        try validateRoutineSteps(routineSteps, context: context)
        return RoutineSaveSpec(routine: StoredRoutine(name: name, steps: routineSteps))
    }

    /// The forbidden-operation list itself lives on `StoredRoutine`, not here, so that
    /// `RoutineStore.save` enforces the identical rule at the write choke point — this adapter is
    /// the door a *planner* comes through, not the only door (SONNY-52). What stays here is the
    /// part only a capability can do: previewing the nested plan, which needs an execution context
    /// the store has no access to, and which is why the store's check is a subset of this one
    /// rather than a replacement for it.
    @MainActor
    private func validateRoutineSteps(_ steps: [AgentStep], context: CapabilityExecutionContext) throws {
        try StoredRoutine.validateStepSafety(steps)

        _ = try context.previewNestedPlan(
            AgentPlan(summary: "Validate routine.", requiresConfirmation: true, steps: steps)
        )
    }
}
