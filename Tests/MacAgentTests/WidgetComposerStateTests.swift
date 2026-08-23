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
    /// them alike. `waitingOnYou` points at the panel above; `working` does not, and must not — the
    /// running branch of `hasVisibleWidgetPanel` is origin-gated, so a Command-Center-originated run
    /// shows no widget panel and a sentence saying "above" would point at empty space.
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

    /// **Every condition the composer disables on is classified, and the classification is the gate.**
    ///
    /// Modelled on `everyDispatchDoorIsClassifiedAndTheClassificationIsChecked` in the sibling file,
    /// and for the same reason: a scan that only counts a population lets a condition sit in the
    /// wrong bucket while reading as coverage. So each of the seven is named with the answer it is
    /// supposed to give, the answer is read off the branch it actually sits in, and the count
    /// underneath is what forces an eighth into the table rather than past it.
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
            openedBy: "private var composerState: ComposerPresentation.State {"
        )

        // Split at the two returns rather than with `region(of:from:to:)`, which excludes its own
        // start anchor — and the start anchor here would be one of the conditions being classified.
        let waitingReturn = try #require(state.range(of: "return .waitingOnYou"), "no .waitingOnYou branch")
        let workingReturn = try #require(state.range(of: "return .working"), "no .working branch")
        let waitingBranch = String(state[state.startIndex..<waitingReturn.lowerBound])
        let workingBranch = String(state[waitingReturn.upperBound..<workingReturn.lowerBound])

        // A question parked on the user. Each of these makes `hasVisibleWidgetPanel` true before it
        // reaches any origin gate, so the panel "above" is always really there.
        let waitingOnYou = [
            "viewModel.isAwaitingApproval",
            "viewModel.clarificationQuestion != nil",
            "viewModel.visionCapturePreview != nil",
            "viewModel.visionDelegationRequest != nil",
            "viewModel.visionSessionPause != nil"
        ]
        // A run in flight with nothing to type into, and no guaranteed panel.
        let working = [
            "viewModel.isRunning",
            "viewModel.visionSessionProgress != nil"
        ]

        for condition in waitingOnYou {
            #expect(
                MacAgentSource.count(of: condition, inText: waitingBranch) == 1,
                "\(condition) is a question parked on the user and belongs in the .waitingOnYou branch"
            )
            #expect(
                MacAgentSource.count(of: condition, inText: workingBranch) == 0,
                "\(condition) has a control above the composer — it is not a bare run in flight"
            )
        }
        for condition in working {
            #expect(
                MacAgentSource.count(of: condition, inText: workingBranch) == 1,
                "\(condition) is a run in flight and belongs in the .working branch"
            )
        }

        // `viewModel.isRunning` is a prefix of nothing else here, so the population count is exact:
        // seven conditions, and an eighth fails this until somebody classifies it above.
        let conditions = MacAgentSource.count(of: "viewModel.", inText: state)
        #expect(conditions == waitingOnYou.count + working.count, "a condition was added — classify it above")

        // And the gate is the classification, not a second copy of it.
        let gate = try MacAgentSource.braceBlock(of: widget, openedBy: "private var isTaskInFlight: Bool {")
        #expect(MacAgentSource.count(of: "ComposerPresentation.acceptsInput(composerState)", inText: gate) == 1)
        #expect(MacAgentSource.count(of: "viewModel.", inText: gate) == 0, "the gate must not re-derive the state")
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

    /// **The caret follows the live field** — the half of the fix that makes the other half rarely
    /// matter.
    ///
    /// While a question is parked, the only field that can take a keystroke is the clarification
    /// panel's, and it never asked for focus: the composer below claimed it unconditionally on
    /// appear, on the hotkey and on every expand, and then refused every keystroke and every paste
    /// because it is `.disabled` in exactly that state. Both halves are pinned, because either alone
    /// leaves the caret in the wrong place: the panel has to claim it, and the composer has to stop
    /// taking it back.
    @Test
    func theClarificationPanelClaimsTheCaretAndTheComposerOnlyTakesItWhenItCanUseIt() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let panel = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "private struct WidgetClarificationPanel: View {"
        )

        #expect(MacAgentSource.count(of: "@FocusState private var answerFocused: Bool", inText: panel) == 1)
        #expect(MacAgentSource.count(of: ".focused($answerFocused)", inText: panel) == 1)
        // Two writers, and they are two events rather than one: the panel appearing, and a second
        // question arriving into a panel SwiftUI has kept the identity of.
        #expect(MacAgentSource.count(of: "answerFocused = true", inText: panel) == 2)
        #expect(MacAgentSource.count(of: ".onChange(of: question)", inText: panel) == 1)

        // The composer's side: one guarded writer, and no unguarded one anywhere in the file.
        let focusHelper = try MacAgentSource.braceBlock(
            of: widget,
            openedBy: "private func focusComposerIfItTakesInput() {"
        )
        #expect(
            MacAgentSource.count(of: "pillFocused = ComposerPresentation.acceptsInput(composerState)", inText: focusHelper) == 1
        )
        #expect(MacAgentSource.count(of: "pillFocused = true", inText: widget) == 0)
        // Its three callers: first render, the hotkey/menu-bar presentation request, and the expand
        // out of the compact capsule.
        #expect(MacAgentSource.count(of: "focusComposerIfItTakesInput()", inText: widget) == 4, "declaration plus three callers")
    }
}
