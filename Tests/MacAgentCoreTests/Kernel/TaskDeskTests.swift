import Foundation
import Testing
@testable import MacAgentCore
import MacAgentTestSupport

/// A watched page whose text a test sets.
final class FixedPage: StandingWatcherObserving, @unchecked Sendable {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    func readableText(at url: URL) async throws -> String { text }
}

@MainActor
private struct DeskFixture {
    let gateway = ScriptedGateway()
    let controller: TaskController
    let desk: TaskDesk
    let routines = RoutineGoalStore(fileURL: nil)
    let history = FinishedTaskStore(fileURL: nil)
    let watchers: ResumableTaskStore
    let page = FixedPage("before")
    let clock = Shared(Date())

    init(capabilities: [any Capability] = [], instant: @escaping (String) -> [WireAction]? = { _ in nil }) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watchers = ResumableTaskStore(fileURL: folder.appendingPathComponent("watchers.json"))
        controller = makeController(gateway, capabilities: capabilities)
        let clock = self.clock
        desk = TaskDesk(
            controller: controller,
            history: history,
            routines: routines,
            watchers: watchers,
            pageReader: page,
            instant: instant,
            mode: { .normal },
            now: { clock.value }
        )
    }

    func start() async {
        await controller.launch()
        await desk.load()
    }

    func startBody(within timeout: TimeInterval = 120) async throws -> (TaskID, TaskStartBody) {
        let message = try await gateway.next("task.start", timeout: timeout)
        guard case .taskStart(let body) = message.payload, let task = message.address?.task else {
            throw KernelTestFailure("not a task.start")
        }
        return (task, body)
    }

    func finish(_ task: TaskID, _ status: FinishBody.Status = .completed, _ summary: String = "Done.") async {
        await gateway.send(task, .finish(FinishBody(status: status, summary: summary)))
    }
}

