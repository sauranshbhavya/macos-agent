import Foundation
import Testing
@testable import MacAgent

/// Phase 14, the founders' hold-⌘ hints ask: "when I hold the Command key, it should show a
/// glimpse of Command 1 for task, Command 2 for routine … It happens in the Claude app." Everything
/// here is `CommandKeyHintModel`, which knows only a delay and a flag — the `NSEvent` monitor that
/// feeds it lives in `AppWindowCoordinator` and is view/AppKit wiring no test process can drive (the
/// same boundary `MicHoverArrivalTests` states for the tracking view one layer below its model).
///
/// **Every wait below is the hold task itself, run to its last line, and nothing here reads a clock**
/// (SONNY-458). The hold is a `Task<Void, Never>` whose last line is the one that sets
/// `isShowingHints`, so once its `.value` returns the flag says what the model decided — however late
/// a busy machine got round to running it. Nothing can give up first, so load makes these tests
/// slower and never makes them wrong.
///
/// **What this replaced, because it was the second wall-clock bet this file lost.** The first draft
/// slept a 150 ms margin past a 20 ms hold, passed in 0.3 seconds alone, and failed under the full
/// suite with the flag still `false` after 60+ real seconds. Its replacement polled the flag every
/// 5 ms up to a 90-second ceiling, and on 2026-09-11 that went red three times under load, on exactly
/// the four tests that used it (`heldAloneShowsAfterTheDelay`, `anotherKeyPressedWhileShowingHidesAtOnce`,
/// `aFreshHoldAfterAHideShowsAgain`, `focusLostWhileShowingHidesAtOnce`), each after 100 to 120
/// seconds — PR #226's and PR #228's reviews and the wave 7 session's first run. A ceiling is still a
/// threshold the test races: the poll's own resumption is queued on the main actor ahead of the
/// hold's, so a stall longer than the ceiling lets the poll wake, find the flag unset and give up
/// while the hold that sets it sits next in the queue. That is reproducible on demand — hold the main
/// thread for 500 ms beside a 20 ms hold, and a poll with a 200 ms ceiling reads `false` where
/// awaiting the hold reads `true`, three runs of three each (the changelog entry for
/// `fix/key-hints-robots-groups-and-routine-refusals` has the probe).
///
/// **Awaiting the task is safe here for one reason, and it is a rule for anyone editing this file:
/// every hold armed below is short.** Phase 12 is why this file used to forbid it — a battery stalled
/// on the mutant that dropped a cancellation, because two tests awaited a cancelled task whose sleep
/// was a day long (`docs/ui-ux-claude-worklog.md`, phase 12). Here a dropped cancellation costs the
/// hold's delay, 20 ms or half a second, and then reads as the hints coming on — a kill, not a hang.
/// A long `holdDelay` in this file would bring the stall back. Every test still cancels whatever hold
/// it armed in its own teardown, so no task outlives the test that started it.
@Suite
@MainActor
struct CommandKeyHintsTests {
    /// Short, so a test waiting on the hold costs almost nothing and a dropped cancellation costs no
    /// more (the type's doc comment), and specific to this file rather than the shipping 0.35, so
    /// nothing here could pass by coincidence with the real number.
    static let shortDelay: TimeInterval = 0.02

    /// Runs the hold `model` armed most recently to its last line. `#require` rather than an
    /// optional chain, so a model that armed nothing ends the test instead of waiting on nothing.
    private static func runTheArmedHold(of model: CommandKeyHintModel) async throws {
        let hold = try #require(model.holdTask, "no hold is armed to wait for")
        await hold.value
    }

    @Test
    func heldAloneShowsAfterTheDelay() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        #expect(model.isShowingHints == false, "the hold has not counted yet")

