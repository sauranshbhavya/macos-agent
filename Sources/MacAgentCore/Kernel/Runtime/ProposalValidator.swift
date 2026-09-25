import Foundation

/// Decides which gateway messages a task may act on, and what each proposed action is.
///
/// Nothing the gateway sends is trusted: a message for another task, from an old connection, or
/// not newer than the last one accepted is dropped whole (V2 plan section 4, rule 4). An action the
/// Mac can't run is answered, not dropped, so the gateway can choose again.
public enum ProposalValidator {
    public enum EnvelopeVerdict: Sendable, Equatable {
        case accept
        case drop(String)
    }

    public static func check(
        _ address: TaskAddress?,
        task: TaskID,
        messageGeneration: UInt64,
        currentGeneration: UInt64,
        lastSeqIn: Int,
        taskIsOver: Bool
    ) -> EnvelopeVerdict {
        guard let address else { return .drop("a connection message reached a task") }
        guard address.task == task else { return .drop("the message is for another task") }
        guard messageGeneration == currentGeneration else { return .drop("the message came on an old connection") }
        guard address.seq > lastSeqIn else { return .drop("the message is not newer than the last one accepted") }
        guard !taskIsOver else { return .drop("the task is over") }
        return .accept
    }

    public enum Route: Sendable {
        case operation(any Capability, [String: JSONValue])
        case screen(ScreenAction)
        /// The Mac answers this action without running it.
        case answer(ActionResult)
    }

    public static func route(
        _ action: WireAction,
        capabilities: KernelCapabilities,
        screenTools: Set<ScreenToolName>
    ) -> Route {
        switch action.kind {
        case .operation(let call):
            guard let capability = capabilities.capability(name: call.name, version: call.version) else {
                return .answer(ActionResult(
                    actionID: action.actionID,
                    status: .refused,
                    effect: action.effect,
                    error: OutcomeError(
                        code: .unsupportedOperation,
                        message: "This Mac has no \(call.name) v\(call.version)."
                    )
                ))
            }
            return .operation(capability, call.args)
        case .screen(let screen):
            guard screenTools.contains(screen.tool) else {
                return .answer(ActionResult(
                    actionID: action.actionID,
                    status: .refused,
                    effect: action.effect,
                    error: OutcomeError(code: .unsupportedOperation, message: "This Mac can't \(screen.tool.rawValue) right now.")
                ))
            }
            return .screen(screen)
        }
    }

    /// Only the first action of a batch may do more than look or move around; the batch stops before
    /// any later action that would (V2 plan section 7.3).
    public static func batchMayContinue(index: Int, judged: Effect, previousJudged: [Effect]) -> Bool {
        if previousJudged.contains(where: { $0 > .navigate }) { return false }
        return index == 0 || judged <= .navigate
    }
}
