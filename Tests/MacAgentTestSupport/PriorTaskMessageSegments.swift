import Foundation
import MacAgentCore

/// The planner's prior-task message, split the way the planner is told to read it (SONNY-491).
///
/// **One reader, shared by both test targets, because the security claim is about where a string
/// lands and three suites assert it.** The trusted block is the lines between the one line that is
/// exactly `TRUSTED_PRIOR_TASK_CONTEXT_BEGIN_<tag>` and the one that is exactly its `END`; the observed
/// segment is the lines between the one line that *starts with* `UNTRUSTED_OBSERVED_CONTENT_BEGIN_<tag>`
/// and the one that starts with its `END`. A boundary is a line, never a substring: since SONNY-234 a
/// marker also appears mid-line in the system message's tag rule, so `range(of:)` would find that
/// mention first and give a wrong answer rather than none.
///
/// **Lines split on every line-break scalar and compared over scalars**, for the reasons
/// `.claude/rules/macagentcore-conventions.md` records: a split on `"\n"` alone does not see a CR- or
/// NEL-forged line, and `==` and `hasPrefix` on `String` compare grapheme clusters, so a forged marker
/// carrying a combining mark would compare unequal and be missed.
///
/// The tag is read off the message's own opening line, so a test in either target can locate the
/// segments of a message a real `OpenAIPlanner` or a real view model produced without choosing the
/// tag itself — `Delimiters(tag:)` is internal to `MacAgentCore`, deliberately.
public struct PriorTaskMessageSegments {
    public let tag: String
    public let lines: [String]
    /// Lines that are exactly this message's trusted opening marker, and its closing one.
    public let trustedBeginCount: Int
    public let trustedEndCount: Int
    /// Lines that start with this message's observed opening marker, and its closing one.
    public let observedBeginCount: Int
    public let observedEndCount: Int
    /// The trusted block's body, markers excluded.
    public let trustedLines: [String]
    /// The observed segment's body, markers excluded. Empty when the message has no observed segment.
    public let observedLines: [String]

    public var trustedBegin: String { "\(PriorTaskContext.trustedBeginName)_\(tag)" }
    public var trustedEnd: String { "\(PriorTaskContext.trustedEndName)_\(tag)" }
    public var observedBegin: String { "\(UntrustedContentBoundary.observedBeginName)_\(tag)" }
    public var observedEnd: String { "\(UntrustedContentBoundary.observedEndName)_\(tag)" }

    public var trustedText: String { trustedLines.joined(separator: "\n") }
    public var observedText: String { observedLines.joined(separator: "\n") }

    /// `nil` when the message has no line opening a tagged trusted block.
    public init?(message: String) {
        let lines = Self.scalarLines(of: message)
        let openingPrefix = "\(PriorTaskContext.trustedBeginName)_"
        guard let opening = lines.first(where: { Self.hasScalarPrefix($0, openingPrefix) }) else {
            return nil
        }
        let tag = String(String.UnicodeScalarView(opening.unicodeScalars.dropFirst(openingPrefix.unicodeScalars.count)))
        guard !tag.isEmpty, tag.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return nil
        }
        self.tag = tag
        self.lines = lines

        let trustedBegin = "\(PriorTaskContext.trustedBeginName)_\(tag)"
        let trustedEnd = "\(PriorTaskContext.trustedEndName)_\(tag)"
        let observedBegin = "\(UntrustedContentBoundary.observedBeginName)_\(tag)"
        let observedEnd = "\(UntrustedContentBoundary.observedEndName)_\(tag)"

        let trustedBeginIndices = lines.indices.filter { Self.scalarEqual(lines[$0], trustedBegin) }
        let trustedEndIndices = lines.indices.filter { Self.scalarEqual(lines[$0], trustedEnd) }
        let observedBeginIndices = lines.indices.filter { Self.hasScalarPrefix(lines[$0], observedBegin) }
        let observedEndIndices = lines.indices.filter { Self.hasScalarPrefix(lines[$0], observedEnd) }
        trustedBeginCount = trustedBeginIndices.count
        trustedEndCount = trustedEndIndices.count
        observedBeginCount = observedBeginIndices.count
        observedEndCount = observedEndIndices.count

        if let start = trustedBeginIndices.first, let end = trustedEndIndices.first(where: { $0 > start }) {
            trustedLines = Array(lines[(start + 1)..<end])
        } else {
            trustedLines = []
        }
        if let start = observedBeginIndices.first, let end = observedEndIndices.first(where: { $0 > start }) {
            observedLines = Array(lines[(start + 1)..<end])
        } else {
            observedLines = []
        }
    }

    /// Whether exactly one of each marker the message writes is a real boundary line, and the
    /// observed segment — when there is one — follows the trusted block.
    public var boundariesAreIntact: Bool {
        guard trustedBeginCount == 1, trustedEndCount == 1 else {
            return false
        }
        if observedBeginCount == 0 && observedEndCount == 0 {
            return true
        }
        return observedBeginCount == 1 && observedEndCount == 1
    }

    /// How many times `needle` occurs in the trusted block, over scalars.
    public func trustedOccurrences(of needle: String) -> Int {
        Self.occurrences(of: needle, in: trustedText)
    }

    /// How many times `needle` occurs in the observed segment, over scalars.
    public func observedOccurrences(of needle: String) -> Int {
        Self.occurrences(of: needle, in: observedText)
    }

    public static func occurrences(of needle: String, in haystack: String) -> Int {
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

    public static func hasScalarPrefix(_ value: String, _ prefix: String) -> Bool {
        let prefixScalars = Array(prefix.unicodeScalars)
        let scalars = Array(value.unicodeScalars)
        return scalars.count >= prefixScalars.count && Array(scalars[0..<prefixScalars.count]) == prefixScalars
    }

    public static func scalarEqual(_ lhs: String, _ rhs: String) -> Bool {
        Array(lhs.unicodeScalars) == Array(rhs.unicodeScalars)
    }

    /// Every line-break scalar ends a line; CRLF is one break.
    public static func scalarLines(of value: String) -> [String] {
        let breaks: Set<Unicode.Scalar> = ["\u{000A}", "\u{000B}", "\u{000C}", "\u{000D}", "\u{0085}", "\u{2028}", "\u{2029}"]
        let scalars = Array(value.unicodeScalars)
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if breaks.contains(scalar) {
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
}
