import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// SONNY-48 — the user story the core was already built for and no product path could reach.
///
/// `StoredRoutine.forbiddenStepOperations` has always permitted a `save_snippet` step inside a
/// routine, and `SnippetSaveCapabilityAdapter.assessRisk` was written specifically so a *scheduled*
/// routine carrying one would not escalate itself into never running again (SONNY-31). But routines
/// are authored through `save_routine`, which only the planner emits, and the planner had no
/// snippet vocabulary at all — so the permission was a promise nothing could collect on, and asked
/// to teach such a routine Sonny correctly answered that it was not a supported step.
///
/// These assert the whole authoring path, not the tool string: the schema accepts the nested step,
/// a strict decode of a planner-shaped response keeps it, validation admits it, and the saved
/// routine really executes it.
@Suite
struct SnippetRoutineAuthoringTests {
    /// The end-to-end shape: a `save_routine` plan whose nested step saves a snippet is validated,
    /// stored with the step intact, and on running actually writes the snippet — which the instant
    /// resolver can then expand by exact trigger.
    @Test
    @MainActor
    func aRoutineContainingASnippetStepSavesAndThenActuallySavesTheSnippet() async throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let routineStore = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
        let executor = AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            routineStore: routineStore,
            workspaceStore: UnreachableLocalStores.workspaces(),
            clipboardHistoryStore: UnreachableLocalStores.clipboardHistory(),
            snippetStore: snippetStore,
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory()
        )
        let runner = AgentRunner(planner: UnusedPlanner(), executor: executor)

        let savePlan = AgentPlan(
            summary: "Teach routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "save-routine",
                    operation: .saveRoutine,
                    description: "Save routine.",
                    routineName: "Onboarding",
                    routineSteps: [
                        AgentStep(
                            id: "save-snippet",
                            operation: .saveSnippet,
                            description: "Save the welcome snippet.",
                            searchQuery: ";welcome",
                            draftContent: "Welcome aboard!"
                        )
                    ]
                )
            ]
        )

        let preparedSave = try runner.prepare(plan: savePlan, source: .planner)
        _ = try await runner.execute(preparedSave, approvalDecision: .approved(.tier2), scope: .unscoped, context: ApprovalContext(mode: .normal, appControl: .notApplicable))

        let saved = try routineStore.routine(named: "Onboarding")
        #expect(saved.steps.map(\.operation) == [.saveSnippet])
        #expect(saved.steps[0].searchQuery == ";welcome")
        #expect(saved.steps[0].draftContent == "Welcome aboard!")

        // Nothing is written until the routine runs — saving a routine is not running it.
        #expect(try snippetStore.findExactTrigger(";welcome") == nil)

        let runPlan = AgentPlan(
            summary: "Run routine.",
            requiresConfirmation: true,
            steps: [
                AgentStep(id: "run-routine", operation: .runRoutine, description: "Run routine.", routineName: "Onboarding")
            ]
        )
        let preparedRun = try runner.prepare(plan: runPlan, source: .planner)
        _ = try await runner.execute(preparedRun, approvalDecision: .approved(.tier2), scope: .unscoped, context: ApprovalContext(mode: .normal, appControl: .notApplicable))

        let stored = try #require(try snippetStore.findExactTrigger(";welcome"))
        #expect(stored.expansion == "Welcome aboard!")

        // And the snippet is now reachable the way snippets are reached — by typing the trigger.
        let resolver = InstantCommandResolver(
            snippetStore: snippetStore,
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            routineStore: routineStore,
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        )
        guard case .plan(let expansion)? = resolver.resolve(command: ";welcome") else {
            Issue.record("The saved trigger should expand through the instant resolver.")
            return
        }
        #expect(expansion.steps.map(\.operation) == [.expandSnippet])
    }

    /// The vocabulary end to end rather than as a prompt string: a planner-shaped JSON response
    /// carrying a nested `save_snippet` step survives `decodeStrict`, which is the layer that
    /// rejects anything outside the schema. A tool the decoder would throw on is not a tool.
    @Test
    func aPlannerResponseNestingASnippetStepDecodesStrictly() throws {
        let json = """
        {
          "summary": "Teach a routine that saves my welcome snippet.",
          "requiresConfirmation": true,
          "steps": [
            {
              "id": "save-routine",
              "operation": "save_routine",
              "description": "Save the onboarding routine.",
              "routineName": "Onboarding",
              "routineSteps": [
                {
                  "id": "save-snippet",
                  "operation": "save_snippet",
                  "description": "Save the welcome snippet.",
                  "searchQuery": ";welcome",
                  "draftContent": "Welcome aboard!",
                  "routineSteps": null
                }
              ]
            }
          ]
        }
        """

        let plan = try AgentPlanDecoder.decodeStrict(from: Data(json.utf8))
        #expect(plan.steps.map(\.operation) == [.saveRoutine])
        #expect(plan.steps[0].routineSteps?.map(\.operation) == [.saveSnippet])
        #expect(plan.steps[0].routineSteps?[0].searchQuery == ";welcome")
        #expect(plan.steps[0].routineSteps?[0].draftContent == "Welcome aboard!")
    }

    /// The boundary that stays. Expansion is still not a planner tool and still not in the schema:
    /// its execution returns the snippet's text as the run summary and types it nowhere, so a
    /// routine-nested expansion would produce text with no consumer. Asserted here, next to the
    /// operation that did become authorable, so the asymmetry reads as a decision rather than an
    /// oversight — which is the failure mode this ticket was filed about in the first place.
    @Test
    func snippetExpansionIsStillNotSomethingThePlannerCanAskFor() {
        #expect(!AgentOperation.plannerVisibleCases.contains(.expandSnippet))
        #expect(!ToolRegistry.default.tools.map(\.operation).contains(.expandSnippet))
        #expect(SnippetExpansionCapabilityAdapter.metadata.plannerTools.isEmpty)
        // Permitted by the routine validator all the same — that combination is exactly what this
        // ticket exists to make legible rather than accidental.
        #expect(!StoredRoutine.forbiddenStepOperations.contains(.expandSnippet))
        #expect(!StoredRoutine.forbiddenStepOperations.contains(.saveSnippet))
    }

    private static func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetRoutineAuthoringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct UnusedPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        Issue.record("These tests drive prebuilt plans; the planner must not be called.")
        throw PlannerError.noPlannerRan
    }
}
