import Foundation

/// What the model is shown of one observation: a short list of elements it may act on, each with
/// a reference that means something only for this observation.
///
/// This is the whole of what leaves the Mac per step, so it is kept small on purpose (V2 plan §8,
/// "new AX text egress needs its own explicit minimization"). Exactly this goes:
///
/// - Elements a step could act on that sit **outside** every list and scroll area — a search
///   field, the message box, a toolbar — each named by one string, `displayName(of:)`.
/// - From **inside** lists and scroll areas, only row-like elements whose name contains the
///   target's, named by that one name. A chat row's last-message preview is its second text and is
///   never read; the conversation's messages are not rows matching the target and are left out
///   (PR #289 review, F4). A message that happens to be named like the target can still appear,
///   cut to one short line: that residue is the price of letting the model pick between "Mom" and
///   "Mom & Dad".
/// - A text field's contents never: only whether it is empty, holds the target, holds the
///   message, or holds something else.
/// - Headings and similar text outside every list and scroll area, such as the name at the top of
///   an open chat.
///
/// Every string is flattened to one line, passed through local redaction and cut to
/// `maxLabelLength`.
public struct AppInteractionScreen: Equatable, Sendable, Encodable {
    public struct Candidate: Equatable, Sendable, Encodable {
        /// "e12": stable only within this screen.
        public let ref: String
        public let kind: String
        public let label: String
        /// What the model may ask for on this element: a subset of `AppInteractionStepKind`.
        public let can: [String]
        public let state: [String]
    }

    public let windowTitle: String?
    public let candidates: [Candidate]
    public let context: [String]
    /// True when the observation stopped early or candidates were dropped to stay within budget.
    public let partial: Bool
}

/// Builds an `AppInteractionScreen` from a snapshot and remembers which element each reference
/// points to.
public struct AppInteractionScreenBuilder: Sendable {
    public var maxCandidates = 60
    public var maxContext = 12
    public var maxLabelLength = 80
    private let redact: @Sendable (String) -> String

    public init(redact: @escaping @Sendable (String) -> String) {
        self.redact = redact
    }

    public struct Built: Sendable {
        public let screen: AppInteractionScreen
        public let references: [String: AccessibilityElementID]
    }

