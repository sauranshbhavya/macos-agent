import Foundation
import Testing
@testable import MacAgentCore
import MacAgentTestSupport

/// Mutable state a test capability and its test share.
final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A capability whose effect, content and timing a test controls.
struct TestCapability: Capability {
    let name: String
    let version = 1
    var floor: Effect = .navigate
    var content = Shared("content")
    var executed = Shared<[ActionID]>([])
    var started = Shared(false)
    /// While false, execute waits (and honours cancellation).
    var released = Shared(true)
    var raiseFacts: RaiseFacts = .none
    var bringsAppForward = false
    var onExecute: (@Sendable (ActionID) -> Void)?

    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        PreparedAction(
            actionID: actionID,
            effect: floor,
            targetIdentity: "\(name)-target",
            content: content.value,
            preview: ApprovalPreview(title: name, details: [content.value]),
            retry: .never,
            raiseFacts: raiseFacts,
            payload: ()
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        started.value = true
        onExecute?(prepared.actionID)
        while !released.value {
            if Task.isCancelled { return .failed(.cancelled, "stopped") }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if Task.isCancelled { return .failed(.cancelled, "stopped") }
        executed.value.append(prepared.actionID)
        return .done("\(name) ran")
    }
}

func call(_ name: String, _ id: ActionID = ActionID(), effect: Effect = .navigate, args: [String: JSONValue] = [:]) -> WireAction {
    WireAction(actionID: id, effect: effect, kind: .operation(OperationCall(name: name, version: 1, args: args)))
}

func propose(_ actions: [WireAction], final: Bool = false) -> ServerPayload {
    .propose(ProposeBody(agent: .planner, actions: actions, final: final))
}

func results(of message: ClientMessage) -> [ActionResult] {
    guard case .outcome(let body) = message.payload else { return [] }
    return body.results
}

@MainActor
func makeController(
    _ gateway: ScriptedGateway,
    ledgers: MemoryTaskLedgerStore = MemoryTaskLedgerStore(),
    capabilities: [any Capability],
    lease: ForegroundLease = ForegroundLease(),
    credentials: any GatewayCredentials = FixedGatewayCredentials()
) -> TaskController {
    TaskController(
        url: URL(string: "ws://gateway.test/v2/session")!,
        transport: gateway,
        credentials: credentials,
        identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
        ledgers: ledgers,
        capabilities: KernelCapabilities(capabilities),
        permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
        backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
        connectTimeout: 60,
        lease: lease
    )
}

@MainActor
func startedTask(_ controller: TaskController, _ request: TaskRequest) async throws -> TaskID {
    let submission = await controller.submit(request)
    guard case .started(let task) = submission else {
        throw KernelTestFailure("the task did not start: \(submission)")
    }
    return task
}

/// Credentials a test signs in and out.
final class SwitchableCredentials: GatewayCredentials, @unchecked Sendable {
    private let lock = NSLock()
    private var signed: Bool

    init(signedIn: Bool) {
        signed = signedIn
    }

    var signedIn: Bool {
        get { lock.withLock { signed } }
        set { lock.withLock { signed = newValue } }
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard signedIn else { throw SonnyBackendError.notSignedIn }
        return "test-token"
    }
}

struct KernelTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite(.serialized)
@MainActor
struct KernelTests {
    @Test
    func aScriptedGatewayOpensAnAppEndToEnd() async throws {
        let gateway = ScriptedGateway()
        let opened = Shared<[String]>([])
        let notes = InstalledApp(
            displayName: "Notes",
            bundleIdentifier: "com.apple.Notes",
            applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app")
        )
        let openApp = OpenAppCapability(resolver: FixedAppResolver([notes]), opener: { app in
            opened.value.append(app.bundleIdentifier)
        })
        let ledgers = MemoryTaskLedgerStore()
        let controller = makeController(gateway, ledgers: ledgers, capabilities: [openApp])
        await controller.launch()

        let task = try await startedTask(controller, TaskRequest(goal: "Open Notes", mode: .normal))
        let start = try await gateway.next("task.start")
        #expect(start.address == TaskAddress(task: task, seq: 1))

        let action = ActionID()
        await gateway.send(task, propose([call("open_app", action, args: ["app": .string("Notes")])], final: true), re: 1)
        let outcome = try await gateway.next("outcome")
        #expect(outcome.address?.re == 1)
        #expect(results(of: outcome) == [ActionResult(actionID: action, status: .done, effect: .navigate, evidence: "Notes is open.")])
        #expect(opened.value == ["com.apple.Notes"])

        await gateway.send(task, .finish(FinishBody(status: .completed, summary: "Opened Notes.")), re: outcome.address?.seq)
        #expect(await eventually { controller.snapshot(task)?.phase == .completed(summary: "Opened Notes.") })
        #expect(ledgers.record(task) == nil)
    }

