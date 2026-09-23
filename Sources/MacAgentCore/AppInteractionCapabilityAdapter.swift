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
        displayName: "Draft in an app",
        description: "Open a chat or item by name in another app and leave text there unsent, through its accessibility tree.",
        operations: [.interactWithApp],
        plannerTools: [
            AgentTool(
                operation: .interactWithApp,
                name: "Draft in an app without sending",
                description: """
                Open a chat, contact or item by name inside a Mac app and leave text there, unsent. \
                Use this, and not vision_session, when the user asks to draft, write or prepare a \
                message without sending it. It never sends: when the user asks to send, use \
                vision_session as before. Use it as the plan's only step. Set appName to the app, \
                interactionGoal to the outcome in one sentence, interactionTarget to the chat or \
                contact name exactly as the user said it, and interactionText to the exact text to \
                leave. Never target a terminal app.
                """,
                requiredFields: ["appName", "interactionGoal"],
                sideEffects: [
                    "Types into the named app as the user would, and leaves the text unsent",
                    "Sends the names and labels in that app's window to Sonny's model, which stores none of it"
                ],
                dryRunBehavior: "Describe the app, the chat and the text; touch nothing.",
                examples: [
                    "draft a WhatsApp to Mom saying I'll be home by 8",
                    "write 'see you at 6' to Alex in WhatsApp but don't send it"
                ]
            )
        ],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .accessibilityControl)
        ],
        defaultRiskTier: .tier2
    )

    /// A goal that cannot be built is asked about before anything runs: the person can answer by
    /// saying it again, where a failure would make them start over.
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
            if let target = goal.target { details.append("Open: \(target)") }
            if let text = goal.text { details.append("Leave unsent: \(text)") }
            return ActionPreview(title: "Draft in \(goal.app)", details: details)
        }
    }

    /// Tier 2 with no escalation: the draft stays on the Mac until the person sends it (founders,
    /// 2026-09-23). What guards the rest is `AppInteractionPolicy`, which refuses every step that
    /// could send, delete or call.
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

    static func clarification(_ question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-app-interaction",
                    operation: .clarify,
                    description: "Ask a question before drafting in another app.",
                    question: question
                )
            ]
        )
    }

    public static func goal(from step: AgentStep) throws(AppInteractionGoalError) -> AppInteractionGoal {
        try AppInteractionGoal.validated(
            app: step.appName ?? "",
            objective: step.interactionGoal ?? "",
            target: step.interactionTarget,
            text: step.interactionText
        )
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
        "I can draft in another app only as a request on its own. Ask for the draft by itself."
    }
}

extension AppInteractionGoalError {
    /// The same fault as `userMessage`, put as the question that fixes it.
    var clarifyingQuestion: String {
        switch self {
        case .missingApp: return "Which app should I draft this in?"
        case .missingObjective, .nothingToDo: return "Who is it for, and what should it say?"
        case .objectiveTooLong: return "Can you say that more briefly?"
        case .targetTooLong, .targetHasLineBreak: return "What's the name of the chat, on one line?"
        case .textTooLong: return "That's longer than \(AppInteractionGoal.maxTextLength) characters. What shorter message should I draft?"
        case .textHasLineBreak: return "I can only draft a message on one line for now. What should it say?"
        }
    }
}
