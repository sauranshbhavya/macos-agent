import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing

// MARK: - Test doubles

/// Plays the model: reads the screen it was given and answers the way a competent model would,
/// unless a test overrides a turn.
private final class ScriptedChooser: AppInteractionStepChoosing, @unchecked Sendable {
    private let lock = NSLock()
    private var turns: [(AppInteractionScreen) -> AppInteractionModelDecision?]
    private(set) var screens: [AppInteractionScreen] = []
    private(set) var histories: [[AppInteractionHistoryEntry]] = []

    /// Each override is consulted once, in order; a nil answer or no override left falls back to
    /// `competent`.
    init(overrides: [(AppInteractionScreen) -> AppInteractionModelDecision?] = []) {
        turns = overrides
    }

    var calls: Int { lock.withLock { screens.count } }

    func chooseStep(
        goal: AppInteractionGoal,
        screen: AppInteractionScreen,
        history: [AppInteractionHistoryEntry]
    ) async throws -> AppInteractionModelDecision {
        let override: ((AppInteractionScreen) -> AppInteractionModelDecision?)? = lock.withLock {
            screens.append(screen)
            histories.append(history)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        if let override, let decision = override(screen) { return decision }
        return Self.competent(goal: goal, screen: screen)
    }

    static func competent(goal: AppInteractionGoal, screen: AppInteractionScreen) -> AppInteractionModelDecision {
        let target = goal.target ?? ""
        let box = screen.candidates.first { $0.kind == "text area" }
        if box?.state.contains("holds the message") == true { return .finished }
        let row = screen.candidates.first { ($0.kind == "row" || $0.kind == "button") && $0.label == target }
        if let box, screen.context.contains(target) || row?.state.contains("selected") == true {
            return .step(.enterText, ref: box.ref)
        }
        if let row { return .step(.press, ref: row.ref) }
        if let search = screen.candidates.first(where: { $0.kind == "search field" }),
           !search.state.contains("holds the target") {
            return .step(.enterTarget, ref: search.ref)
        }
        return .giveUp("nothing matches")
    }
}

private struct FakeApps: AppInteractionAppOpening {
    var installed: [String: InstalledApp] = [
        "chat": InstalledApp(displayName: "Chat", bundleIdentifier: "com.example.chat", applicationURL: URL(fileURLWithPath: "/Applications/Chat.app")),
        "terminal": InstalledApp(displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")),
    ]
    var openCount: OpenCounter = OpenCounter()

    func resolve(_ name: String) -> InstalledApp? { installed[name.lowercased()] }

    func open(bundleIdentifier: String) async throws -> pid_t {
        openCount.increment()
        return 4242
    }
}

private final class OpenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private func goal(
    app: String = "Chat",
    target: String? = "Mom",
    text: String? = "Running late, home by 8"
) throws -> AppInteractionGoal {
    try AppInteractionGoal.validated(
        app: app,
        objective: "Open the chat and leave the message unsent",
        target: target,
        text: text
    )
}

/// The fake chat app stands in for WhatsApp, so the tests allow its bundle identifier; one test
/// runs with the shipping allowlist to show everything else is refused.
private let fakeAppAllowed: Set<String> = ["com.example.chat"]

private func runtime(
    _ app: FakeChatAppAccessibility,
    chooser: any AppInteractionStepChoosing,
    apps: FakeApps = FakeApps(),
    standing: AppControlStanding = .allowed,
    supportedApps: Set<String> = fakeAppAllowed,
    budget: AppInteractionRuntime.Budget = AppInteractionRuntime.Budget(),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
) -> AppInteractionRuntime {
    AppInteractionRuntime(
        accessibility: app,
        chooser: chooser,
        apps: apps,
        appControl: { _ in standing },
        redact: { $0.replacingOccurrences(of: "sk-SECRET", with: "[redacted]") },
        supportedApps: supportedApps,
        budget: budget,
        sleep: sleep
    )
}

private func snapshot(_ state: FakeChatAppState) async throws -> AccessibilitySnapshot {
    try await FakeChatAppAccessibility(state: state).observe(processIdentifier: 1, limits: AccessibilityLimits())
}

private func element(_ snapshot: AccessibilitySnapshot, _ match: (AccessibilityElement) -> Bool) throws -> AccessibilityElement {
    let found = snapshot.elements.first(where: match)
    return try #require(found)
}

/// A snapshot written by hand, in depth-first order, each row naming its parent's index.
private func handMade(_ rows: [(role: String, parent: Int?, label: String?, value: String?, actions: [String])]) -> AccessibilitySnapshot {
    var depths: [Int] = []
    var elements: [AccessibilityElement] = []
    for (index, row) in rows.enumerated() {
        let depth = row.parent.map { depths[$0] + 1 } ?? 0
        depths.append(depth)
        elements.append(AccessibilityElement(
            id: AccessibilityElementID(generation: 1, index: index),
            parentIndex: row.parent,
            depth: depth,
            role: row.role,
            label: row.label,
            value: row.value,
            actions: row.actions
        ))
    }
    return AccessibilitySnapshot(
        generation: 1,
        app: AccessibilityObservedApp(bundleIdentifier: nil, processIdentifier: 1, name: nil),
        windowTitle: nil,
        elements: elements,
        truncation: nil,
        takenAt: Date(timeIntervalSince1970: 0)
    )
}

// MARK: - Goal

@Suite
struct AppInteractionGoalTests {
    @Test
    func aLineBreakInTheMessageIsRefusedBeforeAnythingRuns() {
        #expect(throws: AppInteractionGoalError.textHasLineBreak) {
            try AppInteractionGoal.validated(app: "Chat", objective: "draft", target: "Mom", text: "one\ntwo")
        }
        #expect(throws: AppInteractionGoalError.textHasLineBreak) {
            try AppInteractionGoal.validated(app: "Chat", objective: "draft", target: "Mom", text: "one\u{2028}two")
        }
    }

