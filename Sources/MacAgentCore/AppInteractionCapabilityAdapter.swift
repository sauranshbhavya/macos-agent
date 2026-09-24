import Foundation

/// Plans, previews and assesses `interact_with_app` (SONNY-544, V2 plan Milestone A).
///
/// It does not run the step: a plan whose only step is this one is handed to
/// `AppInteractionRuntime` before `AgentRunner.execute` is reached, so the new path has one owner.
/// `execute` here refuses, which is what a plan mixing this step with others meets — a plain
/// message rather than half the plan on each path.
public struct AppInteractionCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata { Self.metadata }

    public static let metadata = CapabilityMetadata(
        id: "local.accessibility.interact",
        displayName: "New note in Notes",
        description: "Make a new note in the Notes app holding the given text, through its accessibility tree.",
        operations: [.interactWithApp],
        plannerTools: [
            AgentTool(
                operation: .interactWithApp,
                name: "Make a new note in the Notes app",
                description: """
                Start a new note in the Notes app, in whichever folder is open there, and put the \
                user's text in it. Use this only when the user names the Notes app: "make a note \
                in Notes", "add a note to Notes". A note request that does not name the Notes app \
                stays with create_local_draft, and every other app stays with its own operation. \
                Use it as the plan's only step. Set appName to Notes, interactionGoal to the outcome \
                in one sentence, interactionTarget to null, and interactionText to the note's text \
                word for word; it may run over several lines.
                """,
                requiredFields: ["appName", "interactionGoal", "interactionText"],
                sideEffects: [
                    "Starts a new note in the folder open in Notes and puts the text in it",
                    "Sends the labels of the Notes window's controls to Sonny's model, which stores none of it; never the text of any note"
                ],
                dryRunBehavior: "Describe the app and the note's text; touch nothing.",
                examples: [
                    "make a note in Notes saying buy milk and eggs",
                    "add a note to Notes: call the dentist on Monday"
                ]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .accessibilityControl)
        ],
        defaultRiskTier: .tier2
    )

    /// A goal that cannot be built is asked about before anything runs: the person can answer by
    /// saying it again, where a failure would make them start over. A plan mixing the step with
    /// others is asked about too, by `AgentActionExecutor.prepare`, which sees the whole plan where
    /// this sees only its own segment.
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        for step in plan.steps where step.operation == .interactWithApp {
            do {
                _ = try Self.goal(from: step)
            } catch {
                return Self.clarification(error.clarifyingQuestion)
            }
        }
        return plan
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        try plan.steps.filter { $0.operation == .interactWithApp }.map { step in
            let goal = try Self.goal(from: step)
            var details = ["App: \(goal.app)"]
            if let text = goal.text { details.append("New note: \(text)") }
            return ActionPreview(title: "New note in \(goal.app)", details: details)
        }
    }

    /// Tier 2 with no escalation: a new note changes nothing that was there before, and nothing
    /// leaves the Mac beyond what Notes already syncs (founders, 2026-09-23 and 2026-09-24). What
    /// guards the rest is `AppInteractionPolicy`, which refuses every step that could send, delete
    /// or call, and never writes over text Sonny did not put there.
    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        throw AppInteractionPlanError.notAlone
    }

    /// Asked by `AgentActionExecutor.prepare` of a plan that mixes this step with others.
    public static let aloneQuestion = "I can only make a note in Notes as a request on its own. Should I just make the note? Ask for the rest separately."

    static func clarification(_ question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-app-interaction",
                    operation: .clarify,
                    description: "Ask a question before working in another app.",
                    question: question
                )
            ]
        )
    }

    /// Milestone A's goal is a new note in whichever folder is open, so it has text and nothing to
    /// find. A named folder or note is asked about rather than dropped, because dropping it would
    /// put the note somewhere the person did not ask for (founders, 2026-09-24).
    public static func goal(from step: AgentStep) throws(AppInteractionGoalError) -> AppInteractionGoal {
        if let target = step.interactionTarget, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw .targetNotSupported
        }
        let goal = try AppInteractionGoal.validated(
            app: step.appName ?? "",
            objective: step.interactionGoal ?? "",
            target: nil,
            text: step.interactionText
        )
        guard goal.text != nil else { throw .nothingToDo }
        return goal
    }

    /// The goal of a plan the new runtime should run: exactly one step, and it is this operation.
    /// Nil for any other plan, which then runs on the existing path.
    public static func standaloneGoal(in plan: AgentPlan) throws(AppInteractionGoalError) -> AppInteractionGoal? {
        guard plan.steps.count == 1, let step = plan.steps.first, step.operation == .interactWithApp else {
            return nil
        }
        return try goal(from: step)
    }
}

public enum AppInteractionPlanError: Error, LocalizedError, Equatable {
    case notAlone

    public var errorDescription: String? {
        "I can make a note in Notes only as a request on its own. Ask for the note by itself."
    }
}

extension AppInteractionGoalError {
    /// The same fault as `userMessage`, put as the question that fixes it.
    var clarifyingQuestion: String {
        switch self {
        case .missingApp: return "Which app should I use?"
        case .missingObjective, .nothingToDo: return "What should the note say?"
        case .objectiveTooLong: return "Can you say that more briefly?"
        case .targetTooLong, .targetHasLineBreak: return "What's the name, on one line?"
        case .textTooLong: return "That's longer than \(AppInteractionGoal.maxTextLength) characters. What shorter note should I make?"
        case .targetNotSupported: return "I can only put a new note in the folder that's open in Notes. Should I make it there?"
        }
    }
}
