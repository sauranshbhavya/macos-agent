import AppKit
import Foundation
import MacAgentCore
import SwiftUI
import Testing
@testable import MacAgent

// MARK: - Hazard 1: Pause and Stop receive their own clicks, and nothing else does

/// **Real clicks, sent through the real panel, and which action each one fires** (founder decision
/// 2026-09-12 on PR #237's F1, which names SONNY-443's click sink as the hazard; PR #237's delta
/// review, N2 and N6, which is why this suite is shaped the way it is).
///
/// The first version of this suite asked `NSView.hitTest` where a click at each control's centre
/// landed. The delta review showed it answered the hosting view at *every* point — the controls,
/// the glass, and the window's empty transparent corner alike — so it proved only that no AppKit
/// layer covers the window, and could not tell a control from the space around it. Nor could it see
/// the defect that mattered most: swapping the actions behind Pause and Stop passed the whole suite.
///
/// **What this does instead, measured before it was relied on.** `RunPillControllingContent` is
/// hosted with actions that record which one fired, in a real `RunPillPanel` ordered in far off every
/// screen, and a `leftMouseDown`/`leftMouseUp` pair is sent through the panel at every point of a
/// 4 pt grid over the whole window. SwiftUI dispatches each to whatever it resolves the point to. A
/// probe before this suite was written established the two facts it rests on: **a panel that is not
/// ordered in fires nothing at any point** — which is why the old replica, never ordered in, could
/// only ever see the hosting view — and **an ordered-in panel fires a button exactly over that
/// button and nothing between two of them**. Position off-screen does not change either, so the suite
/// puts no window in front of anyone.
///
/// **What it does not establish**, said so nobody reads more into it. `NSWindow.sendEvent` delivers
/// an event to a window directly; it does not go through the window server's decision about whether
/// a first click on a window that cannot become key is delivered at all, which is what a real click
/// from another active app meets. That is the Stop and Pause rows' job at the real app.
@Suite(.serialized)
@MainActor
struct RunPillControlsReceiveClicksTests {
    @Test(arguments: [RunPillSweepCase.oneLineAction, .twoLineAction])
    func eachControlFiresOnlyItsOwnActionOverItsOwnCapsuleAndNothingFiresElsewhere(_ sweepCase: RunPillSweepCase) throws {
        let sweep = try RunPillClickSweep(sweepCase: sweepCase, overlaidWithSink: false)
        defer { sweep.tearDown() }
        let map = sweep.run()

        let expand = try #require(map.bounds(of: .expand), "no point fired Expand")
        let pause = try #require(map.bounds(of: .pause), "no point fired Pause")
        let stop = try #require(map.bounds(of: .stop), "no point fired Stop")

        // **Stop is the Stop.** Pause and Stop sit in one row, Pause first, which is the order the
        // view declares them in. So every point that fires Stop lies to the right of every point
        // that fires Pause: swap the actions behind the two capsules and the rightmost one fires
        // Pause, which fails here. The delta review's N2, pinned behaviourally.
        #expect(stop.minX > pause.maxX, "Stop fired at x \(stop.minX)…\(stop.maxX), Pause at \(pause.minX)…\(pause.maxX)")
        #expect(abs(stop.midY - pause.midY) < 3, "Pause and Stop are one row")

        // The identity row is the only thing that expands, and it sits above the controls in the
        // hosting view's top-left-origin space.
        #expect(expand.maxY < stop.minY, "Expand fired level with or below the control row")

        // **The whole capsule takes the click, not only the word.** With the padding and height
        // outside a `.plain` button, a sweep fired each control only over its label's glyphs — four
        // rows of this 4 pt grid, about 16 pt, inside a 28 pt capsule. At least six rows is a
        // clickable height the size of the capsule.
        #expect(map.rowCount(of: .pause) >= 6, "Pause took clicks on \(map.rowCount(of: .pause)) rows of a 28 pt capsule")
        #expect(map.rowCount(of: .stop) >= 6, "Stop took clicks on \(map.rowCount(of: .stop)) rows of a 28 pt capsule")

        // **Nothing fires anywhere that is not a control**: the window's transparent margin, the
        // glass beside the identity row, the step line and the hotkey line. Each is a grid point
        // the sweep clicked.
        for (name, point) in sweep.surroundings() {
            #expect(map.fired(at: point) == nil, "a click on \(name) at \(point) fired \(String(describing: map.fired(at: point)))")
        }
    }