    @Test
    func surroundingWhitespaceIsTrimmedSoVerificationComparesLikeWithLike() throws {
        let goal = try AppInteractionGoal.validated(app: " Chat ", objective: " draft ", target: " Mom ", text: "  hi  ")
        #expect(goal.app == "Chat")
        #expect(goal.target == "Mom")
        #expect(goal.text == "hi")
    }

    @Test
    func aGoalWithNothingToFindAndNothingToTypeIsRefused() {
        #expect(throws: AppInteractionGoalError.nothingToDo) {
            try AppInteractionGoal.validated(app: "Chat", objective: "draft", target: "  ", text: nil)
        }
        #expect(throws: AppInteractionGoalError.missingApp) {
            try AppInteractionGoal.validated(app: " ", objective: "draft", target: "Mom", text: "hi")
        }
    }

    @Test
    func tooLongATextIsRefusedAtTheLimitAndNotBelowIt() throws {
        let atLimit = String(repeating: "a", count: AppInteractionGoal.maxTextLength)
        _ = try AppInteractionGoal.validated(app: "Chat", objective: "draft", target: "Mom", text: atLimit)
        #expect(throws: AppInteractionGoalError.textTooLong) {
            try AppInteractionGoal.validated(app: "Chat", objective: "draft", target: "Mom", text: atLimit + "a")
        }
    }
}

// MARK: - Decision decoding

@Suite
struct AppInteractionDecisionTests {
    @Test
    func eachDecisionDecodes() throws {
        #expect(try AppInteractionModelDecision.decode(from: #"{"decision":"act","step":"enter_text","ref":"e7","message":null}"#) == .step(.enterText, ref: "e7"))
        #expect(try AppInteractionModelDecision.decode(from: #"{"decision":"finished","step":null,"ref":null,"message":null}"#) == .finished)
        #expect(try AppInteractionModelDecision.decode(from: #"{"decision":"ask_user","step":null,"ref":null,"message":"Which Alex?"}"#) == .askUser("Which Alex?"))
        #expect(try AppInteractionModelDecision.decode(from: #"{"decision":"give_up","step":null,"ref":null,"message":"No chats"}"#) == .giveUp("No chats"))
    }

    @Test(arguments: [
        #"{"decision":"act","step":"type_keys","ref":"e7","message":null}"#,
        #"{"decision":"act","step":"press","ref":" ","message":null}"#,
        #"{"decision":"ask_user","step":null,"ref":null,"message":""}"#,
        #"{"decision":"send","step":null,"ref":null,"message":null}"#,
        "not json",
    ])
    func anythingOutsideTheSchemaIsMalformed(_ json: String) {
        #expect(throws: AppInteractionDecisionError.malformed) {
            try AppInteractionModelDecision.decode(from: json)
        }
    }
}

// MARK: - What the model is shown

