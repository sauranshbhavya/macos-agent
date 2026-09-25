import Combine
import Foundation

/// What someone asked Sonny to do, from any entry point: the composer, voice, a routine, a
/// schedule, a follow-up or a watcher.
public struct TaskRequest: Sendable, Equatable {
    public var goal: String
    public var origin: TaskOrigin
    public var isPrivate: Bool
    public var unattended: Bool
    public var mode: AgentInteractionMode
    public var priorTask: TaskID?
    public var context: TaskStartBody.Context

    public init(
        goal: String,
        origin: TaskOrigin = .composer,
        isPrivate: Bool = false,
        unattended: Bool = false,
        mode: AgentInteractionMode,
        priorTask: TaskID? = nil,
        context: TaskStartBody.Context = .init()
    ) {
        self.goal = goal
        self.origin = origin
        self.isPrivate = isPrivate
        self.unattended = unattended
        self.mode = mode
        self.priorTask = priorTask
        self.context = context
    }

    var startBody: TaskStartBody {
        TaskStartBody(
            goal: goal,
            origin: origin,
            isPrivate: isPrivate,
            unattended: unattended,
            mode: mode,
            priorTask: priorTask,
            context: context
        )
    }
}

public enum TaskSubmission: Sendable, Equatable {
    case started(TaskID)
    /// Another task is running; this one starts when it ends.
    case queued(TaskID)
    case failed(TaskID, TaskFailure)

    public var task: TaskID {
        switch self {
        case .started(let id), .queued(let id), .failed(let id, _): id
        }
    }
}

/// The one thing the UI talks to. It submits requests, publishes a snapshot per task, and routes
/// approvals, answers and cancels by task and action id — never by which window is in front.
///
/// One task runs at a time for now; later ones wait their turn (V2 plan, "Later — concurrent
/// tasks").
@MainActor
public final class TaskController: ObservableObject {
    @Published public private(set) var tasks: [TaskSnapshot] = []
    @Published public private(set) var gateway: GatewayState = .idle