    /// **The control, and it fires.** The same content under a plain `NSView` overlay whose default
    /// `hitTest` claims every point inside its bounds — SONNY-443's hover tracker, reproduced. No
    /// point fires anything, so the assertions above are shown able to produce the other answer
    /// rather than passing because every click fires something.
    @Test
    func aPlainOverlayOverThePillSwallowsEveryClick() throws {
        let sweep = try RunPillClickSweep(sweepCase: .oneLineAction, overlaidWithSink: true)
        defer { sweep.tearDown() }
        let map = sweep.run()

        #expect(map.bounds(of: .expand) == nil)
        #expect(map.bounds(of: .pause) == nil)
        #expect(map.bounds(of: .stop) == nil)
        #expect(map.clickCount > 1000, "the sweep did not run: \(map.clickCount) clicks")
    }
}

// MARK: - Each control's own action, at its own site

/// **Which action each control carries, read where it is bound** (PR #237's delta review, N2).
///
/// The scan this replaces counted each action once across the whole controlling pill, which a swap
/// satisfies exactly as well as the right wiring does — the shared-marker shape `CLAUDE.md` names.
/// Here every binding is sliced from its own marker and asserted alone. The sweep above holds the
/// same property behaviourally for the content view; this holds the level above it, where the view
/// model's methods are handed in, which no click on the content can reach.
@Suite
@MainActor
struct RunPillControlBindingTests {
    @Test
    func theViewModelsThreeDoorsAreHandedToTheirOwnParameters() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        let call = try MacAgentSource.region(
            of: view,
            from: "        RunPillControllingContent(",
            to: "        )"
        )
        let lines = call.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        let expand = try #require(lines.first { $0.hasPrefix("onExpand:") })
        let pause = try #require(lines.first { $0.hasPrefix("onPause:") })
        let stop = try #require(lines.first { $0.hasPrefix("onStop:") })

        #expect(expand == "onExpand: viewModel.expandWidgetFromPill,")
        #expect(pause == "onPause: viewModel.pauseVisionSession,")
        #expect(stop == "onStop: viewModel.emergencyStopVisionSession")
        #expect(MacAgentSource.count(of: "RunPillControllingContent(", inText: view) == 1)
    }

    @Test
    func eachSharedControlIsGivenItsOwnActionInTheContent() throws {
        let content = try Self.contentBody()
        #expect(MacAgentSource.count(
            of: "WidgetSessionPauseButton(appDisplayName: controlling.appDisplayName, action: onPause)",
            inText: content
        ) == 1)
        #expect(MacAgentSource.count(
            of: "WidgetSessionStopButton(appDisplayName: controlling.appDisplayName, action: onStop)",
            inText: content
        ) == 1)
        #expect(MacAgentSource.count(of: "Button(action: onExpand)", inText: content) == 1)
        // No control in the content is a bare `Button` bound to pause or stop, which is how the swap
        // the review ran was written.
        #expect(MacAgentSource.count(of: "Button(action: onPause)", inText: content) == 0)
        #expect(MacAgentSource.count(of: "Button(action: onStop)", inText: content) == 0)
    }

    /// Each shared control wears its own word and its own spoken name, read inside its own body.
    @Test
    func eachSharedControlWearsItsOwnWordAndItsOwnSpokenName() throws {
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let stop = try MacAgentSource.braceBlock(of: widget, openedBy: "struct WidgetSessionStopButton: View {")
        let pause = try MacAgentSource.braceBlock(of: widget, openedBy: "struct WidgetSessionPauseButton: View {")

        #expect(MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.stopLabel)", inText: stop) == 1)
        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.stopAccessibilityLabel(", inText: stop) == 1)
        #expect(MacAgentSource.count(of: "pause", inText: stop.lowercased()) == 0)

        #expect(MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.pauseLabel)", inText: pause) == 1)
        #expect(MacAgentSource.count(of: "ScreenControlSessionPresentation.pauseAccessibilityLabel(", inText: pause) == 1)
        #expect(MacAgentSource.count(of: "stop", inText: pause.lowercased()) == 0)
    }

    static func contentBody() throws -> String {
        try MacAgentSource.braceBlock(
            of: MacAgentSource.read("RunPillView.swift"),
            openedBy: "struct RunPillControllingContent: View {"
        )
    }
}

