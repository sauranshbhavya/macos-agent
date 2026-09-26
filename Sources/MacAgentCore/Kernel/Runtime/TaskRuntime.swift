import Foundation

public enum PauseReason: Sendable, Equatable {
    /// An action with a real effect was dispatched and its end is unknown: it may already have
    /// happened. The user checks, then continues or stops. It is never retried.
    case outcomeUnknown(action: ActionID, effect: Effect, title: String)
}

public enum PauseChoice: Sendable, Equatable {
    case continueTask
    case stop
}

public struct TaskFailure: Sendable, Equatable {
    public var reason: FinishBody.Reason?
    public var message: String

    public init(reason: FinishBody.Reason?, message: String) {
        self.reason = reason
        self.message = message
    }

    /// Decision 13: no gateway, no model-backed task. Said plainly, never a raw error.
    public static let serverUnavailable = TaskFailure(
        reason: nil,
        message: "Sonny couldn't reach its server, so it can't do this right now. Check your internet connection and try again."
    )
}

public enum TaskPhase: Sendable, Equatable {
    case queued
    case connecting
    /// The gateway is thinking.
    case running
    case acting
    case observing
    case awaitingApproval(PreparedCommit)
    case awaitingAnswer(AskBody)
    case paused(PauseReason)
    case reconciling
    case completed(summary: String)
    case failed(TaskFailure)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// One action as the receipt shows it.
public struct ActionSummary: Sendable, Equatable {
    public var actionID: ActionID
    public var agent: ProposingAgent
    public var title: String
    public var effect: Effect
    public var status: OutcomeStatus?
    public var evidence: String?
}

public struct TaskSnapshot: Sendable, Equatable {
    public var id: TaskID
    public var goal: String
    public var origin: TaskOrigin
    public var isPrivate: Bool
    public var phase: TaskPhase
    public var progress: String?
    public var actions: [ActionSummary]
}

/// Looks at the screen for the gateway. Phase 4 supplies the real one.
public protocol TaskObserver: Sendable {
    func observe(_ request: ObserveBody, generation: Int) async -> ObservationBody
}

public struct UnavailableObserver: TaskObserver {
    public init() {}

    public func observe(_ request: ObserveBody, generation: Int) async -> ObservationBody {
        ObservationBody(
            generation: generation,
            error: .init(code: .unreadable, message: "Screen observation isn't available on this Mac yet.")
        )
    }
}

public struct RuntimeDependencies: Sendable {
    public var send: @Sendable (ClientMessage) async -> Bool
    public var ledgers: any TaskLedgerStoring
    public var capabilities: KernelCapabilities
    /// This task's screen control, or nil on a Mac that can't control apps.
    public var screen: (any ScreenControlling)?
    public var broker: ApprovalBroker
    /// Shared by every task: an operation that brings an app forward waits here for any screen
    /// action in flight, and screen actions wait for it.
    public var lease: ForegroundLease
    public var publish: @Sendable (TaskSnapshot) async -> Void
    public var now: @Sendable () -> Date

