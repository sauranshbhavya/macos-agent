import Foundation
import MacAgentCore

// MARK: - A boundary with a tag a test can name (SONNY-234)

/// The delimiters every suite in this target asserts delimiter *text* against.
///
/// **A fixed tag, because production's is random by design.** `UntrustedContentBoundary.Delimiters`
/// carries a tag generated at wrap time, which is the whole security property — and a test that has
/// to write out the closing delimiter it expects cannot assert against a value it does not know. So
/// the suites pass this in, and the tests that care about the *randomness* rather than the wrapping
/// call `forOnePrompt()` themselves and compare tags
/// (`theTagIsFreshForEveryPromptAndNeverReused`).
///
/// **Twenty letters, matching production's length**, so a corpus measured through this boundary is
/// measured at the delimiter lengths the product actually ships. The letters themselves spell
/// nothing; a tag that read as a word would invite a reader to think the value mattered.
///
/// The force-unwrap is the initializer's contract, asserted rather than assumed:
/// `aTagOutsideTheUppercaseAlphabetIsRefused` drives every rejected shape, so a change that made
/// this literal invalid would fail there with a message rather than trapping here without one.
let fixedTagBoundary = UntrustedContentBoundary.Delimiters(tag: "QXZJVWHKMPFRBNLDGYTC")!

/// A second fixed tag, for the assertions that are about two prompts *disagreeing* — a marker from
/// one prompt is not a marker in another, which is what makes an echoed tag inert.
let otherFixedTagBoundary = UntrustedContentBoundary.Delimiters(tag: "MDKWSPXHVBLQZFNRJGTY")!


// MARK: - The forgery corpus

/// One way of decorating a delimiter so that it still *reads* as the delimiter while no longer
/// *comparing* as one.
///
/// Every entry inserts scalars that add no base character of their own: combining marks, which attach
/// to the letter before them, and the invisible formatting scalars. The rendered line is the
/// delimiter, with at most an accent on one letter; the `Character` sequence is not.
struct DelimiterForgery: Sendable {
    let label: String
    /// The forged text for a given delimiter.
    let forge: @Sendable (String) -> String
}

/// Insert `scalar` after the scalar at `offset` (negative counts back from the end).
func inserting(_ scalar: Unicode.Scalar, at offset: Int, in delimiter: String) -> String {
    var scalars = Array(delimiter.unicodeScalars)
    let index = offset < 0 ? scalars.count + offset : offset
    scalars.insert(scalar, at: index)
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}

let delimiterForgeries: [DelimiterForgery] = [
    // The ticket's own reproduction.
    DelimiterForgery(label: "trailing U+0301 combining acute") { $0 + "\u{0301}" },
    DelimiterForgery(label: "combining acute on the first letter") { inserting("\u{0301}", at: 1, in: $0) },
    DelimiterForgery(label: "combining acute inside the final word") { inserting("\u{0301}", at: -2, in: $0) },
    DelimiterForgery(label: "U+200B zero width space before the last letter") { inserting("\u{200B}", at: -1, in: $0) },
    DelimiterForgery(label: "U+200D zero width joiner mid-string") { inserting("\u{200D}", at: 5, in: $0) },
    DelimiterForgery(label: "U+00AD soft hyphen mid-string") { inserting("\u{00AD}", at: 9, in: $0) },
    DelimiterForgery(label: "U+FEFF byte order mark mid-string") { inserting("\u{FEFF}", at: 3, in: $0) },
    // U+034F exists for precisely this: its published purpose is to defeat grapheme segmentation.
    DelimiterForgery(label: "U+034F combining grapheme joiner mid-string") { inserting("\u{034F}", at: 12, in: $0) },
    // Default-ignorable but *not* a mark and not a format character — it is category Lo, and it
    // renders as nothing. Only the `isDefaultIgnorableCodePoint` half of the ignorable test catches
    // it, so this entry is what makes that half load-bearing rather than decorative.
    DelimiterForgery(label: "U+3164 Hangul filler mid-string") { inserting("\u{3164}", at: 7, in: $0) },
    DelimiterForgery(label: "trailing U+FE0F variation selector") { $0 + "\u{FE0F}" },
    DelimiterForgery(label: "trailing U+20DD combining enclosing circle") { $0 + "\u{20DD}" },
    // PR #100 review, F1. Space separators reproduced the ticket's original failure shape verbatim:
    // the matcher stepped over U+200B (Cf) and not over U+200A (Zs), two adjacent code points, and a
    // hair space is *less* visible than the U+0301 accent this fix exists to close.
    DelimiterForgery(label: "U+00A0 no-break space mid-string") { inserting("\u{00A0}", at: -2, in: $0) },
    DelimiterForgery(label: "U+2009 thin space mid-string") { inserting("\u{2009}", at: 6, in: $0) },
    DelimiterForgery(label: "U+200A hair space mid-string") { inserting("\u{200A}", at: -1, in: $0) },
    DelimiterForgery(label: "U+202F narrow no-break space mid-string") { inserting("\u{202F}", at: 10, in: $0) },
    DelimiterForgery(label: "U+205F medium mathematical space mid-string") { inserting("\u{205F}", at: 4, in: $0) },
    DelimiterForgery(label: "U+3000 ideographic space mid-string") { inserting("\u{3000}", at: 8, in: $0) },
    DelimiterForgery(label: "U+1680 ogham space mark mid-string") { inserting("\u{1680}", at: 2, in: $0) },
    DelimiterForgery(label: "U+0009 tab mid-string") { inserting("\u{0009}", at: 11, in: $0) },
    DelimiterForgery(label: "U+001F unit separator mid-string") { inserting("\u{001F}", at: 14, in: $0) },
    // PR #100 review round 2, F1 — the most ordinary forgery there is, and the last separator left
    // open. A page author types a space; no code point to look up, no numeric character reference.
    DelimiterForgery(label: "U+0020 space mid-string") { inserting(" ", at: -2, in: $0) },
    DelimiterForgery(label: "U+0020 space after the first letter") { inserting(" ", at: 1, in: $0) },
    // F3 — category So, not default-ignorable, and blank in every font that carries braille.
    DelimiterForgery(label: "U+2800 braille pattern blank mid-string") { inserting("\u{2800}", at: 9, in: $0) },
    // PR #100 review, F3. `Cf` *and not* default-ignorable, so only the `.format` branch of the
    // ignorable predicate catches it — U+200B above establishes nothing about that branch, because it
    // is default-ignorable and the other branch already has it.
    DelimiterForgery(label: "U+0600 arabic number sign mid-string") { inserting("\u{0600}", at: 5, in: $0) },
    DelimiterForgery(label: "U+FFF9 interlinear annotation anchor mid-string") { inserting("\u{FFF9}", at: 13, in: $0) },
    DelimiterForgery(label: "two combining marks stacked on the last letter") { $0 + "\u{0301}\u{0308}" }
]

// **Moved here from `UntrustedContentBoundaryScalarMatchingTests` by SONNY-234**, for the reason
// `ScalarTextAssertions.swift` exists: this corpus is the repository's red-team material for the
// boundary, three suites now drive it, and a copy per suite is how one of them stays on the shape
// that was closed two rounds ago.