// MARK: - Each row of the HUD, at its own site

/// **The view is held row by row** (PR #237's delta review, N7). Three mutants passed the whole
/// suite: the hotkey line deleted from the view, F7's tooltip defect put back, and the action line's
/// font changed — the last because the old assertion looked for `.font(WidgetType.captionSmall)`
/// anywhere in the file, and the step line and hotkey line still carry it. Each is read here from a
/// region bounded by its own row's markers.
@Suite
@MainActor
struct RunPillControllingSiteTests {
    @Test
    func theActionLineWearsItsOwnFontAndLineCap() throws {
        let content = try RunPillControlBindingTests.contentBody()
        let actionLine = try MacAgentSource.region(
            of: content,
            from: "Text(controlling.currentAction)",
            to: ".frame(maxWidth: .infinity, alignment: .leading)"
        )
        #expect(MacAgentSource.count(of: "Text(controlling.currentAction)", inText: content) == 1)
        #expect(MacAgentSource.count(of: ".font(WidgetType.captionSmall)", inText: actionLine) == 1)
        #expect(MacAgentSource.count(of: ".lineLimit(RunPillView.actionLineLimit)", inText: actionLine) == 1)
        #expect(MacAgentSource.count(of: "captionMedium", inText: actionLine) == 0)
    }

    @Test
    func theHotkeyLineIsDrawnFromItsOneOwnerOnBothSurfaces() throws {
        let content = try RunPillControlBindingTests.contentBody()
        #expect(MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.hotkeyLine)", inText: content) == 1)
        // The widget's HUD draws the same owner, so the two are one sentence rather than two copies
        // that happen to agree (N8).
        let hud = try MacAgentSource.region(
            of: MacAgentSource.read("FloatingWidgetView.swift"),
            from: "private struct WidgetControllingPanel: View {",
            to: "private struct WidgetClarificationPanel: View {"
        )
        #expect(MacAgentSource.count(of: "Text(ScreenControlSessionPresentation.hotkeyLine)", inText: hud) == 1)
        #expect(MacAgentSource.count(of: "stops it from anywhere", inText: hud) == 0)
    }

    /// F7's defect lived in the view, so it is held in the view: each of the two shapes hands its
    /// tooltip the words without the instruction, at its own site.
    @Test
    func bothPillShapesHandTheirTooltipTheWordsWithoutTheInstruction() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        let compact = try MacAgentSource.braceBlock(
            of: view,
            openedBy: "    private func compactPill(_ presentation: RunPillPresentation) -> some View {"
        )
        let content = try RunPillControlBindingTests.contentBody()
        for (name, site) in [("the ordinary pill", compact), ("the controlling pill", content)] {
            #expect(MacAgentSource.count(of: ".help(presentation.tooltip)", inText: site) == 1, "\(name)")
            #expect(MacAgentSource.count(of: ".help(presentation.accessibilityLabel)", inText: site) == 0, "\(name)")
            #expect(MacAgentSource.count(of: ".accessibilityLabel(presentation.accessibilityLabel)", inText: site) == 1, "\(name)")
        }
    }

    @Test
    func theControllingPillWearsThePanelsGlassAndNotThePills() throws {
        let content = try RunPillControlBindingTests.contentBody()
        #expect(MacAgentSource.count(of: ".widgetGlassPanel()", inText: content) == 1)
        #expect(MacAgentSource.count(of: ".widgetGlassPill()", inText: content) == 0)
    }
}

