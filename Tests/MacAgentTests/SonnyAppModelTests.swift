import Foundation
import Testing
@testable import MacAgent
import MacAgentCore
import MacAgentTestSupport

/// A capability whose runs a test counts.
private final class CountingCapability: Capability, @unchecked Sendable {
    let name: String
    let version = 1
    let floor: Effect
    private let lock = NSLock()
    private var ran = 0

    init(name: String, floor: Effect) {
        self.name = name
        self.floor = floor
    }

    var runs: Int { lock.withLock { ran } }

    func prepare(actionID: ActionID, args: [String: JSONValue]) async throws -> PreparedAction {
        PreparedAction(
            actionID: actionID,
            effect: floor,
            targetIdentity: "\(name)-target",
            content: name,
            preview: ApprovalPreview(title: "Send the report", details: ["To: team@example.com"]),
            retry: .never,
            payload: ()
        )
    }

    func execute(_ prepared: PreparedAction) async -> CapabilityOutcome {
        lock.withLock { ran += 1 }
        return .done("\(name) ran")
    }
}

@MainActor
private struct AppFixture {
    let gateway = ScriptedGateway()
    let model: SonnyAppModel
    let send = CountingCapability(name: "send_it", floor: .external)

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)")
        let stores = KernelStores(folder: folder)
        let controller = TaskController(
            url: URL(string: "ws://gateway.test/v2/session")!,
            transport: gateway,
            credentials: FixedGatewayCredentials(),
            identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
            ledgers: MemoryTaskLedgerStore(),
            capabilities: KernelCapabilities([send]),
            permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
            backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
            connectTimeout: 60
        )
        let desk = TaskDesk(
            controller: controller,
            history: stores.history,
            routines: stores.routines,
            watchers: stores.watchers,
            instant: { _ in nil },
            mode: { .normal }
        )
        let defaults = try #require(UserDefaults(suiteName: "SonnyAppModelTests-\(UUID().uuidString)"))
        model = SonnyAppModel(desk: desk, stores: stores, client: makeHermeticBackendClient(), defaults: defaults)
    }

    func start() async throws -> (TaskID, TaskStartBody) {
        let message = try await gateway.next("task.start")
        guard case .taskStart(let body) = message.payload, let task = message.address?.task else {
            throw AppModelTestFailure()
        }
        return (task, body)
    }
}

private struct AppModelTestFailure: Error {}

/// The app model is presentation over `TaskDesk`: what the composer sends, how the private toggle
/// behaves, and that approvals answer the task they belong to.
@Suite(.serialized)
@MainActor
struct SonnyAppModelTests {
    @Test
    func theComposerSendsItsTextAndTheWidgetFollowsThatTask() async throws {
        let fixture = try AppFixture()
        fixture.model.composerText = "Book a table for two"
        fixture.model.submitComposer()
        #expect(fixture.model.composerText.isEmpty)
        let (task, body) = try await fixture.start()
        #expect(body.goal == "Book a table for two")
        #expect(body.origin == .composer)
        #expect(await eventually { fixture.model.widgetTask?.id == task })
    }

    @Test
    func thePrivateToggleHoldsForTheWholeTaskAndResetsWhenItEnds() async throws {
        let fixture = try AppFixture()
        fixture.model.togglePrivate()
        fixture.model.composerText = "Look up my test results"
        fixture.model.submitComposer()
        let (task, body) = try await fixture.start()
        #expect(body.isPrivate)
        #expect(await eventually { fixture.model.followedTask == task })
        #expect(fixture.model.isPrivate)

        await fixture.gateway.send(task, .finish(FinishBody(status: .completed, summary: "Found them.")))
        #expect(await eventually { !fixture.model.isPrivate })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.model.desk.history.isEmpty)
    }

    @Test
    func aSecondRequestStartsWhileTheFirstIsStillRunning() async throws {
        let fixture = try AppFixture()
        fixture.model.composerText = "Summarise my inbox"
        fixture.model.submitComposer()
        let (first, _) = try await fixture.start()
        #expect(await eventually { fixture.model.followedTask == first })

        fixture.model.composerText = "Book a table for two"
        #expect(fixture.model.canSubmit)
        fixture.model.submitComposer()
        let (second, body) = try await fixture.start()
        #expect(body.goal == "Book a table for two")
        #expect(await eventually { fixture.model.followedTask == second })
        #expect(fixture.model.controller.snapshot(first)?.phase.isTerminal == false)
    }

    @Test
    func turningThePrivateToggleOnByHandSurvivesAnEarlierPrivateTaskEnding() async throws {
        let fixture = try AppFixture()
        fixture.model.togglePrivate()
        fixture.model.composerText = "Look up my test results"
        fixture.model.submitComposer()
        let (task, _) = try await fixture.start()
        #expect(await eventually { fixture.model.followedTask == task })

        // Off, then on again by hand for the next request, while the private task still runs.
        fixture.model.togglePrivate()
        fixture.model.togglePrivate()
        #expect(fixture.model.isPrivate)

        await fixture.gateway.send(task, .finish(FinishBody(status: .completed, summary: "Found them.")))
        #expect(await eventually { fixture.model.controller.snapshot(task)?.phase.isTerminal == true })
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.model.isPrivate)
    }

    @Test
    func aFollowUpIsUsedByTheNextRequestAndOnlyThatOne() async throws {
        let fixture = try AppFixture()
        let earlier = TaskID()
        fixture.model.followUp(on: earlier, goal: "Draft the invite")
        fixture.model.composerText = "Now send it to Sam"
        fixture.model.submitComposer()
        let (_, body) = try await fixture.start()
        #expect(body.origin == .followUp)
        #expect(body.priorTask == earlier)
        #expect(fixture.model.followUp == nil)
    }

    @Test
    func anApprovalShownInTheWidgetAnswersItsOwnTask() async throws {
        let fixture = try AppFixture()
        fixture.model.composerText = "Send the weekly report"
        fixture.model.submitComposer()
        let (task, _) = try await fixture.start()
        let action = ActionID()
        await fixture.gateway.send(
            task,
            .propose(ProposeBody(agent: .planner, actions: [
                WireAction(actionID: action, effect: .external, kind: .operation(OperationCall(name: "send_it", version: 1, args: [:]))),
            ], final: false)),
            re: 1
        )
        var commit: PreparedCommit?
        #expect(await eventually {
            if case .awaitingApproval(let pending) = fixture.model.widgetTask?.phase { commit = pending; return true }
            return false
        })
        let pending = try #require(commit)
        #expect(pending.task == task && pending.action == action)
        #expect(pending.preview.title == "Send the report")
        #expect(fixture.send.runs == 0)

        fixture.model.decide(pending, approved: true)
        let outcome = try await fixture.gateway.next("outcome")
        guard case .outcome(let result) = outcome.payload else { throw AppModelTestFailure() }
        #expect(result.results.map(\.status) == [.done])
        #expect(fixture.send.runs == 1)
    }

    @Test
    func stoppingEverythingCancelsTheLiveTask() async throws {
        let fixture = try AppFixture()
        fixture.model.composerText = "Tidy my downloads"
        fixture.model.submitComposer()
        let (task, _) = try await fixture.start()
        #expect(await eventually { fixture.model.isTaskRunning })
        fixture.model.stopEverything()
        _ = try await fixture.gateway.next("task.cancel")
        #expect(await eventually { fixture.model.controller.snapshot(task)?.phase == .cancelled })
    }
}
