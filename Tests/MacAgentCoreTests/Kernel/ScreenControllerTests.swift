import Foundation
import Testing
@testable import MacAgentCore
import MacAgentTestSupport

/// Apps as the screen controller finds them, with Notes running as the fake's process.
struct FakeScreenApps: ScreenApps {
    var running = true
    var activates = true

    func resolve(_ nameOrBundleID: String) async -> ScreenApp? {
        switch nameOrBundleID.lowercased() {
        case "notes", "com.apple.notes": ScreenApp(bundleID: "com.apple.Notes", name: "Notes", pid: running ? 4242 : nil)
        case "mail", "com.apple.mail": ScreenApp(bundleID: "com.apple.mail", name: "Mail", pid: 5151)
        case "terminal", "com.apple.terminal": ScreenApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 6161)
        default: nil
        }
    }

    func activate(pid: pid_t) async -> Bool { activates }
}

struct FakeScreenshots: WindowScreenshotting {
    func screenshot(bundleID: String) async throws -> ObservationBody.Screenshot {
        ObservationBody.Screenshot(mediaType: .jpeg, data: "AAAA", width: 960, height: 540)
    }
}

/// Whether someone is at the Mac, as a test says.
struct FixedAttention: SessionAttentionMonitoring {
    var state: SessionAttention = .attended
    func attention() async -> SessionAttention { state }
}

/// Attention a test changes mid-run.
final class ChangingAttention: SessionAttentionMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var current: SessionAttention = .attended
    var state: SessionAttention {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    func attention() async -> SessionAttention { state }
}

/// Apps with a front one a test can see and move, as the person switching would.
final class TrackingScreenApps: ScreenApps, @unchecked Sendable {
    private let lock = NSLock()
    private var front: pid_t

    init(front: pid_t) {
        self.front = front
    }

    var frontmost: pid_t {
        get { lock.withLock { front } }
        set { lock.withLock { front = newValue } }
    }

    func resolve(_ nameOrBundleID: String) async -> ScreenApp? {
        await FakeScreenApps().resolve(nameOrBundleID)
    }

    func activate(pid: pid_t) async -> Bool {
        frontmost = pid
        return true
    }

    func frontmostPID() async -> pid_t? { frontmost }
}

/// A capture whose redaction found a shell in the picture.
struct ShellInThePicture: WindowScreenshotting {
    func screenshot(bundleID: String) async throws -> ObservationBody.Screenshot {
        throw ScreenshotRefusal.shellOnScreen
    }
}

func screenController(
    _ fake: FakeCuaNotes,
    apps: any ScreenApps = FakeScreenApps(),
    ownPID: pid_t = 1,
    manifests: Shared<[CuaCapabilityManifest]> = Shared([]),
    claims: ScreenAppClaims = ScreenAppClaims(),
    screenshots: any WindowScreenshotting = FakeScreenshots(),
    attention: any SessionAttentionMonitoring = FixedAttention(),
    focusReturn: FocusReturn = FocusReturn()
) -> ScreenController {
    ScreenController(dependencies: .init(
        driver: { manifest in
            manifests.value.append(manifest)
            return fake
        },
        apps: apps,
        screenshots: screenshots,
        lease: ForegroundLease(),
        claims: claims,
        attention: attention,
        focusReturn: focusReturn,
        ownPID: ownPID
    ))
}

func look(_ controller: ScreenController, generation: Int, screenshot: Bool = false) async -> ObservationBody {
    await controller.observe(ObserveBody(app: "Notes", ax: true, screenshot: screenshot), generation: generation)
}

func ref(_ observation: ObservationBody, where match: (AXNode) -> Bool) throws -> ElementRef {
    guard let node = observation.ax?.nodes.first(where: match) else {
        throw KernelTestFailure("no node in the look matches")
    }
    return ElementRef(ref: node.ref, generation: observation.generation)
}

@Suite
struct ScreenControllerTests {
    @Test
    func aLookReadsTheLargestWindowWithAManifestForThatAppAlone() async throws {
        let fake = FakeCuaNotes()
        let manifests = Shared<[CuaCapabilityManifest]>([])
        let controller = screenController(fake, manifests: manifests)
        let observation = await look(controller, generation: 1)
        #expect(observation.error == nil)
        #expect(observation.window?.id == FakeCuaNotes.mainWindow)
        #expect(await fake.windowsRead == [FakeCuaNotes.mainWindow])
        #expect(manifests.value.map(\.bundleIdentifiers) == [["com.apple.Notes"]])
        #expect(observation.ax?.nodes.contains { $0.label == "New Note" && $0.role == "AXButton" } == true)
        let toolbarButton = try #require(observation.ax?.nodes.first { $0.label == "Delete" })
        #expect(toolbarButton.depth == 2)
    }

