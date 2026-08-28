import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacAgentCore

// MARK: - Fakes and fixtures

private final class FakeTextRecognizer: ImageTextRecognizing, @unchecked Sendable {
    var observations: [RecognizedTextObservation]
    var error: Error?

    init(observations: [RecognizedTextObservation] = [], error: Error? = nil) {
        self.observations = observations
        self.error = error
    }

    func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
        if let error { throw error }
        return observations
    }
}

private struct FakeOCRFailure: Error {}

private func capture(png: Data, width: Int, height: Int, bundleID: String = "com.example.notes") -> CapturedWindowImage {
    CapturedWindowImage(
        pngData: png,
        pixelWidth: width,
        pixelHeight: height,
        bundleIdentifier: bundleID,
        windowTitle: "Fixture",
        windowID: 1,
        windowFrame: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )
}

private func textService() -> LocalRedactionService {
    LocalRedactionService(textRecognizer: FakeTextRecognizer())
}

// MARK: - Text masking per class

struct LocalRedactionTextTests {
    @Test
    func vendorPrefixedAPIKeyMasksAndReportsAboveThreshold() {
        let payload = textService().redactText("Use sk-Ab12Cd34Ef56Gh78Ij90 for the staging calls")
        #expect(payload.maskedText == "Use ••••• for the staging calls")
        #expect(payload.maskedText?.contains("sk-Ab12Cd34Ef56Gh78Ij90") == false)
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func labeledAPIKeyMasksTheValueAndKeepsTheLabel() {
        let payload = textService().redactText("api key: 8fj3k2l9q0w7e5r6t4")
        #expect(payload.maskedText == "api key: •••••")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.9, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func unlabeledHighEntropyBlobRedactsAndFlagsBelowThreshold() {
        let blob = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6hJ0q"
        let payload = textService().redactText("artifact \(blob) uploaded")
        #expect(payload.maskedText == "artifact ••••• uploaded")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.5, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func bearerAndJWTTokensBothMaskAsAccessTokens() {
        let text = "Authorization: Bearer abcDEF123456789012345 and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSMeKKF2QT4"
        let payload = textService().redactText(text)
        #expect(payload.maskedText?.contains("abcDEF123456789012345") == false)
        #expect(payload.maskedText?.contains("eyJhbGciOiJIUzI1NiJ9") == false)
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .accessToken, count: 2, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func labeledTokenMasksItsValueAboveThreshold() {
        let payload = textService().redactText("token: 9f8e7d6c5b4a3210")
        #expect(payload.maskedText == "token: •••••")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .accessToken, count: 1, locationCategory: .text, confidence: 0.85, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func passwordFieldMasksTheValueKeepingTheLabel() {
        let payload = textService().redactText("password: hunter2")
        #expect(payload.maskedText == "password: •••••")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .passwordField, count: 1, locationCategory: .text, confidence: 0.9, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func unlabeledBulletRunRedactsAndFlagsAsPasswordShaped() {
        let payload = textService().redactText("Login  ••••••••  Submit")
        #expect(payload.maskedText == "Login  •••••  Submit")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .passwordField, count: 1, locationCategory: .text, confidence: 0.7, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func oneTimeCodeWithContextMasksTheDigits() {
        let payload = textService().redactText("Your verification code is 482913")
        #expect(payload.maskedText == "Your verification code is •••••")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .oneTimeCode, count: 1, locationCategory: .text, confidence: 0.85, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func spacedDigitPairWithoutContextRedactsAndFlags() {
        let payload = textService().redactText("Enter 482 913 to continue")
        #expect(payload.maskedText == "Enter ••••• to continue")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .oneTimeCode, count: 1, locationCategory: .text, confidence: 0.55, belowConfidenceThreshold: true)
        ])
    }

    // MARK: - The two shapes a developer's screen is made of (SONNY-278)

    /// **A `File.swift:129-131` line-range citation is not a one-time code.**
    ///
    /// The lines below are real, copied out of this repository's own tracked Markdown, which is
    /// where the ticket was filed from: the unlabeled spaced pair painted 98 of them across the
    /// docs corpus, and every one blanked its whole line for the vision model. The colon binds the
    /// digits to the file in front of them, and nothing presents a code that way.
    @Test
    func aColonBoundLineRangeCitationIsNotAOneTimeCode() {
        for citation in [
            "the doc comment at `CerebrasPlanner.swift:129-131` and the table beside it",
            "`VisionSessionContainment.swift:205`, `:209-210`, with a note",
            "(`server/test/linking.db.test.ts:773-783`), which is the one that matters",
            "`AutomationStores.swift:296-300` vs `:161-172`",
            "AgentRunner.swift:110-119"
        ] {
            let payload = textService().redactText(citation)
            #expect(payload.report.isEmpty, Comment(rawValue: citation))
            #expect(payload.maskedText == citation, Comment(rawValue: citation))
        }
    }

    /// **A thousands-separated number is not a one-time code either** — the other ten of the
    /// ticket's 105. `146 835` inside `1 146 835` is preceded by a space that is itself preceded by
    /// a digit, which `precededByDigitOrHyphen` could not see because it looks one character back.
    @Test
    func aThousandsSeparatedNumberIsNotAOneTimeCode() {
        for grouped in [
            "clipboard-history.json is 1 011 740 bytes on disk",
            "a genuine 1 207 697 byte response",
            "task-history rows at 4 343 930 bytes"
        ] {
            let payload = textService().redactText(grouped)
            #expect(payload.report.isEmpty, Comment(rawValue: grouped))
            #expect(payload.maskedText == grouped, Comment(rawValue: grouped))
        }
    }

    /// **The other direction, which is the half a narrowing loses if nobody writes it down.** The
    /// hyphenated pair stays, because dropping it — the obvious fix — would leave `Your code is
    /// 483-291` matched by nothing at all: it has no six contiguous digits for the contextual rule
    /// and no space for the spaced one.
    @Test
    func aHyphenatedOneTimeCodeIsStillDetected() {
        for display in [
            "Your code is 483-291",
            "Code: 483-291",
            "483-291",
            "Enter 483-291 to continue"
        ] {
            let payload = textService().redactText(display)
            #expect(payload.report.map(\.detectionClass) == [.oneTimeCode], Comment(rawValue: display))
            #expect(payload.maskedText?.contains("•••••") == true, Comment(rawValue: display))
            #expect(payload.maskedText?.contains("483") == false, Comment(rawValue: display))
        }
    }