    @Test
    func duplicateStaleCrossTaskAndLateProposalsAreDropped() async throws {
        let gateway = ScriptedGateway()
        let step = TestCapability(name: "step")
        let controller = makeController(gateway, capabilities: [step])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Step", mode: .normal))
        _ = try await gateway.next("task.start")

        let first = await gateway.send(task, propose([call("step")]), re: 1)
        _ = try await gateway.next("outcome")
        // The same message again: not newer than the last one accepted.
        await gateway.deliver(first)
        // A later message that arrives after a newer one.
        let third = await gateway.send(task, propose([call("step")]), seq: 3)
        _ = try await gateway.next("outcome")
        await gateway.send(task, propose([call("step")]), seq: 2)
        // Another task's proposal.
        await gateway.send(TaskID(), propose([call("step")]), seq: 4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(step.executed.value.count == 2)
        #expect(await gateway.unread("outcome").isEmpty)

        // A proposal for a task this Mac has cancelled never runs, even if the gateway's turn raced
        // the cancel.
        await controller.cancel(task)
        _ = try await gateway.next("task.cancel")
        await gateway.send(task, propose([call("step")]), seq: (third.address?.seq ?? 3) + 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(step.executed.value.count == 2)
    }

    @Test
    func cancelDuringDispatchStopsFurtherActions() async throws {
        let gateway = ScriptedGateway()
        let slow = TestCapability(name: "slow", released: Shared(false))
        let after = TestCapability(name: "after")
        let controller = makeController(gateway, capabilities: [slow, after])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Two steps", mode: .normal))
        _ = try await gateway.next("task.start")

        await gateway.send(task, propose([call("slow"), call("after")]), re: 1)
        #expect(await eventually { slow.started.value })
        await controller.cancel(task)

        let cancel = try await gateway.next("task.cancel")
        guard case .taskCancel(let body) = cancel.payload else { throw KernelTestFailure("not a cancel") }
        #expect(body.reason == .user)
        #expect(await eventually { controller.snapshot(task)?.phase == .cancelled })
        try await Task.sleep(for: .milliseconds(100))
        #expect(after.executed.value.isEmpty)
        #expect(slow.executed.value.isEmpty)
        #expect(await gateway.unread("outcome").isEmpty)
    }

    @Test
    func theLedgerRecordsADispatchBeforeTheActionRuns() async throws {
        let gateway = ScriptedGateway()
        let ledgers = MemoryTaskLedgerStore()
        let seenState = Shared<LedgerState?>(nil)
        let task = Shared<TaskID?>(nil)
        var step = TestCapability(name: "step")
        step.onExecute = { action in
            seenState.value = task.value.flatMap { ledgers.record($0)?.action(action)?.state }
        }
        let controller = makeController(gateway, ledgers: ledgers, capabilities: [step])
        await controller.launch()
        task.value = try await startedTask(controller, TaskRequest(goal: "Step", mode: .normal))
        _ = try await gateway.next("task.start")
        await gateway.send(task.value!, propose([call("step")]), re: 1)
        _ = try await gateway.next("outcome")
        #expect(seenState.value == .dispatched)
    }

    @Test
    func aConsequentialActionWithAnUnknownEndPausesAndIsNeverReplayed() async throws {
        let gateway = ScriptedGateway()
        let ledgers = MemoryTaskLedgerStore()
        let send = TestCapability(name: "send", floor: .external)
        let task = TaskID()
        let action = ActionID()
        // What a crash leaves behind: the action was dispatched and its end never written.
        var record = TaskLedgerRecord(
            task: task,
            request: TaskStartBody(goal: "Send it", origin: .composer, isPrivate: false, unattended: false, mode: .normal),
            createdAt: Date()
        )
        record.lastSeqIn = 1
        record.lastSeqOut = 1
        record.pending = PendingProposal(seq: 1, agent: .planner, final: false, actions: [action])
        var entry = LedgerAction(actionID: action, state: .dispatched, declared: .external)
        entry.judged = .external
        entry.title = "Send the message"
        record.actions = [entry]
        try ledgers.save(record)

        let controller = makeController(gateway, ledgers: ledgers, capabilities: [send])
        await controller.launch()
        let hello = try await gateway.next("hello")
        guard case .hello(let body) = hello.payload else { throw KernelTestFailure("not a hello") }
        #expect(body.resume.first?.ledger.first?.state == .dispatched)

        #expect(await eventually {
            controller.snapshot(task)?.phase == .paused(.outcomeUnknown(action: action, effect: .external, title: "Send the message"))
        })
        #expect(await gateway.unread("outcome").isEmpty)

        await controller.resolvePause(task: task, choice: .continueTask)
        let outcome = try await gateway.next("outcome")
        #expect(outcome.address?.re == 1)
        #expect(results(of: outcome) == [ActionResult(
            actionID: action,
            status: .outcomeUnknown,
            effect: .external,
            evidence: "The user checked and chose to continue."
        )])
        #expect(send.executed.value.isEmpty)
    }

    @Test
    func aRelaunchDuringADispatchPausesAndNeverRunsTheActionAgain() async throws {
        let ledgers = MemoryTaskLedgerStore()
        let first = ScriptedGateway()
        // The send never returns: the app dies while it is in flight.
        let send = TestCapability(name: "send", floor: .external, released: Shared(false))
        let before = makeController(first, ledgers: ledgers, capabilities: [send])
        await before.launch()
        let task = try await startedTask(before, TaskRequest(goal: "Send it", mode: .power))
        _ = try await first.next("task.start")
        let action = ActionID()
        await first.send(task, propose([call("send", action, effect: .external)]), re: 1)
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = before.snapshot(task)?.phase { commit = pending; return true }
            return false
        })
        await before.decide(task: task, action: action, commit: try #require(commit).commitID, approved: true)
        #expect(await eventually { send.started.value })
        await before.shutDown()

        // A new launch reads the same ledger.
        let second = ScriptedGateway()
        let after = makeController(second, ledgers: ledgers, capabilities: [send])
        await after.launch()
        #expect(await eventually {
            if case .paused(.outcomeUnknown(action, .external, _)) = after.snapshot(task)?.phase { return true }
            return false
        })
        #expect(await second.unread("outcome").isEmpty)
        send.released.value = true
        #expect(send.executed.value.count <= 1)
    }

    @Test
    func aNavigationWithAnUnknownEndIsReportedWithoutPausing() async throws {
        let gateway = ScriptedGateway()
        let ledgers = MemoryTaskLedgerStore()
        let task = TaskID()
        let action = ActionID()
        var record = TaskLedgerRecord(
            task: task,
            request: TaskStartBody(goal: "Look", origin: .composer, isPrivate: false, unattended: false, mode: .normal),
            createdAt: Date()
        )
        record.lastSeqIn = 1
        record.lastSeqOut = 1
        record.pending = PendingProposal(seq: 1, agent: .screen, final: false, actions: [action])
        record.actions = [LedgerAction(actionID: action, state: .dispatched, declared: .navigate)]
        try ledgers.save(record)

        let controller = makeController(gateway, ledgers: ledgers, capabilities: [])
        await controller.launch()
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.outcomeUnknown])
    }

    @Test
    func stoppingAtAnUnknownEndCancelsTheTask() async throws {
        let gateway = ScriptedGateway()
        let ledgers = MemoryTaskLedgerStore()
        let task = TaskID()
        let action = ActionID()
        var record = TaskLedgerRecord(
            task: task,
            request: TaskStartBody(goal: "Pay", origin: .composer, isPrivate: false, unattended: false, mode: .power),
            createdAt: Date()
        )
        record.lastSeqIn = 1
        record.lastSeqOut = 1
        record.pending = PendingProposal(seq: 1, agent: .planner, final: false, actions: [action])
        record.actions = [LedgerAction(actionID: action, state: .dispatched, declared: .financial)]
        try ledgers.save(record)

        let controller = makeController(gateway, ledgers: ledgers, capabilities: [])
        await controller.launch()
        #expect(await eventually {
            if case .paused = controller.snapshot(task)?.phase { return true }
            return false
        })
        await controller.resolvePause(task: task, choice: .stop)
        let cancel = try await gateway.next("task.cancel")
        guard case .taskCancel(let body) = cancel.payload else { throw KernelTestFailure("not a cancel") }
        #expect(body.reason == .outcomeUnknown)
        #expect(controller.snapshot(task)?.phase == .cancelled)
    }

    @Test
    func anApprovalBindsToItsTaskAndActionAndAChangedContentVoidsIt() async throws {
        let gateway = ScriptedGateway()
        let send = TestCapability(name: "send", floor: .external)
        let controller = makeController(gateway, capabilities: [send])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Send", mode: .power))
        _ = try await gateway.next("task.start")

        let action = ActionID()
        await gateway.send(task, propose([call("send", action, effect: .navigate)]), re: 1)
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = controller.snapshot(task)?.phase { commit = pending; return true }
            return false
        })
        let pending = try #require(commit)
        #expect(pending.effect == .external)

        // A yes for another action, or with another commit id, counts for nothing.
        await controller.decide(task: task, action: ActionID(), commit: pending.commitID, approved: true)
        await controller.decide(task: task, action: action, commit: UUID(), approved: true)
        #expect(controller.snapshot(task)?.phase == .awaitingApproval(pending))

        // The content changes between the approval and the dispatch.
        send.content.value = "something else"
        await controller.decide(task: task, action: action, commit: pending.commitID, approved: true)
        let voided = try await gateway.next("outcome")
        #expect(results(of: voided).map(\.status) == [.stale])
        #expect(send.executed.value.isEmpty)

        // The same action with its content unchanged runs once, after the yes.
        let second = ActionID()
        await gateway.send(task, propose([call("send", second, effect: .external)]), re: voided.address?.seq)
        var secondCommit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = controller.snapshot(task)?.phase { secondCommit = pending; return true }
            return false
        })
        await controller.decide(task: task, action: second, commit: try #require(secondCommit).commitID, approved: true)
        let ran = try await gateway.next("outcome")
        #expect(results(of: ran).map(\.status) == [.done])
        #expect(send.executed.value == [second])
    }

    @Test
    func aDeclinedActionDoesNotRun() async throws {
        let gateway = ScriptedGateway()
        let delete = TestCapability(name: "delete", floor: .destructive)
        let controller = makeController(gateway, capabilities: [delete])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Delete", mode: .normal))
        _ = try await gateway.next("task.start")
        let action = ActionID()
        await gateway.send(task, propose([call("delete", action, effect: .destructive)]), re: 1)
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = controller.snapshot(task)?.phase { commit = pending; return true }
            return false
        })
        await controller.decide(task: task, action: action, commit: try #require(commit).commitID, approved: false)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.declined])
        #expect(delete.executed.value.isEmpty)
    }

    @Test
    func anUnattendedTaskRefusesWhatWouldNeedConfirmation() async throws {
        let gateway = ScriptedGateway()
        let send = TestCapability(name: "send", floor: .external)
        let controller = makeController(gateway, capabilities: [send])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Send", origin: .schedule, unattended: true, mode: .power))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("send")]), re: 1)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.error?.code) == [.unattendedRefused])
        #expect(send.executed.value.isEmpty)
    }

    @Test
    func aBatchStopsBeforeAnActionThatDoesMoreThanNavigate() async throws {
        let gateway = ScriptedGateway()
        let look = TestCapability(name: "look")
        let make = TestCapability(name: "make", floor: .create)
        let controller = makeController(gateway, capabilities: [look, make])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Batch", mode: .power))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("look"), call("make", effect: .navigate), call("look")]), re: 1)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.done, .skipped, .skipped])
        #expect(make.executed.value.isEmpty)
    }

    @Test
    func anOperationThisMacLacksIsRefusedAndTheGatewayHearsWhy() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Mystery", mode: .normal))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("launch_rockets")]), re: 1)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.error?.code) == [.unsupportedOperation])
    }

    @Test
    func aTaskStoppedOfflineComesBackStoppedAfterARelaunchAndHoldsNoSlot() async throws {
        let ledgers = MemoryTaskLedgerStore()
        let before = ScriptedGateway()
        let first = makeController(before, ledgers: ledgers, capabilities: [])
        await first.launch()
        let stopped = try await startedTask(first, TaskRequest(goal: "Stop me", mode: .normal))
        _ = try await before.next("task.start")
        // Offline: the socket drops and every reconnect is refused, so the cancel can't go out.
        await before.refuseNext(1000, status: 503)
        await before.drop()
        await first.cancel(stopped)
        #expect(await eventually { first.snapshot(stopped)?.phase == .cancelled })
        #expect(ledgers.record(stopped)?.endedLocally == .cancelled)
        await first.shutDown()

        let after = ScriptedGateway()
        await after.setWelcomeState { _ in .finished }
        let second = makeController(after, ledgers: ledgers, capabilities: [])
        await second.launch()
        #expect(second.snapshot(stopped)?.phase == .cancelled)
        let next = try await startedTask(second, TaskRequest(goal: "Next", mode: .normal))
        let start = try await after.next("task.start")
        #expect(start.address?.task == next)
        #expect(await eventually { ledgers.record(stopped) == nil })
    }

    @Test
    func aRequestMadeWhileConnectingSendsItsStartOnce() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        // Not launched: this request is what opens the socket, so it is waiting when the welcome
        // arrives.
        let task = try await startedTask(controller, TaskRequest(goal: "Once", mode: .normal))
        let hello = try await gateway.next("hello")
        guard case .hello(let body) = hello.payload else { throw KernelTestFailure("not a hello") }
        #expect(body.resume.isEmpty)
        let start = try await gateway.next("task.start")
        #expect(start.address?.task == task)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await gateway.unread("task.start").isEmpty)
    }

    @Test
    func withNoGatewayAModelBackedTaskFailsAtOnceWithAServerError() async throws {
        let gateway = ScriptedGateway()
        await gateway.refuseNext(1000, status: 503)
        let controller = makeController(gateway, capabilities: [])
        let started = Date()
        let submission = await controller.submit(TaskRequest(goal: "Anything", mode: .normal))
        #expect(submission == .failed(submission.task, .serverUnavailable))
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(controller.snapshot(submission.task)?.phase == .failed(.serverUnavailable))
    }

    @Test
    func aReconnectResendsWhatTheGatewayNeverGot() async throws {
        let gateway = ScriptedGateway()
        let step = TestCapability(name: "step", released: Shared(false))
        let controller = makeController(gateway, capabilities: [step])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Step", mode: .normal))
        _ = try await gateway.next("task.start")
        await gateway.send(task, propose([call("step")]), re: 1)
        #expect(await eventually { step.started.value })

        // The socket drops while the action runs, so its outcome can't be sent until the Mac is back.
        await gateway.drop()
        step.released.value = true
        _ = try await gateway.next("hello")
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.done])
        #expect(outcome.address?.seq == 2)
        #expect(step.executed.value.count == 1)
    }
}

