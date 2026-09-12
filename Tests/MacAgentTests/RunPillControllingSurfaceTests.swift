import AppKit
import Foundation
import MacAgentCore
import MacAgentTestSupport
import SwiftUI
import Testing
@testable import MacAgent

// MARK: - Hazard 1: Pause and Stop have to receive their clicks (SONNY-443's shape)

/// **The controlling pill's controls must get their own clicks** (founder decision 2026-09-12 on
/// PR #237's F1, which names this hazard by the case that produced it).
///
/// SONNY-443 shipped a hover tracker overlaid on the mic. `NSView`'s default `hitTest` claims every
/// point inside its bounds, so the founders' clicks on the button underneath landed on the overlay
/// and the mic did nothing while still looking live. The pill repeats the *shape* of that risk from
/// a different direction: the ordinary pill is one big `Button`, and putting Pause and Stop inside
/// it would make the outer button the layer that claims their points.
///
/// So the question is put to AppKit rather than to the source. The real controlling pill — the real
/// `RunPillView` for a real view model in a live `.controlling` state — is hosted in an
/// `NSHostingView` inside the same non-activating panel class the pill ships in, laid out with the
/// run loop turned between passes, and `hitTest` is asked at each control's centre of the view
/// *above* the hosting view, as a real event's dispatch asks it.
///
/// **The control is what makes the answer mean something** (the lesson of PR #230's own F3, and of
/// `CLAUDE.md`'s held-sample rule): a second replica wraps the identical content in an outer
/// `Button`, which is the sink this layout exists to avoid, and its Stop must come back claimed by
/// something else. A test whose negative cannot be produced has not been tested.
@Suite(.serialized)
@MainActor
struct RunPillControlsReceiveClicksTests {
    /// **The measurement.** Where AppKit sends a click at Pause's centre and at Stop's centre, in
    /// the real hosted pill, asked of the view above the hosting view as a real event's dispatch
    /// asks it. Nothing of AppKit's may claim those points — in particular not the
    /// `NSVisualEffectView` the glass background mounts across the pill's whole area, which is a
    /// real AppKit view of exactly the kind that ate the mic's clicks.
    ///
    /// The control centres are not typed in: they are read off the shipped hierarchy by
    /// `HostedControllingPill`, which finds the two control views inside the pill and fails if
    /// there are not exactly two, so a layout change moves the probe with it or fails loudly
    /// rather than quietly testing empty glass.
    @Test
    func clicksAtPauseAndStopReachThePillRatherThanAnyLayerAboveIt() throws {
        let hosted = try HostedControllingPill(overlaidWithSink: false)
        defer { hosted.tearDown() }

        let controls = try hosted.controlCentres()
        let onPause = try #require(hosted.hit(at: controls.pause))
        let onStop = try #require(hosted.hit(at: controls.stop))

        #expect(
            onPause === hosted.hosting,
            "a click at Pause's centre was claimed by \(type(of: onPause))"
        )
        #expect(
            onStop === hosted.hosting,
            "a click at Stop's centre was claimed by \(type(of: onStop))"
        )
    }

    /// **The control, and it fires.** The same pill under an overlay that reproduces SONNY-443's
    /// sink — a plain `NSView` whose default `hitTest` claims every point inside its bounds, which
    /// is precisely the hover tracker the founders' clicks on the mic disappeared into. At the same
    /// two points AppKit now answers that view instead, so the assertions above are shown able to
    /// produce both answers and are not passing over empty space or an empty hierarchy.
    @Test
    func aPlainOverlayOverThePillTakesBothControlsClicks() throws {
        let sunk = try HostedControllingPill(overlaidWithSink: true)
        defer { sunk.tearDown() }

        let controls = try sunk.controlCentres()
        let onPause = try #require(sunk.hit(at: controls.pause))
        let onStop = try #require(sunk.hit(at: controls.stop))

        #expect(onPause is ClickSinkOverlay.SinkView, "the sink did not claim Pause: \(type(of: onPause))")
        #expect(onStop is ClickSinkOverlay.SinkView, "the sink did not claim Stop: \(type(of: onStop))")
        #expect(onStop !== sunk.hosting)
    }

    /// What a hit test cannot answer, asserted where it can be: `NSView.hitTest` says no *foreign*
    /// layer took the point first, and SwiftUI resolves which of its own controls owns it below
    /// that layer. The property that keeps the right control winning there is structural — the
    /// controlling pill is not wrapped in the ordinary pill's expand `Button`, so no outer control
    /// contains Pause and Stop — and it is pinned by reading the shipped view.
    @Test
    func theControllingPillIsNotWrappedInTheExpandButton() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        let compact = try MacAgentSource.braceBlock(
            of: view,
            openedBy: "    private func compactPill(_ presentation: RunPillPresentation) -> some View {"
        )
        let controlling = try MacAgentSource.braceBlock(
            of: view,
            openedBy: "    ) -> some View {"
        )
        // The ordinary pill is one button and the whole of it expands; the controlling pill has
        // three, one per action, and the expand action is on the identity row alone.
        #expect(MacAgentSource.count(of: "Button(action:", inText: compact) == 1)
        #expect(MacAgentSource.count(of: "Button(action:", inText: controlling) == 3)
        #expect(MacAgentSource.count(of: "viewModel.expandWidgetFromPill", inText: controlling) == 1)
        #expect(MacAgentSource.count(of: "viewModel.pauseVisionSession", inText: controlling) == 1)
        #expect(MacAgentSource.count(of: "viewModel.emergencyStopVisionSession", inText: controlling) == 1)
    }
}

