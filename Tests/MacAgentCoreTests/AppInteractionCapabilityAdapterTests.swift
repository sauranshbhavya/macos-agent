import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

@MainActor
struct AppInteractionCapabilityAdapterTests {
    private static func step(
        app: String? = "Notes",
        goal: String? = "A new note that says buy milk",
        target: String? = nil,
        text: String? = "Buy milk\nEggs"
    ) -> AgentStep {
        AgentStep(
            id: "note",
            operation: .interactWithApp,
            description: "New note in Notes",
            appName: app,
            interactionGoal: goal,
            interactionTarget: target,
            interactionText: text
        )
    }

    private static func plan(_ steps: [AgentStep]) -> AgentPlan {
        AgentPlan(summary: "New note", requiresConfirmation: false, steps: steps)
    }

    @Test
    func thePlannersStepDecodesWithItsFields() throws {
        var step: [String: Any] = [:]
        step["id"] = "note"
        step["operation"] = "interact_with_app"
        step["description"] = "New note in Notes"
        step["appName"] = "Notes"
        step["interactionGoal"] = "A new note that says buy milk"
        step["interactionTarget"] = NSNull()
        step["interactionText"] = "Buy milk\nEggs"
        let json: [String: Any] = ["summary": "New note", "requiresConfirmation": false, "itemJob": NSNull(), "steps": [step]]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try AgentPlanDecoder.decodeStrict(from: data)
        let goal = try #require(try AppInteractionCapabilityAdapter.standaloneGoal(in: decoded))
        #expect(goal.app == "Notes")
        #expect(goal.target == nil)
        // A note may run over several lines: the text is set as a value, and no Return is pressed.
        #expect(goal.text == "Buy milk\nEggs")
    }

    /// Founders, 2026-09-24: a new note goes in whichever folder is open, so a named folder or note
    /// is asked about rather than dropped, and a note with nothing to say is asked about too.
    @Test
    func aNamedFolderOrAMissingTextBecomesAQuestionBeforeAnythingRuns() throws {
        let adapter = AppInteractionCapabilityAdapter()
        let context = VisionTestContext.make(installed: [])
        func question(_ step: AgentStep) throws -> String? {
            try adapter.resolveDefaultOutputs(in: Self.plan([step]), context: context).steps.first?.question
        }
        #expect(try question(Self.step(target: "Work")) == "I can only put a new note in the folder that's open in Notes. Should I make it there?")
        #expect(try question(Self.step(text: nil)) == "What should the note say?")
        #expect(try question(Self.step(app: nil)) == "Which app should I use?")

        let fine = Self.plan([Self.step()])
        #expect(try adapter.resolveDefaultOutputs(in: fine, context: context) == fine)
    }

    @Test
    func thePreviewNamesTheAppAndTheNotesText() throws {
        let previews = try AppInteractionCapabilityAdapter().preview(
            plan: Self.plan([Self.step()]),
            context: VisionTestContext.make(installed: [])
        )
        #expect(previews.map(\.title) == ["New note in Notes"])
        #expect(previews.first?.details == ["App: Notes", "New note: Buy milk\nEggs"])
    }

    @Test
    func onlyAPlanOfThisStepAloneGoesToTheNewRuntime() throws {
        #expect(try AppInteractionCapabilityAdapter.standaloneGoal(in: Self.plan([Self.step()])) != nil)
        let mixed = Self.plan([
            AgentStep(id: "open", operation: .openApp, description: "Open Safari", appName: "Safari"),
            Self.step(),
        ])
        #expect(try AppInteractionCapabilityAdapter.standaloneGoal(in: mixed) == nil)
        let other = Self.plan([AgentStep(id: "open", operation: .openApp, description: "Open Safari", appName: "Safari")])
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
