import Foundation

public struct RunRoutineCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.routines.run",
        displayName: "Run saved routine",
        description: "Load and run a saved routine through normal plan validation.",
        operations: [.runRoutine],
        plannerTools: [
            AgentTool(
                operation: .runRoutine,
                name: "Run saved routine",
                description: "Load a saved routine by name and execute its registered steps with the same validation and logging as normal plans. Use only when the user names a routine they have actually saved; do not infer a routine name from vague activity phrasing such as \"start my day\" — ask a clarifying question instead.",
                requiredFields: ["routineName"],
                sideEffects: ["depends on saved routine"],
                dryRunBehavior: "Preview the saved routine without executing its steps.",
                examples: ["Run my morning setup routine"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let routine = try routineRunSpec(plan, context: context)
        let nested = try context.previewNestedPlan(routine.plan)
        return [headerPreview(for: routine)] + nested
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let routine = try routineRunSpec(plan, context: context)
        let nested = try context.assessNestedPlan(routine.plan)
        let defaultTier = highestTier(metadata.defaultRiskTier, nested.defaultTier)
        return CapabilityRiskAssessment(
            defaultTier: defaultTier,
            effectiveTier: highestTier(defaultTier, nested.effectiveTier),
            escalations: nested.escalations
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let routine = try routineRunSpec(plan, context: context)
        log(.act, "Running routine \(routine.name)")
        let result = try await context.executeNestedPlan(routine.plan, log)
        // Return the nested execution's real previews — re-deriving them here would re-resolve
        // default output paths (fresh timestamps) and report files that were never written.
        return AgentRunResult(
            plan: plan,
            previews: [headerPreview(for: routine)] + result.previews,
            summary: "Ran routine \(routine.name). \(result.summary)",
            suggestions: result.suggestions
        )
    }

    private func headerPreview(for routine: StoredRoutine) -> ActionPreview {
        ActionPreview(
            title: "Run routine \(routine.name)",
            details: ["Saved steps: \(routine.steps.count)"]
        )
    }

    private func routineRunSpec(_ plan: AgentPlan, context: CapabilityExecutionContext) throws -> StoredRoutine {
        guard let step = plan.steps.first(where: { $0.operation == .runRoutine }) else {
            throw AgentExecutionError.invalidPlan("run_routine step is missing.")
        }
        return try context.routineStore.routine(named: step.routineName ?? "")
    }

    private func highestTier(_ first: CapabilityRiskTier, _ second: CapabilityRiskTier) -> CapabilityRiskTier {
        first.rawValue >= second.rawValue ? first : second
    }
}
