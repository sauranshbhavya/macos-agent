import Foundation

/// Decides whether one step the model proposed may run, against the element as it is in the
/// latest observation.
///
/// Milestone A has no approval for a commit yet, so anything that could send, delete, call or
/// otherwise act outside the app is refused rather than asked about (V2 plan §15: a consequential
/// action waits until exact approval exists). The rules lean on role first and label second:
///
/// - Pressing or selecting a row, cell, tab or link navigates, so it is allowed.
/// - A button is allowed only inside a list, where it is almost always a row drawn as a button,
///   and only when its label is present and names nothing on `committingWords`. Every other
///   button, menu item, checkbox or pop-up is refused.
/// - Typing is limited to text fields, and only the goal's own `target` or `text`. The message text
///   never goes into a search field, and never over text the person already typed there: setting a
///   field's value replaces it, and a half-written draft is theirs.
///
/// Labels are untrusted and a heuristic cannot prove an arbitrary button harmless (plan §7). The
/// role rule carries the weight; the word list only narrows the one place buttons are allowed.
public enum AppInteractionPolicy {
    public static func decide(
        _ kind: AppInteractionStepKind,
        on id: AccessibilityElementID,
        in snapshot: AccessibilitySnapshot,
        goal: AppInteractionGoal
    ) -> AppInteractionPolicyDecision {
        guard let element = snapshot.element(id) else { return .refuse(.elementGone) }
        guard element.isEnabled else { return .refuse(.disabled) }

        switch kind {
        case .press:
            guard element.canPress else { return .refuse(.unsupported) }
            return mayNavigate(element, in: snapshot) ? .allow(.press) : .refuse(.mightCommit)
        case .select:
            guard element.canSelect else { return .refuse(.unsupported) }
            return mayNavigate(element, in: snapshot) ? .allow(.select) : .refuse(.mightCommit)
        case .focus:
            guard element.isTextInput, element.canFocus else { return .refuse(.unsupported) }
            return .allow(.focus)
        case .enterTarget:
            guard let target = goal.target else { return .refuse(.nothingToType) }
            guard element.isTextInput, element.canSetValue else { return .refuse(.notATextField) }
            return .allow(.setValue(target))
        case .enterText:
            guard let text = goal.text else { return .refuse(.nothingToType) }
            guard element.isTextInput, element.canSetValue else { return .refuse(.notATextField) }
            guard element.subrole != AccessibilityVocabulary.searchFieldSubrole else {
                return .refuse(.searchFieldForMessage)
            }
            if let existing = element.typedText, existing != text {
                return .refuse(.wouldReplaceTypedText)
            }
            return .allow(.setValue(text))
        }
    }

    static func mayNavigate(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> Bool {
        if AccessibilityVocabulary.selectionRoles.contains(element.role) {
            return !namesACommit(element, in: snapshot)
        }
        guard element.role == "AXButton" else { return false }
        // Scroll areas included: SwiftUI often draws a list as buttons in a scroll area. The
        // verifier is stricter about the same containers, because there a wrong answer confirms a
        // chat that is not open, while here it only lets Sonny move between rows.
        let insideList = snapshot.ancestors(of: element).contains {
            AccessibilityVocabulary.listRoles.contains($0.role)
        }
        let label = AppInteractionScreenBuilder.label(for: element, in: snapshot)
        return insideList && !label.isEmpty && !namesACommit(element, in: snapshot)
    }

    static func namesACommit(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> Bool {
        let own = [element.title, element.label, element.identifier].compactMap { $0 }
        let words = own.joined(separator: " ").lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        return words.contains(where: committingWords.contains)
    }

    /// Verbs that commit something outside the app or change it in a way the user did not ask
    /// for. Matched as whole words in an element's own title, description and identifier.
    static let committingWords: Set<String> = [
        "send", "delete", "remove", "pay", "buy", "purchase", "order", "submit", "post", "publish",
        "confirm", "call", "video", "voice", "dial", "forward", "share", "react", "reaction", "like",
        "block", "report", "archive", "leave", "exit", "clear", "erase", "unsend", "mute", "pin",
        "star", "install", "upgrade", "subscribe", "logout", "signout",
    ]
}

public enum AppInteractionPolicyDecision: Equatable, Sendable {
    case allow(AccessibilityAction)
    case refuse(AppInteractionRefusal)
}

public enum AppInteractionRefusal: Equatable, Sendable {
    case elementGone
    case disabled
    case unsupported
    case mightCommit
    case notATextField
    case searchFieldForMessage
    case nothingToType
    /// The field already holds text the person typed, which setting its value would erase.
    case wouldReplaceTypedText
}
