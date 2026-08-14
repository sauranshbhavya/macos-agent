import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Report

public enum RedactionLocationCategory: String, Codable, Equatable, Sendable {
    case imageRegion = "image_region"
    case text = "text"
}

/// §12.3's report shape: {type, count, location category, confidence}. One entry per detection
/// class per surface; `confidence` is the LOWEST confidence among the coalesced detections (the
/// honest worst case), and `belowConfidenceThreshold` marks that at least one of them rode the
/// fail-closed redact-and-flag path. Codable so a consuming surface can persist or render
/// entries; the first consumer is Safe mode's pre-send preview when row I's vision iterations
/// arrive.
public struct RedactionReportEntry: Codable, Equatable, Sendable {
    public var detectionClass: SecretDetectionClass
    public var count: Int
    public var locationCategory: RedactionLocationCategory
    public var confidence: Double
    public var belowConfidenceThreshold: Bool

    public init(
        detectionClass: SecretDetectionClass,
        count: Int,
        locationCategory: RedactionLocationCategory,
        confidence: Double,
        belowConfidenceThreshold: Bool
    ) {
        self.detectionClass = detectionClass
        self.count = count
        self.locationCategory = locationCategory
        self.confidence = confidence
        self.belowConfidenceThreshold = belowConfidenceThreshold
    }
}

// MARK: - Payload

/// The only egress currency for redacted content. The structural non-bypass lives here:
/// construction is `fileprivate`, so the ONLY way to obtain one — inside this module as much as
/// outside it — is through `LocalRedactionService` in this file. A function that egresses screen
/// content takes this type, and an unredacted egress therefore does not compile; there is no
/// caller opt-out to design around.
///
/// Deliberately NOT Codable: a `Decodable` conformance is a public initializer in disguise
/// (`JSONDecoder` would mint payloads from arbitrary bytes). The report entries persist
/// (they are Codable on their own); the payload never does.
public struct RedactedPayload: Equatable, Sendable {
    public let maskedText: String?
    public let redactedImagePNGData: Data?
    public let imagePixelWidth: Int?
    public let imagePixelHeight: Int?
    public let sourceBundleIdentifier: String?
    public let report: [RedactionReportEntry]

    fileprivate init(
        maskedText: String?,
        redactedImagePNGData: Data?,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?,
        sourceBundleIdentifier: String?,
        report: [RedactionReportEntry]
    ) {
        self.maskedText = maskedText
        self.redactedImagePNGData = redactedImagePNGData
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.report = report
    }
}

// MARK: - OCR seam

/// One line of text the recognizer found, with its pixel-space bounding box (top-left origin —
/// the Vision implementation owns the conversion from Vision's normalized bottom-left space).
public struct RecognizedTextObservation: Equatable, Sendable {
    public var string: String
    public var boundingBox: CGRect

    public init(string: String, boundingBox: CGRect) {
        self.string = string
        self.boundingBox = boundingBox
    }
}

public protocol ImageTextRecognizing: Sendable {
    func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation]
}

// MARK: - Errors

public enum LocalRedactionError: Error, Equatable, LocalizedError {
    case detectionUnavailable(String)
    case imageRedactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .detectionUnavailable(let reason):
            return "Sonny could not scan this capture for secrets, so it will not be sent: \(reason)"
        case .imageRedactionFailed(let reason):
            return "Sonny could not redact this capture, so it will not be sent: \(reason)"
        }
    }
}

// MARK: - Service

/// Best-effort, fail-closed local redaction (§12.3): masks secret-shaped strings in text and
/// paints out secret-bearing regions in images, reporting what it did. Best-effort is a stated
/// property, never a guarantee — the fail-closed half is what it promises: a likely-secret shape
/// below the confidence threshold is redacted and flagged rather than passed through, and a
/// capture whose scan cannot run at all produces an error, never an unscanned payload.
public struct LocalRedactionService: Sendable {
    public static let defaultConfidenceThreshold = 0.8

    private let textRecognizer: any ImageTextRecognizing
    private let detector = SecretTextDetector()
    private let confidenceThreshold: Double

    public init(
        textRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer(),
        confidenceThreshold: Double = LocalRedactionService.defaultConfidenceThreshold
    ) {
        self.textRecognizer = textRecognizer
        self.confidenceThreshold = confidenceThreshold
    }

