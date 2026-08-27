import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Media type

/// The image formats a redacted capture may leave the device in.
///
/// Closed on purpose. The raw value is the media type written into the `data:` URL the vision
/// request carries, so adding a case means having checked that the route actually accepts it —
/// SONNY-114 measured HEIC as the smallest encoding on this machine by a wide margin and did not
/// add it for exactly that reason. WebP is not here for a blunter one: `CGImageDestination` on
/// macOS 26.5 refuses to create a destination for `org.webmproject.webp` at all, so the encoder
/// does not exist to call.
public enum VisionCaptureMediaType: String, Equatable, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"

    var contentTypeIdentifier: String {
        switch self {
        case .png: return UTType.png.identifier
        case .jpeg: return UTType.jpeg.identifier
        }
    }
}

// MARK: - Policy

/// How a redacted capture is turned into the bytes that leave the device.
///
/// **Every number here was measured, not chosen** (SONNY-114, at `9a84e3b`, on real captures from
/// the three displays attached to the development machine plus synthetic stress images at display
/// sizes this machine does not have). The two findings the shape follows from:
///
/// 1. **The capture is already at its minimum sensible resolution.** `ScreenCaptureService` captures
///    at `.nominal` — one pixel per point — so a 13-point control label is already 13 pixels tall.
///    Resampling below that destroys text: on-device OCR reproduced 85% of the baseline's lines
///    verbatim from a full-resolution JPEG and 3% from a *lossless* half-scale PNG. Resolution is
///    the expensive axis and quality is the cheap one, so the ladder spends quality first and only
///    resamples once quality is exhausted.
/// 2. **Lossy is not always smaller.** Dense small text is JPEG's worst case and PNG's best: a full
///    screen of 13-point type encoded 1,174,367 bytes as PNG and 1,432,189 as JPEG q80. That is the
///    same content class where lossy compression costs the most legibility — so "encode both, send
///    the smaller" routes exactly the fidelity-critical captures to lossless, without needing a rule
///    that says so.
public struct VisionCaptureEgressPolicy: Equatable, Sendable {
    /// One rung of the degradation ladder: how far to resample, and at what JPEG quality.
    public struct Rung: Equatable, Sendable {
        /// 1.0 is the capture's own resolution. Below 1.0 costs legibility and is a last resort.
        public let scale: Double
        public let jpegQuality: Double

        public init(scale: Double, jpegQuality: Double) {
            self.scale = scale
            self.jpegQuality = jpegQuality
        }
    }

    /// The byte ceiling the ladder encodes down to, on the image alone — before base64, which
    /// inflates it by 4/3.
    ///
    /// **Derived, not inherited.** Base64 plus the JSON envelope turns an image of this size into a
    /// request body of `ceil(n/3) * 4` bytes plus the prompt — 4,000,000 + ~4,700 at this value,
    /// measured against the literal body ``SonnyVisionModelClient/decide(prompt:payload:session:)``
    /// builds. That is the number row 12's host choice is sized against, and it is what puts the
    /// request under the body limits that a 12 MB request ruled out.
    ///
    /// **And it is now the same number on the gateway** (SONNY-131): `MAXIMUM_IMAGE_BYTES` in
    /// `server/src/model/limits.ts`, from which §6.1's 4,200,000 body limit is derived rather than
    /// written as a second literal.
    public let maximumImageBytes: Int

    /// Tried in order; the first rung whose encoding fits ``maximumImageBytes`` wins.
    public let ladder: [Rung]

    public init(maximumImageBytes: Int, ladder: [Rung]) {
        self.maximumImageBytes = maximumImageBytes
        self.ladder = ladder
    }

