import Foundation

/// What the Mac knows about an action's target that can make it more consequential than the model
/// said. Every field is observed on the Mac; none can lower an effect (V2 plan section 7.2).
public struct RaiseFacts: Sendable, Equatable {
    /// A key chord about to be sent, lowercased: `["cmd", "return"]`. A line break typed into a
    /// field is sent as `["return"]`.
    public var keyChord: [String]?
    /// Whether the focused element takes text (a field, a text area, a composer).
    public var focusedTakesText: Bool
    /// The target's label, title, or menu path, as the app reports them.
    public var targetWords: [String]
    /// Text the action would type or set.
    public var text: String?
    /// Whether the target is a secure (password) field, or may be one: text typed at the focus
    /// while a password field shows.
    public var targetIsSecure: Bool

    public init(
        keyChord: [String]? = nil,
        focusedTakesText: Bool = false,
        targetWords: [String] = [],
        text: String? = nil,
        targetIsSecure: Bool = false
    ) {
        self.keyChord = keyChord
        self.focusedTakesText = focusedTakesText
        self.targetWords = targetWords
        self.text = text
        self.targetIsSecure = targetIsSecure
    }

    public static let none = RaiseFacts()
}

/// The deterministic, local rules that can only raise an effect.
public enum EffectRaiser {
    static let externalWords = ["send", "post", "submit", "reply", "share", "invite", "publish"]
    static let financialWords = ["pay", "buy", "purchase", "order", "subscribe", "transfer", "checkout"]
    static let destructiveWords = ["delete", "remove", "trash", "discard", "overwrite", "erase", "reset"]
    /// cua presses Return for "return" or "enter"; the keypad's spellings are here too, so no name
    /// for Enter slips past.
    static let submitKeys: Set<String> = ["return", "enter", "kpenter", "keypadenter", "numpadenter"]

    /// The effect an action is gated as: the highest of what the model declared, the operation's own
    /// floor, and every local rule that fires.
    public static func raise(declared: Effect, floor: Effect, facts: RaiseFacts) -> Effect {
        var effect = declared.raised(to: floor)
        // Any key of the chord counts, not only the last: ["return", "cmd"] still presses Return.
        if let chord = facts.keyChord, facts.focusedTakesText, chord.contains(where: { submitKeys.contains($0.lowercased()) }) {
            effect = effect.raised(to: .external)
        }
        let words = facts.targetWords.flatMap(Self.words(in:))
        if words.contains(where: externalWords.contains) { effect = effect.raised(to: .external) }
        if words.contains(where: financialWords.contains) { effect = effect.raised(to: .financial) }
        if words.contains(where: destructiveWords.contains) { effect = effect.raised(to: .destructive) }
        if facts.targetIsSecure { effect = effect.raised(to: .credential) }
        if let text = facts.text, !SecretTextDetector().matches(in: text).isEmpty {
            effect = effect.raised(to: .credential)
        }
        return effect
    }

    /// Whether text holds a line break of any kind: "\n", "\r", "\r\n", or a Unicode line or
    /// paragraph separator. Typed into a field, each one is a Return press.
    static func breaksLine(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    }

    /// Lowercased words, so "Send Now" and "Unsubscribe" are judged by their parts: "send" matches,
    /// "unsubscribe" does not become "subscribe".
    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Whether Sonny may act in an app at all, and whether the user has allowed it there.
public enum AppStanding: Sendable, Equatable {
    /// Built in or allowed by the user.
    case allowed
    /// Sonny may act here once the user allows it.
    case notAllowed
    /// Never: terminals, script editors, a shell on screen.
    case refused
}

public struct GateContext: Sendable, Equatable {
    public var mode: AgentInteractionMode
    /// Nobody is at the Mac, so nothing can be confirmed.
    public var unattended: Bool
    /// The target app's standing, for actions that control an app. Nil for typed operations that
    /// don't control another app's interface.
    public var standing: AppStanding?

    public init(mode: AgentInteractionMode, unattended: Bool, standing: AppStanding? = nil) {
        self.mode = mode
        self.unattended = unattended
        self.standing = standing
    }
}

public enum GateDecision: Sendable, Equatable {
    case run
    /// Ask the user first, showing the exact effect.
    case confirm
    case refuse(OutcomeErrorCode)
}

/// The one local gate every action passes, whichever agent proposed it (V2 plan section 7.3).
public enum ActionGate {
    public static func decide(_ effect: Effect, context: GateContext) -> GateDecision {
        if effect == .credential { return .refuse(.secureField) }
        if context.standing == .refused { return .refuse(.targetRefused) }

        // Nobody is at the Mac: the Unattended column decides, whatever the mode. Local edits and
        // new things run; anything that would need a yes is refused, since nobody can give one.
        if context.unattended {
            switch effect {
            case .observe, .navigate:
                return .run
            case .editLocal, .create:
                return context.standing == .notAllowed && context.mode != .power ? .refuse(.unattendedRefused) : .run
            case .destructive, .external, .financial, .unknown, .credential:
                return .refuse(.unattendedRefused)
            }
        }

        switch effect {
        case .observe, .navigate:
            return .run
        case .editLocal, .create:
            // Power skips the per-app standing check; Safe asks for every change; Normal asks in an
            // app the user hasn't allowed.
            if context.mode == .safe { return .confirm }
            if context.standing == .notAllowed, context.mode != .power { return .confirm }
            return .run
        case .destructive, .external, .financial, .unknown:
            return .confirm
        case .credential:
            return .refuse(.secureField)
        }
    }
}