@Suite(.serialized)
@MainActor
struct GatewayConnectionTests {
    @Test
    func aReauthRequestIsAnsweredWithAFreshToken() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        _ = try await gateway.next("hello")
        await gateway.deliver(ServerMessage(payload: .reauthRequired(ReauthRequiredBody(expiresAtMs: 0))))
        let reauth = try await gateway.next("reauth")
        #expect(reauth.payload == .reauth(ReauthBody(accessToken: "test-token")))
    }

    @Test
    func aDrainingGatewayIsReconnectedToAfterItsPause() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        _ = try await gateway.next("hello")
        await gateway.deliver(ServerMessage(payload: .goodbye(GoodbyeBody(reason: .draining, reconnectAfterMs: 20))))
        await gateway.drop(code: 1012)
        _ = try await gateway.next("hello")
        #expect(await gateway.connections == 2)
    }

    @Test
    func aSignedOutSessionStopsAndDoesNotReconnect() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        _ = try await gateway.next("hello")
        await gateway.deliver(ServerMessage(payload: .goodbye(GoodbyeBody(reason: .signedOut))))
        await gateway.drop(code: 4403)
        #expect(await eventually { controller.gateway == .stopped(.signedOut) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gateway.connections == 1)
    }
}

@Suite
struct ActionGateTests {
    @Test(arguments: [
        (Effect.observe, AgentInteractionMode.safe, false, GateDecision.run),
        (.navigate, .normal, false, .run),
        (.editLocal, .safe, false, .confirm),
        (.editLocal, .normal, false, .run),
        (.create, .power, false, .run),
        (.destructive, .power, false, .confirm),
        (.external, .normal, false, .confirm),
        (.financial, .power, false, .confirm),
        (.unknown, .normal, false, .confirm),
        (.unknown, .power, true, .refuse(.unattendedRefused)),
        (.external, .normal, true, .refuse(.unattendedRefused)),
        (.editLocal, .normal, true, .run),
        (.editLocal, .safe, true, .run),
        (.create, .safe, true, .run),
        (.navigate, .safe, true, .run),
        (.destructive, .power, true, .refuse(.unattendedRefused)),
        (.credential, .power, false, .refuse(.secureField)),
    ])
    func theModeTableDecides(effect: Effect, mode: AgentInteractionMode, unattended: Bool, expected: GateDecision) {
        #expect(ActionGate.decide(effect, context: GateContext(mode: mode, unattended: unattended)) == expected)
    }

