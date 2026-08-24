import CoreGraphics
import Foundation
import ImageIO
@testable import MacAgentCore

/// SONNY-272, half two: the instrument that measures what lowering `SecretTextDetector`'s
/// high-entropy floor from 32 alphanumerics to 28 would paint, **without lowering it**.
///
/// The founder's decision of 2026-08-24 is that the floor moves only on a measured false-positive
/// rate on real captures, at 32 and at 28, and never in the same change that measures it. So the
/// product keeps its `{32,}` literal untouched, and this carries the blob rule a second time with the
/// floor as a parameter — the one deliberate copy of that rule in the repository, and
/// `HighEntropyFloorMeasurementTests` holds it to the product at 32 so the copy cannot drift from
/// what it claims to measure.
///
/// **What is counted, and why lines.** `LocalRedactionService.redactCapture` paints every observation
/// a match touches, whole, so the cost of a floor is not tokens but *lines a user can no longer
/// see*, and beyond that *captures with any line gone*. Each capture reports the lines painted at the
/// product floor — every class, the product detector as shipped — and the lines painted once the
/// tokens the candidate floor adds are painted too. Nothing in the corpora this measures is a secret,
/// so every painted line is a false positive by construction; a real capture the founder points this
/// at may hold real secrets, which is why the per-class counts at 32 are printed beside the rest.
///
/// **What is never printed.** Not one token, not one line of recognized text — lengths, counts and
/// file names only. The founder's captures are the founder's screen, and a log line gets pasted into
/// a ticket.
enum HighEntropyFloorMeasurement {
    /// The floor the product ships with — `SecretTextDetector.apiKeyMatches(in:)`'s `{32,}`.
    static let productFloor = 32
    /// The floor SONNY-272 asks about: it would have caught the measured key's 30-character body.
    static let candidateFloor = 28

    /// `SONNY_CAPTURE_CORPUS`, a folder of PNG captures, when the founder has set it.
    static var captureCorpusDirectory: URL? {
        ProcessInfo.processInfo.environment["SONNY_CAPTURE_CORPUS"].map { URL(fileURLWithPath: $0) }
    }

    /// The high-entropy blob rule with the floor as a parameter: a run of `floor` or more
    /// alphanumerics on word boundaries carrying a digit, a lowercase and an uppercase letter.
    static func blobRanges(in text: String, floor: Int) throws -> [Range<String.Index>] {
        let blob = try Regex("\\b[A-Za-z0-9]{\(floor),}\\b")
        return text.matches(of: blob).compactMap { match in
            let candidate = text[match.range]
            let hasDigit = candidate.contains { $0.isNumber }
            let hasLower = candidate.contains { $0.isLowercase }
            let hasUpper = candidate.contains { $0.isUppercase }
            return hasDigit && hasLower && hasUpper ? match.range : nil
        }
    }

    /// One capture's cost at both floors.
    struct CaptureCost: Equatable {
        var lines: Int
        var paintedAtProductFloor: Int
        var paintedAtCandidateFloor: Int
        /// Scalar lengths of the tokens only the candidate floor paints — by construction between
        /// `candidateFloor` and `productFloor - 1`, except where a longer run sits inside a token the
        /// product already paints for another reason, which is not an extra and is not listed.
        var extraTokenLengths: [Int]
        var classesAtProductFloor: [SecretDetectionClass: Int]
        /// Every blob the probe finds at the product floor overlaps a product match. False means the
        /// copy of the rule above has drifted from the product's, and the numbers beside it are not
        /// a measurement of anything.
        var probeAgreesWithProduct: Bool

        /// One log line, content-free.
        func line(name: String) -> String {
            let classes = classesAtProductFloor
                .map { "\($0.key.rawValue):\($0.value)" }
                .sorted()
                .joined(separator: ",")
            return "HIGH-ENTROPY-FLOOR capture=\(name) lines=\(lines) painted@\(productFloor)=\(paintedAtProductFloor) painted@\(candidateFloor)=\(paintedAtCandidateFloor) extra\(candidateFloor)=\(extraTokenLengths) classes@\(productFloor)=[\(classes)] probeAgrees=\(probeAgreesWithProduct)"
        }
    }

