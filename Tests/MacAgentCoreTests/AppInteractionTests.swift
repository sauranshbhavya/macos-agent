import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// V2 Milestone A on cua-driver: a new note in Notes (SONNY-544; founders, 2026-09-24). Every run
/// here goes through the real runtime, policy, screen and verifier, and through cua's own JSON at
/// the `CuaToolInvoking` seam, answered by `FakeCuaNotes`.
struct AppInteractionNotesTests {
    @Test
    func aNewNoteHoldsTheTextAndNothingElseChanges() async throws {
        let notes = FakeCuaNotes()
        let outcome = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))

        let report = try #require(outcome.report)
        #expect(report.summary == #"I made a new note in Notes: "Buy milk""#)
        let state = await notes.state
        #expect(state.menus == [["File", "New Note"]])
        #expect(state.notes == ["Groceries for Sunday", "Mom's birthday ideas", "Buy milk"])
        #expect(state.clicked.isEmpty)
        #expect(state.keysPressed.isEmpty)
    }

    @Test
    func aNoteMayRunOverSeveralLines() async throws {
        let notes = FakeCuaNotes()
        let outcome = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk\nEggs\nBread"))
        #expect(outcome.report != nil)
        #expect(await notes.state.notes.last == "Buy milk\nEggs\nBread")
    }

    /// Founders, 2026-09-24: privacy by role. Folder rows, a folder's name in its edit field, the
    /// date over the note and every note's text are the person's, and none of it reaches the model.
    @Test
    func theModelSeesNoFolderNoteOrOtherTextOfThePersons() async throws {
        let notes = FakeCuaNotes()
        let chooser = WritesIntoTheEditor()
        _ = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        let screens = chooser.screens
        #expect(!screens.isEmpty)
        let sent = try screens.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }.joined()
        for private_ in ["Recipes", "Family", "Groceries for Sunday", "Mom's birthday", "24 September", "Note Body", "Folders"] {
            #expect(!sent.contains(private_), "\(private_) reached the model")
        }
        #expect(screens.allSatisfy { $0.windowTitle == nil })
        let editor = try #require(screens.first?.candidates.first { $0.kind == "text area" })
        #expect(editor.label == "")
        #expect(editor.state == ["empty"])
    }

    /// The model is shown only what Sonny would do: no toolbar button, no unnamed button, no menu
    /// command named for a commit — the live WhatsApp run's `pressing ""` (2026-09-24) cannot recur.
    @Test
    func onlyStepsTheRulesAllowAreOffered() async throws {
        let notes = FakeCuaNotes()
        let chooser = WritesIntoTheEditor()
        _ = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        let screen = try #require(chooser.screens.first)
        #expect(screen.candidates.allSatisfy { !$0.can.isEmpty })
        #expect(!screen.candidates.contains { $0.kind == "button" })
        #expect(screen.candidates.filter { $0.kind == "menu command" }.map(\.label) == ["File › New Note", "Edit › Undo", "Format › Title"])
        #expect(screen.keys == ["tab", "up", "down", "left", "right", "escape", "pageup", "pagedown", "home", "end"])
        #expect(screen.shortcuts == ["cmd+f"])
    }

    @Test
    func aStepTheScreenNeverOfferedIsNotTaken() async throws {
        let notes = FakeCuaNotes()
        // e12 is the toolbar's Delete button, which the screen never offers.
        let chooser = Scripted([
            { _ in .step(.click, ref: "e12") },
            { screen in .step(.enterText, ref: screen.editorRef) },
        ])
        let outcome = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        #expect(outcome.report != nil)
        #expect(await notes.state.clicked.isEmpty)
        #expect(chooser.histories.last?.contains { $0.result == "no element has that ref" } == true)
    }

    @Test
    func aClickAtAPointIsJudgedAsAClickOnWhatIsThere() async throws {
        let notes = FakeCuaNotes()
        // The middle of the toolbar's Delete button.
        let outcome = await runtime(notes, chooser: Scripted([{ _ in .step(AppInteractionStep(.clickAt, x: 356, y: 26)) }]))
            .run(try noteGoal("Buy milk"))

        #expect(outcome == .failedAfterChange(.stepNotAllowed("Notes", "Delete"), app: "Notes", left: .newItem("note")))
        #expect(throws: AppInteractionRunError.self) { try outcome.runResult(plan: emptyPlan, previews: []) }
        #expect(AppInteractionRunError.failedAfterChange(.stepNotAllowed("Notes", "Delete"), app: "Notes", left: .newItem("note")).errorDescription
            == #"I stopped before pressing "Delete" in Notes, because it could send or change something. I had already started a new note in Notes."#)
        #expect(await notes.state.clicked.isEmpty)
    }

    @Test
    func aClickWhereNothingIsIsRefusedAndTheRunGoesOn() async throws {
        let notes = FakeCuaNotes()
        let chooser = Scripted([
            { _ in .step(AppInteractionStep(.clickAt, x: 1910, y: 1070)) },
            { screen in .step(.enterText, ref: screen.editorRef) },
        ])
        let outcome = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))
        #expect(outcome.report != nil)
        #expect(chooser.histories.last?.contains { $0.result == "refused: nothingThere" } == true)
    }

    /// Keys: Tab, the arrows, Escape, Page Up, Page Down, Home and End, never Return or Delete.
    /// Shortcuts: only ⌘F (founders, 2026-09-24).
    @Test
    func keysAndShortcutsFollowTheRules() async throws {
        let notes = FakeCuaNotes()
        let chooser = Scripted([
            { _ in .step(AppInteractionStep(.pressKey, input: "return")) },
            { _ in .step(AppInteractionStep(.pressKey, input: "delete")) },
            { _ in .step(AppInteractionStep(.pressKey, input: "tab")) },
            { _ in .step(AppInteractionStep(.shortcut, input: "cmd+delete")) },
            { _ in .step(AppInteractionStep(.shortcut, input: "⌘F")) },
            { screen in .step(.enterText, ref: screen.editorRef) },
        ])
        let outcome = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        #expect(outcome.report != nil)
        let state = await notes.state
        #expect(state.keysPressed == ["tab"])
        #expect(state.shortcuts == [["cmd", "f"]])
    }

    @Test
    func aMenuCommandRunsByItsPathAndOneThatCommitsIsNeverOffered() async throws {
        let notes = FakeCuaNotes()
        let chooser = Scripted([
            { screen in .step(.menu, ref: screen.ref(labelled: "Edit › Undo")) },
            { screen in .step(.enterText, ref: screen.editorRef) },
        ])
        _ = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))
        #expect(await notes.state.menus == [["File", "New Note"], ["Edit", "Undo"]])
        #expect(!chooser.screens.contains { $0.candidates.contains { $0.label.contains("Delete") || $0.label.contains("Close") } })
    }

    @Test
    func aNewNoteNotesWillNotStartEndsTheRunPlainly() async throws {
        var state = FakeCuaNotesState()
        state.newNoteEnabled = false
        let notes = FakeCuaNotes(state: state)
        let outcome = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))

        #expect(outcome == .failed(.couldNotStartItem("Notes", "note")))
        #expect(AppInteractionFailure.couldNotStartItem("Notes", "note").userMessage
            == "I couldn't start a new note in Notes. Open one of your folders there and try again.")
        #expect(await notes.state.notes == ["Groceries for Sunday", "Mom's birthday ideas"])
    }

    /// If New Note left the person's own note open, nothing is written over it.
    @Test
    func thePersonsTextIsNeverWrittenOver() async throws {
        var state = FakeCuaNotesState()
        state.newNoteKeepsOpenNote = true
        let notes = FakeCuaNotes(state: state)
        let chooser = WritesIntoTheEditor()
        let outcome = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        #expect(outcome == .failedAfterChange(.typedTextKept("Notes"), app: "Notes", left: .newItem("note")))
        #expect(chooser.screens.first?.candidates.first { $0.kind == "text area" }?.state == ["holds other text"])
        #expect(await notes.state.notes == ["Groceries for Sunday", "Mom's birthday ideas"])
    }

    @Test
    func aFieldThatTakesNoWholeValueGetsTheTextInsertedInstead() async throws {
        var state = FakeCuaNotesState()
        state.editorTakesValue = false
        let notes = FakeCuaNotes(state: state)
        let outcome = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))

        #expect(outcome.report != nil)
        #expect(await notes.state.notes.last == "Buy milk")
        #expect(await notes.callNames.contains("type_text"))
    }

    /// cua refuses a token from an older reading, so a redraw between the model's reading and the
    /// action never lands the text somewhere else.
    @Test
    func anElementFromAnOlderReadingIsNeverActedOn() async throws {
        let notes = FakeCuaNotes()
        let chooser = Scripted([
            { screen in await notes.redraw(); return .step(.enterText, ref: screen.editorRef) },
            { screen in .step(.enterText, ref: screen.editorRef) },
        ])
        let outcome = await runtime(notes, chooser: chooser).run(try noteGoal("Buy milk"))

        #expect(outcome.report != nil)
        #expect(chooser.histories.last?.contains { $0.result.contains("stale") } == true)
    }

    /// In full screen, Notes' toolbar is a window of its own; the runtime reads the main one.
    @Test
    func theAppsLargestWindowIsTheOneRead() async throws {
        let notes = FakeCuaNotes()
        _ = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))
        let reads = await notes.windowsRead
        #expect(!reads.isEmpty)
        #expect(reads.allSatisfy { $0 == FakeCuaNotes.mainWindow })
    }

    @Test
    func aWindowCuaCannotReadYetIsReadAgainThenReportedHonestly() async throws {
        var state = FakeCuaNotesState()
        state.degradedReadings = 2
        let settling = FakeCuaNotes(state: state)
        #expect(await runtime(settling, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk")).report != nil)

        state.degradedReadings = .max
        let unreadable = FakeCuaNotes(state: state)
        let outcome = await runtime(unreadable, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))
        #expect(outcome == .failedAfterChange(.unreadable("Notes"), app: "Notes", left: .newItem("note")))
    }

    @Test
    func eachGateStopsTheRunBeforeNotesIsTouched() async throws {
        var denied = FakeCuaNotesState()
        denied.accessibilityGranted = false
        let noPermission = FakeCuaNotes(state: denied)
        #expect(await runtime(noPermission, chooser: WritesIntoTheEditor()).run(try noteGoal("x")) == .failed(.accessibilityNotGranted))
        #expect(await noPermission.callNames == ["check_permissions"])

        let notAllowed = FakeCuaNotes()
        #expect(await runtime(notAllowed, chooser: WritesIntoTheEditor(), appControl: .needsApproval).run(try noteGoal("x"))
            == .failed(.appControlNotAllowed("Notes")))
        #expect(await notAllowed.callNames.isEmpty)

        let other = FakeCuaNotes()
        let outcome = await runtime(other, chooser: WritesIntoTheEditor(), apps: OneApp(name: "Mail", bundle: "com.apple.mail"))
            .run(try noteGoal("x", app: "Mail"))
        #expect(outcome == .failed(.appNotSupported("Mail")))
        #expect(AppInteractionFailure.appNotSupported("Mail").userMessage == "I can only make new notes in Notes for now, so I left Mail alone.")

        let terminal = await runtime(FakeCuaNotes(), chooser: WritesIntoTheEditor(), apps: OneApp(name: "Terminal", bundle: "com.apple.Terminal"))
            .run(try noteGoal("x", app: "Terminal"))
        guard case .failed(.refusedApp("Terminal", _)) = terminal else {
            Issue.record("a terminal was not refused: \(terminal)")
            return
        }
    }

    @Test
    func stoppingAfterTheNoteStartedSaysSo() async throws {
        let notes = FakeCuaNotes()
        let hangs = HangsUntilCancelled()
        let goal = try noteGoal("Buy milk")
        let task = Task { await runtime(notes, chooser: hangs).run(goal) }
        await hangs.waitUntilHanging()
        task.cancel()
        let outcome = await task.value

        #expect(outcome == .cancelled(app: "Notes", left: .newItem("note")))
        #expect(throws: AppInteractionStoppedAfterChange(app: "Notes", left: .newItem("note"))) {
            try outcome.runResult(plan: emptyPlan, previews: [])
        }
        #expect(AppInteractionStoppedAfterChange(app: "Notes", left: .newItem("note")).summary
            == "Stopped. I had already started a new note in Notes.")
        #expect(AppInteractionStoppedAfterChange(app: "Notes", left: .text).summary
            == "Stopped. The text I added is still in Notes.")
    }
}

