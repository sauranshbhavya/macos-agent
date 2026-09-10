import Foundation
import Testing
@testable import MacAgent

/// Phase 14's hold-⌘ hints: the badge that appears on each sidebar control while
/// `CommandKeyHintModel.isShowingHints` is true, and the event monitor that feeds it. Neither is
/// reachable from a unit test — the first is a view rendering, the second is AppKit wiring — so both
/// are pinned the way this repository pins everything a runtime assertion cannot reach: a source
/// scan over the comment-stripped text (`MacAgentSource`'s own doc comment explains why stripping
/// comments is the whole soundness of a scan like this).
///
/// **Why the counts differ per site, stated so a future change does not read a mismatch as a bug.**
/// The nav rows (`sidebarButton`) and the toggle (`sidebarToggleButton`) are single shared functions
/// with nothing permanently printed on them while hints are off, so each gets exactly one overlay
/// call site that covers every state the function renders. Ask Sonny already prints "⌘N" as plain
/// text whenever the sidebar is expanded, so its two branches take two different treatments — an
/// overlay for the icon-only collapsed state, and a swap of the existing text for the expanded one —
/// which is two call sites in one function, not one repeated.
@MainActor
@Suite
struct SidebarHintsSourceScanTests {
    private func commandCenterSource() throws -> String {
        try MacAgentSource.read("CommandCenterView.swift")
    }

    @Test
    func theNavRowSiteHasExactlyOneHintBadgeCoveringBothSidebarStates() throws {
        let source = try commandCenterSource()
        let region = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func sidebarButton(_ destination: CommandCenterDestination, ordinal: Int) -> some View {"
        )
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(", inText: region) == 1)
        #expect(region.contains("CommandKeyHintBadge(keys: [\"⌘\", \"\\(ordinal)\"])"))
    }

    @Test
    func askSonnyHasOneOverlaySiteAndOneTextSwapSite() throws {
        let source = try commandCenterSource()
        let region = try MacAgentSource.braceBlock(of: source, openedBy: "private var askSonnyButton: some View {")
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(", inText: region) == 2)
        #expect(region.contains("CommandKeyHintBadge(keys: [\"⌘\", \"N\"])"))
        // The expanded branch still falls back to the plain "⌘N" text once hints are not showing —
        // that text did not simply vanish in favour of an always-on badge.
        #expect(region.contains("Text(\"⌘N\")"))
    }

    @Test
    func sidebarToggleHasExactlyOneHintBadgeSite() throws {
        let source = try commandCenterSource()
        let region = try MacAgentSource.braceBlock(of: source, openedBy: "private var sidebarToggleButton: some View {")
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(", inText: region) == 1)
        #expect(region.contains("CommandKeyHintBadge(keys: [\"⌘\", \"⌥\", \"S\"])"))
    }

    /// Every badge site reads the one shared flag and nothing else — a badge gated on its own local
    /// state would be a second source of truth the coordinator's monitor could drift from.
    @Test
    func everyHintBadgeSiteGatesOnTheSharedModelsFlag() throws {
        let source = try commandCenterSource()
        #expect(MacAgentSource.count(of: "if commandKeyHints.isShowingHints {", inText: source) == 4)
    }

    private func coordinatorSource() throws -> String {
        try MacAgentSource.read("AppWindowCoordinator.swift")
    }

    /// The monitor is installed once, when the window is made, and removed once, when it closes —
    /// never left running past the window it was watching for.
    @Test
    func theMonitorIsInstalledWhenTheWindowIsMadeAndRemovedWhenItCloses() throws {
        let source = try coordinatorSource()

        let makeWindow = try MacAgentSource.braceBlock(of: source, openedBy: "private func makeCommandCenterWindowController() -> NSWindowController {")
        #expect(makeWindow.contains("installCommandKeyHintMonitor()"))

        let windowWillClose = try MacAgentSource.braceBlock(of: source, openedBy: "func windowWillClose(_ notification: Notification) {")
        #expect(windowWillClose.contains("removeCommandKeyHintMonitor()"))

        // Exactly one call site of each in the whole file: the pair above and nowhere else, so the
        // lifecycle is not something a third caller could bypass or duplicate.
        #expect(MacAgentSource.count(of: "installCommandKeyHintMonitor()", inText: source) == 2, "one call site plus the function's own declaration line")
        #expect(MacAgentSource.count(of: "removeCommandKeyHintMonitor()", inText: source) == 2, "one call site plus the function's own declaration line")
    }

    /// The monitor is fed both events the model needs and returns them untouched, so nothing else
    /// watching these events in the app is affected by this one being installed.
    @Test
    func theMonitorWatchesBothEventsAndReturnsThemUntouched() throws {
        let source = try coordinatorSource()
        let install = try MacAgentSource.braceBlock(of: source, openedBy: "private func installCommandKeyHintMonitor() {")
        #expect(install.contains("matching: [.flagsChanged, .keyDown]"))
        #expect(install.contains("commandKeyHintModel.flagsChanged(commandHeldAlone:"))
        #expect(install.contains("commandKeyHintModel.otherKeyPressed()"))
        // Two: the `guard let self else { return event }` early-out and the closure's own final
        // `return event` once both event types have been handled — both hand the event back
        // unmodified, which is the whole property this pins.
        #expect(MacAgentSource.count(of: "return event", inText: install) == 2)
    }
}
