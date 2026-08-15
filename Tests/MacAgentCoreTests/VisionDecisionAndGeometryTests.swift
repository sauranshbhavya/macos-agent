import CoreGraphics
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-92: parsing a model reply, and turning a point in a screenshot into a point on the screen.
///
/// Two things a run's correctness rests on that can be tested exhaustively with no machine at all,
/// which is why they are pure values and not methods on the loop.
@Suite
struct VisionDecisionAndGeometryTests {
    // MARK: - Parsing: lenient about packaging, strict about content

    /// Models fence their JSON, apologize before it, and add a sentence after. None of that is an
    /// attack and none of it should end a run.
    @Test
    func packagingAroundTheJSONIsTolerated() throws {
        let variants = [
            #"{"action":"click","x":10,"y":20,"target":"OK","rationale":"r"}"#,
            "```json\n{\"action\":\"click\",\"x\":10,\"y\":20,\"target\":\"OK\"}\n```",
            "Here is the next action:\n{\"action\":\"click\",\"x\":10,\"y\":20,\"target\":\"OK\"}\nHope that helps.",
            "  \n{\"action\":\"click\",\"x\":\"10\",\"y\":20.0,\"target\":\"OK\"}\n  "
        ]
        for variant in variants {
            let decision = try VisionDecisionParser.decision(from: variant)
            #expect(decision.kind == .click, "\(variant.prefix(30))")
            #expect(decision.x == 10, "\(variant.prefix(30))")
            #expect(decision.y == 20, "\(variant.prefix(30))")
        }
    }

    /// **Strict about content.** An action Sonny does not have is a model asking for a capability it
    /// was never given, and it throws rather than degrading into something adjacent.
    @Test
    func anUnknownActionThrowsRatherThanDegrading() {
        #expect(throws: VisionDecisionParseError.unknownAction("run_shell")) {
            _ = try VisionDecisionParser.decision(from: #"{"action":"run_shell","command":"rm -rf /"}"#)
        }
        #expect(throws: VisionDecisionParseError.unknownAction("<missing>")) {
            _ = try VisionDecisionParser.decision(from: #"{"x":1,"y":2}"#)
        }
    }

