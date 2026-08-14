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
struct SecretTextDetector {
    static let maskReplacement = "•••••"

    func matches(in text: String) -> [SecretTextMatch] {
        var found: [SecretTextMatch] = []
        found += privateKeyMatches(in: text)
        found += apiKeyMatches(in: text)
        found += accessTokenMatches(in: text)
        found += passwordFieldMatches(in: text)
        found += oneTimeCodeMatches(in: text)
        found += creditCardMatches(in: text)
        found += ssnMatches(in: text)
        return Self.coalesceOverlaps(found)
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
        let contextual = /(?i)(?:code|otp|2fa|passcode|verification|authenticator|one[ -]?time)\b\D{0,20}?(\d{6,8})\b/
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
        let spacedPair = /\b(\d{3}[ -]\d{3})\b(?![\d-])/
        for match in text.matches(of: spacedPair) where !Self.precededByDigitOrHyphen(match.range, in: text) {
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
            guard (13...19).contains(digits.count), [3, 4, 5, 6].contains(digits[0]) else { continue }
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

    /// Overlapping detections keep the highest-confidence one ("password: eyJa.b.c" is one
    /// secret, not two), then come back in text order for deterministic masking.
    static func coalesceOverlaps(_ matches: [SecretTextMatch]) -> [SecretTextMatch] {
        let byConfidence = matches.sorted { first, second in
            if first.confidence != second.confidence { return first.confidence > second.confidence }
            return first.range.lowerBound < second.range.lowerBound
        }
        var kept: [SecretTextMatch] = []
        for match in byConfidence {
            let overlapsKept = kept.contains { existing in
                match.range.overlaps(existing.range)
            }
            if !overlapsKept {
                kept.append(match)
            }
        }
        return kept.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