    /// **The one shape the colon refusal newly misses, caught by the contextual rule instead.**
    /// `code:483-291` has its colon immediately against the digits, exactly like a citation — so
    /// the shape rule refuses it, and the context word carries it at 0.85 rather than 0.55. That is
    /// why the contextual pattern's value alternation takes a separated pair.
    @Test
    func aLabelledCodeWithItsSeparatorAgainstTheColonIsStillDetected() {
        for labelled in ["code:483-291", "otp:483 291", "verification_code:483-291"] {
            let payload = textService().redactText(labelled)
            #expect(
                payload.report == [
                    RedactionReportEntry(
                        detectionClass: .oneTimeCode,
                        count: 1,
                        locationCategory: .text,
                        confidence: 0.85,
                        belowConfidenceThreshold: false
                    )
                ],
                Comment(rawValue: labelled)
            )
            #expect(payload.maskedText?.hasSuffix("•••••") == true, Comment(rawValue: labelled))
        }
    }

    /// **What the run guard costs, stated rather than left to be found.**
    ///
    /// Two codes printed side by side separated by one space are, as text, a nine-digit grouped
    /// number — so the second pair is refused and only the first is masked. The check refuses the
    /// left side only, which is why the first survives; the symmetric right-side check was measured
    /// over the same corpus, refused **0** additional matches, and would have lost this one too.
    ///
    /// **On the capture path it costs nothing**, and that is the reason this is acceptable rather
    /// than merely small: `redactCapture` paints every observation a match touches, so the line is
    /// painted whole by the first pair regardless. It is `redactText` — the window title and the
    /// observed history — where the second pair's digits survive.
    @Test
    func twoCodesSideBySideReadAsOneGroupAndOnlyTheFirstIsMasked() {
        let payload = textService().redactText("483 291 992 118")
        #expect(payload.maskedText == "••••• 992 118")
        #expect(payload.report.map(\.detectionClass) == [.oneTimeCode])
    }

    @Test
    func mastercardTwoSeriesLuhnPassingCardMasksAboveThreshold() {
        // Mastercard's 2221–2720 BIN range (issued since 2017) — invisible to the detector's
        // original first-digit check (PR #49 F2). 2223003122003222 is a published 2-series
        // test PAN and passes Luhn.
        let payload = textService().redactText("Card on file 2223003122003222 exp 12/29")
        #expect(payload.maskedText == "Card on file ••••• exp 12/29")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func mastercardTwoSeriesLuhnFailingShapeStillRedactsAndFlags() {
        let payload = textService().redactText("Card on file 2223003122003223 exp 12/29")
        #expect(payload.maskedText == "Card on file ••••• exp 12/29")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 1, locationCategory: .text, confidence: 0.55, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func luhnPassingCardNumberMasksAboveThreshold() {
        let payload = textService().redactText("Card 4111 1111 1111 1111 on file")
        #expect(payload.maskedText == "Card ••••• on file")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func luhnFailingCardShapeStillRedactsAndFlags() {
        // The fail-closed threshold pinned in both directions on one class: same shape, one
        // digit off, drops below the threshold and is redacted anyway.
        let payload = textService().redactText("Card 4111 1111 1111 1112 on file")
        #expect(payload.maskedText == "Card ••••• on file")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 1, locationCategory: .text, confidence: 0.55, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func validRangeSSNMasksAboveThreshold() {
        let payload = textService().redactText("SSN 123-45-6789 ends the form")
        #expect(payload.maskedText == "SSN ••••• ends the form")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .socialSecurityNumber, count: 1, locationCategory: .text, confidence: 0.9, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func outOfRangeSSNShapeStillRedactsAndFlags() {
        let payload = textService().redactText("SSN 000-12-3456 ends the form")
        #expect(payload.maskedText == "SSN ••••• ends the form")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .socialSecurityNumber, count: 1, locationCategory: .text, confidence: 0.5, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func privateKeyBlockMasksInFull() {
        let block = "-----BEGIN RSA PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQ\n-----END RSA PRIVATE KEY-----"
        let payload = textService().redactText("Config dump:\n\(block)\ndone")
        #expect(payload.maskedText == "Config dump:\n•••••\ndone")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .privateKey, count: 1, locationCategory: .text, confidence: 1.0, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func truncatedPrivateKeyBlockMasksToTheEndOfTheText() {
        let payload = textService().redactText("head\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqh")
        #expect(payload.maskedText == "head\n•••••")
        #expect(payload.report.first?.detectionClass == .privateKey)
    }

    @Test
    func cleanTextPassesThroughUnchangedWithAnEmptyReport() {
        let text = "Meet at 4pm to review the Q3 roadmap draft with the team"
        let payload = textService().redactText(text)
        #expect(payload.maskedText == text)
        #expect(payload.report.isEmpty)
    }

    @Test
    func maskedTextNeverContainsAnyOriginalSecret() {
        let secrets = [
            "sk-Ab12Cd34Ef56Gh78Ij90",
            "hunter2",
            "4111 1111 1111 1111",
            "123-45-6789"
        ]
        let text = "key \(secrets[0]) password: \(secrets[1]) card \(secrets[2]) ssn \(secrets[3])"
        let payload = textService().redactText(text)
        for secret in secrets {
            #expect(payload.maskedText?.contains(secret) == false)
        }
    }

    @Test
    func multipleClassesReportPerClassWithCounts() {
        let text = "a sk-Ab12Cd34Ef56Gh78Ij90 b sk-Zz98Yy87Xx76Ww65Vv54 password: swordfish"
        let payload = textService().redactText(text)
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 2, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false),
            RedactionReportEntry(detectionClass: .passwordField, count: 1, locationCategory: .text, confidence: 0.9, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func mixedConfidencesInOneClassReportTheWorstCaseAndFlag() {
        // One Luhn-passing card (0.95) and one Luhn-failing shape (0.55) in the same text:
        // the class entry carries the LOWEST confidence and the flag — the honest worst case,
        // never an average and never the best member.
        let payload = textService().redactText("cards 4111 1111 1111 1111 and 4111 1111 1111 1112")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 2, locationCategory: .text, confidence: 0.55, belowConfidenceThreshold: true)
        ])
    }

    @Test
    func overlapCoalescingMasksTheUnionNotJustTheWinnersOwnRange() {
        // PR #49 F7: the labeled-token match (0.85) covers "v2.eyJ…" in full; the JWT match
        // (0.95) starts after "v2.". Winner-take-range once left "v2." in the clear — the
        // union masks everything either match covered, reported as the winner's class.
        let payload = textService().redactText("token=v2.eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSM done")
        #expect(payload.maskedText == "token=••••• done")
        #expect(payload.maskedText?.contains("v2.") == false)
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .accessToken, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func overlappingDetectionsCoalesceToTheHighestConfidenceClass() {
        // A labeled token whose value is a JWT is one secret, not two: the JWT match (0.95)
        // wins the overlap against the labeled-token match (0.85).
        let payload = textService().redactText("token: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.SflKxwRJSM")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .accessToken, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func textPayloadCarriesNoImageFields() {
        let payload = textService().redactText("password: hunter2")
        #expect(payload.redactedImageData == nil)
        #expect(payload.imagePixelWidth == nil)
        #expect(payload.imagePixelHeight == nil)
        #expect(payload.sourceBundleIdentifier == nil)
    }

    @Test
    func reportEntriesRoundTripThroughCodable() throws {
        let entry = RedactionReportEntry(detectionClass: .creditCardNumber, count: 3, locationCategory: .imageRegion, confidence: 0.55, belowConfidenceThreshold: true)
        let decoded = try JSONDecoder().decode(RedactionReportEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
    }

    // MARK: Look-alike folding (SONNY-272)

    /// The reading SONNY-260 measured at 820 px, verbatim as scalars: the `a` of `api` as U+0430,
    /// the `A` of `Abc` as U+0410, the `o` of `Mno` as U+043E, the final `r` as U+0131. Unfolded,
    /// every api-key pattern misses it — the label pattern never sees `api`, and the dotless i at
    /// the end is a word character the closing `\b` cannot land before. Folded, the vendor pattern
    /// and the label pattern both match, and the mask lands on the caller's own scalars: the label
    /// keeps its U+0430, because the output is never the folded text.
    @Test
    func theLookAlikeReadingSONNY260MeasuredIsMaskedAsAnAPIKey() {
        let reading = "\u{0430}pi_key=sk-\u{0410}bc123Def456Ghi789JklMn\u{043E}012Pq\u{0131}"
        let payload = textService().redactText(reading)

        #expect(Array((payload.maskedText ?? "").unicodeScalars) == Array("\u{0430}pi_key=•••••".unicodeScalars))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    /// A look-alike inside the vendor prefix itself — U+0455 CYRILLIC SMALL LETTER DZE for the `s`
    /// of `sk-` — is the other place one substituted letter defeats the self-identifying pattern.
    @Test
    func aLookAlikeInsideAVendorPrefixStillMatchesIt() {
        let payload = textService().redactText("Use \u{0455}k-Ab12Cd34Ef56Gh78Ij90 for the staging calls")

        #expect(payload.maskedText == "Use ••••• for the staging calls")
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    /// Three Cyrillic letters ahead of the secret are six UTF-8 bytes in the caller's text and three
    /// in the folded one. A range carried back by byte offset would mask the wrong scalars; a range
    /// carried back by scalar ordinal masks the value and nothing else.
    @Test
    func lookAlikesAheadOfASecretDoNotShiftWhatIsMasked() {
        let payload = textService().redactText("\u{043E}\u{043E}\u{043E} password: hunter2")

        #expect(Array((payload.maskedText ?? "").unicodeScalars) == Array("\u{043E}\u{043E}\u{043E} password: •••••".unicodeScalars))
        #expect(payload.report.map(\.detectionClass) == [.passwordField])
    }

    /// The fold is document-wide, not an api-key special case: every class's exact pattern sees the
    /// folded text, and every class's mask lands on the caller's scalars. One look-alike per class —
    /// U+0435 in `Bearer`, U+0430 in `password`, U+0415 in `BEGIN`, U+043E in `code`.
    @Test
    func everyClassMatchesThroughTheFoldAndMasksTheCallersOwnScalars() {
        let bearer = textService().redactText("B\u{0435}arer abcDEF123456789012345")
        #expect(Array((bearer.maskedText ?? "").unicodeScalars) == Array("B\u{0435}arer •••••".unicodeScalars))
        #expect(bearer.report.map(\.detectionClass) == [.accessToken])

        let password = textService().redactText("p\u{0430}ssword: hunter2")
        #expect(Array((password.maskedText ?? "").unicodeScalars) == Array("p\u{0430}ssword: •••••".unicodeScalars))
        #expect(password.report.map(\.detectionClass) == [.passwordField])

        let privateKey = textService().redactText("-----B\u{0415}GIN PRIVATE KEY-----\nMIIEvQ\n-----END PRIVATE KEY-----")
        #expect(privateKey.maskedText == "•••••")
        #expect(privateKey.report.map(\.detectionClass) == [.privateKey])

        let code = textService().redactText("c\u{043E}de: 483291")
        #expect(Array((code.maskedText ?? "").unicodeScalars) == Array("c\u{043E}de: •••••".unicodeScalars))
        #expect(code.report.map(\.detectionClass) == [.oneTimeCode])
    }

    /// PR #116's blocker, proved against the detector rather than read off the table (F1): the
    /// capital-I look-alikes — U+0406, the Ukrainian capital I a uk-UA-capable recognizer can type
    /// for a Latin `I`; U+04C0 CYRILLIC LETTER PALOCHKA; U+0196 LATIN CAPITAL LETTER IOTA — fold to
    /// `I`, so `AKIA` and `AIza` still self-identify and the blob rule still sees an uppercase
    /// letter. Before the fix all three folded to `l` and none of these matched.
    @Test
    func capitalLookAlikesOfIRestoreTheCaseSensitivePatterns() {
        for capital in ["\u{0406}", "\u{04C0}", "\u{0196}"] {
            let aws = textService().redactText("AK\(capital)A\(capital)OSFODNN7EXAMPLE")
            #expect(aws.maskedText == "•••••", Comment(rawValue: capital))
            #expect(aws.report == [
                RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.95, belowConfidenceThreshold: false)
            ], Comment(rawValue: capital))
        }

        let google = textService().redactText("A\u{0406}zaSyA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q")
        #expect(google.maskedText == "•••••")
        #expect(google.report.map(\.confidence) == [0.95])

        // Thirty-one lowercase alphanumerics plus one Ukrainian capital I: the only uppercase letter
        // the blob rule can see is the folded one.
        let blob = textService().redactText("zx9kq2mp8vl4nr7tyw3ea5sd1fg6hj0\u{0406}")
        #expect(blob.maskedText == "•••••")
        #expect(blob.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .text, confidence: 0.5, belowConfidenceThreshold: true)
        ])
    }

    /// The false positive the fold created and the guard that ends it (PR #116 review, F2): an
    /// all-caps Cyrillic word whose look-alikes fold into an OTP context word as a *suffix* — the
    /// Russian word for "view", U+041F U+0420 U+041E U+0421 U+041C U+041E U+0422 U+0420, folds to
    /// `…MOTP` — followed by six digits matched at 0.85 and was masked.
    /// A context word now has to begin a word, where "begin" is "not preceded by a letter of any
    /// script": the two Cyrillic headings match nothing, `Barcode 123456` no longer matches on its
    /// suffix either, and the snake_case labels forms and JSON use still do — that is why the guard
    /// is `[^\p{L}]` and not `\b`, which would have dropped them.
    @Test
    func aFoldedCapitalWordEndingInAContextWordIsNotAOneTimeCodeContext() {
        let headings = [
            "\u{041F}\u{0420}\u{041E}\u{0421}\u{041C}\u{041E}\u{0422}\u{0420}: 123456",
            "\u{041E}\u{0421}\u{041C}\u{041E}\u{0422}\u{0420} 123456",
            "Barcode 123456"
        ]
        for heading in headings {
            let payload = textService().redactText(heading)
            #expect(payload.report.isEmpty, Comment(rawValue: heading))
            #expect(Array((payload.maskedText ?? "").unicodeScalars) == Array(heading.unicodeScalars), Comment(rawValue: heading))
        }

        for labeled in ["otp_code=123456", "verification_code: 483291", "code: 123456", "Your verification code is 482913"] {
            let payload = textService().redactText(labeled)
            #expect(payload.report.map(\.detectionClass) == [.oneTimeCode], Comment(rawValue: labeled))
            #expect(payload.maskedText?.hasSuffix("•••••") == true, Comment(rawValue: labeled))
        }
    }

    /// The byte-offset trap, with the folded text itself carrying wider-than-ASCII scalars ahead of
    /// the secret (PR #116 review, F4): U+0416 and U+4E2D have no Latin twin, so they survive the
    /// fold as two and three UTF-8 bytes, and an ordinal computed from a byte offset in the *folded*
    /// text lands four scalars late. `lookAlikesAheadOfASecretDoNotShiftWhatIsMasked` cannot catch
    /// that — its folded text is pure ASCII, so bytes and scalars coincide there. The ASCII tail after
    /// the secret is what lets this test *name* that mutant: with it, the wrong ordinal is still inside
    /// the mapping and the mask lands on the wrong scalars, which an assertion sees; without it the
    /// ordinal runs past the mapping and the precondition traps the process instead, which names no
    /// test at all.
    @Test
    func unfoldableScalarsAheadOfASecretDoNotShiftWhatIsMasked() {
        let payload = textService().redactText("\u{0416}\u{0416} \u{4E2D} p\u{0430}ssword: hunter2 is the value on this line")

        #expect(Array((payload.maskedText ?? "").unicodeScalars) == Array("\u{0416}\u{0416} \u{4E2D} p\u{0430}ssword: ••••• is the value on this line".unicodeScalars))
        #expect(payload.report.map(\.detectionClass) == [.passwordField])
    }

    /// The false-positive side of the founder's decision, held as a test: ordinary screen text in
    /// the scripts the fold reaches — Russian, Ukrainian, Japanese with fullwidth Latin — folds
    /// letters and matches nothing, and comes back scalar-for-scalar as it went in. The output is
    /// never the folded text, so a Cyrillic word is not rewritten into Latin look-alikes on the way
    /// through a clean screen.
    @Test
    func ordinaryTextInOtherScriptsIsNotMistakenForASecretAndIsNeverRewritten() {
        let screens = [
            "\u{041F}\u{0430}\u{0440}\u{043E}\u{043B}\u{044C} \u{0441}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0451}\u{043D} \u{0432} \u{043D}\u{0430}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{043A}\u{0430}\u{0445} \u{0430}\u{043A}\u{043A}\u{0430}\u{0443}\u{043D}\u{0442}\u{0430}",
            "\u{041A}\u{043B}\u{044E}\u{0447} \u{0434}\u{043E}\u{0441}\u{0442}\u{0443}\u{043F}\u{0443}: \u{0437}\u{0431}\u{0435}\u{0440}\u{0435}\u{0436}\u{0435}\u{043D}\u{043E} \u{0456} \u{043F}\u{0435}\u{0440}\u{0435}\u{0432}\u{0456}\u{0440}\u{0435}\u{043D}\u{043E}",
            "\u{FF21}\u{FF22}\u{FF23}\u{5546}\u{4E8B}\u{306E}\u{FF29}\u{FF24}\u{306F}\u{FF11}\u{FF12}\u{FF13}\u{FF14}"
        ]
        for screen in screens {
            let payload = textService().redactText(screen)
            #expect(payload.report.isEmpty, Comment(rawValue: screen))
            #expect(Array((payload.maskedText ?? "").unicodeScalars) == Array(screen.unicodeScalars), Comment(rawValue: screen))
        }
    }
}

