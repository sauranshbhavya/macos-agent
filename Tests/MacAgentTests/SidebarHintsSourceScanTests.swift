import Foundation
import Testing
@testable import MacAgent

/// Phase 14's hold-⌘ hints: the cap that appears on each sidebar control while
/// `CommandKeyHintModel.isShowingHints` is true, and the event monitor that feeds it. Neither is
/// reachable from a unit test — the first is a view rendering, the second is AppKit wiring — so both
/// are pinned the way this repository pins everything a runtime assertion cannot reach: a source
/// scan over the comment-stripped text (`MacAgentSource`'s own doc comment explains why stripping
/// comments is the whole soundness of a scan like this). What a unit test *can* reach is tested
/// there instead: the flags reduction in `CommandKeyChordTests`, the model in
/// `CommandKeyHintsTests`, and the monitor's install-close-reinstall lifecycle in
/// `ProductShellTests`' window test.
///
/// **Two treatments per control, one per sidebar state, after the review** (phase 14's F4, F7, F8,
/// F10 and F11). The first draft put one `.topTrailing` overlay on each control, which in the
/// collapsed rail drew a 40pt cap over a 36pt tile's icon and in the expanded sidebar landed the
/// Tasks row's cap on top of its active-task count. Now every control has exactly one inline site
/// for the expanded state — the cap sits in the row's own trailing slot, vertically centred, and on
/// the Tasks row swaps with the count rather than covering it — and exactly one
/// `commandKeyHintBelow` site for the collapsed state, where the cap hangs beneath the icon in the
/// gap between controls. The toggle's two sites live in `sidebarWordmark`, the only view that knows
/// which state the toggle is in; the toggle itself carries none.
@MainActor
@Suite
struct SidebarHintsSourceScanTests {
    private func commandCenterSource() throws -> String {
        try MacAgentSource.read("CommandCenterView.swift")
    }

