import Foundation

/// What kind of secret a detection matched. §12.3's detect list, minus the two policy-gated
/// classes (email addresses, phone numbers — "where policy requires" is enterprise-later and a
/// recorded non-goal of SONNY-89).
public enum SecretDetectionClass: String, Codable, CaseIterable, Equatable, Sendable {
    case apiKey = "api_key"
    case accessToken = "access_token"
    case passwordField = "password_field"
    case oneTimeCode = "one_time_code"
    case creditCardNumber = "credit_card_number"
    case socialSecurityNumber = "social_security_number"
    case privateKey = "private_key"

    public var displayName: String {
        switch self {
        case .apiKey: return "API key"
        case .accessToken: return "Access token"
        case .passwordField: return "Password field"
        case .oneTimeCode: return "One-time code"
        case .creditCardNumber: return "Credit card number"
        case .socialSecurityNumber: return "Social Security number"
        case .privateKey: return "Private key"
        }
    }
}

struct SecretTextMatch: Equatable {
    var detectionClass: SecretDetectionClass
    var range: Range<String.Index>
    var confidence: Double
}

/// Pattern-based secret detection over plain text. Deliberately heuristic — §12.3's clarified
/// confidence handling is built on the premise that this has real false-negative rates, which is
/// why every match carries a confidence and the service redacts below-threshold shapes anyway.
///
/// Confidence assignments are structural, not tuned: a match whose *validity* the detector can
/// verify (a known vendor prefix, a passing Luhn check, an in-range SSN, a key-block marker)
/// sits above the service's default threshold; a match that is only *shaped* like a secret
/// (high-entropy blob, Luhn-failing card shape, out-of-range SSN, unlabeled bullet run, spaced
/// digit pair) sits below it and rides the fail-closed redact-and-flag path.
///
/// **Every pattern matches over look-alike-folded text** (SONNY-272). The recognizer can type a
/// letter from another script in place of the one it saw — SONNY-260 measured U+0430 for the `a`
/// of `api`, U+0410 for the `A` of `Abc`, U+043E for the `o` of `Mno` and U+0131 for a final `r`,
/// all in one reading of one key — and every pattern here is exact, so one such letter costs the
/// match. `matches(in:)` therefore folds the whole document once through ``LatinConfusables``
/// before any class runs, and maps every range it found back into the caller's text before
/// coalescing, so a match's `range` is always a range of the string the caller passed and
/// ``mask(matches:in:)`` keeps every scalar the reader saw. The fold is document-wide rather than
/// api-key-only because all seven classes are exact matches with the same exposure — `Bearer`,
/// `eyJ`, `password`, `BEGIN … PRIVATE KEY` — and a per-class fold would be a second call to make
/// the day one of them is next. What the fold does and deliberately does not reach is stated at
/// `LatinConfusables`; the OCR flavours it cannot restore (a dropped leading `api`, `sk-` read as
/// `5k-`) stay open, and spec §12.3 already calls this path best-effort for exactly that reason.
struct SecretTextDetector {
    static let maskReplacement = "•••••"

    func matches(in text: String) -> [SecretTextMatch] {
        let folded = LatinConfusables.fold(text)
        var found: [SecretTextMatch] = []
        found += privateKeyMatches(in: folded.text)
        found += apiKeyMatches(in: folded.text)
        found += accessTokenMatches(in: folded.text)
        found += passwordFieldMatches(in: folded.text)
        found += oneTimeCodeMatches(in: folded.text)
        found += creditCardMatches(in: folded.text)
        found += ssnMatches(in: folded.text)
        let inCallersText = found.map { match in
            SecretTextMatch(
                detectionClass: match.detectionClass,
                range: folded.originalRange(of: match.range),
                confidence: match.confidence
            )
        }
        return Self.coalesceOverlaps(inCallersText)
    }

