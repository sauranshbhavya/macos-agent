import Foundation

/// The delimiters that separate what the user told Sonny from what Sonny merely *observed*.
///
/// **Promoted out of `WebResearchPromptBuilder` by row I, not copied.** Until SONNY-92 there was one
/// source of observed content — fetched web pages — so the boundary lived inside the web-research
/// synthesizer. Screen content is the second source, and it is the more dangerous one: a webpage
/// Sonny fetched is at least a page the user's own command pointed at, while a vision session sees
/// whatever happens to be on screen, including a window some other program put there. Two
/// independently-maintained copies of a security boundary's delimiters is the shape where one gets
/// hardened and the other does not, so there is one copy and both callers reference it.
/// `WebResearchPromptBuilder`'s own constants remain, forwarding here, so no existing call site or
/// test had to change to make that true.
public enum UntrustedContentBoundary {
    public static let observedBeginDelimiter = "UNTRUSTED_OBSERVED_CONTENT_BEGIN"
    public static let observedEndDelimiter = "UNTRUSTED_OBSERVED_CONTENT_END"
    public static let trustedInstructionBeginDelimiter = "TRUSTED_USER_INSTRUCTION_BEGIN"
    public static let trustedInstructionEndDelimiter = "TRUSTED_USER_INSTRUCTION_END"

    public static let allDelimiters = [
        observedBeginDelimiter,
        observedEndDelimiter,
        trustedInstructionBeginDelimiter,
        trustedInstructionEndDelimiter
    ]

    /// Wrap the user's own instruction — the one segment a model is allowed to obey.
    public static func trustedInstruction(_ instruction: String) -> String {
        """
        \(trustedInstructionBeginDelimiter)
        \(escape(instruction.trimmingCharacters(in: .whitespacesAndNewlines)))
        \(trustedInstructionEndDelimiter)
        """
    }

    /// Wrap observed content — text Sonny read from somewhere, which is data and never instruction.
    ///
    /// `id` and `source` land in the opening line the same way the web-research wrapper puts them
    /// there, so one convention covers both sources and a reader of either prompt sees the same
    /// shape.
    public static func observedContent(_ content: String, id: String, source: String) -> String {
        """
        \(observedBeginDelimiter) id=\(escapeAttribute(id)) source=\(escapeAttribute(source))
        \(escape(content))
        \(observedEndDelimiter) id=\(escapeAttribute(id))
        """
    }

    /// Neutralize any delimiter appearing *inside* content, so observed text cannot forge a boundary
    /// and escape its own wrapper.
    ///
    /// This is the attack the wrapper exists to stop and it is not hypothetical for screen content:
    /// OCR reads whatever is rendered, and rendering the literal string
    /// `UNTRUSTED_OBSERVED_CONTENT_END` in a window is something any webpage can do with no
    /// privileges at all.
    public static func escape(_ value: String) -> String {
        var escaped = value
        for delimiter in allDelimiters {
            escaped = escaped.replacingOccurrences(
                of: delimiter,
                with: "[escaped delimiter: \(delimiter)]"
            )
        }
        return escaped
    }

    /// Percent-encode delimiters inside a URL, where the escaped form still has to parse as a URL.
    public static func escapeURLValue(_ value: String) -> String {
        var escaped = value
        for delimiter in allDelimiters {
            let encoded = delimiter.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? delimiter
            escaped = escaped.replacingOccurrences(of: delimiter, with: encoded)
        }
        return escaped
    }

    /// Reduce an attribute value — the `id=` and `source=` tokens on the wrapper's opening line — to
    /// something that can neither start a line nor end the token it sits in.
    ///
    /// **Both properties come from the wrapper's shape.** The opening line is
    /// `DELIMITER id=<attr> source=<attr>`, on one line, and the closing line is
    /// `DELIMITER id=<attr>`. Anything in an attribute that renders as a line break begins a new
    /// line *inside* the wrapper; anything that renders as horizontal whitespace ends the token
    /// early and leaves the remainder reading as a further attribute. One fold over
    /// `CharacterSet.whitespacesAndNewlines` closes both.
    ///
    /// **The set is deliberately wider than the two literals it replaces (SONNY-219).** It was
    /// `"\n"` and `" "`, which left six other ways to begin a line — CR, VT, FF, NEL (U+0085) and
    /// the Unicode line and paragraph separators (U+2028, U+2029) — and every non-space horizontal
    /// separator, tab and the non-breaking space among them, free to split the token. A prompt is
    /// JSON-serialised UTF-8, so each of those survives the wire intact and renders where it lands.
    /// `PriorTaskContext.foldingLineBreaks` closed the same narrowing over the prior-task block one
    /// ticket earlier; this is the observed-content boundary's copy of it.
    ///
    /// **`_` rather than `PriorTaskContext`'s `\n` marker, and that is not an inconsistency.** That
    /// fold marks a paragraph break inside a field *value*, where a reader gains from knowing a
    /// break was there. This one has to leave a single token behind, so the replacement has to read
    /// as part of it. Runs are not collapsed here for the same reason they are collapsed there: `_`
    /// is one character replacing one, so no payload grows by being folded and there is nothing to
    /// bound.
    ///
    /// **Folded on both sides of `escape`, which is not belt-and-braces.** Escaping first and
    /// folding afterwards — what this did before — lets the fold *rebuild* a delimiter that `escape`
    /// never had a chance to see: the delimiters are `[A-Z_]` only, so `UNTRUSTED_OBSERVED
    /// CONTENT_END` contains no delimiter to escape, and the space fold then makes it one. Folding
    /// only first is no better, because `escape`'s own `[escaped delimiter: …]` replacement contains
    /// spaces, which would break the one-token property this whole function is about. So: fold, so
    /// every rebuild is visible to `escape`; escape; fold again, which removes only the whitespace
    /// `escape` itself introduced and cannot rebuild a delimiter across its brackets, because `[`,
    /// `]` and `:` are not delimiter characters.
    static func escapeAttribute(_ value: String) -> String {
        foldingSeparators(in: escape(foldingSeparators(in: value)))
    }

    /// Every whitespace or line-break character replaced by `_`, one for one.
    private static func foldingSeparators(in value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: "_")
    }
}
