import Foundation

/// The look-alikes of the ASCII letters that the on-device recognizer can type in their place,
/// folded back to the letter the glyph was — so that ``SecretTextDetector``'s exact patterns match
/// what a human reads off the screen rather than what Vision happened to emit (SONNY-272).
///
/// **Why this exists.** SONNY-260 measured the real recognizer reading a rendered
/// `api_key=sk-Abc123Def456Ghi789JklMno012Pqr` with four of its letters substituted from other
/// scripts: the `a` of `api` as U+0430 CYRILLIC SMALL LETTER A, the `A` of `Abc` as U+0410, the `o`
/// of `Mno` as U+043E, and the final `r` as U+0131 LATIN SMALL LETTER DOTLESS I. Every api-key
/// pattern in the detector is an exact match, so one substituted letter is enough for the key to
/// ship unpainted — the labeled pattern never sees `api`, and a non-ASCII letter at the end of a
/// token is a word character, so the `\b` the vendor-prefix and high-entropy patterns close on is
/// not there either. Folding before matching is the founder's decision of 2026-08-24, recorded on
/// SONNY-272: the false-positive risk is near zero, because turning U+0430 into a Latin `a`
/// does not make ordinary screen text look like an API key.
///
/// **This is the tree's one look-alike fold, and it is not a copy of the three folds it already
/// has.** `normalized(_:)` in `AutomationStores.swift` folds case and diacritics so that routine and
/// workspace names compare; `MacAppCatalog.normalize` and `ScreenControlPolicy.normalize` do the
/// same job for app names and bundle identifiers; and `UntrustedContentBoundary.canonicalBase(of:)`
/// matches a delimiter through *canonical* equivalence only — it deliberately refuses look-alikes,
/// and must keep refusing them, because there a look-alike is a forgery to leave alone and the
/// frontier of "looks like" has no bottom. Here a look-alike is a *misreading to see through*, on
/// text that goes to a matcher and nowhere else, so the question is different and so is the answer.
/// None of the three can do this job: a diacritic fold leaves U+0430 alone (it is a different letter,
/// not `a` with a mark), and canonical equivalence leaves all four measured scalars alone by design.
///
/// **The rule, stated exactly as `scripts/confusables-table` implements it.** A scalar folds when
/// (1) it is not ASCII; (2) UTS #39's `confusables.txt` maps it to exactly one scalar; (3) that
/// scalar is an ASCII letter; (4) the source is itself a letter — general category `L*` — so no
/// digit, symbol or mark of any script is ever folded, whatever the table says it resembles; and
/// (5) the source lies in a block of a script Vision's accurate recognizer can emit — the scripts
/// its supported recognition languages are written in on macOS 25.5.0 (Latin outside ASCII,
/// Cyrillic, Arabic, Thai, Han, Kana, Hangul; `VNRecognizeTextRequest.supportedRecognitionLanguages()`
/// lists thirty languages and no Greek one). The fifty-two fullwidth Latin letters fold too, by
/// arithmetic rather than from the table: each is its ASCII letter by Unicode's compatibility
/// decomposition, which is a definition rather than a resemblance, and UTS #39 covers only
/// thirty-two of them and sends fullwidth `I` to `l`. ``table`` is generated, not hand-written —
/// the block below is what `scripts/confusables-table <confusables.txt> --write` produces, and
/// `--check` says whether it still is — and ``LatinConfusablesTests`` holds every clause of the rule
/// a test can hold, in both directions.
///
/// **What it deliberately does not fold**, so the next reader does not mistake a gap for an
/// oversight. ASCII look-alikes of each other — `0` for `O`, `1` for `l`, `5` for `S`, the `5k-`
/// flavour SONNY-260 also measured — because every one of those is ordinary text and folding them
/// would paint it; that flavour stays open and is not approved. Digits of other scripts that UTS #39
/// maps to letters (Arabic-Indic one to `l`, Thai zero to `o`): a digit stays a digit. Multi-scalar
/// targets (U+0133 LATIN SMALL LIGATURE IJ to `ij`, U+044B CYRILLIC SMALL LETTER YERU to `bl`) —
/// the fold is scalar-for-scalar so that ranges map back by ordinal. Scripts Vision cannot produce — Greek, the mathematical alphanumerics,
/// Cherokee, Armenian and the rest of the table — because a fold that reached them would be
/// describing adversarial text, which is the boundary's problem and not this one. And the two
/// other OCR flavours on record, a dropped leading `api` and `sk-` read as `5k-`, which no textual
/// fold restores.
///
/// **The output of matching is never the folded text.** ``fold(_:)-swift.type.method`` returns the
/// folded string *and* the way back: `SecretTextDetector` matches over `Folded.text` and reports
/// ranges into the caller's own string, so the masked text keeps every scalar the reader saw and
/// nothing here rewrites `café` or a Cyrillic word into anything else. Same principle as the
/// boundary's, arrived at for the same reason.
///
/// Scalars in this file and its tests are written as `\u{}` escapes, never pasted: U+0430 and a
/// Latin `a` are indistinguishable in a record, and that confusion has already cost this
/// repository a round of review (`.claude/rules/macagentcore-conventions.md`).
enum LatinConfusables {
    /// One string folded, with the way back into the string it was folded from.
    struct Folded {
        /// The text to match against — scalar-for-scalar with the original, every look-alike replaced
        /// by its ASCII letter and everything else exactly as it arrived.
        let text: String