    /// Replaces every match with a fixed-width mask (never length-preserving — a mask that
    /// mirrors the secret's length leaks its length). Context around a match is kept, so
    /// "password: hunter2" masks to "password: •••••".
    static func mask(matches: [SecretTextMatch], in text: String) -> String {
        var masked = text
        for match in matches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            masked.replaceSubrange(match.range, with: maskReplacement)
        }
        return masked
    }

    // MARK: - Per-class detection

    private func privateKeyMatches(in text: String) -> [SecretTextMatch] {
        let begin = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/
        let end = /-----END [A-Z0-9 ]*PRIVATE KEY-----/
        var results: [SecretTextMatch] = []
        for beginMatch in text.matches(of: begin) {
            // The block runs to its END marker when present; a truncated block (screen cut off
            // mid-key) still redacts to the end of the text — fail closed on the whole tail.
            let tail = text[beginMatch.range.upperBound...]
            let upper = tail.firstMatch(of: end)?.range.upperBound ?? text.endIndex
            results.append(SecretTextMatch(
                detectionClass: .privateKey,
                range: beginMatch.range.lowerBound..<upper,
                confidence: 1.0
            ))
        }
        return results
    }

    private func apiKeyMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        // Known vendor prefixes are self-identifying.
        let prefixed = /\b(?:sk-[A-Za-z0-9_-]{16,}|sk_(?:live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35})\b/
        for match in text.matches(of: prefixed) {
            results.append(SecretTextMatch(detectionClass: .apiKey, range: match.range, confidence: 0.95))
        }

        // A labeled value: mask the value, keep the label.
        let labeled = /(?i)\b(?:api[ _-]?key|apikey|secret[ _-]?key|client[ _-]?secret)\s*[:=]\s*(\S{12,})/
        for match in text.matches(of: labeled) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .apiKey,
                range: value.startIndex..<value.endIndex,
                confidence: 0.9
            ))
        }

        // Unlabeled high-entropy blob: only *shaped* like a key, so below threshold by design.
        let blob = /\b[A-Za-z0-9]{32,}\b/
        for match in text.matches(of: blob) {
            let candidate = text[match.range]
            let hasDigit = candidate.contains { $0.isNumber }
            let hasLower = candidate.contains { $0.isLowercase }
            let hasUpper = candidate.contains { $0.isUppercase }
            if hasDigit, hasLower, hasUpper {
                results.append(SecretTextMatch(detectionClass: .apiKey, range: match.range, confidence: 0.5))
            }
        }
        return results
    }

    private func accessTokenMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        let jwt = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}/
        for match in text.matches(of: jwt) {
            results.append(SecretTextMatch(detectionClass: .accessToken, range: match.range, confidence: 0.95))
        }

        let bearer = /\bBearer\s+([A-Za-z0-9._~+\/=-]{16,})/
        for match in text.matches(of: bearer) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .accessToken,
                range: value.startIndex..<value.endIndex,
                confidence: 0.95
            ))
        }

        let labeled = /(?i)\b(?:access[ _-]?token|auth[ _-]?token|refresh[ _-]?token|session[ _-]?token|token)\s*[:=]\s*(\S{12,})/
        for match in text.matches(of: labeled) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .accessToken,
                range: value.startIndex..<value.endIndex,
                confidence: 0.85
            ))
        }
        return results
    }

    private func passwordFieldMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        let labeled = /(?i)\b(?:password|passwd|pwd|passphrase)\s*[:=]\s*(\S+)/
        for match in text.matches(of: labeled) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .passwordField,
                range: value.startIndex..<value.endIndex,
                confidence: 0.9
            ))
        }

        // A run of bullet characters is how a password field *renders* on screen. Unlabeled,
        // it is only password-shaped — below threshold, redact-and-flag.
        let bullets = /[•●*]{5,}/
        for match in text.matches(of: bullets) {
            results.append(SecretTextMatch(detectionClass: .passwordField, range: match.range, confidence: 0.7))
        }
        return results
    }

    private func oneTimeCodeMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        // The context word must begin a word, and "begin" is "not preceded by a letter of any
        // script" rather than `\b` (PR #116 review, F2). Without it a *suffix* was a context word:
        // `Barcode 123456` matched on `code`, and once the fold landed, an all-caps Cyrillic word
        // folded into one — the Russian word for "view", U+041F U+0420 U+041E U+0421 U+041C U+041E
        // U+0422 U+0420, folds to `…MOTP`, so with `: 123456` after it the line matched at 0.85,
        // above the threshold. `[^\p{L}]` rather than `\b` because an underscore is a word
        // character: `otp_code=123456` and `verification_code: 483291` are how forms and JSON label
        // the field, and `\b` would drop both. An unfolded letter (U+0416, which has no Latin twin)
        // is a letter too, so a look-alike glued to a Cyrillic word cannot fake the start of one
        // either. (Code points rather than pasted letters, per the conventions file.)
        // **The value may be a separated pair as well as a run of digits (SONNY-278).** `\d{6,8}`
        // alone could not see `code: 483-291` or `code: 483 291`, so a labelled code that renders
        // with a separator reached the spaced-pair rule below at 0.55 or, when the separator sat
        // straight after the colon, nothing at all. It is here rather than as a third pattern
        // because it is the same question — a context word, then a value — and because the
        // refusals below deliberately drop `code:483-291`, which this alternative catches. Measured
        // over the corpus named at the spaced pair: widening this alternation added **0** matches
        // the tree did not already have.
        let contextual = /(?i)(?:^|[^\p{L}])(?:code|otp|2fa|passcode|verification|authenticator|one[ -]?time)\b\D{0,20}?(\d{3}[ -]\d{3}|\d{6,8})\b/
        for match in text.matches(of: contextual) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .oneTimeCode,
                range: value.startIndex..<value.endIndex,
                confidence: 0.85
            ))
        }

        // "483 291"-style spaced pairs are the standard OTP display shape; without a context
        // word nearby the match is shape-only, so below threshold. The lookahead plus the manual
        // preceding-character check (Swift Regex has no lookbehind) keep this from firing inside
        // longer digit runs (phone numbers, card numbers).
        //
        // **Two further refusals, and both are measured rather than argued (SONNY-278).** A match
        // here paints its whole observation line for the vision model — painting is per-observation
        // and does not read confidence, so a 0.55 shape costs a line exactly as a 0.95 one does —
        // and a developer's screen is full of two shapes this pattern could not tell from a code.
        // Over this repository's own tracked Markdown and source laid out as screens (25 + 396
        // files, 216 774 laid-out lines in 5 366 forty-two-line windows, at `d7d110e`, through the
        // real detector) the whole `one_time_code` class fired **151** times and painted **143**
        // lines in **98** screens. **99** of those matches were a `File.swift:129-131` line-range
        // citation and **7** more were the tail of a thousands-separated number such as
        // `1 011 740`. With both refusals the same corpus answers **45 matches, 41 painted lines,
        // 34 screens** (at `37e7748`, the commit that added them). The Markdown half — which is what the ticket was filed off — goes from
        // **114 matches painting 109 lines in 70 of its 1 235 screens** to **11 painting 10 in 9**.
        // The source half barely moves (37 -> 34) and should not: nearly all of what is left there
        // is this repository's own test data, literal `code: 123456` lines that a detector is
        // right to see.
        //
        // ``continuesASeparatedDigitGroup(_:in:)`` is the run guard one character wider:
        // ``precededByDigitOrHyphen(_:in:)`` refuses a pair whose separator has already been
        // crossed, and `146 835` inside `1 146 835` is preceded by a *space* that is itself
        // preceded by a digit. ``isBoundToALocatorByAColon(_:in:)`` refuses a hyphenated pair whose
        // immediately preceding character is `:` — what binds `129-131` to the file before it. A
        // code is never presented that way, because a label puts a space after its colon; the one
        // shape this newly misses is `code:483-291`, and the contextual rule above now catches that
        // at 0.85 instead.
        //
        // **The hyphen itself stays, and that is the ticket's question answered with a
        // measurement.** Dropping it was the obvious fix and is the wrong one: `Your code is
        // 483-291` has no six contiguous digits for the contextual rule and no space for the
        // spaced one, so nothing else in this file would see it. The cost was never the hyphen; it
        // was the colon in front of it.
        let spacedPair = /\b(\d{3}[ -]\d{3})\b(?![\d-])/
        for match in text.matches(of: spacedPair)
        where !Self.precededByDigitOrHyphen(match.range, in: text)
            && !Self.continuesASeparatedDigitGroup(match.range, in: text)
            && !Self.isBoundToALocatorByAColon(match.range, in: text) {
            let value = match.output.1
            results.append(SecretTextMatch(
                detectionClass: .oneTimeCode,
                range: value.startIndex..<value.endIndex,
                confidence: 0.55
            ))
        }
        return results
    }

    private func creditCardMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        let candidate = /\b\d(?:[ -]?\d){12,18}\b/
        for match in text.matches(of: candidate) {
            let digits = text[match.range].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count) else { continue }
            // Leading digits 3/4/5/6 cover Amex/Visa/Mastercard-5/Discover; Mastercard has also
            // issued the 2221–2720 BIN range since 2017 (PR #49 F2 — a Luhn-valid 2-series PAN
            // sailed through unmasked because the first-digit check predated the range).
            let firstFour = digits[0] * 1_000 + digits[1] * 100 + digits[2] * 10 + digits[3]
            guard [3, 4, 5, 6].contains(digits[0]) || (2221...2720).contains(firstFour) else { continue }
            // Luhn is the validity check that separates "verified card number" from "card-shaped
            // digits": pass sits above the threshold, fail sits below it and still redacts.
            let confidence = Self.passesLuhn(digits) ? 0.95 : 0.55
            results.append(SecretTextMatch(detectionClass: .creditCardNumber, range: match.range, confidence: confidence))
        }
        return results
    }

    private func ssnMatches(in text: String) -> [SecretTextMatch] {
        var results: [SecretTextMatch] = []
        let shaped = /\b(\d{3})-(\d{2})-(\d{4})\b(?![\d-])/
        for match in text.matches(of: shaped) where !Self.precededByDigitOrHyphen(match.range, in: text) {
            let area = Int(match.output.1) ?? 0
            let group = Int(match.output.2) ?? 0
            let serial = Int(match.output.3) ?? 0
            let inValidRanges = area != 0 && area != 666 && area < 900 && group != 0 && serial != 0
            results.append(SecretTextMatch(
                detectionClass: .socialSecurityNumber,
                range: match.range,
                confidence: inValidRanges ? 0.9 : 0.5
            ))
        }
        return results
    }

    // MARK: - Helpers

    /// Stand-in for regex lookbehind, which this toolchain's Regex engine does not support:
    /// rejects a match glued onto a preceding digit run or hyphenated group.
    private static func precededByDigitOrHyphen(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex else { return false }
        let before = text[text.index(before: range.lowerBound)]
        return before.isNumber || before == "-"
    }

    /// Whether the match continues a longer separated digit group — `146 835` inside `1 146 835`
    /// (SONNY-278).
    ///
    /// The space is the only separator this has to look for: a hyphen in that position is already
    /// refused by ``precededByDigitOrHyphen(_:in:)``, so a branch for it here would be one no input
    /// can reach.
    ///
    /// **Only the left side, and that is a measurement rather than an omission.** The symmetric
    /// check — refusing a pair *followed* by a separator and a digit — refused **0** additional
    /// matches over the corpus named at ``oneTimeCodeMatches(in:)``, and it would refuse a genuine
    /// pair of codes printed side by side. An unmeasured guard that can only lose true positives is
    /// worse than no guard.
    private static func continuesASeparatedDigitGroup(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex else { return false }
        let separatorIndex = text.index(before: range.lowerBound)
        guard text[separatorIndex] == " ", separatorIndex > text.startIndex else { return false }
        return text[text.index(before: separatorIndex)].isNumber
    }

    /// Whether a **hyphenated** pair is bound to what precedes it by a colon with no space —
    /// `CerebrasPlanner.swift:129-131`, `linking.db.test.ts:773-783` (SONNY-278).
    ///
    /// Hyphenated only, deliberately, and **the asymmetry is held by a test rather than by this
    /// sentence**: a battery at `6cec301` widened this to the spaced form and survived, because the
    /// obvious example of the difference carries a context word and the contextual rule catches it
    /// either way. `aSpacedPairAgainstAColonIsStillDetected` is the unlabelled case that tells them
    /// apart. Narrow rather than wide because every colon-bound false positive in the measured
    /// corpus was hyphenated — 99 of them, 0 spaced — and a fail-closed detector does not narrow on
    /// a shape no measurement asked it to.
    ///
    /// The colon has to be *immediately* before the digits — `Code: 483-291` is preceded by a space
    /// and is untouched.
    private static func isBoundToALocatorByAColon(_ range: Range<String.Index>, in text: String) -> Bool {
        guard text[range].contains("-"), range.lowerBound > text.startIndex else { return false }
        return text[text.index(before: range.lowerBound)] == ":"
    }

    static func passesLuhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Overlapping detections merge into ONE match covering the union of their ranges,
    /// classified and scored by the highest-confidence member ("password: eyJa.b.c" is one
    /// secret, not two). The union, not the winner's own range (PR #49 F7): keeping only the
    /// narrower high-confidence range once emitted the wider low-confidence match's remainder
    /// in the clear — `token=v2.<jwt>` masked to `token=v2.•••••` because the JWT match (0.95)
    /// starts after the `v2.` the labeled-token match (0.85) covered. Coverage is the
    /// fail-closed half; the class label is only reporting.
    static func coalesceOverlaps(_ matches: [SecretTextMatch]) -> [SecretTextMatch] {
        let byPosition = matches.sorted { first, second in
            if first.range.lowerBound != second.range.lowerBound {
                return first.range.lowerBound < second.range.lowerBound
            }
            return first.confidence > second.confidence
        }
        var merged: [SecretTextMatch] = []
        for match in byPosition {
            guard let last = merged.last, last.range.overlaps(match.range) else {
                merged.append(match)
                continue
            }
            let upperBound = last.range.upperBound < match.range.upperBound
                ? match.range.upperBound
                : last.range.upperBound
            let winner = match.confidence > last.confidence ? match : last
            merged[merged.count - 1] = SecretTextMatch(
                detectionClass: winner.detectionClass,
                range: last.range.lowerBound..<upperBound,
                confidence: winner.confidence
            )
        }
        return merged
    }
}