@Suite
struct AppInteractionScreenTests {
    /// PR #289 review, F4: no preview, no draft, no conversation, no other chat's name.
    @Test
    func theModelSeesOnlyTheTargetsRowsByNameAndNothingOfAnyConversation() async throws {
        var state = FakeChatAppState(chats: ["Mom sk-SECRET", "Dad", "Maddie"], openChat: "Dad")
        state.drafts["Dad"] = "my unsent words to Dad"
        state.conversationControls = true
        let shot = try await snapshot(state)
        let built = AppInteractionScreenBuilder(redact: { $0.replacingOccurrences(of: "sk-SECRET", with: "[redacted]") })
            .build(from: shot, goal: try goal())

        let everything = try String(data: JSONEncoder().encode(built.screen), encoding: .utf8) ?? ""
        for kept in ["an earlier private message", "last message in", "my unsent words", "private-invite", "Join", "Maddie", "sk-SECRET"] {
            #expect(!everything.contains(kept), "\(kept) reached the model")
        }
        #expect(built.screen.candidates.filter { $0.kind == "row" }.map(\.label) == ["Mom [redacted]"])
        #expect(built.screen.context == ["Dad"])
        let box = try #require(built.screen.candidates.first { $0.kind == "text area" })
        #expect(box.state.contains("holds other text"))
        #expect(box.can == ["enter_text"])
        let search = try #require(built.screen.candidates.first { $0.kind == "search field" })
        #expect(search.can == ["enter_target"])
        for candidate in built.screen.candidates {
            #expect(built.references[candidate.ref] != nil)
        }
    }

    @Test
    func labelsAreCutToTheBudget() async throws {
        let long = "Mom " + String(repeating: "x", count: 300)
        let shot = try await snapshot(FakeChatAppState(chats: [long]))
        let built = AppInteractionScreenBuilder(redact: { $0 }).build(from: shot, goal: try goal())
        let row = try #require(built.screen.candidates.first { $0.kind == "row" })
        #expect(row.label.count == 81)
        #expect(row.label.hasSuffix("…"))
    }
}

// MARK: - Policy

@Suite
struct AppInteractionPolicyTests {
    @Test
    func sendAndCallButtonsAreRefusedAsPossibleCommits() async throws {
        let shot = try await snapshot(FakeChatAppState(chats: ["Mom"], openChat: "Mom"))
        let send = try element(shot) { $0.label == "Send" }
        let call = try element(shot) { $0.label == "Voice call" }
        #expect(AppInteractionPolicy.decide(.press, on: send.id, in: shot, goal: try goal()) == .refuse(.mightCommit))
        #expect(AppInteractionPolicy.decide(.press, on: call.id, in: shot, goal: try goal()) == .refuse(.mightCommit))
    }

    @Test
    func aRowNavigatesAndSoDoesARowDrawnAsAButton() async throws {
        let shot = try await snapshot(FakeChatAppState(chats: ["Mom", "Callum"]))
        let row = try element(shot) { $0.role == "AXRow" }
        #expect(AppInteractionPolicy.decide(.press, on: row.id, in: shot, goal: try goal()) == .allow(.press))
        // A person's name that happens to contain a verb opens: rows are matched word by word.
        let callum = try element(shot) { $0.role == "AXRow" && shot.displayName(of: $0) == "Callum" }
        #expect(AppInteractionPolicy.decide(.press, on: callum.id, in: shot, goal: try goal()) == .allow(.press))

        var buttons = FakeChatAppState(chats: ["Mom"])
        buttons.rowRole = "AXButton"
        let buttonShot = try await snapshot(buttons)
        let buttonRow = try element(buttonShot) { $0.role == "AXButton" }
        #expect(AppInteractionPolicy.decide(.press, on: buttonRow.id, in: buttonShot, goal: try goal()) == .allow(.press))
    }