        /// `nil` when nothing folded, in which case ``text`` *is* the original string and every index
        /// into it is already an index into the original. Otherwise the original's index for each
        /// scalar ordinal of ``text``, with the original's end index last — the fold is
        /// scalar-for-scalar, so ordinals are the whole of the mapping.
        private let originalScalarIndices: [String.Index]?

        fileprivate init(text: String, originalScalarIndices: [String.Index]?) {
            self.text = text
            self.originalScalarIndices = originalScalarIndices
        }

        /// The original string's range for a range of ``text``.
        func originalRange(of range: Range<String.Index>) -> Range<String.Index> {
            originalIndex(of: range.lowerBound)..<originalIndex(of: range.upperBound)
        }

        /// The original string's index for an index of ``text``. Any index at a scalar boundary of
        /// ``text`` maps; a regex match's bounds always are.
        func originalIndex(of index: String.Index) -> String.Index {
            guard let originalScalarIndices else {
                return index
            }
            let ordinal = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
            return originalScalarIndices[ordinal]
        }
    }

    /// The ASCII letter `scalar` is a look-alike of, or `scalar` itself.
    static func fold(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let value = scalar.value
        guard value >= 0x80 else {
            return scalar
        }
        if let letter = table[value] {
            return Unicode.Scalar(letter)
        }
        if (0xFF21...0xFF3A).contains(value) || (0xFF41...0xFF5A).contains(value) {
            // FULLWIDTH LATIN CAPITAL LETTER A is U+FF21 and A is U+0041, and the whole block keeps
            // that offset; compatibility decomposition says the same thing one scalar at a time.
            return Unicode.Scalar(UInt8(value - 0xFEE0))
        }
        return scalar
    }

    /// `text` with every look-alike folded, and the mapping back.
    ///
    /// Almost every string folds nothing — screen text is overwhelmingly ASCII, and even a Cyrillic
    /// screen mostly carries letters with no Latin twin — so that case costs one pass over the
    /// scalars and no allocation: the original string comes back as ``Folded/text`` and the mapping
    /// is the identity.
    static func fold(_ text: String) -> Folded {
        guard text.unicodeScalars.contains(where: { fold($0) != $0 }) else {
            return Folded(text: text, originalScalarIndices: nil)
        }
        var folded = String.UnicodeScalarView()
        var originalScalarIndices: [String.Index] = []
        originalScalarIndices.reserveCapacity(text.unicodeScalars.count + 1)
        for index in text.unicodeScalars.indices {
            originalScalarIndices.append(index)
            folded.append(fold(text.unicodeScalars[index]))
        }
        originalScalarIndices.append(text.unicodeScalars.endIndex)
        return Folded(text: String(folded), originalScalarIndices: originalScalarIndices)
    }

