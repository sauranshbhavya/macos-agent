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

    /// The default sent size: the capture's own pixels, which is what the egress encoder produces
    /// for every capture that fits its byte budget — every real capture measured for SONNY-114.
    /// The tests that care about the two *differing* build their own.
    private static func sentSize(
        _ capture: CapturedWindowImage
    ) -> SentImageSize {
        SentImageSize(pixelWidth: capture.pixelWidth, pixelHeight: capture.pixelHeight)
    }

    /// The ordinary case: image point plus the window's live origin.
    @Test
    func anImagePointResolvesThroughTheWindowsLiveOrigin() {
        let capture = Self.capture()
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 200, y: 300),
            sentImageSize: Self.sentSize(capture),
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
            sentImageSize: Self.sentSize(capture),
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
            sentImageSize: Self.sentSize(capture),
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
            sentImageSize: Self.sentSize(capture),
            capture: capture,
            freshFrame: rounded,
            ownWindowFrames: []
        ) {} else {
            Issue.record("a change within the tolerance must still resolve")
        }

        let justOver = CGRect(x: 100, y: 50, width: 800 + VisionPointResolver.resizeTolerance + 0.5, height: 600)
        if case .windowResized = VisionPointResolver.resolve(
            imagePoint: .zero,
            sentImageSize: Self.sentSize(capture),
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
                sentImageSize: Self.sentSize(Self.capture()),
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
            sentImageSize: Self.sentSize(capture),
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
            sentImageSize: Self.sentSize(capture),
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
                sentImageSize: Self.sentSize(capture),
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
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 0, y: 0), sentImageSize: Self.sentSize(capture)))
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 799, y: 599), sentImageSize: Self.sentSize(capture)))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 800, y: 599), sentImageSize: Self.sentSize(capture)))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 799, y: 600), sentImageSize: Self.sentSize(capture)))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: -1, y: 10), sentImageSize: Self.sentSize(capture)))
    }

    // MARK: - SONNY-114: the sent image, not the capture

    /// **The scale comes from the image the model saw, and this test is the difference between a
    /// working click and one off by the resample factor.**
    ///
    /// The egress ladder resamples a capture that will not fit the request budget, so the model is
    /// shown — and names coordinates in — a smaller grid than ScreenCaptureKit produced. Here the
    /// capture is 800x600 pixels over an 800x600-point window while the sent image is 400x300: the
    /// model's (200, 150) is the middle of what it saw, which is the middle of the window, which is
    /// (500, 350) on screen. Scaling by the capture's own pixel count instead would land at
    /// (300, 200) — inside the window, plausible-looking, and wrong.
    @Test
    func theResolverScalesByTheSentImageRatherThanTheCapture() {
        let capture = Self.capture()
        let outcome = VisionPointResolver.resolve(
            imagePoint: CGPoint(x: 200, y: 150),
            sentImageSize: SentImageSize(pixelWidth: 400, pixelHeight: 300),
            capture: capture,
            freshFrame: capture.windowFrame,
            ownWindowFrames: []
        )
        #expect(outcome == .posted(globalPoint: CGPoint(x: 500, y: 350)))
    }

    /// Bounds are the sent image's too: the model was told those dimensions and answered inside
    /// them, so checking its answer against the capture's would be checking a claim nobody made —
    /// and would let a point past the edge of the picture the model actually saw.
    @Test
    func boundsCheckingFollowsTheSentImageNotTheCapture() {
        let capture = Self.capture()
        let sent = SentImageSize(pixelWidth: 400, pixelHeight: 300)
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 399, y: 299), sentImageSize: sent))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 400, y: 150), sentImageSize: sent))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 200, y: 300), sentImageSize: sent))
    }

    /// **What a resample costs a click, bounded exactly.**
    ///
    /// The model can only name whole pixels, and a named pixel resolves to that pixel's leading edge
    /// rather than its centre, so the resolved point lands short of the true target by strictly less
    /// than one sent pixel — `windowWidth / sentPixelWidth` points. Swept over every rung of the
    /// shipping ladder and a grid of targets across a 1440-point window: at most one point at full
    /// resolution and at most two at the 0.5 floor. A macOS control is at least 20 points
    /// on its short edge and the model is told to aim at the middle of the glyphs, so nothing here
    /// can move a click off its target.
    ///
    /// This bounds the arithmetic only. Whether a *model* aims as well at a smaller picture is not
    /// something a test can answer and is the founder's attended run.
    @Test
    func theResolvedPointStaysWithinOneSentPixelOfTheModelsTargetAtEveryLadderScale() {
        let windowWidth: CGFloat = 1_440
        let windowHeight: CGFloat = 900
        let frame = CGRect(x: 120, y: 64, width: windowWidth, height: windowHeight)

        for rung in VisionCaptureEgressPolicy.default.ladder {
            let sentWidth = Int((Double(windowWidth) * rung.scale).rounded())
            let sentHeight = Int((Double(windowHeight) * rung.scale).rounded())
            let sent = SentImageSize(pixelWidth: sentWidth, pixelHeight: sentHeight)
            let capture = Self.capture(
                pixels: CGSize(width: windowWidth, height: windowHeight),
                frame: frame
            )
            let onePixelInPoints = windowWidth / CGFloat(sentWidth)

            // Sweep targets across the window, in points, as the model's true aim. Half-open: a
            // target at the window's outer edge is not a point inside the window, and the model is
            // told `0 <= x < width` for exactly that reason.
            for step in 0..<144 {
                let targetX = windowWidth * CGFloat(step) / 144
                let targetY = windowHeight * CGFloat(step) / 144
                // The best a model can do: name the sent pixel the target falls inside.
                let namedX = min(sentWidth - 1, Int(targetX / windowWidth * CGFloat(sentWidth)))
                let namedY = min(sentHeight - 1, Int(targetY / windowHeight * CGFloat(sentHeight)))

                guard case .posted(let resolved) = VisionPointResolver.resolve(
                    imagePoint: CGPoint(x: namedX, y: namedY),
                    sentImageSize: sent,
                    capture: capture,
                    freshFrame: frame,
                    ownWindowFrames: []
                ) else {
                    Issue.record("a point inside the window must resolve at scale \(rung.scale)")
                    continue
                }
                let errorX = abs((frame.origin.x + targetX) - resolved.x)
                let errorY = abs((frame.origin.y + targetY) - resolved.y)
                #expect(errorX <= onePixelInPoints, "x error at scale \(rung.scale), target \(targetX)")
                #expect(errorY <= windowHeight / CGFloat(sentHeight), "y error at scale \(rung.scale)")
                // The absolute statement, independent of the rung: never more than two points.
                #expect(errorX <= 2 && errorY <= 2, "displacement at scale \(rung.scale)")
            }
        }
    }
}