    /// The shipping policy.
    ///
    /// The ladder's ordering is the measured cost of each degradation, cheapest first. Full
    /// resolution at q80 sits on the flat part of the quality curve: across every real capture
    /// measured, on-device OCR's character-level agreement with the lossless baseline moved by less
    /// than 0.02 between q70 and q90, while q60 was measurably worse. Dropping to q60 before
    /// resampling is not a preference — full-resolution q60 beat lossless 0.9-scale on *both*
    /// legibility metrics while producing less than half the bytes.
    ///
    /// **The floor is 0.5 and there is nothing below it.** Half scale already collapses OCR's exact
    /// line agreement to 0.03–0.12, so a rung below it would be sending an image nothing can read.
    /// A capture that cannot fit even there keeps the behaviour the client documented before this
    /// change: a clear refusal, not a picture that wastes the model's iterations.
    public static let `default` = VisionCaptureEgressPolicy(
        maximumImageBytes: 3_000_000,
        ladder: [
            Rung(scale: 1.0, jpegQuality: 0.8),
            Rung(scale: 1.0, jpegQuality: 0.6),
            Rung(scale: 0.8, jpegQuality: 0.6),
            Rung(scale: 0.64, jpegQuality: 0.6),
            Rung(scale: 0.5, jpegQuality: 0.6)
        ]
    )
}

// MARK: - Result

/// What the encoder produced: the bytes, the media type they are, and the pixel dimensions **the
/// model will actually see**.
///
/// The dimensions travel with the bytes because after SONNY-114 they are no longer necessarily the
/// capture's own. Everything the model is told about the image, and every coordinate it returns,
/// belongs to this size — see ``VisionPointResolver``.
struct EncodedVisionCapture: Equatable, Sendable {
    let data: Data
    let mediaType: VisionCaptureMediaType
    let pixelWidth: Int
    let pixelHeight: Int
}

// MARK: - The encoder

/// Paints redaction regions onto a capture and encodes the result for egress.
///
/// **The ordering is the reason this is one type with one entry point.** Redaction paints regions
/// onto the image before it leaves; any resampling has to happen *after* that, never before, or a
/// downscale run first would smear a secret's pixels into the neighbours of the rectangle that was
/// supposed to hide them. ``render(paintingRegions:inPNGData:policy:)`` is the only way in, it takes
/// the regions and the source bytes together, and the painted pixels are carried between the two
/// halves as a type whose initializer is private to this file. Resampling an unpainted image is not
/// a mistake a caller can make here — there is no function that accepts one.
enum RedactedCaptureEncoder {
    /// Pixels that have already been through redaction painting.
    ///
    /// The token that makes the ordering structural rather than remembered: ``encode(_:policy:)``
    /// takes this and nothing else, and only ``paint(_:on:)`` produces it.
    private struct RedactedPixels {
        let image: CGImage
    }

