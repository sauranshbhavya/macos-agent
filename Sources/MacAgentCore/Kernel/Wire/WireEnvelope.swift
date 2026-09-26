import Foundation

/// The protocol version every V2 message carries as `v`.
public let wireProtocolVersion = 1

public enum WireError: Error, Equatable, Sendable {
    case notAnObject
    case unsupportedVersion(Int)
    case unknownType(String)
    /// The message had a field the contract doesn't define: decoding and re-encoding it lost data.
    case unknownField
    /// The message broke one of the contract's rules.
    case invalid(String)
}

/// Where a task-level message sits in its task's stream. `seq` counts per task and per direction;
/// `re` is the other side's `seq` this message answers.
public struct TaskAddress: Hashable, Sendable {
    public var task: TaskID
    public var seq: Int
    public var re: Int?

    public init(task: TaskID, seq: Int, re: Int? = nil) {
        self.task = task
        self.seq = seq
        self.re = re
    }
}

/// Whether a message type belongs to the connection or to one task, and whether it must answer one
/// of the other side's messages.
public enum WireScope: Sendable {
    case connection
    case task
    case reply
}

/// The body of a message in one direction, keyed by the envelope's `type`.
public protocol WirePayload: Hashable, Sendable {
    var type: String { get }
    var scope: WireScope { get }
    static func decode(type: String, body: Decoder) throws -> Self
    func encodeBody(to encoder: Encoder) throws
    func validate() throws
}

/// One V2 message: the envelope plus a typed body.
public struct WireMessage<Payload: WirePayload>: Hashable, Sendable, Codable {
    public var id: MessageID
    /// Nil for connection-level messages, present for task-level ones.
    public var address: TaskAddress?
    public var payload: Payload

    public init(id: MessageID = MessageID(), address: TaskAddress? = nil, payload: Payload) {
        self.id = id
        self.address = address
        self.payload = payload
    }

    enum CodingKeys: String, CodingKey {
        case v, type, id, task, seq, re, body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .v)
        guard version == wireProtocolVersion else { throw WireError.unsupportedVersion(version) }
        let type = try c.decode(String.self, forKey: .type)
        id = try c.decode(MessageID.self, forKey: .id)
        let task = try c.decodeIfPresent(TaskID.self, forKey: .task)
        let seq = try c.decodeIfPresent(Int.self, forKey: .seq)
        let re = try c.decodeIfPresent(Int.self, forKey: .re)
        payload = try Payload.decode(type: type, body: c.superDecoder(forKey: .body))

        switch payload.scope {
        case .connection:
            guard task == nil, seq == nil, re == nil else {
                throw WireError.invalid("\(type) is a connection message and names no task")
            }
            address = nil
        case .task, .reply:
            guard let task, let seq else { throw WireError.invalid("\(type) needs a task and a seq") }
            if payload.scope == .reply, re == nil {
                throw WireError.invalid("\(type) answers a message, so it needs re")
            }
            address = TaskAddress(task: task, seq: seq, re: re)
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(wireProtocolVersion, forKey: .v)
        try c.encode(payload.type, forKey: .type)
        try c.encode(id, forKey: .id)
        if let address {
            try c.encode(address.task, forKey: .task)
            try c.encode(address.seq, forKey: .seq)
            try c.encodeIfPresent(address.re, forKey: .re)
        }
        try payload.encodeBody(to: c.superEncoder(forKey: .body))
    }

    public func validate() throws {
        if let address {
            try WireRule.range(address.seq, 1...1_000_000, "seq")
            if let re = address.re { try WireRule.range(re, 1...1_000_000, "re") }
        }
        try payload.validate()
    }
}

public typealias ClientMessage = WireMessage<ClientPayload>
public typealias ServerMessage = WireMessage<ServerPayload>

/// Mac to gateway.
public enum ClientPayload: WirePayload {
    case hello(HelloBody)
    case reauth(ReauthBody)
    case taskStart(TaskStartBody)
    case observation(ObservationBody)
    case outcome(OutcomeBody)
    case answer(AnswerBody)
    case taskCancel(TaskCancelBody)