    @Test
    func aWindowThatReadsEmptyIsTriedAgainThenReportedUnreadable() async {
        var state = FakeCuaNotesState()
        state.degradedReadings = 1
        #expect(await look(screenController(FakeCuaNotes(state: state)), generation: 1).error == nil)
        state.degradedReadings = 2
        #expect(await look(screenController(FakeCuaNotes(state: state)), generation: 1).error?.code == .unreadable)
    }

    @Test
    func itSaysWhyItCouldNotLook() async {
        #expect(await look(screenController(FakeCuaNotes(), apps: FakeScreenApps(running: false)), generation: 1).error?.code == .appNotRunning)
        #expect(await look(screenController(FakeCuaNotes(), apps: FakeScreenApps(activates: false)), generation: 1).error?.code == .foregroundUnavailable)
        var state = FakeCuaNotesState()
        state.accessibilityGranted = false
        #expect(await look(screenController(FakeCuaNotes(state: state)), generation: 1).error?.code == .permissionDenied)
    }

    @Test
    func aSecretOnScreenNeverLeavesTheMac() async {
        var state = FakeCuaNotesState()
        state.notes = ["card 4242 4242 4242 4242 for groceries"]
        let observation = await look(screenController(FakeCuaNotes(state: state)), generation: 1)
        let body = observation.ax?.nodes.first { $0.role == "AXTextArea" }
        #expect(body?.value?.contains("4242 4242 4242 4242") == false)
        #expect(body?.value?.contains("groceries") == true)
    }

    @Test
    func aSecureFieldsValueIsNeverReadOutAndTypingIntoItIsACredentialEffect() throws {
        let state = CuaWindowState(snapshotID: "s1", windowID: 1, elements: [
            CuaElement(index: 0, role: "AXWindow", label: "Sign in"),
            CuaElement(index: 1, role: "AXSecureTextField", label: "Password", value: "hunter2", parentIndex: 0),
            CuaElement(index: 2, role: "AXTextField", label: "Password", value: "also-hidden", parentIndex: 0),
        ])
        let built = ScreenController.tree(from: state, maxNodes: 100)
        #expect(built.secureRefs == ["e1", "e2"])
        #expect(built.tree.nodes.filter { $0.secure == true }.map(\.value) == [nil, nil])
        let typed = EffectRaiser.raise(declared: .editLocal, floor: .editLocal, facts: RaiseFacts(text: "hunter2", targetIsSecure: true))
        #expect(ActionGate.decide(typed, context: GateContext(mode: .power, unattended: false)) == .refuse(.secureField))
    }

    @Test
    func pressingAnOfferedElementClicksItAndKeepsCuasReportAsEvidence() async throws {
        let fake = FakeCuaNotes()
        let controller = screenController(fake)
        let observation = await look(controller, generation: 1)
        let newNote = try ref(observation) { $0.label == "New Note" && $0.role == "AXButton" }
        let prepared = try await controller.prepare(.press(app: "com.apple.Notes", element: newNote), actionID: ActionID())
        #expect(prepared.standing == .allowed)
        #expect(prepared.effect == .navigate)
        let outcome = await controller.execute(prepared)
        #expect(outcome == .done("cua reported confirmed"))
        #expect(await fake.state.clicked == ["New Note"])
    }