// MARK: - Hazard 2: the action line is readable at the pill's real width (SONNY-441's instrument)

/// **Measured with AppKit's own text layout, not by eye** (founder decision 2026-09-12, naming PR
/// #228/SONNY-441's measurement as the instrument to use here).
///
/// `RunPillPresentation.actionLimit` is a character budget, and a character count is a proxy for a
/// width in points. This lays the budget out at the controlling pill's real width, in the real font
/// the action line uses, through TextKit — the same instrument that measured the widget's Finder
/// sentence — and asserts it fits the lines the view allows. The font is read at the action line's
/// own site in `RunPillControllingSiteTests`, not by looking for the token anywhere in the file.
///
/// TextKit's line fragments are an estimate of SwiftUI's layout rather than a screenshot; the
/// founders' own row is what looks at the shipped pixels.
@Suite
@MainActor
struct RunPillControllingLayoutTests {
    private static let pointSize: CGFloat = 10

    private static var textWidth: CGFloat {
        RunPillView.controllingWidth - 2 * RunPillView.horizontalPadding
    }

    private static func lines(of text: String) -> Int {
        let storage = NSTextStorage(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: pointSize, weight: .medium)]
        )
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        var count = 0
        var glyph = 0
        while glyph < layout.numberOfGlyphs {
            var range = NSRange()
            _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            glyph = NSMaxRange(range)
            count += 1
        }
        return count
    }

    /// The numbers below are the pill that ships, read from its source and from the theme.
    @Test
    func theMeasurementReadsThePillThatShips() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        #expect(view.contains("static let controllingWidth: CGFloat = 340"))
        #expect(view.contains("static let horizontalPadding: CGFloat = 14"))
        #expect(view.contains("static let actionLineLimit = 2"))
        let theme = try MacAgentSource.read("SonnyWidgetTheme.swift")
        #expect(theme.contains("static let captionSmall = Font.system(size: \(Int(Self.pointSize)), weight: mediumWeight, design: .default)"))
        #expect(RunPillView.controllingWidth == 340)
        #expect(RunPillView.actionLineLimit == 2)
    }

    /// A budget-length line of the widest shape the limit allows, and real action sentences the
    /// session writes: each lays out within the two lines the view gives it.
    @Test
    func theActionBudgetFitsTheTwoLinesTheViewAllows() {
        let widest = String(repeating: "M", count: RunPillPresentation.actionLimit)
        #expect(
            Self.lines(of: widest) <= RunPillView.actionLineLimit,
            "\(RunPillPresentation.actionLimit) of the widest Latin glyph runs \(Self.lines(of: widest)) lines"
        )

        let sentences = [
            "Clicking the New Note button",
            "Typing the line into the note body",
            "Looking at the screen to find the compose field",
            "Scrolling the document to reach the paragraph that mentions invoices",
        ]
        for sentence in sentences {
            let trimmed = RunPillPresentation.trimmed(
                sentence,
                fallback: RunPillPresentation.controllingActionFallback,
                limit: RunPillPresentation.actionLimit
            )
            let count = Self.lines(of: trimmed)
            #expect(count <= RunPillView.actionLineLimit, "\(count) lines for \(trimmed)")
        }
    }

    /// The control that says the instrument can count past the budget.
    @Test
    func theInstrumentCountsPastTheBudget() {
        let overlong = String(repeating: "Scrolling to the next paragraph. ", count: 6)
        #expect(Self.lines(of: overlong) > RunPillView.actionLineLimit)
    }

    /// The budget actually bites: a longer action comes back cut, with an ellipsis, at the limit.
    @Test
    func anOverlongActionIsCutAtTheBudget() {
        let long = String(repeating: "a", count: RunPillPresentation.actionLimit + 40)
        let trimmed = RunPillPresentation.trimmed(
            long,
            fallback: RunPillPresentation.controllingActionFallback,
            limit: RunPillPresentation.actionLimit
        )
        #expect(trimmed.count == RunPillPresentation.actionLimit)
        #expect(trimmed.hasSuffix("…"))
    }
}