    public var type: String {
        switch self {
        case .hello: "hello"
        case .reauth: "reauth"
        case .taskStart: "task.start"
        case .observation: "observation"
        case .outcome: "outcome"
        case .answer: "answer"
        case .taskCancel: "task.cancel"
        }
    }

    public var scope: WireScope {
        switch self {
        case .hello, .reauth: .connection
        case .taskStart, .taskCancel: .task
        case .observation, .outcome, .answer: .reply
        }
    }

    public static func decode(type: String, body: Decoder) throws -> ClientPayload {
        switch type {
        case "hello": .hello(try HelloBody(from: body))
        case "reauth": .reauth(try ReauthBody(from: body))
        case "task.start": .taskStart(try TaskStartBody(from: body))
        case "observation": .observation(try ObservationBody(from: body))
        case "outcome": .outcome(try OutcomeBody(from: body))
        case "answer": .answer(try AnswerBody(from: body))
        case "task.cancel": .taskCancel(try TaskCancelBody(from: body))
        default: throw WireError.unknownType(type)
        }
    }

    public func encodeBody(to encoder: Encoder) throws {
        switch self {
        case .hello(let body): try body.encode(to: encoder)
        case .reauth(let body): try body.encode(to: encoder)
        case .taskStart(let body): try body.encode(to: encoder)
        case .observation(let body): try body.encode(to: encoder)
        case .outcome(let body): try body.encode(to: encoder)
        case .answer(let body): try body.encode(to: encoder)
        case .taskCancel(let body): try body.encode(to: encoder)
        }
    }

    public func validate() throws {
        switch self {
        case .hello(let body): try body.validate()
        case .reauth(let body): try WireRule.length(body.accessToken, 1...8192, "access_token")
        case .taskStart(let body): try body.validate()
        case .observation(let body): try body.validate()
        case .outcome(let body):
            try WireRule.count(body.results, 1...8, "results")
            try body.results.forEach { try $0.validate() }
        case .answer(let body): try WireRule.length(body.text, 1...4000, "text")
        case .taskCancel: break
        }
    }
}

/// Gateway to Mac.
public enum ServerPayload: WirePayload {
    case welcome(WelcomeBody)
    case reauthRequired(ReauthRequiredBody)
    case goodbye(GoodbyeBody)
    case error(ErrorBody)
    case observe(ObserveBody)
    case propose(ProposeBody)
    case ask(AskBody)
    case progress(ProgressBody)
    case finish(FinishBody)

    public var type: String {
        switch self {
        case .welcome: "welcome"
        case .reauthRequired: "reauth.required"
        case .goodbye: "goodbye"
        case .error: "error"
        case .observe: "observe"
        case .propose: "propose"
        case .ask: "ask"
        case .progress: "progress"
        case .finish: "finish"
        }
    }

    public var scope: WireScope {
        switch self {
        case .welcome, .reauthRequired, .goodbye, .error: .connection
        case .observe, .propose, .ask, .progress, .finish: .task
        }
    }

    public static func decode(type: String, body: Decoder) throws -> ServerPayload {
        switch type {
        case "welcome": .welcome(try WelcomeBody(from: body))
        case "reauth.required": .reauthRequired(try ReauthRequiredBody(from: body))
        case "goodbye": .goodbye(try GoodbyeBody(from: body))
        case "error": .error(try ErrorBody(from: body))
        case "observe": .observe(try ObserveBody(from: body))
        case "propose": .propose(try ProposeBody(from: body))
        case "ask": .ask(try AskBody(from: body))
        case "progress": .progress(try ProgressBody(from: body))
        case "finish": .finish(try FinishBody(from: body))
        default: throw WireError.unknownType(type)
        }
    }

    public func encodeBody(to encoder: Encoder) throws {
        switch self {
        case .welcome(let body): try body.encode(to: encoder)
        case .reauthRequired(let body): try body.encode(to: encoder)
        case .goodbye(let body): try body.encode(to: encoder)
        case .error(let body): try body.encode(to: encoder)
        case .observe(let body): try body.encode(to: encoder)
        case .propose(let body): try body.encode(to: encoder)
        case .ask(let body): try body.encode(to: encoder)
        case .progress(let body): try body.encode(to: encoder)
        case .finish(let body): try body.encode(to: encoder)
        }
    }

