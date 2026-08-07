import Foundation
import Testing
@testable import MacAgentCore

@Suite
@MainActor
struct InstantCommandResolverTests {
    @Test
    func calculatorServiceEvaluatesArithmeticAndConversions() throws {
        let calculator = CalculatorService()

        #expect(try calculator.evaluate("2 + 2 * 3").result == "8")
        #expect(try calculator.evaluate("(2 + 2) * 3").result == "12")
        #expect(try calculator.evaluate("100 cm to m").result == "1 m")
        #expect(try calculator.evaluate("32 f to c").result == "0 C")
    }

    @Test
    func resolverBuildsCalculatorPlanForExplicitAndBareInputs() throws {
        let resolver = InstantCommandResolver()

        guard case .plan(let explicitPlan) = resolver.resolve(command: "calc 2 + 2") else {
            Issue.record("Expected explicit calculator command to resolve locally.")
            return
        }
        #expect(explicitPlan.steps.map(\.operation) == [.calculateUtility])
        #expect(explicitPlan.steps[0].searchQuery == "2 + 2")

        guard case .plan(let barePlan) = resolver.resolve(command: "10 cm to in") else {
            Issue.record("Expected bare conversion command to resolve locally.")
            return
        }
        #expect(barePlan.steps.map(\.operation) == [.calculateUtility])
        #expect(barePlan.steps[0].searchQuery == "10 cm to in")

        #expect(resolver.resolve(command: "Open Safari") == nil)
    }

    @Test
    func resolverClarifiesEmptyCalculatorCommand() throws {
        let resolver = InstantCommandResolver()

        guard case .clarify(let plan) = resolver.resolve(command: "calculate") else {
            Issue.record("Expected empty calculator command to ask a clarification.")
            return
        }

        #expect(plan.steps.map(\.operation) == [.clarify])
        #expect(plan.steps[0].question == "What would you like me to calculate?")
    }

    @Test
    func instantCalculatorBypassesPlannerButUsesRunnerRiskPipeline() async throws {
        let resolver = InstantCommandResolver()
        guard case .plan(let plan) = resolver.resolve(command: "calc 2 + 2 * 3") else {
            Issue.record("Expected calculator command to resolve locally.")
            return
        }

        let logStore = AgentLogStore()
        let usageRecorder = TaskUsageRecorder()
        let runner = AgentRunner(
            planner: FailingPlanner(),
            executor: AgentActionExecutor(usageRecorder: usageRecorder),
            logStore: logStore
        )

        let prepared = try runner.prepare(plan: plan, source: .instantResolver)
        #expect(prepared.previews.first?.title == "Calculate")
        #expect(prepared.previews.first?.details.contains("Result: 8") == true)

        let request = try runner.approvalRequest(for: prepared, logAssessment: true, scope: .unscoped)
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(prepared, confirmationMessage: "Instant calculator auto-run", scope: .unscoped)
        #expect(result.summary == "2 + 2 * 3 = 8.")
        #expect(usageRecorder.snapshot().requestCount == 0)
        #expect(logStore.events.contains { $0.phase == .plan && $0.message == "Resolved command locally" })
        #expect(logStore.events.contains { $0.phase == .risk && $0.message.contains("risk.assessed: Tier 0") })
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for an instant calculator command.")
        throw PlannerError.missingAPIKey
    }
}