// MARK: - Image redaction

struct LocalRedactionImageTests {
    @Test
    func pixelSamplerConventionAnchor() {
        // Anchors the sampler's memory orientation independently of the redaction code: the
        // fixture is white on top, black on the bottom, in human-viewed image terms.
        let png = ImageFixtures.whiteOverBlackPNG(width: 100, height: 100)
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: png, x: 50, yFromTop: 5)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: png, x: 50, yFromTop: 95)))
    }

    @Test
    func plantedSecretRegionIsPaintedOutAndReported() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 300)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "password: hunter2", boundingBox: CGRect(x: 50, y: 40, width: 200, height: 30))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 400, height: 300))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 150, yFromTop: 55)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 10, yFromTop: 10)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 350, yFromTop: 250)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .passwordField, count: 1, locationCategory: .imageRegion, confidence: 0.9, belowConfidenceThreshold: false)
        ])
        #expect(payload.sourceBundleIdentifier == "com.example.notes")
        #expect(payload.imagePixelWidth == 400)
        #expect(payload.imagePixelHeight == 300)
        #expect(payload.maskedText == nil)
    }

    /// A capture with nothing to hide keeps every pixel — and is still re-encoded for egress.
    ///
    /// **This used to assert byte-identity with the input PNG, and that assertion had to go**
    /// (SONNY-114). The old pipeline short-circuited a clean capture straight to `capture.pngData`,
    /// which is exactly why an unbounded full-resolution PNG was what left the device on the common
    /// path — most captures contain no secret at all. Byte-identity was pinning the bug. What is
    /// worth pinning is the property that motivated it: a capture with nothing to redact comes back
    /// *visually unchanged*, at its own dimensions, with an empty report.
    @Test
    func cleanObservationsLeaveEveryPixelWhereItWasWhileStillBeingEncodedForEgress() async throws {
        let png = ImageFixtures.whiteOverBlackPNG(width: 200, height: 150)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "Quarterly report draft", boundingBox: CGRect(x: 10, y: 10, width: 150, height: 20))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 200, height: 150))

        #expect(payload.report.isEmpty)
        #expect(payload.imagePixelWidth == 200)
        #expect(payload.imagePixelHeight == 150)
        let redacted = try #require(payload.redactedImageData)
        // Two-tone fixture, so a lossless encoding is the smaller one and the comparison is exact.
        #expect(payload.imageMediaType == .png)
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 100, yFromTop: 10)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 100, yFromTop: 140)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 0, yFromTop: 0)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 199, yFromTop: 149)))
    }

    @Test
    func onlySecretBearingObservationRegionsArePainted() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 300)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "Team standup notes", boundingBox: CGRect(x: 20, y: 20, width: 150, height: 24)),
            RecognizedTextObservation(string: "sk-Ab12Cd34Ef56Gh78Ij90", boundingBox: CGRect(x: 20, y: 200, width: 220, height: 24))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 400, height: 300))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 90, yFromTop: 32)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 90, yFromTop: 212)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .imageRegion, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func belowThresholdSecretShapeInAnImageIsPaintedAndFlagged() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 300)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "4111 1111 1111 1112", boundingBox: CGRect(x: 100, y: 100, width: 180, height: 26))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 400, height: 300))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 190, yFromTop: 113)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .creditCardNumber, count: 1, locationCategory: .imageRegion, confidence: 0.55, belowConfidenceThreshold: true)
        ])
    }

    /// PR #49 F1's defect, pinned shut: Vision hands back one observation per rendered line, so
    /// a BEGIN→END private-key block arrives split across observations. Per-line detection
    /// matched only the BEGIN line and shipped the key's body unpainted — while the report
    /// claimed a confidence-1.0 redaction. Every line the block spans must be painted.
    @Test
    func aPrivateKeyBlockSpanningObservationsIsPaintedInFull() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 500, height: 300)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "-----BEGIN RSA PRIVATE KEY-----", boundingBox: CGRect(x: 20, y: 40, width: 300, height: 24)),
            RecognizedTextObservation(string: "MIIEowIBAAKCAQEAy7Zt+qFwUvGh/PmxKQ", boundingBox: CGRect(x: 20, y: 80, width: 300, height: 24)),
            RecognizedTextObservation(string: "kJ3n2/Qv8bFxAoGBAPq3mV4tR+SsdKuwEr", boundingBox: CGRect(x: 20, y: 120, width: 300, height: 24)),
            RecognizedTextObservation(string: "-----END RSA PRIVATE KEY-----", boundingBox: CGRect(x: 20, y: 160, width: 300, height: 24))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 500, height: 300))

        let redacted = try #require(payload.redactedImageData)
        // Every one of the four lines — the body lines are the key.
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 150, yFromTop: 52)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 150, yFromTop: 92)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 150, yFromTop: 132)))
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 150, yFromTop: 172)))
        // Untouched corners stay white.
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 450, yFromTop: 280)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .privateKey, count: 1, locationCategory: .imageRegion, confidence: 1.0, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func anSSNInAnImageIsPaintedAndReported() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 200)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "SSN 123-45-6789", boundingBox: CGRect(x: 40, y: 60, width: 180, height: 24))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 400, height: 200))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 130, yFromTop: 72)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .socialSecurityNumber, count: 1, locationCategory: .imageRegion, confidence: 0.9, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func aOneTimeCodeInAnImageIsPaintedAndReported() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 200)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "Your verification code is 482913", boundingBox: CGRect(x: 40, y: 60, width: 260, height: 24))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 400, height: 200))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 170, yFromTop: 72)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .oneTimeCode, count: 1, locationCategory: .imageRegion, confidence: 0.85, belowConfidenceThreshold: false)
        ])
    }

    @Test
    func anAccessTokenInAnImageIsPaintedAndReported() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 500, height: 200)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "Authorization: Bearer abcDEF123456789012345", boundingBox: CGRect(x: 40, y: 60, width: 380, height: 24))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 500, height: 200))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 230, yFromTop: 72)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .accessToken, count: 1, locationCategory: .imageRegion, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }

    /// PR #49 F8: a claimed region that lies entirely outside the image cannot be painted, and
    /// silently skipping it would leave the report attesting a redaction that never happened —
    /// same honesty class as F1, same answer: fail closed. Unreachable through the shipped
    /// Vision recognizer; `ImageTextRecognizing` is a public seam row I plugs into.
    @Test
    func aRegionEntirelyOutsideTheImageFailsClosed() async {
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "password: hunter2", boundingBox: CGRect(x: 400, y: 400, width: 100, height: 20))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)
        do {
            _ = try await service.redactCapture(capture(png: ImageFixtures.solidWhitePNG(width: 200, height: 200), width: 200, height: 200))
            Issue.record("an unpaintable claimed region must never become a payload")
        } catch let error as LocalRedactionError {
            guard case .imageRedactionFailed(let reason) = error else {
                Issue.record("expected imageRedactionFailed, got \(error)")
                return
            }
            #expect(reason.contains("outside"))
        } catch {
            Issue.record("expected LocalRedactionError, got \(error)")
        }
    }

    @Test
    func recognizerFailureFailsClosedWithNoPayload() async {
        let service = LocalRedactionService(textRecognizer: FakeTextRecognizer(error: FakeOCRFailure()))
        do {
            _ = try await service.redactCapture(capture(png: ImageFixtures.solidWhitePNG(width: 50, height: 50), width: 50, height: 50))
            Issue.record("an unscanned capture must never become a payload")
        } catch let error as LocalRedactionError {
            guard case .detectionUnavailable = error else {
                Issue.record("expected detectionUnavailable, got \(error)")
                return
            }
            #expect(error.errorDescription?.contains("will not be sent") == true)
        } catch {
            Issue.record("expected LocalRedactionError, got \(error)")
        }
    }

    @Test
    func unpaintableImageWithASecretFailsClosed() async {
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "password: hunter2", boundingBox: CGRect(x: 0, y: 0, width: 40, height: 10))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)
        do {
            _ = try await service.redactCapture(capture(png: Data([0x01, 0x02, 0x03]), width: 50, height: 50))
            Issue.record("pixels that could not be painted out must never leave as a payload")
        } catch let error as LocalRedactionError {
            guard case .imageRedactionFailed = error else {
                Issue.record("expected imageRedactionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected LocalRedactionError, got \(error)")
        }
    }

    @Test
    func topLeftOriginRegionsPaintTheTopOfTheImage() async throws {
        // The Y-flip pin: a region declared at the image's top-left must blacken the top of
        // the final PNG, not the bottom.
        let png = ImageFixtures.solidWhitePNG(width: 300, height: 300)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(string: "sk-Ab12Cd34Ef56Gh78Ij90", boundingBox: CGRect(x: 0, y: 0, width: 100, height: 20))
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 300, height: 300))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 5, yFromTop: 5)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 5, yFromTop: 295)))
    }

    /// The capture path end to end with a fake recognizer that reads like the real one did at 820 px
    /// (SONNY-260): a Cyrillic prose line first, so the joined document carries wider scalars ahead
    /// of the secret, then the measured look-alike reading of the key. The key's observation is
    /// painted, the prose line is not, and the report says api key. This is the join-then-map path
    /// the text tests cannot reach: `redactCapture` matches over one joined document and paints by
    /// overlapping the match's range with each observation's, so a range mapped back wrongly would
    /// paint the wrong line or none.
    @Test
    func anObservationTheRecognizerReadWithLookAlikesIsPaintedAndReported() async throws {
        let png = ImageFixtures.solidWhitePNG(width: 600, height: 200)
        let recognizer = FakeTextRecognizer(observations: [
            RecognizedTextObservation(
                string: "\u{0421}\u{043E}\u{0445}\u{0440}\u{0430}\u{043D}\u{0438}\u{0442}\u{044C} \u{043D}\u{0430}\u{0441}\u{0442}\u{0440}\u{043E}\u{0439}\u{043A}\u{0438}",
                boundingBox: CGRect(x: 20, y: 30, width: 300, height: 24)
            ),
            RecognizedTextObservation(
                string: "\u{0430}pi_key=sk-\u{0410}bc123Def456Ghi789JklMn\u{043E}012Pq\u{0131}",
                boundingBox: CGRect(x: 20, y: 100, width: 520, height: 24)
            )
        ])
        let service = LocalRedactionService(textRecognizer: recognizer)

        let payload = try await service.redactCapture(capture(png: png, width: 600, height: 200))

        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 280, yFromTop: 112)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 170, yFromTop: 42)))
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 580, yFromTop: 10)))
        #expect(payload.report == [
            RedactionReportEntry(detectionClass: .apiKey, count: 1, locationCategory: .imageRegion, confidence: 0.95, belowConfidenceThreshold: false)
        ])
    }
}

