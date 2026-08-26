import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct CalculatorServiceTests {
    private let calculator = CalculatorService()

    @Test
    func evaluatesDigitExpressionsUnchanged() throws {
        #expect(try calculator.evaluate("2 + 2 * 3").result == "8")
        #expect(try calculator.evaluate("(2 + 2) * 3").result == "12")
        #expect(try calculator.evaluate("2+2*3").result == "8")
    }

    @Test
    func evaluatesSpokenOperatorIdioms() throws {
        #expect(try calculator.evaluate("two into two").result == "4")
        #expect(try calculator.evaluate("two times two").result == "4")
        #expect(try calculator.evaluate("ten multiplied by two").result == "20")
        #expect(try calculator.evaluate("six divided by two").result == "3")
        #expect(try calculator.evaluate("six over two").result == "3")
        #expect(try calculator.evaluate("two plus two").result == "4")
        #expect(try calculator.evaluate("five minus two").result == "3")
        #expect(try calculator.evaluate("ten take away two").result == "8")
    }

    @Test
    func evaluatesCompoundSpokenNumbers() throws {
        #expect(try calculator.evaluate("twenty two plus one").result == "23")
        #expect(try calculator.evaluate("one hundred plus five").result == "105")
        #expect(try calculator.evaluate("one hundred and five plus two").result == "107")
        #expect(try calculator.evaluate("nine hundred ninety nine plus one").result == "1000")
    }

    @Test
    func toleratesTrailingPunctuationFromVoiceTranscription() throws {
        #expect(try calculator.evaluate("two into two.").result == "4")
        #expect(try calculator.evaluate("Two Into Two").result == "4")
    }

    /// The sign a person types at the end of a sum, and the question mark after it (SONNY-281).
    @Test
    func toleratesTheEqualsSignTypedAtTheEndOfASum() throws {
        #expect(try calculator.evaluate("2 + 2 =").result == "4")
        #expect(try calculator.evaluate("2 + 2 =").expression == "2 + 2")
        #expect(try calculator.evaluate("2+2=?").result == "4")
        #expect(try calculator.evaluate("2 + 2?").result == "4")
        #expect(try calculator.evaluate("two plus two =").result == "4")
        let bare = try calculator.evaluate("10 cm to in")
        #expect(try calculator.evaluate("10 cm to in =").result == bare.result)
    }

    /// At the end only: an interior sign is a statement and fails as one, and a sign with nothing in
    /// front of it is a missing expression rather than a sum of nothing.
    @Test
    func anEqualsSignAnywhereButTheEndIsStillRefused() throws {
        #expect(throws: CalculatorError.invalidExpression("Unexpected token =.")) {
            try calculator.evaluate("2 + 2 = 4")
        }
        #expect(throws: CalculatorError.missingExpression) {
            try calculator.evaluate("=")
        }
        #expect(throws: CalculatorError.missingExpression) {
            try calculator.evaluate(" = = ? ")
        }
    }

    /// The rule is one function, read by the evaluator and by the resolver's bare-arithmetic rule —
    /// a definition kept in one of the two leaves the other refusing input the first accepts.
    @Test
    func theTrailingSignRuleIsOneFunction() {
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("2 + 2 =") == "2 + 2")
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("  2 + 2 = ? ") == "2 + 2")
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("2 + 2 = 4") == "2 + 2 = 4")
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("==?") == "")
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("2 + 2") == "2 + 2")
        #expect(CalculatorService.withoutTrailingEqualsOrQuestionMark("2 + 2\n") == "2 + 2")
    }

    @Test
    func spokenUnitConversionsAlsoNormalize() throws {
        let spoken = try calculator.evaluate("ten centimeters to inches")
        let digits = try calculator.evaluate("10 cm to in")
        #expect(spoken.result == digits.result)
    }

    @Test
    func doesNotStripFillerWordsByDesign() throws {
        // "what is" is neither a number-word nor an operator idiom, so this still fails cleanly —
        // full command-style phrasing is out of scope; only the arithmetic phrase itself normalizes.
        #expect(throws: CalculatorError.self) {
            try calculator.evaluate("what is two plus two")
        }
    }

    @Test
    func stillThrowsOnEmptyExpression() throws {
        #expect(throws: CalculatorError.self) {
            try calculator.evaluate("   ")
        }
    }
}

@Suite
struct SpokenArithmeticNormalizerTests {
    @Test
    func passesThroughExpressionsWithNoWordsUnchanged() {
        #expect(SpokenArithmeticNormalizer.normalize("2+2*3") == "2+2*3")
        #expect(SpokenArithmeticNormalizer.normalize("(2 + 2) * 3") == "(2 + 2) * 3")
    }

    @Test
    func normalizesOperatorIdioms() {
        #expect(SpokenArithmeticNormalizer.normalize("two into two") == "2 * 2")
        #expect(SpokenArithmeticNormalizer.normalize("six divided by two") == "6 / 2")
        #expect(SpokenArithmeticNormalizer.normalize("ten multiplied by two") == "10 * 2")
        #expect(SpokenArithmeticNormalizer.normalize("ten take away two") == "10 - 2")
    }

    @Test
    func normalizesCompoundNumberWords() {
        #expect(SpokenArithmeticNormalizer.normalize("twenty two") == "22")
        #expect(SpokenArithmeticNormalizer.normalize("one hundred and five") == "105")
        #expect(SpokenArithmeticNormalizer.normalize("nine hundred ninety nine") == "999")
    }

    @Test
    func leavesUnrecognizedWordsAsPassthrough() {
        #expect(SpokenArithmeticNormalizer.normalize("what is two plus two") == "what is 2 + 2")
    }
}
