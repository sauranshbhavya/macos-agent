import Testing
@testable import MacAgentCore

/// The rule `LatinConfusables` states and `scripts/confusables-table` implements, held from both
/// sides — what folds, and what deliberately does not — so that a hand edit to the generated block,
/// a regenerated block with a widened filter, or a fold that quietly reached ASCII fails here rather
/// than being noticed on a painted screen.
///
/// Every scalar below is a `\u{}` escape, never a pasted character (`.claude/rules/macagentcore-conventions.md`).
struct LatinConfusablesTests {
    private static func scalar(_ value: UInt32) -> Unicode.Scalar {
        Unicode.Scalar(value)!
    }

    /// The reading SONNY-260 measured at 820 px, one scalar at a time: the four substitutions Vision
    /// made for `a`, `A`, `o` and `r`. The last one folds to `i`, not `r` — a dotless i looks like an
    /// i, and the fold restores what the glyph *looks like*, which is all a pattern needs from it.
    @Test
    func theFourReadingsSONNY260MeasuredFoldToTheLettersTheyLookLike() {
        #expect(LatinConfusables.fold(Self.scalar(0x0430)) == "a")
        #expect(LatinConfusables.fold(Self.scalar(0x0410)) == "A")
        #expect(LatinConfusables.fold(Self.scalar(0x043E)) == "o")
        #expect(LatinConfusables.fold(Self.scalar(0x0131)) == "i")
    }

    /// Rule 6: a capital that looks like a capital I folds to `I`, not to the `l` UTS #39 names as
    /// the prototype of its merged I/l/1 class — the recognizer said "capital", and `AKIA` needs it
    /// back as one (PR #116 review, F1). The lowercase and caseless members of the same class still
    /// fold to `l`, and the dotted Cyrillic small i to `i`.
    @Test
    func capitalLookAlikesOfIFoldToCapitalIAndTheOthersToL() {
        #expect(LatinConfusables.fold(Self.scalar(0x0406)) == "I")
        #expect(LatinConfusables.fold(Self.scalar(0x04C0)) == "I")
        #expect(LatinConfusables.fold(Self.scalar(0x0196)) == "I")
        #expect(LatinConfusables.fold(Self.scalar(0x04CF)) == "l")
        #expect(LatinConfusables.fold(Self.scalar(0x01C0)) == "l")
        #expect(LatinConfusables.fold(Self.scalar(0x0456)) == "i")
    }

    /// Rule 1 from the other side: nothing in ASCII ever folds — not `0` to `O`, not `1` to `l`, not
    /// `5` to `S`. That is the `5k-` flavour, and it is not approved.
    @Test
    func asciiIsNeverFolded() {
        for value in UInt32(0)..<0x80 {
            let scalar = Self.scalar(value)
            #expect(LatinConfusables.fold(scalar) == scalar, "U+\(String(value, radix: 16, uppercase: true)) folded")
        }
        #expect(LatinConfusables.table.keys.allSatisfy { $0 >= 0x80 })
    }

    /// Rule 4: UTS #39 says these look like letters, and they stay what they are — digits of other
    /// scripts, a multiplication sign, a box-drawing bar, a spacing ogonek, a combining mark.
    @Test
    func digitsSymbolsAndMarksOfOtherScriptsAreNotFolded() {
        for value: UInt32 in [0x0661, 0x06F1, 0x0E50, 0x3007, 0x00D7, 0xFFE8, 0x02DB, 0x0301, 0xFF10, 0xFF01] {
            let scalar = Self.scalar(value)
            #expect(LatinConfusables.fold(scalar) == scalar, "U+\(String(value, radix: 16, uppercase: true)) folded")
            #expect(LatinConfusables.table[value] == nil)
        }
    }

