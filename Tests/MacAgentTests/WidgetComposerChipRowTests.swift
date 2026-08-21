import AppKit
import Foundation
import MacAgentCore
import SwiftUI
import Testing
@testable import MacAgent

/// SONNY-207. The floating widget's chip row was cut by the pill's own top edge — the founder's
/// manual pass of PR #93 saw an `In ManualC` chip sitting half outside the glass.
///
/// **What these measure, and why it is not a proxy.** `FloatingWidgetWindowController` sizes the
/// real panel by reading `NSHostingController.view.fittingSize` off the very view this suite hosts,
/// so the height measured here is the height the shipped window uses. That is as close to the live
/// layout as anything in this repository gets without a human at the app.
///
/// **What they still cannot say.** Nothing here looks at a pixel. They can prove the pill is tall
/// enough for its chips and that a chip's silhouette falls inside the stadium the glass is clipped
/// to; they cannot prove the result *reads* correctly, and the founder's eye is still what closes
/// the ticket.
///
/// **The one replica, and why a wrong one fails loudly rather than passing quietly.**
/// `chipNaturalHeight` measures a stand-in built from the same tokens the three real chips use,
/// because the chips themselves are private to `FloatingWidgetView`. It is used in an *equality*
/// against the real measured pill, not as a bound: if the real chips' font or padding changes and
/// this stand-in is not changed with them, the two numbers stop matching and the suite goes red. A
/// replica that has drifted cannot silently weaken the assertion.
@Suite
@MainActor
struct WidgetComposerChipRowTests {
    /// The hairline `widgetGlassPill()` strokes around the pill. A `stroke` is centred on the path,
    /// so it eats half its width out of the interior — that is the margin a chip has to clear on
    /// top of the stadium itself. Mirrors `WidgetGlassBackground`'s `lineWidth: 1.25`.
    private static let glassHairlineWidth: CGFloat = 1.25

    /// The height a chip actually wants: `WidgetType.captionSmall` plus the chips' 4pt vertical
    /// padding, measured rather than asserted, and re-measured on every run — so it cannot go stale
    /// the way a number written into a comment can.
    private static var chipNaturalHeight: CGFloat {
        let replica = HStack(spacing: 4) {
            Text("In ManualC")
                .font(WidgetType.captionSmall)
                .lineLimit(1)
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        return NSHostingView(rootView: replica.fixedSize()).fittingSize.height
    }

    /// The pill the composer row actually laid out, with the widget's own outer padding removed.
    private static func measuredPillHeight(_ configure: (AgentViewModel) -> Void) throws -> CGFloat {
        let root = try makeChipRowDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeChipRowViewModel(root: root)
        configure(viewModel)

        // Nothing above the composer row may be showing, or this measures something else. The
        // in-flight states below rely on it: the widget renders no panel for a run it did not
        // start, so `isRunning` alone leaves the composer row alone on screen.
        #expect(!viewModel.hasVisibleWidgetPanel)
        #expect(viewModel.scheduledRunNotice == nil)
        #expect(viewModel.localStorageNotice == nil)
        #expect(viewModel.plannerFallbackNotice == nil)

        let controller = NSHostingController(rootView: FloatingWidgetView(viewModel: viewModel))
        return controller.view.fittingSize.height - 2 * WidgetComposerGeometry.widgetOuterPadding
    }

    /// Every chip, and every combination of them.
    private static let armings: [(name: String, apply: (AgentViewModel) -> Void)] = [
        ("In <workspace>", { $0.pendingWorkspaceBinding = "ManualC" }),
        ("Won't be saved", { $0.taskRecordingPolicy = .suppressTraces }),
        ("Following up: <command>", { $0.priorTaskContext = armedFollowUpContext() }),
        ("workspace + won't be saved", {
            $0.pendingWorkspaceBinding = "ManualC"
            $0.taskRecordingPolicy = .suppressTraces
        }),
        ("workspace + following up", {
            $0.pendingWorkspaceBinding = "ManualC"
            $0.priorTaskContext = armedFollowUpContext()
        }),
        ("won't be saved + following up", {
            $0.taskRecordingPolicy = .suppressTraces
            $0.priorTaskContext = armedFollowUpContext()
        }),
        ("all three", {
            $0.pendingWorkspaceBinding = "ManualC"
            $0.taskRecordingPolicy = .suppressTraces
            $0.priorTaskContext = armedFollowUpContext()
        })
    ]

    /// Whether the task has been dispatched. A chip drops its clear button once a task is in
    /// flight, so that is a second chip shape and it gets measured too rather than assumed to be
    /// the same size as the first.
    private static let dispatchStates: [(name: String, inFlight: Bool)] = [
        ("", false),
        (", task in flight", true)
    ]

    /// The cross product: every chip combination in both dispatch states, which is every state in
    /// which the composer can render a chip at all.
    private static var chipStates: [(name: String, apply: (AgentViewModel) -> Void)] {
        armings.flatMap { arming in
            dispatchStates.map { dispatch in
                (
                    name: arming.name + dispatch.name,
                    apply: { (viewModel: AgentViewModel) in
                        arming.apply(viewModel)
                        viewModel.isRunning = dispatch.inFlight
                    }
                )
            }
        }
    }

    /// The first half of the defect: row E framed the chip row to a hardcoded 18 and computed the
    /// pill's height from that same 18, while a chip measures more than 18. The pill was shorter
    /// than its own content before the stadium's corner is even considered.
    ///
    /// Stated as an equality over the whole pill rather than a bound on the row, because the two
    /// gaps are the fix's other half and a bound would pass with either of them missing.
    @Test
    func theChipRowIsAtLeastAsTallAsTheChipsItHolds() throws {
        let chipHeight = Self.chipNaturalHeight
        // The replica means nothing if it measured nothing.
        #expect(chipHeight > 0)

        let expected = 2 * WidgetComposerGeometry.chipRowSpacing
            + chipHeight
            + WidgetComposerGeometry.fieldRowHeight

        for state in Self.chipStates {
            let pillHeight = try Self.measuredPillHeight(state.apply)

            #expect(
                pillHeight == expected,
                """
                With \(state.name) the composer pill measured \(pillHeight)pt. A chip is \
                \(chipHeight)pt tall, so the pill owes it \
                \(WidgetComposerGeometry.chipRowSpacing)pt above, the chip itself, another \
                \(WidgetComposerGeometry.chipRowSpacing)pt of gap and the \
                \(WidgetComposerGeometry.fieldRowHeight)pt field row — \(expected)pt. A pill \
                shorter than that is the SONNY-207 clip; a taller one means something reserved \
                room this arithmetic does not know about.
                """
            )
        }
    }