// MARK: - cua's own ceiling

struct CuaCeilingTests {
    /// The founders' list (2026-09-24): on-screen tools only, less dragging, and Notes alone.
    @Test
    func theManifestNamesOnlyTheOnScreenToolsAndNotes() {
        let manifest = CuaCapabilityManifest.milestoneA
        #expect(Set(manifest.tools) == [
            "check_permissions", "list_windows", "get_window_state", "click", "double_click", "right_click",
            "set_value", "type_text", "press_key", "hotkey", "scroll", "invoke_menu",
        ])
        for never in ["kill_app", "clipboard_read", "clipboard_write", "set_config", "install_extension",
                      "check_for_update", "start_recording", "browser_download", "get_desktop_state", "drag", "launch_app"] {
            #expect(!manifest.tools.contains(never), "\(never) is inside Sonny's ceiling")
        }
        #expect(manifest.bundleIdentifiers == ["com.apple.Notes"])
        #expect(manifest.yaml.contains("    - bundle_id: com.apple.Notes\n      launch: false\n      windows: all"))
        #expect(manifest.yaml.contains("  desktop:\n    display: false"))
    }

    /// Sonny's rules allow the step; cua's ceiling refuses the tool; the run stops rather than
    /// trying another way.
    @Test
    func aCallOutsideTheCeilingEndsTheRun() async throws {
        let narrow = CuaCapabilityManifest(
            tools: CuaCapabilityManifest.milestoneA.tools.filter { $0 != "set_value" && $0 != "type_text" },
            bundleIdentifiers: ["com.apple.Notes"]
        )
        let notes = FakeCuaNotes(manifest: narrow)
        let outcome = await runtime(notes, chooser: WritesIntoTheEditor()).run(try noteGoal("Buy milk"))
        #expect(outcome == .failedAfterChange(.outsideCeiling("Notes"), app: "Notes", left: .newItem("note")))
    }

    /// The real library, in this process, under Sonny's own options: the ceiling it enforces is the
    /// one above. Touches no app — every call here is one cua refuses before acting.
    @Test
    func theRealLibraryRefusesWhatTheCeilingLeavesOut() async throws {
        let client = CuaDriverClient(invoker: try CuaDriverLibrary())
        do {
            _ = try await client.windows(pid: 1)
            Issue.record("cua listed the windows of an app outside the manifest")
        } catch let error as CuaToolError {
            #expect(error.isOutsideCeiling, "\(error.message)")
        }
        let library = try CuaDriverLibrary()
        for tool in ["clipboard_read", "kill_app", "get_desktop_state"] {
            let answer = try await library.invoke(tool, arguments: Data("{}".utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: answer) as? [String: Any])
            #expect(object["isError"] as? Bool == true, "\(tool) was not refused")
            let text = (object["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            #expect(text.contains("outside the capability manifest"), "\(tool): \(text)")
        }
    }
}

// MARK: - The rules on a hand-built reading

/// The target path is dormant in Milestone A (a new note has no target) and kept for the chat work
/// that follows; these hold its rules on a reading shaped like a chat list.
struct AppInteractionRuleTests {
    private static func chatList(selected: String? = nil) -> CuaWindowState {
        var elements = [
            CuaElement(index: 0, role: "AXWindow", label: "Chat"),
            CuaElement(index: 1, role: "AXTable", actions: ["AXScrollDownByPage"], parentIndex: 0),
        ]
        for (offset, name) in ["Mom", "Mom & Dad", "Missed call from Dad"].enumerated() {
            elements.append(CuaElement(index: 2 + offset, role: "AXRow", label: name, selected: name == selected,
                                       actions: ["AXPress"], parentIndex: 1, token: "s1:\(2 + offset)"))
        }
        elements.append(CuaElement(index: 5, role: "AXButton", label: "Send", actions: ["AXPress"], parentIndex: 0, token: "s1:5"))
        elements.append(CuaElement(index: 6, role: "AXTextArea", value: "", actions: [], parentIndex: 0, token: "s1:6"))
        return CuaWindowState(snapshotID: "s1", windowID: 1, windowTitle: "Chats", elements: elements)
    }

    private static func goal() throws -> AppInteractionGoal {
        try AppInteractionGoal.validated(app: "Chat", objective: "Draft to Mom", target: "Mom", text: "Running late")
    }

    @Test
    func aRowGoesOnlyWhenItIsExactlyTheTargetAndByThatName() throws {
        let screen = AppInteractionScreenBuilder(redact: { $0 }).build(from: Self.chatList(), goal: try Self.goal()).screen
        #expect(screen.candidates.filter { $0.kind == "row" }.map(\.label) == ["Mom"])
        #expect(!screen.candidates.contains { $0.label == "Send" })
    }

    @Test
    func aCallEntryAndACommittingButtonAreRefused() throws {
        let state = Self.chatList()
        let goal = try Self.goal()
        #expect(AppInteractionPolicy.decide(.init(.click, ref: "e4"), in: state, goal: goal) == .refuse(.mightCommit))
        #expect(AppInteractionPolicy.decide(.init(.click, ref: "e5"), in: state, goal: goal) == .refuse(.mightCommit))
        #expect(AppInteractionPolicy.decide(.init(.click, ref: "e2"), in: state, goal: goal)
            == .allow(.click(CuaElementRef(snapshotID: "s1", index: 2, token: "s1:2"))))
    }

    @Test
    func someoneElsesChatOpenBlocksTheTextAndIsNeverASuccess() throws {
        let state = Self.chatList(selected: "Mom & Dad")
        let goal = try Self.goal()
        #expect(AppInteractionPolicy.decide(.init(.enterText, ref: "e6"), in: state, goal: goal) == .refuse(.otherTargetOpen))
        #expect(AppInteractionVerifier.check(state, goal: goal) == .otherTargetOpen)
    }
}

