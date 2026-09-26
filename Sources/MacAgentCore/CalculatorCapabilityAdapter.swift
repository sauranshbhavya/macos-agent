import Foundation

public struct CalculatorCapabilityAdapter: CapabilityAdapter {
    public init(calculator: CalculatorService = CalculatorService()) {
        self.calculator = calculator
    }

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.calculator",
        displayName: "Calculator",
        description: "Evaluate arithmetic and common unit conversions locally without the model planner.",
        operations: [.calculateUtility],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )

    private let calculator: CalculatorService

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let evaluation = try evaluation(in: plan)
        return [
            ActionPreview(
                title: "Calculate",
                details: [
                    "Expression: \(evaluation.expression)",
                    "Result: \(evaluation.result)"
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
        let evaluation = try evaluation(in: plan)
        log(.act, "Calculating \(evaluation.expression)")
        log(.summarize, "Calculated result")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "\(evaluation.expression) = \(evaluation.result)."
        )
    }

    private func evaluation(in plan: AgentPlan) throws -> CalculatorEvaluation {
        guard let step = plan.steps.first(where: { $0.operation == .calculateUtility }) else {
            throw AgentExecutionError.invalidPlan("calculate_utility step is missing.")
        }
        return try calculator.evaluate(step.searchQuery ?? "")
    }
}
