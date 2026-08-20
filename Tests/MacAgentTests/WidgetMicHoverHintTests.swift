import Foundation
import Testing
@testable import MacAgent

/// SONNY-177. The mic's hover hint used to be exactly as long-lived as the pointer: it appeared on
/// mouse-entered and left on mouse-exited, so "the pointer is here" and "the hint is showing" were
/// one boolean. The founder's own pass at the packaged app said a reminder that will not leave is
/// nagging, and once the reminder clears itself under a stationary pointer those two facts come
/// apart — which is what this file is about. `MicHoverHintModel` owns the second one.
///
/// **Nothing here waits on wall-clock time it did not arm itself.** Every countdown is awaited
/// through the model's own `dismissCountdown`, so a test finishes when the task it is testing
/// finishes rather than after a sleep long enough to *probably* be safe. That is why the durations
/// below are the two extremes and nothing in between: one short enough to be instant, one long
/// enough that the only way it can finish is cancellation.
///
/// **What is not reachable from here**, stated rather than implied: `FloatingWidgetView`'s four
/// calls into this model are view wiring, and a view cannot be asked what it renders. One `show`,
/// when the pointer enters and the hint's slot is free; and three `dismiss`es — the pointer
/// leaving, the pointer entering while the panel or the compact capsule already owns the slot, and
/// the view disappearing. The founder's manual items 1, 2, 3 and 5 are the verification for those.
@Suite
@MainActor
struct WidgetMicHoverHintTests {
    /// Short enough that awaiting the real countdown costs nothing, so these tests pin the mechanism
    /// without pinning the shipping four seconds — that number is asserted once, on the value the
    /// view model resolves, in `WidgetVoiceEntryTests`.
    private static let promptly = Duration.milliseconds(1)

    /// Long enough that this countdown cannot possibly fire on its own while the assertions run, so
    /// a countdown that finishes at all has been cancelled. Deliberately seconds rather than
    /// minutes: a mutant that stops cancelling is caught either way, and this is what it costs when
    /// one is.
    private static let noSoonerThanTheTestEnds = Duration.seconds(3)

    private static func reminder(clearingAfter delay: Duration?) -> MicHoverHintPresentation {
        MicHoverHintPresentation(
            message: "Speak your command — or hold Ctrl-Opt-Space anywhere",
            autoDismissDelay: delay
        )
    }

    /// The change itself. Note what this test never does: it never tells the model the pointer left.
    /// The hint goes on its own, with the pointer still sitting on the mic — the whole request.
    @Test
    func theReminderClearsItselfWithThePointerStillOnTheMic() async throws {
        let model = MicHoverHintModel()

        model.show(Self.reminder(clearingAfter: Self.promptly))
        #expect(model.visibleHint != nil)

        let countdown = try #require(model.dismissCountdown, "a reminder must arm a countdown")
        await countdown.value

        #expect(model.visibleHint == nil)
    }

    /// Hovering away and back is a fresh hover, not a resumed one. The spent countdown is gone and a
    /// new one is counting — asserted as a *different* task, because "there is a countdown" would
    /// stay true if the model had simply kept the old, already-finished one.
    @Test
    func hoveringAgainShowsTheReminderWithAFreshCountdown() async throws {
        let model = MicHoverHintModel()

        model.show(Self.reminder(clearingAfter: Self.promptly))
        let first = try #require(model.dismissCountdown)
        await first.value
        #expect(model.visibleHint == nil)

        // The pointer leaves and comes back.
        model.dismiss()
        model.show(Self.reminder(clearingAfter: Self.promptly))

        #expect(model.visibleHint != nil, "a second hover must show it again")
        let second = try #require(model.dismissCountdown)
        #expect(second != first, "and must count on a new countdown, not the spent one")

        await second.value
        #expect(model.visibleHint == nil, "and time out again")
    }

    /// The other half of the founder's decision: the message that reports something broken stays for
    /// the whole hover, because unlike the reminder the user cannot act on it and then have it be
    /// true again a moment later.
    ///
    /// **The assertion is the absence of a countdown, not the survival of the hint across some
    /// interval.** Watching it survive a second would only say it did not vanish within that second;
    /// having nothing armed says there is no mechanism by which it could ever vanish on its own.
    @Test
    func theConfigurationHintArmsNoCountdownAndLeavesWithThePointer() {
        let model = MicHoverHintModel()
        let problem = MicHoverHintPresentation(
            message: AgentViewModel.missingAPIKeyVoiceMessage,
            autoDismissDelay: nil
        )

        model.show(problem)

        #expect(model.visibleHint == problem)
        #expect(model.dismissCountdown == nil, "nothing may be counting toward clearing this one")

        // "For the whole hover" is a bound at both ends: it does still go when the pointer does.
        model.dismiss()
        #expect(model.visibleHint == nil)
    }

    /// The failure mode this design is shaped around: a countdown that outlives the hint it was
    /// counting for, lands later, and clears whichever hint is up by then — a hint disappearing
    /// early for no reason the user can see.
    ///
    /// Reproduces it exactly. The abandoned countdown is armed for longer than this test runs, so
    /// its finishing at all means it was cancelled; the assertion is that the hint standing after it
    /// finishes is the *second* one, untouched.
    @Test
    func aCancelledCountdownCannotClearTheHintThatReplacedIt() async throws {
        let model = MicHoverHintModel()

        model.show(Self.reminder(clearingAfter: Self.noSoonerThanTheTestEnds))
        let abandoned = try #require(model.dismissCountdown)

        // The panel takes the slot, or the pointer leaves — the view calls this for both.
        model.dismiss()
        #expect(model.visibleHint == nil)
        #expect(model.dismissCountdown == nil, "a dismissed hint must leave nothing counting")

        // Hovered again, and now there is a second hint that the first countdown must not touch.
        model.show(Self.reminder(clearingAfter: Self.noSoonerThanTheTestEnds))
        await abandoned.value

        #expect(model.visibleHint != nil, "the abandoned countdown cleared a hint it never armed for")
    }

    /// Re-showing without an intervening dismiss must also abandon the previous countdown rather
    /// than leave two running, or the older one clears the newer hint at the older hover's
    /// deadline.
    ///
    /// **No call path does this today, and the example this comment used to give was wrong.** It
    /// named the panel closing with the pointer never having left; that path calls nothing at all,
    /// because the slot-becoming-free direction deliberately does not re-show. Nor can the hover
    /// hook produce two `show`s in a row: reaching a second `false` → `true` transition means
    /// passing through `true` → `false` first, which dismisses on the way out. So this pins the
    /// model's own contract for a caller that does not exist yet, which is what makes `show` safe
    /// to call twice — not a sequence the shipping view can currently produce.
    @Test
    func showingAgainReplacesTheCountdownRatherThanAddingASecond() async throws {
        let model = MicHoverHintModel()

        model.show(Self.reminder(clearingAfter: Self.noSoonerThanTheTestEnds))
        let superseded = try #require(model.dismissCountdown)

        model.show(Self.reminder(clearingAfter: Self.noSoonerThanTheTestEnds))
        let current = try #require(model.dismissCountdown)
        #expect(current != superseded)

        await superseded.value
        #expect(model.visibleHint != nil, "the superseded countdown cleared the hint that replaced it")
    }
}