// MARK: - Live Vision pipeline

/// **Serialized, because every test in here drives the real on-device recognizer** (PR #113 review,
/// F5). Widening the realistic-size case into seven took this suite from three concurrent
/// `VNRecognizeTextRequest`s to ten, and at ten the test process **stalls**. Re-proved at `176f186`
/// by deleting this one attribute and running `--filter LocalRedactionLiveVisionTests`: the run
/// **did not finish within 100 s** and the test process sat at **0% CPU** throughout, against
/// **3.389 s** for the same filtered run with the attribute in place. Each case on its own is fast —
/// the seven parameterized ones together pass in 1.97 s — so it is the concurrency and not any one
/// size. `.serialized` runs this suite's tests one at a time; the suite still runs in parallel with
/// the other 141, so the latency test below still measures under load.
@Suite(.serialized)
struct LocalRedactionLiveVisionTests {
    @Test
    func renderedAPIKeyIsFoundAndPaintedByTheRealRecognizer() async throws {
        let secretLine = "api_key=sk-Abc123Def456Ghi789JklMno012Pqr"
        let png = ImageFixtures.renderedTextPNG(
            width: 900,
            height: 200,
            lines: [(secretLine, CGPoint(x: 40, y: 80))]
        )
        let service = LocalRedactionService()

        let payload = try await service.redactCapture(capture(png: png, width: 900, height: 200))

        #expect(payload.report.contains { $0.detectionClass == .apiKey })
        // The rendered line starts at x=40 with a ~19pt Menlo advance per glyph at 32pt; the
        // middle of the line is comfortably inside the painted observation box.
        let redacted = try #require(payload.redactedImageData)
        #expect(ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: 300, yFromTop: 96)))
        // Far corner stays untouched.
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 880, yFromTop: 190)))
    }

    /// **The ceiling is a tripwire for a pathological regression, not a latency budget** — and the
    /// difference is what SONNY-224 came here to fix. At `.seconds(5)` this was a bet on how busy the
    /// machine was, and it was losing: measured with the flagged suite at `98c50c8`, the 32 pt
    /// fixture this test carried then took **1465 ms** on an idle run, **4422 ms** and **4644 ms**
    /// with an ordinary parallel suite around it, and **11742 ms** with a cold `swift build` beside
    /// it (`grep REDACTION-LATENCY-MS` over four consecutive runs). The middle two are inside a 5 s
    /// ceiling by 7%, which is not a margin; the last one is over it. Under a mutation battery that
    /// failure is worse than a red suite — `scripts/mutate` reads any failing test as the mutant
    /// being caught, so a wall-clock loss here is recorded as coverage that does not exist.
    ///
    /// Sixty seconds keeps every claim this test actually makes. The claim is not "redaction is
    /// fast" — the real number is printed below and belongs in the record with its SHA — it is that
    /// a regression turning half a second into a minute fails loudly. That still fails, with five
    /// times the headroom over the worst load yet measured here, and no dependence on what else the
    /// machine is doing. Those four figures were measured on the **32 pt** fixture, which SONNY-260
    /// replaced, under a suite where this suite's live-Vision tests still ran in parallel with each
    /// other. Both of those changed, so the numbers are not comparable and the smaller ones do not
    /// mean redaction got faster: this fixture's own three-run figures are in SONNY-260's changelog
    /// entry with the SHA they were measured at, and most of the drop is the `.serialized` above
    /// taking nine concurrent recognizer calls off this one's back rather than anything about
    /// redaction. What survives the change is the only thing the ceiling rests on: the worst load
    /// ever measured here is still the 11742 ms cold-build run, and 60 s is still five times that.
    ///
    /// The content expectations are new with the same change. Timing a call that is never checked to
    /// have done anything is a benchmark rather than a test, and a mutant that made `redactCapture`
    /// return early would have passed this the whole time — faster.
    ///
    /// One of those expectations was `redactedImageData != nil`, which asserted nothing at all —
    /// `redactCapture` builds its payload from `EncodedVisionCapture.data`, a non-optional, so it
    /// was true by construction on every path that reached it while its own comment claimed it
    /// proved painted pixels (PR #112 review, F5). It is a pixel check now, on coordinates that were
    /// measured rather than guessed.
    ///
    /// **The fixture is 24 pt because at 32 pt it did not carry the two secrets it claimed to**
    /// (SONNY-260). SONNY-224 found the real recognizer classifying only the card here and left the
    /// key unasserted; the suspicion on record was that a line reaching the capture's right edge is
    /// not recognized, which would have been a hole in the product's central privacy claim. It is
    /// not that. Holding this exact four-line layout and varying **only** the font size, every size
    /// from 18 pt to 30 pt finds both secrets, stable over five runs each, and only 32 pt misses —
    /// and 32 pt is the one size whose 41-character line does not fit the capture (right edge
    /// 829.9 px against a 800 px image; 30 pt ends at 780.5 px). That correlation is not the cause:
    /// a one-line fixture whose line overruns the same 800 px image by 10–50 px is read correctly,
    /// and across the four-line width sweep the outcome is **not monotonic** — 800 px misses, 810 px
    /// finds, 820 px misses, 830 px and up find. What actually happens is character-level OCR error
    /// on an oversized synthetic fixture, in three flavours across the sweep: the leading `api` is
    /// dropped from the observation (the box starts at the `_`), `sk-` is read as `5k-`, and at
    /// 820 px Vision substitutes look-alikes from other scripts — the `a` of `api` comes back as
    /// U+0430 CYRILLIC SMALL LETTER A, the `A` of `Abc` as U+0410, the `o` of `Mno` as U+043E and the
    /// final `r` as U+0131 LATIN SMALL LETTER DOTLESS I. (Written as scalars deliberately: pasting
    /// the rendered characters is what `.claude/rules/macagentcore-conventions.md` bans, because a
    /// Cyrillic `a` and a Latin one are indistinguishable in a record and that confusion has cost
    /// this repo a round of review already.) Any one of the three is enough, because the detector's
    /// api-key patterns are exact — the label pattern needs `api`, the vendor pattern needs `sk-`,
    /// and the high-entropy fallback needs 32 alphanumerics where the key's body is 30. **Vision
    /// never failed to return the line**, so this was never the "nothing to fail closed on" case:
    /// the region came back every time, with text a human reads as a secret, and the patterns did
    /// not match it. At every realistic capture size measured — 1280x800 at 12 and 14 pt,
    /// 1440x900 at 13 and 26 pt, 2560x1600 at 26 pt, 2880x1800 at 28 pt, and this 800x600 at 13 pt —
    /// the key is found — **all seven of those, pinned by
    /// `aPlantedKeyIsFoundAtEveryRealisticCaptureSize` below**, which takes them as its arguments so
    /// the list and the coverage cannot drift apart; `aPlantedKeyAtARealisticCaptureSizeIsPainted`
    /// adds the pixel check on one of them. Nothing in `LocalRedactionService` changed: there is no
    /// edge-of-capture case for it to handle, because the edge is measurably not what breaks this.
    ///
    /// The sweeps behind the paragraph above — the width sweep, the font sweep, the position sweep at
    /// fixed width and the candidate-depth probe — were run from throwaway probe suites that are
    /// **not in this tree**. SONNY-260 carries them: its closing comment has the results and a prose
    /// recipe, and a later comment on the same ticket has the probe suites' full source, which is the
    /// one place to copy them from rather than rewriting them. PR #113's reviewer rewrote all five
    /// from scratch for want of that, which is why the source is now recorded instead of described.
    @Test
    func redactionLatencyIsBoundedOnARepresentativeCapture() async throws {
        let png = ImageFixtures.renderedTextPNG(
            width: 800,
            height: 600,
            lines: [
                ("Meeting notes for the design review", CGPoint(x: 40, y: 60)),
                ("api_key=sk-Abc123Def456Ghi789JklMno012Pqr", CGPoint(x: 40, y: 200)),
                ("Card 4111 1111 1111 1111", CGPoint(x: 40, y: 340)),
                ("Follow-ups assigned to the platform team", CGPoint(x: 40, y: 480))
            ],
            fontSize: 24
        )
        let service = LocalRedactionService()

        let clock = ContinuousClock()
        let start = clock.now
        let payload = try await service.redactCapture(capture(png: png, width: 800, height: 600))
        let elapsed = clock.now - start

        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("REDACTION-LATENCY-MS: \(Int(milliseconds.rounded())) (800x600, 24pt, 4 lines, 2 secrets)")
        // Bounded, not fast: the ceiling exists so a pathological regression fails loudly.
        // The real number for the record is printed above and recorded with its SHA.
        #expect(elapsed < .seconds(60))

        // The work the number above is a measurement of actually happened: **both** planted secrets
        // are classified. Both, not just the card, is the whole of SONNY-260 — a fixture that plants
        // a key and silently fails to find it teaches the next reader that the recognizer cannot
        // read one, and the doc comment above is what that cost to establish.
        #expect(payload.report.contains { $0.detectionClass == .apiKey })
        #expect(payload.report.contains { $0.detectionClass == .creditCardNumber })

        // Painted, read off the pixels, once per secret. Rows 355 and 218 run through the middle of
        // the boxes the real recognizer puts over the card and the key — measured at x 40...390,
        // y 340...370 and x 40...634, y 202...234, which the service pads by 2 px on every side — so
        // every probe below sits at least fifteen pixels inside its box in either direction, rather
        // than on an edge a Vision update could move by three. Probing the *unredacted* fixture at
        // the same points is what makes the black mean painted rather than "the glyphs were already
        // dark there": at those rows the rendered text inks 1 of the 5 probed pixels on the card row
        // and 0 of 5 on the key row, so five out of five is something only the paint can produce.
        // Five reads per row rather than a sweep — every read decodes the PNG again.
        //
        // **The ink guards are pinned at those measured counts, not at `< 5`** (PR #113 review, F4).
        // `< 5` passes at four-of-five, where "only the paint can produce this" no longer follows —
        // the guard would have agreed with a fixture that had drifted until it was inking almost
        // every probe. These fixtures are rendered by CoreText from fixed coordinates, so the counts
        // are deterministic and there is nothing to leave slack for; the card row's one is the
        // glyph stroke that happens to fall under x=270.
        let redacted = try #require(payload.redactedImageData)
        let cardProbes = [60, 130, 200, 270, 350]
        let keyProbes = [60, 180, 300, 420, 560]
        let cardPainted = cardProbes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: $0, yFromTop: 355)) }
            .count
        let cardInFixture = cardProbes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: png, x: $0, yFromTop: 355)) }
            .count
        let keyPainted = keyProbes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: $0, yFromTop: 218)) }
            .count
        let keyInFixture = keyProbes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: png, x: $0, yFromTop: 218)) }
            .count
        #expect(cardPainted == cardProbes.count)
        #expect(cardInFixture == 1)
        #expect(keyPainted == keyProbes.count)
        #expect(keyInFixture == 0)
        // A box, not the whole capture: an all-black image would satisfy the lines above.
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 10, yFromTop: 10)))
    }

    /// The measurement the product's privacy claim actually rests on, kept as tests rather than as
    /// a sentence in the comment above (SONNY-260).
    ///
    /// The fixture above is a *representative capture* for timing a call; it is not representative of
    /// how much text a real window holds, and the 32 pt version of it is what made a missed key look
    /// like a recognition limit. These are the other end: a realistic screenful — 13 pt to 28 pt at a
    /// 1.6x line pitch, which is how a mail or notes window actually packs text — carrying one
    /// planted key among the prose, at each of the seven capture sizes SONNY-260 measured.
    ///
    /// **All seven are arguments rather than prose** (PR #113 review, F5). The doc comment above once
    /// listed seven sizes and said the test below kept them honest while the test pinned one of them,
    /// both Retina sizes included — a coverage gap that read like coverage. Taking the list as
    /// arguments means the sentence and the suite cannot disagree: a size dropped from here is a
    /// test that disappears from the run.
    ///
    /// They deliberately assert only what is durable — the key is found — and no test here asserts
    /// that the 32 pt fixture *fails*, because encoding Vision's current misreads would break the
    /// suite when Vision improves. The pixel half is ``aPlantedKeyAtARealisticCaptureSizeIsPainted``
    /// below, on one size, because painting is a property of the service rather than of the size:
    /// `redactCapture` paints every observation a match touches, so a found key is a painted key by
    /// construction and seven pixel checks would be seven measurements of one fact.
    @Test(arguments: RealisticCaptureSize.allMeasured)
    func aPlantedKeyIsFoundAtEveryRealisticCaptureSize(_ size: RealisticCaptureSize) async throws {
        let png = ImageFixtures.renderedTextPNG(
            width: size.width,
            height: size.height,
            lines: size.lines,
            fontSize: size.fontSize
        )

        let payload = try await LocalRedactionService()
            .redactCapture(capture(png: png, width: size.width, height: size.height))

        #expect(payload.report.contains { $0.detectionClass == .apiKey })
    }

    /// The pixel half of the case above, on the middle size of the seven.
    ///
    /// Found and *painted* are different claims, and the report alone establishes only the first.
    /// This one reads the bytes that would leave the device.
    @Test
    func aPlantedKeyAtARealisticCaptureSizeIsPainted() async throws {
        let size = RealisticCaptureSize.paintProbed
        let png = ImageFixtures.renderedTextPNG(
            width: size.width,
            height: size.height,
            lines: size.lines,
            fontSize: size.fontSize
        )

        let payload = try await LocalRedactionService()
            .redactCapture(capture(png: png, width: size.width, height: size.height))

        #expect(payload.report.contains { $0.detectionClass == .apiKey })

        // Painted, read off the pixels, and read the same way the latency test above does: the
        // probes are checked against the *unredacted* fixture too, or a black pixel could just be a
        // glyph stroke. The recognizer's box over the secret's line measures x 23...347,
        // y 274...289, which the service pads by 2 px on every side; row 282 sits about nine pixels
        // inside it top and bottom, and every probe at least fifteen pixels inside it horizontally.
        // At that row the 13 pt glyphs ink **none** of the seven probed pixels — the line's
        // ascenders and descenders miss all of them — so seven out of seven black is the paint and
        // nothing else. Pinned at `== 0` rather than `< 7` for the reason the latency test's guards
        // are (PR #113 review, F4): `< 7` passes at six-of-seven, where the sentence before it
        // stops being true.
        let redacted = try #require(payload.redactedImageData)
        let probes = [40, 90, 140, 190, 240, 290, 320]
        let painted = probes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: $0, yFromTop: 282)) }
            .count
        let inFixture = probes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: png, x: $0, yFromTop: 282)) }
            .count
        #expect(painted == probes.count)
        #expect(inFixture == 0)
        // Untouched where nothing was planted: the far right of the capture holds no text at all.
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 1400, yFromTop: 860)))
    }

    /// SONNY-272, half two, the half only the founder can run: the false-positive cost of lowering
    /// the high-entropy floor from 32 to 28, measured on **real captures** — a folder of PNG
    /// screenshots named by `SONNY_CAPTURE_CORPUS` — through the real recognizer and the product
    /// detector as shipped, with the floor unchanged. Skipped, visibly, when the variable is unset:
    /// no agent session can take those captures (Screen Recording is the founder's permission), so
    /// the measurement is one command rather than one session:
    ///
    ///     SONNY_CAPTURE_CORPUS=~/Desktop/captures <CLAUDE.md's flagged test command> \
    ///         --filter theHighEntropyFloorsCostOnRealCaptures
    ///
    /// then read the `HIGH-ENTROPY-FLOOR` lines. Nothing recognized is ever printed — names, lengths
    /// and counts only — because the log is going to be pasted into a ticket. In this suite rather
    /// than its own because it drives the shared recognizer once per capture, and this suite is the
    /// one that is serialized for that reason (PR #113 review, F5).
    @Test(.enabled(
        if: HighEntropyFloorMeasurement.captureCorpusDirectory != nil,
        "Set SONNY_CAPTURE_CORPUS to a folder of PNG captures to measure the floor's cost on them."
    ))
    func theHighEntropyFloorsCostOnRealCapturesIsMeasuredWithoutChangingIt() async throws {
        let directory = try #require(HighEntropyFloorMeasurement.captureCorpusDirectory)
        let captures = try HighEntropyFloorMeasurement.pngCaptures(in: directory)
        try #require(!captures.isEmpty, "no .png directly inside \(directory.path) — a measurement over nothing is not one")

        var totals = HighEntropyFloorMeasurement.Totals()
        for url in captures {
            let (data, width, height) = try HighEntropyFloorMeasurement.pngPixels(at: url)
            let observations = try await VisionImageTextRecognizer()
                .recognizeText(inPNGData: data, pixelWidth: width, pixelHeight: height)
            let cost = try HighEntropyFloorMeasurement.cost(of: observations)
            print(cost.line(name: url.lastPathComponent))
            #expect(cost.probeAgreesWithProduct, Comment(rawValue: url.lastPathComponent))
            totals.add(cost)
        }
        print(totals.summary(label: directory.lastPathComponent))
        #expect(totals.captures == captures.count)
    }
}

