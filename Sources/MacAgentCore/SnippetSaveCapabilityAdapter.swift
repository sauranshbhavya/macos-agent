import Foundation

public struct SnippetSaveCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.snippet-save",
        displayName: "Save snippet",
        description: "Save an exact local snippet trigger without calling the model planner.",
        operations: [.saveSnippet],
        plannerTools: [],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try snippetSpec(in: plan)
        return [
            ActionPreview(
                title: "Save snippet",
                details: [
                    "Trigger: \(spec.trigger)",
                    "Expansion: \(spec.expansion)"
                ],
                writes: [context.snippetStore.fileURL.path]
            )
        ]
    }

    /// Escalates when saving this snippet would replace *different* text — not merely when the
    /// trigger exists.
    ///
    /// Re-saving byte-identical content is semantically a no-op: the file ends up holding exactly
    /// what it already held, so "would be replaced" is not true of anything the user would
    /// recognise as their snippet. The old existence-only check made a scheduled routine
    /// containing a `save_snippet` step run exactly once — run one created the trigger, and every
    /// run after that assessed tier 3, which an unattended run structurally cannot satisfy, so the
    /// routine was skipped forever (SONNY-31).
    ///
    /// Compared against the trimmed spec expansion because that is what `execute` writes and what
    /// `SnippetStore.save` stores — comparing raw step text against a stored trimmed value would
    /// make a trailing newline in the plan look like a content change and re-open the same hole.
    /// `updatedAt` is deliberately not part of the comparison: the timestamp moves on every save
    /// by design, and treating that as a change would mean nothing was ever identical.
    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let spec = try snippetSpec(in: plan)
        let existing = try context.snippetStore.findExactTrigger(spec.trigger)
        let replacesDifferentExpansion = existing.map { $0.expansion != spec.expansion } ?? false
        let escalations = replacesDifferentExpansion
            ? [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Snippet trigger \(spec.trigger) already exists and would be replaced."
                )
            ]
            : []
        return CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier, escalations: escalations)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try snippetSpec(in: plan)
        log(.act, "Saving snippet \(spec.trigger)")
        try context.snippetStore.save(
            StoredSnippet(
                trigger: spec.trigger,
                expansion: spec.expansion,
                updatedAt: context.now()
            )
        )
        log(.summarize, "Snippet saved")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Saved snippet \(spec.trigger)."
        )
    }

    private struct SnippetSpec {
        var trigger: String
        var expansion: String
    }

    private func snippetSpec(in plan: AgentPlan) throws -> SnippetSpec {
        guard let step = plan.steps.first(where: { $0.operation == .saveSnippet }) else {
            throw AgentExecutionError.invalidPlan("save_snippet step is missing.")
        }
        let trigger = step.searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expansion = step.draftContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trigger.isEmpty else {
            throw SnippetStoreError.missingTrigger
        }
        guard !expansion.isEmpty else {
            throw SnippetStoreError.missingExpansion
        }
        return SnippetSpec(trigger: trigger, expansion: expansion)
    }
}
