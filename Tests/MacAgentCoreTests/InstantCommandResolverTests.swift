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

        let request = try runner.approvalRequest(
            for: prepared,
            logAssessment: true,
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(request.assessment.effectiveTier == .tier0)
        #expect(request.requirement == .autoRun)

        let result = try await runner.execute(
            prepared,
            confirmationMessage: "Instant calculator auto-run",
            scope: .unscoped,
            context: ApprovalContext(mode: .normal, appControl: .notApplicable)
        )
        #expect(result.summary == "2 + 2 * 3 = 8.")
        #expect(usageRecorder.snapshot().requestCount == 0)
        #expect(logStore.events.contains { $0.phase == .plan && $0.message == "Resolved command locally" })
        #expect(logStore.events.contains { $0.phase == .risk && $0.message.contains("risk.assessed: Tier 0") })
    }

    /// The sign a person types at the end of a sum (SONNY-281). `2 + 2` was answered here and
    /// `2 + 2 =` was not — the trailing sign fell outside the bare-arithmetic rule's character set,
    /// and the sum reached a planner that has no calculator to offer. The rule now reads the sum the
    /// way the evaluator will, and the plan carries that form so its own summary says `2 + 2`.
    @Test
    func bareArithmeticWithATrailingEqualsSignResolvesToTheCalculator() throws {
        let resolver = InstantCommandResolver()

        for command in ["2 + 2 =", "2 + 2 = ", "2+2=", "2 + 2 = ?", "2 + 2?"] {
            guard case .plan(let plan) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to resolve locally as a sum.")
                continue
            }
            let sum = CalculatorService.withoutTrailingEqualsOrQuestionMark(command)
            #expect(plan.steps.map(\.operation) == [.calculateUtility])
            #expect(plan.steps[0].searchQuery == sum)
            #expect(plan.summary == "Calculate \(sum).")
        }

        // The prefixed forms drop it too, so their plan reads the same as the bare one.
        for command in ["= 2 + 2 =", "calc 2 + 2 =", "Calculate 2 + 2 ?"] {
            guard case .plan(let prefixed) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to resolve locally as a sum.")
                continue
            }
            #expect(prefixed.steps[0].searchQuery == "2 + 2")
        }

        // A conversion may end the same way.
        guard case .plan(let conversion) = resolver.resolve(command: "10 cm to in =") else {
            Issue.record("Expected the conversion to resolve locally.")
            return
        }
        #expect(conversion.steps[0].searchQuery == "10 cm to in")

        // An interior sign is a statement, not a sum, and stays the planner's.
        #expect(resolver.resolve(command: "2 + 2 = 4") == nil)

        // The sign alone is still the question it always was, not a sum of nothing — and so is a
        // sign with nothing but signs after it, which used to plan a calculation of `=`.
        for command in ["=", "= =", "=?"] {
            guard case .clarify(let question) = resolver.resolve(command: command) else {
                Issue.record("Expected \(command.debugDescription) to ask what to calculate.")
                continue
            }
            #expect(question.steps[0].question == "What would you like me to calculate?")
        }
    }
}

private struct FailingPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("Planner should not be called for an instant calculator command.")
        throw PlannerError.missingAPIKey
    }
}
