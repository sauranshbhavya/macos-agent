import Foundation

/// Checks a goal against a fresh cua reading, independently of anything the model said
/// (V2 plan §10: "A model saying 'done' is not independent evidence").
public enum AppInteractionVerifier {
    public enum Result: Equatable, Sendable {
        /// The text is in a field Sonny could have written, and the target, if any, is visibly open.
        case satisfied
        /// The text is in place, but nothing names the target as open, so Sonny cannot tell
        /// whether it is in the right place.
        case targetUnconfirmed
        /// Something else is visibly open: never a success, whatever the field holds.
        case otherTargetOpen
        case notYet
    }

    /// What a reading says about whether the target is the thing open.
    public enum TargetState: Equatable, Sendable {
        case shown
        /// A selected row in a list names something else, and nothing names the target.
        case contradicted
        case unknown
    }

    public static func check(_ state: CuaWindowState, goal: AppInteractionGoal) -> Result {
        let target = goal.target.map { targetState($0, in: state) }
        if target == .contradicted { return .otherTargetOpen }
        guard let text = goal.text else { return target == .shown ? .satisfied : .notYet }
        guard textIsPlaced(text, in: state) else { return .notYet }
        guard let target else { return .satisfied }
        return target == .shown ? .satisfied : .targetUnconfirmed
    }

    /// The text sits in a field Sonny could have written: a text field or area that is not a
    /// search field and not inside a list (PR #289 review, F7). Compared apart from whitespace at
    /// either end, which an editor may add or drop around a value it was given.
    static func textIsPlaced(_ text: String, in state: CuaWindowState) -> Bool {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.elements.contains {
            state.isTextInput($0) && !state.isSearchField($0) && !state.isInsideList($0)
                && $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        }
    }

    /// Whether a name is the target, compared whole after dropping case and symbols, so "Mom ❤️"
    /// is Mom and "Mom & Dad" and "Family" are not.
    public static func isTarget(_ name: String?, _ target: String) -> Bool {
        let wanted = normalized(target)
        guard !wanted.isEmpty, let name else { return false }
        return normalized(AppInteractionPolicy.firstSegment(name)) == wanted || normalized(name) == wanted
    }

    public static func targetState(_ target: String, in state: CuaWindowState) -> TargetState {
        if isTarget(state.windowTitle, target) { return .shown }
        // Something outside every list naming the target, such as a heading over an open chat.
        if state.elements.contains(where: { !state.isPrivateByRole($0) && !state.isTextInput($0) && !state.isInMenus($0) && isTarget($0.label, target) }) {
            return .shown
        }
        // A selected row is the one thing an app shows as open inside a list. If its name is not
        // the target, typing now would put the text in someone else's (PR #289 review, F3).
        let selectedElsewhere = state.elements.contains { element in
            element.isSelected && AppInteractionRoles.rows.contains(element.role)
                && element.label != nil && !isTarget(element.label, target)
        }
        return selectedElsewhere ? .contradicted : .unknown
    }

    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
