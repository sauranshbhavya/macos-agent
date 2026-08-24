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
    /// **Ignorable scalars are stepped over rather than ending the match.** `options: .literal` would
    /// have closed the reported case — a trailing mark — and left `UNTRUSTED_OBSERVED_CONTENT_E` +
    /// U+0301 + `ND` and `UNTRUSTED_OBSERVED_CONTENT_EN` + U+200B + `D` wide open, which is the same
    /// attack moved one letter.
    ///
    /// **The frontier here is perceptual, it has no bottom, and saying so plainly is the point of this
    /// paragraph** (PR #100 review round 2, F1 and F3). Two earlier versions of this comment claimed a
    /// cleaner rule than the code follows. The first argued from visibility and died on U+200A HAIR
    /// SPACE, a one-pixel gap less visible than the U+0301 accent this function exists to close. The
    /// second replaced it with a structural-sounding test — "a scalar that cannot legitimately occur
    /// inside a token drawn from `[A-Z_]`" — which reads better and is *false about this code*: `x` and
    /// `3` cannot occur inside such a token either, and they are obviously not stepped over. Relabelling
    /// moved the argument, not the frontier.
    ///
    /// So, honestly: **what is stepped over is a scalar that contributes no visible glyph of its own** —
    /// combining marks, which attach to the letter before them; the format and default-ignorable
    /// scalars; the space separators; the control characters; and U+2800 BRAILLE PATTERN BLANK, the
    /// braille cell with no dots raised, which is category `So` and which no category test reaches.
    /// **That is a rendering test.** Unicode will keep supplying scalars that render as nothing, each
    /// one is another round of this, and three rounds of adversarial review have each found the next
    /// one — a combining mark, then the invisible spaces, then the braille blank.
    ///
    /// **SONNY-234 is what ends the class, and this function is the interim.** That ticket makes the
    /// delimiter unguessable — a random tag generated at wrap time, after the untrusted content already
    /// exists — so a forgery is not a delimiter regardless of how it renders, and the question of
    /// whether a blank-looking scalar is "close enough" stops being asked. Until then this predicate is
    /// deliberately over-inclusive: over-matching brackets a string that was going to be read as the
    /// delimiter anyway, and there is no legitimate text with an invisible scalar inside a
    /// thirty-character SCREAMING_SNAKE identifier.
    ///
    /// **What is not stepped over, and why neither reason is about rendering.** The line breakers — CR,
    /// LF, VT, FF, NEL, U+2028, U+2029 — because a delimiter split by one of them is genuinely on two
    /// lines, and two lines cannot forge the single boundary line this wrapper is read by. And U+0020,
    /// but **only after the delimiter's last letter, never inside it** — see
    /// `isIgnorableAfterADelimiter`.
    ///
    /// **Insertion is closed; substitution is a near-miss and stays open.** A separator standing *in
    /// place of* a delimiter character produces a different string: `_` is an expected scalar, and a
    /// skipped scalar cannot supply it, so `UNTRUSTED_OBSERVED CONTENT_END` matches nothing here even
    /// though every separator is stepped over. That is the same near-miss `escapeAttribute` folds to `_`
    /// before escaping (SONNY-219), and it is untouched by any of this.
    ///
    /// **Canonically equivalent spellings match, which is not a homoglyph concession** (PR #100 review,
    /// F2). `UNTRUSTED_OBSERVED_CONTENT_` + U+00C9 + `ND` and the same string written `E` + U+0301 are
    /// *the same text* by Unicode's own definition — Swift's `==` reports them equal — so closing one
    /// spelling and leaving the other open was incoherent rather than a bounded decision, and it was
    /// the precomposed spelling, the one a reader is most likely to type, that stayed open. A content
    /// scalar therefore matches an expected one when it *canonically decomposes* to it followed only by
    /// marks. That is canonical equivalence, a fixed Unicode relation, and it reaches nothing else.
    ///
    /// **What it still deliberately does not close.** A *different character* that merely looks similar:
    /// a Cyrillic `Е` (U+0415), a fullwidth `Ｅ` (U+FF25), a lowercase `end`. None is canonically
    /// equivalent to `E`; each is its own character. That tail is unbounded and matching cannot win it.
    /// Compatibility normalisation (NFKD) would fold the fullwidth forms and nothing else on that list,
    /// buying an arbitrary slice of an infinite problem while making the escaped output depend on a
    /// Unicode table version. The system prompts naming the observed segment as data are the backstop
    /// for what matching cannot reach, and they are unchanged.
    ///
    /// **The output is never normalised.** Only a matched run is replaced; every other scalar is
    /// emitted exactly as it arrived, so `escape` does not silently rewrite `café` into either
    /// spelling. `ordinaryTextIsUntouched` compares scalar arrays rather than `==` for that reason —
    /// `==` is itself canonical-equivalence-based and could not tell the difference.
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
        // One canonical base per scalar, computed once for the whole input rather than per delimiter
        // per position — four targets are tried at most positions, and decomposing inside that loop
        // would pay for the same scalar four times.
        let bases = scalars.map(canonicalBase(of:))
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            // A match may never *begin* on an ignorable scalar. Without this, a combining acute in
            // "cafe\u{0301}UNTRUSTED_…" would be swallowed into the replaced range and the accent
            // would vanish from text that had nothing to do with the forgery.
            if !isIgnorableInsideADelimiter(scalars[index]),
               let match = targets.lazy.compactMap({ target -> (text: String, end: Int)? in
                   guard let end = matchEnd(of: target.scalars, at: index, in: scalars, bases: bases) else {
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

    /// The scalar a delimiter's letter has to be compared against: `scalar` itself, unless it
    /// canonically decomposes to a single base followed only by marks, in which case that base.
    ///
    /// **Guarded on `uppercaseLetter`, and that guard is a measured fact rather than a hopeful range.**
    /// Across the entire scalar range, **exactly 244 scalars canonically decompose to an ASCII `[A-Z_]`
    /// base followed only by marks, and all 244 are category `uppercaseLetter`**, spanning U+00C0 to
    /// U+212B — U+212A KELVIN SIGN and U+212B ANGSTROM SIGN included, which is why the range runs past
    /// the Latin blocks. `theCanonicalBaseGuardCoversEveryScalarThatDecomposesToAnASCIIBase` re-derives
    /// it over U+0080–U+212B on every run and asserts the count; a second reviewer re-derived it over
    /// the whole `0...0x10FFFF` range independently. Unicode's normalisation stability policy is why
    /// that census does not go stale: canonical decompositions of existing characters cannot change.
    ///
    /// **What the guard buys, corrected — the figure this comment used to carry did not reproduce**
    /// (PR #100 review round 2, F5). Timing the `scalars.map(canonicalBase)` pass alone over a
    /// 173 334-scalar / 520 002-byte varied-CJK page, in the debug configuration the suite runs in,
    /// with the two predicates written out identically apart from the guard: **17.0 ms guarded,
    /// 99.7 ms unguarded, a delta of 82.8 ms**, outputs identical (a `@testable` scratch suite over
    /// `String` built from U+4E00 upward, best of three; an independent reviewer measured 22.9 ms
    /// against 136.7 ms on the same shape). The old figure said "283ms to nothing" and both halves were
    /// wrong: 283 ms was measured over 512 000 *scalars* — about 1.5 MB of UTF-8 for CJK, roughly three
    /// times the page it was labelled as — and 17.0 ms is not nothing. The guard is worth having and
    /// the direction was right; the number was a mislabelled scalar count reported as a byte size.
    /// `readableText` is uncapped (`WebResearchService.readableLines` applies no limit), so an attacker
    /// chooses that size, which is why the pass is worth guarding at all.
    ///
    private static func canonicalBase(of scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x80, scalar.properties.generalCategory == .uppercaseLetter else {
            return scalar
        }
        let decomposed = Array(String(scalar).decomposedStringWithCanonicalMapping.unicodeScalars)
        // **The all-marks tail check is unreachable, and that is measured rather than assumed.** A
        // canonical decomposition is a singleton mapping or a base followed by combining marks, never
        // a base followed by anything else, so across `0...0x10FFFF` there are **zero** scalars that
        // would take this branch — which is why the mutant deleting it survives every battery and no
        // test can kill it. It is kept because deleting it trades one line for a silent over-match if
        // that invariant is ever wrong, and the invariant itself is asserted by
        // `theCanonicalBaseGuardCoversEveryScalarThatDecomposesToAnASCIIBase` so the guard's
        // precondition fails loudly rather than the guard sitting there unexamined.
        guard let base = decomposed.first, base.value < 0x80,
              decomposed.dropFirst().allSatisfy(isMark) else {
            return scalar
        }
        return base
    }

    /// Where a match of `needle` starting at `start` ends, or `nil` if there is none.
    ///
    /// Ignorable scalars are skipped before each expected scalar and again after the last one, but the
    /// two skips take **different sets** — `isIgnorableInsideADelimiter` and
    /// `isIgnorableAfterADelimiter`, which differ by U+0020 alone. The trailing skip is what makes the
    /// escaped form identical however the delimiter was decorated; excluding the ordinary space from it
    /// is what stops that canonicalisation eating a space out of ordinary text.
    private static func matchEnd(
        of needle: [Unicode.Scalar],
        at start: Int,
        in scalars: [Unicode.Scalar],
        bases: [Unicode.Scalar]
    ) -> Int? {
        var cursor = start
        for expected in needle {
            while cursor < scalars.count, isIgnorableInsideADelimiter(scalars[cursor]) {
                cursor += 1
            }
            guard cursor < scalars.count, bases[cursor] == expected else {
                return nil
            }
            cursor += 1
        }
        while cursor < scalars.count, isIgnorableAfterADelimiter(scalars[cursor]) {
            cursor += 1
        }
        return cursor
    }

    /// Scalars that render as nothing and that no general-category test reaches.
    ///
    /// One member today. U+2800 BRAILLE PATTERN BLANK is the braille cell with no dots raised: category
    /// `So`, not default-ignorable, and blank in every font that carries braille — which is why it is
    /// the standard way to fake whitespace in chat clients, and why it defeated a predicate built from
    /// categories alone (PR #100 review round 2, F3). Listed by scalar rather than by category because
    /// `So` also contains `©`, `°` and most emoji, every one of which is visible. The rest of the
    /// braille block has dots raised and is visible, so the block is not the unit either.
    private static let blankRenderingScalars: Set<Unicode.Scalar> = ["\u{2800}"]

    /// Whether `scalar` contributes no visible glyph, and so can be hidden **inside** a delimiter by a
    /// forger. See `neutralizingDelimiters` for why this test is perceptual and what ends that.
    ///
    /// **Every branch is held by a corpus entry, because a branch no test holds is a comment** — this
    /// function has now shipped twice with a clause nothing exercised (PR #100 review, F3; and its own
    /// M6 lesson before that):
    ///
    /// - the three **mark** categories — U+0301, and U+20DD which is `Me` rather than `Mn`;
    /// - **`.format`** — held by U+0600 ARABIC NUMBER SIGN, which is `Cf` and is **not**
    ///   default-ignorable. An earlier justification for this clause named U+200B, which *is*
    ///   default-ignorable and therefore establishes nothing about it;
    /// - **`isDefaultIgnorableCodePoint`** — held by U+3164 HANGUL FILLER, category `Lo`, caught by
    ///   no other branch;
    /// - **`.spaceSeparator`** — held by U+200A HAIR SPACE and now by U+0020 itself;
    /// - **`.control`** — held by U+0009 TAB;
    /// - **`blankRenderingScalars`** — held by U+2800.
    ///
    /// The only exclusion is `CharacterSet.newlines`, and it is not about rendering: a delimiter split
    /// by a real line break is two lines, and two lines cannot forge one boundary line.
    private static func isIgnorableInsideADelimiter(_ scalar: Unicode.Scalar) -> Bool {
        guard !CharacterSet.newlines.contains(scalar) else {
            return false
        }
        if blankRenderingScalars.contains(scalar) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format, .spaceSeparator, .control:
            return true
        default:
            return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// The same, for the scalars **following** a completed match — everything above except U+0020.
    ///
    /// **The two positions are not the same question, and conflating them was the whole cost of
    /// closing U+0020** (PR #100 review round 2, F1). Inside a delimiter an ordinary space cannot
    /// be legitimate: nothing puts one in the middle of a thirty-character identifier, so a space
    /// there is a forgery every time. Immediately *after* one it is the most ordinary character
    /// there is — `escape("UNTRUSTED_OBSERVED_CONTENT_BEGIN tail")` must keep its space.
    ///
    /// **No consumer of this function reaches a surface a person reads, so that cost is
    /// prospective rather than live — and an earlier version of this note named a path that does
    /// not exist** (PR #100 records round, finding 1). It said a swallowed space "reaches the
    /// user through `WebResearchMarkdownCapabilityAdapter`'s `escape(note.summary)`". That
    /// adapter never calls this type at all: `git grep -n "UntrustedContentBoundary" --
    /// Sources/MacAgentCore/WebResearchMarkdownCapabilityAdapter.swift` exits 1 with no output at
    /// `c92600f`, and its own `escape` is a different function on a different type that folds
    /// newlines in the *model's* note.
    ///
    /// Traced properly: every caller of `neutralizingDelimiters` — `escape`, `escapeURLValue`,
    /// `escapeAttribute`, `trustedInstruction`, `observedContent`, and
    /// `PriorTaskContext.escapeForPlanner` — produces prompt text, and every one of those strings
    /// is handed to a model API and to nothing else (`OpenAIPlanner.requestBody`,
    /// `CerebrasPlanner.requestBody`, `VisionModelClient.decide`,
    /// `WebResearchSynthesisPrompt.requestBody`). Nothing persists a prompt and nothing renders
    /// one; the single place a request body travels further is `AIUsageRecord.responses`'
    /// `estimatedInputText`, which `AIUsageEstimator.estimateTextTokens` turns into a count
    /// before the record stores anything.
    ///
    /// **So the carve-out is precautionary, and a reader deciding whether it can be deleted
    /// should know that.** It is kept because silently deleting a space out of escaped text is
    /// the kind of corruption a future consumer inherits without noticing — not because a user
    /// can see one today. If a rendering path is ever added, this paragraph is the one to re-
    /// check rather than rewrite.
    ///
    /// Everything else is still consumed here, which is what keeps the escaped form identical however
    /// the delimiter was decorated: the mark or zero-width scalar an attacker hung on the final letter
    /// is theirs, and leaving it behind would re-attach it to the `]` of the replacement.
    private static func isIgnorableAfterADelimiter(_ scalar: Unicode.Scalar) -> Bool {
        scalar != " " && isIgnorableInsideADelimiter(scalar)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
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
