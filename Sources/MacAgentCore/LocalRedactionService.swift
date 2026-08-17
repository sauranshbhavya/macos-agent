import CoreGraphics
import Foundation

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
    /// The redacted image, in whatever format ``imageMediaType`` names.
    ///
    /// Not `…PNGData` any more (SONNY-114): the egress encoder picks between PNG and JPEG per
    /// capture, so a name that asserted one of them would be wrong on roughly half of real captures.
    public let redactedImageData: Data?
    /// What ``redactedImageData`` actually is. `nil` exactly when there is no image.
    public let imageMediaType: VisionCaptureMediaType?
    /// The pixel dimensions of the image **as encoded**, which since SONNY-114 may be smaller than
    /// the capture's own when the ladder had to resample to fit the byte budget.
    ///
    /// This is the coordinate space the model is told about and the space every coordinate it
    /// returns lives in — see ``VisionPointResolver/resolve(imagePoint:sentImageSize:capture:freshFrame:ownWindowFrames:)``.
    public let imagePixelWidth: Int?
    public let imagePixelHeight: Int?
    public let sourceBundleIdentifier: String?
    public let report: [RedactionReportEntry]
    /// Whether the text this payload was built from came off a shell (SONNY-139).
    ///
    /// **Produced here so the text it was read from stays here.** The recognized screen text is the
    /// most sensitive thing this service touches and it never leaves the type; what leaves is a
    /// closed vocabulary of at most six signal names. That is row I's most expensive lesson applied
    /// in advance: a structural guarantee is only as wide as the type that carries it, and F5's fix
    /// was correct for the one parameter it constrained while the same class of text left by two
    /// other doors that took plain `String`s.
    ///
    /// **Non-optional, never defaulted, and there is deliberately no "could not tell" case.** An
    /// `Optional` here — or a third enum state — would be permission granted by omission: a `nil`
    /// that a reader treats as "no shell" is exactly the answer an unreadable screen must not
    /// produce. The unreadable case is already handled a level up and it throws:
    /// ``LocalRedactionError/detectionUnavailable(_:)`` means no payload exists at all.
    ///
    /// Every producer in this file fills it from ``ShellSurfaceDetector`` over the text it actually
    /// had, so the field is a true statement about *this* payload rather than a capture-only
    /// special case with an inert value on the other path. Which payload's verdict is acted on is
    /// the runner's decision, not this type's: ``VisionSessionRunner`` reads the one built from the
    /// capture it is about to act inside.
    public let shellSurface: ShellSurfaceVerdict

    fileprivate init(
        maskedText: String?,
        redactedImageData: Data?,
        imageMediaType: VisionCaptureMediaType?,
        imagePixelWidth: Int?,
        imagePixelHeight: Int?,
        sourceBundleIdentifier: String?,
        report: [RedactionReportEntry],
        shellSurface: ShellSurfaceVerdict
    ) {
        self.maskedText = maskedText
        self.redactedImageData = redactedImageData
        self.imageMediaType = imageMediaType
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.report = report
        self.shellSurface = shellSurface
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
    private let egressPolicy: VisionCaptureEgressPolicy

    public init(
        textRecognizer: any ImageTextRecognizing = VisionImageTextRecognizer(),
        confidenceThreshold: Double = LocalRedactionService.defaultConfidenceThreshold,
        egressPolicy: VisionCaptureEgressPolicy = .default
    ) {
        self.textRecognizer = textRecognizer
        self.confidenceThreshold = confidenceThreshold
        self.egressPolicy = egressPolicy
    }

    public func redactText(_ text: String) -> RedactedPayload {
        let matches = detector.matches(in: text)
        let masked = SecretTextDetector.mask(matches: matches, in: text)
        return RedactedPayload(
            maskedText: masked,
            redactedImageData: nil,
            imageMediaType: nil,
            imagePixelWidth: nil,
            imagePixelHeight: nil,
            sourceBundleIdentifier: nil,
            report: report(from: matches, category: .text),
            // Over the text as given, not the masked form: masking replaces a secret with bullets
            // and would erase nothing a shell signal reads, but the verdict should describe what was
            // actually looked at.
            shellSurface: ShellSurfaceDetector.verdict(for: text)
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

        // Detect over the observations' text as ONE document, never line by line (PR #49 F1):
        // Vision returns one observation per rendered line, and a per-line scan let a
        // BEGIN→END private-key block match only on its BEGIN line — the key's body lines
        // shipped unpainted while the report claimed a confidence-1.0 redaction. Joining with
        // newlines keeps every single-line match working, lets block and context patterns span
        // lines, and cannot under-match relative to per-line scanning.
        var joinedText = ""
        var lineRanges: [Range<String.Index>] = []
        for (index, observation) in observations.enumerated() {
            if index > 0 {
                joinedText += "\n"
            }
            let start = joinedText.endIndex
            joinedText += observation.string
            lineRanges.append(start..<joinedText.endIndex)
        }

        let matches = detector.matches(in: joinedText)
        var regions: [CGRect] = []
        var paintedObservations: Set<Int> = []
        for match in matches {
            // Every observation the match touches is painted whole — the cheap over-redaction
            // side of §12.3's tradeoff, with a small pad for the anti-aliased edges the
            // recognizer's box can clip. A match always overlaps at least one line range (the
            // joined text is nothing but line ranges and separators), so a reported match is a
            // painted match by construction — the report cannot claim work that did not happen.
            for (index, lineRange) in lineRanges.enumerated() where lineRange.overlaps(match.range) {
                if paintedObservations.insert(index).inserted {
                    regions.append(observations[index].boundingBox.insetBy(dx: -2, dy: -2))
                }
            }
        }

        // **One path, painted then encoded, whether or not anything was found.** A clean capture
        // used to short-circuit straight to `capture.pngData`, which meant the bytes that left the
        // device were whatever ScreenCaptureKit happened to produce — full-resolution PNG, the
        // ~12 MB request SONNY-114 was filed about. It also meant the encoding a capture shipped in
        // depended on whether it contained a secret, which is not a property anything should depend
        // on. `render(paintingRegions:…)` takes an empty region list perfectly well.
        let encodedImage: EncodedVisionCapture
        do {
            encodedImage = try RedactedCaptureEncoder.render(
                paintingRegions: regions,
                inPNGData: capture.pngData,
                policy: egressPolicy
            )
        } catch let error as LocalRedactionError {
            // Already the encoder's own typed failure — rethrow rather than wrapping the
            // wording inside itself.
            throw error
        } catch {
            // Fail closed again: pixels that could not be painted out are pixels that
            // do not leave the device.
            throw LocalRedactionError.imageRedactionFailed(String(describing: error))
        }

        return RedactedPayload(
            maskedText: nil,
            redactedImageData: encodedImage.data,
            imageMediaType: encodedImage.mediaType,
            imagePixelWidth: encodedImage.pixelWidth,
            imagePixelHeight: encodedImage.pixelHeight,
            sourceBundleIdentifier: capture.bundleIdentifier,
            report: report(from: matches, category: .imageRegion),
            // **The shell verdict, from the observations already in hand** (SONNY-139). No second
            // OCR pass, no new network call, no new model call and no new permission — the
            // recognition above already ran, and `joinedText` is already in memory. It reads the
            // joined document rather than the observations one at a time, for the reason the
            // detector above it does.
            shellSurface: ShellSurfaceDetector.verdict(for: joinedText)
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
