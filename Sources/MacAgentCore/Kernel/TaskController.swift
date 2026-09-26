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
    /// As many tasks as run at once are running; this one starts when one of them ends.
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
/// Up to `maxLiveTasks` tasks run at once, and later ones wait their turn (V2 plan, "Later —
/// concurrent tasks"). Tasks share the Mac through the foreground lease, and an app's screen work
/// belongs to one task at a time.
@MainActor
public final class TaskController: ObservableObject {
    @Published public private(set) var tasks: [TaskSnapshot] = []
    @Published public private(set) var gateway: GatewayState = .idle

    private var runtimes: [TaskID: TaskRuntime] = [:]
    /// Instant-path tasks: they never touch the gateway, so they sit out hello and welcome.
    private var localTasks: Set<TaskID> = []
    private var waiting: [TaskID] = []
    private var liveTasks: Set<TaskID> = []
    private let maxLiveTasks: Int
    private var generation: UInt64 = 0
    private var connection: GatewayConnection!
    private let ledgers: any TaskLedgerStoring
    private let capabilities: KernelCapabilities
    private let localCapabilities: KernelCapabilities
    private let screenTools: Set<ScreenToolName>
    private let screenFactory: @Sendable () -> (any ScreenControlling)?
    private let broker: ApprovalBroker
    private let lease: ForegroundLease
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
        localCapabilities: [any Capability] = [],
        screenTools: Set<ScreenToolName> = [],
        screenFactory: @escaping @Sendable () -> (any ScreenControlling)? = { nil },
        permissions: @escaping @Sendable () -> Manifest.Permissions,
        backoff: GatewayBackoff = GatewayBackoff(),
        connectTimeout: TimeInterval = 8,
        maxLiveTasks: Int = TaskController.defaultMaxLiveTasks,
        lease: ForegroundLease = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.maxLiveTasks = max(1, maxLiveTasks)
        self.lease = lease
        self.ledgers = ledgers
        self.capabilities = capabilities
        self.localCapabilities = KernelCapabilities(capabilities.all + localCapabilities)
        self.screenTools = screenTools
        self.screenFactory = screenFactory
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
            let snapshot = await runtime.snapshot()
            // A task that already ended here only has messages to deliver; it holds no slot.
            if !snapshot.phase.isTerminal { liveTasks.insert(record.task) }
            apply(snapshot)
        }
        await connection.start()
    }

    public func shutDown() async {
        await connection.stop()
    }

    /// The account changed: close the socket and connect again as whoever is signed in now. A
    /// sign-out leaves it stopped until the next sign-in.
    public func reconnect() async {
        await connection.stop()
        await connection.start()
    }

    /// Ends every unfinished task, here and on disk, without telling the gateway: they belonged to
    /// an account that is no longer signed in, and none of them may be offered to the next one's
    /// session or shown to whoever signs in next. Callable before `launch()`, when only ledgers exist.
    public func discardUnfinishedTasks() async {
        for runtime in runtimes.values { await runtime.discard() }
        for record in (try? ledgers.unfinished()) ?? [] { try? ledgers.delete(record.task) }
        runtimes.removeAll()
        localTasks.removeAll()
        liveTasks.removeAll()
        waiting.removeAll()
        tasks.removeAll()
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
            let failure = await connectionFailure()
            await runtime.fail(failure)
            return .failed(id, failure)
        }
        if liveTasks.count >= maxLiveTasks || !waiting.isEmpty {
            waiting.append(id)
            await runtime.setQueued()
            return .queued(id)
        }
        liveTasks.insert(id)
        await runtime.start(generation: generation)
        return .started(id)
    }

    /// Runs a command the Mac resolved on its own, with no model and no gateway (V2 plan section 6,
    /// "Instant path"). Its actions go through the same validator, gate, approval and ledger as a
    /// gateway task's, and the task ends from its own outcome. Instant commands don't queue behind a
    /// running task: they are single quick actions, and the gate and the foreground lease still
    /// apply.
    @discardableResult
    public func submitLocal(_ request: TaskRequest, actions: [WireAction]) async -> TaskSubmission {
        let id = TaskID()
        let finisher = LocalFinisher()
        let runtime = TaskRuntime(id: id, request: request.startBody, deps: dependencies(local: finisher))
        await finisher.attach(runtime)
        runtimes[id] = runtime
        localTasks.insert(id)
        apply(await runtime.snapshot())
        await runtime.start(generation: Self.localGeneration)
        let propose = ServerMessage(
            address: TaskAddress(task: id, seq: 1, re: 1),
            payload: .propose(ProposeBody(agent: .planner, actions: actions, final: true))
        )
        await runtime.receive(propose, generation: Self.localGeneration)
        return .started(id)
    }

    /// Local tasks' connection generation. A gateway connection's generations start at 1.
    static let localGeneration: UInt64 = 0

    /// How many model-backed tasks run at once. Each holds a planner on the gateway and may hold an
    /// app's screen work, so a few is plenty; more wait their turn.
    public static let defaultMaxLiveTasks = 3

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

    private func dependencies(local: LocalFinisher? = nil) -> RuntimeDependencies {
        let connection = self.connection!
        return RuntimeDependencies(
            send: { message in
                if let local {
                    await local.handle(message)
                    return true
                }
                return await connection.send(message)
            },
            ledgers: ledgers,
            capabilities: local == nil ? capabilities : localCapabilities,
            screen: screenFactory(),
            broker: broker,
            lease: lease,
            publish: { [weak self] snapshot in await self?.apply(snapshot) },
            now: now
        )
    }

    private func resumeEntries() async -> [HelloBody.ResumeEntry] {
        var entries: [HelloBody.ResumeEntry] = []
        for (id, runtime) in runtimes where !localTasks.contains(id) {
            if let entry = await runtime.resumeEntry() { entries.append(entry) }
        }
        return Array(entries.prefix(16))
    }

    private func welcomed(_ welcome: WelcomeBody, generation: UInt64) async {
        self.generation = generation
        for (id, runtime) in runtimes where !localTasks.contains(id) {
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
        if snapshot.phase.isTerminal, liveTasks.remove(snapshot.id) != nil {
            Task { await self.startNext() }
        }
        if snapshot.phase.isTerminal { forgetOldFinishedTasks() }
    }

    /// Finished tasks kept in memory for the UI; history keeps the rest on disk.
    static let finishedKept = 20

    private func forgetOldFinishedTasks() {
        let finished = tasks.filter { $0.phase.isTerminal }
        guard finished.count > Self.finishedKept else { return }
        let forgotten = Set(finished.prefix(finished.count - Self.finishedKept).map(\.id))
        tasks.removeAll { forgotten.contains($0.id) }
        for id in forgotten {
            runtimes[id] = nil
            localTasks.remove(id)
        }
    }

    /// Why a task couldn't reach the gateway, in words that say what to do about it.
    private func connectionFailure() async -> TaskFailure {
        switch await connection.state {
        case .stopped(.notSignedIn), .stopped(.signedOut): .signInNeeded
        case .stopped(.clientTooOld): .clientTooOld
        case .stopped(.replaced): .replacedElsewhere
        default: .serverUnavailable
        }
    }

    /// Starts waiting tasks, oldest first, while there are free slots.
    private func startNext() async {
        while liveTasks.count < maxLiveTasks, !waiting.isEmpty {
            let next = waiting.removeFirst()
            guard let runtime = runtimes[next] else { continue }
            // Claimed before the wait below, so a second call can't start more tasks than there are
            // slots.
            liveTasks.insert(next)
            guard await connection.ensureConnected(within: connectTimeout) else {
                liveTasks.remove(next)
                await runtime.fail(await connectionFailure())
                continue
            }
            await runtime.start(generation: generation)
        }
    }
}

/// Plays the gateway's last part for an instant-path task: when the task's outcome comes back, it
/// finishes the task from that outcome.
actor LocalFinisher {
    private var runtime: TaskRuntime?

    func attach(_ runtime: TaskRuntime) {
        self.runtime = runtime
    }

    func handle(_ message: ClientMessage) {
        guard case .outcome(let body) = message.payload, let runtime, let address = message.address else { return }
        let done = body.results.allSatisfy { $0.status == .done }
        let evidence = body.results.compactMap { $0.evidence ?? $0.error?.message }.prefix(3).joined(separator: " ")
        let finish = FinishBody(
            status: done ? .completed : .failed,
            summary: evidence.isEmpty ? (done ? "Done." : "That didn't work.") : evidence
        )
        let message = ServerMessage(address: TaskAddress(task: address.task, seq: 2, re: address.seq), payload: .finish(finish))
        // Delivered after this send returns, so the runtime isn't finishing mid-send.
        Task { await runtime.receive(message, generation: TaskController.localGeneration) }
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
