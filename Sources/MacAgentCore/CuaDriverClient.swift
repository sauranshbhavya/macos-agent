import Foundation

/// cua's own ceiling for Sonny, written as the capability manifest cua reads in `bounded` mode:
/// the only tools it will run and the only apps they may touch. It is a second fence behind
/// `AppInteractionPolicy`, not the rules themselves — measured 2026-09-24, a tool outside it
/// answers "Permission denied: tool '…' is outside the capability manifest", and another app
/// "desktop application pid … is outside the capability manifest".
public struct CuaCapabilityManifest: Equatable, Sendable {
    public let tools: [String]
    /// Exactly as the app declares its bundle identifier.
    public let bundleIdentifiers: [String]

    public init(tools: [String], bundleIdentifiers: [String]) {
        self.tools = tools
        self.bundleIdentifiers = bundleIdentifiers
    }

    /// The on-screen tools the founders allowed, less dragging, which the rules refuse for now
    /// (2026-09-24), and Notes. Never the clipboard, configuration, updates, extensions,
    /// recording, killing an app, browser downloads or a capture of the whole screen.
    public static let milestoneA = CuaCapabilityManifest(
        tools: [
            "check_permissions", "list_windows", "get_window_state",
            "click", "double_click", "right_click", "set_value", "type_text",
            "press_key", "hotkey", "scroll", "invoke_menu",
        ],
        bundleIdentifiers: ["com.apple.Notes"]
    )

    public var yaml: String {
        // One run's worth: the app creates a driver per run, so the ceiling never outlives one.
        var lines = ["version: 3", "expires_after: 1h", "idle_timeout: 30m", "", "allow:", "  tools:"]
        lines += tools.map { "    - \($0)" }
        lines += ["", "resources:", "  apps:"]
        for bundleIdentifier in bundleIdentifiers {
            // Sonny opens the app itself, so cua may not launch or quit one.
            lines += ["    - bundle_id: \(bundleIdentifier)", "      launch: false", "      windows: all"]
        }
        lines += ["", "  desktop:", "    display: false", ""]
        return lines.joined(separator: "\n")
    }
}

// MARK: - What cua reports

public struct CuaFrame: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + w && py >= y && py < y + h
    }
}

/// One window from `list_windows`.
public struct CuaWindow: Decodable, Equatable, Sendable {
    public let windowID: Int
    public let pid: Int32
    public let isOnScreen: Bool
    public let bounds: Bounds?

    public struct Bounds: Decodable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id", pid, isOnScreen = "is_on_screen", bounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try container.decode(Int.self, forKey: .windowID)
        pid = try container.decode(Int32.self, forKey: .pid)
        isOnScreen = try container.decodeIfPresent(Bool.self, forKey: .isOnScreen) ?? false
        bounds = try container.decodeIfPresent(Bounds.self, forKey: .bounds)
    }

    var area: Double { (bounds?.width ?? 0) * (bounds?.height ?? 0) }
}

/// One entry of `get_window_state`'s structured `elements`. cua lists only elements with
/// something to act on, plus the window, toolbar and menus: plain text and containers such as
/// groups are left out (measured on Calculator and Notes, 2026-09-24).
public struct CuaElement: Decodable, Equatable, Sendable {
    public let index: Int
    public let role: String
    public let label: String?
    /// The element's text or AXValue, as cua reports it.
    public let value: String?
    public let enabled: Bool?
    public let selected: Bool?
    public let actions: [String]
    public let frame: CuaFrame?
    public let parentIndex: Int?
    public let token: String?

    enum CodingKeys: String, CodingKey {
        case index = "element_index", role, label, value, enabled, selected, actions, frame
        case parentIndex = "parent_index", token = "element_token"
    }

    public init(
        index: Int, role: String, label: String? = nil, value: String? = nil, enabled: Bool? = nil,
        selected: Bool? = nil, actions: [String] = [], frame: CuaFrame? = nil, parentIndex: Int? = nil,
        token: String? = nil
    ) {
        self.index = index; self.role = role; self.label = label; self.value = value
        self.enabled = enabled; self.selected = selected; self.actions = actions; self.frame = frame
        self.parentIndex = parentIndex; self.token = token
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "AXUnknown"
        label = try container.decodeIfPresent(String.self, forKey: .label).flatMap { $0.isEmpty ? nil : $0 }
        // A value is text for a field but a number for a checkbox or slider.
        if let text = try? container.decodeIfPresent(String.self, forKey: .value) {
            value = text
        } else if let number = try? container.decodeIfPresent(Double.self, forKey: .value) {
            value = String(number)
        } else if let flag = try? container.decodeIfPresent(Bool.self, forKey: .value) {
            value = String(flag)
        } else {
            value = nil
        }
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected)
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
        frame = try container.decodeIfPresent(CuaFrame.self, forKey: .frame)
        parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
        token = try container.decodeIfPresent(String.self, forKey: .token)
    }

    public var isEnabled: Bool { enabled ?? true }
    public var isSelected: Bool { selected ?? false }
}

