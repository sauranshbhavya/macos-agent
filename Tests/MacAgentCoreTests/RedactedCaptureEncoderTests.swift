import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MacAgentCore

// MARK: - Fakes

private struct StubRecognizer: ImageTextRecognizing {
    var observations: [RecognizedTextObservation] = []

    func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
        observations
    }
}

private func fixtureCapture(png: Data, width: Int, height: Int) -> CapturedWindowImage {
    CapturedWindowImage(
        pngData: png,
        pixelWidth: width,
        pixelHeight: height,
        bundleIdentifier: "com.example.notes",
        windowTitle: "Fixture",
        windowID: 1,
        windowFrame: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
    )
}

/// A budget nothing can meet, so the ladder always runs to its 0.5 floor. Used to exercise the
/// resampling path deterministically without needing a fixture the size of a real 5K screen.
private let flooredPolicy = VisionCaptureEgressPolicy(
    maximumImageBytes: 1,
    ladder: VisionCaptureEgressPolicy.default.ladder
)

/// SONNY-114: what the egress encoder guarantees about the bytes that leave the device.
@Suite
struct RedactedCaptureEncoderTests {

    // MARK: - Format choice

    /// **The smaller of the two encodings ships, and that is what routes fidelity-critical captures
    /// to lossless without a rule that says so.** Dense, sharp, two-tone content is simultaneously
    /// PNG's best case and JPEG's worst — both for size and for what lossy compression does to small
    /// text — so "pick the smaller" and "pick the one that reads better" agree on it. Measured for
    /// SONNY-114 on real captures at `9a84e3b`: a terminal window chose PNG (60,390 bytes against
    /// JPEG q80's 78,315) while a photo-heavy desktop chose JPEG (124,953 against PNG's 1,552,704).
    @Test
    func theSmallerOfTheLosslessAndLossyEncodingsIsTheOneThatShips() async throws {
        let service = LocalRedactionService(textRecognizer: StubRecognizer())

        // Two-tone: flat runs compress losslessly to far less than any DCT of the same edges.
        let twoTone = ImageFixtures.whiteOverBlackPNG(width: 600, height: 400)
        let flat = try await service.redactCapture(fixtureCapture(png: twoTone, width: 600, height: 400))
        #expect(flat.imageMediaType == .png)

        // Uniform noise: nothing to predict, so lossless pays full price and lossy does not.
        let noise = ImageFixtures.uniformNoisePNG(width: 600, height: 400)
        let busy = try await service.redactCapture(fixtureCapture(png: noise, width: 600, height: 400))
        #expect(busy.imageMediaType == .jpeg)
        let losslessBytes = noise.count
        let sentBytes = try #require(busy.redactedImageData).count
        #expect(sentBytes < losslessBytes)
    }

