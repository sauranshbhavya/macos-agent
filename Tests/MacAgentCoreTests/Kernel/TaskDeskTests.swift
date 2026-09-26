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
    let routines: RoutineGoalStore
    let history: FinishedTaskStore
    let watchers: ResumableTaskStore
    let page = FixedPage("before")
    let clock = Shared(Date())

    init(
        capabilities: [any Capability] = [],
        history: FinishedTaskStore = FinishedTaskStore(fileURL: nil),
        routines: RoutineGoalStore = RoutineGoalStore(fileURL: nil),
        installed: [InstalledApp] = [],
        instant: @escaping (String) -> [WireAction]? = { _ in nil }
    ) throws {
        self.history = history
        self.routines = routines
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("desk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watchers = ResumableTaskStore(fileURL: folder.appendingPathComponent("watchers.json"))
        controller = makeController(gateway, capabilities: capabilities)
        let clock = self.clock
        // The resolver the app reads saved routines through, with an installed-app list this test
        // states rather than this Mac's.
        let resolver = InstantCommandResolver(
            snippetStore: UnreachableLocalStores.snippets(),
            recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
            installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed))
        )
        desk = TaskDesk(
            controller: controller,
            history: history,
            routines: routines,
            watchers: watchers,
            pageReader: page,
            instant: instant,
            routineNamed: { resolver.routine(namedBy: $0, in: $1) },
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
        #expect(try await fixture.history.all().map(\.id) == [ordinary])
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

    // MARK: Running a saved routine by name

    /// The gateway never sees the routine list, so a request that names a saved routine the way V1
    /// recognised it runs that routine's goal as a new routine task, ahead of the instant path.
    @Test
    func aRequestThatNamesASavedRoutineRunsItsGoal() async throws {
        let step = TestCapability(name: "step")
        let fixture = try DeskFixture(capabilities: [step]) { _ in [call("step")] }
        await fixture.start()
        let goal = "Read today's calendar and unread mail and summarise them"
        try await fixture.routines.save(RoutineGoal(name: "Morning Briefing", goal: goal, schedule: nil, savedAt: Date()))

        for request in ["run morning briefing", "run routine Morning Briefing", "run my morning briefing routine", "Morning Briefing", "start the morning briefing"] {
            let submission = try #require(await fixture.desk.ask(request, origin: .voice))
            let (task, body) = try await fixture.startBody()
            #expect(task == submission.task, "\(request)")
            #expect(body.goal == goal, "\(request)")
            #expect(body.origin == .routine, "\(request)")
            #expect(!body.isPrivate && !body.unattended, "\(request)")
            await fixture.finish(task)
            #expect(await eventually { fixture.controller.snapshot(task)?.phase.isTerminal == true })
        }
        #expect(step.executed.value.isEmpty)

        _ = await fixture.desk.ask("run morning briefing", isPrivate: true)
        let (_, secret) = try await fixture.startBody()
        #expect(secret.origin == .routine)
        #expect(secret.isPrivate)
    }

    /// Matching is by exact saved name, so a request that only mentions a routine, names one that
    /// isn't saved, or follows up an earlier task goes to the gateway exactly as it was typed.
    @Test
    func aRequestThatNamesNoSavedRoutineGoesToTheGatewayAsTyped() async throws {
        let fixture = try DeskFixture()
        await fixture.start()
        try await fixture.routines.save(RoutineGoal(name: "Morning Briefing", goal: "Summarise my day", schedule: nil, savedAt: Date()))

        for request in ["Summarise my morning briefing email", "run evening briefing", "morning briefing please"] {
            _ = await fixture.desk.ask(request)
            let (task, body) = try await fixture.startBody()
            #expect(body.goal == request)
            #expect(body.origin == .composer)
            await fixture.finish(task)
            #expect(await eventually { fixture.controller.snapshot(task)?.phase.isTerminal == true })
        }

        let earlier = TaskID()
        _ = await fixture.desk.ask("run morning briefing", followingUp: earlier)
        let (_, followUp) = try await fixture.startBody()
        #expect(followUp.goal == "run morning briefing")
        #expect(followUp.origin == .followUp)
    }

    /// "run Slack" when Slack is both a saved routine and an installed app is the gateway's to read;
    /// naming the kind still runs the routine.
    @Test
    func aBareVerbStepsAsideWhenTheRoutineIsAlsoAnInstalledApp() async throws {
        let slack = InstalledApp(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", applicationURL: URL(fileURLWithPath: "/Applications/Slack.app"))
        let fixture = try DeskFixture(installed: [slack])
        await fixture.start()
        try await fixture.routines.save(RoutineGoal(name: "Slack", goal: "Post my standup in Slack", schedule: nil, savedAt: Date()))

        _ = await fixture.desk.ask("run Slack")
        let (bare, bareBody) = try await fixture.startBody()
        #expect(bareBody.goal == "run Slack")
        #expect(bareBody.origin == .composer)
        await fixture.finish(bare)
        #expect(await eventually { fixture.controller.snapshot(bare)?.phase.isTerminal == true })

        _ = await fixture.desk.ask("run routine Slack")
        let (_, named) = try await fixture.startBody()
        #expect(named.goal == "Post my standup in Slack")
        #expect(named.origin == .routine)
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
    func aRoutineWhoseRunCantBeRecordedDoesntRunAgainAtEveryCheck() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unmarkable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let routines = RoutineGoalStore(fileURL: folder.appendingPathComponent("routines.json"), encryption: keyedEncryption(0x42))
        let fixture = try DeskFixture(routines: routines)
        await fixture.start()
        let now = fixture.clock.value
        let time = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: now.addingTimeInterval(-3600))
        let timing = RoutineSchedule.newlyCreated(cadence: .daily, hour: time.hour!, minute: time.minute!, now: now.addingTimeInterval(-7200))
        try await routines.save(RoutineGoal(name: "Standup", goal: "Post my standup", schedule: nil, timing: timing, savedAt: now))

        // The file still reads, but nothing more can be written beside it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        await fixture.desk.runDueRoutines()
        await fixture.desk.runDueRoutines()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await fixture.gateway.unread("task.start").isEmpty)
        #expect(fixture.desk.notices.filter { $0.message.contains("\"Standup\" didn't run") }.count == 1)
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

    /// History and routines Sonny can't read show as unreadable, not as empty lists, and nothing
    /// the desk does afterwards saves over them.
    @Test
    func historyAndRoutinesThatCantBeReadAreShownAsSuchAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("desk-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let historyURL = folder.appendingPathComponent("history.json")
        let routinesURL = folder.appendingPathComponent("routines.json")
        let earlier = finishedTaskSnapshot("Book the dentist")
        let routine = RoutineGoal(name: "Morning", goal: "Open my calendar", schedule: nil, savedAt: Date())
        try await FinishedTaskStore(fileURL: historyURL, encryption: keyedEncryption(0x42)).record(earlier, finishedAt: Date())
        try await RoutineGoalStore(fileURL: routinesURL, encryption: keyedEncryption(0x42)).save(routine)
        let originals = try [Data(contentsOf: historyURL), Data(contentsOf: routinesURL)]

        let step = TestCapability(name: "step")
        let fixture = try DeskFixture(
            capabilities: [step],
            history: FinishedTaskStore(fileURL: historyURL, encryption: keyedEncryption(0x99)),
            routines: RoutineGoalStore(fileURL: routinesURL, encryption: keyedEncryption(0x99))
        ) { $0 == "open notes" ? [call("step")] : nil }

        // A task that ends tries to record itself, and finds the history unreadable.
        _ = await fixture.desk.ask("open notes")
        #expect(await eventually { fixture.desk.unreadable == [.history, .routines] })
        #expect(step.executed.value.count == 1)

        await fixture.desk.load()
        #expect(fixture.desk.unreadable == [.history, .routines])
        #expect(fixture.desk.history.isEmpty && fixture.desk.routines.isEmpty)
        #expect(fixture.desk.hasHistoryToDelete)

        let now = fixture.clock.value
        await fixture.desk.setTiming(.newlyCreated(cadence: .daily, hour: 9, minute: 0, now: now), for: routine)
        await fixture.desk.deleteRoutine(routine)
        await fixture.desk.deleteHistory(earlier.id)
        await fixture.desk.runDueRoutines()

        #expect(try [Data(contentsOf: historyURL), Data(contentsOf: routinesURL)] == originals)
        #expect(fixture.desk.unreadable == [.history, .routines])

        // Deleting all history is the person's own choice, so it does replace the file.
        await fixture.desk.deleteAllHistory()
        #expect(fixture.desk.unreadable == [.routines])
        #expect(try await FinishedTaskStore(fileURL: historyURL, encryption: keyedEncryption(0x99)).all().isEmpty)
    }

    @Test
    func theFirstV2LaunchRemovesV1DataOnceAndLeavesV2Alone() throws {
        let sonny = FileManager.default.temporaryDirectory.appendingPathComponent("sonny-\(UUID().uuidString)/Sonny")
        let v2 = sonny.appendingPathComponent("V2")
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        for old in ["task-history.json", "workspaces.json", "routines.json"] {
            FileManager.default.createFile(atPath: sonny.appendingPathComponent(old).path, contents: Data("v1".utf8))
        }
        FileManager.default.createFile(atPath: v2.appendingPathComponent("history.json").path, contents: Data("v2".utf8))

        #expect(KernelStores.removeV1Data(v2Folder: v2) == ["routines.json", "task-history.json", "workspaces.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sonny.path) == ["V2"])
        #expect(FileManager.default.fileExists(atPath: v2.appendingPathComponent("history.json").path))

        // Once only: a file that appears later is not V1's, and stays.
        FileManager.default.createFile(atPath: sonny.appendingPathComponent("later.json").path, contents: Data())
        #expect(KernelStores.removeV1Data(v2Folder: v2).isEmpty)
        #expect(FileManager.default.fileExists(atPath: sonny.appendingPathComponent("later.json").path))
    }

    @Test
    func v1DataThatCouldNotBeRemovedIsTriedAgainOnTheNextLaunch() throws {
        let sonny = FileManager.default.temporaryDirectory.appendingPathComponent("sonny-\(UUID().uuidString)/Sonny")
        let v2 = sonny.appendingPathComponent("V2")
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        for old in ["task-history.json", "routines.json"] {
            FileManager.default.createFile(atPath: sonny.appendingPathComponent(old).path, contents: Data("v1".utf8))
        }
        let busy = RefusingFileManager(refusing: "routines.json")

        #expect(KernelStores.removeV1Data(v2Folder: v2, fileManager: busy) == ["task-history.json"])
        #expect(FileManager.default.fileExists(atPath: sonny.appendingPathComponent("routines.json").path))

        busy.refusing = nil
        #expect(KernelStores.removeV1Data(v2Folder: v2, fileManager: busy) == ["routines.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sonny.path) == ["V2"])
        #expect(KernelStores.removeV1Data(v2Folder: v2, fileManager: busy).isEmpty)
    }
}

/// A file manager that can't remove one named item, the way a file in use or a permission error
/// would stop it.
private final class RefusingFileManager: FileManager, @unchecked Sendable {
    var refusing: String?

    init(refusing: String) {
        self.refusing = refusing
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.lastPathComponent == refusing {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}