// MARK: - Hazard 2: the action line has to be readable at the pill's real width (SONNY-441's instrument)

/// **Measured with AppKit's own text layout, not by eye** (founder decision 2026-09-12, naming PR
/// #228/SONNY-441's measurement as the instrument to use here).
///
/// `RunPillPresentation.actionLimit` is a character budget, and a character count is a proxy for a
/// width in points. This lays the budget out at the controlling pill's real width, in the real font
/// the action line uses, through TextKit — the same instrument that measured the widget's Finder
/// sentence — and asserts it fits the lines the view allows. The width, padding, font and line cap
/// are read from the source, so changing any of them fails here rather than silently widening or
/// narrowing what the budget was measured against.
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

    /// The numbers below are the pill that ships, read from its source.
    @Test
    func theMeasurementReadsThePillThatShips() throws {
        let view = try MacAgentSource.read("RunPillView.swift")
        #expect(view.contains("static let controllingWidth: CGFloat = 340"))
        #expect(view.contains("static let horizontalPadding: CGFloat = 14"))
        #expect(view.contains("static let actionLineLimit = 2"))
        #expect(view.contains(".lineLimit(Self.actionLineLimit)"))
        #expect(view.contains(".font(WidgetType.captionSmall)"))
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

    /// The control that says the instrument can count past the budget: an untrimmed sentence twice
    /// the budget's length measures more than two lines at the same width. Without this, a
    /// measurement that silently returned 1 for everything would read as a pass.
    @Test
    func theInstrumentCountsPastTheBudget() {
        let overlong = String(repeating: "Scrolling to the next paragraph. ", count: 6)
        #expect(Self.lines(of: overlong) > RunPillView.actionLineLimit)
    }

    /// The budget actually bites: a session action longer than it comes back cut, with an ellipsis,
    /// at the limit.
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

// MARK: - Hazard 3: System B throughout

/// The controlling pill is the widget's own material, like the rest of the pill: `WidgetTheme`
/// tints, SF Pro through `WidgetType`, and never a `SonnyTheme` token. Reads the real file rather
/// than a held sample.
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
        // The control that says this scan can find a token at all: the file's System B tokens are
        // there in the numbers the pill uses them in.
        #expect(MacAgentSource.count(of: "WidgetTheme.", inText: view) > 0)
        #expect(MacAgentSource.count(of: "WidgetType.", inText: view) > 0)
        #expect(view.contains("WidgetTheme.secondaryCircular"))
        #expect(view.contains("WidgetTheme.errorGlyph"))
        #expect(view.contains("WidgetTheme.controlSize"))
    }
}

// MARK: - The hosted replica

/// The real `RunPillView`, in a real `RunPillPanel`, in a live `.controlling` state.
///
/// `overlaidWithSink` builds the control: the same pill under a plain `NSView` overlay whose
/// default `hitTest` claims every point inside its bounds — SONNY-443's hover tracker, reproduced.
@MainActor
private final class HostedControllingPill {
    /// Room for the pill to lay itself out at its own size; the pill is measured, not assumed.
    private static let width: CGFloat = 420
    private static let height: CGFloat = 220

    let panel: RunPillPanel
    let hosting: NSView
    private let fixture: ControllingPillFixture