/// SONNY-92: the mouse-up guarantee, at the synthesis seam.
///
/// The ticket asks for this as a *tested contract* rather than a habit, and no test in this repo may
/// post a real HID event — so `ClickEventSequence` is a pure function over an injected poster and an
/// injected sleep, and this is what that extraction is for.
@Suite
struct ClickEventSequenceTests {
    private final class Recorder: @unchecked Sendable {
        private(set) var posted: [CGEventType] = []
        func post(_ type: CGEventType) { posted.append(type) }
    }

    /// The ordinary sequence: move, down, up.
    @Test
    func anUninterruptedClickPostsMoveDownAndUp() async throws {
        let recorder = Recorder()
        try await ClickEventSequence.run(post: recorder.post, sleep: { _ in })
        #expect(recorder.posted == [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    /// **The guarantee.** A cancellation landing inside the hold still releases the button before it
    /// propagates. Without this the user is left with a machine that drags everything it touches,
    /// from a run they just stopped — and the run they stopped is exactly when this happens.
    @Test
    func aCancellationDuringTheHoldStillReleasesTheButton() async {
        let recorder = Recorder()
        do {
            try await ClickEventSequence.run(
                post: recorder.post,
                // Throws only on the hold, not on the move settle, so the cancellation lands in the
                // one window where the button is actually down.
                sleep: { nanoseconds in
                    if nanoseconds == ClickEventSequence.holdNanoseconds {
                        throw CancellationError()
                    }
                }
            )
            Issue.record("the cancellation must propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }

        #expect(recorder.posted == [.mouseMoved, .leftMouseDown, .leftMouseUp])
        #expect(recorder.posted.last == .leftMouseUp, "the button must never be left down")
    }

    /// A cancellation *before* the button goes down posts no up event, because there is nothing
    /// held. Pinned so the fix stays targeted rather than becoming an unconditional extra event.
    @Test
    func aCancellationBeforeTheButtonGoesDownPostsNoUpEvent() async {
        let recorder = Recorder()
        try? await ClickEventSequence.run(
            post: recorder.post,
            sleep: { _ in throw CancellationError() }
        )
        #expect(recorder.posted == [.mouseMoved])
    }
}