    public init(
        send: @escaping @Sendable (ClientMessage) async -> Bool,
        ledgers: any TaskLedgerStoring,
        capabilities: KernelCapabilities,
        screen: (any ScreenControlling)? = nil,
        broker: ApprovalBroker,
        lease: ForegroundLease = .shared,
        publish: @escaping @Sendable (TaskSnapshot) async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.send = send
        self.ledgers = ledgers
        self.capabilities = capabilities
        self.screen = screen
        self.broker = broker
        self.lease = lease
        self.publish = publish
        self.now = now
    }
}

/// One task on the Mac: the only place its actions are validated, gated, approved and run.
///
/// The ledger is written before every dispatch, so after a crash an action is either known to have
/// run, known not to have run, or honestly unknown — and an unknown consequential action pauses the
/// task instead of being replayed.
public actor TaskRuntime {
    public nonisolated let id: TaskID
    private var record: TaskLedgerRecord
    private let deps: RuntimeDependencies

    public private(set) var phase: TaskPhase
    private var progress: String?
    private var summaries: [ActionSummary] = []
    private var connectionGeneration: UInt64 = 0
    private var working: Task<Void, Never>?
    private var approval: (commit: PreparedCommit, reply: CheckedContinuation<Bool, Never>)?
    private var askSeq: Int?
    private var observationGeneration = 0
    /// A rebuilt outcome waiting for the user to resolve an unknown end, or for the next welcome.
    private var heldOutcome: (re: Int, results: [ActionResult])?
    /// A consequential action in the proposal now running ended unknown.
    private var unknownDuringRun: (action: ActionID, effect: Effect, title: String)?

    /// A new task.
    public init(id: TaskID, request: TaskStartBody, deps: RuntimeDependencies) {
        self.id = id
        self.record = TaskLedgerRecord(task: id, request: request, createdAt: deps.now())
        self.deps = deps
        self.phase = .queued
    }

    /// A task restored from its ledger after a relaunch.
    public init(restoring record: TaskLedgerRecord, deps: RuntimeDependencies) {
        self.id = record.task
        self.record = record
        self.deps = deps
        // A task that ended here is still ended; only its undelivered messages remain to send.
        self.phase = record.endedLocally == .cancelled ? .cancelled : .reconciling
    }

    // MARK: Driving the task

    /// Sends task.start on the connection whose generation is given. Call once it is up.
    public func start(generation: UInt64) async {
        guard phase == .queued || phase == .connecting else { return }
        connectionGeneration = generation
        phase = .running
        await sendNew(.taskStart(record.request), re: nil)
    }

    public func setConnecting() async {
        guard phase == .queued else { return }
        phase = .connecting
        await publish()
    }

    /// Connected, but every slot is taken: it waits its turn.
    public func setQueued() async {
        guard phase == .connecting else { return }
        phase = .queued
        await publish()
    }

    public func fail(_ failure: TaskFailure) async {
        guard !phase.isTerminal else { return }
        await end(.failed(failure))
    }

    /// Rebuilds what a relaunch interrupted. An action that was dispatched but never recorded as
    /// ended is outcome_unknown; one that never reached dispatch did not run.
    public func reconcile() async {
        guard phase == .reconciling, let pending = record.pending else { return }
        var results: [ActionResult] = []
        var unknownConsequential: LedgerAction?
        for actionID in pending.actions {
            guard var action = record.action(actionID) else { continue }
            let effect = action.judged ?? action.declared
            switch action.state {
            case .dispatched, .outcomeUnknown:
                action.state = .outcomeUnknown
                record.update(actionID) { $0.state = .outcomeUnknown }
                if effect > .navigate, unknownConsequential == nil { unknownConsequential = action }
                results.append(ActionResult(actionID: actionID, status: .outcomeUnknown, effect: effect))
            case .received, .prepared, .approved, .skipped:
                record.update(actionID) { $0.state = .skipped }
                results.append(ActionResult(actionID: actionID, status: .skipped, effect: effect))
            case .done, .failed, .refused, .declined, .stale:
                results.append(ActionResult(
                    actionID: actionID,
                    status: Self.status(of: action.state),
                    effect: effect,
                    evidence: action.evidence,
                    error: action.error
                ))
            }
        }
        // The proposal stays pending until its rebuilt outcome is sent, so a second crash rebuilds the
        // same answer instead of losing it.
        try? save()
        heldOutcome = (pending.seq, results)
        if let unknown = unknownConsequential {
            let title = unknown.title ?? "the last action"
            phase = .paused(.outcomeUnknown(action: unknown.actionID, effect: unknown.judged ?? unknown.declared, title: title))
        } else {
            phase = .running
        }
        await publish()
    }

    /// The connection is up and the gateway has said what it knows about this task.
    public func welcomed(_ state: WelcomeBody.TaskState?, generation: UInt64) async {
        // A task that already sent on this connection has nothing to send again.
        let alreadyHere = connectionGeneration == generation
        connectionGeneration = generation
        // Ended here, and over or gone on the gateway too: nothing left to deliver.
        if phase.isTerminal, state?.state == .finished || state?.state == .unknown {
            try? deps.ledgers.delete(id)
            return
        }
        if phase == .reconciling { await reconcile() }
        switch state?.state {
        case .unknown?:
            if record.lastSeqIn > 0 {
                // The gateway had this task and no longer does: it ended there, and a private task's
                // record is gone.
                await end(.failed(TaskFailure(reason: nil, message: "Sonny lost track of this task on its server.")))
                return
            }
        case .live?, .finished?:
            record.acknowledge(through: state!.lastSeqIn)
            if phase.isTerminal && record.outbox.isEmpty {
                try? deps.ledgers.delete(id)
                return
            }
            try? save()
        case nil:
            break
        }
        if !alreadyHere {
            for message in record.outbox { _ = await deps.send(message) }
        }
        if case .paused = phase { return }
        if let held = heldOutcome {
            heldOutcome = nil
            await sendNew(.outcome(OutcomeBody(results: held.results)), re: held.re, clearingPending: true)
        }
    }

    public func receive(_ message: ServerMessage, generation: UInt64) async {
        if phase.isTerminal {
            // A task that ended here may still be waiting for the gateway to hear its last message.
            if let re = message.address?.re, message.address?.task == id {
                record.acknowledge(through: re)
                if record.outbox.isEmpty { try? deps.ledgers.delete(id) } else { try? save() }
            }
            return
        }
        let verdict = ProposalValidator.check(
            message.address,
            task: id,
            messageGeneration: generation,
            currentGeneration: connectionGeneration,
            lastSeqIn: record.lastSeqIn,
            taskIsOver: phase.isTerminal
        )
        guard verdict == .accept, let address = message.address else { return }
        if case .propose = message.payload, working != nil { return }

        record.lastSeqIn = address.seq
        if let re = address.re { record.acknowledge(through: re) }
        try? save()

        switch message.payload {
        case .progress(let body):
            progress = body.message
            await publish()
        case .ask(let body):
            askSeq = address.seq
            phase = .awaitingAnswer(body)
            await publish()
        case .observe(let body):
            phase = .observing
            await publish()
            observationGeneration += 1
            let observer: any TaskObserver = deps.screen ?? UnavailableObserver()
            let observation = await observer.observe(body, generation: observationGeneration)
            guard !phase.isTerminal else { return }
            phase = .running
            await sendNew(.observation(observation), re: address.seq)
        case .propose(let body):
            phase = .acting
            await publish()
            working = Task { await self.run(body, re: address.seq) }
        case .finish(let body):
            await finish(body)
        case .welcome, .reauthRequired, .goodbye, .error:
            break
        }
    }

    public func cancel() async {
        guard !phase.isTerminal else { return }
        working?.cancel()
        approval?.reply.resume(returning: false)
        approval = nil
        await deps.broker.void(task: id)
        await sendNew(.taskCancel(TaskCancelBody(reason: .user)), re: nil)
        await end(.cancelled, keepLedgerUntilAcknowledged: true)
    }

    public func answer(_ text: String) async {
        guard case .awaitingAnswer = phase, let askSeq else { return }
        self.askSeq = nil
        phase = .running
        await sendNew(.answer(AnswerBody(text: text)), re: askSeq)
    }

    /// The user's decision on a confirm-level action. It counts only for the commit issued for this
    /// task and this action.
    public func decide(action: ActionID, commitID: UUID, approved: Bool) async {
        guard let pending = approval, pending.commit.action == action, pending.commit.commitID == commitID else {
            return
        }
        approval = nil
        if approved {
            await deps.broker.approve(task: id, action: action, commitID: commitID)
        }
        pending.reply.resume(returning: approved)
    }

    public func resolvePause(_ choice: PauseChoice) async {
        guard case .paused(let reason) = phase else { return }
        switch choice {
        case .stop:
            heldOutcome = nil
            await sendNew(.taskCancel(TaskCancelBody(reason: .outcomeUnknown)), re: nil)
            await end(.cancelled, keepLedgerUntilAcknowledged: true)
        case .continueTask:
            phase = .running
            guard let held = heldOutcome else { await publish(); return }
            heldOutcome = nil
            let results = held.results.map { result -> ActionResult in
                guard case .outcomeUnknown(let action, _, _) = reason, result.actionID == action else { return result }
                var checked = result
                checked.evidence = "The user checked and chose to continue."
                return checked
            }
            await sendNew(.outcome(OutcomeBody(results: results)), re: held.re, clearingPending: true)
        }
    }

    /// What hello tells the gateway about this task: nothing for a task the gateway has never
    /// heard from, or one that ended with nothing left to deliver.
    public func resumeEntry() -> HelloBody.ResumeEntry? {
        if record.lastSeqOut == 0 { return nil }
        return phase.isTerminal && record.outbox.isEmpty ? nil : record.resumeEntry
    }

    public func snapshot() -> TaskSnapshot {
        TaskSnapshot(
            id: id,
            goal: record.request.goal,
            origin: record.request.origin,
            isPrivate: record.request.isPrivate,
            phase: phase,
            progress: progress,
            actions: summaries
        )
    }

    // MARK: Running a proposal

    private func run(_ body: ProposeBody, re: Int) async {
        record.pending = PendingProposal(seq: re, agent: body.agent, final: body.final, actions: body.actions.map(\.actionID))
        for action in body.actions {
            record.actions.append(LedgerAction(actionID: action.actionID, state: .received, declared: action.effect))
        }
        try? save()

        var results: [ActionResult] = []
        var judgedSoFar: [Effect] = []
        var stopped = false
        for (index, action) in body.actions.enumerated() {
            if stopped || Task.isCancelled {
                results.append(skip(action))
                continue
            }
            let result = await runOne(action, index: index, agent: body.agent, judgedSoFar: &judgedSoFar)
            results.append(result)
            if result.status != .done { stopped = true }
        }
        working = nil
        guard !Task.isCancelled, !phase.isTerminal else { return }
        if let unknown = unknownDuringRun {
            // It may already have happened: the user checks before anything else is done.
            unknownDuringRun = nil
            heldOutcome = (re, results)
            phase = .paused(.outcomeUnknown(action: unknown.action, effect: unknown.effect, title: unknown.title))
            await publish()
            return
        }
        phase = .running
        await sendNew(.outcome(OutcomeBody(results: results)), re: re, clearingPending: true)
    }

    private func skip(_ action: WireAction) -> ActionResult {
        record.update(action.actionID) { $0.state = .skipped }
        return ActionResult(actionID: action.actionID, status: .skipped, effect: action.effect)
    }

    private func answered(_ action: WireAction, _ result: ActionResult, title: String, agent: ProposingAgent) -> ActionResult {
        record.update(action.actionID) {
            $0.state = Self.ledgerState(of: result.status)
            $0.title = title
            $0.judged = result.effect
            $0.evidence = result.evidence
            $0.error = result.error
        }
        try? save()
        summaries.append(ActionSummary(
            actionID: action.actionID,
            agent: agent,
            title: title,
            effect: result.effect,
            status: result.status,
            evidence: result.evidence
        ))
        return result
    }

    private func runOne(
        _ action: WireAction,
        index: Int,
        agent: ProposingAgent,
        judgedSoFar: inout [Effect]
    ) async -> ActionResult {
        let prepareAgain: @Sendable () async throws -> PreparedAction
        let run: @Sendable (PreparedAction) async -> CapabilityOutcome
        switch ProposalValidator.route(action, capabilities: deps.capabilities, screenTools: deps.screen?.tools ?? []) {
        case .answer(let result):
            return answered(action, result, title: Self.title(of: action), agent: agent)
        case .screen(let screenAction):
            guard let screen = deps.screen else {
                let result = ActionResult(
                    actionID: action.actionID,
                    status: .refused,
                    effect: action.effect,
                    error: OutcomeError(code: .unsupportedOperation, message: "This Mac can't control apps.")
                )
                return answered(action, result, title: Self.title(of: action), agent: agent)
            }
            let actionID = action.actionID
            prepareAgain = { try await screen.prepare(screenAction, actionID: actionID) }
            run = { await screen.execute($0) }
        case .operation(let capability, let args):
            let actionID = action.actionID
            prepareAgain = { try await capability.prepare(actionID: actionID, args: args) }
            if capability.bringsAppForward {
                let lease = deps.lease
                run = { prepared in await lease.hold { await capability.execute(prepared) } }
            } else {
                run = { await capability.execute($0) }
            }
        }

        var prepared: PreparedAction
        do {
            prepared = try await prepareAgain()
        } catch let error as CapabilityPrepareError {
            let (status, outcomeError) = error.result
            return answered(action, ActionResult(actionID: action.actionID, status: status, effect: action.effect, error: outcomeError), title: Self.title(of: action), agent: agent)
        } catch {
            return answered(action, ActionResult(actionID: action.actionID, status: .failed, effect: action.effect, error: OutcomeError(code: .executionError, message: "Sonny couldn't prepare this action.")), title: Self.title(of: action), agent: agent)
        }

        let judged = EffectRaiser.raise(declared: action.effect, floor: prepared.effect, facts: prepared.raiseFacts)
        let title = prepared.preview.title
        guard ProposalValidator.batchMayContinue(index: index, judged: judged, previousJudged: judgedSoFar) else {
            record.update(action.actionID) { $0.judged = judged }
            return answered(action, ActionResult(actionID: action.actionID, status: .skipped, effect: judged), title: title, agent: agent)
        }
        judgedSoFar.append(judged)
        record.update(action.actionID) {
            $0.state = .prepared
            $0.judged = judged
            $0.title = title
        }
        try? save()

        let context = GateContext(mode: record.request.mode, unattended: record.request.unattended, standing: prepared.standing)
        switch ActionGate.decide(judged, context: context) {
        case .refuse(let code):
            return answered(action, ActionResult(actionID: action.actionID, status: .refused, effect: judged, error: OutcomeError(code: code, message: Self.refusalMessage(code))), title: title, agent: agent)
        case .confirm:
            let commit = await deps.broker.issue(task: id, prepared: prepared, effect: judged)
            phase = .awaitingApproval(commit)
            await publish()
            let approved = await withCheckedContinuation { (reply: CheckedContinuation<Bool, Never>) in
                approval = (commit, reply)
            }
            if phase.isTerminal || Task.isCancelled {
                return answered(action, ActionResult(actionID: action.actionID, status: .skipped, effect: judged), title: title, agent: agent)
            }
            phase = .acting
            await publish()
            guard approved else {
                return answered(action, ActionResult(actionID: action.actionID, status: .declined, effect: judged), title: title, agent: agent)
            }
            // Revalidate the live target and content right before the commit: the approval covers
            // exactly what the user saw, and any change voids it.
            do {
                let reprepared = try await prepareAgain()
                try await deps.broker.consume(commitID: commit.commitID, task: id, action: action.actionID, reprepared: reprepared)
                prepared = reprepared
            } catch {
                return answered(action, ActionResult(actionID: action.actionID, status: .stale, effect: judged, error: OutcomeError(code: .staleReference, message: "What was approved changed before it could run, so it didn't run.")), title: title, agent: agent)
            }
        case .run:
            break
        }

        record.update(action.actionID) { $0.state = .approved }
        record.update(action.actionID) { $0.state = .dispatched }
        do {
            try save()
        } catch {
            // Without a record of the dispatch, a crash could replay this action. It doesn't run.
            return answered(action, ActionResult(actionID: action.actionID, status: .failed, effect: judged, error: OutcomeError(code: .executionError, message: "Sonny couldn't record this action safely, so it didn't run.")), title: title, agent: agent)
        }
        let outcome = await run(prepared)
        if outcome.status == .outcomeUnknown, judged > .navigate {
            unknownDuringRun = (action.actionID, judged, title)
        }
        return answered(
            action,
            ActionResult(actionID: action.actionID, status: outcome.status, effect: judged, evidence: outcome.evidence, error: outcome.error),
            title: title,
            agent: agent
        )
    }

    // MARK: Ending

    private func finish(_ body: FinishBody) async {
        working?.cancel()
        switch body.status {
        case .completed:
            let unresolved = record.actions.contains { $0.state == .outcomeUnknown }
            if unresolved {
                await end(.failed(TaskFailure(reason: nil, message: body.summary.isEmpty ? "Sonny couldn't confirm what happened." : body.summary)))
            } else {
                await end(.completed(summary: body.summary))
            }
        case .failed:
            await end(.failed(TaskFailure(reason: body.reason, message: body.summary)))
        case .cancelled:
            await end(.cancelled)
        }
    }

    private func end(_ terminal: TaskPhase, keepLedgerUntilAcknowledged: Bool = false) async {
        phase = terminal
        await deps.broker.void(task: id)
        await deps.screen?.taskEnded()
        if keepLedgerUntilAcknowledged && !record.outbox.isEmpty {
            if terminal == .cancelled { record.endedLocally = .cancelled }
            try? save()
        } else {
            try? deps.ledgers.delete(id)
        }
        await publish()
    }

    // MARK: Messages and records

    /// Numbers, records and sends one message. With `clearingPending`, the proposal it answers stops
    /// being pending in the same write that puts the answer in the outbox.
    private func sendNew(_ payload: ClientPayload, re: Int?, clearingPending: Bool = false) async {
        record.lastSeqOut += 1
        let message = ClientMessage(address: TaskAddress(task: id, seq: record.lastSeqOut, re: re), payload: payload)
        record.outbox.append(message)
        if clearingPending { record.pending = nil }
        try? save()
        await publish()
        _ = await deps.send(message)
    }

    private func save() throws {
        try deps.ledgers.save(record)
    }

    private func publish() async {
        await deps.publish(snapshot())
    }

    static func status(of state: LedgerState) -> OutcomeStatus {
        switch state {
        case .done: .done
        case .failed: .failed
        case .refused: .refused
        case .declined: .declined
        case .stale: .stale
        case .skipped, .received, .prepared, .approved: .skipped
        case .dispatched, .outcomeUnknown: .outcomeUnknown
        }
    }

    static func ledgerState(of status: OutcomeStatus) -> LedgerState {
        switch status {
        case .done: .done
        case .failed: .failed
        case .refused: .refused
        case .declined: .declined
        case .stale: .stale
        case .skipped: .skipped
        case .outcomeUnknown: .outcomeUnknown
        }
    }

    static func title(of action: WireAction) -> String {
        switch action.kind {
        case .operation(let call): call.name.replacingOccurrences(of: "_", with: " ")
        case .screen(let screen): screen.tool.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }

    static func refusalMessage(_ code: OutcomeErrorCode) -> String {
        switch code {
        case .secureField: "Sonny never types into a password field. Please do this part yourself."
        case .targetRefused: "Sonny doesn't act in this app."
        case .unattendedRefused: "This needs you at the Mac, so Sonny didn't do it on a schedule."
        default: "Sonny didn't do this."
        }
    }
}
