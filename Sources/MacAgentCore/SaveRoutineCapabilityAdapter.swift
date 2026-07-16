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
        let nested = try context.assessNestedPlan(spec.routine.plan)
        let defaultTier = highestTier(metadata.defaultRiskTier, nested.defaultTier)

        var escalations = nested.escalations
        var effectiveTier = highestTier(defaultTier, nested.effectiveTier)
        if (try? context.routineStore.routine(named: spec.routine.name)) != nil {
            escalations.append(
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Routine named \(spec.routine.name) already exists and would be replaced."
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

    @MainActor
    private func validateRoutineSteps(_ steps: [AgentStep], context: CapabilityExecutionContext) throws {
        for step in steps {
            switch step.operation {
            case .saveRoutine, .runRoutine, .createWorkspace, .openWorkspace, .clarify, .unsupported:
                throw AutomationStoreError.unsafeRoutineStep(step.operation.rawValue)
            default:
                break
            }

            if let nested = step.routineSteps, !nested.isEmpty {
                throw AutomationStoreError.unsafeRoutineStep("nested routineSteps")
            }
        }

        _ = try context.previewNestedPlan(
            AgentPlan(summary: "Validate routine.", requiresConfirmation: true, steps: steps)
        )
    }
}