    private var runtimes: [TaskID: TaskRuntime] = [:]
    private var waiting: [TaskID] = []
    private var liveTask: TaskID?
    private var generation: UInt64 = 0
    private var connection: GatewayConnection!
    private let ledgers: any TaskLedgerStoring
    private let capabilities: KernelCapabilities
    private let screenTools: Set<ScreenToolName>
    private let observer: any TaskObserver
    private let broker: ApprovalBroker
    private let permissions: @Sendable () -> Manifest.Permissions
    private let connectTimeout: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        url: URL,
        transport: any GatewayTransport,
        credentials: any GatewayCredentials,
        identity: GatewayConnection.Identity,
        ledgers: any TaskLedgerStoring,
        capabilities: KernelCapabilities,
        screenTools: Set<ScreenToolName> = [],
        observer: any TaskObserver = UnavailableObserver(),
        permissions: @escaping @Sendable () -> Manifest.Permissions,
        backoff: GatewayBackoff = GatewayBackoff(),
        connectTimeout: TimeInterval = 8,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ledgers = ledgers
        self.capabilities = capabilities
        self.screenTools = screenTools
        self.observer = observer
        self.broker = ApprovalBroker(now: now)
        self.permissions = permissions
        self.connectTimeout = connectTimeout
        self.now = now
        let operations = capabilities.manifestOperations
        let tools = screenTools.sorted { $0.rawValue < $1.rawValue }
        self.connection = GatewayConnection(
            url: url,
            transport: transport,
            credentials: credentials,
            identity: identity,
            handlers: GatewayHandlers(
                manifest: { Manifest(operations: operations, screen: .init(tools: tools), permissions: permissions()) },
                resume: { [weak self] in await self?.resumeEntries() ?? [] },
                welcomed: { [weak self] welcome, generation in await self?.welcomed(welcome, generation: generation) },
                received: { [weak self] message, generation in await self?.route(message, generation: generation) },
                stateChanged: { [weak self] state in await self?.gatewayChanged(state) }
            ),
            backoff: backoff
        )
    }

    /// Restores every task a relaunch interrupted, then connects. Their ledgers go to the gateway in
    /// hello, and each is reconciled against what the gateway says.
    public func launch() async {
        let unfinished = (try? ledgers.unfinished()) ?? []
        for record in unfinished {
            let runtime = TaskRuntime(restoring: record, deps: dependencies())
            runtimes[record.task] = runtime
            if liveTask == nil { liveTask = record.task }
            apply(await runtime.snapshot())
        }
        await connection.start()
    }

    public func shutDown() async {
        await connection.stop()
    }

    /// Starts a model-backed task. With no gateway connection it fails at once with a plain server
    /// error (V2 plan decision 13).
    @discardableResult
    public func submit(_ request: TaskRequest) async -> TaskSubmission {
        let id = TaskID()
        let runtime = TaskRuntime(id: id, request: request.startBody, deps: dependencies())
        runtimes[id] = runtime
        apply(await runtime.snapshot())
        await runtime.setConnecting()

        guard await connection.ensureConnected(within: connectTimeout) else {
            await runtime.fail(.serverUnavailable)
            return .failed(id, .serverUnavailable)
        }
        if liveTask != nil {
            waiting.append(id)
            return .queued(id)
        }
        liveTask = id
        await runtime.start(generation: generation)
        return .started(id)
    }

    public func cancel(_ task: TaskID) async {
        if let index = waiting.firstIndex(of: task) {
            waiting.remove(at: index)
            await runtimes[task]?.fail(TaskFailure(reason: .cancelled, message: "Stopped before it started."))
            return
        }
        await runtimes[task]?.cancel()
    }

    public func decide(task: TaskID, action: ActionID, commit: UUID, approved: Bool) async {
        await runtimes[task]?.decide(action: action, commitID: commit, approved: approved)
    }

    public func answer(task: TaskID, text: String) async {
        await runtimes[task]?.answer(text)
    }

    public func resolvePause(task: TaskID, choice: PauseChoice) async {
        await runtimes[task]?.resolvePause(choice)
    }

    public func snapshot(_ task: TaskID) -> TaskSnapshot? {
        tasks.first { $0.id == task }
    }

    // MARK: Connection callbacks

    private func dependencies() -> RuntimeDependencies {
        let connection = self.connection!
        return RuntimeDependencies(
            send: { message in await connection.send(message) },
            ledgers: ledgers,
            capabilities: capabilities,
            screenTools: screenTools,
            observer: observer,
            broker: broker,
            publish: { [weak self] snapshot in await self?.apply(snapshot) },
            now: now
        )
    }

    private func resumeEntries() async -> [HelloBody.ResumeEntry] {
        var entries: [HelloBody.ResumeEntry] = []
        for runtime in runtimes.values {
            if let entry = await runtime.resumeEntry() { entries.append(entry) }
        }
        return Array(entries.prefix(16))
    }

    private func welcomed(_ welcome: WelcomeBody, generation: UInt64) async {
        self.generation = generation
        for (id, runtime) in runtimes {
            let state = welcome.tasks.first { $0.task == id }
            await runtime.welcomed(state, generation: generation)
        }
    }

    private func route(_ message: ServerMessage, generation: UInt64) async {
        guard let task = message.address?.task, let runtime = runtimes[task] else { return }
        await runtime.receive(message, generation: generation)
    }

    private func gatewayChanged(_ state: GatewayState) {
        gateway = state
    }

    private func apply(_ snapshot: TaskSnapshot) {
        if let index = tasks.firstIndex(where: { $0.id == snapshot.id }) {
            tasks[index] = snapshot
        } else {
            tasks.append(snapshot)
        }
        if snapshot.phase.isTerminal, liveTask == snapshot.id {
            liveTask = nil
            Task { await self.startNext() }
        }
    }

    private func startNext() async {
        guard liveTask == nil, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        guard let runtime = runtimes[next] else { return }
        guard await connection.ensureConnected(within: connectTimeout) else {
            await runtime.fail(.serverUnavailable)
            await startNext()
            return
        }
        liveTask = next
        await runtime.start(generation: generation)
    }
}

/// The Mac's device id: random, made once, kept in the Keychain (V2 plan section 5).
public enum GatewayDeviceIdentity {
    static let service = "com.sonny.v2"
    static let account = "device-id"

    public static func deviceID(store: any KeychainSecretStoring = KeychainSecretStore()) -> DeviceID {
        if let data = try? store.data(service: service, account: account),
           let text = String(data: data, encoding: .utf8),
           let id = DeviceID(text) {
            return id
        }
        let id = DeviceID()
        try? store.save(Data(id.description.utf8), service: service, account: account)
        return id
    }
}

public enum GatewayEndpoint {
    /// `wss://host/v2/session` for an `https` base URL, `ws://` for `http`.
    public static func sessionURL(base: URL) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v2/session"
        components.query = nil
        return components.url ?? base
    }
}
