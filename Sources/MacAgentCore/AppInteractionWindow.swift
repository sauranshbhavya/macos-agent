import Foundation

/// Role names as cua reports them, grouped the way Sonny's rules read them.
public enum AppInteractionRoles {
    /// Where apps keep chats, notes and folders. Never shown to the model unless one is exactly the
    /// goal's target (founders, 2026-09-24: privacy by role).
    public static let rows: Set<String> = ["AXRow", "AXOutlineRow", "AXCell"]
    /// Pressing one of these only moves between things.
    public static let navigation: Set<String> = rows.union(["AXRadioButton", "AXTab"])
    public static let lists: Set<String> = ["AXList", "AXTable", "AXOutline", "AXCollection", "AXBrowser"]
    public static let textInputs: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    public static let menus: Set<String> = ["AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"]
    /// Things a click lands on as a control.
    public static let clickable: Set<String> = navigation.union([
        "AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle",
    ])
}

/// Structural questions about one cua reading, answered from the parent chain it reports. cua
/// lists only elements with something to act on, so a container appears only when it has actions
/// of its own; a question the chain cannot answer is answered the cautious way.
extension CuaWindowState {
    public func element(_ index: Int) -> CuaElement? {
        elements.first { $0.index == index }
    }

    public func ancestors(of element: CuaElement) -> [CuaElement] {
        var chain: [CuaElement] = []
        var next = element.parentIndex
        while let index = next, let parent = self.element(index), !chain.contains(parent) {
            chain.append(parent)
            next = parent.parentIndex
        }
        return chain
    }

    public func isInsideList(_ element: CuaElement) -> Bool {
        ancestors(of: element).contains { AppInteractionRoles.lists.contains($0.role) }
    }

    public func isInsideToolbar(_ element: CuaElement) -> Bool {
        ancestors(of: element).contains { $0.role == "AXToolbar" }
    }

    /// A search box: cua reports no subrole, so a text field in a toolbar counts as one too —
    /// where Notes, Mail and Finder keep theirs.
    public func isSearchField(_ element: CuaElement) -> Bool {
        element.role == "AXSearchField" || (element.role == "AXTextField" && isInsideToolbar(element))
    }

    public func isTextInput(_ element: CuaElement) -> Bool {
        AppInteractionRoles.textInputs.contains(element.role)
    }

    /// A row, or anything inside a list: where an app keeps what belongs to the person.
    public func isPrivateByRole(_ element: CuaElement) -> Bool {
        AppInteractionRoles.rows.contains(element.role) || isInsideList(element)
    }

    public func isInMenus(_ element: CuaElement) -> Bool {
        AppInteractionRoles.menus.contains(element.role)
            || ancestors(of: element).contains { AppInteractionRoles.menus.contains($0.role) }
    }

    /// The labels from the menu bar down to this item, as `invoke_menu` takes them: nil for an
    /// item outside the menu bar, such as a context menu, or one with an unnamed step.
    public func menuPath(of element: CuaElement) -> [String]? {
        guard element.role == "AXMenuItem", let label = element.label else { return nil }
        var path = [label]
        for ancestor in ancestors(of: element) {
            switch ancestor.role {
            case "AXMenu": continue
            case "AXMenuItem", "AXMenuBarItem":
                guard let name = ancestor.label else { return nil }
                path.insert(name, at: 0)
                if ancestor.role == "AXMenuBarItem" { return path }
            default: return nil
            }
        }
        return nil
    }

    /// The smallest element under a point, leaving out the window and the menus: what a click
    /// there would land on. Nil when nothing is there.
    public func element(atX x: Double, y: Double) -> CuaElement? {
        elements
            .filter { $0.role != "AXWindow" && !isInMenus($0) && ($0.frame?.contains(x: x, y: y) ?? false) }
            .min { ($0.frame!.w * $0.frame!.h) < ($1.frame!.w * $1.frame!.h) }
    }
}