// MARK: - The glass contains the content (PR #237's delta review, N3)

/// **Every corner of the content sits inside the glass, measured the way the review measured the
/// defect.** The controlling pill used the 40 pt command pill's `Capsule`. At the pill's real height
/// a capsule's corner radius is half that height, and the review's arithmetic put the top-left of the
/// cursor glyph and the first key of the hotkey line outside it. The panel's `RoundedRectangle` at
/// `WidgetTheme.panelRadius` contains both.
///
/// The pill is hosted and its glass view — the `NSVisualEffectView` the glass mounts, at the pill's
/// own width — is found in the real hierarchy, so its height is read rather than assumed. That
/// matters: the height is not fixed, because a wrapped action line adds a row, which the entry
/// records. The content box is the glass inset by the view's own padding, and its four corners are
/// the furthest any row's content can reach. Geometry, not pixels.
@Suite(.serialized)
@MainActor
struct RunPillControllingGlassTests {
    @Test(arguments: [RunPillSweepCase.oneLineAction, .twoLineAction])
    func everyCornerOfTheContentSitsInsideThePanelsGlass(_ sweepCase: RunPillSweepCase) throws {
        let glass = try RunPillHostedGlass.measure(sweepCase)
        let shipped = RoundedRectangle(cornerRadius: WidgetTheme.panelRadius).path(in: glass.rect)

        for corner in glass.contentCorners {
            #expect(shipped.contains(corner.point), "\(corner.name) at \(corner.point) is outside a \(glass.rect.size) panel glass")
        }
    }

    /// **The control reproduces the defect**: the same corners against a `Capsule` at the same
    /// measured size, the shape this pill used to wear. The review's two corners fall outside it, so
    /// the assertion above is shown able to fail rather than passing over any shape at all.
    @Test(arguments: [RunPillSweepCase.oneLineAction, .twoLineAction])
    func theCapsuleThePillUsedToWearCutsThroughThoseCorners(_ sweepCase: RunPillSweepCase) throws {
        let glass = try RunPillHostedGlass.measure(sweepCase)
        let capsule = Capsule().path(in: glass.rect)

        let outside = glass.contentCorners.filter { !capsule.contains($0.point) }.map(\.name)
        #expect(outside.contains("top-left"), "the review's cursor-glyph corner fits a \(glass.rect.size) capsule")
        #expect(outside.contains("bottom-left"), "the review's hotkey-line corner fits a \(glass.rect.size) capsule")
    }

    /// The height really does change when the action wraps — the limitation the entry records —
    /// and both heights are what the cases above measured.
    @Test
    func theGlassIsTallerWhenTheActionLineWraps() throws {
        let one = try RunPillHostedGlass.measure(.oneLineAction)
        let two = try RunPillHostedGlass.measure(.twoLineAction)
        #expect(one.rect.width == RunPillView.controllingWidth)
        #expect(two.rect.width == RunPillView.controllingWidth)
        #expect(two.rect.height > one.rect.height)
    }
}

// MARK: - Hazard 3: System B throughout

/// The controlling pill is the widget's own material: `WidgetTheme` tints, SF Pro through
/// `WidgetType`, and never a `SonnyTheme` token. Reads the real file rather than a held sample.
@Suite
@MainActor
struct RunPillControllingTokenTests {
    @Test
    func theControllingPillUsesOnlySystemBTokens() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        for forbidden in ["SonnyTheme", "SonnyType", "SonnySpacing", "SonnyRadius"] {
            #expect(
                MacAgentSource.count(of: forbidden, inText: view) == 0,
                "\(forbidden) is a System A token and may not enter the widget's material"
            )
        }
        // The control that says this scan can find a token at all.
        #expect(MacAgentSource.count(of: "WidgetTheme.", inText: view) > 0)
        #expect(MacAgentSource.count(of: "WidgetType.", inText: view) > 0)
        #expect(view.contains("WidgetTheme.secondaryCircular"))
    }
}

