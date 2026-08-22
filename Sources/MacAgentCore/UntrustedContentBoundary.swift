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
    /// This is the attack the wrapper exists to stop and it is not hypothetical for either source.
    ///
    /// **Fetched web pages are the reliably reachable one.** `ReadableWebPage.readableText` is raw
    /// extracted DOM text under complete attacker control — a page author writes the codepoint
    /// sequence, or an HTML numeric character reference, straight into their page. No rendering step,
    /// nothing that could normalise it on the way in.
    ///
    /// **For screen content the channel is the window title and the observed history, not OCR** —
    /// this line used to say OCR and that was wrong (SONNY-222 established it). Recognized text never
    /// becomes prompt text: `LocalRedactionService.redactCapture` returns `maskedText: nil` and uses
    /// its observations only to decide which pixels to paint. What the vision model reads as text is
    /// `VisionSessionPromptBuilder.observedBlock` — `capture.windowTitle`, which an app names for
    /// itself and a webpage sets with `document.title`, plus history lines quoting control labels the
    /// model read off the window. Both are plain UTF-8 strings that reach here untouched, so the
    /// forgery works on that path with exactly the reliability it has on the web one. The screenshot's
    /// own pixels are a separate matter that no escaping can reach, which is why the vision system
    /// rules name the image as data in so many words.
    public static func escape(_ value: String) -> String {
        neutralizingDelimiters(in: value, delimiters: allDelimiters) { "[escaped delimiter: \($0)]" }
    }

    /// Percent-encode delimiters inside a URL, where the escaped form still has to parse as a URL.
    public static func escapeURLValue(_ value: String) -> String {
        neutralizingDelimiters(in: value, delimiters: allDelimiters) {
            $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0
        }
    }

    // MARK: - Matching delimiters over Unicode scalars (SONNY-222)

    /// Replace every occurrence of a `delimiters` entry in `value` with `replacement(delimiter)`,
    /// matching over **Unicode scalars** and stepping over scalars that carry no base character of
    /// their own.
    ///
    /// **This exists because `String.replacingOccurrences(of:with:)` could not see the attack the
    /// escaping is for.** Swift compares strings by extended grapheme cluster. Append U+0301
    /// COMBINING ACUTE ACCENT to a delimiter's final letter and that letter becomes a different
    /// `Character` — `D` with an accent on it, one cluster, not equal to `D` — so the substring
    /// search silently finds nothing and the near-verbatim delimiter passes through **completely
    /// unescaped**, landing as its own well-formed line inside what is supposed to be pure data.
    /// `hasPrefix`, `==`, `range(of:)` and `components(separatedBy: String)` share the identical
    /// blind spot, which is why a regression test written in that idiom passes against the unfixed
    /// tree; the tests for this live in `UntrustedContentBoundaryScalarMatchingTests` and assert over
    /// scalars and UTF-8 bytes throughout.
    ///
    /// **Ignorable scalars are stepped over rather than ending the match, and that is the line this
    /// draws.** `options: .literal` would have closed the reported case — a trailing mark — and left
    /// `UNTRUSTED_OBSERVED_CONTENT_ÉND` and `UNTRUSTED_OBSERVED_CONTENT_EN<U+200B>D` wide open, which
    /// is the same attack moved one letter. What is skipped is exactly the scalars that add no base
    /// character: combining marks, which attach to the letter before them, and the invisible
    /// formatting scalars (zero-width space, ZWJ/ZWNJ, soft hyphen, byte order mark, the bidi
    /// controls, variation selectors, and U+034F COMBINING GRAPHEME JOINER, whose published purpose
    /// is to defeat exactly this kind of segmentation). Every one of those leaves a rendered line
    /// that still reads as the delimiter.
    ///
    /// **What it deliberately does not close, stated so nobody reads more into it.** Base characters
    /// must match exactly, so a *visibly different* string is not a delimiter here: a Cyrillic
    /// `Е`, a fullwidth `Ｅ`, a lowercase `end`. That is a boundary rather than an oversight — the
    /// homoglyph tail is unbounded and matching cannot win it, and unlike an invisible insertion each
    /// of those changes what the line looks like. Normalising (NFC/NFD/NFKD) is not the answer either
    /// and was considered: NFKD would fold the fullwidth forms and nothing else on that list, buying
    /// an arbitrary slice of an infinite problem while making the escaped output depend on a Unicode
    /// table version. The system prompts naming the observed segment as data are the backstop for
    /// what matching cannot reach, and they are unchanged.
    ///
    /// **Not a loop of four passes any more, which also removes a latent hazard.** The old shape
    /// re-scanned its own output on each pass — safe only because no delimiter appears inside another
    /// delimiter's `[escaped delimiter: …]` replacement, a property nothing checked and a fifth
    /// delimiter could have broken. One left-to-right pass never reads what it has written.
    ///
    /// - Parameter delimiters: matched longest-first, so a delimiter that is a prefix of another
    ///   cannot silently win by being earlier in the list. No pair today has that shape; the sort
    ///   costs one line and removes the footgun from whoever adds the next one.
    static func neutralizingDelimiters(
        in value: String,
        delimiters: [String],
        replacement: (String) -> String
    ) -> String {
        let targets = delimiters
            .map { (text: $0, scalars: Array($0.unicodeScalars)) }
            .filter { !$0.scalars.isEmpty }
            .sorted { $0.scalars.count > $1.scalars.count }
        guard !targets.isEmpty else {
            return value
        }

        let scalars = Array(value.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            // A match may never *begin* on an ignorable scalar. Without this, a combining acute in
            // "cafe\u{0301}UNTRUSTED_…" would be swallowed into the replaced range and the accent
            // would vanish from text that had nothing to do with the forgery.
            if !isIgnorableForDelimiterMatching(scalars[index]),
               let match = targets.lazy.compactMap({ target -> (text: String, end: Int)? in
                   guard let end = matchEnd(of: target.scalars, at: index, in: scalars) else {
                       return nil
                   }
                   return (target.text, end)
               }).first {
                output.append(contentsOf: replacement(match.text).unicodeScalars)
                index = match.end
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// Where a match of `needle` starting at `start` ends, or `nil` if there is none.
    ///
    /// Ignorable scalars are skipped before each expected scalar and again after the last one. The
    /// trailing skip is what makes the escaped form **identical however the delimiter was
    /// decorated**: the mark an attacker hung on the final letter is theirs, not the content's, and
    /// leaving it behind would simply re-attach it to the `]` of the replacement.
    private static func matchEnd(
        of needle: [Unicode.Scalar],
        at start: Int,
        in scalars: [Unicode.Scalar]
    ) -> Int? {
        var cursor = start
        for expected in needle {
            while cursor < scalars.count, isIgnorableForDelimiterMatching(scalars[cursor]) {
                cursor += 1
            }
            guard cursor < scalars.count, scalars[cursor] == expected else {
                return nil
            }
            cursor += 1
        }
        while cursor < scalars.count, isIgnorableForDelimiterMatching(scalars[cursor]) {
            cursor += 1
        }
        return cursor
    }

    /// Whether `scalar` contributes no base character of its own, and so can be hidden inside a
    /// delimiter without changing what the delimiter reads as.
    ///
    /// The three mark categories are listed as well as `isDefaultIgnorableCodePoint` because they are
    /// not the same set and neither contains the other: U+0301 is a nonspacing mark and is **not**
    /// default-ignorable (it renders), while U+200B is default-ignorable and is a format character
    /// rather than a mark. Both have to be skipped, so both tests are here.
    private static func isIgnorableForDelimiterMatching(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format:
            return true
        default:
            return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// Reduce an attribute value — the `id=` and `source=` tokens on the wrapper's opening line — to
    /// something that can neither start a line nor end the token it sits in.
    ///
    /// **Both properties come from the wrapper's shape.** The opening line is
    /// `DELIMITER id=<attr> source=<attr>`, on one line, and the closing line is
    /// `DELIMITER id=<attr>`. Anything in an attribute that renders as a line break begins a new
    /// line *inside* the wrapper; anything that renders as horizontal whitespace ends the token
    /// early and leaves the remainder reading as a further attribute. ``separators`` closes both.
    ///
    /// **The set is deliberately wider than the two literals it replaces (SONNY-219).** It was
    /// `"\n"` and `" "`, which left six other ways to begin a line — CR, VT, FF, NEL (U+0085) and
    /// the Unicode line and paragraph separators (U+2028, U+2029) — and every non-space horizontal
    /// separator, tab and the non-breaking space among them, free to split the token. A prompt is
    /// JSON-serialised UTF-8, so each of those survives the wire intact and renders where it lands.
    /// `PriorTaskContext.foldingLineBreaks` closed the same narrowing over the prior-task block one
    /// ticket earlier; this is the observed-content boundary's copy of it.
    ///
    /// **`_` is the replacement, and its one-for-one-ness is not what makes any of this safe.** Say
    /// that plainly, because the first draft of this comment credited it and PR #97's review was
    /// right to call that out: one character for one only means a folded payload cannot grow the
    /// prompt, which is a length argument and nothing more. It is why runs are *not* collapsed here —
    /// deliberately unlike `PriorTaskContext.foldingLineBreaks`, whose two-character `\n` marker
    /// really could expand a capped string, and whose marker belongs in a field *value* where a
    /// reader gains from knowing a break was there. Here the value has to survive as one token, so
    /// the replacement has to read as part of it. **The property that carries the safety is the
    /// ordering below.**
    ///
    /// **Fold, escape, fold — and collapsing those two folds into one reopens the hole.** This is
    /// the load-bearing part of the function. Escaping first and folding afterwards — what shipped
    /// before SONNY-219 — lets the fold *rebuild* a delimiter that `escape` never had a chance to
    /// see: the delimiters are `[A-Z_]` only, so `UNTRUSTED_OBSERVED CONTENT_END` contains no
    /// delimiter to escape, and the fold then makes it one. Widening the set widened that surface
    /// rather than shrinking it — `UNTRUSTED_OBSERVED<U+001C>CONTENT_END` folds to a real delimiter
    /// too. Folding *only* first is no better, because `escape`'s own `[escaped delimiter: …]`
    /// replacement contains spaces, which would break the one-token property the first paragraph is
    /// about. So: fold, so every rebuild is visible to `escape`; escape; fold again, which removes
    /// only the whitespace `escape` itself introduced and cannot rebuild a delimiter across its
    /// brackets, because `[`, `]` and `:` are not delimiter characters.
    /// `UntrustedContentBoundaryAttributeTests.theFoldCannotRebuildADelimiterEscapeHasAlreadyPassed`
    /// and its control-character twin are what fail if the two folds are ever merged.
    static func escapeAttribute(_ value: String) -> String {
        foldingSeparators(in: escape(foldingSeparators(in: value)))
    }

    /// Everything an attribute may not contain: what renders as a break, what renders as a gap, and
    /// what renders as nothing at all.
    ///
    /// **`.controlCharacters` is in here for defence in depth, not to close a live hole, and the
    /// distinction is worth keeping straight** (PR #97, F2). `.whitespacesAndNewlines` excludes the
    /// C0 information separators U+001C–U+001F, which sit immediately beside VT and FF — which it
    /// *does* include — and whose names (file, group, record, unit separator) are the reason to look
    /// twice. PR #97's review drove all four through both real paths and found them inert: nothing
    /// downstream renders them as a line, and they defeat no matching. They are folded anyway,
    /// because an `id=` or a `source=` has no legitimate use for a control character and "inert
    /// today" is a claim about the consumer rather than about this boundary. Unioning the whole
    /// category rather than the four also takes the C1 range, DEL, the soft hyphen, ZWNJ/ZWJ, the
    /// BOM, and the BIDI controls U+202A–U+202E and U+2066–U+2069 — the last of which that review
    /// classed as a visual-spoofing concern rather than a boundary escape, and which are no longer
    /// this line's problem either way.
    ///
    /// **What this set does not reach, said out loud so nobody reads it as more than it is:**
    /// combining marks and variation selectors are `Mn`/`Me`/`Sk`, in neither
    /// `.whitespacesAndNewlines` nor `.controlCharacters`, and they are not folded. The
    /// grapheme-cluster weakness in `escape` that a trailing combining mark exploits is **SONNY-222**
    /// and is untouched by anything on this line; it needs scalar or byte matching inside `escape`,
    /// not a wider fold out here.
    ///
    /// **What it costs, stated rather than hidden:** an app whose display name contains a ZWJ emoji
    /// sequence reaches the `source=` attribute with the joiners folded — `Family 👨‍👩‍👧 Sharing`
    /// becomes `Family_👨_👩_👧_Sharing`. The same prompt carries the unfolded name in
    /// `VisionSessionPromptBuilder.systemRules`, so nothing the model needs is lost.
    private static let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// Every character in ``separators`` replaced by `_`, one for one.
    private static func foldingSeparators(in value: String) -> String {
        value
            .components(separatedBy: separators)
            .joined(separator: "_")
    }
}
