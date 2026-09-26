import Foundation

/// Hands the connection a fresh access token. The app's `SonnyBackendClient` refreshes through
/// `/v1/auth/refresh` as it does for every HTTP call.
public protocol GatewayCredentials: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public enum GatewayStopReason: Sendable, Equatable {
    /// The account or its sign-in ended. Sign in again.
    case signedOut
    /// Another session from this Mac took over.
    case replaced
    case notSignedIn
    /// The gateway refused this app version.
    case clientTooOld
}

public enum GatewayState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    /// Waiting to try again.
    case offline
    case stopped(GatewayStopReason)
}

/// How long to wait before reconnecting: doubling from half a second to thirty, each wait jittered
/// down by up to half so a fleet of Macs doesn't reconnect in step after a deploy.
public struct GatewayBackoff: Sendable {
    public var base: TimeInterval
    public var cap: TimeInterval
    public var jitter: @Sendable () -> Double

    public init(base: TimeInterval = 0.5, cap: TimeInterval = 30, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.base = base
        self.cap = cap
        self.jitter = jitter
    }

    public func delay(afterFailures failures: Int) -> TimeInterval {
        let exponential = min(cap, base * pow(2, Double(max(0, failures - 1))))
        return exponential * (1 - 0.5 * jitter())
    }
}

/// What the connection needs from the rest of the kernel, as callbacks so it holds no reference to
/// the task controller.
public struct GatewayHandlers: Sendable {
    public var manifest: @Sendable () async -> Manifest
    public var resume: @Sendable () async -> [HelloBody.ResumeEntry]
    public var welcomed: @Sendable (WelcomeBody, UInt64) async -> Void
    public var received: @Sendable (ServerMessage, UInt64) async -> Void
    public var stateChanged: @Sendable (GatewayState) async -> Void

    public init(
        manifest: @escaping @Sendable () async -> Manifest,
        resume: @escaping @Sendable () async -> [HelloBody.ResumeEntry],
        welcomed: @escaping @Sendable (WelcomeBody, UInt64) async -> Void,
        received: @escaping @Sendable (ServerMessage, UInt64) async -> Void,
        stateChanged: @escaping @Sendable (GatewayState) async -> Void = { _ in }
    ) {
        self.manifest = manifest
        self.resume = resume
        self.welcomed = welcomed
        self.received = received
        self.stateChanged = stateChanged
    }
}