// MARK: - Shared hosting

enum RunPillSweepCase: CustomTestStringConvertible, Sendable {
    case oneLineAction
    case twoLineAction

    var action: String {
        switch self {
        case .oneLineAction:
            return "Clicking the New Note button"
        case .twoLineAction:
            return "Scrolling the document to reach the paragraph that mentions invoices and receipts"
        }
    }

    var testDescription: String {
        switch self {
        case .oneLineAction: return "a one-line action"
        case .twoLineAction: return "an action that wraps"
        }
    }

    @MainActor
    func presentation() throws -> (RunPillPresentation, RunPillPresentation.Controlling) {
        let progress = VisionSessionProgress(
            appDisplayName: "Notes",
            iteration: 2,
            maximumIterations: 12,
            currentAction: action
        )
        let presentation = try #require(RunPillPresentation.make(state: .controlling(progress), command: ""))
        return (presentation, try #require(presentation.controlling))
    }
}

enum RunPillFired: Equatable {
    case expand
    case pause
    case stop
}

/// A clicked grid point, in the hosting view's own top-left-origin space.
struct RunPillGridPoint: Hashable {
    let x: Int
    let y: Int
}

/// What a sweep fired at each clicked point.
struct RunPillClickMap {
    let step: CGFloat
    let clickCount: Int
    let hits: [RunPillGridPoint: RunPillFired]

    func fired(at point: CGPoint) -> RunPillFired? {
        hits[RunPillGridPoint(x: Int((point.x / step).rounded(.down) * step), y: Int((point.y / step).rounded(.down) * step))]
    }

    func bounds(of action: RunPillFired) -> CGRect? {
        let points = hits.filter { $0.value == action }.map { CGPoint(x: $0.key.x, y: $0.key.y) }
        guard let first = points.first else {
            return nil
        }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    func rowCount(of action: RunPillFired) -> Int {
        Set(hits.filter { $0.value == action }.map(\.key.y)).count
    }
}

/// The controlling content, hosted in a real `RunPillPanel` ordered in far off every screen, with
/// actions that record which one fired.
@MainActor
private final class RunPillClickSweep {
    private static let step: CGFloat = 4

    private final class Recorder {
        var last: RunPillFired?
    }

    let panel: RunPillPanel
    let hosting: NSView
    private let recorder = Recorder()