/// Every entry point makes the same kind of request and goes through the controller (V2 plan
/// section 6, "Entry points"; phase 6's done-when list).
@Suite(.serialized)
@MainActor
struct TaskDeskTests {
    @Test
    func theComposerSendsWhatTheMacCantDoAloneToTheGateway() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        let submission = try #require(await fixture.desk.ask("  Summarise my unread mail  "))
        let (task, body) = try await fixture.startBody()
        #expect(task == submission.task)
        #expect(body.goal == "Summarise my unread mail")
        #expect(body.origin == .composer)
        #expect(!body.isPrivate && !body.unattended)
        #expect(body.priorTask == nil)
    }

    @Test
    func aCommandTheMacRecognisesRunsWithNoGateway() async throws {
        let step = TestCapability(name: "step")
        let fixture = try DeskFixture(capabilities: [step]) { $0 == "open notes" ? [call("step")] : nil }
        let submission = try #require(await fixture.desk.ask("open notes"))
        #expect(await eventually { fixture.controller.snapshot(submission.task)?.phase.isTerminal == true })
        #expect(step.executed.value.count == 1)
        #expect(await fixture.gateway.connections == 0)
        #expect(await eventually { fixture.desk.history.map(\.id) == [submission.task] })
    }

    @Test
    func voiceIsAComposerRequestWithItsOwnOrigin() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        _ = await fixture.desk.ask("What's on my calendar", origin: .voice)
        let (_, body) = try await fixture.startBody()
        #expect(body.origin == .voice)
    }

    @Test
    func aFollowUpNamesItsEarlierTaskAndSkipsTheInstantPath() async throws {
        let step = TestCapability(name: "step")
        let fixture = try DeskFixture(capabilities: [step]) { _ in [call("step")] }
        await fixture.start()
        let earlier = TaskID()
        _ = await fixture.desk.ask("open notes", followingUp: earlier)
        let (_, body) = try await fixture.startBody()
        #expect(body.origin == .followUp)
        #expect(body.priorTask == earlier)
        #expect(step.executed.value.isEmpty)
    }

    @Test
    func aFinishedTaskIsKeptButAPrivateOneLeavesNoHistory() async throws {
        let fixture = try DeskFixture()
        await fixture.start()

        _ = await fixture.desk.ask("Private errand", isPrivate: true)
        let (secret, secretBody) = try await fixture.startBody()
        #expect(secretBody.isPrivate)
        await fixture.finish(secret)
        #expect(await eventually { fixture.controller.snapshot(secret)?.phase.isTerminal == true })

        _ = await fixture.desk.ask("Ordinary errand")
        let (ordinary, _) = try await fixture.startBody()
        #expect(ordinary != secret)
        await fixture.finish(ordinary, .completed, "Did the errand.")

        #expect(await eventually { fixture.desk.history.map(\.id) == [ordinary] })
        #expect(await fixture.history.all().map(\.id) == [ordinary])
        #expect(fixture.desk.history.first?.summary == "Did the errand.")
    }

    @Test
    func aRoutineRunStartsANewModelBackedTaskFromItsSavedGoal() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        let routine = RoutineGoal(name: "Morning", goal: "Open my calendar and summarise today", schedule: nil, savedAt: Date())
        try await fixture.routines.save(routine)
        await fixture.desk.load()

        let submission = await fixture.desk.run(fixture.desk.routines[0])
        let (task, body) = try await fixture.startBody()
        #expect(task == submission.task)
        #expect(body.goal == "Open my calendar and summarise today")
        #expect(body.origin == .routine)
        #expect(!body.unattended)
    }

    @Test
    func aScheduledRunIsUnattendedRefusesWhatNeedsAYesAndSaysSo() async throws {
        let send = TestCapability(name: "send_it", floor: .external)
        let fixture = try DeskFixture(capabilities: [send])
        await fixture.start()
        let now = fixture.clock.value
        let time = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now.addingTimeInterval(-3600))
        let timing = RoutineSchedule.newlyCreated(cadence: .daily, hour: time.hour!, minute: time.minute!, now: now.addingTimeInterval(-7200))
        try await fixture.routines.save(RoutineGoal(name: "Weekly report", goal: "Send the weekly report", schedule: nil, timing: timing, savedAt: now))

        await fixture.desk.runDueRoutines()
        let (task, body) = try await fixture.startBody()
        #expect(body.origin == .schedule)
        #expect(body.unattended)
        #expect(body.goal == "Send the weekly report")

        // The same occurrence never runs twice.
        await fixture.desk.runDueRoutines()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.gateway.unread("task.start").isEmpty)

        await fixture.gateway.send(task, propose([call("send_it", effect: .external)]), re: 1)
        let outcome = try await fixture.gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.refused])
        #expect(results(of: outcome).map(\.error?.code) == [.unattendedRefused])
        #expect(send.executed.value.isEmpty)

        await fixture.gateway.send(task, .finish(FinishBody(status: .failed, summary: "It needed you.")), re: outcome.address?.seq)
        #expect(await eventually { fixture.desk.notices.contains { $0.task == task } })
        let notice = try #require(fixture.desk.notices.first { $0.task == task })
        #expect(notice.kind == .unattendedRun)
        #expect(notice.message.contains("\"Weekly report\" stopped where it needed you"))
    }

    @Test
    func twoScheduleChecksAtOnceStartEachOccurrenceOnce() async throws {
        let fixture = try DeskFixture()
        // Not launched: the first start opens the socket, which is when a second check could read
        // a list the first one hasn't finished marking.
        let now = fixture.clock.value
        let time = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now.addingTimeInterval(-3600))
        for name in ["Standup", "Timesheet"] {
            let timing = RoutineSchedule.newlyCreated(cadence: .daily, hour: time.hour!, minute: time.minute!, now: now.addingTimeInterval(-7200))
            try await fixture.routines.save(RoutineGoal(name: name, goal: "Do the \(name)", schedule: nil, timing: timing, savedAt: now))
        }

        async let first: Void = fixture.desk.runDueRoutines()
        async let second: Void = fixture.desk.runDueRoutines()
        _ = await (first, second)
        // One task runs at a time, so each start is finished to let the next one through; a
        // duplicate would show up as a third.
        var goals: [String] = []
        while let (task, body) = try? await fixture.startBody(within: 2) {
            goals.append(body.goal)
            await fixture.finish(task)
        }
        #expect(goals.sorted() == ["Do the Standup", "Do the Timesheet"])
    }

    @Test
    func aScheduleWhoseTimePassedLongAgoIsReportedNotRun() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        let now = fixture.clock.value
        let time = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now.addingTimeInterval(-5 * 3600))
        let timing = RoutineSchedule.newlyCreated(cadence: .daily, hour: time.hour!, minute: time.minute!, now: now.addingTimeInterval(-6 * 3600))
        try await fixture.routines.save(RoutineGoal(name: "Tidy", goal: "Tidy my desktop", schedule: nil, timing: timing, savedAt: now))

        await fixture.desk.runDueRoutines()
        #expect(fixture.desk.notices.map(\.kind) == [.missedSchedule])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.gateway.unread("task.start").isEmpty)
    }

    @Test
    func aWatcherWhosePageChangedStartsAnUnattendedTask() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        try fixture.watchers.saveWatcher(StandingWatcher(
            subject: "the ticket price",
            url: URL(string: "https://example.com/tickets")!,
            createdAt: fixture.clock.value,
            baselineDigest: StandingWatcherEvaluator.digest(of: "before")
        ))
        fixture.page.text = "after"
        await fixture.desk.checkWatchers()
        #expect(fixture.desk.watchers.count == 1)

        // A difference counts once it is read twice in a row.
        fixture.clock.value = fixture.clock.value.addingTimeInterval(StandingWatcherLimits.standard.checkInterval + 1)
        await fixture.desk.checkWatchers()
        let (_, body) = try await fixture.startBody()
        #expect(body.origin == .watcher)
        #expect(body.unattended)
        #expect(body.goal.contains("the ticket price"))
        #expect(body.goal.contains("https://example.com/tickets"))
        #expect(fixture.desk.watchers.isEmpty)
    }

    @Test
    func withTheGatewayDownAModelBackedRequestFailsAtOnceWithAServerError() async throws {
        let fixture = try DeskFixture()
        await fixture.gateway.refuseNext(1000, status: 503)
        let started = Date()
        let submission = try #require(await fixture.desk.ask("Book a table"))
        #expect(submission == .failed(submission.task, .serverUnavailable))
        #expect(Date().timeIntervalSince(started) < 30)
        #expect(fixture.controller.snapshot(submission.task)?.phase == .failed(.serverUnavailable))
    }

    @Test
    func anEmptyRequestStartsNothing() async throws {
        let fixture = try DeskFixture()
        #expect(await fixture.desk.ask("   \n") == nil)
        #expect(fixture.controller.tasks.isEmpty)
    }
}
