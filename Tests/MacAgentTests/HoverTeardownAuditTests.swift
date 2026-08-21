import Foundation
import Testing
@testable import MacAgent

/// SONNY-178 — the hover-teardown audit, and the pins that keep its answer true.
///
/// **The hole this looks for.** SONNY-179 fixed a real bug: the widget's mic hint kept a boolean
/// copy of "the pointer is on the mic", the compact collapse removed the mic while the pointer was
/// inside it, AppKit therefore delivered no exit, and the boolean stayed `true` — so the next hover
/// was not a transition and the hint never appeared again. It fixed one tracked view and never asked
/// whether the same shape existed anywhere else. This suite is that question, answered.
///
/// **The mechanism.** The hole needs *two* things at once:
///
/// 1. hover writes state that **outlives the tracked view**, and
/// 2. some path removes the tracked view while the pointer is inside it.
///
/// **Condition 1 is about where the flag is declared, not what kind of storage it is** — and the
/// first version of this suite got that wrong, in a way PR #84's review caught. It reasoned that
/// `@State` "dies with the view" and concluded five of six sites were clean by construction. That is
/// only true when the `@State` is on the *tracked* view. Two of the six declare theirs on
/// `CommandCenterView`, the window root, while the views their hover tracks live inside a popover
/// torn down independently — structurally the mic case, and reachable: see `F2` in the review and
/// the fix pinned by `theLearnMoreDwellTimerCannotOutliveTheMenuThatOwnsIt` below.
///
/// So the sites divide by *why* each is safe, and the reasons are not interchangeable:
///
/// - **The mic** — was unsafe on both counts; SONNY-179 removed the stored copy.
/// - **The two Learn-more sites** — flag on the window root, tracked views in a dismissible popover.
///   Both conditions held. Fixed on this branch by cancelling the dwell timer when the menu closes.
/// - **The weekly chart's day columns** — safe on **condition 2 alone**: `days` is a fixed
///   seven-element `let`, so a column is never removed while the chart exists. Condition 1 *holds*
///   here — `hoveredDayIndex` is `@State` on `WeeklyCompletionChart`, while the `.onHover` is on the
///   per-column view inside its `ForEach`, so the flag does outlive what it tracks. An earlier
///   version of this comment claimed the flag "sits on the same view as the `.onHover`", which is
///   the exact mistake this suite was rewritten to correct, re-made one paragraph after correcting
///   it (PR #84 cycle 3, C2). **If `days` ever stops being a fixed list, this site needs the
///   Learn-more treatment**, and nothing else here would tell you that.
/// - **The two `ContentView` modifiers** — the flag is `@State` on the modifier itself, which is
///   attached to the tracked view, so it has exactly that view's lifetime.
@Suite
@MainActor
struct HoverTeardownAuditTests {
    /// **The hover-tracking *code sites*, counted rather than remembered — and "sites" is the word
    /// that matters.**
    ///
    /// Six is the number of places hover is wired up. It is emphatically **not** the number of views
    /// that end up tracked: `.sonnyPointerCursor()` alone is applied at 28 call sites and
    /// `.sonnyHoverHighlight(…)` at 22, so the tracked-view population is in the dozens. The first
    /// version of this suite's closing record said "the population is six" without that distinction
    /// (PR #84 review, R1). **28 and 22 are measured, not eyeballed**: `.sonnyPointerCursor()` with
    /// its leading dot, over code lines only, is 21 in `CommandCenterView`, 3 in `RoutineDetailView`,
    /// 2 in `ContentView`, 1 each in `ScreenAccessOnboarding` and `SonnyModeSegmentedControl`. A bare
    /// `sonnyPointerCursor()` grep answers 29, because `ContentView` also holds the `func`
    /// declaration and a doc-comment mention of it.
    ///
    /// **The conclusion still generalizes, and this is why:** the judgement is made per *site*,
    /// because every view a site produces shares that site's storage shape. All 28 pointer-cursor
    /// applications are the same modifier with the same `@State` attached to whatever view carries
    /// it, so judging the modifier judges all 28. What a count of sites cannot do is stand in for a
    /// count of views, which is the claim that was overstated.
    ///
    /// Enumerated over the whole target recursively, and read **by URL** — passing
    /// `lastPathComponent` to `read` would flatten a nested file onto a top-level namesake or throw
    /// (PR #84 review, F4). Keys are paths relative to `Sources/MacAgent/`, which cannot collide.
    @Test
    func theHoverTrackingCodeSitesAreSixAcrossTheWholeAppTarget() throws {
        var onHoverSites: [String: Int] = [:]
        var trackerSites: [String: Int] = [:]

        for file in try MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(file)
            let key = MacAgentSource.relativePath(of: file)
            let hovers = MacAgentSource.count(of: ".onHover", inText: source)
            // The call site takes an argument list; the type's own declaration does not, so
            // counting the open paren separates the two without excluding the declaring file.
            let trackers = MacAgentSource.count(of: "AlwaysActiveHoverTracker(", inText: source)
            if hovers > 0 { onHoverSites[key] = hovers }
            if trackers > 0 { trackerSites[key] = trackers }
        }

