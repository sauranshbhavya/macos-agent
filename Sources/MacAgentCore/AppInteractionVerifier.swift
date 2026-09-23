import Foundation

/// Checks a goal against a fresh observation, independently of anything the model said
/// (V2 plan §10: "A model saying 'done' is not independent evidence").
public enum AppInteractionVerifier {
    public enum Result: Equatable, Sendable {
        /// The text is in a text field and the target is visibly open.
        case satisfied
        /// The text is in a text field, but nothing outside a list names the target, so Sonny
        /// cannot tell whether it is in the right place.
        case targetUnconfirmed
        case notYet
    }

    public static func check(_ snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> Result {
        if let text = goal.text {
            let placed = snapshot.elements.contains {
                $0.isTextInput
                    && $0.subrole != AccessibilityVocabulary.searchFieldSubrole
                    && $0.value == text
            }
            guard placed else { return .notYet }
            guard let target = goal.target else { return .satisfied }
            return targetIsShown(target, in: snapshot) ? .satisfied : .targetUnconfirmed
        }
        guard let target = goal.target else { return .notYet }
        return targetIsShown(target, in: snapshot) ? .satisfied : .notYet
    }

    /// True when the target's name appears as the window's title or as text outside every list and
    /// outside every text field: where an app shows what is open, not where it lists what could be.
    /// Compared whole, after dropping symbols and case, so "Mom" does not confirm "Mom & Dad".
    static func targetIsShown(_ target: String, in snapshot: AccessibilitySnapshot) -> Bool {
        let wanted = normalized(target)
        guard !wanted.isEmpty else { return false }
        if let title = snapshot.windowTitle, normalized(title) == wanted { return true }
        return snapshot.elements.contains { element in
            guard !element.isTextInput else { return false }
            let names = [element.title, element.value, element.label].compactMap { $0 }
            guard names.contains(where: { normalized($0) == wanted }) else { return false }
            // Scroll areas count as lists here: a SwiftUI app often draws its chat list as a scroll
            // area with no list inside, and a row there must not confirm that the chat is open.
            return !snapshot.ancestors(of: element).contains {
                AccessibilityVocabulary.listRoles.contains($0.role)
            }
        }
    }

    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
