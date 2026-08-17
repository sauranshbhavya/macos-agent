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
}

// MARK: - Live Vision pipeline

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
            ]
        )
        let service = LocalRedactionService()

        let clock = ContinuousClock()
        let start = clock.now
        _ = try await service.redactCapture(capture(png: png, width: 800, height: 600))
        let elapsed = clock.now - start

        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("REDACTION-LATENCY-MS: \(Int(milliseconds.rounded())) (800x600, 4 lines, 2 secrets)")
        // Bounded, not fast: the ceiling exists so a pathological regression fails loudly.
        // The real number for the record is printed above and recorded with its SHA.
        #expect(elapsed < .seconds(5))
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