    /// The reviewer's probes, each of which was allowed before (PR #289 review, F1).
    @Test
    func whatAButtonShowsAndWhereItSitsDecideItNotItsOwnTitleAlone() throws {
        let shot = handMade([
            ("AXWindow", nil, nil, nil, []),                          // 0
            ("AXTable", 0, nil, nil, []),                             // 1
            ("AXButton", 1, nil, nil, ["AXPress"]),                   // 2: named only by its child
            ("AXStaticText", 2, nil, "Send", []),                     // 3
            ("AXButton", 1, "Resend", nil, ["AXPress"]),              // 4: an inflection
            ("AXLink", 1, nil, nil, ["AXPress"]),                     // 5: a link
            ("AXStaticText", 5, nil, "https://evil.example/x", []),   // 6
            ("AXRow", 1, "Join call", nil, ["AXPress"]),              // 7: a row whose words commit
            ("AXStaticText", 0, nil, "Send", ["AXPress"]),            // 8: pressable text
            ("AXScrollArea", 0, nil, nil, []),                        // 9
            ("AXButton", 9, "Join", nil, ["AXPress"]),                // 10: in a scroll area, not a list
            ("AXButton", 9, "Mom", nil, ["AXPress"]),                 // 11: harmless name, not in a list
        ])
        let id = { AccessibilityElementID(generation: 1, index: $0) }
        let g = try goal()
        for index in [2, 4, 5, 7, 8, 10, 11] {
            #expect(
                AppInteractionPolicy.decide(.press, on: id(index), in: shot, goal: g) == .refuse(.mightCommit),
                "element \(index) could be pressed"
            )
        }
    }

    @Test
    func theTargetNameIsTypedOnlyIntoSearchAndTheMessageNeverIntoSearch() async throws {
        let shot = try await snapshot(FakeChatAppState(chats: ["Mom"], openChat: "Mom"))
        let search = try element(shot) { $0.subrole == AccessibilityVocabulary.searchFieldSubrole }
        let box = try element(shot) { $0.role == "AXTextArea" }
        let row = try element(shot) { $0.role == "AXRow" }
        let g = try goal()
        #expect(AppInteractionPolicy.decide(.enterTarget, on: search.id, in: shot, goal: g) == .allow(.setValue("Mom")))
        #expect(AppInteractionPolicy.decide(.enterText, on: box.id, in: shot, goal: g) == .allow(.setValue("Running late, home by 8")))
        #expect(AppInteractionPolicy.decide(.enterText, on: search.id, in: shot, goal: g) == .refuse(.searchFieldForMessage))
        #expect(AppInteractionPolicy.decide(.enterText, on: row.id, in: shot, goal: g) == .refuse(.notATextField))
        // PR #289 review, F2: the name typed into the message box would replace a draft with a name.
        #expect(AppInteractionPolicy.decide(.enterTarget, on: box.id, in: shot, goal: g) == .refuse(.notASearchField))
        let noText = try goal(text: nil)
        #expect(AppInteractionPolicy.decide(.enterText, on: box.id, in: shot, goal: noText) == .refuse(.nothingToType))
    }

    @Test
    func theMessageNeverReplacesWhatThePersonTypedButMayReplaceWhatSonnyTyped() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.drafts["Mom"] = "my own half-written words"
        let shot = try await snapshot(state)
        let box = try element(shot) { $0.role == "AXTextArea" }
        #expect(AppInteractionPolicy.decide(.enterText, on: box.id, in: shot, goal: try goal()) == .refuse(.wouldReplaceTypedText))
        #expect(
            AppInteractionPolicy.decide(.enterText, on: box.id, in: shot, goal: try goal(), sonnyWrote: ["My own  half-written words"])
                == .allow(.setValue("Running late, home by 8"))
        )

        state.drafts["Mom"] = "Running late, home by 8"
        let same = try await snapshot(state)
        let sameBox = try element(same) { $0.role == "AXTextArea" }
        #expect(AppInteractionPolicy.decide(.enterText, on: sameBox.id, in: same, goal: try goal()) == .allow(.setValue("Running late, home by 8")))
    }

    @Test
    func theMessageIsNotTypedWhileSomeoneElsesChatIsOpen() async throws {
        let shot = try await snapshot(FakeChatAppState(chats: ["Mom", "Dad"], openChat: "Dad"))
        let box = try element(shot) { $0.role == "AXTextArea" }
        #expect(AppInteractionPolicy.decide(.enterText, on: box.id, in: shot, goal: try goal()) == .refuse(.otherTargetOpen))
    }

    @Test
    func aPlaceholderShownAsTheValueCountsAsEmptyAndAPasswordFieldIsNoField() throws {
        let id = { AccessibilityElementID(generation: 1, index: $0) }
        let shot = AccessibilitySnapshot(
            generation: 1,
            app: AccessibilityObservedApp(bundleIdentifier: nil, processIdentifier: 1, name: nil),
            windowTitle: nil,
            elements: [
                AccessibilityElement(id: id(0), parentIndex: nil, depth: 0, role: "AXWindow"),
                AccessibilityElement(
                    id: id(1), parentIndex: 0, depth: 1, role: "AXTextArea",
                    placeholder: "Type a message", value: "Type a message", canSetValue: true
                ),
                AccessibilityElement(
                    id: id(2), parentIndex: 0, depth: 1, role: "AXTextField", subrole: "AXSecureTextField",
                    placeholder: "Search", canSetValue: true, canFocus: true
                ),
            ],
            truncation: nil,
            takenAt: Date(timeIntervalSince1970: 0)
        )
        let g = try goal()
        #expect(AppInteractionPolicy.decide(.enterText, on: id(1), in: shot, goal: g) == .allow(.setValue("Running late, home by 8")))
        #expect(!shot.elements[2].isTextInput)
        #expect(AppInteractionPolicy.decide(.enterTarget, on: id(2), in: shot, goal: g) == .refuse(.notASearchField))
        let built = AppInteractionScreenBuilder(redact: { $0 }).build(from: shot, goal: g)
        #expect(built.screen.candidates.map(\.ref) == ["e1"])
    }

    @Test
    func anIdFromAnEarlierObservationIsGone() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        let first = try await app.observe(processIdentifier: 1, limits: AccessibilityLimits())
        let second = try await app.observe(processIdentifier: 1, limits: AccessibilityLimits())
        let row = try element(first) { $0.role == "AXRow" }
        #expect(AppInteractionPolicy.decide(.press, on: row.id, in: second, goal: try goal()) == .refuse(.elementGone))
    }
}