    /// Paint the regions, then encode — in that order, in one call.
    static func render(
        paintingRegions regions: [CGRect],
        inPNGData pngData: Data,
        policy: VisionCaptureEgressPolicy
    ) throws -> EncodedVisionCapture {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LocalRedactionError.imageRedactionFailed("the capture data is not a decodable image")
        }
        return try encode(paint(regions, on: image), policy: policy)
    }

    /// Paints the given top-left-origin pixel rects with opaque black, onto an opaque canvas.
    ///
    /// Opaque fill rather than a Gaussian blur is a deliberate call: a blur is a convolution with
    /// residual information (partially invertible on text-sized regions), while a fill is provably
    /// zero-information — the fail-closed reading of §12.3's "blur". The product language stays
    /// "redacted".
    ///
    /// The canvas is opaque (`noneSkipLast` over black) rather than alpha-bearing, which is new with
    /// SONNY-114 and load-bearing for two reasons. JPEG cannot carry alpha at all, so the two
    /// candidate encodings would otherwise be encoding two different pictures and their sizes would
    /// not be comparable. And a window capture *does* carry alpha — `SCContentFilter`'s
    /// desktop-independent window leaves the rounded corners transparent — so without this the PNG
    /// candidate would pay for a fourth channel that the JPEG one drops. Black is the
    /// status-quo-preserving choice: an alpha-bearing PNG's transparent pixels composite onto black
    /// in a decoder that ignores alpha, which is what those corners already became on the way out.
    private static func paint(_ regions: [CGRect], on image: CGImage) throws -> RedactedPixels {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw LocalRedactionError.imageRedactionFailed("no drawing context for \(width)x\(height)")
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        for region in regions {
            // Top-left-origin rect → CoreGraphics bottom-left-origin space, clamped to the image.
            let flipped = CGRect(
                x: region.minX,
                y: CGFloat(height) - region.maxY,
                width: region.width,
                height: region.height
            ).intersection(bounds)
            // A region entirely outside the image cannot be painted, and silently skipping it
            // would leave the report claiming a redaction that did not happen (PR #49 F8) —
            // the same false-attestation class as F1, so the same answer: fail closed. The
            // shipped Vision recognizer cannot produce one (its boxes are normalized then
            // scaled), but `ImageTextRecognizing` is a public seam and row I plugs into it.
            guard !flipped.isEmpty else {
                throw LocalRedactionError.imageRedactionFailed(
                    "a detected region lies entirely outside the \(width)x\(height) capture"
                )
            }
            context.fill(flipped)
        }

        guard let painted = context.makeImage() else {
            throw LocalRedactionError.imageRedactionFailed("the redacted image could not be rasterized")
        }
        return RedactedPixels(image: painted)
    }

    /// Walk the ladder and return the first encoding that fits the policy's budget.
    private static func encode(
        _ pixels: RedactedPixels,
        policy: VisionCaptureEgressPolicy
    ) throws -> EncodedVisionCapture {
        var smallest: EncodedVisionCapture?
        // The rungs are ordered by scale, so consecutive rungs at the same scale share a lossless
        // encoding. Only the over-budget path ever sees a second rung, but a PNG encode of a
        // full-screen capture is the most expensive step here and re-doing it would be pure waste.
        var losslessCache: (scale: Double, encoded: EncodedVisionCapture)?

        for rung in policy.ladder {
            let image = try resampled(pixels.image, scale: rung.scale)
            let lossless: EncodedVisionCapture
            if let losslessCache, losslessCache.scale == rung.scale {
                lossless = losslessCache.encoded
            } else {
                lossless = try encoded(image, as: .png, quality: nil)
                losslessCache = (rung.scale, lossless)
            }
            let lossy = try encoded(image, as: .jpeg, quality: rung.jpegQuality)

            // Strictly smaller, so a tie keeps the lossless one.
            let candidate = lossy.data.count < lossless.data.count ? lossy : lossless
            if smallest == nil || candidate.data.count < smallest!.data.count {
                smallest = candidate
            }
            if candidate.data.count <= policy.maximumImageBytes {
                return candidate
            }
        }

        // Past the floor. The smallest the ladder reached goes back rather than a throw, because the
        // refusal belongs to the client that owns the wire limit and its message — this type would
        // only be guessing at one. See `SonnyVisionModelClient.maximumImageBytes`.
        guard let smallest else {
            throw LocalRedactionError.imageRedactionFailed("the redaction policy has no encoding steps")
        }
        return smallest
    }

    private static func resampled(_ image: CGImage, scale: Double) throws -> CGImage {
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw LocalRedactionError.imageRedactionFailed("no drawing context for \(width)x\(height)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw LocalRedactionError.imageRedactionFailed("the capture could not be resampled to \(width)x\(height)")
        }
        return resized
    }

    private static func encoded(
        _ image: CGImage,
        as mediaType: VisionCaptureMediaType,
        quality: Double?
    ) throws -> EncodedVisionCapture {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            mediaType.contentTypeIdentifier as CFString,
            1,
            nil
        ) else {
            throw LocalRedactionError.imageRedactionFailed("no \(mediaType.rawValue) encoder is available")
        }
        var properties: [CFString: Any] = [:]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties.isEmpty ? nil : properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LocalRedactionError.imageRedactionFailed("the redacted image could not be encoded as \(mediaType.rawValue)")
        }
        return EncodedVisionCapture(
            data: buffer as Data,
            mediaType: mediaType,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
