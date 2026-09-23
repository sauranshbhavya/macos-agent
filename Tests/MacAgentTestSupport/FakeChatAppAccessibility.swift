import CoreGraphics
import Foundation
import MacAgentCore

/// A chat app's Accessibility tree, small enough to reason about in a test and shaped like the
/// common layout: a search field over a list of chats, and for the open chat a name at the top, a
/// call button, a message box and a Send button.
///
/// Every action the provider receives is applied to this state, so a test asserts on what the app
/// ended up holding (`drafts`, `sentMessages`, `callsPlaced`) rather than on which calls were made.
public struct FakeChatAppState: Sendable, Equatable {
    public var chats: [String]
    public var openChat: String?
    public var search = ""
    public var drafts: [String: String] = [:]
    public var sentMessages: [String] = []
    public var callsPlaced = 0
    /// Off models an app whose open-chat name is not exposed to Accessibility.
    public var exposesHeader = true
    /// "AXRow", or "AXButton" for an app that draws its rows as buttons.
    public var rowRole = "AXRow"
    /// Off models an app whose message box ignores `AXValue` writes.
    public var messageBoxIsSettable = true

    public init(chats: [String], openChat: String? = nil) {
        self.chats = chats
        self.openChat = openChat
    }
}

public actor FakeChatAppAccessibility: AccessibilityProviding {
    public private(set) var state: FakeChatAppState
    public private(set) var performed: [AccessibilityAction] = []
    public private(set) var observations = 0
    private var trusted: Bool
    /// Observations that answer `.noWindow` before the window appears.
    private var windowlessObservations: Int
    private var generation = 0
    private var keys: [String] = []

    public init(state: FakeChatAppState, trusted: Bool = true, windowlessObservations: Int = 0) {
        self.state = state
        self.trusted = trusted
        self.windowlessObservations = windowlessObservations
    }

    public func isTrusted() -> Bool { trusted }

    public func revokeTrust() { trusted = false }

    public func observe(processIdentifier: pid_t, limits: AccessibilityLimits) throws -> AccessibilitySnapshot {
        guard trusted else { throw AccessibilityError.notTrusted }
        observations += 1
        if windowlessObservations > 0 {
            windowlessObservations -= 1
            throw AccessibilityError.noWindow
        }
        generation += 1
        var builder = TreeBuilder(generation: generation)
        let window = builder.add("window", role: "AXWindow", parent: nil, title: "Chats")
        let sidebar = builder.add("sidebar", role: "AXGroup", parent: window)
        builder.add(
            "search", role: "AXTextField", parent: sidebar, subrole: AccessibilityVocabulary.searchFieldSubrole,
            placeholder: "Search", value: state.search.isEmpty ? nil : state.search, canSetValue: true, canFocus: true
        )
        let scroll = builder.add("scroll", role: "AXScrollArea", parent: sidebar)
        let list = builder.add("list", role: "AXTable", parent: scroll)
        let visible = state.search.isEmpty
            ? state.chats
            : state.chats.filter { $0.localizedCaseInsensitiveContains(state.search) }
        for chat in visible {
            let row = builder.add(
                "row:\(chat)", role: state.rowRole, parent: list,
                isSelected: chat == state.openChat, actions: ["AXPress"], canSelect: state.rowRole == "AXRow"
            )
            builder.add("rowtext:\(chat)", role: "AXStaticText", parent: row, value: chat)
            builder.add("preview:\(chat)", role: "AXStaticText", parent: row, value: "last message in \(chat)")
        }
        let main = builder.add("main", role: "AXGroup", parent: window)
        if let open = state.openChat {
            if state.exposesHeader {
                builder.add("header", role: "AXStaticText", parent: main, value: open)
            }
            builder.add("call", role: "AXButton", parent: main, label: "Voice call", actions: ["AXPress"])
            let messages = builder.add("messages", role: "AXScrollArea", parent: main)
            builder.add("bubble", role: "AXStaticText", parent: messages, value: "an earlier private message")
            builder.add(
                "messagebox", role: "AXTextArea", parent: main, placeholder: "Type a message",
                value: state.drafts[open], canSetValue: state.messageBoxIsSettable, canFocus: true
            )
            builder.add("send", role: "AXButton", parent: main, label: "Send", actions: ["AXPress"])
        }
        keys = builder.keys
        return AccessibilitySnapshot(
            generation: generation,
            app: AccessibilityObservedApp(bundleIdentifier: "com.example.chat", processIdentifier: processIdentifier, name: "Chat"),
            windowTitle: "Chats",
            elements: builder.elements,
            truncation: nil,
            takenAt: Date(timeIntervalSince1970: 0)
        )
    }

    public func perform(_ action: AccessibilityAction, on element: AccessibilityElementID) throws {
        guard trusted else { throw AccessibilityError.notTrusted }
        guard element.generation == generation, keys.indices.contains(element.index) else {
            throw AccessibilityError.staleElement
        }
        performed.append(action)
        let key = keys[element.index]
        switch (key, action) {
        case (let key, .press) where key.hasPrefix("row:"), (let key, .select) where key.hasPrefix("row:"):
            state.openChat = String(key.dropFirst("row:".count))
        case ("search", .setValue(let text)):
            state.search = text
        case ("messagebox", .setValue(let text)):
            guard state.messageBoxIsSettable, let open = state.openChat else { throw AccessibilityError.valueNotSettable }
            state.drafts[open] = text
        case ("send", .press):
            if let open = state.openChat, let draft = state.drafts[open] {
                state.sentMessages.append(draft)
                state.drafts[open] = nil
            }
        case ("call", .press):
            state.callsPlaced += 1
        case (_, .focus):
            break
        default:
            throw AccessibilityError.actionUnsupported
        }
    }

    private struct TreeBuilder {
        let generation: Int
        var elements: [AccessibilityElement] = []
        var keys: [String] = []
        var depths: [Int] = []

        @discardableResult
        mutating func add(
            _ key: String,
            role: String,
            parent: Int?,
            subrole: String? = nil,
            title: String? = nil,
            label: String? = nil,
            placeholder: String? = nil,
            value: String? = nil,
            isSelected: Bool = false,
            actions: [String] = [],
            canSetValue: Bool = false,
            canFocus: Bool = false,
            canSelect: Bool = false
        ) -> Int {
            let index = elements.count
            let depth = parent.map { depths[$0] + 1 } ?? 0
            elements.append(AccessibilityElement(
                id: AccessibilityElementID(generation: generation, index: index),
                parentIndex: parent,
                depth: depth,
                role: role,
                subrole: subrole,
                title: title,
                label: label,
                placeholder: placeholder,
                value: value,
                isSelected: isSelected,
                actions: actions,
                canSetValue: canSetValue,
                canFocus: canFocus,
                canSelect: canSelect,
                frame: CGRect(x: 0, y: CGFloat(index) * 10, width: 100, height: 10)
            ))
            keys.append(key)
            depths.append(depth)
            return index
        }
    }
}
