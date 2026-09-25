import Foundation

// The value types inside V2 messages. Each mirrors a `$defs` entry of
// `contracts/v2/protocol.schema.json`; field names on the wire are snake_case.

public struct WireRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct WireAppRef: Hashable, Sendable, Codable {
    public var bundleID: String
    public var name: String

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name
    }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum PermissionState: String, Hashable, Sendable, Codable {
    case granted
    case denied
    case notDetermined = "not_determined"
}

public enum ScreenToolName: String, Hashable, Sendable, Codable, CaseIterable {
    case observeAX = "observe_ax"
    case screenshot
    case press
    case setValue = "set_value"
    case typeText = "type_text"
    case key
    case scroll
    case menu
    case clickPoint = "click_point"
}

public enum LedgerState: String, Hashable, Sendable, Codable, CaseIterable {
    case received
    case prepared
    case approved
    case dispatched
    case done
    case failed
    case refused
    case declined
    case stale
    case skipped
    case outcomeUnknown = "outcome_unknown"
}

/// What this Mac can do right now. Sent in `hello`.
public struct Manifest: Hashable, Sendable, Codable {
    public struct Operation: Hashable, Sendable, Codable {
        public var name: String
        public var version: Int

        public init(name: String, version: Int) {
            self.name = name
            self.version = version
        }
    }

    public struct Screen: Hashable, Sendable, Codable {
        public var tools: [ScreenToolName]

        public init(tools: [ScreenToolName]) {
            self.tools = tools
        }
    }

    public struct AutomationPermission: Hashable, Sendable, Codable {
        public var bundleID: String
        public var state: PermissionState

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case state
        }

        public init(bundleID: String, state: PermissionState) {
            self.bundleID = bundleID
            self.state = state
        }
    }

    public struct Permissions: Hashable, Sendable, Codable {
        public var accessibility: PermissionState
        public var screenRecording: PermissionState
        public var automation: [AutomationPermission]

        enum CodingKeys: String, CodingKey {
            case accessibility
            case screenRecording = "screen_recording"
            case automation
        }

        public init(
            accessibility: PermissionState,
            screenRecording: PermissionState,
            automation: [AutomationPermission]
        ) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
            self.automation = automation
        }
    }

    public var operations: [Operation]
    public var screen: Screen
    public var permissions: Permissions

    public init(operations: [Operation], screen: Screen, permissions: Permissions) {
        self.operations = operations
        self.screen = screen
        self.permissions = permissions
    }
}

/// An element from an earlier observation. A ref means nothing outside the generation it came from.
public struct ElementRef: Hashable, Sendable, Codable {
    public var ref: String
    public var generation: Int

    public init(ref: String, generation: Int) {
        self.ref = ref
        self.generation = generation
    }
}

public struct AXNode: Hashable, Sendable, Codable {
    public var ref: String
    public var depth: Int
    public var role: String
    public var label: String?
    public var value: String?
    public var enabled: Bool?
    public var focused: Bool?
    public var selected: Bool?
    /// A secure text field. Its value is never sent.
    public var secure: Bool?
    public var frame: WireRect?
    public var actions: [String]?

    public init(
        ref: String,
        depth: Int,
        role: String,
        label: String? = nil,
        value: String? = nil,
        enabled: Bool? = nil,
        focused: Bool? = nil,
        selected: Bool? = nil,
        secure: Bool? = nil,
        frame: WireRect? = nil,
        actions: [String]? = nil
    ) {
        self.ref = ref
        self.depth = depth
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.secure = secure
        self.frame = frame
        self.actions = actions
    }
}

public enum ScrollDirection: String, Hashable, Sendable, Codable {
    case up
    case down
    case left
    case right
}

/// One screen action. Every one names its target app, which the Mac checks against the app it
/// observed and against the apps it refuses.
public enum ScreenAction: Hashable, Sendable, Codable {
    case press(app: String, element: ElementRef)
    case setValue(app: String, element: ElementRef, value: String)
    case typeText(app: String, text: String, element: ElementRef?)
    case key(app: String, keys: [String])
    case scroll(app: String, direction: ScrollDirection, amount: Int, element: ElementRef?)
    case menu(app: String, path: [String])
    case clickPoint(app: String, x: Double, y: Double, generation: Int, count: Int?)

    public var tool: ScreenToolName {
        switch self {
        case .press: .press
        case .setValue: .setValue
        case .typeText: .typeText
        case .key: .key
        case .scroll: .scroll
        case .menu: .menu
        case .clickPoint: .clickPoint
        }
    }

    public var app: String {
        switch self {
        case .press(let app, _), .setValue(let app, _, _), .typeText(let app, _, _),
            .key(let app, _), .scroll(let app, _, _, _), .menu(let app, _),
            .clickPoint(let app, _, _, _, _):
            app
        }
    }