/// One `get_window_state` reading. Element indexes mean something only with this `snapshotID`.
public struct CuaWindowState: Decodable, Equatable, Sendable {
    public let snapshotID: String?
    public let windowID: Int
    public let windowTitle: String?
    public let elements: [CuaElement]
    /// Set when cua could not read the window, which then comes back with no elements.
    public let degradedReason: String?
    /// cua's Markdown rendering of the same tree, the one place it gives a row's name when the name
    /// sits in a child text. Read on the Mac only, to find a folder Sonny opens itself
    /// (`rows(named:)`); the screen the model sees is built from `elements` and never carries it.
    public let treeMarkdown: String?

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id", windowID = "window_id", windowTitle = "window_title", elements
        case degradedReason = "degraded_reason", treeMarkdown = "tree_markdown"
    }

    public init(
        snapshotID: String?, windowID: Int, windowTitle: String? = nil, elements: [CuaElement],
        degradedReason: String? = nil, treeMarkdown: String? = nil
    ) {
        self.snapshotID = snapshotID
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.elements = elements
        self.degradedReason = degradedReason
        self.treeMarkdown = treeMarkdown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshotID = try container.decodeIfPresent(String.self, forKey: .snapshotID)
        windowID = try container.decode(Int.self, forKey: .windowID)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        elements = try container.decodeIfPresent([CuaElement].self, forKey: .elements) ?? []
        degradedReason = try container.decodeIfPresent(String.self, forKey: .degradedReason)
        treeMarkdown = try container.decodeIfPresent(String.self, forKey: .treeMarkdown)
    }
}

/// A tool that answered with `isError`: a refusal, a stale element, a missing window.
public struct CuaToolError: Error, Equatable, Sendable {
    public let tool: String
    /// cua's refusal code when it gave one, such as `menu_path_unavailable`.
    public let code: String?
    public let message: String

    /// cua's own ceiling refused the call: a tool or an app outside the manifest.
    public var isOutsideCeiling: Bool { message.contains("outside the capability manifest") }
}

// MARK: - The calls Sonny makes

/// A reference to one element of one reading: stale once the app redraws, which cua detects
/// by the token and refuses rather than acting on something else.
public struct CuaElementRef: Equatable, Sendable {
    public let snapshotID: String?
    public let index: Int
    public let token: String?

    public init(snapshotID: String?, index: Int, token: String?) {
        self.snapshotID = snapshotID
        self.index = index
        self.token = token
    }

    public init(_ element: CuaElement, in state: CuaWindowState) {
        self.init(snapshotID: state.snapshotID, index: element.index, token: element.token)
    }
}

public enum CuaAction: Equatable, Sendable {
    case click(CuaElementRef)
    case doubleClick(CuaElementRef)
    case rightClick(CuaElementRef)
    case setValue(CuaElementRef, String)
    /// Inserts at the element's selection, for a field that takes no whole value.
    case typeText(CuaElementRef, String)
    case pressKey(String)
    case hotkey([String])
    case scroll(CuaElementRef?, direction: String)
    case menu([String])
}

/// The runtime's typed door to cua. Every call goes through `CuaToolInvoking`, so the JSON it
/// sends is what the fake app in the tests reads.
public struct CuaDriverClient: Sendable {
    private let invoker: any CuaToolInvoking

    public init(invoker: any CuaToolInvoking) {
        self.invoker = invoker
    }

    /// Sonny's own Accessibility grant: in-process, cua reports the host app's permission.
    public func accessibilityGranted() async throws -> Bool {
        let result = try await call("check_permissions", [:])
        return (result["accessibility"] as? Bool) ?? false
    }

    public func windows(pid: pid_t) async throws -> [CuaWindow] {
        try await decode([CuaWindow].self, from: call("list_windows", ["pid": Int(pid)])["windows"] ?? [])
    }

    public func windowState(pid: pid_t, windowID: Int) async throws -> CuaWindowState {
        try await decode(CuaWindowState.self, from: call("get_window_state", [
            "pid": Int(pid), "window_id": windowID, "include_screenshot": false, "timeout_ms": 3000,
        ]))
    }

    public func perform(_ action: CuaAction, pid: pid_t, windowID: Int) async throws {
        let base: [String: Any] = ["pid": Int(pid), "window_id": windowID]
        func element(_ ref: CuaElementRef) -> [String: Any] {
            var arguments = base
            arguments["element_index"] = ref.index
            if let snapshotID = ref.snapshotID { arguments["snapshot_id"] = snapshotID }
            if let token = ref.token { arguments["element_token"] = token }
            return arguments
        }
        switch action {
        case .click(let ref): _ = try await call("click", element(ref))
        case .doubleClick(let ref): _ = try await call("double_click", element(ref))
        case .rightClick(let ref): _ = try await call("right_click", element(ref))
        case .setValue(let ref, let text): _ = try await call("set_value", element(ref).merging(["value": text]) { $1 })
        case .typeText(let ref, let text): _ = try await call("type_text", element(ref).merging(["text": text]) { $1 })
        case .pressKey(let key): _ = try await call("press_key", base.merging(["key": key]) { $1 })
        case .hotkey(let keys): _ = try await call("hotkey", base.merging(["keys": keys]) { $1 })
        case .scroll(let ref, let direction):
            _ = try await call("scroll", (ref.map(element) ?? base).merging(["direction": direction]) { $1 })
        case .menu(let path): _ = try await call("invoke_menu", base.merging(["path": path]) { $1 })
        }
    }

    /// One tool call: the arguments as JSON, and the structured part of its answer, or the
    /// answer's own message when it is an error.
    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let data = try await invoker.invoke(tool, arguments: JSONSerialization.data(withJSONObject: arguments))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CuaToolError(tool: tool, code: nil, message: "cua answered with something that is not a JSON object")
        }
        let structured = object["structuredContent"] as? [String: Any] ?? [:]
        if (object["isError"] as? Bool) == true {
            let refusal = structured["refusal"] as? [String: Any]
            let text = (object["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            throw CuaToolError(
                tool: tool,
                code: refusal?["code"] as? String,
                message: (refusal?["message"] as? String) ?? text ?? "cua refused \(tool)"
            )
        }
        return structured
    }

    private func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
