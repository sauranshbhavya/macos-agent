import Foundation
import MacAgentCore

/// Notes as cua-driver reports it, answering cua's tool calls in cua's own JSON, so everything
/// above `CuaToolInvoking` runs in tests exactly as it runs against the live library.
///
/// Shaped from what cua-driver 0.28.3 returned for the real Notes window on 2026-09-24: folder rows
/// with no labels of their own inside an `AXOutline`, a folder-name text field inside one row,
/// unnamed buttons, a pressable date line, a toolbar holding named buttons and the search field,
/// the menu bar, and — once a note is open — the editor as an `AXTextArea`. cua lists no containers
/// and no plain text, so neither does this.
///
/// Every call is applied to `state`, so a test asserts on what Notes ended up holding
/// (`notes`, `clicked`, `keysPressed`) rather than on which calls were made.
public struct FakeCuaNotesState: Sendable, Equatable {
    public var folders = ["Notes", "Recipes", "Family"]
    public var selectedFolder = "Notes"
    /// Set to a folder's name to model a New Note that is greyed out everywhere but there, as
    /// Notes' is in a shared view, a smart folder or Recently Deleted.
    public var newNoteOnlyIn: String?
    /// Each note's text. The last one is open in the editor when `editorOpen` is set.
    public var notes: [String] = ["Groceries for Sunday", "Mom's birthday ideas"]
    public var editorOpen = true
    /// Off models File › New Note greyed out, as in Recently Deleted.
    public var newNoteEnabled = true
    /// On models a New Note that leaves the person's last note open instead of a blank one.
    public var newNoteKeepsOpenNote = false
    /// Off models an editor that takes no whole value, so cua's `type_text` has to insert it.
    public var editorTakesValue = true
    /// On models a locked note asking for its password: a secure field stands in the editor's place
    /// and holds the keyboard focus, so text typed at the focus lands in it.
    public var noteLocked = false
    /// What reached the locked note's password field.
    public var passwordTyped = ""
    public var accessibilityGranted = true
    /// Readings that come back degraded, as a window on another Space or still animating does.
    public var degradedReadings = 0
    /// Clicks, by the element's label or role.
    public var clicked: [String] = []
    /// Folders opened by clicking their row.
    public var foldersOpened: [String] = []
    public var keysPressed: [String] = []
    public var shortcuts: [[String]] = []
    public var menus: [[String]] = []
    public var scrolls: [String] = []

    public init() {}
}