    init(sweepCase: RunPillSweepCase, overlaidWithSink: Bool) throws {
        let (presentation, controlling) = try sweepCase.presentation()
        let recorder = self.recorder
        let content = RunPillControllingContent(
            presentation: presentation,
            controlling: controlling,
            onExpand: { recorder.last = .expand },
            onPause: { recorder.last = .pause },
            onStop: { recorder.last = .stop }
        )
        let hosting = NSHostingView(
            rootView: overlaidWithSink ? AnyView(content.overlay(ClickSinkOverlay())) : AnyView(content)
        )
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel = RunPillPanel(
            contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        self.hosting = hosting
        // Ordered in, because an unordered panel fires nothing anywhere — measured before this was
        // written — and a sweep over one would pass the control above for the wrong reason.
        panel.orderFrontRegardless()
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// Clicks every grid point, taken in the hosting view's flipped space and converted to the
    /// window's unflipped space for the event — the conversion the delta review found missing.
    func run() -> RunPillClickMap {
        var hits: [RunPillGridPoint: RunPillFired] = [:]
        var clicks = 0
        let timestamp = ProcessInfo.processInfo.systemUptime
        var y: CGFloat = 0
        while y < hosting.bounds.height {
            var x: CGFloat = 0
            while x < hosting.bounds.width {
                let inWindow = hosting.convert(CGPoint(x: x, y: y), to: nil)
                recorder.last = nil
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(
                        with: type,
                        location: inWindow,
                        modifierFlags: [],
                        timestamp: timestamp,
                        windowNumber: panel.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0
                    ) {
                        panel.sendEvent(event)
                    }
                }
                clicks += 1
                if let fired = recorder.last {
                    hits[RunPillGridPoint(x: Int(x), y: Int(y))] = fired
                }
                x += Self.step
            }
            y += Self.step
        }
        return RunPillClickMap(step: Self.step, clickCount: clicks, hits: hits)
    }

    /// Points that are not controls, in the hosting view's flipped space: the transparent window
    /// margin at every corner, the glass beside the identity row, the step line and the hotkey line.
    func surroundings() -> [(String, CGPoint)] {
        let width = hosting.bounds.width
        let height = hosting.bounds.height
        let margin = RunPillView.windowMargin
        let contentLeft = margin + RunPillView.horizontalPadding
        let glassBottom = height - margin
        return [
            ("the window margin, top-left", CGPoint(x: 4, y: 4)),
            ("the window margin, top-right", CGPoint(x: width - 5, y: 4)),
            ("the window margin, bottom-left", CGPoint(x: 4, y: height - 5)),
            ("the window margin, bottom-right", CGPoint(x: width - 5, y: height - 5)),
            ("the glass left of the identity row", CGPoint(x: margin + 4, y: margin + RunPillView.verticalPadding + 4)),
            ("the step line", CGPoint(x: contentLeft + 8, y: glassBottom - RunPillView.verticalPadding - 36)),
            ("the hotkey line", CGPoint(x: contentLeft + 8, y: glassBottom - RunPillView.verticalPadding - 6)),
        ]
    }

    func tearDown() {
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }
}

/// The controlling content, hosted and laid out, with its glass measured from the real hierarchy.
@MainActor
private enum RunPillHostedGlass {
    struct Corner {
        let name: String
        let point: CGPoint
    }

    struct Measurement {
        /// The glass, in its own coordinates, origin at its top-left.
        let rect: CGRect
        let contentCorners: [Corner]
    }

    static func measure(_ sweepCase: RunPillSweepCase) throws -> Measurement {
        let (presentation, controlling) = try sweepCase.presentation()
        let hosting = NSHostingView(rootView: RunPillControllingContent(
            presentation: presentation,
            controlling: controlling,
            onExpand: {},
            onPause: {},
            onStop: {}
        ))
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = RunPillPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        let effect = try #require(
            firstDescendant(of: hosting) { $0 is NSVisualEffectView && $0.frame.width == RunPillView.controllingWidth },
            "the glass's visual-effect view is not in the hosted hierarchy at the pill's width"
        )
        let rect = CGRect(origin: .zero, size: effect.frame.size)
        let left = RunPillView.horizontalPadding
        let right = rect.width - RunPillView.horizontalPadding
        let top = RunPillView.verticalPadding
        let bottom = rect.height - RunPillView.verticalPadding
        return Measurement(rect: rect, contentCorners: [
            Corner(name: "top-left", point: CGPoint(x: left, y: top)),
            Corner(name: "top-right", point: CGPoint(x: right, y: top)),
            Corner(name: "bottom-left", point: CGPoint(x: left, y: bottom)),
            Corner(name: "bottom-right", point: CGPoint(x: right, y: bottom)),
        ])
    }

    private static func firstDescendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        for child in view.subviews {
            if matches(child) {
                return child
            }
            if let found = firstDescendant(of: child, where: matches) {
                return found
            }
        }
        return nil
    }
}

/// A plain `NSView` with AppKit's default `hitTest`, which claims every point inside its bounds —
/// the shape SONNY-443 shipped over the mic. Here only so the sweep has a control that genuinely
/// produces the other answer.
private struct ClickSinkOverlay: NSViewRepresentable {
    final class SinkView: NSView {}

    func makeNSView(context: Context) -> SinkView {
        SinkView()
    }

    func updateNSView(_ nsView: SinkView, context: Context) {}
}
