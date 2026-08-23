import Foundation
import Testing
@testable import MacAgentCore

/// The shape of a clarified command (SONNY-248), at the type that owns it.
///
/// The behaviour these back is asserted end to end on the real dispatch path in
/// `ClarificationKeepsTheRequestTests` — a run really pauses on a question, the answer really goes
/// through `start()`, and the planner's prompt, the label and the stored record are read back. This
/// suite is the format's own unit: it can put the pathological inputs in directly, which a run
/// cannot be made to produce.
@Suite
struct ClarifiedCommandTests {
    private static let request = "zip my three largest files"

    @Test
    func aClarifiedCommandIsTheRequestFollowedByTheExchange() {
        let composed = ClarifiedCommand.composed(
            request: Self.request,
            question: "Which folder should I scan?",
            answer: "The Desktop"
        )

        // The literal shape, once, because everything else in this file is derived from it: the
        // request first, a blank line, then a labelled line each for the question and the answer.
        #expect(composed == """
        zip my three largest files

        Clarification question: Which folder should I scan?
        Clarification answer: The Desktop
        """)
        // And it is the request that leads, which is the whole of what SONNY-248 restored — the
        // three surfaces that read a command all take its head.
        #expect(composed.hasPrefix(Self.request))
    }

    /// **The two-question case, which is the one a naive fix still gets wrong.** Answering composes
    /// from what the *paused run* was submitted with, and after one answer that is already request +
    /// first pair — so the second answer appends rather than replaces, and the request is still at
    /// the front of a command that has now been clarified twice.
    @Test
    func aSecondClarificationAccumulatesRatherThanReplacingTheFirst() throws {
        let once = ClarifiedCommand.composed(
            request: Self.request,
            question: "Which folder should I scan?",
            answer: "The Desktop"
        )
        let twice = ClarifiedCommand.composed(
            request: once,
            question: "Zip them where?",
            answer: "Into Downloads"
        )

        #expect(twice.hasPrefix(Self.request))
        #expect(twice.contains("Clarification answer: The Desktop"))
        #expect(twice.contains("Clarification answer: Into Downloads"))
        // In the order the conversation happened, not merely both present.
        let first = try #require(twice.range(of: "Which folder should I scan?"))
        let second = try #require(twice.range(of: "Zip them where?"))
        #expect(first.lowerBound < second.lowerBound)
        // Two exchanges, not one overwritten and not one nested inside the other.
        #expect(twice.components(separatedBy: ClarifiedCommand.questionLabel).count == 3)
    }

    /// **A question that wraps onto two lines is still one exchange** (PR #109 re-check).
    ///
    /// The pair rule was justified as "the shape `composed` always writes", and `composed` did not
    /// always write it: it interpolates the question verbatim, `AgentActionExecutor` only
    /// *end*-trims it, and `AgentStep.question` is model-authored free text — so an interior line
    /// break survives all the way here and pushes the answer off the question's next line. Both of
    /// this ticket's symptoms came back for such a question: the clarified command went to
    /// `InstantCommandResolver`, and the resume offer named Sonny's question, which is the founder's
    /// original report.
    @Test
    func aQuestionThatWrapsOntoTwoLinesIsStillOneExchange() {
        let composed = ClarifiedCommand.composed(
            request: Self.request,
            question: "Which folder should I scan?\nDesktop or Downloads?",
            answer: "The Desktop"
        )

        #expect(ClarifiedCommand.carriesExchange(composed))
        #expect(ClarifiedCommand.request(in: composed) == Self.request)
        // The whole question is still there for the planner — folded, not truncated.
        #expect(composed.contains("Which folder should I scan?"))
        #expect(composed.contains("Desktop or Downloads?"))
    }

    /// **The fold takes `CharacterSet.newlines`, not `\n`** — the same reasoning
    /// `PriorTaskContext.foldingLineBreaks` gives for the same job. A plan arrives as
    /// JSON-serialised UTF-8, so every one of these survives the wire intact and any of them can
    /// begin a line where the composed command is read back.
    @Test
    func everyKindOfLineBreakInAQuestionIsFolded() {
        for (name, breakCharacter) in [
            ("LF", "\u{000A}"), ("VT", "\u{000B}"), ("FF", "\u{000C}"), ("CR", "\u{000D}"),
            ("CRLF", "\u{000D}\u{000A}"), ("NEL", "\u{0085}"),
            ("line separator", "\u{2028}"), ("paragraph separator", "\u{2029}")
        ] {
            let composed = ClarifiedCommand.composed(
                request: Self.request,
                question: "Which folder?\(breakCharacter)Desktop or Downloads?",
                answer: "The Desktop"
            )

            #expect(ClarifiedCommand.carriesExchange(composed), "\(name) broke the pair")
            #expect(ClarifiedCommand.request(in: composed) == Self.request, "\(name) truncated the request")
        }
    }

    /// The user's own words are **not** folded, and that asymmetry is the point: a multi-line answer
    /// is safe under the pair rule because it follows its question line, while a multi-line question
    /// splits the pair. Folding the answer too would edit what the user typed for no gain.
    @Test
    func aMultiLineAnswerIsLeftAloneAndStillReadsAsOneExchange() {
        let composed = ClarifiedCommand.composed(
            request: Self.request,
            question: "Which folder should I scan?",
            answer: "The Desktop\nand the Downloads folder"
        )

        #expect(ClarifiedCommand.carriesExchange(composed))
        #expect(ClarifiedCommand.request(in: composed) == Self.request)
        #expect(composed.contains("The Desktop\nand the Downloads folder"))
    }

    /// An empty request degrades to the exchange alone — the shape this produced for *every*
    /// clarification before the fix, kept deliberately for a question no real run raised.
    @Test
    func anAbsentRequestLeavesTheExchangeAloneRatherThanInventingOne() {
        let composed = ClarifiedCommand.composed(
            request: "   \n  ",
            question: "Which folder should I scan?",
            answer: "The Desktop"
        )

        #expect(composed.hasPrefix(ClarifiedCommand.questionLabel))
        #expect(!composed.hasPrefix("\n"))
        // Still recognisable as carrying an exchange, so the dispatch path keeps it away from the
        // instant resolver even in the degraded case.
        #expect(ClarifiedCommand.carriesExchange(composed))
        // And there is no request to pull back out, so the label keeps what it has rather than
        // becoming blank.
        #expect(ClarifiedCommand.request(in: composed) == composed)
    }

    @Test
    func anOrdinaryCommandCarriesNoExchangeAndIsItsOwnLabel() {
        #expect(!ClarifiedCommand.carriesExchange(Self.request))
        #expect(ClarifiedCommand.request(in: Self.request) == Self.request)
        // A multi-line command is untouched too — the split is on the exchange, not on newlines.
        let dictated = "zip my three largest files\nand then open the folder"
        #expect(!ClarifiedCommand.carriesExchange(dictated))
        #expect(ClarifiedCommand.request(in: dictated) == dictated)
    }

    /// The label surfaces get the request back out, including from a command clarified twice — the
    /// case where the naive "take the first line" would be right by accident and "take everything
    /// before the last exchange" would be wrong.
    @Test
    func theLabelIsTheRequestHoweverManyTimesTheTaskWasClarified() {
        let once = ClarifiedCommand.composed(
            request: "zip my three largest files\nand then open the folder",
            question: "Which folder should I scan?",
            answer: "The Desktop"
        )
        let twice = ClarifiedCommand.composed(
            request: once,
            question: "Zip them where?",
            answer: "Into Downloads"
        )

        #expect(ClarifiedCommand.request(in: once) == "zip my three largest files\nand then open the folder")
        #expect(ClarifiedCommand.request(in: twice) == "zip my three largest files\nand then open the folder")
    }

    /// **Matched at the start of a line, so a request that mentions the words is still a request.**
    /// The mention has to survive as the label, or a user asking Sonny about clarification questions
    /// would see their own sentence cut in half.
    @Test
    func aRequestThatMentionsTheWordsMidLineIsNotMistakenForAnExchange() {
        let mentioning = "explain what a Clarification question: prefix means"

        #expect(!ClarifiedCommand.carriesExchange(mentioning))
        #expect(ClarifiedCommand.request(in: mentioning) == mentioning)
    }

    /// **A lone question label is not an exchange, and the reason is that this truncates a payload**
    /// (PR #109 review F3).
    ///
    /// The first version matched a single `Clarification question:` line and called being wrong
    /// "the safe direction" — which is true of `carriesExchange`, where the cost is planning a
    /// command instead of resolving it locally, and false of `request(in:)`, whose output is what
    /// `runTaskAgain` resubmits and what `followUpOnTask` hands a later planner. So a command of the
    /// user's own that begins a line that way lost everything after it, and Run again would have
    /// sent the truncated half.
    @Test
    func aLoneQuestionLabelIsNotAnExchangeBecauseThisTruncatesWhatRunAgainResubmits() {
        let typed = "draft the doc with these headings\nClarification question: what to ask"

        #expect(!ClarifiedCommand.carriesExchange(typed))
        // The whole command survives — the half after the label included.
        #expect(ClarifiedCommand.request(in: typed) == typed)
    }

    /// The other side of the pair rule: both labels on consecutive lines *is* an exchange, whoever
    /// wrote them. This is the residual the doc comment states rather than a case anything prevents —
    /// a user who types the pair collides with the format, and the only real fix for that family is
    /// an unguessable delimiter (SONNY-234's shape), which this string does not warrant.
    @Test
    func bothLabelsOnConsecutiveLinesAreReadAsAnExchangeWhoeverWroteThem() {
        let typed = "do the thing\nClarification question: what did I mean?\nClarification answer: this"

        #expect(ClarifiedCommand.carriesExchange(typed))
        #expect(ClarifiedCommand.request(in: typed) == "do the thing")
    }

    /// A question label separated from its answer by a blank line is not the shape `composed`
    /// writes, so it is not an exchange either. Pins the adjacency rather than merely "an answer
    /// appears somewhere below".
    @Test
    func aQuestionLabelSeparatedFromItsAnswerIsNotAnExchange() {
        let straddled = "do the thing\nClarification question: what did I mean?\n\nClarification answer: this"

        #expect(!ClarifiedCommand.carriesExchange(straddled))
        #expect(ClarifiedCommand.request(in: straddled) == straddled)
    }
}
