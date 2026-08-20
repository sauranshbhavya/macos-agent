import Foundation
import Testing
@testable import MacAgent

/// SONNY-178 — the hover-teardown audit, and the two pins that keep its answer true.
///
/// **The hole this looks for.** SONNY-179 fixed a real bug: the widget's mic hint kept a boolean
/// copy of "the pointer is on the mic", the compact collapse removed the mic while the pointer was
/// inside it, AppKit therefore delivered no exit, and the boolean stayed `true` — so the next hover
/// was not a transition and the hint never appeared again. It fixed one tracked view and never asked
/// whether the same shape existed anywhere else. This suite is that question, answered.
///
/// **The mechanism, stated precisely, because the precise version is what makes five of the six
/// sites safe by construction.** The hole needs *two* things at once:
///
/// 1. hover writes state that **outlives the tracked view**, and
/// 2. some path removes the tracked view while the pointer is inside it.
///
/// The mic satisfied both: its flag lived on `FloatingWidgetView`, which survives the collapse that
/// removes the mic. Every other site keeps its flag in `@State` on the tracked view itself, so the
/// storage is destroyed with the view and a stale `true` has nowhere to live — condition 1 fails and
/// no amount of condition 2 matters. **That is why "audit the rest" came back clean and is not a
/// claim that the rest are careful.**
///
/// The one exception writes process-global state, which no view lifetime can destroy, and it is
/// pinned separately below.
@Suite
@MainActor
struct HoverTeardownAuditTests {
    /// **The population, counted rather than remembered.**
    ///
    /// The ticket's own framing: one instance found by accident is evidence about a population, not
    /// an isolated case. So the count is asserted, and a seventh site fails this with a message
    /// telling whoever added it what to check. Recounted here rather than inherited — the figure
    /// PR #75's review recorded had already moved by the time this ticket ran, which is exactly why
    /// a number in prose is worth less than a number a test recomputes.
    ///
    /// Enumerated over the whole target recursively (see `MacAgentSource.appSourceFiles`), not over
    /// the three files that happen to hold the sites today.
    @Test
    func theHoverTrackedPopulationIsSixAcrossTheWholeAppTarget() throws {
        var onHoverSites: [String: Int] = [:]
        var trackerSites: [String: Int] = [:]

        for file in try MacAgentSource.appSourceFiles() {
            let source = try MacAgentSource.read(file.lastPathComponent)
            let hovers = MacAgentSource.count(of: ".onHover", inText: source)
            // The call site takes an argument list; the type's own declaration does not, so
            // counting the open paren separates the two without excluding the declaring file.
            let trackers = MacAgentSource.count(of: "AlwaysActiveHoverTracker(", inText: source)
            if hovers > 0 { onHoverSites[file.lastPathComponent] = hovers }
            if trackers > 0 { trackerSites[file.lastPathComponent] = trackers }
        }

        let total = onHoverSites.values.reduce(0, +) + trackerSites.values.reduce(0, +)
        #expect(
            total == 6,
            """
            The hover-tracked population changed. Judge the new site against SONNY-178's rule \
            before updating this number: does hover write state that outlives the tracked view, \
            and can that view be removed while the pointer is inside it? If both, fix it by \
            responding to the event (SONNY-179's shape), not by teaching a flag to notice \
            teardown. Found: .onHover \(onHoverSites.sorted { $0.key < $1.key }), \
            tracker \(trackerSites.sorted { $0.key < $1.key })
            """
        )
        // Where they are, so a move shows up as a move rather than as a silent re-count.
        #expect(onHoverSites == ["CommandCenterView.swift": 3, "ContentView.swift": 2])
        #expect(trackerSites == ["FloatingWidgetView.swift": 1])
    }

    /// **The ticket's main job: the `SonnyPointerCursorModifier` question, answered.**
    ///
    /// The hypothesis was that it leaks — a view carrying it removed from the hierarchy under the
    /// pointer would never receive the exit, the `NSCursor.pop()` would never run, and the push
    /// would be stranded, leaving the whole app in the pointing-hand cursor. That is the right thing
    /// to have worried about: it is the only hover site whose state is process-global, so it is the
    /// only one a view's destruction cannot clean up.
    ///
    /// **Refuted.** The modifier discharges its push on four paths, not one: hover-exit, `isEnabled`
    /// going false, `isControlEnabled` going false, and `onDisappear` — which is the teardown path
    /// the hypothesis is about. `git log -S` puts all four in `8c48c83`, the commit that introduced
    /// the modifier, so this was never a hole that got fixed; it was never open.
    ///
    /// **This is not the "repair a copy of the state" pattern the ticket forbids**, and the
    /// distinction is worth keeping straight. `didPushCursor` is not a copy of AppKit's hover state.
    /// It records an *obligation*: `NSCursor.push()` and `.pop()` are a stack, so a caller must know
    /// whether it owes a pop. Tracking that is the only correct way to use the API. What SONNY-179
    /// deleted was a second copy of a fact AppKit already owned — a different thing.
    ///
    /// One real interleaving, checked and dismissed: two nested views both carrying the modifier
    /// both push, and pops then unwind in exit order rather than push order, so one view can pop the
    /// other's cursor. The pushes and pops still balance, and both cursors are `pointingHand`, so
    /// there is nothing to see. Not a defect; recorded so it is not rediscovered as one.
    @Test
    func theOnlyHoverThatMutatesProcessGlobalStateDischargesItOnEveryExitIncludingTeardown() throws {
        var filesTouchingCursor: Set<String> = []
        for file in try MacAgentSource.appSourceFiles()
        where try MacAgentSource.read(file.lastPathComponent).contains("NSCursor") {
            filesTouchingCursor.insert(file.lastPathComponent)
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
        // One push, four discharges. The count is the assertion: a push added without a matching
        // discharge, or a discharge deleted, moves one of these two numbers.
        #expect(MacAgentSource.count(of: "NSCursor.pointingHand.push()", inText: modifier) == 1)
        #expect(MacAgentSource.count(of: "NSCursor.pop()", inText: modifier) == 4)
        // And the fourth is specifically the teardown path the ticket asked about, rather than a
        // fourth copy of one of the other three.
        #expect(modifier.contains(".onDisappear {"))
        let teardown = try MacAgentSource.region(of: modifier, from: ".onDisappear {", to: "}")
        #expect(teardown.contains("NSCursor.pop()"))
    }

    /// The other five sites, pinned as a class rather than one by one: each keeps its hover flag in
    /// `@State`, which is destroyed with the view that owns it.
    ///
    /// This is the assertion that makes the audit's conclusion checkable instead of a paragraph. If
    /// someone moves one of these flags onto a longer-lived object — a view model, a shared
    /// `@StateObject`, a static — the flag starts outliving the tracked view and condition 1 of the
    /// hole becomes true again. That is precisely the change SONNY-179 had to undo, and it would
    /// otherwise be invisible until a user reported a hint that stopped appearing.
    @Test
    func everyOtherHoverFlagLivesInStateAndDiesWithItsView() throws {
        let contentView = try MacAgentSource.read("ContentView.swift")
        // `@State private var <name>` and not the type or its default: the storage kind is the
        // property under test, and a reformat that adds `= nil` is not a lifetime change. A pin
        // that fails on one cries wolf about the other.
        #expect(contentView.contains("@State private var didPushCursor"))
        #expect(contentView.contains("@State private var isHovering"))

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        #expect(commandCenter.contains("@State private var isLearnMoreExpanded"))
        #expect(commandCenter.contains("@State private var learnMoreHoverTask"))
        #expect(commandCenter.contains("@State private var hoveredDayIndex"))

        // The sixth is the exception that proves the rule, and it is the one SONNY-179 rewrote:
        // the widget keeps a hint model, deliberately *not* a copy of where the pointer is.
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        #expect(widget.contains("@StateObject private var micHint = MicHoverHintModel()"))
        #expect(MacAgentSource.count(of: "isPointerOnMic", inText: widget) == 0)
    }
}
