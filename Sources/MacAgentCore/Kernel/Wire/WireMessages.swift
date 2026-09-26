import Foundation

// The bodies of the V2 messages, one type per message.

// MARK: Mac to gateway

public struct HelloBody: Hashable, Sendable, Codable {
    public struct ResumeEntry: Hashable, Sendable, Codable {
        public struct LedgerEntry: Hashable, Sendable, Codable {
            public var actionID: ActionID
            public var state: LedgerState

            enum CodingKeys: String, CodingKey {
                case actionID = "action_id"
                case state
            }

            public init(actionID: ActionID, state: LedgerState) {
                self.actionID = actionID
                self.state = state
            }
        }

        public var task: TaskID
        /// The last gateway seq this Mac received.
        public var lastSeqIn: Int
        /// The last seq this Mac sent.
        public var lastSeqOut: Int
        public var ledger: [LedgerEntry]

        enum CodingKeys: String, CodingKey {
            case task
            case lastSeqIn = "last_seq_in"
            case lastSeqOut = "last_seq_out"
            case ledger
        }

        public init(task: TaskID, lastSeqIn: Int, lastSeqOut: Int, ledger: [LedgerEntry]) {
            self.task = task
            self.lastSeqIn = lastSeqIn
            self.lastSeqOut = lastSeqOut
            self.ledger = ledger
        }
    }

    public var deviceID: DeviceID
    public var appVersion: String
    public var osVersion: String
    public var manifest: Manifest
    public var resume: [ResumeEntry]

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case manifest, resume
    }

    public init(
        deviceID: DeviceID,
        appVersion: String,
        osVersion: String,
        manifest: Manifest,
        resume: [ResumeEntry]
    ) {
        self.deviceID = deviceID
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.manifest = manifest
        self.resume = resume
    }
}

public struct ReauthBody: Hashable, Sendable, Codable {
    public var accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

public enum TaskOrigin: String, Hashable, Sendable, Codable, CaseIterable {
    case composer
    case voice
    case routine
    case schedule
    case followUp = "follow_up"
    case watcher
}

public struct TaskStartBody: Hashable, Sendable, Codable {
    public struct Context: Hashable, Sendable, Codable {
        public var frontmostApp: WireAppRef?
        public var finderSelection: [String]?

        enum CodingKeys: String, CodingKey {
            case frontmostApp = "frontmost_app"
            case finderSelection = "finder_selection"
        }

        public init(frontmostApp: WireAppRef? = nil, finderSelection: [String]? = nil) {
            self.frontmostApp = frontmostApp
            self.finderSelection = finderSelection
        }
    }

    public var goal: String
    public var origin: TaskOrigin
    /// Don't keep this task: the gateway deletes its transcript when it ends.
    public var isPrivate: Bool
    /// Nobody is at the Mac, so anything that needs confirmation is refused.
    public var unattended: Bool
    public var mode: AgentInteractionMode
    public var priorTask: TaskID?
    public var context: Context

    enum CodingKeys: String, CodingKey {
        case goal, origin
        case isPrivate = "private"
        case unattended, mode
        case priorTask = "prior_task"
        case context
    }

    public init(
        goal: String,
        origin: TaskOrigin,
        isPrivate: Bool,
        unattended: Bool,
        mode: AgentInteractionMode,
        priorTask: TaskID? = nil,
        context: Context = Context()
    ) {
        self.goal = goal
        self.origin = origin
        self.isPrivate = isPrivate
        self.unattended = unattended
        self.mode = mode
        self.priorTask = priorTask
        self.context = context
    }
}

public struct ObservationBody: Hashable, Sendable, Codable {
    public struct App: Hashable, Sendable, Codable {
        public var bundleID: String
        public var name: String
        public var pid: Int

        enum CodingKeys: String, CodingKey {
            case bundleID = "bundle_id"
            case name, pid
        }

        public init(bundleID: String, name: String, pid: Int) {
            self.bundleID = bundleID
            self.name = name
            self.pid = pid
        }
    }

    public struct Window: Hashable, Sendable, Codable {
        public var id: Int
        public var title: String?
        public var frame: WireRect

        public init(id: Int, title: String? = nil, frame: WireRect) {
            self.id = id
            self.title = title
            self.frame = frame
        }
    }

    public struct Tree: Hashable, Sendable, Codable {
        public var nodes: [AXNode]
        public var truncated: Bool

        public init(nodes: [AXNode], truncated: Bool) {
            self.nodes = nodes
            self.truncated = truncated
        }
    }

    public struct Screenshot: Hashable, Sendable, Codable {
        public enum MediaType: String, Hashable, Sendable, Codable {
            case jpeg = "image/jpeg"
            case png = "image/png"
        }

        public var mediaType: MediaType
        /// Base64 of the redacted image.
        public var data: String
        public var width: Int
        public var height: Int

        enum CodingKeys: String, CodingKey {
            case mediaType = "media_type"
            case data, width, height
        }

        public init(mediaType: MediaType, data: String, width: Int, height: Int) {
            self.mediaType = mediaType
            self.data = data
            self.width = width
            self.height = height
        }
    }

    public enum ErrorCode: String, Hashable, Sendable, Codable {
        case permissionDenied = "permission_denied"
        case appNotRunning = "app_not_running"
        case noWindow = "no_window"
        case unreadable
        case foregroundUnavailable = "foreground_unavailable"
    }

    public struct Failure: Hashable, Sendable, Codable {
        public var code: ErrorCode
        public var message: String?

        public init(code: ErrorCode, message: String? = nil) {
            self.code = code
            self.message = message
        }
    }

    public var generation: Int
    public var app: App?
    public var window: Window?
    public var ax: Tree?
    public var screenshot: Screenshot?
    public var error: Failure?

