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

/// cua's Notes, except that it refuses every click with a reason longer than the contract carries.
struct LongWindedCua: CuaToolInvoking {
    let notes: FakeCuaNotes

    func invoke(_ tool: String, arguments: Data) async throws -> Data {
        guard tool == "click" else { return try await notes.invoke(tool, arguments: arguments) }
        return try JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": overByOneUnit(1000)]], "isError": true,
        ])
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
    focusReturn: FocusReturn = FocusReturn(),
    invoker: (any CuaToolInvoking)? = nil
) -> ScreenController {
    ScreenController(dependencies: .init(
        driver: { manifest in
            manifests.value.append(manifest)
            return invoker ?? fake
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

/// The effect the kernel gates a prepared screen action as.
func judged(_ prepared: PreparedAction, declared: Effect) -> Effect {
    EffectRaiser.raise(declared: declared, floor: prepared.effect, facts: prepared.raiseFacts)
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
    func returnOrEnterAnywhereInAChordIsRaisedToExternal() async throws {
        let controller = screenController(FakeCuaNotes())
        _ = await look(controller, generation: 1)
        for keys in [["return", "cmd"], ["enter"], ["cmd", "enter"], ["enter", "shift"]] {
            let prepared = try await controller.prepare(.key(app: "Notes", keys: keys), actionID: ActionID())
            #expect(judged(prepared, declared: .navigate) == .external, "\(keys)")
        }
    }

    @Test
    func returnIsRaisedEvenWhenTheLookSentNoTextFieldOrNoTreeAtAll() async throws {
        // A screenshot-only look and a tree cut to its first node: the window still has fields. And
        // a window cua read nothing of, seen in a screenshot: one may be focused.
        var unread = FakeCuaNotesState()
        unread.degradedReadings = 2
        let looks = [
            (FakeCuaNotesState(), ObserveBody(app: "Notes", ax: false, screenshot: true)),
            (FakeCuaNotesState(), ObserveBody(app: "Notes", ax: true, screenshot: false, maxNodes: 1)),
            (unread, ObserveBody(app: "Notes", ax: true, screenshot: true)),
        ]
        for (state, request) in looks {
            let controller = screenController(FakeCuaNotes(state: state))
            #expect(await controller.observe(request, generation: 1).error == nil)
            let prepared = try await controller.prepare(.key(app: "Notes", keys: ["return"]), actionID: ActionID())
            #expect(judged(prepared, declared: .navigate) == .external, "\(request)")
        }
    }

    @Test
    func aLineBreakAnywhereInTypedTextIsRaisedToExternal() async throws {
        let controller = screenController(FakeCuaNotes())
        let observation = await look(controller, generation: 1)
        let body = try ref(observation) { $0.role == "AXTextArea" }
        // A chat app sends "Late" on the first break; "\r\n" is one Character, so it has no "\n" suffix.
        for text in ["hi\n", "hi\r\n", "hi\r", "Late\nsee you", "Late\rsee you", "Late\u{2028}see you", "Late\u{2029}see you"] {
            for element in [nil, body] {
                let prepared = try await controller.prepare(.typeText(app: "Notes", text: text, element: element), actionID: ActionID())
                #expect(judged(prepared, declared: .editLocal) == .external, "\(text.debugDescription) at \(element?.ref ?? "focus")")
            }
        }
        let plain = try await controller.prepare(.typeText(app: "Notes", text: "see you soon", element: nil), actionID: ActionID())
        #expect(judged(plain, declared: .editLocal) == .editLocal)
    }

    @Test
    func aLineBreakIsNeverTypedThroughTheSetValueFallbackAndCountsAsReturnInAOneLineField() async throws {
        // An empty note body that can't be set: typing the value would press Return at the break.
        var state = FakeCuaNotesState()
        state.notes.append("")
        state.editorTakesValue = false
        let fake = FakeCuaNotes(state: state)
        let controller = screenController(fake)
        let observation = await look(controller, generation: 1)
        let body = try ref(observation) { $0.role == "AXTextArea" }
        let list = try await controller.prepare(.setValue(app: "Notes", element: body, value: "milk\neggs"), actionID: ActionID())
        #expect(judged(list, declared: .editLocal) == .editLocal)
        #expect(await controller.execute(list).status == .failed)
        #expect(await fake.state.notes.last == "")

        // A note body that takes its whole value gets the lines set, with no key pressed.
        let settable = FakeCuaNotes()
        let other = screenController(settable)
        let open = try ref(await look(other, generation: 1)) { $0.role == "AXTextArea" }
        let set = try await other.prepare(.setValue(app: "Notes", element: open, value: "milk\neggs"), actionID: ActionID())
        #expect(judged(set, declared: .editLocal) == .editLocal)
        #expect(await other.execute(set).status == .done)
        #expect(await settable.state.notes.last == "milk\neggs")

        // A one-line field has no use for a line break except to submit.
        let search = try ref(observation) { $0.role == "AXTextField" && $0.label == nil }
        let query = try await controller.prepare(.setValue(app: "Notes", element: search, value: "cats\n"), actionID: ActionID())
        #expect(judged(query, declared: .editLocal) == .external)
    }

    @Test
    func typingAtTheFocusWhileAPasswordFieldShowsIsACredentialEffect() async throws {
        var state = FakeCuaNotesState()
        state.noteLocked = true
        let password = "Sunflower1987"
        #expect(SecretTextDetector().matches(in: password).isEmpty)
        // A full look, and one whose tree stops before the password field: cua doesn't say what has
        // the focus, so any password field in the window counts.
        for request in [ObserveBody(app: "Notes", ax: true, screenshot: false), ObserveBody(app: "Notes", ax: true, screenshot: false, maxNodes: 3)] {
            let controller = screenController(FakeCuaNotes(state: state))
            #expect(await controller.observe(request, generation: 1).error == nil)
            let typed = try await controller.prepare(.typeText(app: "Notes", text: password, element: nil), actionID: ActionID())
            #expect(judged(typed, declared: .editLocal) == .credential)
            // Typed one key at a time, it is the same.
            for keys in [["s"], ["shift", "s"], ["1"]] {
                let key = try await controller.prepare(.key(app: "Notes", keys: keys), actionID: ActionID())
                #expect(judged(key, declared: .navigate) == .credential, "\(keys)")
            }
            // Keys that type nothing stay as they were.
            let tab = try await controller.prepare(.key(app: "Notes", keys: ["tab"]), actionID: ActionID())
            #expect(judged(tab, declared: .navigate) == .navigate)
            let newNote = try await controller.prepare(.key(app: "Notes", keys: ["cmd", "n"]), actionID: ActionID())
            #expect(judged(newNote, declared: .create) == .create)
        }

        // With no password field in the window, typing at the focus is an ordinary edit.
        let unlocked = screenController(FakeCuaNotes())
        _ = await look(unlocked, generation: 1)
        let typed = try await unlocked.prepare(.typeText(app: "Notes", text: password, element: nil), actionID: ActionID())
        #expect(judged(typed, declared: .editLocal) == .editLocal)
        let key = try await unlocked.prepare(.key(app: "Notes", keys: ["s"]), actionID: ActionID())
        #expect(judged(key, declared: .navigate) == .navigate)
    }

    @Test
    func whileAPasswordFieldShowsOnlyChordsThatCantChangeTextArePressed() async throws {
        var state = FakeCuaNotesState()
        state.noteLocked = true
        let controller = screenController(FakeCuaNotes(state: state))
        _ = await look(controller, generation: 1)
        func effect(_ keys: [String], declared: Effect = .navigate) async throws -> Effect {
            judged(try await controller.prepare(.key(app: "Notes", keys: keys), actionID: ActionID()), declared: declared)
        }
        let power = GateContext(mode: .power, unattended: false, standing: .allowed)

        // Space, Delete, a paste in any modifier order, Undo, a ⌃ editing binding, ⌥Tab and ⌥Return
        // (a tab or line break in a Cocoa field), and a key an app may bind: each can put text in.
        let changesText: [[String]] = [
            ["space"], ["delete"], ["cmd", "v"], ["v", "cmd"], ["ctrl", "v"], ["shift", "insert"],
            ["option", "shift", "cmd", "v"], ["cmd", "z"], ["ctrl", "y"], ["option", "tab"], ["option", "return"], ["f5"],
        ]
        for keys in changesText {
            let judgedEffect = try await effect(keys)
            #expect(judgedEffect == .credential, "\(keys)")
            #expect(ActionGate.decide(judgedEffect, context: power) == .refuse(.secureField), "\(keys)")
        }

        // Moving through the window, modifiers alone, Return, and New stay as they were.
        for keys in [["tab"], ["shift", "tab"], ["escape"], ["up"], ["cmd", "left"], ["pagedown"], ["shift"]] {
            #expect(try await effect(keys) == .navigate, "\(keys)")
        }
        #expect(try await effect(["return"]) == .external)
        #expect(try await effect(["cmd", "n"], declared: .create) == .create)
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

    @Test
    func whatALookSendsFitsTheGatewaysLimitsCountedInUTF16Units() {
        let state = CuaWindowState(snapshotID: "s1", windowID: 1, elements: [
            CuaElement(index: 0, role: "AXWindow", label: overByOneUnit(500)),
            CuaElement(index: 1, role: overByOneUnit(64), value: overByOneUnit(2000), actions: [overByOneUnit(64)], parentIndex: 0),
        ])
        let nodes = ScreenController.tree(from: state, maxNodes: 100).tree.nodes
        #expect(nodes.map(\.label) == [lettersOf(500), nil])
        #expect(nodes.map(\.value) == [nil, lettersOf(2000)])
        #expect(nodes.map(\.role) == ["AXWindow", lettersOf(64)])
        #expect(nodes.map(\.actions) == [nil, [lettersOf(64)]])
    }
}

@Suite(.serialized)
@MainActor
struct ScreenKernelTests {
    func controller(
        _ gateway: ScriptedGateway,
        fake: FakeCuaNotes,
        claims: ScreenAppClaims = ScreenAppClaims(),
        invoker: (any CuaToolInvoking)? = nil
    ) -> TaskController {
        TaskController(
            url: URL(string: "ws://gateway.test/v2/session")!,
            transport: gateway,
            credentials: FixedGatewayCredentials(),
            identity: .init(deviceID: DeviceID(), appVersion: "2.0.0", osVersion: "26.0"),
            ledgers: MemoryTaskLedgerStore(),
            capabilities: KernelCapabilities([]),
            screenTools: Set(ScreenToolName.allCases),
            screenFactory: { screenController(fake, claims: claims, invoker: invoker) },
            permissions: { .init(accessibility: .granted, screenRecording: .granted, automation: []) },
            backoff: GatewayBackoff(base: 0.01, cap: 0.05, jitter: { 0 }),
            connectTimeout: 60
        )
    }

    func observed(_ gateway: ScriptedGateway, _ task: TaskID, re: Int, _ request: ObserveBody = ObserveBody(app: "Notes", ax: true, screenshot: false)) async throws -> ClientMessage {
        await gateway.send(task, .observe(request), re: re)
        return try await gateway.next("observation")
    }

    /// The task stops to ask, showing the effect it was judged as.
    func asksFirst(_ tasks: TaskController, _ task: TaskID, as effect: Effect) async -> Bool {
        await eventually {
            if case .awaitingApproval(let commit) = tasks.snapshot(task)?.phase { return commit.effect == effect }
            return false
        }
    }

    /// Starts a task in `mode`, looks at Notes with `request`, and proposes one screen action.
    func propose(_ action: ScreenAction, declared: Effect, mode: AgentInteractionMode, fake: FakeCuaNotes, request: ObserveBody = ObserveBody(app: "Notes", ax: true, screenshot: false)) async throws -> (ScriptedGateway, TaskController, TaskID) {
        let gateway = ScriptedGateway()
        let tasks = controller(gateway, fake: fake)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Work in Notes", mode: mode))
        _ = try await gateway.next("task.start")
        let first = try await observed(gateway, task, re: 1, request)
        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: ActionID(), effect: declared, kind: .screen(action)),
        ], final: false)), re: first.address?.seq)
        return (gateway, tasks, task)
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
        #expect(await asksFirst(tasks, task, as: .external))
        #expect(await fake.state.keysPressed.isEmpty)
    }

    @Test
    func aLineBreakInTheMiddleOfTypedTextAsksFirstInNormalMode() async throws {
        let gateway = ScriptedGateway()
        let fake = FakeCuaNotes()
        let tasks = controller(gateway, fake: fake)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Reply", mode: .normal))
        _ = try await gateway.next("task.start")
        let first = try await observed(gateway, task, re: 1)

        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: ActionID(), effect: .editLocal, kind: .screen(.typeText(app: "Notes", text: "Late\nsee you", element: nil))),
        ], final: false)), re: first.address?.seq)
        #expect(await asksFirst(tasks, task, as: .external))
        #expect(await fake.state.notes == FakeCuaNotesState().notes)
    }

    @Test
    func typingAtTheFocusOfALockedNotesPasswordFieldIsRefusedEvenInPowerMode() async throws {
        var state = FakeCuaNotesState()
        state.noteLocked = true
        let gateway = ScriptedGateway()
        let fake = FakeCuaNotes(state: state)
        let tasks = controller(gateway, fake: fake)
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "Open the locked note", mode: .power))
        _ = try await gateway.next("task.start")
        let first = try await observed(gateway, task, re: 1)

        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: ActionID(), effect: .editLocal, kind: .screen(.typeText(app: "Notes", text: "Sunflower1987", element: nil))),
        ], final: false)), re: first.address?.seq)
        let outcome = try await gateway.next("outcome")
        #expect(results(of: outcome).map(\.status) == [.refused])
        #expect(results(of: outcome).first?.error?.code == .secureField)
        #expect(await fake.state.passwordTyped == "")
    }

    @Test
    func returnHeldWithAnotherKeyAsksFirstInNormalMode() async throws {
        let fake = FakeCuaNotes()
        let (_, tasks, task) = try await propose(.key(app: "Notes", keys: ["return", "cmd"]), declared: .navigate, mode: .normal, fake: fake)
        #expect(await asksFirst(tasks, task, as: .external))
        #expect(await fake.state.shortcuts.isEmpty)
    }

    @Test
    func returnAsksFirstAfterAScreenshotOnlyLookAndAfterAWindowCuaCouldNotRead() async throws {
        var unread = FakeCuaNotesState()
        unread.degradedReadings = 2
        let looks = [
            (FakeCuaNotesState(), ObserveBody(app: "Notes", ax: false, screenshot: true)),
            (unread, ObserveBody(app: "Notes", ax: true, screenshot: true)),
        ]
        for (state, request) in looks {
            let fake = FakeCuaNotes(state: state)
            let (_, tasks, task) = try await propose(.key(app: "Notes", keys: ["return"]), declared: .navigate, mode: .normal, fake: fake, request: request)
            #expect(await asksFirst(tasks, task, as: .external), "\(request)")
            #expect(await fake.state.keysPressed.isEmpty)
        }
    }

    @Test
    func aPasteOrASpaceWhileAPasswordFieldShowsIsRefusedEvenInPowerMode() async throws {
        var state = FakeCuaNotesState()
        state.noteLocked = true
        for keys in [["cmd", "v"], ["space"]] {
            let fake = FakeCuaNotes(state: state)
            let (gateway, tasks, _) = try await propose(.key(app: "Notes", keys: keys), declared: .navigate, mode: .power, fake: fake)
            let outcome = try await gateway.next("outcome")
            #expect(results(of: outcome).map(\.status) == [.refused], "\(keys)")
            #expect(results(of: outcome).first?.error?.code == .secureField, "\(keys)")
            #expect(await fake.state.shortcuts.isEmpty, "\(keys)")
            #expect(await fake.state.keysPressed.isEmpty, "\(keys)")
            withExtendedLifetime(tasks) {}
        }
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

    @Test
    func cuasReasonForRefusingAnActionIsCutToWhatTheGatewayTakes() async throws {
        let gateway = ScriptedGateway()
        let fake = FakeCuaNotes()
        let tasks = controller(gateway, fake: fake, invoker: LongWindedCua(notes: fake))
        await tasks.launch()
        let task = try await startedTask(tasks, TaskRequest(goal: "New note", mode: .normal))
        _ = try await gateway.next("task.start")
        let first = try await observed(gateway, task, re: 1)
        guard case .observation(let look) = first.payload else { throw KernelTestFailure("not an observation") }

        let press = ActionID()
        let newNote = try ref(look) { $0.label == "New Note" && $0.role == "AXButton" }
        await gateway.send(task, .propose(ProposeBody(agent: .screen, actions: [
            WireAction(actionID: press, effect: .navigate, kind: .screen(.press(app: "com.apple.Notes", element: newNote))),
        ], final: false)), re: first.address?.seq)
        let outcome = try await gateway.next("outcome")
        let result = try #require(results(of: outcome).first)
        #expect(result.status == .failed)
        #expect(result.error?.message == lettersOf(1000))
    }
}