        let total = onHoverSites.values.reduce(0, +) + trackerSites.values.reduce(0, +)
        #expect(
            total == 6,
            """
            The hover-tracking site count changed. Judge the new site against SONNY-178's rule \
            before updating this number, and judge both halves: is the flag declared on a view that \
            outlives the one the hover tracks, and can that tracked view be removed while the \
            pointer is inside it? If both, fix it by responding to the event (SONNY-179's shape), \
            not by teaching a flag to notice teardown. Found: .onHover \
            \(onHoverSites.sorted { $0.key < $1.key }), tracker \
            \(trackerSites.sorted { $0.key < $1.key })
            """
        )
        // Where they are, so a move shows up as a move rather than as a silent re-count.
        #expect(onHoverSites == ["CommandCenterView.swift": 3, "ContentView.swift": 2])
        #expect(trackerSites == ["FloatingWidgetView.swift": 1])
    }

    /// **The `SonnyPointerCursorModifier` question, answered: refuted.**
    ///
    /// The hypothesis was that it leaks — a view carrying it removed from the hierarchy under the
    /// pointer would never receive the exit, the `NSCursor.pop()` would never run, and the push
    /// would be stranded, leaving the whole app in the pointing-hand cursor. That is the right thing
    /// to have worried about: it is the only hover site whose state is process-global, so it is the
    /// only one a view's destruction cannot clean up.
    ///
    /// **Refuted.** The modifier discharges its push on four paths: hover-exit, `isEnabled` going
    /// false, `isControlEnabled` going false, and `onDisappear` — the teardown path the hypothesis
    /// is about. `git log -S` puts all four in `8c48c83`, the commit that introduced the modifier, so
    /// this was never a hole that got fixed; it was never open.
    ///
    /// **What this test actually holds, stated because the closing record once claimed more**
    /// (PR #84 review, R2): that `NSCursor` appears in exactly one file, and that the modifier's own
    /// block contains one push and four pops. It does **not** count `NSCursor` occurrences across
    /// `Sources/` — a second push added *inside this file but outside the modifier* would move
    /// neither number. The file-set assertion is what catches a new file; nothing catches a second
    /// site in this one, and no claim here should imply otherwise.
    ///
    /// `didPushCursor` is **not** the "copy of the state to repair" pattern the ticket forbids. It
    /// records an *obligation*: `NSCursor.push()`/`.pop()` are a stack, so a caller must know whether
    /// it owes a pop. What SONNY-179 deleted was a second copy of a fact AppKit already owned.
    ///
    /// One real interleaving, checked and dismissed: two nested views both carrying the modifier both
    /// push, and pops unwind in exit order rather than push order, so one can pop the other's cursor.
    /// The pushes and pops still balance and both are `pointingHand`, so nothing is visible.
    @Test
    func theOnlyHoverThatMutatesProcessGlobalStateDischargesItOnEveryExitIncludingTeardown() throws {
        var filesTouchingCursor: Set<String> = []
        for file in try MacAgentSource.appSourceFiles()
        where try MacAgentSource.read(file).contains("NSCursor") {
            filesTouchingCursor.insert(MacAgentSource.relativePath(of: file))
        }
        #expect(
            filesTouchingCursor == ["ContentView.swift"],
            """
            A second file now mutates the process-global cursor stack. Every push needs a pop on \
            hover-exit *and* on teardown, or a view removed under the pointer strands it for the \
            whole app. Found in: \(filesTouchingCursor.sorted())
            """
        )

        let modifier = try MacAgentSource.region(
            of: MacAgentSource.read("ContentView.swift"),
            from: "private struct SonnyPointerCursorModifier: ViewModifier {",
            to: "private struct SonnyHoverHighlightModifier: ViewModifier {"
        )
        #expect(MacAgentSource.count(of: "NSCursor.pointingHand.push()", inText: modifier) == 1)
        #expect(MacAgentSource.count(of: "NSCursor.pop()", inText: modifier) == 4)
        // And the fourth is specifically the teardown path the ticket asked about, rather than a
        // fourth copy of one of the other three. Brace-matched, so it is the `onDisappear` body and
        // not "everything up to the next closing brace" (PR #84 review, F1).
        let teardown = try MacAgentSource.braceBlock(of: modifier, openedBy: ".onDisappear {")
        #expect(teardown.contains("NSCursor.pop()"))
    }

    /// **Every hover flag is declared `@State` — which establishes the storage *kind*, and that is
    /// all it establishes.**
    ///
    /// This test used to be called `everyOtherHoverFlagLivesInStateAndDiesWithItsView`, and the
    /// second half of that name was false: a grep for `@State` cannot see *which view* the
    /// declaration sits on, and location is the whole of condition 1. Two of these five are declared
    /// on `CommandCenterView` — the window root — while the views their hover tracks are inside a
    /// popover; they passed this test the entire time the defect F2 found was live. Renamed to what
    /// it tests, with the gap stated rather than implied.
    ///
    /// It is still worth keeping. `@State` on the tracked view is the shape that makes a flag safe,
    /// so a change *away* from it — to a binding, a shared object, a view-model property — is always
    /// worth a second look, and this fails on all of them. What it cannot do is confirm safety;
    /// `theLearnMoreDwellTimerCannotOutliveTheMenuThatOwnsIt` is what covers the one site where the
    /// location is wrong and the fix has to carry it.
    @Test
    func everyHoverFlagIsDeclaredAsStateWhichEstablishesKindNotLocation() throws {
        let contentView = try MacAgentSource.read("ContentView.swift")
        // The storage kind and the name, not the type annotation or its default: a reformat that
        // adds `= nil` is not a lifetime change, and a pin failing on one cries wolf about the other.
        #expect(contentView.contains("@State private var didPushCursor"))
        #expect(contentView.contains("@State private var isHovering"))

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        #expect(commandCenter.contains("@State private var isLearnMoreExpanded"))
        #expect(commandCenter.contains("@State private var learnMoreHoverTask"))
        #expect(commandCenter.contains("@State private var hoveredDayIndex"))

        // The sixth is the exception that proves the rule, and it is the one SONNY-179 rewrote: the
        // widget keeps a hint model, deliberately *not* a copy of where the pointer is.
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(widget.contains("@StateObject private var micHint = MicHoverHintModel()"))
        #expect(MacAgentSource.count(of: "isPointerOnMic", inText: widget) == 0)
    }

    /// **The one site where condition 1 genuinely held, and the fix that closes condition 2**
    /// (PR #84 review, F2).
    ///
    /// `isLearnMoreExpanded` and `learnMoreHoverTask` are `@State` on `CommandCenterView`, the window
    /// root; the Learn-more row and its flyout live inside the account-menu popover, which is torn
    /// down independently. The reachable path: rest the pointer on the row, and inside its 100ms
    /// dwell dismiss the menu with Escape. The row goes without AppKit delivering an exit, nothing
    /// cancels the pending task, and it sets the flag with no hover anywhere — so the *next* opening
    /// of the account menu shows the flyout already open.
    ///
    /// The fix responds to the menu closing rather than to a view's teardown, which is SONNY-179's
    /// shape. Read rather than run: `isAccountMenuPresented` is `@State` inside a SwiftUI view and no
    /// test process can drive it or press Escape. What is checkable is that the handler exists, is
    /// keyed on the menu closing, and does both halves — cancelling the timer alone would leave a
    /// flag already set by an earlier fire.
    @Test
    func theLearnMoreDwellTimerCannotOutliveTheMenuThatOwnsIt() throws {
        let source = try MacAgentSource.read("CommandCenterView.swift")
        let handler = try MacAgentSource.braceBlock(
            of: source,
            openedBy: ".onChange(of: isAccountMenuPresented) { _, isPresented in"
        )
        // Only on the way closed — opening the menu must not reset anything.
        #expect(handler.contains("guard !isPresented else { return }"))
        // Both halves: the pending dwell is cancelled, and any flag it already set is cleared.
        #expect(handler.contains("learnMoreHoverTask?.cancel()"))
        #expect(handler.contains("isLearnMoreExpanded = false"))
    }
}
