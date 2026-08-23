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

    /// The documented limit, asserted rather than left as a claim: a label typed at the start of a
    /// line of the user's own *is* read as an exchange. It costs them the instant resolver — their
    /// command is planned instead — and it is the direction that fails safe, which is why the cheap
    /// line-start rule was chosen over a stricter one nothing else needs.
    @Test
    func aLabelTypedAtTheStartOfALineIsReadAsAnExchangeAndThatIsTheSafeDirection() {
        let typed = "do the thing\nClarification question: what did I mean?"

        #expect(ClarifiedCommand.carriesExchange(typed))
        #expect(ClarifiedCommand.request(in: typed) == "do the thing")
    }
}
