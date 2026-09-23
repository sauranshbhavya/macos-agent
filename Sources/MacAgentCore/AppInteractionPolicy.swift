import Foundation

/// Decides whether one step the model proposed may run, against the element as it is in the
/// latest observation.
///
/// Milestone A has no approval for a commit yet, so anything that could send, delete, call, join or
/// otherwise act outside the app is refused rather than asked about (V2 plan §15: a consequential
/// action waits until exact approval exists). The rules lean on role first and name second:
///
/// - Pressing or selecting a row, cell or tab navigates, so it is allowed unless its name commits.
/// - A button is allowed only inside a list (a scroll area does not count), where it is a row drawn
///   as a button, and only when it has a name and the name commits nothing. Every other button,
///   link, pressable text, menu item, checkbox or pop-up is refused.
/// - The target name is typed only into a search field. The message is typed only into a writable
///   field that is not a search field, never over text the person typed there, and never while a
///   different chat is visibly open.
///
/// The name checked is `AccessibilitySnapshot.displayName(of:)`, the same string the model is
/// shown, plus the element's own fields; matching is by substring, so "Resend" and "Reposting"
/// fall to "send" and "post" (PR #289 review, F1). A false match only refuses. Labels are
/// untrusted and a word list cannot prove a button harmless (plan §7), which is why the role rule
/// carries the weight and the runtime only runs in WhatsApp for now.
public enum AppInteractionPolicy {
    public static func decide(
        _ kind: AppInteractionStepKind,
        on id: AccessibilityElementID,
        in snapshot: AccessibilitySnapshot,
        goal: AppInteractionGoal,
        sonnyWrote: Set<String> = []
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
            // Search fields only: a name typed into a message box would replace the person's draft
            // with a name (PR #289 review, F2).
            guard element.isSearchField, element.canSetValue else { return .refuse(.notASearchField) }
            return .allow(.setValue(target))
        case .enterText:
            guard let text = goal.text else { return .refuse(.nothingToType) }
            guard element.isTextInput, element.canSetValue else { return .refuse(.notATextField) }
            guard !element.isSearchField else { return .refuse(.searchFieldForMessage) }
            if let existing = element.typedText,
               !sameText(existing, text),
               !sonnyWrote.contains(where: { sameText($0, existing) }) {
                return .refuse(.wouldReplaceTypedText)
            }
            if let target = goal.target,
               AppInteractionVerifier.targetState(target, in: snapshot) == .contradicted {
                return .refuse(.otherTargetOpen)
            }
            return .allow(.setValue(text))
        }
    }

    static func mayNavigate(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> Bool {
        if AccessibilityVocabulary.selectionRoles.contains(element.role) {
            return !namesACommit(element, in: snapshot)
        }
        guard element.role == "AXButton", snapshot.isInsideList(element) else { return false }
        return !snapshot.displayName(of: element).isEmpty && !namesACommit(element, in: snapshot)
    }

    /// A button outside a list is matched by substring over every name it has, so "Resend" and
    /// "Huddle now" are caught and a false match only refuses.
    ///
    /// A row, a tab or a row drawn as a button inside a list only navigates, and its name is usually
    /// a person's, so it is matched word by word with the common inflections, in two tiers:
    ///
    /// - **Its name** — `rowName` and the part before the first comma of each of its own fields —
    ///   against every committing word. "Callum", "Maddie" and "Book club meetup" open; "Join call",
    ///   "Resend" and a row whose own description is "Missed video call" do not (PR #289 review F1,
    ///   its delta N2 and the final check).
    /// - **Everything it carries**, its own fields whole and its inner texts, against call wording
    ///   only. That is what a call-log entry shown as "Mom" gives itself away by, whether its
    ///   "Outgoing voice call" sits in its label or in a child. A chat's preview goes through this
    ///   tier and no other, so "did you send it?" does not stop Sonny opening the chat, while "call
    ///   me later" does, which is the safe direction.
    static func namesACommit(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> Bool {
        if element.role == "AXButton", !snapshot.isInsideList(element) {
            let names = [snapshot.displayName(of: element), element.title, element.label, element.identifier, element.value]
                .compactMap { $0?.lowercased() }
            return names.contains { name in committingWords.contains { name.contains($0) } }
        }
        let ownNames = [element.title, element.label, element.identifier, element.value]
            .map { $0.map(AccessibilitySnapshot.firstSegment) }
        let nameParts = ([snapshot.rowName(of: element)] + ownNames).compactMap { $0?.lowercased() }
        if nameParts.contains(where: { matchesAWord($0, of: committingWords) }) { return true }
        return snapshot.allTexts(of: element).contains { matchesAWord($0.lowercased(), of: callWords) }
    }

    /// Whether `text` holds one of `list` as a whole word or a common inflection of one, or a
    /// multi-word entry anywhere.
    static func matchesAWord(_ text: String, of list: [String]) -> Bool {
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return list.contains { word in
            word.contains(" ")
                ? text.contains(word)
                : !words.isDisjoint(with: [word, word + "s", word + "ing", word + "ed", "re" + word, "un" + word])
        }
    }

    /// The words that mark a row as a call rather than a chat, read from everything a row carries.
    /// "join", "ongoing" and "ring" catch a group row offering its live call (PR #289 check of
    /// 0bc0587f). "voice" and "video" alone are deliberately absent: a chat whose last message was
    /// a voice note or a video shows exactly those words, and "voice call" and "video call" are
    /// still caught by "call".
    static let callWords: [String] = [
        "call", "dial", "missed", "outgoing", "incoming", "facetime", "huddle", "join", "ongoing", "ring",
    ]

    /// Two strings the app may have tidied: compared without case and with whitespace collapsed.
    static func sameText(_ a: String, _ b: String) -> Bool {
        func tidy(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return tidy(a) == tidy(b)
    }

    /// Verbs and nouns that commit something outside the app or change it in a way the user did not
    /// ask for, matched as substrings of an element's names.
    static let committingWords: [String] = [
        "send", "delete", "remove", "pay", "buy", "purchase", "order", "submit", "post", "publish",
        "confirm", "call", "video", "voice", "dial", "ring", "forward", "share", "react", "like",
        "block", "report", "archive", "leave", "exit", "clear", "erase", "mute", "pin", "star",
        "install", "upgrade", "subscribe", "log out", "logout", "sign out", "signout", "join",
        "retry", "accept", "answer", "decline", "reject", "follow", "invite", "huddle", "meet",
        "record", "upload", "attach", "approve", "vote", "transfer", "download", "start", "add",
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
    case notASearchField
    case searchFieldForMessage
    case nothingToType
    /// The field already holds text the person typed, which setting its value would erase.
    case wouldReplaceTypedText
    /// A different chat is visibly open, so the message would land in the wrong place.
    case otherTargetOpen
}