    public func build(from snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> Built {
        let shown = snapshot.elements.filter { Self.isActionable($0) && Self.mayBeShown($0, in: snapshot, goal: goal) }
        let chosen = Self.prioritised(shown, in: snapshot, goal: goal).prefix(maxCandidates)
            .sorted { $0.id.index < $1.id.index }

        var references: [String: AccessibilityElementID] = [:]
        var candidates: [AppInteractionScreen.Candidate] = []
        for element in chosen {
            let ref = "e\(element.id.index)"
            references[ref] = element.id
            candidates.append(
                AppInteractionScreen.Candidate(
                    ref: ref,
                    kind: Self.kind(of: element),
                    label: clean(snapshot.displayName(of: element)),
                    can: Self.capabilities(of: element).map(\.rawValue),
                    state: Self.state(of: element, goal: goal)
                )
            )
        }

        let context = snapshot.elements
            .filter { Self.isContext($0, in: snapshot) }
            .compactMap { $0.title ?? $0.value ?? $0.label }
            .map(clean)
            .filter { !$0.isEmpty }
            .prefix(maxContext)

        return Built(
            screen: AppInteractionScreen(
                windowTitle: snapshot.windowTitle.map(clean),
                candidates: candidates,
                context: Array(context),
                partial: !snapshot.isComplete || shown.count > chosen.count
            ),
            references: references
        )
    }

    // MARK: - Selection

    static func isActionable(_ element: AccessibilityElement) -> Bool {
        guard element.isEnabled, !windowChromeSubroles.contains(element.subrole ?? "") else { return false }
        return !capabilities(of: element).isEmpty
    }

    /// Outside lists and scroll areas, anything actionable. Inside them, only a row-like element
    /// whose name contains the target's: the rows the goal is about, and nothing of the
    /// conversation.
    static func mayBeShown(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> Bool {
        guard snapshot.isInsideListOrScrollArea(element) else { return true }
        guard AccessibilityVocabulary.selectionRoles.contains(element.role) || element.role == "AXButton",
              let target = goal.target else { return false }
        let wanted = AppInteractionVerifier.normalized(target)
        return !wanted.isEmpty && AppInteractionVerifier.normalized(snapshot.displayName(of: element)).contains(wanted)
    }

    static func capabilities(of element: AccessibilityElement) -> [AppInteractionStepKind] {
        var kinds: [AppInteractionStepKind] = []
        if element.canPress { kinds.append(.press) }
        if element.canSelect { kinds.append(.select) }
        if element.isTextInput && element.canSetValue {
            kinds.append(element.isSearchField ? .enterTarget : .enterText)
        } else if element.isTextInput && element.canFocus {
            kinds.append(.focus)
        }
        return kinds
    }

    /// Text fields first, then anything whose name mentions the target, then the rest in window
    /// order, so the cap drops the least useful elements.
    static func prioritised(
        _ elements: [AccessibilityElement],
        in snapshot: AccessibilitySnapshot,
        goal: AppInteractionGoal
    ) -> [AccessibilityElement] {
        let target = goal.target.map(AppInteractionVerifier.normalized)
        func rank(_ element: AccessibilityElement) -> Int {
            if element.isTextInput { return 0 }
            if let target, !target.isEmpty,
               AppInteractionVerifier.normalized(snapshot.displayName(of: element)).contains(target) { return 1 }
            return 2
        }
        return elements.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rank(lhs.element), rank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func isContext(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> Bool {
        guard ["AXStaticText", "AXHeading"].contains(element.role),
              !snapshot.isInsideListOrScrollArea(element) else { return false }
        return !snapshot.ancestors(of: element).contains { isActionable($0) }
    }

    // MARK: - Wording

    static func kind(of element: AccessibilityElement) -> String {
        if element.isSearchField { return "search field" }
        switch element.role {
        case "AXTextField", "AXComboBox": return "text field"
        case "AXTextArea": return "text area"
        case "AXButton": return "button"
        case "AXRow", "AXOutlineRow": return "row"
        case "AXCell": return "cell"
        case "AXRadioButton", "AXTab": return "tab"
        case "AXLink": return "link"
        case "AXMenuItem": return "menu item"
        case "AXCheckBox": return "checkbox"
        case "AXPopUpButton", "AXMenuButton": return "menu button"
        case "AXStaticText": return "text"
        default: return element.role.hasPrefix("AX") ? String(element.role.dropFirst(2)).lowercased() : element.role
        }
    }

    /// Focus, selection, and for a text field what it holds, as a word rather than the text.
    static func state(of element: AccessibilityElement, goal: AppInteractionGoal) -> [String] {
        var state: [String] = []
        if element.isFocused { state.append("focused") }
        if element.isSelected { state.append("selected") }
        if element.isTextInput {
            if let typed = element.typedText {
                if let target = goal.target, AppInteractionPolicy.sameText(typed, target) {
                    state.append("holds the target")
                } else if let text = goal.text, AppInteractionPolicy.sameText(typed, text) {
                    state.append("holds the message")
                } else {
                    state.append("holds other text")
                }
            } else {
                state.append("empty")
            }
        }
        return state
    }

    private func clean(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let redacted = redact(flattened)
        return redacted.count > maxLabelLength ? String(redacted.prefix(maxLabelLength)) + "…" : redacted
    }

    static let windowChromeSubroles: Set<String> = [
        "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXToolbarButton",
    ]
}

/// The step kinds the model may choose. `enterTarget` and `enterText` carry no text: the runtime
/// types the goal's own `target` or `text`, never words the model supplies.
public enum AppInteractionStepKind: String, CaseIterable, Sendable, Codable {
    case press
    case select
    case focus
    case enterTarget = "enter_target"
    case enterText = "enter_text"
}