    init(overlaidWithSink: Bool) throws {
        fixture = try makeControllingPillFixture()
        panel = RunPillPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingView(
            rootView: ControllingPillReplica(viewModel: fixture.viewModel, overlaidWithSink: overlaidWithSink)
        )
        panel.contentView = hosting
        self.hosting = hosting
        // Four passes with the run loop turned between them, for the reason PR #230's replica gives:
        // SwiftUI mounts its platform hosts on a later pass than the first, and a hit test asked
        // before they exist reads as the clean answer, which is the reassuring direction.
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func hit(at point: NSPoint) -> NSView? {
        (hosting.superview ?? hosting).hitTest(point)
    }

    /// Pause's and Stop's centres, in the coordinate space `hit(at:)` asks in, read off the shipped
    /// hierarchy rather than typed in.
    ///
    /// The pill lays itself out at `RunPillView.controllingWidth`, so its own container is found by
    /// that width; the two controls are the only children of that container narrow enough to be
    /// buttons in its trailing control row. **Exactly two is required**: a pill that lost a control,
    /// or gained one, fails here instead of leaving this probe measuring empty glass.
    func controlCentres() throws -> (pause: NSPoint, stop: NSPoint) {
        let pill = try #require(
            firstDescendant(of: hosting) { $0.frame.width == RunPillView.controllingWidth },
            "no view in the hosted hierarchy is the pill's own width — the pill did not lay out"
        )
        let controls = pill.subviews
            .filter { $0.frame.width < 100 && $0.frame.height < 40 }
            .sorted { $0.frame.minX < $1.frame.minX }
        #expect(controls.count == 2, "expected Pause and Stop, found \(controls.count) control-sized views")
        let pause = try #require(controls.first)
        let stop = try #require(controls.last)
        return (
            pause: hosting.convert(NSPoint(x: pause.frame.midX, y: pause.frame.midY), from: pill),
            stop: hosting.convert(NSPoint(x: stop.frame.midX, y: stop.frame.midY), from: pill)
        )
    }

    private func firstDescendant(of view: NSView, where matches: (NSView) -> Bool) -> NSView? {
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

    func tearDown() {
        panel.contentView = nil
        panel.close()
        fixture.cleanUp()
    }
}

/// The pill as it ships, or the same pill under the click sink.
private struct ControllingPillReplica: View {
    @ObservedObject var viewModel: AgentViewModel
    let overlaidWithSink: Bool

    var body: some View {
        RunPillView(viewModel: viewModel)
            .overlay(overlaidWithSink ? ClickSinkOverlay() : nil)
    }
}

/// A plain `NSView` with AppKit's default `hitTest`, which claims every point inside its bounds.
/// This is the shape SONNY-443 shipped over the mic; it exists here only so the measurement above
/// has a control that genuinely produces the other answer.
private struct ClickSinkOverlay: NSViewRepresentable {
    final class SinkView: NSView {}

    func makeNSView(context: Context) -> SinkView {
        SinkView()
    }

    func updateNSView(_ nsView: SinkView, context: Context) {}
}

private struct ControllingPillFixture {
    let viewModel: AgentViewModel
    let root: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeControllingPillFixture() throws -> ControllingPillFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RunPillControllingSurfaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encryption = LocalStorageEncryption(keyManager: ControllingPillKeyManager())
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: UnreachableLocalStores.routines(),
        workspaceStore: UnreachableLocalStores.workspaces(),
        snippetStore: UnreachableLocalStores.snippets(),
        recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
        finderRevealer: { _ in },
        shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
        taskHistoryStore: UnreachableLocalStores.taskHistory(),
        taskPlanDetailStore: UnreachableLocalStores.taskPlanDetails(),
        visionSessionJournalStore: UnreachableLocalStores.visionSessionJournal(),
        clipboardHistorySettingsStore: clipboardSettingsStore,
        approvedAppStore: UnreachableLocalStores.approvedApps(),
        outputLocationStore: UnreachableLocalStores.outputLocations(),
        resumableTaskStore: UnreachableLocalStores.resumableTasks(),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            store: UnreachableLocalStores.clipboardHistory(),
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        backendClient: makeHermeticBackendClient(),
        userDefaults: UserDefaults(suiteName: "RunPillControllingSurfaceTests-\(UUID().uuidString)") ?? .standard
    )
    viewModel.isRunning = true
    viewModel.visionSessionProgress = VisionSessionProgress(
        appDisplayName: "Notes",
        iteration: 2,
        maximumIterations: 12,
        currentAction: "Clicking the New Note button"
    )
    return ControllingPillFixture(viewModel: viewModel, root: root)
}

private struct ControllingPillKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x5E, count: 32)
    }
}