        try await Self.runTheArmedHold(of: model)
        #expect(model.isShowingHints == true)
    }

    /// The release and the hold both land synchronously, with no `await` between them — so the hold
    /// task, which cannot begin running until this function suspends or returns, is cancelled before
    /// it has ever had a chance to start sleeping. The first two assertions are therefore true by
    /// construction however busy the machine is.
    ///
    /// **The cancelled hold is then run to its last line, which is what makes "never" a claim about
    /// the model rather than about one instant** (SONNY-458). A cancelled task still runs its body:
    /// `Task.sleep` throws at once, and the task's own `guard !Task.isCancelled` is the only line
    /// between it and setting the flag. So this reaches that guard on every run, in any order the
    /// machine schedules things — which the checks above, read before the task has run at all, never
    /// could (phase 14's review, F7 of the rules lane, found a model without the guard passing them).
    @Test
    func releasedBeforeTheDelayNeverShows() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        let hold = try #require(model.holdTask, "setup: holding ⌘ alone arms a hold")
        model.flagsChanged(commandHeldAlone: false)

        #expect(model.isShowingHints == false, "released before the hold fired must cancel it, not merely hide a shown result")
        #expect(model.holdTask == nil, "nothing should be left counting toward a hold that was released")

        await hold.value
        #expect(model.isShowingHints == false, "a released hold must never show, even once its cancelled task has run")
    }

    @Test
    func anotherKeyPressedWhileShowingHidesAtOnce() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        try await Self.runTheArmedHold(of: model)
        #expect(model.isShowingHints == true, "setup: the hold must have fired before this test can prove a key hides it")

        model.otherKeyPressed()
        #expect(model.isShowingHints == false, "a ⌘-shortcut firing must never leave its badges lingering")
    }

    /// A single flags-change reporting ⌘+⇧ arrives as `commandHeldAlone: false` — the coordinator
    /// resolves that from the event's modifier set before calling in, so this model never sees
    /// "alone" turn into "not alone" for a chord that was never alone to begin with.
    @Test
    func commandWithShiftNeverShows() {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: false)

        #expect(model.isShowingHints == false)
        #expect(model.holdTask == nil, "a modifier chord must never arm a hold at all")
    }

    @Test
    func aFreshHoldAfterAHideShowsAgain() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        try await Self.runTheArmedHold(of: model)
        #expect(model.isShowingHints == true)

        model.otherKeyPressed()
        #expect(model.isShowingHints == false)

        // Released and held again — a fresh hold, not a resumed one.
        model.flagsChanged(commandHeldAlone: true)
        try await Self.runTheArmedHold(of: model)
        #expect(model.isShowingHints == true, "a fresh hold after a hide must show the hints again")
    }

    /// The release landing while the hold is part-way through its sleep, where
    /// `releasedBeforeTheDelayNeverShows` lands it before the task has run at all. The test suspends
    /// after arming so the hold's first turn — the one that starts its sleep — can run, releases,
    /// and then runs the cancelled hold to its last line: a model that dropped
    /// `guard !Task.isCancelled` sets the flag the moment the cancelled sleep throws, and one that
    /// dropped the cancellation sets it half a second later. Either reads here as the hints showing.
    ///
    /// **This read the flag for two seconds until SONNY-458, and that was a bet in the other
    /// direction** — not a red test on a correct model, but a kill a busy machine could withhold: a
    /// cancelled task whose next turn came more than two seconds late left the flag unset inside the
    /// window, and a model without the guard passed. Running the hold to its end has no window.
    ///
    /// The five-millisecond sleep is a suspension, not a window, and nothing is asserted across it.
    /// The hold's first turn was queued before this test's resumption, and its half second starts
    /// only when that turn runs, so a main actor taking turns in the order they were queued has the
    /// release land while the hold counts. Were it ever to land after the hold fired, the release
    /// hides the hints and the assertion below is still right; only the guard's evidence moves, and
    /// `releasedBeforeTheDelayNeverShows` holds that on every run.
    @Test
    func releasedWhileTheHoldIsCountingNeverShowsAfterwards() async throws {
        let model = CommandKeyHintModel(holdDelay: 0.5)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        let hold = try #require(model.holdTask, "setup: holding ⌘ alone arms a hold")
        try await Task.sleep(for: .milliseconds(5))
        model.flagsChanged(commandHeldAlone: false)
        #expect(model.holdTask == nil, "the release drops the hold")

        await hold.value
        #expect(model.isShowingHints == false, "a hold released while counting must never show, however late its cancelled task runs")
    }

    /// The window losing key status while the hints are up — the widget's panel, another app —
    /// hides them at once; the coordinator's local monitor receives nothing from then on, so nothing
    /// else could.
    @Test
    func focusLostWhileShowingHidesAtOnce() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        try await Self.runTheArmedHold(of: model)
        #expect(model.isShowingHints == true, "setup: the hold must have fired before this test can prove focus loss hides it")

        model.focusLost()
        #expect(model.isShowingHints == false, "a glimpse on screen when focus left would otherwise stay until the window's next event")
    }

    /// "Must not fire into it later" is checked later, too: the hold is run to its last line after
    /// the focus loss, the way `releasedBeforeTheDelayNeverShows` runs a released one (SONNY-458).
    /// Read only at the instant of the focus loss, a model whose `focusLost` forgot to cancel the
    /// hold passed this, since it still dropped the reference and cleared the flag.
    @Test
    func focusLostWhileTheHoldIsCountingCancelsIt() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        let hold = try #require(model.holdTask, "setup: a hold is counting")

        model.focusLost()
        #expect(model.holdTask == nil, "a hold armed in a window that is no longer key must not fire into it later")
        #expect(model.isShowingHints == false)

        await hold.value
        #expect(model.isShowingHints == false, "the hold a focus loss cancelled must not show the hints once its task has run")
    }
}
