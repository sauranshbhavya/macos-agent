import Foundation

/// What the model is shown of one observation: a short list of elements it may act on, each with
/// a reference that means something only for this observation.
///
/// This is the whole of what leaves the Mac per step, so it is kept small on purpose (V2 plan §8,
/// "new AX text egress needs its own explicit minimization"). Exactly this goes:
///
/// - Elements a step could act on that sit **outside** every list and scroll area — the search
///   field, a toolbar — each named by one string, `displayName(of:)`.
/// - Text fields outside a list, the message box included even inside a scroll area, because a
///   Mac text view always sits in one (PR #289 delta review, N1) — but inside a scroll area only a
///   writable one, so a read-only message bubble is not a field. Named by placeholder alone, never
///   by a title or description a bubble could carry its message in (final check, F4), and never
///   their contents: only whether one is empty, holds the target, holds the message, or holds
///   something else.
/// - From **inside** lists and scroll areas, only row-like elements whose one name (`rowName`) *is*
///   the target, compared whole (`AppInteractionVerifier.isTarget`), shown by that name alone. A
///   combined label's preview, a row's other texts and the conversation's messages never match and
///   never go. What can still go is a message whose first text is exactly the target's name — the
///   word "Mom" on its own.
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
        let shown = snapshot.elements.filter { Self.isActionable($0) && Self.shownName($0, in: snapshot, goal: goal) != nil }
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
                    label: clean(Self.shownName(element, in: snapshot, goal: goal) ?? ""),
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

    /// The name an element is shown to the model by, or nil when it is not shown at all. Text
    /// fields outside lists and everything outside lists and scroll areas go by `displayName`.
    /// Inside them, only a row-like element with a name that is the target, shown by that name.
    static func shownName(_ element: AccessibilityElement, in snapshot: AccessibilitySnapshot, goal: AppInteractionGoal) -> String? {
        if element.isTextInput {
            guard !snapshot.isInsideList(element) else { return nil }
            if snapshot.isInsideListOrScrollArea(element), !element.canSetValue { return nil }
            return element.placeholder ?? ""
        }
        guard snapshot.isInsideListOrScrollArea(element) else { return snapshot.displayName(of: element) }
        guard AccessibilityVocabulary.selectionRoles.contains(element.role) || element.role == "AXButton",
              let target = goal.target,
              let name = snapshot.rowName(of: element),
              AppInteractionVerifier.isTarget(name, target) else { return nil }
        return name
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
        func rank(_ element: AccessibilityElement) -> Int {
            if element.isTextInput { return 0 }
            if let target = goal.target, AppInteractionVerifier.isTarget(snapshot.rowName(of: element), target) { return 1 }
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
