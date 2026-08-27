import Foundation
import Testing
@testable import MacAgent

/// The widget composer while it is not taking a command (SONNY-247).
///
/// **What was broken, and what deliberately was not.** The composer is disabled whenever a task
/// occupies the app, and that behaviour is correct — a second task must not start while one is parked
/// on the user's answer, and the answer has its own field a few pixels above. What was wrong is that
/// the composer said none of it: it kept the idle placeholder, stopped responding, and swallowed a
/// paste, which is indistinguishable from a hung app. The founder reported it twice on 2026-08-23 —
/// "I cannot type inside the floating widget nor copy-paste anything" in the morning, and "when a
/// clarification question is asked, the typing bar doesn't work" mid-manual-pass.
///
/// Every wiring pin here is a source scan, for the reason `ResumeOfferPresentationTests` gives: this
/// repository has no SwiftUI inspection harness and no way to type into the live app.
/// `MacAgentSource.read` strips both comment syntaxes, so nothing here can be satisfied by a comment
/// describing the code.
@MainActor
struct WidgetComposerStateTests {
    // MARK: - The copy

    /// Each state says a different thing, and the idle one is untouched.
    ///
    /// The ready prompt is asserted verbatim because it is a shipped string the founder has already
    /// signed off and a manual-checklist row names it (`docs/sonny-manual-test-checklist.md` §3a) —
    /// this ticket changes what the composer says while it is *busy*, not while it is free.
    @Test
    func eachComposerStateSaysSomethingDifferentAndTheIdleOneIsUnchanged() {
        #expect(ComposerPresentation.prompt(for: .ready) == "Let Sonny take it from here\u{2026}")
        #expect(ComposerPresentation.prompt(for: .waitingOnYou) == "Answer above first\u{2026}")
        #expect(ComposerPresentation.prompt(for: .working) == "Sonny is working\u{2026}")

        let prompts = Set(ComposerPresentation.State.allCases.map { ComposerPresentation.prompt(for: $0) })
        #expect(
            prompts.count == ComposerPresentation.State.allCases.count,
            "two states sharing a sentence is two states the user cannot tell apart"
        )
    }

    /// **The split is the fix, so the split is what is held.**
    ///
    /// "A question is parked on you and the control is right there" is not the same situation as "a
    /// run is in flight and there is nothing here to type into", and the whole defect was treating
    /// them alike. `waitingOnYou` points at the panel above; `working` does not, and must not — a
    /// run whose panel is origin-gated may put nothing in the widget at all, and a screen-control
    /// session with nothing parked on it puts a progress HUD there rather than a question. (That
    /// second clause used to read "a live screen-control session", full stop, which was true of a
    /// session holding an unanswerable approval and is not true of one since SONNY-255.)
    @Test
    func onlyTheStateWithAControlAboveItPointsUpwards() {
        #expect(ComposerPresentation.prompt(for: .waitingOnYou).localizedCaseInsensitiveContains("above"))
        #expect(!ComposerPresentation.prompt(for: .working).localizedCaseInsensitiveContains("above"))
        #expect(!ComposerPresentation.prompt(for: .ready).localizedCaseInsensitiveContains("above"))
    }

    /// Exactly one state takes input, and it is the idle one.
    @Test
    func onlyTheReadyStateTakesInput() {
        #expect(ComposerPresentation.acceptsInput(.ready))
        #expect(!ComposerPresentation.acceptsInput(.waitingOnYou))
        #expect(!ComposerPresentation.acceptsInput(.working))
        #expect(ComposerPresentation.State.allCases.filter(ComposerPresentation.acceptsInput).count == 1)
    }

    /// **Nothing here explains how Sonny works**, per the founder's standing rule of 2026-08-14 and
    /// restated for this ticket: a changed placeholder is the composer describing its own state,
    /// which is a different thing from a sentence teaching the feature — but the line is real and
    /// worth respecting, so it is held the same way `ResumeOfferPresentationTests` holds the offer's.
    @Test
    func noneOfTheComposersCopyExplainsHowSonnyWorks() {
        let explanatory = [
            "step", "because", "so that", "this means", "automatically", "you can", "in order to",
            "while", "since", "disabled", "will be"
        ]
        for state in ComposerPresentation.State.allCases {
            let sentence = ComposerPresentation.prompt(for: state)
            for phrase in explanatory {
                #expect(
                    !sentence.localizedCaseInsensitiveContains(phrase),
                    "\u{201C}\(sentence)\u{201D} explains rather than states"
                )
            }
            // Short enough to sit in a 472pt pill beside a wand glyph without competing with it.
            #expect(sentence.count <= 34, "\u{201C}\(sentence)\u{201D} is a sentence, not a placeholder")
        }
    }

    // MARK: - The classification, and the gate derived from it

    /// **Every condition the composer disables on is classified, the classification is checked, and
    /// the ordering that makes it *true* is checked with it.**
    ///
    /// Modelled on `everyDispatchDoorIsClassifiedAndTheClassificationIsChecked` in the sibling file,
    /// and for the same reason: a scan that only counts a population lets a condition sit in the
    /// wrong bucket while reading as coverage. So each of the seven is named with the answer it is
    /// supposed to give, the answer is read off the branch it actually sits in, and the count
    /// underneath is what forces an eighth into the table rather than past it.
    ///
    /// **The ordering assertions are the part that would have caught F1.** The first version of this
    /// test was green while the classification it pinned rested on a false premise —
    /// `isAwaitingApproval` was called `.waitingOnYou` unconditionally, which was wrong at the time
    /// because a live screen-control session outranked the approval in `FloatingWidgetView.state`
    /// and put a progress HUD on screen instead of the question. A table alone cannot see that,
    /// because the table was *correct about which bucket the token was in*; what was wrong was the
    /// reason the bucket was right. So the branch shape and the relative order are pinned too, and
    /// `theWidgetsOwnPrecedenceIsWhatMakesTheComposersClassificationTrue` pins the fact in `state`
    /// they depend on.
    ///
    /// **The premise has since been fixed rather than the classification** (SONNY-255): the approval
    /// now outranks the session, so `isAwaitingApproval` is `.waitingOnYou` unconditionally after
    /// all, and this table says so — the bucket that was right for the wrong reason is right for the
    /// right one, and the ordering assertion below is what carries the difference. That is the point
    /// of pinning an order rather than a bucket: when the order moved, both this test and the state
    /// it mirrors had to move, and neither could do it quietly.
    ///
    /// **The second half matters as much as the first.** `isTaskInFlight` is *derived* from
    /// `composerState` rather than computed a second time — so the gate that disables the field and
    /// the sentence that explains why cannot drift apart. Two independent copies of a seven-term
    /// disjunction is precisely the shape that produced a composer whose placeholder disagreed with
    /// its own behaviour.
    @Test
    func everyConditionTheComposerDisablesOnIsClassified() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let state = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "var composerState: ComposerPresentation.State {"
        )

        /// The word after each `return .`, in source order.
        func returnedCases(of block: String) -> [String] {
            var results: [String] = []
            var cursor = block.startIndex
            while let found = block.range(of: "return .", range: cursor..<block.endIndex) {
                results.append(String(block[found.upperBound...].prefix { $0.isLetter }))
                cursor = found.upperBound
            }
            return results
        }

        // The branch shape itself. Five guarded returns and a fallthrough, in this order — a sixth
        // guard, or the same five reordered, is a change to the argument above and fails here.
        //
        // It was four until SONNY-255 split the approval out of the pair below the session line and
        // put it above: `["waitingOnYou", "working", "waitingOnYou", "working", "ready"]` was the
        // shape while `.controlling` outranked `.permission` in `state`.
        #expect(
            returnedCases(of: state)
                == ["waitingOnYou", "waitingOnYou", "working", "waitingOnYou", "working", "ready"],
            "the branch shape carries the correctness argument — see this test's doc comment"
        )

        /// Which answer a condition actually gets: the first `return .` that follows it.
        func answer(for condition: String) throws -> String {
            let site = try #require(state.range(of: condition), "not in composerState: \(condition)")
            let rest = state[site.upperBound...]
            let returned = try #require(rest.range(of: "return ."), "no return follows \(condition)")
            return String(rest[returned.upperBound...].prefix { $0.isLetter })
        }

        /// Where a condition sits, for the ordering assertions below.
        func position(of condition: String) throws -> Int {
            let site = try #require(state.range(of: condition), "not in composerState: \(condition)")
            return state.distance(from: state.startIndex, to: site.lowerBound)
        }

        let classification: [(condition: String, answer: String, why: String)] = [
            // These three outrank `.controlling` in `state`, so each really does put its own
            // question on screen whatever else is happening.
            ("viewModel.visionCapturePreview != nil", "waitingOnYou", "a Safe-mode capture review is its own panel"),
            ("viewModel.visionDelegationRequest != nil", "waitingOnYou", "a Safe-mode delegation review is its own panel"),
            ("viewModel.visionSessionPause != nil", "waitingOnYou", "a session pause is its own panel"),
            // The fourth question, and since SONNY-255 it outranks the HUD like the three above it.
            ("viewModel.isAwaitingApproval", "waitingOnYou", "an approval takes the panel, session or no session"),
            // The HUD, which outranks the one below it and carries no question.
            ("viewModel.visionSessionProgress != nil", "working", "a live session shows a progress HUD, not a question"),
            // Reachable as a question only once no session is live — and unreachable *inside* one by
            // construction, which `state`'s own clarification branch records.
            ("viewModel.clarificationQuestion != nil", "waitingOnYou", "with no session live, the clarification panel is what renders"),
            ("viewModel.isRunning", "working", "an ordinary run in flight, whose panel is origin-gated")
        ]

        for row in classification {
            #expect(
                try answer(for: row.condition) == row.answer,
                "\(row.condition) must answer .\(row.answer) — \(row.why)"
            )
        }

        // **The ordering, stated as the dependency it is — and it points both ways** (SONNY-255).
        // The clarification may only be called `.waitingOnYou` after a live session has been ruled
        // out, because the HUD outranks it; moving it above that check reinstates F1 exactly. The
        // approval must sit on the *other* side, because it now outranks the HUD — leaving it below
        // would say "Sonny is working" over a panel holding a question, which is F1's mistake in
        // mirror image.
        let session = try position(of: "viewModel.visionSessionProgress != nil")
        #expect(
            try position(of: "viewModel.isAwaitingApproval") < session,
            "an approval outranks the HUD in `state`, so it is a question above the composer whether or not a session is live"
        )
        #expect(
            try session < position(of: "viewModel.clarificationQuestion != nil"),
            "a live session must be ruled out before a clarification is called a question above the composer"
        )

        // `viewModel.isRunning` is a prefix of nothing else here, so the population count is exact:
        // seven conditions, and an eighth fails this until somebody classifies it above.
        #expect(
            MacAgentSource.count(of: "viewModel.", inText: state) == classification.count,
            "a condition was added — classify it above"
        )
        #expect(classification.count == 7)

        // And the gate is the classification, not a second copy of it.
        let gate = try MacAgentSource.braceBlock(of: widget, openedBy: "private var isTaskInFlight: Bool {")
        #expect(MacAgentSource.count(of: "ComposerPresentation.acceptsInput(composerState)", inText: gate) == 1)
        #expect(MacAgentSource.count(of: "viewModel.", inText: gate) == 0, "the gate must not re-derive the state")
    }

    /// **The composer's classification is only true because of an ordering in a different property,
    /// so that ordering is pinned here** (PR #107 review, F1).
    ///
    /// `FloatingWidgetView.state` returns the *first* branch that matches, so the panel a user is
    /// looking at is whichever question outranks the rest. `composerState` mirrors that order, and
    /// its correctness is inherited rather than local — reorder `state` and the composer starts
    /// describing a panel that is not on screen, with nothing in its own file changed and nothing in
    /// the test above failing. That is exactly how F1 shipped, so the dependency gets an assertion
    /// rather than a sentence.
    ///
    /// The three Safe-mode questions and, since SONNY-255, the approval must stay *above*
    /// `.controlling`, because the composer calls all four questions unconditionally; the
    /// clarification must stay *below* it, because the composer rules a live session out before
    /// calling it a question at all.
    ///
    /// **The approval moved sides, which is what this ticket was.** It was below, and the composer
    /// was right to rule the session out first — the widget really did show the HUD over a pending
    /// question, for the whole length of every session. Fixing that in `state` and not here would
    /// leave the composer saying "Sonny is working" above a panel asking something, so the two moved
    /// together and this assertion is what says so.
    @Test
    func theWidgetsOwnPrecedenceIsWhatMakesTheComposersClassificationTrue() throws {
        let precedence = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "var state: WidgetState {"
        )

        func position(of branch: String) throws -> Int {
            let site = try #require(precedence.range(of: branch), "not in state: \(branch)")
            return precedence.distance(from: precedence.startIndex, to: site.lowerBound)
        }

        let controlling = try position(of: "return .controlling(progress)")

        for outranking in [
            "return .captureReview(preview)",
            "return .delegationReview(delegation)",
            "return .sessionPaused(pause)",
            "return .permission(approvalRequest)"
        ] {
            #expect(
                try position(of: outranking) < controlling,
                "\(outranking) is called a question above the composer unconditionally, so it must outrank the HUD"
            )
        }

        for outranked in [
            "return .clarification(question)"
        ] {
            #expect(
                controlling < (try position(of: outranked)),
                "the HUD outranks \(outranked), which is why the composer rules a live session out first"
            )
        }
    }

    /// **The field the user is meant to type into is the field that says so.**
    ///
    /// One scan, both halves, because they are one decision: the composer's prompt is read off
    /// `composerState` rather than written as a literal, and the field is disabled off the same
    /// state. A literal placeholder is what shipped, and it is what made a disabled composer
    /// indistinguishable from a hung one.
    @Test
    func theComposerReadsItsPlaceholderAndItsGateOffTheSameState() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let row = try MacAgentSource.braceBlock(of: widget, openedBy: "private var composerFieldRow: some View {")

        #expect(MacAgentSource.count(of: "ComposerPresentation.prompt(for: composerState)", inText: row) == 1)
        #expect(MacAgentSource.count(of: ".disabled(isTaskInFlight)", inText: row) == 1)
        // The literal is gone from the view and lives in `ComposerPresentation`, where a test can
        // read it. Counted across the whole file, not just this row, so it cannot reappear beside
        // the function that replaced it.
        #expect(MacAgentSource.count(of: "Let Sonny take it from here", inText: widget) == 0)
    }

    // MARK: - Where the caret goes

    /// **The caret follows the live field, and one owner decides which field that is** (SONNY-247,
    /// then SONNY-283).
    ///
    /// While a question is parked, the only field that can take a keystroke is the clarification
    /// panel's, and it never asked for focus: the composer below claimed it unconditionally on
    /// appear, on the hotkey and on every expand, and then refused every keystroke and every paste
    /// because it is `.disabled` in exactly that state (SONNY-247). The first fix gave each field a
    /// `Bool` of its own — the panel claimed the caret on appear, the composer's helper declined a
    /// dead field — which fixed the keyboard and left the push-to-talk hotkey doing nothing: its
    /// summon reached only the composer's helper, which rightly wrote `false` and had no other field
    /// to offer (SONNY-283). So the widget owns one `FocusState<WidgetInputField?>`, the panel takes
    /// a binding to it, and every summon asks `WidgetInputField.takingInput`. Every half is pinned,
    /// because any one alone leaves the caret in the wrong place.
    @Test
    func theWidgetOwnsTheCaretAndEverySummonAsksWhichFieldTakesIt() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")

        // One owner, and no field keeping a focus state of its own.
        #expect(MacAgentSource.count(of: "@FocusState private var focusedField: WidgetInputField?", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "@FocusState private var", inText: widget) == 1)
        #expect(MacAgentSource.count(of: "pillFocused", inText: widget) == 0)
        #expect(MacAgentSource.count(of: "answerFocused", inText: widget) == 0)

        // Two fields, each bound to that one state under its own case.
        let composerRow = try MacAgentSource.braceBlock(of: widget, openedBy: "private var composerFieldRow: some View {")
        #expect(MacAgentSource.count(of: ".focused($focusedField, equals: .composer)", inText: composerRow) == 1)

        let panel = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "private struct WidgetClarificationPanel: View {"
        )
        #expect(MacAgentSource.count(of: "@FocusState.Binding var focusedField: WidgetInputField?", inText: panel) == 1)
        #expect(MacAgentSource.count(of: ".focused($focusedField, equals: .clarificationAnswer)", inText: panel) == 1)
        // Two writers, and they are two events rather than one: the panel appearing, and a second
        // question arriving into a panel SwiftUI has kept the identity of.
        #expect(MacAgentSource.count(of: "focusedField = .clarificationAnswer", inText: panel) == 2)
        #expect(MacAgentSource.count(of: ".onChange(of: question)", inText: panel) == 1)
        // And the widget hands the panel its binding rather than a copy.
        #expect(MacAgentSource.count(of: "focusedField: $focusedField", inText: widget) == 1)

        // The summons' side: one helper, reading the rule off the same precedence that decides what
        // is drawn, and no unguarded writer to either field anywhere in the file.
        let helper = try MacAgentSource.braceBlock(of: widget, openedBy: "private func focusTheFieldThatTakesInput() {")
        #expect(MacAgentSource.count(of: "focusedField = WidgetInputField.takingInput(", inText: helper) == 1)
        #expect(MacAgentSource.count(of: "clarificationPanelShowing: isShowingClarificationPanel", inText: helper) == 1)
        #expect(MacAgentSource.count(of: "composer: composerState", inText: helper) == 1)
        #expect(MacAgentSource.count(of: "focusedField = .composer", inText: widget) == 0)
        #expect(MacAgentSource.count(of: "focusedField = nil", inText: widget) == 0)
        let showing = try MacAgentSource.braceBlock(of: widget, openedBy: "private var isShowingClarificationPanel: Bool {")
        #expect(MacAgentSource.count(of: "if case .clarification = state", inText: showing) == 1)
        // Its three callers: first render, the hotkey/menu-bar presentation request, and the expand
        // out of the compact capsule. The hotkey's is the one SONNY-283 was about.
        #expect(MacAgentSource.count(of: "focusTheFieldThatTakesInput()", inText: widget) == 4, "declaration plus three callers")
        let presentation = try MacAgentSource.region(
            of: widget,
            from: ".onChange(of: viewModel.widgetPresentationRequest) { _, _ in",
            to: ".onChange(of: isMicHintSlotFree)"
        )
        #expect(MacAgentSource.count(of: "focusTheFieldThatTakesInput()", inText: presentation) == 1)
    }

    /// **The rule itself, off the view** (SONNY-283): a parked question's field wins outright, the
    /// composer takes the caret only when it is free, and everything else leaves it nowhere.
    ///
    /// The last case is the manual item's "the caret still never jumps to the disabled composer",
    /// stated as the function that decides it: with the clarification panel showing, no composer
    /// state — not even `.ready`, which the two cannot produce together — puts the caret in the
    /// composer.
    @Test
    func theCaretGoesToTheAnswerFieldWhileAQuestionIsParkedAndToTheComposerOnlyWhenItIsFree() {
        #expect(WidgetInputField.takingInput(clarificationPanelShowing: true, composer: .waitingOnYou) == .clarificationAnswer)
        #expect(WidgetInputField.takingInput(clarificationPanelShowing: false, composer: .ready) == .composer)
        #expect(
            WidgetInputField.takingInput(clarificationPanelShowing: false, composer: .waitingOnYou) == nil,
            "an approval's panel has no field to type into"
        )
        #expect(WidgetInputField.takingInput(clarificationPanelShowing: false, composer: .working) == nil)

        for state in ComposerPresentation.State.allCases {
            #expect(
                WidgetInputField.takingInput(clarificationPanelShowing: true, composer: state) == .clarificationAnswer,
                "with a question parked the caret never reaches the composer, whatever the composer says (\(state))"
            )
        }
        #expect(
            ComposerPresentation.State.allCases
                .filter { WidgetInputField.takingInput(clarificationPanelShowing: false, composer: $0) == .composer }
                == [.ready],
            "exactly one composer state takes the caret, and it is the one that accepts input"
        )
    }
}