    @Test
    func standingAsksInSafeAndNormalAndNotInPowerAndARefusedAppIsNeverTouched() {
        #expect(ActionGate.decide(.editLocal, context: GateContext(mode: .normal, unattended: false, standing: .notAllowed)) == .confirm)
        #expect(ActionGate.decide(.editLocal, context: GateContext(mode: .power, unattended: false, standing: .notAllowed)) == .run)
        #expect(ActionGate.decide(.navigate, context: GateContext(mode: .normal, unattended: false, standing: .notAllowed)) == .run)
        #expect(ActionGate.decide(.observe, context: GateContext(mode: .power, unattended: false, standing: .refused)) == .refuse(.targetRefused))
    }

    @Test
    func localRulesOnlyRaise() {
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(keyChord: ["cmd", "return"], focusedTakesText: true)) == .external)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(keyChord: ["return", "cmd"], focusedTakesText: true)) == .external)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(keyChord: ["return"], focusedTakesText: false)) == .navigate)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(targetWords: ["Send Now"])) == .external)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(targetWords: ["File", "Unsubscribe"])) == .navigate)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(targetWords: ["Place Order"])) == .financial)
        #expect(EffectRaiser.raise(declared: .navigate, floor: .navigate, facts: RaiseFacts(targetWords: ["Move to Trash"])) == .destructive)
        #expect(EffectRaiser.raise(declared: .external, floor: .navigate, facts: RaiseFacts(targetWords: ["Delete"])) == .external)
        #expect(EffectRaiser.raise(declared: .editLocal, floor: .navigate, facts: RaiseFacts(targetIsSecure: true)) == .credential)
        #expect(EffectRaiser.raise(declared: .editLocal, floor: .navigate, facts: RaiseFacts(text: "my card is 4242 4242 4242 4242")) == .credential)
        #expect(EffectRaiser.raise(declared: .observe, floor: .editLocal, facts: .none) == .editLocal)
        #expect(EffectRaiser.raise(declared: .financial, floor: .navigate, facts: .none) == .financial)
    }
}