    public func redactText(_ text: String) -> RedactedPayload {
        let matches = detector.matches(in: text)
        let masked = SecretTextDetector.mask(matches: matches, in: text)
        return RedactedPayload(
            maskedText: masked,
            redactedImagePNGData: nil,
            imagePixelWidth: nil,
            imagePixelHeight: nil,
            sourceBundleIdentifier: nil,
            report: report(from: matches, category: .text)
        )
    }

    public func redactCapture(_ capture: CapturedWindowImage) async throws -> RedactedPayload {
        let observations: [RecognizedTextObservation]
        do {
            observations = try await textRecognizer.recognizeText(
                inPNGData: capture.pngData,
                pixelWidth: capture.pixelWidth,
                pixelHeight: capture.pixelHeight
            )
        } catch {
            // Fail closed: no scan, no payload. An unscanned image must never become sendable.
            throw LocalRedactionError.detectionUnavailable(String(describing: error))
        }

        var regions: [CGRect] = []
        var matches: [SecretTextMatch] = []
        for observation in observations {
            let observationMatches = detector.matches(in: observation.string)
            guard !observationMatches.isEmpty else { continue }
            // The whole observation box is painted out, not a per-character sub-box — the
            // cheap over-redaction side of §12.3's tradeoff, with a small pad for the
            // anti-aliased edges the recognizer's box can clip.
            regions.append(observation.boundingBox.insetBy(dx: -2, dy: -2))
            matches.append(contentsOf: observationMatches)
        }

        let pngData: Data
        let width: Int
        let height: Int
        if regions.isEmpty {
            (pngData, width, height) = (capture.pngData, capture.pixelWidth, capture.pixelHeight)
        } else {
            do {
                (pngData, width, height) = try RedactionImageRenderer.fillRegions(regions, inPNGData: capture.pngData)
            } catch {
                // Fail closed again: pixels that could not be painted out are pixels that
                // do not leave the device.
                throw LocalRedactionError.imageRedactionFailed(String(describing: error))
            }
        }

        return RedactedPayload(
            maskedText: nil,
            redactedImagePNGData: pngData,
            imagePixelWidth: width,
            imagePixelHeight: height,
            sourceBundleIdentifier: capture.bundleIdentifier,
            report: report(from: matches, category: .imageRegion)
        )
    }

    private func report(from matches: [SecretTextMatch], category: RedactionLocationCategory) -> [RedactionReportEntry] {
        let grouped = Dictionary(grouping: matches, by: \.detectionClass)
        return grouped
            .map { detectionClass, classMatches in
                RedactionReportEntry(
                    detectionClass: detectionClass,
                    count: classMatches.count,
                    locationCategory: category,
                    confidence: classMatches.map(\.confidence).min() ?? 0,
                    belowConfidenceThreshold: classMatches.contains { $0.confidence < confidenceThreshold }
                )
            }
            .sorted { $0.detectionClass.rawValue < $1.detectionClass.rawValue }
    }
}

// MARK: - Region painting

enum RedactionImageRenderer {
    /// Paints the given top-left-origin pixel rects with opaque black and re-encodes as PNG.
    ///
    /// Opaque fill rather than a Gaussian blur is a deliberate call: a blur is a convolution
    /// with residual information (partially invertible on text-sized regions), while a fill is
    /// provably zero-information — the fail-closed reading of §12.3's "blur". The product
    /// language stays "redacted".
    static func fillRegions(_ regions: [CGRect], inPNGData pngData: Data) throws -> (Data, Int, Int) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LocalRedactionError.imageRedactionFailed("the capture data is not a decodable image")
        }
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw LocalRedactionError.imageRedactionFailed("no drawing context for \(width)x\(height)")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        for region in regions {
            // Top-left-origin rect → CoreGraphics bottom-left-origin space, clamped to the image.
            let flipped = CGRect(
                x: region.minX,
                y: CGFloat(height) - region.maxY,
                width: region.width,
                height: region.height
            ).intersection(bounds)
            guard !flipped.isEmpty else { continue }
            context.fill(flipped)
        }

        guard let redacted = context.makeImage(), let data = Self.pngData(from: redacted) else {
            throw LocalRedactionError.imageRedactionFailed("the redacted image could not be encoded as PNG")
        }
        return (data, width, height)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
