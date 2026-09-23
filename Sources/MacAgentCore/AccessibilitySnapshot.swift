import CoreGraphics
import Foundation

// MARK: - Snapshot values

/// Identifies one element inside one snapshot. Only meaningful for the generation it came from:
/// the provider refuses an id from an older generation instead of acting on whatever now sits at
/// that position (V2 plan §7, "a model-visible ID is not a durable identity or authority to act").
public struct AccessibilityElementID: Hashable, Sendable, CustomStringConvertible {
    public let generation: Int
    public let index: Int

    public init(generation: Int, index: Int) {
        self.generation = generation
        self.index = index
    }

    public var description: String { "g\(generation).e\(index)" }
}

/// One element of an Accessibility snapshot, as plain values. No `AXUIElement` ever leaves the
/// provider that read it.
public struct AccessibilityElement: Equatable, Sendable {
    public let id: AccessibilityElementID
    public let parentIndex: Int?
    public let depth: Int
    public let role: String
    public let subrole: String?
    public let identifier: String?
    public let title: String?
    public let label: String?
    public let placeholder: String?
    /// The element's string value, cut to the snapshot's per-value budget. Nil for a non-string
    /// value.
    public let value: String?
    public let isEnabled: Bool
    public let isFocused: Bool
    public let isSelected: Bool
    public let actions: [String]
    public let canSetValue: Bool
    public let canFocus: Bool
    public let canSelect: Bool
    public let frame: CGRect?

    public init(
        id: AccessibilityElementID,
        parentIndex: Int?,
        depth: Int,
        role: String,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        label: String? = nil,
        placeholder: String? = nil,
        value: String? = nil,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        isSelected: Bool = false,
        actions: [String] = [],
        canSetValue: Bool = false,
        canFocus: Bool = false,
        canSelect: Bool = false,
        frame: CGRect? = nil
    ) {
        self.id = id
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.label = label
        self.placeholder = placeholder
        self.value = value
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.actions = actions
        self.canSetValue = canSetValue
        self.canFocus = canFocus
        self.canSelect = canSelect
        self.frame = frame
    }

    public var canPress: Bool { actions.contains(AccessibilityVocabulary.pressAction) }

    /// A field the user types into. Decided by role, so a settable slider or checkbox is not one,
    /// and never a password field: nothing on this path may type into one.
    public var isTextInput: Bool {
        guard subrole != AccessibilityVocabulary.secureFieldSubrole else { return false }
        return AccessibilityVocabulary.textInputRoles.contains(role)
            || subrole == AccessibilityVocabulary.searchFieldSubrole
    }

    /// What the person has typed here, with an app's placeholder shown as a value treated as empty.
    public var typedText: String? {
        guard let value, !value.isEmpty, value != placeholder else { return nil }
        return value
    }
}

/// The app a snapshot was read from.
public struct AccessibilityObservedApp: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: pid_t
    public let name: String?

    public init(bundleIdentifier: String?, processIdentifier: pid_t, name: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.name = name
    }
}

/// Why a snapshot stopped short of the whole window. Lazy or partial trees are an expected result
/// (V2 plan §7), so a truncated snapshot is still usable; it just says it is not the whole window.
public enum AccessibilityTruncation: Equatable, Sendable {
    case nodeLimit
    case depthLimit
    case deadline
}

/// An immutable reading of one window of one app.
public struct AccessibilitySnapshot: Equatable, Sendable {
    public let generation: Int
    public let app: AccessibilityObservedApp
    public let windowTitle: String?
    /// In traversal order; `elements[i].id.index == i`.
    public let elements: [AccessibilityElement]
    public let truncation: AccessibilityTruncation?
    public let takenAt: Date

    public init(
        generation: Int,
        app: AccessibilityObservedApp,
        windowTitle: String?,
        elements: [AccessibilityElement],
        truncation: AccessibilityTruncation?,
        takenAt: Date
    ) {
        self.generation = generation
        self.app = app
        self.windowTitle = windowTitle
        self.elements = elements
        self.truncation = truncation
        self.takenAt = takenAt
    }