@Suite(.serialized)
@MainActor
struct InstantPathTests {
    @Test
    func anInstantCommandRunsWithoutTheGatewayAndEndsFromItsOwnOutcome() async throws {
        let gateway = ScriptedGateway()
        await gateway.refuseNext(1000, status: 503)
        let opened = Shared<[String]>([])
        let notes = InstalledApp(displayName: "Notes", bundleIdentifier: "com.apple.Notes", applicationURL: URL(fileURLWithPath: "/System/Applications/Notes.app"))
        let tasks = makeController(gateway, capabilities: [OpenAppCapability(resolver: FixedAppResolver([notes]), opener: { opened.value.append($0.bundleIdentifier) })])
        let actions = try #require(InstantPath.actions(for: AgentPlan(
            summary: "Open Notes",
            requiresConfirmation: false,
            steps: [AgentStep(id: "1", operation: .openApp, description: "open", appName: "Notes")]
        )))
        let submission = await tasks.submitLocal(TaskRequest(goal: "open notes", mode: .normal), actions: actions)
        #expect(await eventually { tasks.snapshot(submission.task)?.phase == .completed(summary: "Notes is open.") })
        #expect(opened.value == ["com.apple.Notes"])
        #expect(await gateway.connections == 0)
    }

    @Test
    func anInstantCommandStillAsksWhereTheGateSaysSo() async throws {
        let gateway = ScriptedGateway()
        let make = TestCapability(name: "make", floor: .create)
        let tasks = makeController(gateway, capabilities: [make])
        let submission = await tasks.submitLocal(
            TaskRequest(goal: "make it", mode: .safe),
            actions: [call("make", effect: .create)]
        )
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = tasks.snapshot(submission.task)?.phase { commit = pending; return true }
            return false
        })
        await tasks.decide(task: submission.task, action: try #require(commit).action, commit: try #require(commit).commitID, approved: true)
        #expect(await eventually {
            if case .completed = tasks.snapshot(submission.task)?.phase { return true }
            return false
        })
        #expect(make.executed.value.count == 1)
    }

    @Test
    func aMacLaunchedSignedOutConnectsOnceThePersonSignsIn() async throws {
        let gateway = ScriptedGateway()
        let credentials = SwitchableCredentials(signedIn: false)
        let controller = makeController(gateway, capabilities: [], credentials: credentials)
        await controller.launch()

        let signedOut = await controller.submit(TaskRequest(goal: "Open Notes", mode: .normal))
        guard case .failed(_, let failure) = signedOut else { throw KernelTestFailure("expected a failure: \(signedOut)") }
        #expect(failure == .signInNeeded)

        credentials.signedIn = true
        let task = try await startedTask(controller, TaskRequest(goal: "Open Notes", mode: .normal))
        let start = try await gateway.next("task.start")
        #expect(start.address?.task == task)
    }

    @Test
    func signingInConnectsWithoutWaitingForARequest() async throws {
        let gateway = ScriptedGateway()
        let credentials = SwitchableCredentials(signedIn: false)
        let controller = makeController(gateway, capabilities: [], credentials: credentials)
        await controller.launch()
        #expect(await eventually { controller.gateway == .stopped(.notSignedIn) })

        credentials.signedIn = true
        await controller.reconnect()
        _ = try await gateway.next("hello")
        #expect(await eventually { controller.gateway == .connected })
    }

    @Test
    func anotherAccountsTasksEndWithoutAWordToTheGatewayAndLeaveNothingBehind() async throws {
        let gateway = ScriptedGateway()
        let ledgers = MemoryTaskLedgerStore()
        let send = TestCapability(name: "send_it", floor: .external)
        let controller = makeController(gateway, ledgers: ledgers, capabilities: [send])
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Send the report", mode: .normal))
        _ = try await gateway.next("task.start")
        let action = ActionID()
        await gateway.send(task, propose([call("send_it", action, effect: .external)]), re: 1)
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = controller.snapshot(task)?.phase { commit = pending; return true }
            return false
        })

        // Signed out, or someone else signed in: the task is gone, here and on disk.
        await controller.discardUnfinishedTasks()
        #expect(controller.tasks.isEmpty)
        #expect(ledgers.record(task) == nil)

        // A late yes counts for nothing, and nothing more reaches the gateway.
        await controller.decide(task: task, action: action, commit: try #require(commit).commitID, approved: true)
        try await Task.sleep(for: .milliseconds(200))
        #expect(send.executed.value.isEmpty)
        #expect(await gateway.unread("outcome").isEmpty)
    }

    @Test
    func aVersionTheGatewayRefusedSaysToUpdate() async throws {
        let gateway = ScriptedGateway()
        await gateway.refuseNext(1, status: 410)
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()
        let refused = await controller.submit(TaskRequest(goal: "Open Notes", mode: .normal))
        guard case .failed(_, let failure) = refused else { throw KernelTestFailure("expected a failure: \(refused)") }
        #expect(failure == .clientTooOld)
    }

    @Test
    func threeTasksRunAtOnceAndAFourthWaitsForASlot() async throws {
        let gateway = ScriptedGateway()
        let controller = makeController(gateway, capabilities: [])
        await controller.launch()

        var running: [TaskID] = []
        for goal in ["one", "two", "three"] {
            running.append(try await startedTask(controller, TaskRequest(goal: goal, mode: .normal)))
            _ = try await gateway.next("task.start")
        }
        #expect(TaskController.defaultMaxLiveTasks == 3)

        let fourth = await controller.submit(TaskRequest(goal: "four", mode: .normal))
        guard case .queued(let waiting) = fourth else { throw KernelTestFailure("the fourth task did not wait: \(fourth)") }
        #expect(controller.snapshot(waiting)?.phase == .queued)

        await gateway.send(running[1], .finish(FinishBody(status: .completed, summary: "Done.")), re: 1)
        let start = try await gateway.next("task.start")
        #expect(start.address?.task == waiting)
        #expect(await eventually { controller.snapshot(waiting)?.phase == .running })
    }

    @Test
    func anOperationThatBringsAnAppForwardWaitsForTheForegroundLease() async throws {
        let gateway = ScriptedGateway()
        let lease = ForegroundLease()
        var open = TestCapability(name: "open_it")
        open.bringsAppForward = true
        let controller = makeController(gateway, capabilities: [open], lease: lease)
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Open it", mode: .normal))
        _ = try await gateway.next("task.start")

        // Another task's screen action is in the middle of its click.
        let clicking = Shared(true)
        let holder = Task { await lease.hold { while clicking.value { try? await Task.sleep(for: .milliseconds(5)) } } }
        try await Task.sleep(for: .milliseconds(50))

        await gateway.send(task, propose([call("open_it")], final: true), re: 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!open.started.value)

        clicking.value = false
        await holder.value
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.done])
    }

    @Test
    func anOperationThatDoesNotBringAnAppForwardRunsWhileTheLeaseIsHeld() async throws {
        let gateway = ScriptedGateway()
        let lease = ForegroundLease()
        let save = TestCapability(name: "save_it")
        let controller = makeController(gateway, capabilities: [save], lease: lease)
        await controller.launch()
        let task = try await startedTask(controller, TaskRequest(goal: "Save it", mode: .normal))
        _ = try await gateway.next("task.start")

        let clicking = Shared(true)
        let holder = Task { await lease.hold { while clicking.value { try? await Task.sleep(for: .milliseconds(5)) } } }
        try await Task.sleep(for: .milliseconds(50))

        await gateway.send(task, propose([call("save_it")], final: true), re: 1)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.done])
        clicking.value = false
        await holder.value
    }

    @Test
    func aPlanWithAStepThatHasNoV2FormGoesToTheGateway() {
        let plan = AgentPlan(summary: "x", requiresConfirmation: false, steps: [AgentStep(id: "1", operation: .rename, description: "w")])
        #expect(InstantPath.actions(for: plan) == nil)
    }
}
