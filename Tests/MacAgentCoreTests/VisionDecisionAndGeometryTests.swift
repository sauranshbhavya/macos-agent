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
    ///
    /// The half-point tails are the pixel *centre* (SONNY-145): scale is 1 here, so pixel (200, 300)
    /// covers the point square `[200, 201) x [300, 301)` and its centre is (200.5, 300.5).
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
        #expect(outcome == .posted(globalPoint: CGPoint(x: 300.5, y: 350.5)))
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
        #expect(outcome == .posted(globalPoint: CGPoint(x: 510.5, y: 420.5)))
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
        #expect(outcome == .suppressedOwnWindow(globalPoint: CGPoint(x: 300.5, y: 350.5)))
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
        #expect(outcome == .posted(globalPoint: CGPoint(x: 200.25, y: 100.25)))
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
    /// capture is 800x600 pixels over an 800x600-point window while the sent image is 400x300, so one
    /// sent pixel is two points. The model's (200, 150) names the pixel spanning `[200, 201)` of that
    /// smaller grid, whose centre is (200.5, 150.5) sent pixels — (401, 301) points into the window,
    /// so (501, 351) on screen.
    ///
    /// **Scaling by the capture's own pixel count instead would land at (300.5, 200.5)** — inside the
    /// window, plausible-looking, and wrong by two hundred points. That gap, not the half-pixel, is
    /// what this test is for; the half-pixel is SONNY-145's centre sampling and is why neither number
    /// is round.
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
        #expect(outcome == .posted(globalPoint: CGPoint(x: 501, y: 351)))
    }

    /// Bounds are the sent image's too: the model was told those dimensions and answered inside
    /// them, so checking its answer against the capture's would be checking a claim nobody made —
    /// and would let a point past the edge of the picture the model actually saw.
    @Test
    func boundsCheckingFollowsTheSentImageNotTheCapture() {
        let sent = SentImageSize(pixelWidth: 400, pixelHeight: 300)
        #expect(VisionPointResolver.isInsideImage(CGPoint(x: 399, y: 299), sentImageSize: sent))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 400, y: 150), sentImageSize: sent))
        #expect(!VisionPointResolver.isInsideImage(CGPoint(x: 200, y: 300), sentImageSize: sent))
    }

    /// **What a resample costs a click, bounded exactly — and in both directions** (SONNY-145).
    ///
    /// The model can only name whole pixels, and a named pixel now resolves to that pixel's *centre*
    /// rather than its leading edge, so the resolved point is within **half** a sent pixel of the
    /// model's true target: at most half a point at full resolution, one point at the ladder's 0.5
    /// floor. Before SONNY-145 it was a whole sent pixel and always in the same direction — up and to
    /// the left.
    ///
    /// **The step count is 997 because the old 144 sampled sub-pixel positions degenerately.** The
    /// distinct fractional positions a step count reaches within a sent pixel is exactly
    /// `steps / gcd(sentDimension, steps)`. Over a 1440x900 window at 144 steps:
    ///
    /// | scale | sent | x | y |
    /// |---|---|---|---|
    /// | 1.0 | 1440x900 | 1 | 4 |
    /// | 0.8 | 1152x720 | 1 | 1 |
    /// | 0.64 | 922x576 | **72** | 1 |
    /// | 0.5 | 720x450 | 1 | 8 |
    ///
    /// **Five of the eight cells reach exactly one position** — always fraction 0, a pixel boundary,
    /// which is the one input where leading-edge and centre sampling give the same answer. Only
    /// three sample more than that, and **x at 0.64 is far and away the largest at 72**: half the
    /// sweep's targets at distinct positions. That single cell is where the old sweep's ability to
    /// see this defect actually sat, which is the fact this paragraph exists to state — an earlier
    /// draft said "2 to 8 distinct positions" and missed exactly the cell that mattered (PR #69
    /// review, G1).
    ///
    /// **The table is exact rational arithmetic, deliberately.** Recomputing it in the `Double`
    /// arithmetic the test itself uses returns larger and unstable counts — 8, 129, 14 and so on —
    /// because a fraction that is mathematically 0 shows up as a scatter of values around 1e-14.
    /// That is rounding dust, not sub-pixel positions, and any count taken from it depends on how
    /// much dust the counter happens to tolerate.
    ///
    /// 997 is prime and coprime with every sent dimension here (1440, 900, 1152, 720, 922, 576,
    /// 450), so every `gcd` is 1 and every cell becomes 997.
    ///
    /// **Stated precisely, because the tempting stronger claim is false:** the old sweep was not
    /// blind. Measured — the assertions below, run against the pre-SONNY-145 mapping with the step
    /// count back at 144, still fail. What 144 bought was a test whose whole discriminating power
    /// sat in a few rung/axis pairs by arithmetic accident, one ladder change away from resting on
    /// nothing. 997 makes every rung carry its own weight.
    ///
    /// **The direction assertions are belt-and-braces, not load-bearing, and the earlier note here
    /// claimed otherwise** (PR #69 review, G3). For a constant offset `c` in sent pixels the signed
    /// residual spans `[-c, 1-c)` pixels, so requiring `|residual| <= 0.5` pixels forces `c = 0.5`
    /// exactly. **The half-pixel bound alone therefore already pins the offset**, direction
    /// included. "A bound alone cannot pin a direction" was true of the *one*-sent-pixel bound this
    /// branch replaced, and is not true of the bound that replaced it.
    ///
    /// They are kept because they are cheap, they document the intent directly, and they still have
    /// something to say about a mapping that is not a constant offset — one that is asymmetric
    /// between the axes, or varies with position. They are tracked **per axis** for that reason: fed
    /// from `signedX` alone, the claim was true of x and silent about y, and ORing y into the same
    /// two flags does not help, because x on its own still sets both. Measured both ways.
    ///
    /// **This bounds the arithmetic only.** Whether a click lands on the control the user sees is not
    /// something any test in this repository can answer — nothing here drives the real UI — and it is
    /// the founder's attended run. Whether a *model* aims as well at a smaller picture is the same
    /// kind of question and the same answer.
    @Test
    func theResolvedPointStaysWithinHalfASentPixelOfTheModelsTargetAtEveryLadderScale() {
        let windowWidth: CGFloat = 1_440
        let windowHeight: CGFloat = 900
        let frame = CGRect(x: 120, y: 64, width: windowWidth, height: windowHeight)
        let steps = 997
        // Absorbs binary rounding in the scale division only — three orders of magnitude below the
        // half-point figure being asserted, so it cannot hide a real regression.
        let epsilon: CGFloat = 0.000_001

        // Per axis, not shared. Two flags fed from `signedX` alone made the direction claim true of
        // x and silent about y; ORing y into the same two flags does not fix it either, since x on
        // its own still sets both (measured — the assertion fires zero times either way).
        var sawUndershootX = false
        var sawOvershootX = false
        var sawUndershootY = false
        var sawOvershootY = false

        for rung in VisionCaptureEgressPolicy.default.ladder {
            let sentWidth = Int((Double(windowWidth) * rung.scale).rounded())
            let sentHeight = Int((Double(windowHeight) * rung.scale).rounded())
            let sent = SentImageSize(pixelWidth: sentWidth, pixelHeight: sentHeight)
            let capture = Self.capture(
                pixels: CGSize(width: windowWidth, height: windowHeight),
                frame: frame
            )
            let halfPixelX = windowWidth / CGFloat(sentWidth) / 2
            let halfPixelY = windowHeight / CGFloat(sentHeight) / 2

            // Sweep targets across the window, in points, as the model's true aim. Half-open: a
            // target at the window's outer edge is not a point inside the window, and the model is
            // told `0 <= x < width` for exactly that reason.
            for step in 0..<steps {
                let targetX = windowWidth * CGFloat(step) / CGFloat(steps)
                let targetY = windowHeight * CGFloat(step) / CGFloat(steps)
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

                // Positive: the click landed short of the target, the old mapping's only direction.
                let signedX = (frame.origin.x + targetX) - resolved.x
                let signedY = (frame.origin.y + targetY) - resolved.y
                if signedX > epsilon { sawUndershootX = true }
                if signedX < -epsilon { sawOvershootX = true }
                if signedY > epsilon { sawUndershootY = true }
                if signedY < -epsilon { sawOvershootY = true }

                #expect(abs(signedX) <= halfPixelX + epsilon, "x error at scale \(rung.scale), target \(targetX)")
                #expect(abs(signedY) <= halfPixelY + epsilon, "y error at scale \(rung.scale)")
                // The absolute statement, independent of the rung: never more than one point.
                #expect(abs(signedX) <= 1 + epsilon && abs(signedY) <= 1 + epsilon, "displacement at scale \(rung.scale)")
            }
        }

        #expect(
            sawUndershootX && sawUndershootY,
            "some targets must sit past their pixel's centre, on both axes"
        )
        #expect(
            sawOvershootX && sawOvershootY,
            "must err in both directions on both axes — leading-edge only undershoots"
        )
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