// MARK: - Verification

@Suite
struct AppInteractionVerifierTests {
    private func check(_ state: FakeChatAppState, _ goal: AppInteractionGoal) async throws -> AppInteractionVerifier.Result {
        AppInteractionVerifier.check(try await snapshot(state), goal: goal)
    }

    @Test
    func theTextInTheNamedOpenChatIsSatisfied() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.drafts["Mom"] = "Running late, home by 8"
        #expect(try await check(state, try goal()) == .satisfied)
    }

    @Test
    func withNoVisibleChatNameTheResultIsUnconfirmedNotSatisfied() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.drafts["Mom"] = "Running late, home by 8"
        state.exposesHeader = false
        #expect(try await check(state, try goal()) == .targetUnconfirmed)
    }

    /// PR #289 review, F3: a different chat visibly open is never "couldn't confirm".
    @Test
    func someoneElsesChatVisiblyOpenIsNeverASuccess() async throws {
        var state = FakeChatAppState(chats: ["Mom & Dad", "Mom"], openChat: "Mom & Dad")
        state.drafts["Mom & Dad"] = "Running late, home by 8"
        #expect(try await check(state, try goal()) == .otherTargetOpen)

        var hidden = FakeChatAppState(chats: ["Mom", "Dad"], openChat: "Dad")
        hidden.drafts["Dad"] = "Running late, home by 8"
        hidden.exposesHeader = false
        #expect(try await check(hidden, try goal()) == .otherTargetOpen)
    }

    @Test
    func theTextInTheSearchFieldOrNowhereIsNotYet() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        #expect(try await check(state, try goal()) == .notYet)
        state.search = "Running late, home by 8"
        #expect(try await check(state, try goal()) == .notYet)
    }

    /// PR #289 review, F7: a sent message shown in a read-only text view is not a draft.
    @Test
    func aReadOnlyTextInsideTheConversationIsNotADraft() throws {
        let shot = handMade([
            ("AXWindow", nil, nil, nil, []),
            ("AXStaticText", 0, nil, "Mom", []),
            ("AXScrollArea", 0, nil, nil, []),
            ("AXTextArea", 2, nil, "Running late, home by 8", []),
        ])
        #expect(AppInteractionVerifier.check(shot, goal: try goal()) == .notYet)
    }
}

@Suite
struct AccessibilityIdentityTests {
    @Test
    func aRowShowingADifferentChatIsADifferentElementButATypedFieldIsTheSame() async throws {
        let before = try await snapshot(FakeChatAppState(chats: ["Mom", "Dad"], openChat: "Mom"))
        let after = try await snapshot(FakeChatAppState(chats: ["Dad", "Mom"], openChat: "Mom"))
        let firstRowBefore = try element(before) { $0.role == "AXRow" }
        let firstRowAfter = after.elements[firstRowBefore.id.index]
        #expect(!after.identity(of: firstRowAfter).matches(before.identity(of: firstRowBefore)))

        var typed = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        let empty = try await snapshot(typed)
        typed.drafts["Mom"] = "hello"
        let full = try await snapshot(typed)
        let box = try element(empty) { $0.role == "AXTextArea" }
        #expect(full.identity(of: full.elements[box.id.index]).matches(empty.identity(of: box)))
    }
}