    @Test
    func theNavRowHasOneInlineSiteThatSwapsWithTheCountAndOneCollapsedSite() throws {
        let source = try commandCenterSource()
        let region = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func sidebarButton(_ destination: CommandCenterDestination, ordinal: Int) -> some View {"
        )
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(chord: \"⌘\\(ordinal)\")", inText: region) == 1)
        #expect(MacAgentSource.count(of: ".commandKeyHintBelow(\"⌘\\(ordinal)\", isShowing: commandKeyHints.isShowingHints)", inText: region) == 1)
        // The swap: while the hints show, the Tasks row's count gives up the trailing slot rather
        // than sharing its pixels with the cap.
        #expect(region.contains("} else if destination == .tasks, viewModel.activeTaskCount > 0 {"))
        // No floating overlay is left on the row — the collapsed treatment is the modifier above,
        // and the expanded one is inline.
        #expect(!region.contains(".overlay("))
    }

    @Test
    func askSonnyHasOneInlineSiteAndOneCollapsedSite() throws {
        let source = try commandCenterSource()
        let region = try MacAgentSource.braceBlock(of: source, openedBy: "private var askSonnyButton: some View {")
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(chord: \"⌘N\")", inText: region) == 1)
        #expect(MacAgentSource.count(of: ".commandKeyHintBelow(\"⌘N\", isShowing: commandKeyHints.isShowingHints)", inText: region) == 1)
        // The expanded branch still falls back to the plain "⌘N" text once hints are not showing —
        // that text did not simply vanish in favour of an always-on badge.
        #expect(region.contains("Text(\"⌘N\")"))
        #expect(!region.contains(".overlay("))
    }

    /// The toggle is one shared view used in both states, so it cannot know which treatment it
    /// needs; `sidebarWordmark` places the cap, inline before the toggle when expanded and beneath
    /// it when collapsed.
    @Test
    func theToggleCarriesNoCapOfItsOwnAndTheWordmarkPlacesBoth() throws {
        let source = try commandCenterSource()
        let toggle = try MacAgentSource.braceBlock(of: source, openedBy: "private var sidebarToggleButton: some View {")
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(", inText: toggle) == 0)
        #expect(MacAgentSource.count(of: "commandKeyHintBelow(", inText: toggle) == 0)

        let wordmark = try MacAgentSource.braceBlock(of: source, openedBy: "private var sidebarWordmark: some View {")
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(chord: \"⌘⌥S\")", inText: wordmark) == 1)
        #expect(MacAgentSource.count(of: ".commandKeyHintBelow(\"⌘⌥S\", isShowing: commandKeyHints.isShowingHints)", inText: wordmark) == 1)
        // Inline means before the toggle in the expanded row's HStack, so the cap reads at the
        // toggle's leading side and never spills across the sidebar's edge.
        let inlineCap = try #require(wordmark.range(of: "CommandKeyHintBadge(chord: \"⌘⌥S\")"))
        let expandedToggle = try #require(wordmark.range(of: "sidebarToggleButton", options: .backwards))
        #expect(inlineCap.lowerBound < expandedToggle.lowerBound)
    }

    /// Every site reads the one shared flag and nothing else — a cap gated on its own local state
    /// would be a second source of truth the coordinator's monitor could drift from. Three inline
    /// sites gate with `if`, three collapsed sites hand the flag to the modifier, and those six are
    /// every read of the flag in the file.
    @Test
    func everyHintSiteGatesOnTheSharedModelsFlag() throws {
        let source = try commandCenterSource()
        #expect(MacAgentSource.count(of: "if commandKeyHints.isShowingHints {", inText: source) == 3)
        #expect(MacAgentSource.count(of: "isShowing: commandKeyHints.isShowingHints)", inText: source) == 3)
        #expect(MacAgentSource.count(of: "CommandKeyHintBadge(chord:", inText: source) == 3)
        #expect(MacAgentSource.count(of: ".commandKeyHintBelow(", inText: source) == 3)
        #expect(MacAgentSource.count(of: "isShowingHints", inText: source) == 6)
    }

    /// The badge file: one cap per chord, hung beneath a collapsed control by the shared modifier,
    /// and every size a `SonnyMetrics` token — the comment-stripped file carries no digit at all
    /// (phase 14's review, F6 of the rules lane).
    @Test
    func theCapIsOneKeyCapSizedByTokensAndHangsBeneathACollapsedControl() throws {
        let source = try MacAgentSource.read("CommandKeyHintBadge.swift")
        let badge = try MacAgentSource.braceBlock(of: source, openedBy: "struct CommandKeyHintBadge: View {")
        #expect(badge.contains("SonnyKeyCap(text: chord, font: SonnyType.micro, minWidth: SonnyMetrics.hintBadgeMinWidth, height: SonnyMetrics.hintBadgeHeight)"))
        #expect(badge.contains(".accessibilityHidden(true)"))
        #expect(MacAgentSource.count(of: "SonnyKeyCap(", inText: badge) == 1, "one cap holding the whole chord, not a cap per key")

        let below = try MacAgentSource.braceBlock(of: source, openedBy: "func commandKeyHintBelow(_ chord: String, isShowing: Bool) -> some View {")
        #expect(below.contains("overlay(alignment: .bottom)"))
        #expect(below.contains("if isShowing {"))
        #expect(below.contains(".offset(y: SonnyMetrics.hintBadgeDrop)"))

        #expect(source.range(of: "[0-9]", options: .regularExpression) == nil, "no literal size or offset in the view body")
    }

    private func coordinatorSource() throws -> String {
        try MacAgentSource.read("AppWindowCoordinator.swift")
    }

    /// The monitor is installed on every show — not once when the window is made, which the review
    /// found ran once per process against a removal that ran on every close (F2) — and removed once,
    /// when the window closes, never left running past the window it was watching for. The runtime
    /// half of this is `ProductShellTests`' window test: show, close, show again.
    @Test
    func theMonitorIsInstalledOnEveryShowAndRemovedWhenTheWindowCloses() throws {
        let source = try coordinatorSource()

        let show = try MacAgentSource.braceBlock(of: source, openedBy: "func showCommandCenter() {")
        #expect(show.contains("installCommandKeyHintMonitor()"))

        let makeWindow = try MacAgentSource.braceBlock(of: source, openedBy: "private func makeCommandCenterWindowController() -> NSWindowController {")
        #expect(!makeWindow.contains("installCommandKeyHintMonitor()"), "an install tied to the window's making runs once per process")

        let windowWillClose = try MacAgentSource.braceBlock(of: source, openedBy: "func windowWillClose(_ notification: Notification) {")
        #expect(windowWillClose.contains("removeCommandKeyHintMonitor()"))

        // Exactly one call site of each in the whole file: the pair above and nowhere else, so the
        // lifecycle is not something a third caller could bypass or duplicate.
        #expect(MacAgentSource.count(of: "installCommandKeyHintMonitor()", inText: source) == 2, "one call site plus the function's own declaration line")
        #expect(MacAgentSource.count(of: "removeCommandKeyHintMonitor()", inText: source) == 2, "one call site plus the function's own declaration line")

        // Calling it on every show is only right because a second call is a no-op.
        let install = try MacAgentSource.braceBlock(of: source, openedBy: "private func installCommandKeyHintMonitor() {")
        #expect(install.contains("guard commandKeyEventMonitor == nil else { return }"))
    }

    /// The monitor is fed both events the model needs and returns them untouched, so nothing else
    /// watching these events in the app is affected by this one being installed.
    @Test
    func theMonitorWatchesBothEventsAndReturnsThemUntouched() throws {
        let source = try coordinatorSource()
        let install = try MacAgentSource.braceBlock(of: source, openedBy: "private func installCommandKeyHintMonitor() {")
        #expect(install.contains("matching: [.flagsChanged, .keyDown]"))
        #expect(install.contains("commandKeyHintModel.otherKeyPressed()"))
        // Two: the `guard let self else { return event }` early-out and the closure's own final
        // `return event` once both event types have been handled — both hand the event back
        // unmodified, which is the whole property this pins.
        #expect(MacAgentSource.count(of: "return event", inText: install) == 2)
    }

    /// The "⌘ alone" answer comes from `CommandKeyChord`, whose four-modifier mask is unit-tested,
    /// and from nowhere else: the whole-flags mask that let Caps Lock defeat it (F1) is gone from the
    /// file. This is the pin the first draft's scan lacked (F4 of the rhythm lane, F4 of the window
    /// lane): it checked that the model was called, never what it was called with.
    @Test
    func theMonitorReducesTheFlagsThroughCommandKeyChord() throws {
        let source = try coordinatorSource()
        let install = try MacAgentSource.braceBlock(of: source, openedBy: "private func installCommandKeyHintMonitor() {")
        #expect(install.contains("commandKeyHintModel.flagsChanged(commandHeldAlone: CommandKeyChord.isCommandHeldAlone(event.modifierFlags))"))
        #expect(MacAgentSource.count(of: "flagsChanged(commandHeldAlone:", inText: source) == 1)
        #expect(!source.contains("deviceIndependentFlagsMask"))
    }

    /// The window resigning key status resets the model — a local monitor receives nothing once
    /// another window is key, so this is the only signal that can hide a glimpse focus left behind.
    @Test
    func losingKeyStatusHidesTheHints() throws {
        let source = try coordinatorSource()
        let resign = try MacAgentSource.braceBlock(of: source, openedBy: "func windowDidResignKey(_ notification: Notification) {")
        #expect(resign.contains("commandKeyHintModel.focusLost()"))
        #expect(MacAgentSource.count(of: "focusLost()", inText: source) == 1)
    }
}
