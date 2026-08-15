import CoreGraphics
import Foundation

// MARK: - What the vision model may ask for

/// The complete vocabulary of things a vision model may ask Sonny to do.
///
/// **Closed, and closed is the point.** The model returns free-form JSON; this enum is where that
/// free-form text stops being free-form. An action the model names that is not one of these does not
/// map to a case, and a decision that does not map is a parse failure — not a silently ignored
/// instruction, and certainly not a default. `AgentOperation` gets the same treatment one layer up.
public enum VisionActionKind: String, CaseIterable, Equatable, Sendable {
    case click
    case type
    case scroll
    case key
    case wait
    case done
    case stuck

    /// Whether this kind actually drives the machine. The four that do not (`wait`, `done`,
    /// `stuck`, and — once row I's decomposition ticket adds it — anything that only talks) never
    /// reach input synthesis, so they never need an approval and never produce a journal entry for a
    /// synthesized action.
    public var synthesizesInput: Bool {
        switch self {
        case .click, .type, .scroll, .key:
            return true
        case .wait, .done, .stuck:
            return false
        }
    }
}

/// The keys a vision session may press. Closed for the same reason ``VisionActionKind`` is: a model
/// naming an arbitrary key combination is a model composing keyboard shortcuts nobody reviewed.
public enum VisionActionKey: String, CaseIterable, Equatable, Sendable {
    case enterKey = "enter"
    case tab
    case escape
    case delete
    case arrowUp = "up"
    case arrowDown = "down"
    case arrowLeft = "left"
    case arrowRight = "right"
}

public enum VisionScrollDirection: String, CaseIterable, Equatable, Sendable {
    case up
    case down
}

/// One decision, parsed from the vision model's reply.
public struct VisionDecision: Equatable, Sendable {
    public var kind: VisionActionKind
    public var x: Int?
    public var y: Int?
    public var text: String?
    public var key: VisionActionKey?
    public var scrollDirection: VisionScrollDirection?
    /// The visible label of the control the model is aiming at, in the model's own words.
    ///
    /// **Untrusted, and load-bearing anyway.** It is read off the screen, so it is exactly the kind
    /// of string an injected page can control — and it is also the single best signal available for
    /// "is this button a Delete button". The resolution is that it may only ever *add* an approval
    /// (``VisionConsequenceClassifier``), never remove one: an attacker who controls this string can
    /// make Sonny ask more often, which is not an attack.
    public var target: String
    public var rationale: String
    /// The model's own reading of what this action would do. Advisory input to the consequence
    /// classifier, never the whole of it — see ``VisionConsequenceClassifier``.
    public var declaredConsequence: CapabilityRiskEscalation.Consequence?

    public init(
        kind: VisionActionKind,
        x: Int? = nil,
        y: Int? = nil,
        text: String? = nil,
        key: VisionActionKey? = nil,
        scrollDirection: VisionScrollDirection? = nil,
        target: String = "",
        rationale: String = "",
        declaredConsequence: CapabilityRiskEscalation.Consequence? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.key = key
        self.scrollDirection = scrollDirection
        self.target = target
        self.rationale = rationale
        self.declaredConsequence = declaredConsequence
    }

    /// A short, human sentence naming what this action does — the line the HUD shows and the
    /// approval panel leads with.
    public var actionDescription: String {
        switch kind {
        case .click:
            return target.isEmpty ? "Click in the window" : "Click \u{201C}\(target)\u{201D}"
        case .type:
            return "Type \u{201C}\(VisionDecision.previewText(text ?? ""))\u{201D}"
        case .scroll:
            return "Scroll \(scrollDirection?.rawValue ?? "down")"
        case .key:
            return "Press \(key?.rawValue ?? "a key")"
        case .wait:
            return "Wait for the screen to settle"
        case .done:
            return "Finish — the goal looks complete"
        case .stuck:
            return "Stop — no way forward from here"
        }
    }

    /// Typed text is the one action whose payload can be long and can itself contain a secret the
    /// user is pasting. The approval line shows a bounded prefix, never the whole thing.
    static func previewText(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: "\u{21A9}")
        return collapsed.count <= 60 ? collapsed : String(collapsed.prefix(60)) + "\u{2026}"
    }
}

// MARK: - Parsing the reply

public enum VisionDecisionParseError: Error, Equatable, LocalizedError {
    case noJSONObject(String)
    case unknownAction(String)
    case missingField(action: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "The vision model's reply did not contain a JSON object."
        case .unknownAction(let action):
            return "The vision model asked for an action Sonny does not support: \(action)."
        case .missingField(let action, let field):
            return "The vision model's \(action) action is missing its \(field)."
        }
    }
}

public enum VisionDecisionParser {
    /// Parse a model reply into a decision.
    ///
    /// Lenient about *packaging* — the object is taken from the first `{` to the last `}`, so
    /// markdown fences and stray prose around it do not break a run — and strict about *content*: an
    /// unrecognized action, or an action missing the field it cannot act without, throws rather than
    /// degrading into something adjacent. The distinction matters because sloppy packaging is a
    /// model habit while an unrecognized action is a model asking for a capability it was never
    /// given.
    public static func decision(from reply: String) throws -> VisionDecision {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end,
              let object = try? JSONSerialization.jsonObject(
                with: Data(String(reply[start...end]).utf8)
              ) as? [String: Any] else {
            throw VisionDecisionParseError.noJSONObject(reply)
        }

        guard let rawAction = object["action"] as? String,
              let kind = VisionActionKind(rawValue: rawAction.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw VisionDecisionParseError.unknownAction((object["action"] as? String) ?? "<missing>")
        }

        func int(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String { return Int(value) }
            return nil
        }

        let decision = VisionDecision(
            kind: kind,
            x: int("x"),
            y: int("y"),
            text: object["text"] as? String,
            key: (object["key"] as? String).flatMap { VisionActionKey(rawValue: $0.lowercased()) },
            scrollDirection: (object["direction"] as? String).flatMap { VisionScrollDirection(rawValue: $0.lowercased()) },
            target: (object["target"] as? String) ?? "",
            rationale: (object["rationale"] as? String) ?? "",
            declaredConsequence: declaredConsequence(object["consequence"] as? String)
        )

        switch kind {
        case .click:
            guard decision.x != nil, decision.y != nil else {
                throw VisionDecisionParseError.missingField(action: kind.rawValue, field: "coordinates")
            }
        case .type:
            guard let text = decision.text, !text.isEmpty else {
                throw VisionDecisionParseError.missingField(action: kind.rawValue, field: "text")
            }
        case .key:
            guard decision.key != nil else {
                throw VisionDecisionParseError.missingField(action: kind.rawValue, field: "key")
            }
        case .scroll:
            guard decision.scrollDirection != nil else {
                throw VisionDecisionParseError.missingField(action: kind.rawValue, field: "direction")
            }
        case .wait, .done, .stuck:
            break
        }

        return decision
    }

    /// The model's declared consequence, mapped onto the engine's own class vocabulary.
    ///
    /// An unrecognized string yields `nil` — "the model said nothing usable" — rather than
    /// `.advisory`. The two are very different: `nil` leaves the classifier's local evidence to
    /// decide alone, while `.advisory` would be the model actively asserting "this is harmless",
    /// which is a claim a typo should never be able to make on its behalf.
    private static func declaredConsequence(_ raw: String?) -> CapabilityRiskEscalation.Consequence? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "destructive":
            return .destructive
        case "affects_others", "affectsothers", "external":
            return .affectsOthers
        case "ordinary", "advisory", "none":
            return .advisory
        default:
            return nil
        }
    }
}
