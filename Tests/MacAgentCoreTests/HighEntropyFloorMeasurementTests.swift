import Testing
@testable import MacAgentCore

/// What keeps `HighEntropyFloorMeasurement` a measurement of the product rather than of itself: the
/// probe's copy of the blob rule agrees with `SecretTextDetector` at the product floor, finds at 28
/// exactly the tokens 32 misses, and counts lines the way `redactCapture` paints them.
struct HighEntropyFloorMeasurementTests {
    private static let token27 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG"
    private static let token28 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6"
    private static let token29 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6h"
    private static let token30 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6hJ"
    private static let token31 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6hJ0"
    private static let token32 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6hJ0q"
    private static let token40 = "Zx9kQ2mP8vL4nR7tYw3eA5sD1fG6hJ0qWe4Rt6Yu"

    @Test
    func theProbeAgreesWithTheProductAtTheProductFloorInBothDirections() throws {
        let text = "one \(Self.token31) two \(Self.token32) three \(Self.token40) four \u{043E}\u{043E} \(Self.token32) lower0nly0000000000000000000000000000 UPPER0NLY0000000000000000000000000000"
        let product = SecretTextDetector().matches(in: text).filter { $0.confidence == 0.5 }
        let folded = LatinConfusables.fold(text)
        let probed = try HighEntropyFloorMeasurement.blobRanges(in: folded.text, floor: HighEntropyFloorMeasurement.productFloor)
            .map(folded.originalRange(of:))

        #expect(probed.count == 3)
        #expect(product.count == 3)
        #expect(probed.allSatisfy { range in product.contains { $0.range == range } })
        #expect(product.allSatisfy { match in probed.contains { $0 == match.range } })
    }

    @Test
    func theProbeAtTwentyEightFindsExactlyTheTokensTheProductFloorMisses() throws {
        let lines = [
            "a \(Self.token27)",
            "b \(Self.token28)",
            "c \(Self.token29)",
            "d \(Self.token30)",
            "e \(Self.token31)",
            "f \(Self.token32)",
            "g zx9kq2mp8vl4nr7tyw3ea5sd1fg6h",
            "h api_key=\(Self.token30)"
        ]
        let cost = try HighEntropyFloorMeasurement.cost(ofLines: lines)

        #expect(cost.lines == 8)
        // Line f (the 32) and line h (labeled, already painted by the label pattern).
        #expect(cost.paintedAtProductFloor == 2)
        // Plus b, c, d, e. Not a (27), not g (no uppercase), and h is not counted twice.
        #expect(cost.paintedAtCandidateFloor == 6)
        #expect(cost.extraTokenLengths == [28, 29, 30, 31])
        #expect(cost.classesAtProductFloor == [.apiKey: 2])
        #expect(cost.probeAgreesWithProduct)
    }

    /// The founder's exact motivating case: the measured key's 30-character body on its own — no
    /// label, no vendor prefix — is missed at 32 and painted at 28.
    @Test
    func theMeasuredKeyBodyIsCaughtAtTwentyEightAndNotAtThirtyTwo() throws {
        let cost = try HighEntropyFloorMeasurement.cost(ofLines: ["Abc123Def456Ghi789JklMno012Pqr"])

        #expect(cost.paintedAtProductFloor == 0)
        #expect(cost.paintedAtCandidateFloor == 1)
        #expect(cost.extraTokenLengths == [30])
        #expect(cost.classesAtProductFloor.isEmpty)
        #expect(cost.probeAgreesWithProduct)
    }

    /// Lines are counted the way `redactCapture` paints them — whole, by overlap — and a token that
    /// spans nothing but its own line paints that line only. A wider-than-ASCII line ahead of the
    /// token is the fold's mapping under test, as in the redaction tests.
    @Test
    func costCountsLinesTheWayRedactCapturePaintsThem() throws {
        let lines = [
            "\u{041F}\u{0430}\u{0440}\u{043E}\u{043B}\u{044C}",
            "artifact \(Self.token30) uploaded",
            "password: hunter2",
            "nothing here"
        ]
        let cost = try HighEntropyFloorMeasurement.cost(ofLines: lines)

        #expect(cost == HighEntropyFloorMeasurement.CaptureCost(
            lines: 4,
            paintedAtProductFloor: 1,
            paintedAtCandidateFloor: 2,
            extraTokenLengths: [30],
            classesAtProductFloor: [.passwordField: 1],
            probeAgreesWithProduct: true
        ))
        #expect(cost.line(name: "fixture.png") == "HIGH-ENTROPY-FLOOR capture=fixture.png lines=4 painted@32=1 painted@28=2 extra28=[30] classes@32=[password_field:1] probeAgrees=true")
    }

    @Test
    func totalsAccumulateAcrossCapturesAndSummariseWithoutContent() throws {
        var totals = HighEntropyFloorMeasurement.Totals()
        totals.add(try HighEntropyFloorMeasurement.cost(ofLines: ["clean", "also clean"]))
        totals.add(try HighEntropyFloorMeasurement.cost(ofLines: ["x \(Self.token28)", "y \(Self.token32)", "z \(Self.token28)"]))
        totals.add(try HighEntropyFloorMeasurement.cost(ofLines: ["Abc123Def456Ghi789JklMno012Pqr"]))

        #expect(totals.captures == 3)
        #expect(totals.lines == 6)
        #expect(totals.paintedAtProductFloor == 1)
        #expect(totals.capturesTouchedAtProductFloor == 1)
        #expect(totals.paintedAtCandidateFloor == 4)
        #expect(totals.capturesTouchedAtCandidateFloor == 2)
        #expect(totals.extraTokensByLength == [28: 2, 30: 1])
        #expect(totals.classesAtProductFloor == [.apiKey: 1])
        #expect(totals.disagreements == 0)
        #expect(totals.summary(label: "fixture") == "HIGH-ENTROPY-FLOOR-TOTALS fixture: captures=3 lines=6 painted@32=1 (1 captures) painted@28=4 (2 captures) extra28-tokens=3 by-length={28:2,30:1} classes@32=[api_key:1] disagreements=0")
    }
}