// MARK: - Runtime

@Suite
struct AppInteractionRuntimeTests {
    @Test
    func draftsIntoTheNamedChatAndSendsNothing() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Dad", "Mom", "Mom & Dad"]))
        let outcome = await runtime(app, chooser: ScriptedChooser()).run(try goal())

        guard case .done(let report) = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
        #expect(report.targetConfirmed)
        #expect(report.summary.contains("not sent"))
        let state = await app.state
        #expect(state.openChat == "Mom")
        #expect(state.drafts == ["Mom": "Running late, home by 8"])
        #expect(state.sentMessages.isEmpty)
        #expect(state.callsPlaced == 0)
    }

    /// PR #289 review, F6.
    @Test
    func everyAppButWhatsAppIsRefusedByName() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        let apps = FakeApps()
        let outcome = await runtime(app, chooser: ScriptedChooser(), apps: apps, supportedApps: AppInteractionRuntime.milestoneAApps)
            .run(try goal())
        #expect(outcome == .failed(.appNotSupported("Chat")))
        #expect(apps.openCount.count == 0)
        #expect(AppInteractionRuntime.milestoneAApps.contains("net.whatsapp.whatsapp"))
    }

    @Test
    func whenTheChatNameCannotBeSeenTheReportSaysSo() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.exposesHeader = false
        let app = FakeChatAppAccessibility(state: state)
        let outcome = await runtime(app, chooser: ScriptedChooser()).run(try goal())
        guard case .done(let report) = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
        #expect(!report.targetConfirmed)
        #expect(report.summary.contains("couldn't see which chat is open"))
    }

    /// PR #289 review, F3: typing first into someone else's open chat is refused, and the run goes
    /// on to the right chat instead of ending as a success.
    @Test
    func aModelThatTypesIntoTheWrongOpenChatIsTurnedAround() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom", "Dad"], openChat: "Dad"))
        let chooser = ScriptedChooser(overrides: [{ screen in
            screen.candidates.first { $0.kind == "text area" }.map { .step(.enterText, ref: $0.ref) }
        }])
        let outcome = await runtime(app, chooser: chooser).run(try goal())
        guard case .done(let report) = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
        #expect(report.targetConfirmed)
        #expect(await app.state.drafts == ["Mom": "Running late, home by 8"])
        #expect(chooser.histories[1].first?.result == "refused: otherTargetOpen")
    }

    @Test
    func aModelThatReachesForSendIsStoppedAndNothingIsSent() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.drafts["Mom"] = "Running late, home by 8"
        state.exposesHeader = false
        let app = FakeChatAppAccessibility(state: state)
        let chooser = ScriptedChooser(overrides: [{ screen in
            screen.candidates.first { $0.label == "Send" }.map { .step(.press, ref: $0.ref) }
        }])
        let outcome = await runtime(app, chooser: chooser).run(try goal())
        #expect(outcome == .failed(.stepNotAllowed("Chat", "Send")))
        #expect(await app.state.sentMessages.isEmpty)
        #expect(await app.performed.isEmpty)
    }

    @Test
    func aChatWithTheirOwnDraftInItIsLeftAloneAndTheRunSaysWhy() async throws {
        var state = FakeChatAppState(chats: ["Mom"], openChat: "Mom")
        state.drafts["Mom"] = "my own half-written words"
        let app = FakeChatAppAccessibility(state: state)
        let outcome = await runtime(app, chooser: ScriptedChooser()).run(try goal())
        #expect(outcome == .failed(.typedTextKept("Chat")))
        #expect(await app.state.drafts == ["Mom": "my own half-written words"])
        #expect(await app.performed.isEmpty)
    }

    /// PR #289 review, F5: a row that a new message moved during the model call is not pressed.
    @Test
    func aRowThatMovedWhileTheModelWasDecidingIsNotPressed() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom", "Dad"]))
        let reorders = ReorderingChooser(app: app)
        let outcome = await runtime(app, chooser: reorders).run(try goal())
        guard case .done = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
        #expect(reorders.firstResult == "failed: staleElement")
        #expect(await app.state.drafts == ["Mom": "Running late, home by 8"])
    }

    @Test
    func withoutAccessibilityNothingIsAskedOrOpened() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]), trusted: false)
        let chooser = ScriptedChooser()
        let apps = FakeApps()
        let outcome = await runtime(app, chooser: chooser, apps: apps).run(try goal())
        #expect(outcome == .failed(.accessibilityNotGranted))
        #expect(chooser.calls == 0)
        #expect(apps.openCount.count == 0)
    }

    @Test
    func aTerminalIsRefusedAndAnAppNotAllowedInThisModeIsNotOpened() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        let apps = FakeApps()
        let terminal = await runtime(app, chooser: ScriptedChooser(), apps: apps).run(try goal(app: "Terminal"))
        #expect(terminal == .failed(.refusedApp("Terminal", .terminal)))
        let notAllowed = await runtime(app, chooser: ScriptedChooser(), apps: apps, standing: .needsApproval).run(try goal())
        #expect(notAllowed == .failed(.appControlNotAllowed("Chat")))
        let missing = await runtime(app, chooser: ScriptedChooser(), apps: apps).run(try goal(app: "Nowhere"))
        #expect(missing == .failed(.appNotInstalled("Nowhere")))
        #expect(apps.openCount.count == 0)
        #expect(await app.observations == 0)
    }

    @Test
    func askingTheUserAndGivingUpEndTheRunWithTheirWords() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Alex", "Alex"]))
        let asks = await runtime(app, chooser: ScriptedChooser(overrides: [{ _ in .askUser("Which Alex?") }])).run(try goal(target: "Alex"))
        #expect(asks == .needsUserInput("Which Alex?"))
        let quits = await runtime(app, chooser: ScriptedChooser(overrides: [{ _ in .giveUp("no such chat") }])).run(try goal())
        #expect(quits == .failed(.gaveUp("Chat", "no such chat")))
    }

    /// PR #289 review, F8.
    @Test
    func aFailureAfterTypingSaysTheTextIsStillThere() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Dad"]))
        let chooser = ScriptedChooser(overrides: [
            { screen in screen.candidates.first { $0.kind == "search field" }.map { .step(.enterTarget, ref: $0.ref) } },
            { _ in .giveUp("no chat called Mom") },
        ])
        let outcome = await runtime(app, chooser: chooser).run(try goal())
        #expect(outcome == .failedAfterTyping(.gaveUp("Chat", "no chat called Mom"), app: "Chat"))
        let error = AppInteractionRunError.failedAfterTyping(.gaveUp("Chat", "no chat called Mom"), app: "Chat")
        #expect(error.errorDescription?.hasSuffix("Anything I typed is still in Chat, unsent.") == true)
    }

    /// PR #289 review, F7: "finished" before anything was typed is not believed.
    @Test
    func aModelThatSaysFinishedBeforeTypingIsNotBelieved() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        let chooser = ScriptedChooser(overrides: [{ _ in .finished }])
        let outcome = await runtime(app, chooser: chooser).run(try goal())
        guard case .done = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
        #expect(chooser.histories[1].first?.did == "said finished")
        #expect(await app.state.drafts == ["Mom": "Running late, home by 8"])
    }

    @Test
    func aRefusedOrUnknownStepIsReportedBackAndCountsAgainstTheBudget() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        var budget = AppInteractionRuntime.Budget()
        budget.maxSteps = 3
        let chooser = ScriptedChooser(overrides: [
            { _ in .step(.press, ref: "e999") },
            { screen in screen.candidates.first { $0.kind == "row" }.map { .step(.enterText, ref: $0.ref) } },
            { _ in .step(.press, ref: "e999") },
        ])
        let outcome = await runtime(app, chooser: chooser, budget: budget).run(try goal())
        #expect(outcome == .failed(.ranOutOfSteps("Chat", 3)))
        #expect(chooser.histories[1].first?.result == "no element has that ref")
        #expect(chooser.histories[2].last?.result == "refused: notATextField")
    }

    @Test
    func aMessageBoxThatIgnoresWritesIsReportedAndNotClaimed() async throws {
        var state = FakeChatAppState(chats: ["Mom"])
        state.messageBoxIsSettable = false
        let app = FakeChatAppAccessibility(state: state)
        var budget = AppInteractionRuntime.Budget()
        budget.maxSteps = 5
        let outcome = await runtime(app, chooser: ScriptedChooser(), budget: budget).run(try goal())
        #expect(outcome == .failed(.ranOutOfSteps("Chat", 5)))
        #expect(await app.state.drafts.isEmpty)
    }

    @Test
    func aWindowThatTakesAMomentIsWaitedFor() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]), windowlessObservations: 3)
        let outcome = await runtime(app, chooser: ScriptedChooser()).run(try goal())
        guard case .done = outcome else {
            Issue.record("expected done, got \(outcome)")
            return
        }
    }

    @Test
    func aWindowThatNeverAppearsFailsWithinTheWait() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]), windowlessObservations: .max)
        var budget = AppInteractionRuntime.Budget()
        budget.windowWait = .milliseconds(30)
        budget.windowPoll = .milliseconds(5)
        let outcome = await runtime(app, chooser: ScriptedChooser(), budget: budget, sleep: { try await Task.sleep(for: $0) })
            .run(try goal())
        #expect(outcome == .failed(.noWindow("Chat")))
    }

    @Test
    func losingAccessibilityMidRunStopsWithThatReason() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Mom"]))
        let revoking = RevokingChooser(inner: ScriptedChooser(), app: app, revokeOnCall: 2)
        #expect(await runtime(app, chooser: revoking).run(try goal()) == .failed(.accessibilityNotGranted))
    }

    @Test
    func stoppingAfterTextWasTypedSaysSo() async throws {
        let app = FakeChatAppAccessibility(state: FakeChatAppState(chats: ["Dad"]))
        // Call 1 types the name into search, which counts as typing; call 2 hangs.
        let typesIntoSearch = ScriptedChooser(overrides: [{ screen in
            screen.candidates.first { $0.kind == "search field" }.map { .step(.enterTarget, ref: $0.ref) }
        }])
        let gate = HangingChooser(inner: typesIntoSearch, hangOnCall: 2)
        let running = runtime(app, chooser: gate)
        let g = try goal(text: "one")
        let task = Task { await running.run(g) }
        await gate.waitUntilHanging()
        task.cancel()
        #expect(await task.value == .cancelled(typedSomething: true, app: "Chat"))
        #expect(await app.state.search == "Mom")
    }
}

