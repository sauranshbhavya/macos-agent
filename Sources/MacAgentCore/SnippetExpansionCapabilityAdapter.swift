import Foundation

public struct SnippetExpansionCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.snippet-expansion",
        displayName: "Snippet expansion",
        description: "Expand an exact local snippet trigger without calling the model planner.",
        operations: [.expandSnippet],
        // Deliberately empty, and deliberately still empty after SONNY-48 gave `save_snippet` a
        // tool: expansion has no planner-shaped use. `execute` returns the snippet's text as the
        // run summary and types it nowhere, so a planned or routine-nested expansion produces text
        // with no consumer. The front door is the instant resolver's exact-trigger match, and
        // `PlannerBoundaryTests` asserts that door stays open for exactly the operations excluded
        // from the planner's schema — so this emptiness is checked, not merely intended.
        plannerTools: [],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let snippet = try snippet(in: plan, context: context)
        return [
            ActionPreview(
                title: "Expand snippet",
                details: [
                    "Trigger: \(snippet.trigger)",
                    "Expansion: \(snippet.expansion)"
                ]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let snippet = try snippet(in: plan, context: context)
        log(.act, "Expanding snippet \(snippet.trigger)")
        log(.summarize, "Snippet expanded")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: snippet.expansion
        )
    }

    private func snippet(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> StoredSnippet {
        guard let step = plan.steps.first(where: { $0.operation == .expandSnippet }) else {
            throw AgentExecutionError.invalidPlan("expand_snippet step is missing.")
        }
        return try context.snippetStore.snippet(matchingTrigger: step.searchQuery ?? "")
    }
}
