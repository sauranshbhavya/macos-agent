import Foundation

/// What the model answered for one step. Decoded strictly from its JSON; anything else is an
/// error, never a guess.
public enum AppInteractionModelDecision: Equatable, Sendable {
    case step(AppInteractionStepKind, ref: String)
    /// The model believes the goal is met. Sonny still checks for itself.
    case finished
    /// The model needs the person to choose, for example between two chats with the same name.
    case askUser(String)
    /// The model sees no way to reach the goal in this app.
    case giveUp(String)

    public static let schemaName = "app_interaction_step"

    /// Strict JSON schema for the step route: every key required, nulls where a key does not
    /// apply, no extra keys.
    public static func schema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["decision", "step", "ref", "message"],
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["act", "finished", "ask_user", "give_up"],
                    "description": "act to take one step; finished when the goal is met; ask_user when the person must choose; give_up when this app offers no way to reach the goal.",
                ],
                "step": [
                    "type": ["string", "null"],
                    "enum": (AppInteractionStepKind.allCases.map(\.rawValue) as [Any]) + [NSNull()],
                    "description": "For act: which step. Must be one the element lists under can. Null otherwise.",
                ],
                "ref": [
                    "type": ["string", "null"],
                    "description": "For act: the element's ref, exactly as given. Null otherwise.",
                ],
                "message": [
                    "type": ["string", "null"],
                    "description": "For ask_user: one short question for the person. For give_up: one short reason. Null otherwise.",
                ],
            ] as [String: Any],
        ]
    }

    private struct Wire: Decodable {
        let decision: String
        let step: String?
        let ref: String?
        let message: String?
    }

    public static func decode(from json: String) throws -> AppInteractionModelDecision {
        guard let data = json.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            throw AppInteractionDecisionError.malformed
        }
        let message = wire.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch wire.decision {
        case "act":
            guard let raw = wire.step, let kind = AppInteractionStepKind(rawValue: raw),
                  let ref = wire.ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else {
                throw AppInteractionDecisionError.malformed
            }
            return .step(kind, ref: ref)
        case "finished":
            return .finished
        case "ask_user":
            guard let message, !message.isEmpty else { throw AppInteractionDecisionError.malformed }
            return .askUser(message)
        case "give_up":
            guard let message, !message.isEmpty else { throw AppInteractionDecisionError.malformed }
            return .giveUp(message)
        default:
            throw AppInteractionDecisionError.malformed
        }
    }
}

public enum AppInteractionDecisionError: Error, Equatable, Sendable {
    case malformed
}

/// One line of what has happened so far, sent back to the model so it does not repeat a step
/// that already failed.
public struct AppInteractionHistoryEntry: Equatable, Sendable, Encodable {
    public let did: String
    public let result: String

    public init(did: String, result: String) {
        self.did = did
        self.result = result
    }
}

/// Chooses the next step. The live implementation calls the gateway's step route.
public protocol AppInteractionStepChoosing: Sendable {
    func chooseStep(
        goal: AppInteractionGoal,
        screen: AppInteractionScreen,
        history: [AppInteractionHistoryEntry]
    ) async throws -> AppInteractionModelDecision
}
