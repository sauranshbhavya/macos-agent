import Foundation

/// What the model is shown of one observation: a short list of elements it may act on, each with
/// a reference that means something only for this observation.
///
/// This is the whole of what leaves the Mac per step, so it is kept small on purpose (V2 plan §8,
/// "new AX text egress needs its own explicit minimization"): only elements a step could act on,
/// labels cut short and passed through local redaction, and context text only from outside lists,
/// which keeps a chat's message history out of the request.
public struct AppInteractionScreen: Equatable, Sendable, Encodable {
    public struct Candidate: Equatable, Sendable, Encodable {
        /// "e12": stable only within this screen.
        public let ref: String
        public let kind: String
        public let label: String
        /// A text field's current contents, so the model can see what is already typed.
        public let value: String?
        /// What the model may ask for on this element: a subset of `AppInteractionStepKind`.
        public let can: [String]
        public let state: [String]
    }

    public let windowTitle: String?
    public let candidates: [Candidate]
    /// Headings and similar text outside any list, such as the name at the top of an open chat.
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
        let actionable = snapshot.elements.filter { Self.isActionable($0) }
        let chosen = Self.prioritised(actionable, goal: goal).prefix(maxCandidates)
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
                    label: clean(Self.label(for: element, in: snapshot)),
                    value: element.isTextInput ? element.value.map(clean) : nil,
                    can: Self.capabilities(of: element).map(\.rawValue),
                    state: Self.state(of: element)
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
                partial: !snapshot.isComplete || actionable.count > chosen.count
            ),
            references: references
        )
    }

    // MARK: - Selection

    static func isActionable(_ element: AccessibilityElement) -> Bool {
        guard element.isEnabled, !windowChromeSubroles.contains(element.subrole ?? "") else { return false }
        return !capabilities(of: element).isEmpty
    }

    static func capabilities(of element: AccessibilityElement) -> [AppInteractionStepKind] {
        var kinds: [AppInteractionStepKind] = []
        if element.canPress { kinds.append(.press) }
        if element.canSelect { kinds.append(.select) }
        if element.isTextInput && element.canSetValue {
            kinds.append(.enterTarget)
            kinds.append(.enterText)
        } else if element.isTextInput && element.canFocus {
            kinds.append(.focus)
        }
        return kinds
    }

    /// Text fields first, then anything whose label mentions the target, then the rest in window
    /// order, so the cap drops the least useful elements.
    static func prioritised(_ elements: [AccessibilityElement], goal: AppInteractionGoal) -> [AccessibilityElement] {
        let target = goal.target?.lowercased()
        func rank(_ element: AccessibilityElement) -> Int {
            if element.isTextInput { return 0 }
            if let target, [element.title, element.label, element.value]
                .compactMap({ $0?.lowercased() }).contains(where: { $0.contains(target) }) { return 1 }
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
        guard ["AXStaticText", "AXHeading"].contains(element.role) else { return false }
        return !snapshot.ancestors(of: element).contains {
            AccessibilityVocabulary.listRoles.contains($0.role) || isActionable($0)
        }
    }

    // MARK: - Wording

    /// An element's own name, or failing that the text inside it: a chat row usually carries no
    /// title of its own and holds the contact's name in a child.
    static func label(for element: AccessibilityElement, in snapshot: AccessibilitySnapshot) -> String {
        if let own = [element.title, element.label].compactMap({ $0 }).first { return own }
        if element.isTextInput, let placeholder = element.placeholder { return placeholder }
        if !element.isTextInput, let value = element.value { return value }
        let inner = snapshot.descendants(of: element)
            .compactMap { $0.title ?? $0.value ?? $0.label }
            .prefix(3)
        return inner.joined(separator: " · ")
    }

    static func kind(of element: AccessibilityElement) -> String {
        if element.subrole == AccessibilityVocabulary.searchFieldSubrole { return "search field" }
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

    static func state(of element: AccessibilityElement) -> [String] {
        var state: [String] = []
        if element.isFocused { state.append("focused") }
        if element.isSelected { state.append("selected") }
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
