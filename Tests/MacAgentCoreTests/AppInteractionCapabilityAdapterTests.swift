import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@MainActor
struct AppInteractionCapabilityAdapterTests {
    private static func step(
        app: String? = "WhatsApp",
        goal: String? = "Open the chat with Mom and leave the message unsent",
        target: String? = "Mom",
        text: String? = "Running late, home by 8"
    ) -> AgentStep {
        AgentStep(
            id: "draft",
            operation: .interactWithApp,
            description: "Draft to Mom",
            appName: app,
            interactionGoal: goal,
            interactionTarget: target,
            interactionText: text
        )
    }

    private static func plan(_ steps: [AgentStep]) -> AgentPlan {
        AgentPlan(summary: "Draft", requiresConfirmation: false, steps: steps)
    }

    @Test
    func thePlannersStepDecodesWithItsThreeFields() throws {
        var step: [String: Any] = [:]
        step["id"] = "draft"
        step["operation"] = "interact_with_app"
        step["description"] = "Draft to Mom"
        step["appName"] = "WhatsApp"
        step["interactionGoal"] = "Open the chat with Mom and leave the message unsent"
        step["interactionTarget"] = "Mom"
        step["interactionText"] = "Running late"
        let json: [String: Any] = ["summary": "Draft", "requiresConfirmation": false, "itemJob": NSNull(), "steps": [step]]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try AgentPlanDecoder.decodeStrict(from: data)
        let goal = try #require(try AppInteractionCapabilityAdapter.standaloneGoal(in: decoded))
        #expect(goal.app == "WhatsApp")
        #expect(goal.target == "Mom")
        #expect(goal.text == "Running late")
    }

    @Test
    func aMessageWithALineBreakBecomesAQuestionBeforeAnythingRuns() throws {
        let adapter = AppInteractionCapabilityAdapter()
        let resolved = try adapter.resolveDefaultOutputs(
            in: Self.plan([Self.step(text: "one\ntwo")]),
            context: VisionTestContext.make(installed: [])
        )
        #expect(resolved.steps.map(\.operation) == [.clarify])
        #expect(resolved.steps.first?.question == "I can only draft a message on one line for now. What should it say?")

        let noApp = try adapter.resolveDefaultOutputs(
            in: Self.plan([Self.step(app: nil)]),
            context: VisionTestContext.make(installed: [])
        )
        #expect(noApp.steps.first?.question == "Which app should I draft this in?")

        let fine = Self.plan([Self.step()])
        #expect(try adapter.resolveDefaultOutputs(in: fine, context: VisionTestContext.make(installed: [])) == fine)
    }

    @Test
    func thePreviewNamesTheAppTheChatAndTheUnsentText() throws {
        let previews = try AppInteractionCapabilityAdapter().preview(
            plan: Self.plan([Self.step()]),
            context: VisionTestContext.make(installed: [])
        )
        #expect(previews.map(\.title) == ["Draft in WhatsApp"])
        #expect(previews.first?.details == ["App: WhatsApp", "Open: Mom", "Leave unsent: Running late, home by 8"])
    }

    @Test
    func onlyAPlanOfThisStepAloneGoesToTheNewRuntime() throws {
        #expect(try AppInteractionCapabilityAdapter.standaloneGoal(in: Self.plan([Self.step()])) != nil)
        let mixed = Self.plan([
            AgentStep(id: "open", operation: .openApp, description: "Open Notes", appName: "Notes"),
            Self.step(),
        ])
        #expect(try AppInteractionCapabilityAdapter.standaloneGoal(in: mixed) == nil)
        let other = Self.plan([AgentStep(id: "open", operation: .openApp, description: "Open Notes", appName: "Notes")])
        #expect(try AppInteractionCapabilityAdapter.standaloneGoal(in: other) == nil)
    }

    @Test
    func theStepInsideAMixedPlanIsRefusedPlainlyRatherThanRunOnTheOldPath() async throws {
        await #expect(throws: AppInteractionPlanError.notAlone) {
            try await AppInteractionCapabilityAdapter().execute(
                plan: Self.plan([Self.step()]),
                context: VisionTestContext.make(installed: []),
                log: { _, _ in }
            )
        }
    }

    @Test
    func itIsTierTwoAndAsksNothing() throws {
        let assessment = try AppInteractionCapabilityAdapter().assessRisk(
            plan: Self.plan([Self.step()]),
            context: VisionTestContext.make(installed: [])
        )
        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.escalations.isEmpty)
    }
}