/// One realistic capture size, and the screenful of text it carries.
///
/// The construction is shared by every size so that the only thing varying across the seven is the
/// size itself — a per-size layout would make a miss ambiguous between the size and the layout,
/// which is the mistake SONNY-260 spent a session undoing at 32 pt.
struct RealisticCaptureSize: Sendable, CustomStringConvertible {
    let width: Int
    let height: Int
    let fontSize: CGFloat

    var description: String { "\(width)x\(height) at \(Int(fontSize)) pt" }

    /// The seven SONNY-260 measured, in the order its record lists them.
    static let allMeasured: [RealisticCaptureSize] = [
        RealisticCaptureSize(width: 1280, height: 800, fontSize: 12),
        RealisticCaptureSize(width: 1280, height: 800, fontSize: 14),
        RealisticCaptureSize(width: 1440, height: 900, fontSize: 13),
        RealisticCaptureSize(width: 1440, height: 900, fontSize: 26),
        RealisticCaptureSize(width: 2560, height: 1600, fontSize: 26),
        RealisticCaptureSize(width: 2880, height: 1800, fontSize: 28),
        RealisticCaptureSize(width: 800, height: 600, fontSize: 13)
    ]

    /// The one the pixel check runs on. A `MacBook`-shaped capture at ordinary UI text size, and the
    /// probe coordinates in that test are measured against *this* layout — changing it moves them.
    static let paintProbed = RealisticCaptureSize(width: 1440, height: 900, fontSize: 13)