/// Revokes trust just before answering its `revokeOnCall`th decision, so the action that follows
/// meets a provider that no longer trusts Sonny.
private struct RevokingChooser: AppInteractionStepChoosing {
    let inner: ScriptedChooser
    let app: FakeChatAppAccessibility
    let revokeOnCall: Int

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let decision = try await inner.chooseStep(goal: goal, screen: screen, history: history)
        if inner.calls == revokeOnCall { await app.revokeTrust() }
        return decision
    }
}

/// On its first turn, answers "press Mom's row" and then moves Dad to the top before the press
/// lands, as a new message would; after that, plays the competent model.
private final class ReorderingChooser: AppInteractionStepChoosing, @unchecked Sendable {
    private let app: FakeChatAppAccessibility
    private let inner = ScriptedChooser()
    private let lock = NSLock()
    private var turn = 0
    private var recorded: String?

    init(app: FakeChatAppAccessibility) {
        self.app = app
    }

    var firstResult: String? { lock.withLock { recorded } }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let current = lock.withLock { () -> Int in
            turn += 1
            if turn == 2 { recorded = history.first?.result }
            return turn
        }
        let decision = try await inner.chooseStep(goal: goal, screen: screen, history: history)
        if current == 1 { await app.reorderChats(["Dad", "Mom"]) }
        return decision
    }
}

/// Suspends on its `hangOnCall`th decision until the task is cancelled, and lets the test wait
/// for that moment on a signal rather than on the clock.
private final class HangingChooser: AppInteractionStepChoosing, @unchecked Sendable {
    private let inner: ScriptedChooser
    private let hangOnCall: Int
    private let signal: AsyncStream<Void>
    private let signalContinuation: AsyncStream<Void>.Continuation

    init(inner: ScriptedChooser, hangOnCall: Int) {
        self.inner = inner
        self.hangOnCall = hangOnCall
        (signal, signalContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func waitUntilHanging() async {
        for await _ in signal { return }
    }

    func chooseStep(goal: AppInteractionGoal, screen: AppInteractionScreen, history: [AppInteractionHistoryEntry]) async throws -> AppInteractionModelDecision {
        let decision = try await inner.chooseStep(goal: goal, screen: screen, history: history)
        guard inner.calls == hangOnCall else { return decision }
        signalContinuation.yield()
        // A hang backstop, not a bet on a window: only a failure to cancel ever reaches it.
        try await Task.sleep(for: .seconds(3_600))
        return decision
    }
}
