import Foundation

// MARK: - Scalar- and byte-level assertions, shared by every suite that counts delimiters

/// **Every assertion in this file compares Unicode scalars or UTF-8 bytes, and that is the point of
/// the file rather than a stylistic choice** (SONNY-222).
///
/// `contains`, `range(of:)`, `hasPrefix`, `==` and `components(separatedBy: String)` all compare
/// *extended grapheme clusters*. `UNTRUSTED_OBSERVED_CONTENT_END` followed by U+0301 COMBINING ACUTE
/// ACCENT ends in a single `Character` — `D` with an accent on it — which is not equal to `D`, so
/// every one of those calls answers "the delimiter is not there" about a string whose bytes plainly
/// spell it. That is the defect this file exists to catch, so a test written in that idiom would
/// **pass against the unfixed tree**: it could not see the forgery it was written for. The three
/// helpers below ask the honest question instead.
///
/// This is the same class of trap PR #94 found in SONNY-198's separator test, which counted lines by
/// splitting on line feed and so could not see a CR-forged line.

/// Occurrences of `needle` as an exact, non-overlapping run of Unicode scalars in `haystack`.
func scalarOccurrences(of needle: String, in haystack: String) -> Int {
    let needleScalars = Array(needle.unicodeScalars)
    let scalars = Array(haystack.unicodeScalars)
    guard !needleScalars.isEmpty, scalars.count >= needleScalars.count else {
        return 0
    }
    var count = 0
    var index = 0
    while index <= scalars.count - needleScalars.count {
        if Array(scalars[index..<(index + needleScalars.count)]) == needleScalars {
            count += 1
            index += needleScalars.count
        } else {
            index += 1
        }
    }
    return count
}

/// Occurrences of `needle` as an exact, non-overlapping run of UTF-8 **bytes** in `haystack`.
///
/// A second, independent anchor for the same question. The four delimiters are ASCII, so this and
/// `scalarOccurrences` must always agree about them — a test asserts that they do, so neither helper
/// can drift into agreeing with the defect.
func utf8Occurrences(of needle: String, in haystack: String) -> Int {
    let needleBytes = Array(needle.utf8)
    let bytes = Array(haystack.utf8)
    guard !needleBytes.isEmpty, bytes.count >= needleBytes.count else {
        return 0
    }
    var count = 0
    var index = 0
    while index <= bytes.count - needleBytes.count {
        if Array(bytes[index..<(index + needleBytes.count)]) == needleBytes {
            count += 1
            index += needleBytes.count
        } else {
            index += 1
        }
    }
    return count
}

/// Whether `value`'s leading Unicode scalars are exactly `prefix`'s.
///
/// `String.hasPrefix` cannot answer this: it compares grapheme clusters, and a combining mark on the
/// prefix's final letter makes it say no.
func hasScalarPrefix(_ value: String, _ prefix: String) -> Bool {
    let prefixScalars = Array(prefix.unicodeScalars)
    let scalars = Array(value.unicodeScalars)
    guard scalars.count >= prefixScalars.count else {
        return false
    }
    return Array(scalars[0..<prefixScalars.count]) == prefixScalars
}

/// The line-break **scalars**, which is wider than `\n` on purpose: LF, VT, FF, CR, NEL (U+0085) and
/// the Unicode line and paragraph separators. A prompt is JSON-serialised UTF-8, so every one of them
/// survives the wire intact and begins a line where it is rendered — the reasoning
/// `PriorTaskContext.foldingLineBreaks` already records, applied to the assertions here.
let lineBreakScalars: Set<Unicode.Scalar> = [
    "\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0085}", "\u{2028}", "\u{2029}"
]

/// `value` split into lines at line-break scalars, CR LF counting as one break.
///
/// `components(separatedBy: .newlines)` would do for today's inputs, but it is a Foundation call
/// whose contract this file is in no position to assume — the whole subject here is a Foundation
/// string call whose contract was assumed and was wrong.
func scalarLines(of value: String) -> [String] {
    let scalars = Array(value.unicodeScalars)
    var lines: [String] = []
    var current = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        let scalar = scalars[index]
        if lineBreakScalars.contains(scalar) {
            lines.append(String(current))
            current = String.UnicodeScalarView()
            if scalar == "\u{000D}", index + 1 < scalars.count, scalars[index + 1] == "\u{000A}" {
                index += 1
            }
        } else {
            current.append(scalar)
        }
        index += 1
    }
    lines.append(String(current))
    return lines
}

// **One copy, in its own file, because three was the shape this ticket exists to end** (PR #100 review
// round 2, F7). `UntrustedContentBoundaryScalarMatchingTests` defined these, `VisionPromptInjectionTests`
// carried its own `scalarOccurrences`, and `WebResearchSynthesizerTests` — the *more* reliably
// attacker-controlled path of the two — was still counting boundary lines with `hasPrefix`, the exact
// idiom this branch's own doc comments say passes against a vulnerable tree. A helper duplicated per
// suite is how one of them stays on the trapped idiom.