    /// Prose at a 1.6x line pitch with one planted key at a fixed index, so the secret sits in the
    /// middle of a block of text rather than alone on an empty capture. Index 12 fits every size
    /// above: the smallest, 800x600 at 13 pt, holds 27 lines.
    var lines: [(text: String, topLeft: CGPoint)] {
        let filler = [
            "Inbox — 42 unread", "Design review notes", "Deploy checklist", "Staging config",
            "Follow-ups assigned to the platform team", "Meeting notes for the design review",
            "Release train Thursday", "Rotate the staging credential"
        ]
        let secretLine = "api_key=sk-Abc123Def456Ghi789JklMno012Pqr"
        let pitch = fontSize * 1.6
        var result: [(text: String, topLeft: CGPoint)] = []
        var y = pitch
        var index = 0
        while y < CGFloat(height) - pitch {
            result.append((index == 12 ? secretLine : filler[index % filler.count], CGPoint(x: 24, y: y)))
            y += pitch
            index += 1
        }
        return result
    }
}

// MARK: - The shell verdict on the payload (SONNY-139)

/// The screen check where it is actually produced. ``ShellSurfaceDetectorTests`` covers what counts
/// as a shell; this covers that a capture's payload carries the answer, and that the recognized text
/// it was computed from does not come with it.
struct CaptureShellVerdictTests {
    private static func observations(_ screen: String) -> [RecognizedTextObservation] {
        screen.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            RecognizedTextObservation(
                string: String(line),
                boundingBox: CGRect(x: 8, y: 8 + 18 * index, width: 300, height: 16)
            )
        }
    }

    private static func service(reading screen: String) -> LocalRedactionService {
        LocalRedactionService(textRecognizer: FakeTextRecognizer(observations: observations(screen)))
    }

    @Test
    func aCaptureOfAShellCarriesTheVerdictOnItsPayload() async throws {
        let service = Self.service(reading: """
        Last login: Sat Aug 16 09:14:22 on ttys000
        sauransh@Mac macos-agent % ./scripts/deploy.sh
        zsh: permission denied: ./scripts/deploy.sh
        """)

        let payload = try await service.redactCapture(
            capture(png: ImageFixtures.solidWhitePNG(width: 400, height: 300), width: 400, height: 300)
        )

        #expect(payload.shellSurface.showsShell)
        #expect(payload.shellSurface.signals == [.interactivePrompt, .commandRunInAShell, .shellDiagnostic, .sessionBanner])
    }

    @Test
    func aCaptureOfAnOrdinaryWindowCarriesAVerdictThatSaysSo() async throws {
        let service = Self.service(reading: """
        Reading List — Safari
        Building a Mac agent, and what npm has to do with it
        """)

        let payload = try await service.redactCapture(
            capture(png: ImageFixtures.solidWhitePNG(width: 400, height: 300), width: 400, height: 300)
        )

        #expect(payload.shellSurface.showsShell == false)
        #expect(payload.shellSurface.signals.isEmpty)
    }

    /// **Every observation is read, not just the first.** Neither line below reaches the threshold on
    /// its own; together they do. A service that handed the detector one observation, or the first
    /// one, would leave this at a single sign and let the session run.
    @Test
    func theVerdictIsComputedOverEveryObservationTogether() async throws {
        let promptOnly = Self.service(reading: "sauransh@Mac macos-agent % ")
        let diagnosticOnly = Self.service(reading: "zsh: permission denied: ./scripts/deploy.sh")
        let both = Self.service(reading: """
        sauransh@Mac macos-agent % ./scripts/deploy.sh
        zsh: permission denied: ./scripts/deploy.sh
        """)
        let png = ImageFixtures.solidWhitePNG(width: 400, height: 300)

        let first = try await promptOnly.redactCapture(capture(png: png, width: 400, height: 300))
        let second = try await diagnosticOnly.redactCapture(capture(png: png, width: 400, height: 300))
        let together = try await both.redactCapture(capture(png: png, width: 400, height: 300))

        #expect(first.shellSurface.signals == [.interactivePrompt])
        #expect(first.shellSurface.showsShell == false)
        #expect(second.shellSurface.signals == [.shellDiagnostic])
        #expect(second.shellSurface.showsShell == false)
        #expect(together.shellSurface.signals == [.interactivePrompt, .commandRunInAShell, .shellDiagnostic])
        #expect(together.shellSurface.showsShell)
    }

    /// **The recognized text does not leave with the verdict, and the type is what says so.** A
    /// capture payload's `maskedText` is `nil` — there is no text field on it at all — so the only
    /// thing that crosses this boundary about what the screen said is at most six fixed strings from
    /// a closed enum. The image is redacted separately and is not text.
    @Test
    func noRecognisedTextLeavesTheServiceWithTheVerdict() async throws {
        let secretiveShell = """
        sauransh@Mac macos-agent % export API_KEY=sk-Abc123Def456Ghi789JklMno012Pqr
        zsh: permission denied: ./scripts/deploy.sh
        """
        let payload = try await Self.service(reading: secretiveShell).redactCapture(
            capture(png: ImageFixtures.solidWhitePNG(width: 400, height: 300), width: 400, height: 300)
        )

        #expect(payload.maskedText == nil)
        #expect(payload.shellSurface.showsShell)

        // **The real assertion: the verdict is a function of the signal classes and of nothing
        // else.** A second capture whose text shares not one word with the first — different user,
        // different host, different command, a different secret — produces an *equal* verdict,
        // because equality on this type is equality of the signal list. A field carrying a matched
        // line or a snippet, added later to help someone debug, would make these differ and would be
        // the leak this whole boundary exists to prevent.
        //
        // The previous version of this test looped over the signals asserting that the screen text
        // did not contain their raw values, which was near-vacuous (PR #57 F4): screen text does not
        // contain "interactive_prompt" whatever the verdict carries.
        let differentScreen = try await Self.service(reading: """
        priya@build-07 releases % cat /etc/shadow
        zsh: permission denied: /etc/shadow
        """).redactCapture(
            capture(png: ImageFixtures.solidWhitePNG(width: 400, height: 300), width: 400, height: 300)
        )
        #expect(differentScreen.shellSurface == payload.shellSurface)
        #expect(payload.shellSurface.signals == [.interactivePrompt, .commandRunInAShell, .shellDiagnostic])
    }

    /// **A recognizer that throws produces no payload at all** — so there is no verdict to misread
    /// as permission. The fail-closed property this check inherits, asserted at the level it lives
    /// at; `anUnreadableScreenEndsTheSessionRatherThanProducingANoShellVerdict` asserts the session
    /// consequence through the real runner.
    @Test
    func aRecognizerThatThrowsProducesNoPayloadRatherThanACleanVerdict() async throws {
        let service = LocalRedactionService(textRecognizer: FakeTextRecognizer(error: FakeOCRFailure()))
        await #expect(throws: LocalRedactionError.self) {
            _ = try await service.redactCapture(
                capture(png: ImageFixtures.solidWhitePNG(width: 400, height: 300), width: 400, height: 300)
            )
        }
    }

    /// The real recognizer, on a real rendered terminal window, through the real service — the one
    /// test here that does not fake the OCR seam. Everything above establishes what the detector
    /// concludes; this establishes that Vision reads a terminal well enough for it to conclude it.
    @Test
    func theRealRecognizerReadsARenderedTerminalWellEnoughToRefuseIt() async throws {
        let png = ImageFixtures.renderedTextPNG(
            width: 900,
            height: 300,
            lines: [
                ("Last login: Sat Aug 16 09:14:22 on ttys000", CGPoint(x: 20, y: 60)),
                ("sauransh@Mac macos-agent % ls -la", CGPoint(x: 20, y: 140)),
                ("total 48", CGPoint(x: 20, y: 220))
            ],
            fontSize: 24
        )

        let payload = try await LocalRedactionService().redactCapture(
            capture(png: png, width: 900, height: 300)
        )

        #expect(
            payload.shellSurface.showsShell,
            "real OCR read: \(payload.shellSurface.signals.map(\.rawValue))"
        )
    }
}