    /// The media type describes the bytes, rather than being a label attached beside them. A payload
    /// that said `.png` over JPEG bytes would produce a `data:image/png;base64,…` URL carrying a
    /// JPEG, which is the exact bug the hardcoded literal in `OpenCodeVisionModelClient` was.
    @Test
    func theDeclaredMediaTypeMatchesWhatTheBytesActuallyAre() async throws {
        let service = LocalRedactionService(textRecognizer: StubRecognizer())
        for png in [
            ImageFixtures.whiteOverBlackPNG(width: 300, height: 200),
            ImageFixtures.uniformNoisePNG(width: 300, height: 200)
        ] {
            let payload = try await service.redactCapture(fixtureCapture(png: png, width: 300, height: 200))
            let data = try #require(payload.redactedImageData)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let declared = try #require(CGImageSourceGetType(source)) as String
            switch try #require(payload.imageMediaType) {
            case .png: #expect(declared == UTType.png.identifier)
            case .jpeg: #expect(declared == UTType.jpeg.identifier)
            }
        }
    }

    // MARK: - The dimensions a coordinate is named in

    /// The payload's reported dimensions are the encoded image's own, not the capture's.
    ///
    /// This is the contract the whole acting path rests on: `VisionSessionPromptBuilder` tells the
    /// model these numbers, and `VisionPointResolver` scales the model's answer by them. A payload
    /// that reported the capture's dimensions after resampling would put every click off by the
    /// resample factor.
    @Test
    func theReportedDimensionsAreTheEncodedImagesOwnAtEveryLadderRung() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 500, height: 300)
        for policy in [VisionCaptureEgressPolicy.default, flooredPolicy] {
            let service = LocalRedactionService(textRecognizer: StubRecognizer(), egressPolicy: policy)
            let payload = try await service.redactCapture(fixtureCapture(png: png, width: 500, height: 300))
            let decoded = ImageFixtures.decoded(try #require(payload.redactedImageData))
            #expect(payload.imagePixelWidth == decoded.width)
            #expect(payload.imagePixelHeight == decoded.height)
        }
    }

    /// A capture that fits is never resampled. Every real capture measured for SONNY-114 — three
    /// displays and two windows on the development machine, plus synthetic full screens of 13-point
    /// type at five display sizes up to 3440x1440 — took this path.
    @Test
    func aCaptureInsideTheBudgetKeepsEveryPixelOfItsResolution() async throws {
        let service = LocalRedactionService(textRecognizer: StubRecognizer())
        let png = ImageFixtures.whiteOverBlackPNG(width: 1_728, height: 1_117)

        let payload = try await service.redactCapture(fixtureCapture(png: png, width: 1_728, height: 1_117))

        #expect(payload.imagePixelWidth == 1_728)
        #expect(payload.imagePixelHeight == 1_117)
        #expect(try #require(payload.redactedImageData).count <= VisionCaptureEgressPolicy.default.maximumImageBytes)
    }

    /// **Quality is spent before resolution, and that ordering is measured rather than assumed.** At
    /// full resolution and q60, on-device OCR reproduced more of a real capture's text than a
    /// *lossless* encoding of the same capture at 0.9 scale did — 0.761 of its lines verbatim against
    /// 0.718, at 0.972 character agreement against 0.902 — while producing less than half the bytes.
    /// A ladder that resampled first would pay more legibility for less saving.
    @Test
    func aBudgetOnlyTheLowerQualityRungCanMeetLeavesTheResolutionAlone() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 700, height: 500)
        let service = LocalRedactionService(textRecognizer: StubRecognizer())
        let atDefaultQuality = try await service.redactCapture(fixtureCapture(png: png, width: 700, height: 500))
        let q80Bytes = try #require(atDefaultQuality.redactedImageData).count

        // A budget below what the first rung produced, so the ladder must move — but reachable at
        // full resolution by the second rung's lower quality.
        let policy = VisionCaptureEgressPolicy(
            maximumImageBytes: q80Bytes - 1,
            ladder: VisionCaptureEgressPolicy.default.ladder
        )
        let payload = try await LocalRedactionService(textRecognizer: StubRecognizer(), egressPolicy: policy)
            .redactCapture(fixtureCapture(png: png, width: 700, height: 500))

        #expect(payload.imagePixelWidth == 700)
        #expect(payload.imagePixelHeight == 500)
        #expect(try #require(payload.redactedImageData).count <= q80Bytes - 1)
    }

    /// **The ladder stops at half scale and hands back what it got.**
    ///
    /// Below 0.5 there is nothing worth sending: on-device OCR's verbatim line agreement on real
    /// captures collapses from 0.79–0.90 at full resolution to 0.03–0.10 at half, and that is with a
    /// *lossless* encoding — the loss is the resolution, not the compression. A rung below the floor
    /// would be trading a clear refusal for a picture nothing can read. The refusal itself belongs to
    /// the client that owns the wire limit, so the encoder returns the smallest it managed and
    /// `OpenCodeVisionModelClient` declines it with its own message.
    @Test
    func theLadderStopsAtHalfScaleRatherThanSendingSomethingUnreadable() async throws {
        let png = ImageFixtures.uniformNoisePNG(width: 800, height: 600)
        let service = LocalRedactionService(textRecognizer: StubRecognizer(), egressPolicy: flooredPolicy)

        let payload = try await service.redactCapture(fixtureCapture(png: png, width: 800, height: 600))

        #expect(payload.imagePixelWidth == 400)
        #expect(payload.imagePixelHeight == 300)
        // Still over the (impossible) budget: the encoder does not pretend to have met it.
        #expect(try #require(payload.redactedImageData).count > flooredPolicy.maximumImageBytes)
    }

    // MARK: - The ordering guarantee

    /// **Resampling runs after redaction painting, pinned rather than asserted** — the ticket's
    /// fourth obligation.
    ///
    /// The fixture plants a pure-red block and tells the recognizer it is a secret. Painted first,
    /// the block is opaque black before a single pixel is resampled, so the payload is black and
    /// white and every blend the resample produces between them is grey: red dominance zero, at
    /// every rung, everywhere in the image. The control implements the misordering and asserts the
    /// tracer survives it, so "no red found" cannot be a test that passes whether or not the
    /// property holds.
    ///
    /// **One thing measured here came out against the ticket's stated worry, and it is recorded
    /// rather than quietly dropped.** SONNY-114 expected a resample-before-paint to smear a redacted
    /// region's edges past the rectangle. Measured at `9a84e3b` on this fixture at every ladder scale
    /// (0.8, 0.64, 0.5) and at both round and odd source dimensions, a misordering that *also
    /// rescales the region* leaks nothing — 0 red dominance — because
    /// `LocalRedactionService`'s existing 2-pixel pad is wider than the resample kernel's spread even
    /// after the pad itself shrinks. The pad is doing work nobody had counted on it for, and it would
    /// stop doing it if the pad were ever narrowed. What does leak, badly, is the misordering that
    /// forgets to rescale the region — 219 to 231 red dominance across the same grid, which is a
    /// region left almost entirely unpainted. That is the realistic shape of the bug and it is what
    /// the control below implements.
    @Test
    func resamplingRunsAfterPaintingSoNoTraceOfARedactedRegionSurvivesTheResample() async throws {
        let width = 400
        let height = 400
        let secret = CGRect(x: 150, y: 150, width: 100, height: 100)
        let png = ImageFixtures.redBlockOnWhitePNG(width: width, height: height, block: secret)
        let recognizer = StubRecognizer(observations: [
            RecognizedTextObservation(string: "sk-Ab12Cd34Ef56Gh78Ij90", boundingBox: secret)
        ])

        // Every rung, not just the floor: the guarantee is about the order, not about one scale.
        for policy in [VisionCaptureEgressPolicy.default, flooredPolicy] {
            let payload = try await LocalRedactionService(textRecognizer: recognizer, egressPolicy: policy)
                .redactCapture(fixtureCapture(png: png, width: width, height: height))
            let sent = try #require(payload.redactedImageData)
            #expect(ImageFixtures.maximumRedDominance(inImageData: sent) == 0)
        }

        // The control: resample first, then paint the region in the coordinate space it was detected
        // in. Nothing about the payload above distinguishes the two orders unless this leaks.
        let wrongOrder = Self.resampleThenPaint(png: png, scale: 0.5, region: secret.insetBy(dx: -2, dy: -2))
        #expect(
            ImageFixtures.maximumRedDominance(inImageData: wrongOrder) > 100,
            "the tracer must survive the wrong order, or this test proves nothing"
        )
    }

    /// The wrong order, implemented here so the test above has something to fail against: resample
    /// the capture, *then* paint the region — in the coordinates the recognizer produced, which are
    /// the capture's and no longer the image's.
    private static func resampleThenPaint(png: Data, scale: Double, region: CGRect) -> Data {
        let source = ImageFixtures.decoded(png)
        let width = Int((Double(source.width) * scale).rounded())
        let height = Int((Double(source.height) * scale).rounded())
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(
            x: region.minX,
            y: CGFloat(height) - region.maxY,
            width: region.width,
            height: region.height
        ))

        let buffer = NSMutableData()
        let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return buffer as Data
    }

    // MARK: - The flatten

    /// The opaque canvas is required by the format choice — JPEG cannot carry alpha, so without it
    /// the two candidate encodings would be describing different pictures and their sizes would not
    /// be comparable. It costs nothing visible: a window capture's only non-opaque pixels are its
    /// rounded corners, which are transparent *black*, so compositing them onto black leaves them
    /// exactly where they were. Verified on the real captures at `9a84e3b`: 356 sub-opaque pixels in
    /// each window capture, zero pixels whose RGB changed.
    @Test
    func theOpaqueCanvasLeavesTheVisiblePixelsExactlyWhereTheyWere() async throws {
        let width = 240
        let height = 160
        let png = ImageFixtures.whiteOverBlackPNG(width: width, height: height)
        let service = LocalRedactionService(textRecognizer: StubRecognizer())

        let payload = try await service.redactCapture(fixtureCapture(png: png, width: width, height: height))
        let sent = try #require(payload.redactedImageData)

        for x in stride(from: 2, to: width, by: 17) {
            for y in stride(from: 2, to: height, by: 13) {
                let before = ImageFixtures.rgb(inPNG: png, x: x, yFromTop: y)
                let after = ImageFixtures.rgb(inPNG: sent, x: x, yFromTop: y)
                #expect(before == after, "pixel (\(x), \(y)) changed")
            }
        }
    }
}