    /// The half that actually produced the founder's screenshot, and the one a taller pill alone
    /// would not have fixed. `widgetGlassPill()` clips the glass to a `Capsule()`, so on a pill H
    /// tall the leading cap is a semicircle of radius H/2 and there is no fill at all above that
    /// arc. A chip at the pill's 14pt leading inset with no top inset lands outside it, and over a
    /// transparent panel that is indistinguishable from being clipped.
    ///
    /// A chip is itself a capsule, so the question is whether its leading cap disc lies inside the
    /// pill's leading cap disc — true exactly when the distance between the two centres plus the
    /// chip's radius fits inside the pill's radius, less the hairline the stroke takes back.
    ///
    /// **Where the chip's top edge comes from matters, so it is measured rather than assumed.** It
    /// is read back out of the pill the layout actually produced — what is left once the field row,
    /// the gap and a full-height chip are taken out of it — not from the inset this view *intends*
    /// to apply. Assuming the intended inset is how this test first passed against the very layout
    /// it was written to catch. On a pill too short for its chips that subtraction goes negative,
    /// and it is then a *pessimistic* reading of where the chip sits (row E's chip overflowed a
    /// short row by half the shortfall in each direction, not all of it) — which is the safe
    /// direction for a containment check: it can fail a layout that is fine, never pass one that
    /// clips.
    @Test
    func everyChipCombinationClearsTheStadiumsLeadingCap() throws {
        let chipHeight = Self.chipNaturalHeight
        let chipRadius = chipHeight / 2

        for state in Self.chipStates {
            let pillHeight = try Self.measuredPillHeight(state.apply)
            let capRadius = pillHeight / 2
            let chipTopInset = pillHeight
                - WidgetComposerGeometry.fieldRowHeight
                - WidgetComposerGeometry.chipRowSpacing
                - chipHeight
            let chipCapCentre = CGPoint(
                x: WidgetComposerGeometry.leadingInset + chipRadius,
                y: chipTopInset + chipRadius
            )

            // The disc test below is the whole story only while the chip's cap stays inside the
            // pill's cap region; past that the pill's edge is flat and a different check applies.
            // Asserted rather than assumed, so the test cannot quietly stop meaning what it says.
            #expect(
                chipCapCentre.x + chipRadius <= capRadius,
                """
                With \(state.name) the chip's leading cap reaches x=\(chipCapCentre.x + chipRadius)pt, \
                past the pill's cap region (\(capRadius)pt). This test's geometry no longer covers \
                the tightest point — rewrite it before trusting it.
                """
            )

            let centreDistance = hypot(capRadius - chipCapCentre.x, capRadius - chipCapCentre.y)
            let slack = capRadius - Self.glassHairlineWidth / 2 - (centreDistance + chipRadius)

            #expect(
                slack >= 0,
                """
                With \(state.name) the chip's leading cap falls \(-slack)pt outside the pill's \
                glass. Pill \(pillHeight)pt (cap radius \(capRadius)pt); chip \(chipHeight)pt at \
                leading inset \(WidgetComposerGeometry.leadingInset)pt and top inset \
                \(chipTopInset)pt. This is the SONNY-207 clip: the fill is not behind the chip, \
                and the widget's panel is transparent, so the chip reads as cut.
                """
            )
        }
    }

    /// The **horizontal** half, and the founder's second manual pass: "the first chip's left margin
    /// looks cramped and out of line with the field row below."
    ///
    /// **`leadingInset` is not one margin, it is two.** The field row's content sits near the pill's
    /// vertical middle where the stadium's edge has nearly finished curving; the chip row sits high
    /// in the leading cap where it has not. The same 14 points from the frame therefore buy the two
    /// rows different amounts of room from the glass — measured on the shipped layout, 4.75pt at the
    /// chip's narrowest against 8.88pt for the field row (a scanline sweep over a rendered pill; the
    /// numbers below are the same quantities derived from the geometry, which is why they do not
    /// carry the hairline or the icon's own side bearing).
    ///
    /// **The narrowest gap is not at the chip's centre line, and that is why the first read of this
    /// was wrong.** A chip is a capsule inside a capsule, both curving the same way, so the gap
    /// between them is tightest where the two arcs run parallel — near the chip's top-left, not
    /// beside it. Measured at the centre line the shipped layout looks 0.9pt off and fine; measured
    /// where the eye actually reads it, it is short by nearly four points.
    ///
    /// `narrowestChipGap` brute-forces that minimum instead of reusing the closed form
    /// `chipRowLeadingInset` solves, so an error in the derivation shows up as a disagreement rather
    /// than being reproduced on both sides. The field-row half *is* the same one-line evaluation in
    /// both places, and is not independent — said plainly rather than implied.
    @Test
    func theFirstChipGetsTheSameRoomFromTheGlassAsTheFieldRow() throws {
        for state in Self.chipStates {
            let pillHeight = try Self.measuredPillHeight(state.apply)
            let derived = WidgetComposerGeometry.chipRowLeadingInset(pillHeight: pillHeight)
            let fieldMargin = Self.fieldRowGlassMargin(pillHeight: pillHeight)

            #expect(
                derived > WidgetComposerGeometry.leadingInset,
                """
                With \(state.name) the derived chip-row inset came back \(derived)pt, which is the \
                field row's own \(WidgetComposerGeometry.leadingInset)pt. Then the derivation is a \
                no-op and the chip is back where the founder found it.
                """
            )

            // The defect itself, pinned: the field row's inset, borrowed as-is, is materially
            // tighter for the chip than it is for the field row.
            let borrowed = Self.narrowestChipGap(
                pillHeight: pillHeight,
                chipLeadingInset: WidgetComposerGeometry.leadingInset
            )
            #expect(
                borrowed < fieldMargin - 1,
                """
                With \(state.name) the chip at a plain \(WidgetComposerGeometry.leadingInset)pt \
                clears the glass by \(borrowed)pt against the field row's \(fieldMargin)pt. This \
                assertion is the cramped layout the founder reported; if the two are ever within a \
                point of each other the derivation has stopped earning its place.
                """
            )

            let achieved = Self.narrowestChipGap(pillHeight: pillHeight, chipLeadingInset: derived)
            #expect(
                abs(achieved - fieldMargin) < 0.01,
                """
                With \(state.name) the chip at the derived \(derived)pt clears the glass by \
                \(achieved)pt, against the field row's \(fieldMargin)pt — they must match. Pill \
                \(pillHeight)pt. A disagreement here means the closed form in \
                `chipRowLeadingInset` and this brute-force scan have parted company, and the \
                brute force is the one to trust.
                """
            )
        }
    }

    /// The founder asked for a derivation that survives the pill changing size, so it is exercised
    /// over sizes the layout does not currently produce as well as the one it does.
    ///
    /// **The clamped cases are the point of it.** On a tall enough pill the field row's own content
    /// sits deep in the cap with *less* room than the chip already has, and the right answer is then
    /// the plain `leadingInset` — the shift gives the chip room, it never takes room away by
    /// dragging it left. So the invariant is three-way, not an equality: match the target, or sit at
    /// a bound on the side that bound exists to protect. Writing it as a plain equality is what this
    /// test did first, and it failed on every pill above about 94 points for a reason that was the
    /// function being right.
    @Test
    func theDerivedInsetStaysInsideItsBoundsAtEveryPillHeight() throws {
        let ceiling = WidgetComposerGeometry.chipRowSpacing + WidgetComposerGeometry.fieldRowHeight / 2

        // Below the field row plus two gaps there is no chip row at all, so there is nothing to
        // inset and the answer is the inset everything else uses.
        for tooShort in [CGFloat(0), 40, 56] {
            #expect(
                WidgetComposerGeometry.chipRowLeadingInset(pillHeight: tooShort)
                    == WidgetComposerGeometry.leadingInset,
                """
                A \(tooShort)pt pill has no room for a chip row, so the chip-row inset must be the \
                plain \(WidgetComposerGeometry.leadingInset)pt. This is also the unmeasured case: \
                the view asks before the first layout pass has reported a height.
                """
            )
        }

        var height = CGFloat(58)
        while height <= 160 {
            let derived = WidgetComposerGeometry.chipRowLeadingInset(pillHeight: height)
            #expect(
                derived >= WidgetComposerGeometry.leadingInset && derived <= ceiling,
                """
                At a \(height)pt pill the derived inset is \(derived)pt, outside \
                [\(WidgetComposerGeometry.leadingInset), \(ceiling)]. Below the low bound the chip \
                would sit left of the field row's content; above the high bound it is indented past \
                the point where moving it buys any more room.
                """
            )

            let achieved = Self.narrowestChipGap(pillHeight: height, chipLeadingInset: derived)
            let target = Self.fieldRowGlassMargin(pillHeight: height)
            let matched = abs(achieved - target) < 0.01
            let heldAtTheFloor = derived == WidgetComposerGeometry.leadingInset && achieved >= target
            let heldAtTheCeiling = derived == ceiling && achieved <= target
            #expect(
                matched || heldAtTheFloor || heldAtTheCeiling,
                """
                At a \(height)pt pill the chip clears the glass by \(achieved)pt against a target \
                of \(target)pt at an inset of \(derived)pt. That is none of the three right \
                answers: hit the target, or sit at \(WidgetComposerGeometry.leadingInset)pt with \
                room to spare, or sit at \(ceiling)pt still short of it.
                """
            )
            height += 1
        }
    }

    /// The other side of the contract, and the one row E got right: with no chip armed the pill is
    /// the 40pt bar it has always been. The fix's top inset is conditional for exactly this reason,
    /// and a top inset applied unconditionally would show up here rather than in a manual pass.
    @Test
    func theUnarmedComposerIsStillTheFortyPointBarItAlwaysWas() throws {
        for dispatch in Self.dispatchStates {
            let pillHeight = try Self.measuredPillHeight { $0.isRunning = dispatch.inFlight }

            #expect(
                pillHeight == WidgetComposerGeometry.fieldRowHeight,
                """
                An unarmed composer\(dispatch.name) measured \(pillHeight)pt. It must be exactly \
                \(WidgetComposerGeometry.fieldRowHeight)pt — SONNY-150's own promise that the \
                widget is unchanged whenever no chip is on, and the reason SONNY-207's top inset \
                is applied only when a chip row exists.
                """
            )
        }
    }

    /// **The arithmetic above is worth nothing if the view does not use it**, and no measurement in
    /// this suite can tell a derived inset from a hardcoded one — `measuredPillHeight` reads a
    /// height, and a leading padding does not change a height. So the wiring is pinned textually,
    /// the way `MacAgentSourceScan` exists to do, with that file's own caveats: comments are
    /// stripped, and this is a scan, so it holds where the tokens are rather than what they compute.
    ///
    /// Counted rather than merely present, per the same rule: a count sees a *swap* — the chip row
    /// given the field row's plain inset and vice versa leaves both tokens in the file and only the
    /// per-site counts move.
    @Test
    func theComposerPillActuallyAppliesTheDerivedChipRowInset() throws {
        let source = try MacAgentSource.read("FloatingWidgetView.swift")
        let pill = try MacAgentSource.braceBlock(of: source, openedBy: "private var composerPill: some View {")

        #expect(
            MacAgentSource.count(of: ".padding(.leading, chipRowExtraLeadingInset)", inText: pill) == 1,
            """
            The chip row does not carry the derived leading inset. Everything in             `theFirstChipGetsTheSameRoomFromTheGlassAsTheFieldRow` can still pass with the chip             back at the field row's own inset, which is the layout the founder rejected.
            """
        )
        #expect(
            MacAgentSource.count(of: ".padding(.leading, WidgetComposerGeometry.leadingInset)", inText: pill) == 1,
            "The pill's own leading inset must stay the plain one — it is what positions the field row."
        )
        #expect(
            MacAgentSource.count(of: ".padding(.leading,", inText: pill) == 2,
            """
            `composerPill` applies a leading inset somewhere this suite does not know about. Two             sites are expected: the pill's own, and the chip row's extra.
            """
        )
        #expect(
            MacAgentSource.count(of: "composerPillHeight = ", inText: pill) == 2,
            """
            The pill's height is no longer being read back from the layout, so             `chipRowLeadingInset` is being asked about a height that never updates — it answers             `leadingInset` for that, which is silently the cramped layout again.
            """
        )

        let extra = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private var chipRowExtraLeadingInset: CGFloat {"
        )
        #expect(
            MacAgentSource.count(
                of: "WidgetComposerGeometry.chipRowLeadingInset(pillHeight: composerPillHeight)",
                inText: extra
            ) == 1,
            "The extra inset must come from the derivation, applied to the measured height."
        )
        #expect(
            MacAgentSource.count(of: "WidgetComposerGeometry.leadingInset", inText: extra) == 1,
            """
            The extra inset is a difference: the pill already applies `leadingInset` to everything             inside it, so this subtracts it. Without the subtraction the chip row is inset twice.
            """
        )
    }

    /// The narrowest horizontal distance between the first chip and the pill's glass, found by
    /// walking the chip's own height rather than by solving.
    ///
    /// **Deliberately not the closed form the production code uses.** `chipRowLeadingInset` locates
    /// the minimum analytically, where the two arcs run parallel; this one just looks. Two methods
    /// that agree are evidence; one method checked against itself is not.
    private static func narrowestChipGap(pillHeight: CGFloat, chipLeadingInset: CGFloat) -> CGFloat {
        let capRadius = pillHeight / 2
        let chipHeight = pillHeight
            - 2 * WidgetComposerGeometry.chipRowSpacing
            - WidgetComposerGeometry.fieldRowHeight
        let chipRadius = chipHeight / 2
        let chipCentreY = WidgetComposerGeometry.chipRowSpacing + chipRadius

        func edge(_ radius: CGFloat, _ offset: CGFloat) -> CGFloat {
            radius - max(0, radius * radius - offset * offset).squareRoot()
        }

        var narrowest = CGFloat.greatestFiniteMagnitude
        var y = WidgetComposerGeometry.chipRowSpacing
        let bottom = WidgetComposerGeometry.chipRowSpacing + chipHeight
        while y <= bottom {
            let chipEdge = chipLeadingInset + edge(chipRadius, y - chipCentreY)
            narrowest = min(narrowest, chipEdge - edge(capRadius, y - capRadius))
            y += 0.001
        }
        return narrowest
    }

    /// The room the field row's content has from the glass, horizontally, at the vertical centre of
    /// that content. The target the chip row is asked to match, and the one quantity this suite does
    /// evaluate the same way the production code does.
    private static func fieldRowGlassMargin(pillHeight: CGFloat) -> CGFloat {
        let capRadius = pillHeight / 2
        let offset = capRadius - WidgetComposerGeometry.fieldRowHeight / 2
        let edge = capRadius - max(0, capRadius * capRadius - offset * offset).squareRoot()
        return WidgetComposerGeometry.leadingInset - edge
    }
}

private func armedFollowUpContext() -> PriorTaskContext {
    PriorTaskContext(
        armedFollowUpOn: "Zip the largest files in ~/Downloads",
        planSummary: "Zip them.",
        steps: [],
        outcome: PriorTaskOutcome(status: .completed, summary: "Zipped 3 files."),
        completedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@MainActor
private func makeChipRowViewModel(root: URL) throws -> AgentViewModel {
    let suiteName = "WidgetComposerChipRowTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json")
        ),
        shortcutCatalog: ChipRowEmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). Nothing here runs a
        // plan, but the fixture is hermetic structurally rather than by luck — the same reasoning
        // `WidgetVoiceEntryTests` records beside its own copy.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: ChipRowFakePasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // In-memory by construction — this store has no file at all.
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private struct ChipRowEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class ChipRowFakePasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeChipRowDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WidgetComposerChipRowTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
