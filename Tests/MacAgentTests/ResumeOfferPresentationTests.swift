import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The widget's offer to carry on with an unfinished task (row 13, SONNY-210) — its copy, and the
/// two wirings the founder's sign-off named as constraints.
///
/// The wiring pins are source scans because there is no way to drive SwiftUI here and no object to
/// interrogate: what is being held is where a branch sits in a precedence, and which token set a
/// panel is built from. `MacAgentSource.read` strips both comment syntaxes, so neither can be
/// satisfied by a sentence describing the code.
@MainActor
struct ResumeOfferPresentationTests {
    // MARK: - The copy

    /// The founder's own sentence, 2026-08-22: "you were partway through X, continue?" — the message
    /// is the first half and the button label is the second.
    @Test
    func theOfferNamesTheTaskAndTheButtonIsTheQuestionsAnswer() {
        #expect(
            ResumeOfferPresentation.message(command: "Zip my three largest files")
                == "You were partway through \u{201C}Zip my three largest files\u{201D}."
        )
        #expect(ResumeOfferPresentation.continueLabel == "Continue")
        #expect(ResumeOfferPresentation.dismissLabel == "Not now")
    }

    /// A long command is cut at a word boundary rather than mid-word, at this panel's own width.
    @Test
    func aLongCommandIsTruncatedAtAWordBoundary() {
        let long = "Zip my three largest files and then convert every document in the project folder to PDF"
        let truncated = ResumeOfferPresentation.truncatedCommand(long)

        #expect(truncated.count <= 61, "60 characters plus the ellipsis")
        #expect(truncated.hasSuffix("\u{2026}"))
        #expect(!truncated.dropLast().hasSuffix(" "), "cut at the space, not after it")
        #expect(long.hasPrefix(String(truncated.dropLast())))
    }

    /// **The squeeze the truncation alone cannot do.** A short first line followed by ten more is
    /// under any character budget and still eleven lines tall, which a pasted or dictated command
    /// really can be — and this panel is a fixed 472pt with one sentence in it.
    @Test
    func aMultiLineCommandBecomesOneLine() {
        let pasted = "Zip my files\n\nthen open the report\n  and email it"
        #expect(
            ResumeOfferPresentation.truncatedCommand(pasted)
                == "Zip my files then open the report and email it"
        )
    }

    /// Unreachable from a live run — `canSubmit` refuses an empty command — and answered anyway,
    /// because this text comes back off disk.
    @Test
    func aCommandlessRecordStillReadsAsASentence() {
        #expect(
            ResumeOfferPresentation.message(command: "   \n  ")
                == "You were partway through \u{201C}an untitled task\u{201D}."
        )
    }

    /// Nothing here explains how resuming works, per the founder's rule of 2026-08-14 — not which
    /// steps are left, not that a unit may re-run, not why the task stopped. What happened to the
    /// task is data and lives in the Memory row that lists it.
    @Test
    func noneOfTheOffersCopyExplainsHowItWorks() {
        let copy = [
            ResumeOfferPresentation.message(command: "Zip my files"),
            ResumeOfferPresentation.continueLabel,
            ResumeOfferPresentation.dismissLabel,
            ResumeOfferPresentation.continueAccessibilityLabel(command: "Zip my files"),
            ResumeOfferPresentation.dismissAccessibilityLabel(command: "Zip my files")
        ]
        let explanatory = ["step", "resume", "because", "Sonny will", "so that", "this means", "automatically"]
        for sentence in copy {
            for phrase in explanatory {
                #expect(
                    !sentence.localizedCaseInsensitiveContains(phrase),
                    "\u{201C}\(sentence)\u{201D} explains rather than asks"
                )
            }
        }
    }

    // MARK: - The two constraints the widget placement creates

    /// **System B only.** The floating widget's tokens are `WidgetTheme`/`WidgetType`; `SonnyTheme`
    /// and `SonnyType` are Command Center's and the two sets are deliberately separate rather than
    /// variants of each other. The founder restated the constraint on this specific panel when
    /// signing the design off on 2026-08-22, so it is held rather than assumed.
    @Test
    func theOfferPanelIsBuiltFromSystemBTokensOnly() throws {
        let panel = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private struct WidgetResumeOfferPanel: View {"
        )

        #expect(panel.contains("WidgetTheme."))
        #expect(panel.contains("WidgetType."))
        #expect(!panel.contains("SonnyTheme."), "System A tokens do not belong in the widget")
        #expect(!panel.contains("SonnyType."))
        #expect(!panel.contains("SonnyRadius."))
    }

    /// **Where the offer sits in the widget's precedence, pinned by position.**
    ///
    /// CLAUDE.md records this precedence as already delicate: it picks `.failure` ahead of `.result`,
    /// and a bookkeeping write failure routed into `errorMessage` twice replaced the result of a task
    /// that had succeeded. The offer is a fifth thing competing for the same panel, and the whole of
    /// its safety is that it is below every state describing the task the user is doing *now*. A
    /// branch moved above `.failure` would hide the reason a run stopped behind an offer to try
    /// again; above `.result` it would displace a finished task's answer.
    ///
    /// Asserted by *order within the property*, not by presence: a token can be added by a trailing
    /// comment, and presence would be satisfied by a branch sitting anywhere at all.
    @Test
    func theOfferIsTheLastBranchOfTheWidgetsPrecedenceBeforeIdle() throws {
        let state = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            openedBy: "private var state: WidgetState {"
        )

        let failure = try #require(state.range(of: "return .failure(error)"))
        let result = try #require(state.range(of: "return .result(viewModel.finalSummary, suggestion)"))
        let offer = try #require(state.range(of: "return .resumeOffer(offer)"))
        let idle = try #require(state.range(of: "return .idle"))

        #expect(failure.lowerBound < offer.lowerBound, "a failure outranks the offer")
        #expect(result.lowerBound < offer.lowerBound, "a result outranks the offer")
        #expect(offer.lowerBound < idle.lowerBound, "the offer outranks nothing but idle")
    }

    /// `AgentViewModel.hasVisibleWidgetPanel` mirrors that precedence and the widget's panel does not
    /// render without it — so the offer's branch has to sit in the same place there too, after the
    /// summary check and before the final `false`.
    @Test
    func theViewModelsPanelPredicatePutsTheOfferInTheSamePlace() throws {
        let predicate = try MacAgentSource.braceBlock(
            of: MacAgentSource.read("AgentViewModel.swift"),
            openedBy: "var hasVisibleWidgetPanel: Bool {"
        )

        let summary = try #require(predicate.range(of: "if !finalSummary.isEmpty {"))
        let offer = try #require(predicate.range(of: "if resumeOffer != nil {"))
        let end = try #require(predicate.range(of: "return false"))

        #expect(summary.lowerBound < offer.lowerBound)
        #expect(offer.lowerBound < end.lowerBound)
    }
}
