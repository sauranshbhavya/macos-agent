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

    /// **The ceiling is a tripwire for a pathological regression, not a latency budget** — and the
    /// difference is what SONNY-224 came here to fix. At `.seconds(5)` this was a bet on how busy the
    /// machine was, and it was losing: measured with the flagged suite at `961b9c2`, this same call
    /// took **1465 ms** on an idle run, **4422 ms** and **4644 ms** with an ordinary parallel suite
    /// around it, and **11742 ms** with a cold `swift build` beside it (`grep REDACTION-LATENCY-MS`
    /// over four consecutive runs). The middle two are inside a 5 s ceiling by 7%, which is not a
    /// margin; the last one is over it. Under a mutation battery that failure is worse than a red
    /// suite — `scripts/mutate` reads any failing test as the mutant being caught, so a wall-clock
    /// loss here is recorded as coverage that does not exist.
    ///
    /// Sixty seconds keeps every claim this test actually makes. The claim is not "redaction is
    /// fast" — the real number is printed below and belongs in the record with its SHA — it is that
    /// a regression turning a second and a half into a minute fails loudly. That still fails, with
    /// five times the headroom over the worst load yet measured here, and no dependence on what else
    /// the machine is doing.
    ///
    /// The content expectations are new with the same change. Timing a call that is never checked to
    /// have done anything is a benchmark rather than a test, and a mutant that made `redactCapture`
    /// return early would have passed this the whole time — faster. Writing them is also what turned
    /// up **SONNY-260**: the fixture plants two secrets and the label below says two, and the real
    /// recognizer finds one. So the card is asserted and the key is not, which is the true statement
    /// rather than the tidy one.
    ///
    /// One of those expectations was `redactedImageData != nil`, which asserted nothing at all —
    /// `redactCapture` builds its payload from `EncodedVisionCapture.data`, a non-optional, so it
    /// was true by construction on every path that reached it while its own comment claimed it
    /// proved painted pixels (PR #112 review, F5). It is a pixel check now, on coordinates that were
    /// measured rather than guessed.
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
        let payload = try await service.redactCapture(capture(png: png, width: 800, height: 600))
        let elapsed = clock.now - start

        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        print("REDACTION-LATENCY-MS: \(Int(milliseconds.rounded())) (800x600, 4 lines, 2 secrets)")
        // Bounded, not fast: the ceiling exists so a pathological regression fails loudly.
        // The real number for the record is printed above and recorded with its SHA.
        #expect(elapsed < .seconds(60))

        // The work the number above is a measurement of actually happened: a planted secret was
        // classified, and the pixels came back painted. The card and not the key, deliberately —
        // the real recognizer finds only the card on this fixture, and why that is is SONNY-260.
        #expect(payload.report.contains { $0.detectionClass == .creditCardNumber })

        // Painted, read off the pixels. Row 360 runs through the middle of the box the real
        // recognizer puts over the card line — measured at x 38...505, y 344...375 — so every probe
        // below sits at least fifteen pixels inside it in either direction, rather than on an edge a
        // Vision update could move by three. Probing the *unredacted* fixture at the same points is
        // what makes the black mean painted rather than "the glyphs were already dark there": at
        // that row the rendered text inks 64 of the 468 pixels the box covers, so five out of five
        // is something only the paint can produce. Five reads rather than a sweep — every read
        // decodes the PNG again.
        let redacted = try #require(payload.redactedImageData)
        let probes = [60, 150, 270, 390, 490]
        let paintedBlack = probes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: redacted, x: $0, yFromTop: 360)) }
            .count
        let fixtureBlack = probes
            .filter { ImageFixtures.isBlack(ImageFixtures.rgb(inPNG: png, x: $0, yFromTop: 360)) }
            .count
        #expect(paintedBlack == probes.count)
        #expect(fixtureBlack < probes.count)
        // A box, not the whole capture: an all-black image would satisfy the line above.
        #expect(ImageFixtures.isWhite(ImageFixtures.rgb(inPNG: redacted, x: 10, yFromTop: 10)))
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