    public func validate() throws {
        switch self {
        case .welcome(let body):
            try WireRule.range(body.maxPayloadBytes, 1024...Int.max, "max_payload_bytes")
            try WireRule.range(body.heartbeatSeconds, 1...300, "heartbeat_seconds")
            try WireRule.count(body.tasks, 0...16, "tasks")
            try body.tasks.forEach { try WireRule.range($0.lastSeqIn, 0...1_000_000, "last_seq_in") }
        case .reauthRequired(let body):
            try WireRule.range(Int(body.expiresAtMs), 0...Int.max, "expires_at_ms")
        case .goodbye(let body):
            if let after = body.reconnectAfterMs { try WireRule.range(after, 0...600_000, "reconnect_after_ms") }
        case .error(let body): try WireRule.length(body.message, 0...1000, "message")
        case .observe(let body):
            guard body.ax || body.screenshot else {
                throw WireError.invalid("observe asks for the tree, a screenshot or both")
            }
            try WireRule.length(body.app, 1...255, "app")
            if let maxNodes = body.maxNodes { try WireRule.range(maxNodes, 1...2000, "max_nodes") }
        case .propose(let body):
            try WireRule.count(body.actions, 1...8, "actions")
            try body.actions.forEach { try $0.validate() }
        case .ask(let body):
            try WireRule.length(body.question, 1...2000, "question")
            if let choices = body.choices {
                try WireRule.count(choices, 0...6, "choices")
                try choices.forEach { try WireRule.length($0, 1...200, "choice") }
            }
        case .progress(let body): try WireRule.length(body.message, 1...300, "message")
        case .finish(let body): try WireRule.length(body.summary, 0...4000, "summary")
        }
    }
}

/// Encoding and strict decoding for V2 messages.
public enum WireCoding {
    /// Sorted keys, so the same message always encodes to the same bytes (approval digests rely on it).
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }

    public static func encode<P: WirePayload>(_ message: WireMessage<P>) throws -> Data {
        try encoder.encode(message)
    }

    /// Decodes one message and refuses anything the contract doesn't define.
    ///
    /// Codable ignores unknown keys, so strictness comes from a round trip: the message is decoded,
    /// encoded again, and compared with what arrived. Any field the Swift types don't carry, at any
    /// depth, makes the two differ.
    public static func decode<P: WirePayload>(_ type: WireMessage<P>.Type, from data: Data) throws -> WireMessage<P> {
        guard let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw WireError.notAnObject
        }
        let message = try decoder.decode(type, from: data)
        let again = try JSONSerialization.jsonObject(with: encoder.encode(message))
        guard original.isEqual(again) else { throw WireError.unknownField }
        return message
    }
}

/// The contract's value rules, checked after decoding. Lengths count Unicode scalars, as JSON Schema's
/// `maxLength` does.
enum WireRule {
    static func range(_ value: Int, _ bounds: ClosedRange<Int>, _ field: String) throws {
        guard bounds.contains(value) else { throw WireError.invalid("\(field) is out of range") }
    }

    static func range(_ value: Double, min: Double, _ field: String) throws {
        guard value >= min, value.isFinite else { throw WireError.invalid("\(field) is out of range") }
    }

    static func length(_ value: String, _ bounds: ClosedRange<Int>, _ field: String) throws {
        guard bounds.contains(value.unicodeScalars.count) else {
            throw WireError.invalid("\(field) has the wrong length")
        }
    }

    static func count<T>(_ values: [T], _ bounds: ClosedRange<Int>, _ field: String) throws {
        guard bounds.contains(values.count) else { throw WireError.invalid("\(field) has the wrong count") }
    }

    static func matches(_ value: String, _ pattern: String, _ field: String) throws {
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw WireError.invalid("\(field) is not in the expected form")
        }
    }

    static let operationNamePattern = "^[a-z][a-z0-9_]{0,63}$"
    static let elementRefPattern = "^e[0-9]{1,5}$"
    static let keyPattern = "^[a-z0-9]{1,16}$"
}