    // BEGIN generated by scripts/confusables-table — do not edit by hand
    // Unicode 17.0.0 confusables.txt dated 2025-07-22; 98 entries.
    static let table: [UInt32: UInt8] = [
        0x00FE: 0x70, // LATIN SMALL LETTER THORN -> p
        0x0131: 0x69, // LATIN SMALL LETTER DOTLESS I -> i
        0x017F: 0x66, // LATIN SMALL LETTER LONG S -> f
        0x0184: 0x62, // LATIN CAPITAL LETTER TONE SIX -> b
        0x018D: 0x67, // LATIN SMALL LETTER TURNED DELTA -> g
        0x0192: 0x66, // LATIN SMALL LETTER F WITH HOOK -> f
        0x0196: 0x6C, // LATIN CAPITAL LETTER IOTA -> l
        0x01A6: 0x52, // LATIN LETTER YR -> R
        0x01BD: 0x73, // LATIN SMALL LETTER TONE FIVE -> s
        0x01BF: 0x70, // LATIN LETTER WYNN -> p
        0x01C0: 0x6C, // LATIN LETTER DENTAL CLICK -> l
        0x0251: 0x61, // LATIN SMALL LETTER ALPHA -> a
        0x0261: 0x67, // LATIN SMALL LETTER SCRIPT G -> g
        0x0263: 0x79, // LATIN SMALL LETTER GAMMA -> y
        0x0269: 0x69, // LATIN SMALL LETTER IOTA -> i
        0x026A: 0x69, // LATIN LETTER SMALL CAPITAL I -> i
        0x026F: 0x77, // LATIN SMALL LETTER TURNED M -> w
        0x028B: 0x75, // LATIN SMALL LETTER V WITH HOOK -> u
        0x028F: 0x79, // LATIN LETTER SMALL CAPITAL Y -> y
        0x0405: 0x53, // CYRILLIC CAPITAL LETTER DZE -> S
        0x0406: 0x6C, // CYRILLIC CAPITAL LETTER BYELORUSSIAN-UKRAINIAN I -> l
        0x0408: 0x4A, // CYRILLIC CAPITAL LETTER JE -> J
        0x0410: 0x41, // CYRILLIC CAPITAL LETTER A -> A
        0x0412: 0x42, // CYRILLIC CAPITAL LETTER VE -> B
        0x0415: 0x45, // CYRILLIC CAPITAL LETTER IE -> E
        0x041A: 0x4B, // CYRILLIC CAPITAL LETTER KA -> K
        0x041C: 0x4D, // CYRILLIC CAPITAL LETTER EM -> M
        0x041D: 0x48, // CYRILLIC CAPITAL LETTER EN -> H
        0x041E: 0x4F, // CYRILLIC CAPITAL LETTER O -> O
        0x0420: 0x50, // CYRILLIC CAPITAL LETTER ER -> P
        0x0421: 0x43, // CYRILLIC CAPITAL LETTER ES -> C
        0x0422: 0x54, // CYRILLIC CAPITAL LETTER TE -> T
        0x0423: 0x59, // CYRILLIC CAPITAL LETTER U -> Y
        0x0425: 0x58, // CYRILLIC CAPITAL LETTER HA -> X
        0x042C: 0x62, // CYRILLIC CAPITAL LETTER SOFT SIGN -> b
        0x0430: 0x61, // CYRILLIC SMALL LETTER A -> a
        0x0433: 0x72, // CYRILLIC SMALL LETTER GHE -> r
        0x0435: 0x65, // CYRILLIC SMALL LETTER IE -> e
        0x043E: 0x6F, // CYRILLIC SMALL LETTER O -> o
        0x0440: 0x70, // CYRILLIC SMALL LETTER ER -> p
        0x0441: 0x63, // CYRILLIC SMALL LETTER ES -> c
        0x0443: 0x79, // CYRILLIC SMALL LETTER U -> y
        0x0445: 0x78, // CYRILLIC SMALL LETTER HA -> x
        0x0448: 0x77, // CYRILLIC SMALL LETTER SHA -> w
        0x0455: 0x73, // CYRILLIC SMALL LETTER DZE -> s
        0x0456: 0x69, // CYRILLIC SMALL LETTER BYELORUSSIAN-UKRAINIAN I -> i
        0x0458: 0x6A, // CYRILLIC SMALL LETTER JE -> j
        0x0461: 0x77, // CYRILLIC SMALL LETTER OMEGA -> w
        0x0474: 0x56, // CYRILLIC CAPITAL LETTER IZHITSA -> V
        0x0475: 0x76, // CYRILLIC SMALL LETTER IZHITSA -> v
        0x04AE: 0x59, // CYRILLIC CAPITAL LETTER STRAIGHT U -> Y
        0x04AF: 0x79, // CYRILLIC SMALL LETTER STRAIGHT U -> y
        0x04BB: 0x68, // CYRILLIC SMALL LETTER SHHA -> h
        0x04BD: 0x65, // CYRILLIC SMALL LETTER ABKHASIAN CHE -> e
        0x04C0: 0x6C, // CYRILLIC LETTER PALOCHKA -> l
        0x04CF: 0x6C, // CYRILLIC SMALL LETTER PALOCHKA -> l
        0x0501: 0x64, // CYRILLIC SMALL LETTER KOMI DE -> d
        0x050C: 0x47, // CYRILLIC CAPITAL LETTER KOMI SJE -> G
        0x051B: 0x71, // CYRILLIC SMALL LETTER QA -> q
        0x051C: 0x57, // CYRILLIC CAPITAL LETTER WE -> W
        0x051D: 0x77, // CYRILLIC SMALL LETTER WE -> w
        0x0627: 0x6C, // ARABIC LETTER ALEF -> l
        0x0647: 0x6F, // ARABIC LETTER HEH -> o
        0x06BE: 0x6F, // ARABIC LETTER HEH DOACHASHMEE -> o
        0x06C1: 0x6F, // ARABIC LETTER HEH GOAL -> o
        0x06D5: 0x6F, // ARABIC LETTER AE -> o
        0x1E9D: 0x66, // LATIN SMALL LETTER LONG S WITH HIGH STROKE -> f
        0x1EFF: 0x79, // LATIN SMALL LETTER Y WITH LOOP -> y
        0xA647: 0x69, // CYRILLIC SMALL LETTER IOTA -> i
        0xA731: 0x73, // LATIN LETTER SMALL CAPITAL S -> s
        0xA798: 0x46, // LATIN CAPITAL LETTER F WITH STROKE -> F
        0xA799: 0x66, // LATIN SMALL LETTER F WITH STROKE -> f
        0xA79F: 0x75, // LATIN SMALL LETTER VOLAPUK UE -> u
        0xA7B2: 0x4A, // LATIN CAPITAL LETTER J WITH CROSSED-TAIL -> J
        0xA7B3: 0x58, // LATIN CAPITAL LETTER CHI -> X
        0xA7B4: 0x42, // LATIN CAPITAL LETTER BETA -> B
        0xAB32: 0x65, // LATIN SMALL LETTER BLACKLETTER E -> e
        0xAB35: 0x66, // LATIN SMALL LETTER LENIS F -> f
        0xAB3D: 0x6F, // LATIN SMALL LETTER BLACKLETTER O -> o
        0xAB47: 0x72, // LATIN SMALL LETTER R WITHOUT HANDLE -> r
        0xAB48: 0x72, // LATIN SMALL LETTER DOUBLE R -> r
        0xAB4E: 0x75, // LATIN SMALL LETTER U WITH SHORT RIGHT LEG -> u
        0xAB52: 0x75, // LATIN SMALL LETTER U WITH LEFT HOOK -> u
        0xAB5A: 0x79, // LATIN SMALL LETTER Y WITH SHORT RIGHT LEG -> y
        0xFBA6: 0x6F, // ARABIC LETTER HEH GOAL ISOLATED FORM -> o
        0xFBA7: 0x6F, // ARABIC LETTER HEH GOAL FINAL FORM -> o
        0xFBA8: 0x6F, // ARABIC LETTER HEH GOAL INITIAL FORM -> o
        0xFBA9: 0x6F, // ARABIC LETTER HEH GOAL MEDIAL FORM -> o
        0xFBAA: 0x6F, // ARABIC LETTER HEH DOACHASHMEE ISOLATED FORM -> o
        0xFBAB: 0x6F, // ARABIC LETTER HEH DOACHASHMEE FINAL FORM -> o
        0xFBAC: 0x6F, // ARABIC LETTER HEH DOACHASHMEE INITIAL FORM -> o
        0xFBAD: 0x6F, // ARABIC LETTER HEH DOACHASHMEE MEDIAL FORM -> o
        0xFE8D: 0x6C, // ARABIC LETTER ALEF ISOLATED FORM -> l
        0xFE8E: 0x6C, // ARABIC LETTER ALEF FINAL FORM -> l
        0xFEE9: 0x6F, // ARABIC LETTER HEH ISOLATED FORM -> o
        0xFEEA: 0x6F, // ARABIC LETTER HEH FINAL FORM -> o
        0xFEEB: 0x6F, // ARABIC LETTER HEH INITIAL FORM -> o
        0xFEEC: 0x6F, // ARABIC LETTER HEH MEDIAL FORM -> o
    ]
    // END generated by scripts/confusables-table
}
