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

/// A capture whose redaction found a shell in the picture.
struct ShellInThePicture: WindowScreenshotting {
    func screenshot(bundleID: String) async throws -> ObservationBody.Screenshot {
        throw ScreenshotRefusal.shellOnScreen
    }
}

func screenController(
    _ fake: FakeCuaNotes,
    apps: FakeScreenApps = FakeScreenApps(),
    ownPID: pid_t = 1,
    manifests: Shared<[CuaCapabilityManifest]> = Shared([]),
    claims: ScreenAppClaims = ScreenAppClaims(),
    screenshots: any WindowScreenshotting = FakeScreenshots()
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