    /// The cost of one capture, from its recognized lines, joined with newlines exactly as
    /// `redactCapture` joins them so that cross-line matches and word boundaries behave identically.
    static func cost(ofLines lines: [String]) throws -> CaptureCost {
        var joined = ""
        var lineRanges: [Range<String.Index>] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                joined += "\n"
            }
            let start = joined.endIndex
            joined += line
            lineRanges.append(start..<joined.endIndex)
        }

        let product = SecretTextDetector().matches(in: joined)

        // The product matches over look-alike-folded text, so the probe does too, and carries its
        // ranges back the same way.
        let folded = LatinConfusables.fold(joined)
        let probeAtProduct = try blobRanges(in: folded.text, floor: productFloor).map(folded.originalRange(of:))
        let probeAtCandidate = try blobRanges(in: folded.text, floor: candidateFloor).map(folded.originalRange(of:))
        let agrees = probeAtProduct.allSatisfy { probed in product.contains { $0.range.overlaps(probed) } }

        let extras = probeAtCandidate.filter { probed in !product.contains { $0.range.overlaps(probed) } }
        let extraLengths = extras.map { joined[$0].unicodeScalars.count }

        func paintedLines(_ ranges: [Range<String.Index>]) -> Int {
            lineRanges.filter { lineRange in ranges.contains { $0.overlaps(lineRange) } }.count
        }
        let productRanges = product.map(\.range)

        return CaptureCost(
            lines: lines.count,
            paintedAtProductFloor: paintedLines(productRanges),
            paintedAtCandidateFloor: paintedLines(productRanges + extras),
            extraTokenLengths: extraLengths,
            classesAtProductFloor: Dictionary(grouping: product, by: \.detectionClass).mapValues(\.count),
            probeAgreesWithProduct: agrees
        )
    }

    static func cost(of observations: [RecognizedTextObservation]) throws -> CaptureCost {
        try cost(ofLines: observations.map(\.string))
    }

    /// A corpus's totals, accumulated one capture at a time.
    struct Totals: Equatable {
        var captures = 0
        var lines = 0
        var paintedAtProductFloor = 0
        var paintedAtCandidateFloor = 0
        var capturesTouchedAtProductFloor = 0
        var capturesTouchedAtCandidateFloor = 0
        var extraTokensByLength: [Int: Int] = [:]
        var classesAtProductFloor: [SecretDetectionClass: Int] = [:]
        var disagreements = 0

        mutating func add(_ cost: CaptureCost) {
            captures += 1
            lines += cost.lines
            paintedAtProductFloor += cost.paintedAtProductFloor
            paintedAtCandidateFloor += cost.paintedAtCandidateFloor
            if cost.paintedAtProductFloor > 0 { capturesTouchedAtProductFloor += 1 }
            if cost.paintedAtCandidateFloor > 0 { capturesTouchedAtCandidateFloor += 1 }
            for length in cost.extraTokenLengths {
                extraTokensByLength[length, default: 0] += 1
            }
            for (detectionClass, count) in cost.classesAtProductFloor {
                classesAtProductFloor[detectionClass, default: 0] += count
            }
            if !cost.probeAgreesWithProduct { disagreements += 1 }
        }

        func summary(label: String) -> String {
            let lengths = extraTokensByLength.keys.sorted().map { "\($0):\(extraTokensByLength[$0]!)" }.joined(separator: ",")
            let classes = classesAtProductFloor.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ",")
            let extraTokens = extraTokensByLength.values.reduce(0, +)
            return "HIGH-ENTROPY-FLOOR-TOTALS \(label): captures=\(captures) lines=\(lines) painted@\(productFloor)=\(paintedAtProductFloor) (\(capturesTouchedAtProductFloor) captures) painted@\(candidateFloor)=\(paintedAtCandidateFloor) (\(capturesTouchedAtCandidateFloor) captures) extra\(candidateFloor)-tokens=\(extraTokens) by-length={\(lengths)} classes@\(productFloor)=[\(classes)] disagreements=\(disagreements)"
        }
    }

    // MARK: - PNG captures on disk

    /// Every `.png` directly inside `directory`, sorted by name.
    static func pngCaptures(in directory: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    struct UndecodableCapture: Error {
        var url: URL
    }

    /// The file's bytes and its pixel size, which `ImageTextRecognizing` takes beside the data.
    static func pngPixels(at url: URL) throws -> (data: Data, width: Int, height: Int) {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw UndecodableCapture(url: url)
        }
        return (data, image.width, image.height)
    }
}