    /// Each action that needs a field is rejected without it, rather than acting on a default.
    @Test
    func everyActionMissingItsRequiredFieldThrows() {
        let cases: [(String, String)] = [
            (#"{"action":"click","target":"OK"}"#, "coordinates"),
            (#"{"action":"type","target":"field"}"#, "text"),
            (#"{"action":"type","text":"","target":"field"}"#, "text"),
            (#"{"action":"key","target":""}"#, "key"),
            (#"{"action":"key","key":"f13","target":""}"#, "key"),
            (#"{"action":"scroll","target":""}"#, "direction")
        ]
        for (reply, field) in cases {
            #expect(throws: (any Error).self, "\(reply)") {
                _ = try VisionDecisionParser.decision(from: reply)
            }
            _ = field
        }
    }

    /// The terminal actions need nothing but their name.
    @Test
    func doneStuckAndWaitParseWithNoExtraFields() throws {
        for kind in [VisionActionKind.done, .stuck, .wait] {
            let decision = try VisionDecisionParser.decision(
                from: "{\"action\":\"\(kind.rawValue)\",\"rationale\":\"because\"}"
            )
            #expect(decision.kind == kind)
            #expect(decision.rationale == "because")
        }
    }

    /// **An unrecognized consequence string is "the model said nothing usable", not "harmless".**
    /// The two are very different, and a typo must never be able to assert the second on the model's
    /// behalf.
    @Test
    func anUnrecognizedConsequenceStringIsAbsentRatherThanAdvisory() throws {
        let unrecognized = try VisionDecisionParser.decision(
            from: #"{"action":"click","x":1,"y":1,"target":"OK","consequence":"probably-fine"}"#
        )
        #expect(unrecognized.declaredConsequence == nil)

        let absent = try VisionDecisionParser.decision(
            from: #"{"action":"click","x":1,"y":1,"target":"OK"}"#
        )
        #expect(absent.declaredConsequence == nil)

        for (raw, expected) in [
            ("destructive", CapabilityRiskEscalation.Consequence.destructive),
            ("affects_others", .affectsOthers),
            ("external", .affectsOthers),
            ("ordinary", .advisory),
            ("DESTRUCTIVE", .destructive)
        ] {
            let parsed = try VisionDecisionParser.decision(
                from: "{\"action\":\"click\",\"x\":1,\"y\":1,\"target\":\"OK\",\"consequence\":\"\(raw)\"}"
            )
            #expect(parsed.declaredConsequence == expected, "\(raw)")
        }
    }

    /// Typed text is shown to the user in a bounded prefix — it can be long, and it can be a secret
    /// the user is pasting.
    @Test
    func theTypedTextShownOnAnApprovalIsBounded() {
        let long = String(repeating: "a", count: 500)
        let description = VisionDecision(kind: .type, text: long).actionDescription
        #expect(description.count < 120)
        #expect(description.contains("\u{2026}"))

        // A newline would break the one-line approval row, so it renders as a return symbol.
        let multiline = VisionDecision(kind: .type, text: "line one\nline two").actionDescription
        #expect(!multiline.contains("\n"))
    }

    // MARK: - Geometry

    private static func capture(
        pixels: CGSize = CGSize(width: 800, height: 600),
        frame: CGRect = CGRect(x: 100, y: 50, width: 800, height: 600)
    ) -> CapturedWindowImage {
        CapturedWindowImage(
            pngData: Data(),
            pixelWidth: Int(pixels.width),
            pixelHeight: Int(pixels.height),
            bundleIdentifier: "com.example.App",
            windowTitle: "W",
            windowID: 7,
            windowFrame: frame
        )
    }

    /// The ordinary case: image point plus the window's live origin.
    @Test
    func anImagePointResolvesThroughTheWindowsLiveOrigin() {
        let capture = Self.capture()
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 200, y: 300),
            capture: capture,
            freshFrame: capture.windowFrame,
            ownWindowFrames: []
        )
        #expect(outcome == .posted(globalPoint: CGPoint(x: 300, y: 350)))
    }

    /// **A window that merely moved keeps the model's point valid**, so the click goes through — at
    /// the new origin. This is why the fresh frame is read at all rather than the capture-time one
    /// being reused.
    @Test
    func aWindowThatMovedResolvesAtItsNewOriginRatherThanBeingRefused() {
        let capture = Self.capture()
        let moved = CGRect(x: 500, y: 400, width: 800, height: 600)
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 10, y: 20),
            capture: capture,
            freshFrame: moved,
            ownWindowFrames: []
        )
        #expect(outcome == .posted(globalPoint: CGPoint(x: 510, y: 420)))
    }

    /// **A window that resized has reflowed its content under the model**, so the point no longer
    /// names the control it was aiming at. That click would be a lie, and it is refused for a
    /// recapture instead.
    @Test
    func aWindowThatResizedIsRefusedForARecapture() {
        let capture = Self.capture()
        let resized = CGRect(x: 100, y: 50, width: 900, height: 600)
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 10, y: 20),
            capture: capture,
            freshFrame: resized,
            ownWindowFrames: []
        )
        #expect(outcome == .windowResized(from: CGSize(width: 800, height: 600), to: CGSize(width: 900, height: 600)))
    }

    /// Sub-point rounding is absorbed; a real resize is not. The tolerance is a boundary worth
    /// pinning on both sides rather than trusting the constant.
    @Test
    func theResizeToleranceAbsorbsRoundingButNotARealResize() {
        let capture = Self.capture()
        let rounded = CGRect(x: 100, y: 50, width: 800 + VisionPointResolver.resizeTolerance, height: 600)
        if case .posted = VisionPointResolver.resolve(
            imagePoint: .zero,
            capture: capture,
            freshFrame: rounded,
            ownWindowFrames: []
        ) {} else {
            Issue.record("a change within the tolerance must still resolve")
        }

        let justOver = CGRect(x: 100, y: 50, width: 800 + VisionPointResolver.resizeTolerance + 0.5, height: 600)
        if case .windowResized = VisionPointResolver.resolve(
            imagePoint: .zero,
            capture: capture,
            freshFrame: justOver,
            ownWindowFrames: []
        ) {} else {
            Issue.record("a change past the tolerance must refuse")
        }
    }

    @Test
    func aVanishedWindowIsRefused() {
        #expect(
            VisionPointResolver.resolve(
                imagePoint: .zero,
                capture: Self.capture(),
                freshFrame: nil,
                ownWindowFrames: []
            ) == .windowDisappeared
        )
    }

    /// **Own-window suppression.** A click landing inside one of Sonny's own windows would be Sonny
    /// operating its own UI — in the worst case, its own approval buttons. Refused, always.
    @Test
    func aClickLandingInsideSonnysOwnWindowIsSuppressed() {
        let capture = Self.capture()
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 200, y: 300),
            capture: capture,
            freshFrame: capture.windowFrame,
            ownWindowFrames: [CGRect(x: 250, y: 300, width: 200, height: 200)]
        )
        #expect(outcome == .suppressedOwnWindow(globalPoint: CGPoint(x: 300, y: 350)))
    }

    /// Retina and other scale factors: the mapping is derived per capture, so a 2x image maps
    /// correctly without anyone hardcoding a scale.
    @Test
    func aRetinaScaledCaptureMapsThroughItsOwnDerivedScale() {
        let capture = Self.capture(
            pixels: CGSize(width: 1_600, height: 1_200),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 400, y: 200),
            capture: capture,
            freshFrame: capture.windowFrame,
            ownWindowFrames: []
        )
        #expect(outcome == .posted(globalPoint: CGPoint(x: 200, y: 100)))
    }

    /// A degenerate capture cannot produce a divide-by-zero point somewhere arbitrary on screen.
    @Test
    func aZeroSizedCaptureRefusesRatherThanDividingByZero() {
        let capture = Self.capture(pixels: .zero)
        #expect(
            VisionPointResolver.resolve(
                imagePoint: CGPoint(x: 1, y: 1),
                capture: capture,
                freshFrame: capture.windowFrame,
                ownWindowFrames: []
            ) == .windowDisappeared
        )
    }

    /// Bounds checking is separate from resolution, because an out-of-bounds coordinate is a *model*
    /// error worth telling the model about, while the outcomes above are *world* changes worth
    /// telling it something different.
    @Test
    func pointsOutsideTheCapturedImageAreRejectedBeforeResolution() {
        let capture = Self.capture()
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 0, y: 0), capture: capture))
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 799, y: 599), capture: capture))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 800, y: 599), capture: capture))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 799, y: 600), capture: capture))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: -1, y: 10), capture: capture))
    }
}
