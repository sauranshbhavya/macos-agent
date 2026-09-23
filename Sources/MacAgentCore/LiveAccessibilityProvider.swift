import ApplicationServices
import CoreGraphics
import Foundation

/// Reads and acts on other apps through `AXUIElement`.
///
/// An actor so the element handles, which are not `Sendable`, stay in one isolation domain and
/// never reach a model, a snapshot or the UI. Only the latest generation's handles are kept; an id
/// from an earlier observation is refused as stale rather than resolved against a tree that may
/// have moved.
public actor LiveAccessibilityProvider: AccessibilityProviding {
    private var generation = 0
    private var handles: [AXUIElement] = []
    /// What each handle was when observed, compared again before acting on it.
    private var identities: [AccessibilityIdentity] = []
    private var lastLimits = AccessibilityLimits()
    private let trust: @Sendable () -> Bool
    private let clock: @Sendable () -> Date

    public init(
        trust: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.trust = trust
        self.clock = clock
    }

    public func isTrusted() -> Bool {
        trust()
    }

    public func observe(processIdentifier: pid_t, limits: AccessibilityLimits) throws -> AccessibilitySnapshot {
        guard trust() else { throw AccessibilityError.notTrusted }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, limits.messagingTimeout)

        let window = try Self.targetWindow(of: application)
        generation += 1
        let thisGeneration = generation
        let started = clock()

        var collected: [AccessibilityElement] = []
        var collectedHandles: [AXUIElement] = []
        var truncation: AccessibilityTruncation?
        // Depth-first with an explicit stack, children pushed in reverse so they are visited in
        // order. `AccessibilitySnapshot.descendants(of:)` relies on this order.
        var stack: [(element: AXUIElement, parent: Int?, depth: Int)] = [(window, nil, 0)]
        while let next = stack.popLast() {
            if collected.count >= limits.maxElements {
                truncation = .nodeLimit
                break
            }
            if clock().timeIntervalSince(started) > limits.deadline {
                truncation = .deadline
                break
            }
            let index = collected.count
            let id = AccessibilityElementID(generation: thisGeneration, index: index)
            collected.append(Self.read(next.element, id: id, parent: next.parent, depth: next.depth, limits: limits))
            collectedHandles.append(next.element)

            guard next.depth < limits.maxDepth else {
                if !Self.children(of: next.element).isEmpty { truncation = truncation ?? .depthLimit }
                continue
            }
            for child in Self.children(of: next.element).reversed() {
                stack.append((child, index, next.depth + 1))
            }
        }

        let snapshot = AccessibilitySnapshot(
            generation: thisGeneration,
            app: AccessibilityObservedApp(
                bundleIdentifier: nil,
                processIdentifier: processIdentifier,
                name: Self.string(application, "AXTitle", limit: limits.maxTextLength)
            ),
            windowTitle: Self.string(window, "AXTitle", limit: limits.maxTextLength),
            elements: collected,
            truncation: truncation,
            takenAt: started
        )
        handles = collectedHandles
        identities = snapshot.elements.map { snapshot.identity(of: $0) }
        lastLimits = limits
        return snapshot
    }

    public func perform(_ action: AccessibilityAction, on element: AccessibilityElementID) throws {
        guard trust() else { throw AccessibilityError.notTrusted }
        guard element.generation == generation, handles.indices.contains(element.index) else {
            throw AccessibilityError.staleElement
        }
        let handle = handles[element.index]
        // Re-resolve immediately before acting. An element that no longer answers has been torn
        // down; one that answers as something else is a reused view — a table row that now shows a
        // different chat after a new message reordered the list during the model call (PR #289
        // review, F5). Either way it is not what the model was shown, so it is stale.
        var role: CFTypeRef?
        let probe = AXUIElementCopyAttributeValue(handle, "AXRole" as CFString, &role)
        guard probe == .success else { throw Self.error(for: probe, staleOnInvalid: true) }
        guard Self.currentIdentity(of: handle, limits: lastLimits).matches(identities[element.index]) else {
            throw AccessibilityError.staleElement
        }

        let result: AXError
        switch action {
        case .press:
            result = AXUIElementPerformAction(handle, AccessibilityVocabulary.pressAction as CFString)
        case .select:
            result = AXUIElementSetAttributeValue(handle, "AXSelected" as CFString, kCFBooleanTrue)
        case .focus:
            result = AXUIElementSetAttributeValue(handle, "AXFocused" as CFString, kCFBooleanTrue)
        case .setValue(let text):
            var settable = DarwinBoolean(false)
            let check = AXUIElementIsAttributeSettable(handle, "AXValue" as CFString, &settable)
            guard check == .success, settable.boolValue else { throw AccessibilityError.valueNotSettable }
            result = AXUIElementSetAttributeValue(handle, "AXValue" as CFString, text as CFString)
        }
        guard result == .success else { throw Self.error(for: result, staleOnInvalid: true) }
    }

    // MARK: - Reading

    private static func targetWindow(of application: AXUIElement) throws -> AXUIElement {
        for attribute in ["AXFocusedWindow", "AXMainWindow"] {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
            if result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return unsafeDowncast(value, to: AXUIElement.self)
            }
            if result == .cannotComplete || result == .notImplemented { continue }
            if result == .apiDisabled { throw AccessibilityError.notTrusted }
            if result == .invalidUIElement { throw AccessibilityError.appNotRunning }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &windows) == .success,
           let list = windows as? [AXUIElement], let first = list.first {
            return first
        }
        throw AccessibilityError.noWindow
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        // Lists and tables can hold thousands of rows; the visible ones are what a person could
        // act on, so prefer them when the element offers the distinction.
        for attribute in ["AXVisibleChildren", "AXChildren"] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let list = value as? [AXUIElement] {
                return list
            }
        }
        return []
    }

    /// Every attribute a snapshot element carries, fetched in one IPC round trip rather than one per
    /// attribute: a chat window has hundreds of elements, and one call each keeps the reading inside
    /// its deadline where a dozen each would cut it off before the message box.
    private static let batchedAttributes = [
        "AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXPlaceholderValue",
        "AXValue", "AXEnabled", "AXFocused", "AXSelected", "AXPosition", "AXSize",
    ]

    private static func read(
        _ element: AXUIElement,
        id: AccessibilityElementID,
        parent: Int?,
        depth: Int,
        limits: AccessibilityLimits
    ) -> AccessibilityElement {
        var raw: CFArray?
        var values: [String: AnyObject] = [:]
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            batchedAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &raw
        )
        if result == .success, let list = raw as? [AnyObject] {
            // A missing attribute comes back as an AXValue holding an AXError, not as a gap.
            for (name, value) in zip(batchedAttributes, list) where !isErrorValue(value) {
                values[name] = value
            }
        }
        let limit = limits.maxTextLength
        func text(_ name: String) -> String? { (values[name] as? String).flatMap { clipped($0, limit: limit) } }
        func flag(_ name: String) -> Bool? { (values[name] as? NSNumber)?.boolValue }

        let role = text("AXRole") ?? "AXUnknown"
        let subrole = text("AXSubrole")
        // Settability is a separate IPC per attribute, so it is asked only where a step could use
        // it: typing into fields, and selecting rows.
        let typable = subrole != AccessibilityVocabulary.secureFieldSubrole
            && (AccessibilityVocabulary.textInputRoles.contains(role) || subrole == AccessibilityVocabulary.searchFieldSubrole)
        let selectable = AccessibilityVocabulary.selectionRoles.contains(role) || role == "AXButton"
        return AccessibilityElement(
            id: id,
            parentIndex: parent,
            depth: depth,
            role: role,
            subrole: subrole,
            identifier: text("AXIdentifier"),
            title: text("AXTitle"),
            label: text("AXDescription"),
            placeholder: text("AXPlaceholderValue"),
            value: text("AXValue"),
            isEnabled: flag("AXEnabled") ?? true,
            isFocused: flag("AXFocused") ?? false,
            isSelected: flag("AXSelected") ?? false,
            actions: actions(of: element),
            canSetValue: typable && settable(element, "AXValue"),
            canFocus: typable && settable(element, "AXFocused"),
            canSelect: selectable && settable(element, "AXSelected"),
            frame: frame(position: values["AXPosition"], size: values["AXSize"])
        )
    }

    private static func currentIdentity(of handle: AXUIElement, limits: AccessibilityLimits) -> AccessibilityIdentity {
        let current = read(handle, id: AccessibilityElementID(generation: -1, index: 0), parent: nil, depth: 0, limits: limits)
        return AccessibilityIdentity(
            role: current.role,
            subrole: current.subrole,
            title: current.title,
            label: current.label,
            placeholder: current.placeholder,
            value: current.isTextInput ? nil : current.value,
            firstText: firstText(inside: handle, limit: limits.maxTextLength)
        )
    }

    /// The first text inside an element, depth first over the same children the observation walks,
    /// bounded so a large container cannot stall the check.
    private static func firstText(inside element: AXUIElement, limit: Int) -> String? {
        var stack = Array(children(of: element).reversed())
        var visited = 0
        while let next = stack.popLast(), visited < 24 {
            visited += 1
            if let text = string(next, "AXTitle", limit: limit)
                ?? string(next, "AXValue", limit: limit)
                ?? string(next, "AXDescription", limit: limit) {
                return text
            }
            stack.append(contentsOf: children(of: next).reversed())
        }
        return nil
    }

    private static func isErrorValue(_ value: AnyObject) -> Bool {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        return AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError
    }

    private static func clipped(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) : trimmed
    }

    private static func string(_ element: AXUIElement, _ attribute: String, limit: Int) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return clipped(text, limit: limit)
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else {
            return []
        }
        return list
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        guard let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    private static func error(for result: AXError, staleOnInvalid: Bool) -> AccessibilityError {
        switch result {
        case .apiDisabled: return .notTrusted
        case .invalidUIElement: return staleOnInvalid ? .staleElement : .appNotRunning
        case .cannotComplete: return .timedOut
        case .actionUnsupported, .attributeUnsupported, .notImplemented: return .actionUnsupported
        default: return .failed(code: result.rawValue)
        }
    }
}