    /// Rule 5 from the other side: Greek alpha, capital alpha and omicron look exactly like `a`, `A`
    /// and `o`, and Vision's accurate recognizer lists no Greek language, so they are not folded. A
    /// regenerated table that widened the script rule would fail here first.
    @Test
    func scriptsVisionCannotEmitAreDeliberatelyNotFolded() {
        for value: UInt32 in [0x03B1, 0x0391, 0x03BF, 0x1D400, 0x13AA, 0x0585] {
            let scalar = Self.scalar(value)
            #expect(LatinConfusables.fold(scalar) == scalar, "U+\(String(value, radix: 16, uppercase: true)) folded")
            #expect(LatinConfusables.table[value] == nil)
        }
    }

    /// Rules 1, 3, 4 and 5 over the whole generated block, entry by entry. The block ranges are the
    /// generator's `BLOCKS` list, restated here so that the two cannot drift apart silently.
    @Test
    func everyTableEntryIsANonASCIILetterOfAScriptVisionCanEmitFoldingToAnASCIILetter() {
        let blocks: [ClosedRange<UInt32>] = [
            0x00A0...0x024F, 0x0250...0x02AF, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F,
            0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F, 0x1E030...0x1E08F,
            0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF,
            0x0E00...0x0E7F,
            0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x323AF
        ]
        let asciiLetters = Set(UInt8(ascii: "A")...UInt8(ascii: "Z")).union(UInt8(ascii: "a")...UInt8(ascii: "z"))
        for (source, target) in LatinConfusables.table {
            let name = "U+\(String(source, radix: 16, uppercase: true))"
            #expect(source >= 0x80, Comment(rawValue: name))
            #expect(asciiLetters.contains(target), Comment(rawValue: name))
            let scalar = Self.scalar(source)
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
                break
            default:
                Issue.record("\(name) is not a letter")
            }
            #expect(blocks.contains { $0.contains(source) }, "\(name) is outside every block Vision can emit")
            #expect(LatinConfusables.fold(scalar) == Unicode.Scalar(target), Comment(rawValue: name))
            // Rule 6, structurally: no capital in the table folds to a lowercase l.
            if scalar.properties.generalCategory == .uppercaseLetter {
                #expect(target != UInt8(ascii: "l"), "\(name) is a capital folding to l")
            }
        }
    }

    /// The population is the generator's, not a hand-maintained list: 98 entries
    /// (`grep -c '^        0x' Sources/MacAgentCore/LatinConfusables.swift`, from Unicode 17.0.0's
    /// `confusables.txt` dated 2025-07-22). An entry added or dropped by hand moves this, and the
    /// fix is to regenerate rather than to edit the number.
    @Test
    func theTableIsTheGeneratorsPopulation() {
        #expect(LatinConfusables.table.count == 98)
        // Two the reading needs and two chosen because they are easy to drop when "tidying" a table
        // one cannot read: the dotless i, the Cyrillic a, the palochka that looks like an l, and
        // an Arabic presentation form of heh that looks like an o.
        #expect(LatinConfusables.table[0x0131] == UInt8(ascii: "i"))
        #expect(LatinConfusables.table[0x0430] == UInt8(ascii: "a"))
        #expect(LatinConfusables.table[0x04CF] == UInt8(ascii: "l"))
        #expect(LatinConfusables.table[0x0406] == UInt8(ascii: "I"))
        #expect(LatinConfusables.table[0xFEEB] == UInt8(ascii: "o"))
    }

    /// The fullwidth letters fold by arithmetic, all fifty-two of them, to the letter with the same
    /// case — including fullwidth `I` to `I` and not to `l`, which is where UTS #39 sends it. Nothing
    /// else in that block folds: a fullwidth digit, a fullwidth exclamation mark, a halfwidth bar.
    @Test
    func everyFullwidthLatinLetterFoldsToItsOwnLetterAndNothingElseInTheBlockDoes() {
        for (fullwidth, ascii) in zip(UInt32(0xFF21)...0xFF3A, UInt32(0x41)...0x5A) {
            #expect(LatinConfusables.fold(Self.scalar(fullwidth)) == Self.scalar(ascii))
        }
        for (fullwidth, ascii) in zip(UInt32(0xFF41)...0xFF5A, UInt32(0x61)...0x7A) {
            #expect(LatinConfusables.fold(Self.scalar(fullwidth)) == Self.scalar(ascii))
        }
        #expect(LatinConfusables.fold(Self.scalar(0xFF29)) == "I")
        for value: UInt32 in [0xFF00, 0xFF01, 0xFF10, 0xFF19, 0xFF20, 0xFF3B, 0xFF40, 0xFF5B, 0xFFE8, 0xFFEF] {
            let scalar = Self.scalar(value)
            #expect(LatinConfusables.fold(scalar) == scalar, "U+\(String(value, radix: 16, uppercase: true)) folded")
        }
    }

    /// The fold is scalar-for-scalar and touches nothing outside the rule: the combining mark, the
    /// ideograph, the emoji and the ordinary Cyrillic letter with no Latin twin all come through
    /// exactly, at the same ordinals, and only the four look-alikes change — to what they *look
    /// like*, which for U+0440 CYRILLIC SMALL LETTER ER is `p`, not the `r` it sounds like.
    @Test
    func foldingIsScalarForScalarAndLeavesEverythingElseExactlyAsItArrived() {
        let original = "e\u{0301} \u{4E2D}\u{6587} \u{1F600} \u{0436}\u{0430}\u{0440} \u{FF21}\u{0131}"
        let folded = LatinConfusables.fold(original)

        let expected = "e\u{0301} \u{4E2D}\u{6587} \u{1F600} \u{0436}ap Ai"
        #expect(Array(folded.text.unicodeScalars) == Array(expected.unicodeScalars))
        #expect(folded.text.unicodeScalars.count == original.unicodeScalars.count)
    }

    /// A range found in the folded text maps back to the same scalars of the original, however many
    /// wider-than-ASCII scalars sit ahead of it — which is where a UTF-8 offset would drift: three
    /// Cyrillic letters are six bytes before the fold and three after it.
    @Test
    func rangesMapBackToTheOriginalTextThroughWiderScalarsAheadOfThem() throws {
        let original = "\u{043E}\u{043E}\u{043E} secret \u{0430}"
        let folded = LatinConfusables.fold(original)
        #expect(folded.text == "ooo secret a")

        let foldedRange = try #require(folded.text.range(of: "secret"))
        let mapped = folded.originalRange(of: foldedRange)

        #expect(String(original[mapped]) == "secret")
        let originalScalars = original.unicodeScalars
        #expect(originalScalars.distance(from: originalScalars.startIndex, to: mapped.lowerBound) == 4)
        #expect(originalScalars.distance(from: originalScalars.startIndex, to: mapped.upperBound) == 10)

        // The bounds map too — the last scalar of the original is the folded `a`.
        let last = folded.text.index(before: folded.text.endIndex)..<folded.text.endIndex
        #expect(Array(original[folded.originalRange(of: last)].unicodeScalars) == [Unicode.Scalar(0x0430)!])
        #expect(folded.originalIndex(of: folded.text.endIndex) == original.endIndex)
    }

    /// The common case: nothing folds, the original comes back as itself, and ranges are their own
    /// mapping — no second string and no lookup table for the ASCII screenful this runs on.
    @Test
    func textThatFoldsNothingComesBackAsItselfWithIdentityRanges() throws {
        let original = "api_key=sk-Abc123Def456Ghi789JklMno012Pqr \u{4E2D}\u{6587} caf\u{00E9} \u{0436}"
        let folded = LatinConfusables.fold(original)

        #expect(Array(folded.text.unicodeScalars) == Array(original.unicodeScalars))
        let range = try #require(folded.text.range(of: "sk-Abc123"))
        #expect(folded.originalRange(of: range) == range)
        #expect(folded.originalIndex(of: folded.text.endIndex) == original.endIndex)
    }
}
