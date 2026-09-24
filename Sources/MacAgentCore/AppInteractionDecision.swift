import Foundation

/// The step kinds the model may choose (founders, 2026-09-24): cua's on-screen tools, less
/// dragging. `enter_target` and `enter_text` carry no text: Sonny places the goal's own `target` or
/// `text`, never words the model supplies.
public enum AppInteractionStepKind: String, CaseIterable, Sendable, Codable {
    case click
    case doubleClick = "double_click"
    case rightClick = "right_click"
    /// A click at a point, judged as a click on whatever element is there.
    case clickAt = "click_at"
    case enterTarget = "enter_target"
    case enterText = "enter_text"
    case pressKey = "press_key"
    case shortcut
    case scroll
    case menu

    /// The kinds that name an element by `ref`. `click_at` names a point, and a key or a shortcut
    /// goes to the window.
    public var takesRef: Bool {
        switch self {
        case .clickAt, .pressKey, .shortcut: return false
        case .click, .doubleClick, .rightClick, .enterTarget, .enterText, .scroll, .menu: return true
        }
    }
}

/// One step the model asked for, exactly as it asked.
public struct AppInteractionStep: Equatable, Sendable {
    public let kind: AppInteractionStepKind
    /// The element's ref: required by `takesRef` kinds, optional for scroll, nil otherwise.
    public let ref: String?
    /// The key for `press_key`, the shortcut for `shortcut` ("cmd+f"), the direction for `scroll`.
    public let input: String?
    /// For `click_at`, in the screen points the candidates' `at` are given in.
    public let x: Double?
    public let y: Double?

    public init(_ kind: AppInteractionStepKind, ref: String? = nil, input: String? = nil, x: Double? = nil, y: Double? = nil) {
        self.kind = kind
        self.ref = ref
        self.input = input
        self.x = x
        self.y = y
    }
}

/// What the model answered for one step. Decoded strictly from its JSON; anything else is an
/// error, never a guess.
public enum AppInteractionModelDecision: Equatable, Sendable {
    case step(AppInteractionStep)
    /// The model believes the goal is met. Sonny still checks for itself.
    case finished
    /// The model needs the person to choose, for example between two chats with the same name.
    case askUser(String)
    /// The model sees no way to reach the goal in this app.
    case giveUp(String)

    /// A step on an element, the shape most steps take.
    public static func step(_ kind: AppInteractionStepKind, ref: String) -> AppInteractionModelDecision {
        .step(AppInteractionStep(kind, ref: ref))
    }

    public static let schemaName = "app_interaction_step"

    /// Strict JSON schema for the step route: every key required, nulls where a key does not
    /// apply, no extra keys.
    public static func schema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["decision", "step", "ref", "input", "x", "y", "message"],
            "properties": [
                "decision": [
                    "type": "string",
                    "enum": ["act", "finished", "ask_user", "give_up"],
                    "description": "act to take one step; finished when the goal is met; ask_user when the person must choose; give_up when this app offers no way to reach the goal.",
                ],
                "step": [
                    "type": ["string", "null"],
                    "enum": (AppInteractionStepKind.allCases.map(\.rawValue) as [Any]) + [NSNull()],
                    "description": "For act: which step. An element step must be one that element lists under can. Null otherwise.",
                ],
                "ref": [
                    "type": ["string", "null"],
                    "description": "For an element step: the element's ref, exactly as given. Null for click_at, press_key and shortcut, and optional for scroll.",
                ],
                "input": [
                    "type": ["string", "null"],
                    "description": "For press_key: one key from the screen's keys. For shortcut: one entry from the screen's shortcuts. For scroll: up, down, left or right. Null otherwise.",
                ],
                "x": [
                    "type": ["number", "null"],
                    "description": "For click_at: the horizontal point, in the coordinates of the candidates' at. Null otherwise.",
                ],
                "y": [
                    "type": ["number", "null"],
                    "description": "For click_at: the vertical point, in the coordinates of the candidates' at. Null otherwise.",
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
        let input: String?
        let x: Double?
        let y: Double?
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
            guard let raw = wire.step, let kind = AppInteractionStepKind(rawValue: raw) else {
                throw AppInteractionDecisionError.malformed
            }
            let ref = wire.ref?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            let input = wire.input?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            switch kind {
            case .clickAt:
                guard let x = wire.x, let y = wire.y, x.isFinite, y.isFinite else { throw AppInteractionDecisionError.malformed }
                return .step(AppInteractionStep(kind, x: x, y: y))
            case .pressKey, .shortcut:
                guard let input else { throw AppInteractionDecisionError.malformed }
                return .step(AppInteractionStep(kind, input: input))
            case .scroll:
                guard let input else { throw AppInteractionDecisionError.malformed }
                return .step(AppInteractionStep(kind, ref: ref, input: input))
            case .click, .doubleClick, .rightClick, .enterTarget, .enterText, .menu:
                guard let ref else { throw AppInteractionDecisionError.malformed }
                return .step(AppInteractionStep(kind, ref: ref))
            }
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

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
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