// MARK: - Doubles

private let emptyPlan = AgentPlan(summary: "", requiresConfirmation: false, steps: [])

private func noteGoal(_ text: String, app: String = "Notes") throws -> AppInteractionGoal {
    try AppInteractionGoal.validated(app: app, objective: "A new note", target: nil, text: text)
}

private func runtime(
    _ notes: FakeCuaNotes,
    chooser: any AppInteractionStepChoosing,
    apps: any AppInteractionAppOpening = OneApp(name: "Notes", bundle: "com.apple.Notes"),
    appControl: AppControlStanding = .allowed
) -> AppInteractionRuntime {
    var budget = AppInteractionRuntime.Budget()
    budget.windowWait = .milliseconds(200)
    return AppInteractionRuntime(
        driver: CuaDriverClient(invoker: notes),
        chooser: chooser,
        apps: apps,
        appControl: { _ in appControl },
        redact: { $0 },
        budget: budget,
        sleep: { _ in await Task.yield() }
    )
}

struct OneApp: AppInteractionAppOpening {
    let name: String
    let bundle: String

    func resolve(_ name: String) -> InstalledApp? {
        InstalledApp(displayName: self.name, bundleIdentifier: bundle, applicationURL: URL(fileURLWithPath: "/Applications/\(self.name).app"))
    }

