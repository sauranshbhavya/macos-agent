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
