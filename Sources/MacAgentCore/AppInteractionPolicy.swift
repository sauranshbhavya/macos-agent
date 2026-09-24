import Foundation

/// Decides whether one step the model proposed may run, against the latest cua reading, and turns
/// it into the cua action that runs it.
///
/// Milestone A has no approval for a commit yet, so anything that could send, delete, call, join or
/// otherwise act outside the app is refused rather than asked about (V2 plan §15: a consequential
/// action waits until exact approval exists). The rules, as the founders set them on 2026-09-24:
///
/// - A click, double-click or right-click lands only on something that moves between things — a
///   row, cell or tab — or on a named button inside a list, and never on one whose name commits.
///   Every other button, link, checkbox or pop-up is refused.
/// - A click at a point is judged as a click on the element there, and refused when nothing is.
/// - The target name goes only into a search field; the goal's text only into a text field that is
///   not a search field and not in a list, never over text the person typed there, and never while
///   a different item is visibly open. Neither is ever the model's own words.
/// - Keys: Tab, the arrows, Escape, Page Up, Page Down, Home and End — never Return or Delete.
/// - Shortcuts: only ⌘F.
/// - A menu command, found by its path in the menu bar, never when any step of it names a commit.
/// - Scrolling is allowed; dragging is not offered at all.
///
/// Names are untrusted and a word list cannot prove a control harmless (plan §7), which is why the
/// role rule carries the weight, a false match only refuses, and cua's own manifest fences the
/// tools and the app behind this.
public enum AppInteractionPolicy {
    public static func decide(
        _ step: AppInteractionStep,
        in state: CuaWindowState,
        goal: AppInteractionGoal,
        sonnyWrote: Set<String> = []
    ) -> AppInteractionPolicyDecision {
        switch step.kind {
        case .pressKey:
            guard let key = step.input?.lowercased(), allowedKeys.contains(key) else { return .refuse(.keyNotAllowed) }
            return .allow(.pressKey(key))
        case .shortcut:
            guard let keys = step.input.map(shortcutKeys), keys == ["cmd", "f"] else { return .refuse(.shortcutNotAllowed) }
            return .allow(.hotkey(keys))
        case .clickAt:
            guard let x = step.x, let y = step.y else { return .refuse(.elementGone) }
            guard let element = state.element(atX: x, y: y) else { return .refuse(.nothingThere) }
            return decideOnElement(.click, element, in: state, goal: goal, sonnyWrote: sonnyWrote)
        case .scroll where step.ref == nil:
            guard let direction = step.input?.lowercased(), scrollDirections.contains(direction) else {
                return .refuse(.unsupported)
            }
            return .allow(.scroll(nil, direction: direction))
        default:
            guard let ref = step.ref, ref.hasPrefix("e"), let index = Int(ref.dropFirst()),
                  let element = state.element(index) else { return .refuse(.elementGone) }
            return decideOnElement(step.kind, element, in: state, goal: goal, sonnyWrote: sonnyWrote, input: step.input)
        }
    }

    /// The same rules for a step on a known element; the screen asks this to decide what to offer.
    public static func decideOnElement(
        _ kind: AppInteractionStepKind,
        _ element: CuaElement,
        in state: CuaWindowState,
        goal: AppInteractionGoal,
        sonnyWrote: Set<String> = [],
        input: String? = nil
    ) -> AppInteractionPolicyDecision {
        guard element.isEnabled else { return .refuse(.disabled) }
        let ref = CuaElementRef(element, in: state)

        switch kind {
        case .click, .doubleClick, .rightClick, .clickAt:
            guard mayNavigate(element, in: state) else { return .refuse(.mightCommit) }
            switch kind {
            case .doubleClick: return .allow(.doubleClick(ref))
            case .rightClick: return .allow(.rightClick(ref))
            default: return .allow(.click(ref))
            }
        case .scroll:
            guard element.actions.contains(where: { $0.hasPrefix("AXScroll") }) else { return .refuse(.unsupported) }
            guard let direction = input?.lowercased(), scrollDirections.contains(direction) else { return .refuse(.unsupported) }
            return .allow(.scroll(ref, direction: direction))
        case .menu:
            guard element.role == "AXMenuItem", let path = state.menuPath(of: element) else { return .refuse(.unsupported) }
            let names = path.map { $0.lowercased() }
            guard !names.contains(where: { name in committingWords.contains { name.contains($0) } }) else {
                return .refuse(.mightCommit)
            }
            return .allow(.menu(path))
        case .enterTarget:
            guard let target = goal.target else { return .refuse(.nothingToType) }
            // Search fields only: a name typed into a message box would replace the person's draft
            // with a name (PR #289 review, F2).
            guard state.isSearchField(element) else { return .refuse(.notASearchField) }
            return .allow(.setValue(ref, target))
        case .enterText:
            guard let text = goal.text else { return .refuse(.nothingToType) }
            guard state.isTextInput(element), !state.isInsideList(element) else { return .refuse(.notATextField) }
            guard !state.isSearchField(element) else { return .refuse(.searchFieldForMessage) }
            if let existing = element.value?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty,
               !sameText(existing, text),
               !sonnyWrote.contains(where: { sameText($0, existing) }) {
                return .refuse(.wouldReplaceTypedText)
            }
            if let target = goal.target, AppInteractionVerifier.targetState(target, in: state) == .contradicted {
                return .refuse(.otherTargetOpen)
            }
            return .allow(.setValue(ref, text))
        case .pressKey, .shortcut:
            return .refuse(.unsupported)
        }
    }