// MARK: - Structural non-bypass

struct RedactedPayloadStructureTests {
    @Test
    func payloadConstructionIsConfinedToTheRedactionServiceFile() throws {
        // The compile-time property under pin: RedactedPayload's only initializer is
        // fileprivate, and the type is not Decodable (a Decodable conformance would be a
        // public initializer in disguise). Asserted against the source because a test target
        // cannot express "this does not compile".
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore/LocalRedactionService.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let declarationStart = try #require(source.range(of: "public struct RedactedPayload"))
        let declarationEnd = try #require(source.range(of: "// MARK: - OCR seam"))
        let declaration = source[declarationStart.lowerBound..<declarationEnd.lowerBound]

        #expect(declaration.contains("fileprivate init("))
        #expect(!declaration.contains("public init"))
        #expect(!declaration.contains("Codable"))
        #expect(!declaration.contains("Decodable"))
        // Content fields are immutable — a mutable field would let a caller launder unredacted
        // content into a service-built payload.
        #expect(!declaration.contains("public var"))
    }

    @Test
    func onlyTheServiceProducesPayloadsInTheLiveModule() throws {
        // Enumeration half of the non-bypass claim: RedactedPayload( construction appears in
        // exactly one production file — the service's own.
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let coreDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MacAgentCore")
        let files = try FileManager.default.contentsOfDirectory(at: coreDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 50)

        var constructingFiles: Set<String> = []
        for file in files {
            let contents = try String(contentsOf: file, encoding: .utf8)
            if contents.contains("RedactedPayload(") {
                constructingFiles.insert(file.lastPathComponent)
            }
        }
        #expect(constructingFiles == ["LocalRedactionService.swift"])
    }
}
