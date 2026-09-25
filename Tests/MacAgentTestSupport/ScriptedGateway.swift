import Foundation
@testable import MacAgentCore

/// One in-memory socket. The Mac side sees `events`; the gateway side delivers and drops.
public final class InMemoryChannel: GatewayChannel, @unchecked Sendable {
    public let events: AsyncStream<GatewayChannelEvent>
    private let continuation: AsyncStream<GatewayChannelEvent>.Continuation
    private let lock = NSLock()
    private var isClosed = false
    let fromMac: @Sendable (String) -> Void

    init(fromMac: @escaping @Sendable (String) -> Void) {
        (events, continuation) = AsyncStream.makeStream(of: GatewayChannelEvent.self)
        self.fromMac = fromMac
    }

    public func send(_ text: String) async throws {
        guard !lock.withLock({ isClosed }) else { throw GatewayTransportError.unreachable("closed") }
        fromMac(text)
    }

    public func close(code: Int) async {
        drop(code: code)
    }

    func deliver(_ text: String) {
        guard !lock.withLock({ isClosed }) else { return }
        continuation.yield(.text(text))
    }

    func drop(code: Int) {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        guard first else { return }
        continuation.yield(.closed(code: code, reason: ""))
        continuation.finish()
    }
}

/// A gateway that follows a script: the test decides every message it sends, and reads every
/// message the Mac sends.
public actor ScriptedGateway: GatewayTransport {
    public struct Refusal: Sendable {
        public var status: Int
        public var remaining: Int
    }

    private var channel: InMemoryChannel?
    private var received: [ClientMessage] = []
    private var waiters: [(type: String, reply: CheckedContinuation<ClientMessage, any Error>)] = []
    private var seqOut: [TaskID: Int] = [:]
    private var seqIn: [TaskID: Int] = [:]
    private var refusal: Refusal?
    public private(set) var connections = 0
    /// What welcome says about each resumed task. Defaults to live, with what the gateway has seen.
    public var welcomeState: @Sendable (TaskID) -> WelcomeBody.TaskState.State = { _ in .live }

    public init() {}

    public func refuseNext(_ count: Int, status: Int) {
        refusal = Refusal(status: status, remaining: count)
    }

    public func setWelcomeState(_ state: @escaping @Sendable (TaskID) -> WelcomeBody.TaskState.State) {
        welcomeState = state
    }

    public nonisolated func open(url: URL, headers: [String: String]) async throws -> any GatewayChannel {
        try await accept()
    }

    private func accept() throws -> InMemoryChannel {
        if var refusal, refusal.remaining > 0 {
            refusal.remaining -= 1
            self.refusal = refusal.remaining > 0 ? refusal : nil
            throw GatewayTransportError.refused(status: refusal.status)
        }
        connections += 1
        let channel = InMemoryChannel { [weak self] text in
            Task { await self?.fromMac(text) }
        }
        self.channel = channel
        return channel
    }

    private func fromMac(_ text: String) {
        guard let message = try? WireCoding.decode(ClientMessage.self, from: Data(text.utf8)) else { return }
        if case .hello(let hello) = message.payload {
            let tasks = hello.resume.map {
                WelcomeBody.TaskState(task: $0.task, state: welcomeState($0.task), lastSeqIn: seqIn[$0.task] ?? 0)
            }
            deliver(ServerMessage(payload: .welcome(WelcomeBody(
                sessionID: SessionID(),
                serverTimeMs: 0,
                maxPayloadBytes: 6 * 1024 * 1024,
                heartbeatSeconds: 20,
                tasks: tasks
            ))))
        }
        if let address = message.address {
            seqIn[address.task] = max(seqIn[address.task] ?? 0, address.seq)
        }
        received.append(message)
        if let index = waiters.firstIndex(where: { $0.type == message.payload.type }) {
            let waiter = waiters.remove(at: index)
            received.removeAll { $0.id == message.id }
            waiter.reply.resume(returning: message)
        }
    }

    /// The next message of this type the Mac sends, or one it already sent and nobody read.
    public func next(_ type: String, timeout: TimeInterval = 3) async throws -> ClientMessage {
        if let index = received.firstIndex(where: { $0.payload.type == type }) {
            return received.remove(at: index)
        }
        return try await withCheckedThrowingContinuation { reply in
            waiters.append((type, reply))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeOut(type)
            }
        }
    }

    private func timeOut(_ type: String) {
        guard let index = waiters.firstIndex(where: { $0.type == type }) else { return }
        waiters.remove(at: index).reply.resume(throwing: ScriptedGatewayTimeout(type: type))
    }

    public func unread(_ type: String) -> [ClientMessage] {
        received.filter { $0.payload.type == type }
    }

    /// Sends a task message with the task's next seq, or with the seq given.
    @discardableResult
    public func send(_ task: TaskID, _ payload: ServerPayload, re: Int? = nil, seq: Int? = nil) -> ServerMessage {
        let next = seq ?? ((seqOut[task] ?? 0) + 1)
        seqOut[task] = max(seqOut[task] ?? 0, next)
        let message = ServerMessage(address: TaskAddress(task: task, seq: next, re: re), payload: payload)
        deliver(message)
        return message
    }

    public func deliver(_ message: ServerMessage) {
        guard let data = try? WireCoding.encode(message) else { return }
        channel?.deliver(String(decoding: data, as: UTF8.self))
    }

    public func drop(code: Int = 1006) {
        channel?.drop(code: code)
        channel = nil
    }
}

public struct ScriptedGatewayTimeout: Error, CustomStringConvertible {
    public let type: String
    public var description: String { "the Mac sent no \(type) in time" }
}

/// Credentials that always have a token.
public struct FixedGatewayCredentials: GatewayCredentials {
    public init() {}
    public func accessToken(forceRefresh: Bool) async throws -> String { "test-token" }
}

/// Resolves app names from a fixed list, as Launch Services would.
public struct FixedAppResolver: InstalledAppResolving {
    public let apps: [InstalledApp]

    public init(_ apps: [InstalledApp]) {
        self.apps = apps
    }

    public func resolve(_ rawName: String?) -> InstalledApp? {
        guard let name = rawName?.lowercased() else { return nil }
        return apps.first { $0.displayName.lowercased() == name || $0.bundleIdentifier.lowercased() == name }
    }
}

/// Polls until a condition holds, for state that settles through actor hops.
public func eventually(
    timeout: TimeInterval = 3,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