    @Test
    func aRefFromAnEarlierLookOrNotOfferedIsRefusedAsStale() async throws {
        let fake = FakeCuaNotes()
        let controller = screenController(fake)
        let first = await look(controller, generation: 1)
        let newNote = try ref(first) { $0.label == "New Note" }
        _ = await look(controller, generation: 2)
        await #expect(throws: CapabilityPrepareError.self) {
            try await controller.prepare(.press(app: "Notes", element: newNote), actionID: ActionID())
        }
        await #expect(throws: CapabilityPrepareError.self) {
            try await controller.prepare(.press(app: "Notes", element: ElementRef(ref: "e9999", generation: 2)), actionID: ActionID())
        }
    }

    @Test
    func aWindowThatChangedAfterTheLookEndsTheActionStale() async throws {
        let fake = FakeCuaNotes()
        let controller = screenController(fake)
        let observation = await look(controller, generation: 1)
        let prepared = try await controller.prepare(
            .press(app: "Notes", element: try ref(observation) { $0.label == "New Note" }),
            actionID: ActionID()
        )
        await fake.redraw()
        #expect(await controller.execute(prepared).status == .stale)
        #expect(await fake.state.clicked.isEmpty)
    }

    @Test
    func anEmptyFieldThatCantBeSetIsTypedIntoInstead() async throws {
        var state = FakeCuaNotesState()
        state.notes.append("")
        state.editorTakesValue = false
        let fake = FakeCuaNotes(state: state)
        let controller = screenController(fake)
        let observation = await look(controller, generation: 1)
        let body = try ref(observation) { $0.role == "AXTextArea" }
        let prepared = try await controller.prepare(.setValue(app: "Notes", element: body, value: "buy milk"), actionID: ActionID())
        #expect(prepared.effect == .editLocal)
        #expect(await controller.execute(prepared).status == .done)
        #expect(await fake.state.notes.last == "buy milk")
    }

    @Test
    func aMenuRunsInTheLookedAtAppAndNeverInSonnysOwn() async throws {
        let fake = FakeCuaNotes()
        let controller = screenController(fake)
        _ = await look(controller, generation: 1)
        let prepared = try await controller.prepare(.menu(app: "Notes", path: ["File", "New Note"]), actionID: ActionID())
        #expect(await controller.execute(prepared).status == .done)
        #expect(await fake.state.menus == [["File", "New Note"]])

        let sonnyItself = screenController(FakeCuaNotes(), ownPID: 4242)
        _ = await look(sonnyItself, generation: 1)
        await #expect(throws: CapabilityPrepareError.targetRefused("Sonny doesn't use its own menus.")) {
            try await sonnyItself.prepare(.menu(app: "Notes", path: ["File", "Close"]), actionID: ActionID())
        }
    }

    @Test
    func anActionAimedAtAnotherAppIsRefused() async throws {
        let controller = screenController(FakeCuaNotes())
        _ = await look(controller, generation: 1)
        await #expect(throws: CapabilityPrepareError.self) {
            try await controller.prepare(.key(app: "Mail", keys: ["cmd", "n"]), actionID: ActionID())
        }
    }

    @Test
    func returnInAWindowWithATextFieldIsRaisedToExternal() async throws {
        let controller = screenController(FakeCuaNotes())
        _ = await look(controller, generation: 1)
        let prepared = try await controller.prepare(.key(app: "Notes", keys: ["return"]), actionID: ActionID())
        #expect(EffectRaiser.raise(declared: .navigate, floor: prepared.effect, facts: prepared.raiseFacts) == .external)
        let chord = try await controller.prepare(.key(app: "Notes", keys: ["cmd", "n"]), actionID: ActionID())
        #expect(EffectRaiser.raise(declared: .create, floor: chord.effect, facts: chord.raiseFacts) == .create)
    }

    @Test
    func anAppIsWorkedInByOneTaskAtATimeUntilThatTaskEndsOrMovesOn() async throws {
        let claims = ScreenAppClaims()
        let first = screenController(FakeCuaNotes(), claims: claims)
        let second = screenController(FakeCuaNotes(), claims: claims)
        #expect(await look(first, generation: 1).error == nil)

        let refused = await look(second, generation: 1)
        #expect(refused.error?.code == .foregroundUnavailable)
        #expect(refused.error?.message == "Another Sonny task is working in Notes. Try again when it has finished.")

        await first.taskEnded()
        #expect(await look(second, generation: 1).error == nil)

        // The second task moves on to Mail, and Notes is free again.
        _ = await second.observe(ObserveBody(app: "Mail", ax: true, screenshot: false), generation: 2)
        #expect(await look(first, generation: 2).error == nil)
    }

    @Test
    func aTerminalIsRefusedBeforeAnythingOfItIsRead() async throws {
        let manifests = Shared<[CuaCapabilityManifest]>([])
        let controller = screenController(FakeCuaNotes(), manifests: manifests)
        let observation = await controller.observe(ObserveBody(app: "Terminal", ax: true, screenshot: true), generation: 1)
        #expect(observation.error?.code == .appRefused)
        #expect(observation.ax == nil && observation.screenshot == nil)
        // No driver session was even made for it.
        #expect(manifests.value.isEmpty)
    }

    @Test
    func aShellShowingInAnAllowedAppIsRefusedAndEarlierLooksCantBeActedOn() async throws {
        let fake = FakeCuaNotes()
        let claims = ScreenAppClaims()
        let controller = screenController(fake, claims: claims)
        let clean = await look(controller, generation: 1)
        let newNote = try ref(clean) { $0.label == "New Note" }

        // A shell's prompt and a command's output now show in the window.
        await fake.update { $0.notes[$0.notes.count - 1] = "sauransh@Mac macos-agent % ls\nREADME.md  Sources  Tests  docs\nsauransh@Mac macos-agent %" }
        let refused = await look(controller, generation: 2)
        #expect(refused.error?.code == .appRefused)
        #expect(refused.error?.message == "A shell is showing in Notes, and Sonny doesn't work in shells.")
        #expect(refused.ax == nil)

        await #expect(throws: CapabilityPrepareError.self) {
            _ = try await controller.prepare(.press(app: "Notes", element: newNote), actionID: ActionID())
        }
        // The refused task doesn't keep Notes from another.
        #expect(await look(screenController(FakeCuaNotes(), claims: claims), generation: 1).error == nil)
    }

    @Test
    func aScreenshotShowingAShellIsNotSent() async throws {
        let controller = screenController(FakeCuaNotes(), screenshots: ShellInThePicture())
        let observation = await look(controller, generation: 1, screenshot: true)
        #expect(observation.error?.code == .appRefused)
        #expect(observation.screenshot == nil && observation.ax == nil)
    }

    @Test
    func nobodyAtTheMacStopsScreenWork() async throws {
        let locked = await look(screenController(FakeCuaNotes(), attention: FixedAttention(state: .screenLocked)), generation: 1)
        #expect(locked.error?.code == .foregroundUnavailable)
        #expect(locked.error?.message == "Sonny stopped working in apps because your Mac is locked.")
        #expect(locked.ax == nil)

        // Someone was there for the look, then went away before the click.
        let fake = FakeCuaNotes()
        let attention = ChangingAttention()
        let controller = screenController(fake, attention: attention)
        let observation = await look(controller, generation: 1)
        let prepared = try await controller.prepare(.press(app: "Notes", element: try ref(observation) { $0.label == "New Note" }), actionID: ActionID())
        attention.state = .userIdle
        let outcome = await controller.execute(prepared)
        #expect(outcome.status == .failed)
        #expect(outcome.error?.message == "Sonny stopped working in apps because nobody has used this Mac for a few minutes.")
        #expect(await fake.state.clicked.isEmpty)
    }

    @Test
    func thePersonsAppComesBackWhenTheScreenWorkEnds() async throws {
        // Mail (5151) is in front; the task works in Notes (4242).
        let apps = TrackingScreenApps(front: 5151)
        let controller = screenController(FakeCuaNotes(), apps: apps)
        _ = await look(controller, generation: 1)
        #expect(apps.frontmost == 4242)
        await controller.taskEnded()
        #expect(apps.frontmost == 5151)

        // Someone who has already moved on to another app is left there.
        let moved = TrackingScreenApps(front: 5151)
        let other = screenController(FakeCuaNotes(), apps: moved)
        _ = await look(other, generation: 1)
        moved.frontmost = 9999
        await other.taskEnded()
        #expect(moved.frontmost == 9999)
    }

    @Test
    func twoTasksWorkingAtOnceGiveBackThePersonsAppNotEachOthers() async throws {
        // Mail (5151) is in front. Task A brings Notes (4242) forward, then task B looks at Notes
        // too, with Notes already in front: B must not take Notes for the person's app.
        let apps = TrackingScreenApps(front: 5151)
        let shared = FocusReturn()
        let first = screenController(FakeCuaNotes(), apps: apps, claims: ScreenAppClaims(), focusReturn: shared)
        let second = screenController(FakeCuaNotes(), apps: apps, claims: ScreenAppClaims(), focusReturn: shared)
        _ = await look(first, generation: 1)
        _ = await look(second, generation: 1)
        #expect(apps.frontmost == 4242)

        // The first to finish leaves the other's work in front; the last gives Mail back.
        await first.taskEnded()
        #expect(apps.frontmost == 4242)
        await second.taskEnded()
        #expect(apps.frontmost == 5151)
    }

    @Test
    func theMonitorReadsLockedThenAsleepThenIdle() async {
        func monitor(locked: Bool = false, asleep: Bool = false, idle: TimeInterval = 0) -> SystemSessionAttentionMonitor {
            SystemSessionAttentionMonitor(environment: .init(isScreenLocked: { locked }, isDisplayAsleep: { asleep }, secondsSinceLastInput: { idle }))
        }
        #expect(await monitor().attention() == .attended)
        #expect(await monitor(idle: 179).attention() == .attended)
        #expect(await monitor(idle: 180).attention() == .userIdle)
        #expect(await monitor(asleep: true, idle: 500).attention() == .displayAsleep)
        #expect(await monitor(locked: true, asleep: true).attention() == .screenLocked)
        // A session dictionary that can't be read counts as locked.
        #expect(SystemSessionAttentionMonitor.isScreenLocked(sessionDictionary: nil))
        #expect(!SystemSessionAttentionMonitor.isScreenLocked(sessionDictionary: ["CGSSessionScreenIsLocked": 0]))
    }

    @Test
    func aPointInTheScreenshotClicksTheElementUnderIt() async throws {
        let fake = FakeCuaNotes()
        let controller = screenController(fake)
        let observation = await look(controller, generation: 1, screenshot: true)
        #expect(observation.screenshot?.width == 960)
        // New Note sits at 300…332 × 10…42 in a 1920×1080 window; the screenshot is half size.
        let prepared = try await controller.prepare(.clickPoint(app: "Notes", x: 158, y: 13, generation: 1, count: nil), actionID: ActionID())
        #expect(await controller.execute(prepared).status == .done)
        #expect(await fake.state.clicked == ["New Note"])
    }
}

