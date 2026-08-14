import CoreGraphics
import Foundation
import ImageIO
import Vision

/// On-device OCR via the Vision framework — internal machinery for redaction detection, not a
/// user-facing OCR feature (that stays a row-14 residual).
public struct VisionImageTextRecognizer: ImageTextRecognizing {
    public init() {}

    public func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LocalRedactionError.detectionUnavailable("the capture data is not a decodable image")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Language correction would "fix" token-shaped strings into dictionary words before the
        // detector ever sees them — exactly the strings this recognizer exists to find.
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision boxes are normalized with a bottom-left origin; the redaction pipeline
            // works in pixel-space top-left, so flip Y here — in exactly one place.
            let box = observation.boundingBox
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height,
                width: box.width * width,
                height: box.height * height
            )
            return RecognizedTextObservation(string: candidate.string, boundingBox: rect)
        }
    }
}