/// The Mac's one socket to the gateway: connects, says hello, keeps the token fresh, reconnects with
/// backoff, and routes what arrives. Each connection gets a new generation number, and tasks drop
/// any message stamped with a generation that is no longer current.
public actor GatewayConnection {
    public struct Identity: Sendable {
        public var deviceID: DeviceID
        public var appVersion: String
        public var osVersion: String

        public init(deviceID: DeviceID, appVersion: String, osVersion: String) {
            self.deviceID = deviceID
            self.appVersion = appVersion
            self.osVersion = osVersion
        }
    }

    private let url: URL
    private let transport: any GatewayTransport
    private let credentials: any GatewayCredentials
    private let identity: Identity
    private let handlers: GatewayHandlers
    private let backoff: GatewayBackoff

    public private(set) var state: GatewayState = .idle
    public private(set) var generation: UInt64 = 0
    private var channel: (any GatewayChannel)?
    private var loop: Task<Void, Never>?
    private var failures = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        url: URL,
        transport: any GatewayTransport,
        credentials: any GatewayCredentials,
        identity: Identity,
        handlers: GatewayHandlers,
        backoff: GatewayBackoff = GatewayBackoff()
    ) {
        self.url = url
        self.transport = transport
        self.credentials = credentials
        self.identity = identity
        self.handlers = handlers
        self.backoff = backoff
    }

    /// Starts connecting, and keeps reconnecting until stopped.
    public func start() {
        guard loop == nil else { return }
        if case .stopped = state { state = .idle }
        loop = Task { await self.run() }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        await channel?.close(code: 1000)
        channel = nil
        await setState(.idle)
    }

    /// Whether the socket is up, trying to connect first if it isn't. Resolves false as soon as a
    /// connection attempt fails, so a model-backed request can fail at once instead of hanging
    /// (V2 plan decision 13).
    public func ensureConnected(within timeout: TimeInterval) async -> Bool {
        if state == .connected { return true }
        if case .stopped = state { return false }
        start()
        let id = UUID()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.resolveWaiter(id, false)
            }
        }
    }

    /// Sends one message. False if there is no open socket; the task keeps it in its outbox and
    /// sends it again after the next welcome.
    @discardableResult
    public func send(_ message: ClientMessage) async -> Bool {
        guard state == .connected, let channel else { return false }
        do {
            let data = try WireCoding.encode(message)
            try await channel.send(String(decoding: data, as: UTF8.self))
            return true
        } catch {
            return false
        }
    }

    private func resolveWaiter(_ id: UUID, _ connected: Bool) {
        waiters.removeValue(forKey: id)?.resume(returning: connected)
    }

    private func resolveWaiters(_ connected: Bool) {
        let pending = waiters
        waiters = [:]
        for continuation in pending.values { continuation.resume(returning: connected) }
    }

    private func setState(_ new: GatewayState) async {
        guard new != state else { return }
        state = new
        switch new {
        case .connected: resolveWaiters(true)
        case .offline, .stopped: resolveWaiters(false)
        case .idle, .connecting: break
        }
        await handlers.stateChanged(new)
    }

    private func run() async {
        var refreshToken = false
        while !Task.isCancelled {
            await setState(.connecting)
            let next = await attempt(refreshingToken: refreshToken)
            refreshToken = false
            channel = nil
            if Task.isCancelled { return }

            switch next {
            case .stop(let reason):
                await setState(.stopped(reason))
                loop = nil
                return
            case .refreshAndRetry:
                refreshToken = true
                failures += 1
            case .reconnect(let delay):
                failures = 0
                await setState(.offline)
                await pause(delay)
            case .backoff:
                failures += 1
                await setState(.offline)
                await pause(backoff.delay(afterFailures: failures))
            }
        }
    }

    /// Waits before the next attempt. A direct `Task.sleep`, not an injected closure: calling a stored
    /// async closure from this actor crashed the Swift 6.3 runtime ("freed pointer was not the last
    /// allocation"), and tests shorten waits through `GatewayBackoff` instead.
    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// One connection attempt, from the token to the socket closing.
    private func attempt(refreshingToken: Bool) async -> Next {
        let token: String
        do {
            token = try await credentials.accessToken(forceRefresh: refreshingToken)
        } catch SonnyBackendError.notSignedIn {
            return .stop(.notSignedIn)
        } catch {
            return .backoff
        }
        let opened: any GatewayChannel
        do {
            opened = try await transport.open(url: url, headers: [
                "Authorization": "Bearer \(token)",
                "Sonny-Client-Version": identity.appVersion,
            ])
        } catch let GatewayTransportError.refused(status) {
            switch status {
            case 401: return failures == 0 ? .refreshAndRetry : .backoff
            case 410: return .stop(.clientTooOld)
            default: return .backoff
            }
        } catch {
            return .backoff
        }
        return await session(on: opened)
    }

    private enum Next {
        case stop(GatewayStopReason)
        case refreshAndRetry
        case reconnect(after: TimeInterval)
        case backoff
    }

    /// One connected socket, from hello until it closes. Returns what to do next.
    private func session(on channel: any GatewayChannel) async -> Next {
        self.channel = channel
        generation += 1
        let current = generation
        let hello = ClientMessage(payload: .hello(HelloBody(
            deviceID: identity.deviceID,
            appVersion: identity.appVersion,
            osVersion: identity.osVersion,
            manifest: await handlers.manifest(),
            resume: await handlers.resume()
        )))
        do {
            try await channel.send(String(decoding: try WireCoding.encode(hello), as: UTF8.self))
        } catch {
            return .backoff
        }

        var goodbye: GoodbyeBody?
        for await event in channel.events {
            switch event {
            case .text(let text):
                guard let message = try? WireCoding.decode(ServerMessage.self, from: Data(text.utf8)) else {
                    continue
                }
                switch message.payload {
                case .welcome(let welcome):
                    failures = 0
                    await setState(.connected)
                    await handlers.welcomed(welcome, current)
                case .reauthRequired:
                    if let token = try? await credentials.accessToken(forceRefresh: true) {
                        _ = await send(ClientMessage(payload: .reauth(ReauthBody(accessToken: token))))
                    }
                case .goodbye(let body):
                    goodbye = body
                case .error:
                    continue
                default:
                    await handlers.received(message, current)
                }
            case .closed(let code, _):
                return next(afterClose: code, goodbye: goodbye)
            }
        }
        return next(afterClose: 1006, goodbye: goodbye)
    }

    private func next(afterClose code: Int, goodbye: GoodbyeBody?) -> Next {
        switch (goodbye?.reason, code) {
        case (.signedOut?, _), (_, 4403): return .stop(.signedOut)
        case (.replaced?, _), (_, 4409): return .stop(.replaced)
        case (.authExpired?, _), (_, 4401): return .refreshAndRetry
        case (.draining?, _), (_, 1012):
            return .reconnect(after: Double(goodbye?.reconnectAfterMs ?? 1000) / 1000)
        default: return .backoff
        }
    }
}