@Suite(.serialized)
@MainActor
struct ScreenKernelTests {
    func controller(_ gateway: ScriptedGateway, fake: FakeCuaNotes, claims: ScreenAppClaims = ScreenAppClaims()) -> TaskController {
        TaskController(
            url: URL(string: "ws://gateway.test/v2/session")!,
            transport: gateway,
            credentials: FixedGatewayCredentials(),
            identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
            ledgers: MemoryTaskLedgerStore(),
            capabilities: KernelCapabilities([]),
            screenTools: Set(ScreenToolName.allCases),
            screenFactory: { screenController(fake, claims: claims) },
            permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
            backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
            connectTimeout: 60
        )
    }

    func observed(_ gateway: ScriptedGateway, _ task: TaskID, re: Int) async throws -> ClientMessage {
        await gateway.send(task, .observe(ObserveBody(app: "Notes", ax: true, screenshot: false)), re: re)
        return try await gateway.next("observation")
    }

    @Test
    func aNewNoteInNotesThroughTheKernel() async throws {
        let gateway = ScriptedGateway()
        let fake = FakeCuaNotes()
        let tasks = controller(gateway, fake: fake)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "New note", mode: .normal))
        _ = try await gateway.next("task.start")

        let first = try await observed(gateway, task, re: 1)
        guard case .observation(let look) = first.payload else { throw KernelTestFailure("not an observation") }
        #expect(look.generation == 1)

        let newNote = ActionID()
        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: newNote, effect: .create, kind: .screen(.key(app: "com.apple.Notes", keys: ["cmd", "n"]))),
        ], final: false)), re: first.address?.seq)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome) == [ActionResult(actionID: newNote, status: .done, effect: .create, evidence: "cua reported confirmed")])
        #expect(await fake.state.shortcuts == [["cmd", "n"]])
    }

    @Test
    func returnInATextFieldAsksFirstAndASecureFieldIsNeverTypedInto() async throws {
        let gateway = ScriptedGateway()
        let fake = FakeCuaNotes()
        let tasks = controller(gateway, fake: fake)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Send", mode: .power))
        _ = try await gateway.next("task.start")
        let first = try await observed(gateway, task, re: 1)

        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: ActionID(), effect: .navigate, kind: .screen(.key(app: "Notes", keys: ["return"]))),
        ], final: false)), re: first.address?.seq)
        #expect(await eventually {
            if case .awaitingApproval(let commit) = tasks.snapshot(task)?.phase { return commit.effect == .external }
            return false
        })
        #expect(await fake.state.keysPressed.isEmpty)
    }

    @Test
    func aSecondTaskIsToldTheAppIsBusyUntilTheFirstTaskEnds() async throws {
        let gateway = ScriptedGateway()
        let tasks = controller(gateway, fake: FakeCuaNotes(), claims: ScreenAppClaims())
        await tasks.launch()
        let first = try await startedTask(tasks, TaskRequest(goal: "Tidy a note", mode: .normal))
        _ = try await gateway.next("task.start")
        let second = try await startedTask(tasks, TaskRequest(goal: "Start a note", mode: .normal))
        _ = try await gateway.next("task.start")

        func observation(_ message: ClientMessage) throws -> ObservationBody {
            guard case .observation(let body) = message.payload else { throw KernelTestFailure("not an observation") }
            return body
        }
        #expect(try observation(await observed(gateway, first, re: 1)).error == nil)
        #expect(try observation(await observed(gateway, second, re: 1)).error?.code == .foregroundUnavailable)

        await gateway.send(first, .finish(FinishBody(status: .completed, summary: "Tidied.")), re: 2)
        #expect(await eventually { tasks.snapshot(first)?.phase.isTerminal == true })
        #expect(try observation(await observed(gateway, second, re: 2)).error == nil)
    }
}