    public var isComplete: Bool { truncation == nil }

    public func element(_ id: AccessibilityElementID) -> AccessibilityElement? {
        guard id.generation == generation, elements.indices.contains(id.index) else { return nil }
        return elements[id.index]
    }

    /// The element's ancestors, nearest first.
    public func ancestors(of element: AccessibilityElement) -> [AccessibilityElement] {
        var result: [AccessibilityElement] = []
        var next = element.parentIndex
        while let index = next, elements.indices.contains(index) {
            result.append(elements[index])
            next = elements[index].parentIndex
        }
        return result
    }

    /// The element's descendants in traversal order. Relies on depth-first order, which is what
    /// the live provider and the test fake both produce.
    public func descendants(of element: AccessibilityElement) -> [AccessibilityElement] {
        let start = element.id.index + 1
        guard start < elements.count else { return [] }
        var result: [AccessibilityElement] = []
        for candidate in elements[start...] {
            if candidate.depth <= element.depth { break }
            result.append(candidate)
        }
        return result
    }
}

// MARK: - Limits

/// Bounds on one observation. Chosen for a single chat-style window; revisit from measurements.
public struct AccessibilityLimits: Equatable, Sendable {
    public var maxElements: Int
    public var maxDepth: Int
    public var deadline: TimeInterval
    /// Longest string kept for any one title, label, placeholder or value.
    public var maxTextLength: Int
    /// Per-call IPC timeout, so one unresponsive app cannot stall the observation.
    public var messagingTimeout: Float

    public init(
        maxElements: Int = 800,
        maxDepth: Int = 40,
        deadline: TimeInterval = 2.0,
        maxTextLength: Int = 200,
        messagingTimeout: Float = 1.0
    ) {
        self.maxElements = maxElements
        self.maxDepth = maxDepth
        self.deadline = deadline
        self.maxTextLength = maxTextLength
        self.messagingTimeout = messagingTimeout
    }
}

// MARK: - Actions and errors

/// The only things Milestone A can do to another app. There is deliberately no key-press case:
/// with no synthesized keys, nothing on this path can press Return in a message box.
public enum AccessibilityAction: Equatable, Sendable {
    case press
    case select
    case focus
    case setValue(String)
}

/// Distinct outcomes the V2 plan asks to keep apart (§7): a denied permission, an app with no
/// window, a stale target and a timeout are different facts and get different wording.
public enum AccessibilityError: Error, Equatable, Sendable {
    case notTrusted
    case appNotRunning
    case noWindow
    case staleElement
    case actionUnsupported
    case valueNotSettable
    case timedOut
    case failed(code: Int32)
}

// MARK: - Provider seam

/// The OS boundary for reading and acting on other apps. The live implementation wraps
/// `AXUIElement`; tests use a scripted fake.
public protocol AccessibilityProviding: Sendable {
    func isTrusted() async -> Bool
    /// Reads the app's focused window (falling back to its main window). Each call starts a new
    /// generation and invalidates every id from the previous one.
    func observe(processIdentifier: pid_t, limits: AccessibilityLimits) async throws -> AccessibilitySnapshot
    /// Re-resolves the element for its generation and performs the action once.
    func perform(_ action: AccessibilityAction, on element: AccessibilityElementID) async throws
}

// MARK: - Vocabulary

/// Accessibility attribute, role and action names as plain strings. The SDK's `kAX…` globals are
/// avoided because Swift 6 strict concurrency treats some of them as mutable globals.
public enum AccessibilityVocabulary {
    public static let pressAction = "AXPress"
    public static let searchFieldSubrole = "AXSearchField"
    public static let secureFieldSubrole = "AXSecureTextField"
    public static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// Rows and similar selection targets: pressing or selecting one navigates, it does not commit.
    public static let selectionRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXRadioButton", "AXTab", "AXLink", "AXStaticText",
    ]
    public static let listRoles: Set<String> = ["AXList", "AXTable", "AXOutline", "AXCollection", "AXScrollArea"]
}