    public init(
        generation: Int,
        app: App? = nil,
        window: Window? = nil,
        ax: Tree? = nil,
        screenshot: Screenshot? = nil,
        error: Failure? = nil
    ) {
        self.generation = generation
        self.app = app
        self.window = window
        self.ax = ax
        self.screenshot = screenshot
        self.error = error
    }
}

public struct OutcomeBody: Hashable, Sendable, Codable {
    public var results: [ActionResult]

    public init(results: [ActionResult]) {
        self.results = results
    }
}

public struct AnswerBody: Hashable, Sendable, Codable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct TaskCancelBody: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        case user
        case shutdown
        case outcomeUnknown = "outcome_unknown"
    }

    public var reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }
}

// MARK: Gateway to Mac

public struct WelcomeBody: Hashable, Sendable, Codable {
    public struct TaskState: Hashable, Sendable, Codable {
        public enum State: String, Hashable, Sendable, Codable {
            case live
            case finished
            case unknown
        }

        public var task: TaskID
        public var state: State
        /// The last Mac seq the gateway stored. The Mac resends anything after it.
        public var lastSeqIn: Int

        enum CodingKeys: String, CodingKey {
            case task, state
            case lastSeqIn = "last_seq_in"
        }

        public init(task: TaskID, state: State, lastSeqIn: Int) {
            self.task = task
            self.state = state
            self.lastSeqIn = lastSeqIn
        }
    }

    public var sessionID: SessionID
    public var serverTimeMs: Int64
    public var maxPayloadBytes: Int
    public var heartbeatSeconds: Int
    public var tasks: [TaskState]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case serverTimeMs = "server_time_ms"
        case maxPayloadBytes = "max_payload_bytes"
        case heartbeatSeconds = "heartbeat_seconds"
        case tasks
    }

    public init(
        sessionID: SessionID,
        serverTimeMs: Int64,
        maxPayloadBytes: Int,
        heartbeatSeconds: Int,
        tasks: [TaskState]
    ) {
        self.sessionID = sessionID
        self.serverTimeMs = serverTimeMs
        self.maxPayloadBytes = maxPayloadBytes
        self.heartbeatSeconds = heartbeatSeconds
        self.tasks = tasks
    }
}

public struct ReauthRequiredBody: Hashable, Sendable, Codable {
    public var expiresAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case expiresAtMs = "expires_at_ms"
    }

    public init(expiresAtMs: Int64) {
        self.expiresAtMs = expiresAtMs
    }
}

public struct GoodbyeBody: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        case draining
        case replaced
        case signedOut = "signed_out"
        case authExpired = "auth_expired"
    }

    public var reason: Reason
    public var reconnectAfterMs: Int?

    enum CodingKeys: String, CodingKey {
        case reason
        case reconnectAfterMs = "reconnect_after_ms"
    }

    public init(reason: Reason, reconnectAfterMs: Int? = nil) {
        self.reason = reason
        self.reconnectAfterMs = reconnectAfterMs
    }
}

public struct ErrorBody: Hashable, Sendable, Codable {
    public enum Code: String, Hashable, Sendable, Codable {
        case malformed
        case unsupportedVersion = "unsupported_version"
        case rateLimited = "rate_limited"
        case payloadTooLarge = "payload_too_large"
        case unknownTask = "unknown_task"
        case taskConflict = "task_conflict"
        case sequenceGap = "sequence_gap"
        case `internal`
    }

    public var code: Code
    public var message: String
    public var ref: MessageID?

    public init(code: Code, message: String, ref: MessageID? = nil) {
        self.code = code
        self.message = message
        self.ref = ref
    }
}

public struct ObserveBody: Hashable, Sendable, Codable {
    public var app: String
    public var ax: Bool
    public var screenshot: Bool
    public var maxNodes: Int?

    enum CodingKeys: String, CodingKey {
        case app, ax, screenshot
        case maxNodes = "max_nodes"
    }

    public init(app: String, ax: Bool, screenshot: Bool, maxNodes: Int? = nil) {
        self.app = app
        self.ax = ax
        self.screenshot = screenshot
        self.maxNodes = maxNodes
    }
}

public enum ProposingAgent: String, Hashable, Sendable, Codable {
    case planner
    case screen
}

public struct ProposeBody: Hashable, Sendable, Codable {
    public var agent: ProposingAgent
    public var actions: [WireAction]
    /// If every action ends done, the task is finished.
    public var final: Bool

    public init(agent: ProposingAgent, actions: [WireAction], final: Bool) {
        self.agent = agent
        self.actions = actions
        self.final = final
    }
}

public struct AskBody: Hashable, Sendable, Codable {
    public var question: String
    public var choices: [String]?

    public init(question: String, choices: [String]? = nil) {
        self.question = question
        self.choices = choices
    }
}

public struct ProgressBody: Hashable, Sendable, Codable {
    public var message: String

    public init(message: String) {
        self.message = message
    }
}

public struct FinishBody: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case completed
        case failed
        case cancelled
    }

    public enum Reason: String, Hashable, Sendable, Codable {
        case creditsExhausted = "credits_exhausted"
        case spendCap = "spend_cap"
        case budgetExhausted = "budget_exhausted"
        case modelUnavailable = "model_unavailable"
        case invalidOutput = "invalid_output"
        case noProgress = "no_progress"
        case unsupported
        case refused
        case cancelled
        case internalError = "internal_error"
    }

    /// The gateway's claim. The Mac decides the verified status from its own evidence.
    public var status: Status
    public var summary: String
    public var reason: Reason?

    public init(status: Status, summary: String, reason: Reason? = nil) {
        self.status = status
        self.summary = summary
        self.reason = reason
    }
}
