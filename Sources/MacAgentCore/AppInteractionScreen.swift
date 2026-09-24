import Foundation

/// What the model is shown of one cua reading: a short list of elements it may act on, each with
/// a reference that means something only for this reading.
///
/// This is the whole of what leaves the Mac per step, so it is kept small on purpose (V2 plan §8,
/// "new AX text egress needs its own explicit minimization"). The rule goes by role (founders,
/// 2026-09-24), because cua reports no containers and no plain text:
///
/// - Rows and cells, and anything inside a list — where apps keep chats, notes and folders — go
///   only when one's name is exactly the goal's target, by that name alone. WhatsApp draws its
///   chats as plain buttons outside any list, which a rule by container could not see (the live
///   run, 2026-09-24); it stays out of Milestone A.
/// - A text field or text area goes as its kind and a state word — "empty", "holds the target",
///   "holds the text", "holds other text" — never its label or contents.
/// - Anything else goes by its label, and only with the steps the policy would take on it now, so
///   the model is never shown a control Sonny will always refuse; a menu command goes by its path.
/// - The window's title only when the goal names a target, because it is there to show which one
///   is open. A new note sends none.
///
/// Every string is flattened to one line, passed through local redaction and cut to
/// `maxLabelLength`.
public struct AppInteractionScreen: Equatable, Sendable, Encodable {
    public struct Candidate: Equatable, Sendable, Encodable {
        /// "e12": stable only within this reading.
        public let ref: String
        public let kind: String
        public let label: String
        /// The element steps the model may ask for here: a subset of `AppInteractionStepKind`.
        public let can: [String]
        public let state: [String]
        /// x, y, width and height in screen points, the coordinates `click_at` takes.
        public let at: [Int]?
    }

    public let windowTitle: String?
    public let candidates: [Candidate]
    /// The keys `press_key` may send and the shortcuts `shortcut` may press, fixed by the rules.
    public let keys: [String]
    public let shortcuts: [String]
    /// True when candidates were dropped to stay within budget.
    public let partial: Bool
}

/// Builds an `AppInteractionScreen` from a reading and remembers which element each reference
/// points to.
public struct AppInteractionScreenBuilder: Sendable {
    public var maxCandidates = 60
    public var maxLabelLength = 80
    private let redact: @Sendable (String) -> String

    public init(redact: @escaping @Sendable (String) -> String) {
        self.redact = redact
    }

    public struct Built: Sendable {
        public let screen: AppInteractionScreen
        /// Ref to element index in the reading.
        public let references: [String: Int]
    }

    public func build(from state: CuaWindowState, goal: AppInteractionGoal, sonnyWrote: Set<String> = []) -> Built {
        var offers: [Int: [AppInteractionStepKind]] = [:]
        for element in state.elements where Self.shownName(element, in: state, goal: goal) != nil {
            let kinds = Self.offered(element, in: state, goal: goal, sonnyWrote: sonnyWrote)
            if !kinds.isEmpty { offers[element.index] = kinds }
        }
        let shown = state.elements.filter { offers[$0.index] != nil }
        let chosen = Self.prioritised(shown, in: state, goal: goal).prefix(maxCandidates)
            .sorted { $0.index < $1.index }

        var references: [String: Int] = [:]
        var candidates: [AppInteractionScreen.Candidate] = []
        for element in chosen {
            let ref = "e\(element.index)"
            references[ref] = element.index
            candidates.append(AppInteractionScreen.Candidate(
                ref: ref,
                kind: Self.kind(of: element, in: state),
                label: clean(Self.shownName(element, in: state, goal: goal) ?? ""),
                can: (offers[element.index] ?? []).map(\.rawValue),
                state: Self.state(of: element, in: state, goal: goal),
                at: element.frame.map { [Int($0.x), Int($0.y), Int($0.w), Int($0.h)] }
            ))
        }

        return Built(
            screen: AppInteractionScreen(
                windowTitle: goal.target != nil ? state.windowTitle.map(clean) : nil,
                candidates: candidates,
                keys: AppInteractionPolicy.allowedKeys,
                shortcuts: AppInteractionPolicy.allowedShortcuts,
                partial: shown.count > chosen.count
            ),
            references: references
        )
    }

    // MARK: - Selection

