import Foundation

/// Checks a goal against a fresh observation, independently of anything the model said
/// (V2 plan §10: "A model saying 'done' is not independent evidence").
public enum AppInteractionVerifier {
    public enum Result: Equatable, Sendable {
        /// The text is in a writable field and the target is visibly open.
        case satisfied
        /// The text is in a writable field, but nothing names the target as open, so Sonny cannot
        /// tell whether it is in the right place.
        case targetUnconfirmed
        /// Something else is visibly open: never a success, whatever the text field holds.
        case otherTargetOpen
        case notYet
    }

    /// What an observation says about whether the target is the thing open.
    public enum TargetState: Equatable, Sendable {
        case shown
        /// A selected row in a list names something else, and nothing names the target.
        case contradicted
        case unknown
    }

    public static func check(_ snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> Result {
        let target = goal.target.map { targetState($0, in: snapshot) }
        if target == .contradicted { return .otherTargetOpen }
        guard let text = goal.text else { return target == .shown ? .satisfied : .notYet }
        guard textIsPlaced(text, in: snapshot) else { return .notYet }
        guard let target else { return .satisfied }
        return target == .shown ? .satisfied : .targetUnconfirmed
    }

    /// The text sits in a field Sonny could have written: writable, not a search field, and not a
    /// cell inside a list (PR #289 review, F7). A scroll area is allowed, because a Mac text view
    /// always sits inside one (delta review, N1); a sent message shown as a text view there is
    /// read-only, which `canSetValue` already refuses.
    static func textIsPlaced(_ text: String, in snapshot: AccessibilitySnapshot) -> Bool {
        snapshot.elements.contains {
            $0.isTextInput && !$0.isSearchField && $0.canSetValue
                && $0.value == text
                && !snapshot.isInsideList($0)
        }
    }

    /// Which of a row's names (`rowNames`) is the target, compared whole after dropping case and
    /// symbols, so "Mom ❤️" is Mom and "Mom & Dad", "Family" and "Give me a moment" are not. The
    /// same test decides what the model may see, what counts as another chat being open, and what
    /// confirms the right one.
    public static func targetName(in names: [String], _ target: String) -> String? {
        let wanted = normalized(target)
        guard !wanted.isEmpty else { return nil }
        return names.first { normalized($0) == wanted }
    }

    public static func targetState(_ target: String, in snapshot: AccessibilitySnapshot) -> TargetState {
        let wanted = normalized(target)
        guard !wanted.isEmpty else { return .unknown }
        if targetIsShown(wanted, in: snapshot) { return .shown }
        // A selected row is the one thing an app shows as open inside a list. If its name is not
        // the target, typing now would put the message in someone else's chat (PR #289 review, F3).
        // Its one name (`rowName`): "Mom, see you soon, 10:32" and a row led by an unread count are
        // Mom's; a "Family" group whose last sender was Mom is not.
        let selectedElsewhere = snapshot.elements.contains { element in
            guard element.isSelected,
                  AccessibilityVocabulary.selectionRoles.contains(element.role) || element.role == "AXButton",
                  snapshot.isInsideList(element) else { return false }
            let names = snapshot.rowNames(of: element)
            return !names.isEmpty && targetName(in: names, target) == nil
        }
        return selectedElsewhere ? .contradicted : .unknown
    }

    /// True when the target's name appears as the window's title or as text outside every list and
    /// scroll area and outside every text field: where an app shows what is open, not where it lists
    /// what could be. Compared whole, after dropping symbols and case, so "Mom" does not confirm
    /// "Mom & Dad". Scroll areas count here because a SwiftUI app often draws its chat list as one
    /// with no list inside, and a row there must not confirm that the chat is open.
    static func targetIsShown(_ wanted: String, in snapshot: AccessibilitySnapshot) -> Bool {
        if let title = snapshot.windowTitle, normalized(title) == wanted { return true }
        return snapshot.elements.contains { element in
            guard !element.isTextInput else { return false }
            let names = [element.title, element.value, element.label].compactMap { $0 }
            guard names.contains(where: { normalized($0) == wanted }) else { return false }
            return !snapshot.isInsideListOrScrollArea(element)
        }
    }

    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
