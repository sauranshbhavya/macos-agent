import Foundation
import Testing
@testable import MacAgent

/// Phase 14, the founders' hold-⌘ hints ask: "when I hold the Command key, it should show a
/// glimpse of Command 1 for task, Command 2 for routine … It happens in the Claude app." Everything
/// here is `CommandKeyHintModel`, which knows only a delay and a flag — the `NSEvent` monitor that
/// feeds it lives in `AppWindowCoordinator` and is view/AppKit wiring no test process can drive (the
/// same boundary `MicHoverArrivalTests` states for the tracking view one layer below its model).
///
/// **Nothing here awaits the model's own hold task, and that is deliberate — the phase 12 lesson.**
/// The receipt rework's auto-stop tests once awaited a *cancelled* task's `.value` directly; a
/// mutant that dropped the cancellation left the old sleep still running underneath, and the battery
/// stalled on it rather than reporting a kill (`docs/ui-ux-claude-worklog.md`, phase 12). A mutant
/// that breaks cancellation here must read as "the hints came on late, or stayed on" — never as a
/// hang — so every test below reads `isShowingHints` instead, and cancels whatever hold it armed in
/// its own teardown so no task outlives the test that started it.
///
/// **Waiting for "becomes true" polls the flag rather than sleeping a fixed margin past the delay.**
/// `WidgetMicHoverHintTests` documents a full-suite run stalling an ordinary MainActor task for tens
/// of seconds under load; this file hit exactly that measuring its own first draft — five tests with
/// a 20 ms hold and a 150 ms wait passed in 0.3 seconds run alone and failed under the full 3,121-test
/// suite with the flag still `false` after 60+ real seconds, not because the model was wrong but
/// because the scheduler had not yet run the sleeping task's continuation. Polling on a short
/// interval up to a generous ceiling resolves the instant the real answer arrives instead of racing
/// a guess at how long a busy machine might take, and only costs the ceiling when the model is
/// genuinely broken.
@Suite
@MainActor
struct CommandKeyHintsTests {
    /// Short enough that a correct model resolves almost immediately once polled, and specific to
    /// this file rather than the shipping 0.35, so nothing here could pass by coincidence with the
    /// real number.
    static let shortDelay: TimeInterval = 0.02

    /// How long a poll below is willing to wait for the flag to become true before concluding the
    /// model is actually broken rather than merely scheduled late. Generous on purpose — see the
    /// type's own doc comment for the run that motivated it — and it costs this only when a test
    /// would otherwise fail anyway.
    private static func waitUntilShowing(_ model: CommandKeyHintModel, timeout: Duration = .seconds(90)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !model.isShowingHints {
            guard ContinuousClock.now < deadline else { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test
    func heldAloneShowsAfterTheDelay() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        #expect(model.isShowingHints == false, "the hold has not counted yet")

        try await Self.waitUntilShowing(model)
        #expect(model.isShowingHints == true)
    }

    /// The release and the hold both land synchronously, with no `await` between them — so the hold
    /// task, which cannot begin running until this function suspends or returns, is cancelled before
    /// it has ever had a chance to start sleeping. That makes the assertion below true by
    /// construction regardless of how busy the machine is or how late the cancelled task eventually
    /// gets scheduled: `Task.sleep` checks cancellation up front and returns immediately rather than
    /// waiting out `holdDelay`, so there is no window in which the flag could flip to `true` first.
    @Test
    func releasedBeforeTheDelayNeverShows() {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        model.flagsChanged(commandHeldAlone: false)

        #expect(model.isShowingHints == false, "released before the hold fired must cancel it, not merely hide a shown result")
        #expect(model.holdTask == nil, "nothing should be left counting toward a hold that was released")
    }

    @Test
    func anotherKeyPressedWhileShowingHidesAtOnce() async throws {
        let model = CommandKeyHintModel(holdDelay: Self.shortDelay)
        defer { model.holdTask?.cancel() }

        model.flagsChanged(commandHeldAlone: true)
        try await Self.waitUntilShowing(model)
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
        try await Self.waitUntilShowing(model)
        #expect(model.isShowingHints == true)

        model.otherKeyPressed()
        #expect(model.isShowingHints == false)

        // Released and held again — a fresh hold, not a resumed one.
        model.flagsChanged(commandHeldAlone: true)
        try await Self.waitUntilShowing(model)
        #expect(model.isShowingHints == true, "a fresh hold after a hide must show the hints again")
    }
}