    /// The name an element is shown to the model by, or nil when it is not shown at all.
    static func shownName(_ element: CuaElement, in state: CuaWindowState, goal: AppInteractionGoal) -> String? {
        guard element.role != "AXWindow" else { return nil }
        if element.role == "AXMenuItem" {
            return state.menuPath(of: element)?.joined(separator: " › ")
        }
        if state.isInMenus(element) { return nil }
        if state.isTextInput(element) {
            return state.isInsideList(element) ? nil : ""
        }
        if state.isPrivateByRole(element) {
            guard let target = goal.target, AppInteractionVerifier.isTarget(element.label, target) else { return nil }
            return target
        }
        return element.label
    }

    /// The element steps the policy would take on this element now. Two refusals that hold only
    /// for the moment stay on offer — a box holding the person's own text, and someone else's chat
    /// being open — so choosing one ends the run with its plain reason, or lets the model move
    /// first, rather than leaving the model to guess why the box vanished.
    static func offered(
        _ element: CuaElement,
        in state: CuaWindowState,
        goal: AppInteractionGoal,
        sonnyWrote: Set<String>
    ) -> [AppInteractionStepKind] {
        capabilities(of: element, in: state).filter { kind in
            // Any direction stands in for scrolling in general.
            let input = kind == .scroll ? "down" : nil
            switch AppInteractionPolicy.decideOnElement(kind, element, in: state, goal: goal, sonnyWrote: sonnyWrote, input: input) {
            case .allow, .refuse(.wouldReplaceTypedText), .refuse(.otherTargetOpen): return true
            case .refuse: return false
            }
        }
    }

    /// What the element itself could take, before the policy has its say.
    static func capabilities(of element: CuaElement, in state: CuaWindowState) -> [AppInteractionStepKind] {
        if element.role == "AXMenuItem" { return [.menu] }
        var kinds: [AppInteractionStepKind] = []
        if AppInteractionRoles.clickable.contains(element.role) || element.actions.contains("AXPress") {
            kinds += [.click, .doubleClick, .rightClick]
        }
        if state.isTextInput(element) {
            kinds.append(state.isSearchField(element) ? .enterTarget : .enterText)
        }
        if element.actions.contains(where: { $0.hasPrefix("AXScroll") }) { kinds.append(.scroll) }
        return kinds
    }

    /// Text fields first, then anything named for the target, then the rest in window order, and
    /// menu commands last, so the cap drops the least useful elements.
    static func prioritised(_ elements: [CuaElement], in state: CuaWindowState, goal: AppInteractionGoal) -> [CuaElement] {
        func rank(_ element: CuaElement) -> Int {
            if state.isTextInput(element) { return 0 }
            if let target = goal.target, AppInteractionVerifier.isTarget(element.label, target) { return 1 }
            if element.role == "AXMenuItem" { return 3 }
            return 2
        }
        return elements.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rank(lhs.element), rank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Wording

    static func kind(of element: CuaElement, in state: CuaWindowState) -> String {
        if state.isSearchField(element) { return "search field" }
        switch element.role {
        case "AXTextField", "AXComboBox": return "text field"
        case "AXTextArea": return "text area"
        case "AXButton": return "button"
        case "AXRow", "AXOutlineRow": return "row"
        case "AXCell": return "cell"
        case "AXRadioButton", "AXTab": return "tab"
        case "AXLink": return "link"
        case "AXMenuItem": return "menu command"
        case "AXCheckBox": return "checkbox"
        case "AXPopUpButton", "AXMenuButton": return "menu button"
        default: return element.role.hasPrefix("AX") ? String(element.role.dropFirst(2)).lowercased() : element.role
        }
    }

    /// Selection, and for a text field what it holds, as a word rather than the text.
    static func state(of element: CuaElement, in state: CuaWindowState, goal: AppInteractionGoal) -> [String] {
        var words: [String] = []
        if element.isSelected { words.append("selected") }
        if state.isTextInput(element) {
            let typed = element.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if typed.isEmpty {
                words.append("empty")
            } else if let target = goal.target, AppInteractionPolicy.sameText(typed, target) {
                words.append("holds the target")
            } else if let text = goal.text, AppInteractionPolicy.sameText(typed, text) {
                words.append("holds the text")
            } else {
                words.append("holds other text")
            }
        }
        return words
    }

    private func clean(_ text: String) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let redacted = redact(flattened)
        return redacted.count > maxLabelLength ? String(redacted.prefix(maxLabelLength)) + "…" : redacted
    }
}
