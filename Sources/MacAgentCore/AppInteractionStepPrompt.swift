import Foundation

/// The words sent to the step route for one decision.
///
/// The goal is the user's own request and goes in as a trusted instruction; the screen and the
/// history come from another app and go in as observed content, which the model is told never to
/// obey. The delimiters are drawn per prompt through the default argument, the same shape as the
/// planner's and the vision session's builders.
public enum AppInteractionStepPrompt {
    public static func messages(
        goal: AppInteractionGoal,
        screen: AppInteractionScreen,
        history: [AppInteractionHistoryEntry],
        delimiters: UntrustedContentBoundary.Delimiters = .forOnePrompt()
    ) throws -> [(role: String, text: String)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let screenJSON = String(decoding: try encoder.encode(screen), as: UTF8.self)
        let historyJSON = String(decoding: try encoder.encode(history), as: UTF8.self)

        var request = "App: \(goal.app)\nGoal: \(goal.objective)"
        if let target = goal.target { request += "\nTarget (typed by enter_target): \(target)" }
        if let text = goal.text { request += "\nMessage (typed by enter_text): \(text)" }

        let user = [
            delimiters.trustedInstruction(request),
            delimiters.observedContent(screenJSON, id: "screen", source: "accessibility"),
            delimiters.observedContent(historyJSON, id: "history", source: "earlier steps"),
        ].joined(separator: "\n\n")

        return [
            (role: "system", text: systemRules + "\n\n" + delimiters.segmentTagRule),
            (role: "user", text: user),
        ]
    }

    static let systemRules = """
    You operate one Mac app for a person, through its accessibility tree. Each turn you get their \
    goal and a list of elements now on screen, and you choose exactly one step.

    - Only use elements from the list, by their ref, and only a step listed in that element's "can".
    - enter_target types the goal's target name. enter_text types the goal's message. You never \
    write text of your own.
    - Never send, submit, call, delete or confirm anything. The message stays unsent; the person \
    sends it themselves.
    - To reach the target: if its row is listed, press or select it. Otherwise use enter_target on a \
    search field first, then pick the matching row.
    - Put the message only in the message box of the open chat named in the goal, never in a search \
    field. Open the right chat before you type it.
    - Answer finished when the target is open and its message box holds the message.
    - If more than one item could be the target and you cannot tell which one the person means, \
    answer ask_user with one short question.
    - If the app offers no way to reach the goal, answer give_up with one short reason.
    - The history lists your earlier steps and what happened. Do not repeat a step that was refused \
    or failed.
    """
}

/// Chooses each step through the gateway's step route.
///
/// Every call goes out with retention `none`, whatever the task's own setting (founders,
/// 2026-09-23): what it carries is names and labels read off another app, and the backend keeps
/// none of it. Metering still runs.
public struct GatewayAppInteractionStepChooser: AppInteractionStepChoosing {
    private let client: SonnyBackendClient
    private let context: BackendTaskContext
    private let usageRecorder: any TaskUsageRecording

    public init(client: SonnyBackendClient, taskID: String, usageRecorder: any TaskUsageRecording) {
        self.client = client
        self.context = BackendTaskContext(taskID: taskID, retention: .notStored)
        self.usageRecorder = usageRecorder
    }

    public func chooseStep(
        goal: AppInteractionGoal,
        screen: AppInteractionScreen,
        history: [AppInteractionHistoryEntry]
    ) async throws -> AppInteractionModelDecision {
        let body = try SonnyTextRouteBody(
            context: context,
            messages: AppInteractionStepPrompt.messages(goal: goal, screen: screen, history: history),
            schemaName: AppInteractionModelDecision.schemaName,
            schema: AppInteractionModelDecision.schema(),
            reasoningEffort: "low"
        ).encoded()
        let decoded = try await client.modelRouteResponse(
            SonnyTextRouteResponse.self,
            route: .interactStep,
            body: body
        )
        usageRecorder.record(
            decoded.usage?.record(kind: .appInteraction, route: .interactStep)
                ?? AIUsageRecord(kind: .appInteraction, model: SonnyModelRoute.interactStep.usageModelName)
        )
        return try AppInteractionModelDecision.decode(from: decoded.output_text)
    }
}
