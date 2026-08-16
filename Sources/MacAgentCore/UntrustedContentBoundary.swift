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

    static func escapeAttribute(_ value: String) -> String {
        escape(value)
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