public actor FakeCuaNotes: CuaToolInvoking {
    public private(set) var state: FakeCuaNotesState
    private var calls: [(tool: String, arguments: [String: Any])] = []
    private let manifest: CuaCapabilityManifest
    private let pid: Int32
    private var snapshot = 0
    /// Bumped by a test between a reading and an action, as a redraw does.
    private var redrawnSinceReading = false
    public static let mainWindow = 119415
    public static let toolbarStrip = 132320

    public init(state: FakeCuaNotesState = FakeCuaNotesState(), manifest: CuaCapabilityManifest = .forApp("com.apple.Notes"), pid: Int32 = 4242) {
        self.state = state
        self.manifest = manifest
        self.pid = pid
    }

    public func update(_ change: @Sendable (inout FakeCuaNotesState) -> Void) { change(&state) }

    /// The next action sees the window redrawn since the model's reading, so its token is stale.
    public func redraw() { redrawnSinceReading = true }

    public var callNames: [String] { calls.map(\.tool) }

    /// The window each `get_window_state` asked for.
    public var windowsRead: [Int] { calls.filter { $0.tool == "get_window_state" }.compactMap { $0.arguments["window_id"] as? Int } }

    public func invoke(_ tool: String, arguments data: Data) async throws -> Data {
        let arguments = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        calls.append((tool, arguments))
        guard manifest.tools.contains(tool) else {
            return Self.error("Permission denied: tool '\(tool)' is outside the capability manifest")
        }
        if let requested = arguments["pid"] as? Int, requested != Int(pid) {
            return Self.error("protected resource is outside the capability manifest: desktop application pid \(requested) is outside the capability manifest")
        }
        switch tool {
        case "check_permissions":
            return Self.result(["accessibility": state.accessibilityGranted, "screen_recording": false])
        case "list_windows":
            return Self.result(["windows": [
                ["window_id": Self.toolbarStrip, "pid": Int(pid), "is_on_screen": true,
                 "bounds": ["x": 0, "y": 0, "width": 1920, "height": 52], "title": ""],
                ["window_id": Self.mainWindow, "pid": Int(pid), "is_on_screen": true,
                 "bounds": ["x": 0, "y": 0, "width": 1920, "height": 1080], "title": ""],
            ]])
        case "get_window_state":
            guard arguments["window_id"] as? Int == Self.mainWindow else {
                return Self.result(["window_id": arguments["window_id"] ?? 0, "elements": [], "degraded_reason": "ax_window_unresolved: the toolbar strip"])
            }
            if state.degradedReadings > 0 {
                state.degradedReadings -= 1
                return Self.result(["window_id": Self.mainWindow, "elements": [], "degraded_reason": "ax_window_unresolved: off_space"])
            }
            snapshot += 1
            redrawnSinceReading = false
            let listed = elements()
            return Self.result([
                "snapshot_id": "s\(snapshot)", "window_id": Self.mainWindow, "window_title": "Notes",
                "elements": listed.map { $0.json(snapshot: snapshot) },
                "tree_markdown": Self.markdown(listed),
            ])
        case "invoke_menu":
            let path = arguments["path"] as? [String] ?? []
            guard let item = elements().first(where: { $0.menuPath == path }) else {
                return Self.error("invoke_menu: no menu item at that path", code: "menu_path_unavailable")
            }
            guard item.enabled else { return Self.error("invoke_menu: that menu item is disabled", code: "menu_path_unavailable") }
            state.menus.append(path)
            if path == ["File", "New Note"], !state.newNoteKeepsOpenNote {
                state.notes.append("")
                state.editorOpen = true
            }
            return Self.result(["status": "ok"])
        case "click", "double_click", "right_click", "set_value", "type_text", "scroll", "press_key", "hotkey":
            return try act(tool, arguments)
        default:
            return Self.error("the fake Notes does not model \(tool)")
        }
    }

    private func act(_ tool: String, _ arguments: [String: Any]) throws -> Data {
        var target: Element?
        if let index = arguments["element_index"] as? Int {
            // cua refuses a token from an older reading rather than act on something else.
            guard !redrawnSinceReading, arguments["snapshot_id"] as? String == "s\(snapshot)",
                  arguments["element_token"] as? String == "s\(snapshot):\(index)",
                  let element = elements().first(where: { $0.index == index }) else {
                return Self.error("element_token is stale: the window changed since snapshot; re-read it")
            }
            target = element
        }
        switch tool {
        case "set_value", "type_text":
            let text = (arguments["value"] ?? arguments["text"]) as? String ?? ""
            // type_text naming no element goes to the focus: a locked note's password field, or the editor.
            let atFocus = tool == "type_text" && target == nil
            if atFocus, state.noteLocked {
                state.passwordTyped += text
                return Self.result(["effect": "confirmed"])
            }
            guard atFocus || target?.role == "AXTextArea", state.editorOpen, !state.noteLocked else { return Self.error("\(tool): not a text input") }
            if tool == "set_value", !state.editorTakesValue { return Self.error("set_value: AXValue is not settable") }
            state.notes[state.notes.count - 1] = tool == "set_value" ? text : state.notes[state.notes.count - 1] + text
        case "press_key":
            state.keysPressed.append(arguments["key"] as? String ?? "")
        case "hotkey":
            state.shortcuts.append(arguments["keys"] as? [String] ?? [])
        case "scroll":
            state.scrolls.append(arguments["direction"] as? String ?? "")
        default:
            if let folder = target?.folder {
                state.selectedFolder = folder
                state.foldersOpened.append(folder)
            } else {
                state.clicked.append(target?.label ?? target?.role ?? "nothing")
            }
        }
        return Self.result(["effect": "confirmed"])
    }

    // MARK: - The window, as cua lists it

    private struct Element {
        let index: Int
        let role: String
        var label: String?
        var value: String?
        var enabled = true
        var selected: Bool?
        var actions: [String] = []
        var frame: (Double, Double, Double, Double)
        var parent: Int?
        var menuPath: [String]?
        /// For a folder row: the folder's name, which cua lists nowhere but its Markdown.
        var folder: String?

        func json(snapshot: Int) -> [String: Any] {
            var json: [String: Any] = [
                "element_index": index, "role": role, "actions": actions,
                "frame": ["x": frame.0, "y": frame.1, "w": frame.2, "h": frame.3],
                "depth": parent == nil ? 0 : 2, "element_token": "s\(snapshot):\(index)",
            ]
            if let label { json["label"] = label }
            if let value { json["value"] = value }
            if role != "AXRow" { json["enabled"] = enabled }
            if let selected { json["selected"] = selected }
            if let parent { json["parent_index"] = parent }
            return json
        }
    }

    private func elements() -> [Element] {
        var list: [Element] = []
        func add(_ role: String, label: String? = nil, value: String? = nil, actions: [String] = [], at frame: (Double, Double, Double, Double), parent: Int? = 0, selected: Bool? = nil, enabled: Bool = true, menuPath: [String]? = nil, folder: String? = nil) -> Int {
            list.append(Element(index: list.count, role: role, label: label, value: value, enabled: enabled, selected: selected, actions: actions, frame: frame, parent: parent, menuPath: menuPath, folder: folder))
            return list.count - 1
        }
        _ = add("AXWindow", label: "Notes", actions: ["AXRaise"], at: (0, 0, 1920, 1080), parent: nil)
        let outline = add("AXOutline", label: "Folders", actions: ["AXShowMenu"], at: (0, 52, 240, 1028))
        for (offset, folder) in state.folders.enumerated() {
            let row = add("AXRow", actions: ["AXShowDefaultUI", "AXShowAlternateUI"], at: (0, 60 + Double(offset) * 30, 240, 30), parent: outline, selected: folder == state.selectedFolder, folder: folder)
            // The one folder whose name is an editable field, carrying the name as label and value.
            if offset == 1 {
                _ = add("AXTextField", label: folder, value: folder, actions: ["AXConfirm"], at: (20, 60 + Double(offset) * 30, 200, 30), parent: row)
            }
        }
        for offset in 0..<2 {
            _ = add("AXButton", actions: ["AXPress"], at: (250 + Double(offset) * 30, 60, 28, 28))
        }
        // The date line over the note, pressable, holding text of the person's.
        _ = add("AXStaticText", label: "24 September 2026 at 17:50", value: "24 September 2026 at 17:50", actions: ["AXPress"], at: (600, 60, 200, 20))
        if state.noteLocked {
            _ = add("AXSecureTextField", label: "Password", actions: ["AXConfirm"], at: (1000, 400, 300, 30))
        } else if state.editorOpen {
            _ = add("AXTextArea", label: "Note Body", value: state.notes.last ?? "", actions: ["AXShowMenu"], at: (600, 90, 1300, 900))
        }
        let toolbar = add("AXToolbar", actions: ["AXShowMenu"], at: (0, 0, 1920, 52))
        for (offset, name) in ["New Note", "Delete", "Share", "Lock Note", "Checklist"].enumerated() {
            _ = add("AXButton", label: name, actions: ["AXPress"], at: (300 + Double(offset) * 40, 10, 32, 32), parent: toolbar)
        }
        _ = add("AXTextField", actions: ["AXConfirm"], at: (1600, 10, 280, 32), parent: toolbar)
        let bar = add("AXMenuBar", at: (0, 0, 1920, 24))
        for (menu, items) in [("File", ["New Note", "Close"]), ("Edit", ["Undo", "Delete"]), ("Format", ["Title"])] {
            let barItem = add("AXMenuBarItem", label: menu, at: (0, 0, 40, 24), parent: bar)
            let menuElement = add("AXMenu", at: (0, 24, 200, 200), parent: barItem)
            for item in items {
                let greyedHere = state.newNoteOnlyIn.map { $0 != state.selectedFolder } ?? false
                let enabled = !(menu == "File" && item == "New Note" && (!state.newNoteEnabled || greyedHere))
                _ = add("AXMenuItem", label: item, actions: ["AXPress", "AXCancel"], at: (0, 24, 200, 20), parent: menuElement, enabled: enabled, menuPath: [menu, item])
            }
        }
        return list
    }

    /// cua's Markdown shape, measured 2026-09-24: `- [N] Role (label) [actions=…]` per listed element,
    /// indented by depth, with a folder row's name as an `AXStaticText = "…"` line beneath it.
    private static func markdown(_ elements: [Element]) -> String {
        func depth(_ element: Element) -> Int {
            var depth = 0
            var next = element.parent
            while let index = next, let parent = elements.first(where: { $0.index == index }) {
                depth += 1
                next = parent.parent
            }
            return depth
        }
        var lines: [String] = []
        for element in elements {
            let indent = String(repeating: "  ", count: depth(element))
            let label = element.label.map { " (\($0))" } ?? ""
            lines.append("\(indent)- [\(element.index)] \(element.role)\(label) [actions=[\(element.actions.joined(separator: ","))]]")
            // The real tree marks names with a left-to-right mark, which the lookup has to ignore.
            if let folder = element.folder, folder != "Recipes" {
                lines.append("\(indent)  - AXStaticText = \"\u{200E}\(folder)\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func result(_ structured: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "ok"]], "structuredContent": structured])
    }

    private static func error(_ message: String, code: String? = nil) -> Data {
        var structured: [String: Any] = ["status": "refused"]
        if let code { structured["refusal"] = ["code": code, "message": message] }
        return try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": message]], "isError": true, "structuredContent": structured,
        ])
    }
}