extension HelloBody {
    func validate() throws {
        try WireRule.length(appVersion, 1...32, "app_version")
        try WireRule.length(osVersion, 1...32, "os_version")
        try manifest.validate()
        try WireRule.count(resume, 0...16, "resume")
        for entry in resume {
            try WireRule.range(entry.lastSeqIn, 0...1_000_000, "last_seq_in")
            try WireRule.range(entry.lastSeqOut, 0...1_000_000, "last_seq_out")
            try WireRule.count(entry.ledger, 0...64, "ledger")
        }
    }
}

extension Manifest {
    func validate() throws {
        try WireRule.count(operations, 0...128, "operations")
        for operation in operations {
            try WireRule.matches(operation.name, WireRule.operationNamePattern, "operation name")
            try WireRule.range(operation.version, 1...1000, "operation version")
        }
        try WireRule.count(screen.tools, 0...16, "screen tools")
        guard Set(screen.tools).count == screen.tools.count else {
            throw WireError.invalid("screen tools must be unique")
        }
        try WireRule.count(permissions.automation, 0...64, "automation")
    }
}

extension TaskStartBody {
    func validate() throws {
        try WireRule.length(goal, 1...4000, "goal")
        if let selection = context.finderSelection {
            try WireRule.count(selection, 0...50, "finder_selection")
            try selection.forEach { try WireRule.length($0, 1...1024, "finder_selection item") }
        }
    }
}

extension ObservationBody {
    func validate() throws {
        try WireRule.range(generation, 1...1_000_000, "generation")
        if let app { try WireRule.range(app.pid, 1...Int.max, "pid") }
        if let ax {
            try WireRule.count(ax.nodes, 0...2000, "nodes")
            for node in ax.nodes {
                try WireRule.matches(node.ref, WireRule.elementRefPattern, "ref")
                try WireRule.range(node.depth, 0...64, "depth")
                try WireRule.length(node.role, 1...64, "role")
                if let label = node.label { try WireRule.length(label, 0...500, "label") }
                if let value = node.value { try WireRule.length(value, 0...2000, "value") }
                if let actions = node.actions { try WireRule.count(actions, 0...8, "actions") }
            }
        }
        if let screenshot {
            try WireRule.length(screenshot.data, 1...4_000_000, "data")
            try WireRule.range(screenshot.width, 1...20_000, "width")
            try WireRule.range(screenshot.height, 1...20_000, "height")
        }
    }
}

extension ActionResult {
    func validate() throws {
        if let evidence { try WireRule.length(evidence, 0...2000, "evidence") }
        if let message = error?.message { try WireRule.length(message, 0...1000, "error message") }
    }
}

extension ElementRef {
    func validate() throws {
        try WireRule.matches(ref, WireRule.elementRefPattern, "ref")
        try WireRule.range(generation, 1...1_000_000, "generation")
    }
}

extension WireAction {
    func validate() throws {
        if let expect { try WireRule.length(expect, 0...500, "expect") }
        switch kind {
        case .operation(let operation):
            try WireRule.matches(operation.name, WireRule.operationNamePattern, "operation name")
            try WireRule.range(operation.version, 1...1000, "operation version")
        case .screen(let screen):
            try WireRule.length(screen.app, 1...255, "app")
            try screen.validate()
        }
    }
}

extension ScreenAction {
    func validate() throws {
        switch self {
        case .press(_, let element):
            try element.validate()
        case .setValue(_, let element, let value):
            try element.validate()
            try WireRule.length(value, 0...10_000, "value")
        case .typeText(_, let text, let element):
            try WireRule.length(text, 1...10_000, "text")
            try element?.validate()
        case .key(_, let keys):
            try WireRule.count(keys, 1...5, "keys")
            try keys.forEach { try WireRule.matches($0, WireRule.keyPattern, "key") }
        case .scroll(_, _, let amount, let element):
            try WireRule.range(amount, 1...20, "amount")
            try element?.validate()
        case .menu(_, let path):
            try WireRule.count(path, 1...6, "path")
            try path.forEach { try WireRule.length($0, 1...200, "menu title") }
        case .clickPoint(_, let x, let y, let generation, let count):
            try WireRule.range(x, min: 0, "x")
            try WireRule.range(y, min: 0, "y")
            try WireRule.range(generation, 1...1_000_000, "generation")
            if let count { try WireRule.range(count, 1...2, "count") }
        }
    }
}