    func open(bundleIdentifier: String) async throws -> pid_t { 4242 }
}

extension AppInteractionOutcome {
    var report: AppInteractionReport? {
        if case .done(let report) = self { return report }
        return nil
    }
}

extension AppInteractionScreen {
    var editorRef: String { candidates.first { $0.kind == "text area" }?.ref ?? "none" }

    func ref(labelled label: String) -> String { candidates.first { $0.label == label }?.ref ?? "none" }
}

/// The model's part, played by rule: put the text in the editor, then say finished.
final class WritesIntoTheEditor: AppInteractionStepChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [AppInteractionScreen] = []
    var screens: [AppInteractionScreen] { lock.withLock { seen } }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        lock.withLock { seen.append(screen) }
        if history.last?.did.hasPrefix("enter_text") == true { return .finished }
        return screen.candidates.contains { $0.kind == "text area" } ? .step(.enterText, ref: screen.editorRef) : .giveUp("no editor")
    }
}

/// Answers from a script, one entry per turn, then says finished.
final class Scripted: AppInteractionStepChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [@Sendable (AppInteractionScreen) async -> AppInteractionModelDecision]
    private var seen: [AppInteractionScreen] = []
    private var heard: [[AppInteractionHistoryEntry]] = []
    var screens: [AppInteractionScreen] { lock.withLock { seen } }
    var histories: [[AppInteractionHistoryEntry]] { lock.withLock { heard } }

    init(_ turns: [@Sendable (AppInteractionScreen) async -> AppInteractionModelDecision]) {
        self.turns = turns
    }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let next = lock.withLock { () -> (@Sendable (AppInteractionScreen) async -> AppInteractionModelDecision)? in
            seen.append(screen)
            heard.append(history)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        guard let next else { return .finished }
        return await next(screen)
    }
}

/// Waits until cancelled, signalling when it starts waiting.
final class HangsUntilCancelled: AppInteractionStepChoosing, @unchecked Sendable {
    private let signal: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (signal, continuation) = AsyncStream.makeStream(of: Void.self)
    }

    func waitUntilHanging() async {
        for await _ in signal { return }
    }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        continuation.yield()
        // A hang backstop, not a bet on a window: only a failure to cancel ever reaches it.
        try await Task.sleep(for: .seconds(3_600))
        return .giveUp("unreachable")
    }
}
