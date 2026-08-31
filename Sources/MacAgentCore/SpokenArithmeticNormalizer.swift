import Foundation

/// Translates common spoken number-words and operator idioms ("two into two") into the digit/symbol
/// form `ArithmeticParser` already understands ("2 * 2"). Runs as a preprocessing pass ahead of both
/// arithmetic and conversion parsing in `CalculatorService.evaluate(_:)`, so "ten cm to in" normalizes
/// too, not just arithmetic.
///
/// Deliberately bounded, not general NLP: whole numbers zero through nine hundred ninety-nine, plus
/// the operator idioms people actually say out loud ("into"/"times"/"multiplied by", "divided
/// by"/"over", "plus", "minus"/"take away"). Anything else — numbers above 999, decimal/fraction
/// words ("point five", "a half"), standalone negative-number words ("negative five"), filler words
/// ("what is") — passes through unchanged and still fails with the parser's normal, honest error
/// rather than silently guessing. That's a stated scope boundary, not an oversight.
///
/// **The filler words are somebody else's job, and since SONNY-284 somebody does it.**
/// `InstantCommandResolver` takes a bounded list of lead-in and tail-off phrases off a *command*
/// before deciding it is a calculation at all, and hands this normalizer only what is left — so
/// "what is two plus two" is answered without this file learning what "what is" means. Which is the
/// layer the stripping belongs at: a command is the thing that can be a calculation or an
/// instruction, and an expression is already known to be neither.
enum SpokenArithmeticNormalizer {
    private static let onesAndTeens: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19
    ]

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90
    ]

    private static let twoWordOperators: [String: String] = [
        "multiplied by": "*",
        "divided by": "/",
        "take away": "-"
    ]

    private static let oneWordOperators: [String: String] = [
        "into": "*", "times": "*", "plus": "+", "minus": "-", "over": "/"
    ]

    /// Punctuation Whisper transcription actually appends (sentence-ending marks) — deliberately not
    /// the full `.punctuationCharacters` set, which also contains "(" / ")" and would otherwise
    /// silently swallow parentheses glued to a word-number token (e.g. "(two" → "two").
    ///
    /// **`InstantCommandResolver` reads this too** (SONNY-284's fix round, F1), for the end of a
    /// dictated *sentence* rather than the end of a token — so there is one list of what a
    /// transcriber appends rather than two that drift. It is trimmed off the trailing end only
    /// there: a leading `.` is a decimal point, and `.5 + 1` trimmed at both ends is `6` instead
    /// of `1.5`.
    static let trimmablePunctuation = CharacterSet(charactersIn: ".,!?;:")

    static func normalize(_ expression: String) -> String {
        let rawTokens = expression
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !rawTokens.isEmpty else {
            return expression
        }

        var output: [String] = []
        var index = 0
        while index < rawTokens.count {
            if index + 1 < rawTokens.count,
               let symbol = twoWordOperators["\(key(rawTokens[index])) \(key(rawTokens[index + 1]))"] {
                output.append(symbol)
                index += 2
                continue
            }

            if let symbol = oneWordOperators[key(rawTokens[index])] {
                output.append(symbol)
                index += 1
                continue
            }

            if let run = numberWordRun(startingAt: index, in: rawTokens) {
                output.append(String(run.value))
                index += run.consumed
                continue
            }

            output.append(rawTokens[index])
            index += 1
        }

        return output.joined(separator: " ")
    }

    /// Greedily consumes a run of number-words (ones/teens/tens/"hundred", with "and" only as an
    /// interior connector directly followed by another number-word) starting at `start`. Returns nil
    /// if `start` isn't the beginning of a number-word at all, so callers fall through to passthrough.
    private static func numberWordRun(
        startingAt start: Int,
        in tokens: [String]
    ) -> (value: Int, consumed: Int)? {
        var index = start
        var current = 0
        var matchedAny = false

        while index < tokens.count {
            let word = key(tokens[index])
            if let value = onesAndTeens[word] {
                current += value
                matchedAny = true
            } else if let value = tensWords[word] {
                current += value
                matchedAny = true
            } else if word == "hundred" {
                current = (current == 0 ? 1 : current) * 100
                matchedAny = true
            } else if word == "and", matchedAny, index + 1 < tokens.count,
                      isNumberWord(key(tokens[index + 1])) {
                // Interior connector ("one hundred and five") — skip without changing `current`.
            } else {
                break
            }
            index += 1
        }

        guard matchedAny else {
            return nil
        }
        return (current, index - start)
    }

    private static func isNumberWord(_ word: String) -> Bool {
        onesAndTeens[word] != nil || tensWords[word] != nil || word == "hundred"
    }

    private static func key(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: Self.trimmablePunctuation)
    }
}