    enum CodingKeys: String, CodingKey {
        case tool, app, element, value, text, keys, direction, amount, path, x, y, generation, count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let app = try c.decode(String.self, forKey: .app)
        switch try c.decode(ScreenToolName.self, forKey: .tool) {
        case .press:
            self = .press(app: app, element: try c.decode(ElementRef.self, forKey: .element))
        case .setValue:
            self = .setValue(
                app: app,
                element: try c.decode(ElementRef.self, forKey: .element),
                value: try c.decode(String.self, forKey: .value)
            )
        case .typeText:
            self = .typeText(
                app: app,
                text: try c.decode(String.self, forKey: .text),
                element: try c.decodeIfPresent(ElementRef.self, forKey: .element)
            )
        case .key:
            self = .key(app: app, keys: try c.decode([String].self, forKey: .keys))
        case .scroll:
            self = .scroll(
                app: app,
                direction: try c.decode(ScrollDirection.self, forKey: .direction),
                amount: try c.decode(Int.self, forKey: .amount),
                element: try c.decodeIfPresent(ElementRef.self, forKey: .element)
            )
        case .menu:
            self = .menu(app: app, path: try c.decode([String].self, forKey: .path))
        case .clickPoint:
            self = .clickPoint(
                app: app,
                x: try c.decode(Double.self, forKey: .x),
                y: try c.decode(Double.self, forKey: .y),
                generation: try c.decode(Int.self, forKey: .generation),
                count: try c.decodeIfPresent(Int.self, forKey: .count)
            )
        case .observeAX, .screenshot:
            throw DecodingError.dataCorruptedError(
                forKey: .tool,
                in: c,
                debugDescription: "observing is an observe message, not an action"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool)
        try c.encode(app, forKey: .app)
        switch self {
        case .press(_, let element):
            try c.encode(element, forKey: .element)
        case .setValue(_, let element, let value):
            try c.encode(element, forKey: .element)
            try c.encode(value, forKey: .value)
        case .typeText(_, let text, let element):
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(element, forKey: .element)
        case .key(_, let keys):
            try c.encode(keys, forKey: .keys)
        case .scroll(_, let direction, let amount, let element):
            try c.encode(direction, forKey: .direction)
            try c.encode(amount, forKey: .amount)
            try c.encodeIfPresent(element, forKey: .element)
        case .menu(_, let path):
            try c.encode(path, forKey: .path)
        case .clickPoint(_, let x, let y, let generation, let count):
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(generation, forKey: .generation)
            try c.encodeIfPresent(count, forKey: .count)
        }
    }
}

public struct OperationCall: Hashable, Sendable, Codable {
    public var name: String
    public var version: Int
    public var args: [String: JSONValue]

    public init(name: String, version: Int, args: [String: JSONValue]) {
        self.name = name
        self.version = version
        self.args = args
    }
}

/// One proposed action: a typed operation or a screen action, never both.
public struct WireAction: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable {
        case operation(OperationCall)
        case screen(ScreenAction)
    }

    public var actionID: ActionID
    public var effect: Effect
    public var expect: String?
    public var kind: Kind

    public init(actionID: ActionID, effect: Effect, expect: String? = nil, kind: Kind) {
        self.actionID = actionID
        self.effect = effect
        self.expect = expect
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case effect, expect, operation, screen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try c.decode(ActionID.self, forKey: .actionID)
        effect = try c.decode(Effect.self, forKey: .effect)
        expect = try c.decodeIfPresent(String.self, forKey: .expect)
        let operation = try c.decodeIfPresent(OperationCall.self, forKey: .operation)
        let screen = try c.decodeIfPresent(ScreenAction.self, forKey: .screen)
        switch (operation, screen) {
        case (let operation?, nil): kind = .operation(operation)
        case (nil, let screen?): kind = .screen(screen)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "an action carries exactly one of operation or screen"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionID, forKey: .actionID)
        try c.encode(effect, forKey: .effect)
        try c.encodeIfPresent(expect, forKey: .expect)
        switch kind {
        case .operation(let operation): try c.encode(operation, forKey: .operation)
        case .screen(let screen): try c.encode(screen, forKey: .screen)
        }
    }
}

public enum OutcomeStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case done
    case failed
    case refused
    case declined
    case stale
    case skipped
    case outcomeUnknown = "outcome_unknown"
}

public enum OutcomeErrorCode: String, Hashable, Sendable, Codable, CaseIterable {
    case permissionDenied = "permission_denied"
    case appNotRunning = "app_not_running"
    case targetNotFound = "target_not_found"
    case targetRefused = "target_refused"
    case staleReference = "stale_reference"
    case invalidArguments = "invalid_arguments"
    case unsupportedOperation = "unsupported_operation"
    case secureField = "secure_field"
    case modeRefused = "mode_refused"
    case unattendedRefused = "unattended_refused"
    case foregroundUnavailable = "foreground_unavailable"
    case timeout
    case executionError = "execution_error"
    case cancelled
}

public struct OutcomeError: Hashable, Sendable, Codable {
    public var code: OutcomeErrorCode
    public var message: String?

    public init(code: OutcomeErrorCode, message: String? = nil) {
        self.code = code
        self.message = message
    }
}

public struct ActionResult: Hashable, Sendable, Codable {
    public var actionID: ActionID
    public var status: OutcomeStatus
    /// The effect the Mac judged, after raising.
    public var effect: Effect
    public var evidence: String?
    public var error: OutcomeError?

    enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case status, effect, evidence, error
    }

    public init(
        actionID: ActionID,
        status: OutcomeStatus,
        effect: Effect,
        evidence: String? = nil,
        error: OutcomeError? = nil
    ) {
        self.actionID = actionID
        self.status = status
        self.effect = effect
        self.evidence = evidence
        self.error = error
    }
}