    static func mayNavigate(_ element: CuaElement, in state: CuaWindowState) -> Bool {
        guard !state.isInMenus(element) else { return false }
        if AppInteractionRoles.navigation.contains(element.role) {
            return !namesACommit(element, in: state)
        }
        guard element.role == "AXButton", state.isInsideList(element), let label = element.label, !label.isEmpty else {
            return false
        }
        return !namesACommit(element, in: state)
    }

    /// A button outside a list is matched by substring over every name it has, so "Resend" and
    /// "Huddle now" are caught and a false match only refuses. A row, tab or button inside a list
    /// is usually named for a person, so its name's first part is matched word by word with the
    /// common inflections — "Callum" opens, "Join call" does not — and its whole name against call
    /// wording, which is what a call-log entry gives itself away by.
    static func namesACommit(_ element: CuaElement, in state: CuaWindowState) -> Bool {
        let names = [element.label, element.value].compactMap { $0?.lowercased() }
        if element.role == "AXButton", !state.isInsideList(element) {
            return names.contains { name in committingWords.contains { name.contains($0) } }
        }
        if names.map(firstSegment).contains(where: { matchesAWord($0, of: committingWords) }) { return true }
        return names.contains { matchesAWord($0, of: callWords) }
    }

    /// Up to the first ", ": an app that joins name, last message and time into one label puts
    /// the name first.
    static func firstSegment(_ text: String) -> String {
        String(text.split(separator: ",", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
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

    /// "cmd+f", "⌘F" and "Cmd + F" all read as ["cmd", "f"].
    static func shortcutKeys(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "⌘", with: "cmd+")
            .split(whereSeparator: { $0 == "+" || $0 == " " })
            .map { $0 == "command" ? "cmd" : String($0) }
    }

    /// Never Return or Enter, which send and submit, and never Delete or Backspace, which erase.
    public static let allowedKeys: [String] = ["tab", "up", "down", "left", "right", "escape", "pageup", "pagedown", "home", "end"]
    public static let allowedShortcuts: [String] = ["cmd+f"]
    static let scrollDirections: Set<String> = ["up", "down", "left", "right"]

    /// The words that mark a row as a call rather than a chat. "voice" and "video" alone are
    /// deliberately absent: a chat whose last message was a voice note shows exactly those words,
    /// and "voice call" and "video call" are still caught by "call".
    static let callWords: [String] = [
        "call", "dial", "missed", "outgoing", "incoming", "facetime", "huddle", "join", "ongoing", "ring",
    ]

    /// Two strings the app may have tidied: compared without case and with whitespace collapsed.
    static func sameText(_ a: String, _ b: String) -> Bool {
        func tidy(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return tidy(a) == tidy(b)
    }

    /// Verbs and nouns that commit something outside the app or change it in a way the user did not
    /// ask for, matched as substrings of a button's or a menu command's names.
    static let committingWords: [String] = [
        "send", "delete", "remove", "pay", "buy", "purchase", "order", "submit", "post", "publish",
        "confirm", "call", "video", "voice", "dial", "ring", "forward", "share", "react", "like",
        "block", "report", "archive", "leave", "exit", "clear", "erase", "mute", "pin", "star",
        "install", "upgrade", "subscribe", "log out", "logout", "sign out", "signout", "join",
        "retry", "accept", "answer", "decline", "reject", "follow", "invite", "huddle", "meet",
        "record", "upload", "attach", "approve", "vote", "transfer", "download", "start", "add",
        "quit", "close", "lock", "move", "print", "export",
    ]
}

public enum AppInteractionPolicyDecision: Equatable, Sendable {
    case allow(CuaAction)
    case refuse(AppInteractionRefusal)
}

public enum AppInteractionRefusal: Equatable, Sendable {
    case elementGone
    case disabled
    case unsupported
    case mightCommit
    /// A click at a point where no element is.
    case nothingThere
    case keyNotAllowed
    case shortcutNotAllowed
    case notATextField
    case notASearchField
    case searchFieldForMessage
    case nothingToType
    /// The field already holds text the person typed, which setting its value would erase.
    case wouldReplaceTypedText
    /// A different item is visibly open, so the text would land in the wrong place.
    case otherTargetOpen
}
