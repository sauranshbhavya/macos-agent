import AppKit
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
/// calls into this model are view wiring, and a view cannot be asked what it renders. One
/// `pointerArrived`, when the pointer reaches the mic; and three `dismiss`es — the pointer leaving,
/// the slot being taken while a hint was up, and the view disappearing. The founder's manual items
/// 1, 2, 3 and 5 are the verification for those. What an arrival then *does*, slot rule included,
/// is `pointerArrived`'s and is tested here (SONNY-179); what the view still owns alone is which
/// boolean it passes.
///
/// The last suite below reaches one step further than that, into the tracking view those calls hang
/// off, because SONNY-179's bug lived in what the view remembered *between* two of them rather than
/// in either one.
@Suite
@MainActor
struct WidgetMicHoverHintTests {
    /// Short enough that awaiting the real countdown costs nothing, so these tests pin the mechanism
    /// without pinning the shipping three seconds — that number is asserted once, on the value the
    /// view model resolves, in `WidgetVoiceEntryTests`.
    static let promptly = Duration.milliseconds(1)

    /// Long enough that this countdown cannot possibly fire on its own while the assertions run, so
    /// a countdown that finishes at all has been cancelled. Deliberately seconds rather than
    /// minutes: a mutant that stops cancelling is caught either way, and this is what it costs when
    /// one is. Deliberately *not* the shipping three either, so no assertion here can be satisfied
    /// by the two happening to be the same number.
    static let noSoonerThanTheTestEnds = Duration.seconds(5)

    static func reminder(clearingAfter delay: Duration?) -> MicHoverHintPresentation {
        MicHoverHintPresentation(
            message: AgentViewModel.micHoverShortcutReminder,
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

    /// An arrival that finds the hint's slot taken shows nothing — and does not even ask what it
    /// would have shown, which is the assertion that says the arrival stopped rather than that the
    /// answer happened to be discarded.
    ///
    /// It also clears whatever was up, which is not redundant with the slot hook that fires when
    /// the panel takes the slot: the two orders both happen. The panel can open under a pointer
    /// already sitting on the mic, and the pointer can arrive on a mic the panel is already over.
    @Test
    func anArrivalWithTheSlotTakenShowsNothingAndClearsWhatWasUp() {
        let model = MicHoverHintModel()
        var resolutions = 0
        let resolve = {
            resolutions += 1
            return Self.reminder(clearingAfter: Self.noSoonerThanTheTestEnds)
        }

        model.pointerArrived(slotIsFree: true, hint: resolve)
        #expect(model.visibleHint != nil, "a free slot must show the hint")
        #expect(resolutions == 1)

        model.pointerArrived(slotIsFree: false, hint: resolve)

        #expect(model.visibleHint == nil, "a taken slot must leave no hint set")
        #expect(model.dismissCountdown == nil, "and nothing counting toward a row that is not there")
        #expect(resolutions == 1, "the hint was resolved for an arrival that could not show it")
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
    /// **The shipping view produces exactly this sequence, and that is new in SONNY-179.** Two
    /// earlier tellings of this comment called it unreachable: the second said a second `show`
    /// required a `false` → `true` transition of a stored hover boolean and so had to pass through a
    /// dismissing `true` → `false` first. There is no such boolean now — the view responds to each
    /// arrival — so two arrivals with no departure delivered between them, which is the very
    /// sequence the old boolean turned into a swallowed hover, now reach `show` twice in a row. See
    /// `MicHoverArrivalTests`.
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

/// SONNY-179. The hint did not show on the first hover of a session, showed on the second, and
/// showed on every hover after that — exactly one lost, and always the first.
///
/// **The cause was a stored copy of where the pointer is, not the hint's own machinery.** SONNY-177
/// shipped the mic's tracking view writing a `Binding<Bool>` and `FloatingWidgetView` reacting to
/// that boolean *changing*. Both of the events that write it — `mouseEntered` and `mouseExited` —
/// need the pointer to cross the tracking area's edge while that area exists, and the area is
/// created and destroyed with the mic button: the widget's own six-second auto-collapse takes the
/// mic away under a stationary pointer, no crossing happens, so nothing writes `false` and the
/// boolean stays `true` with the pointer nowhere near the mic. Expanding again and hovering wrote
/// `true` over `true` — not a change, so the hook never ran and that hover showed nothing. Leaving
/// finally wrote `false`, the two agreed again, and every later hover worked. The founder's report,
/// mechanism for mechanism.
///
/// So the fix deleted the copy: the tracking view reports the two arrivals and the view responds to
/// each, and what these tests pin is that it responds to *each* — an arrival whose predecessor's
/// departure was never delivered is still an arrival. That is the one property the old design could
/// not have, and it is the whole of the fix; a first hover is not a case anything here names.
///
/// **The tracker is wired the way the app wires it, which is the point and was once the hole.** The
/// arrival goes to `MicHoverHintModel.pointerArrived`, exactly as `FloatingWidgetView`'s
/// `micHintPointerEnteredMic` sends it. These tests first shipped calling `show` directly, so the
/// one test pinning "a repeat arrival is still an arrival" routed around the very function this
/// branch created to be the arrival's one entry point — and a mutant that swallowed the repeat
/// *inside* `pointerArrived`, which is the shipped bug re-expressed one layer down, survived the
/// whole suite. Measured at `5cac908`, found by PR #75's review as F1, and the reason a test's
/// wiring is now a thing this file states rather than a detail.
///
/// **What is still out of reach**, since this suite gets closer to the view than its neighbour
/// above and should not be read as reaching it. `makeNSView`/`updateNSView` handing these two
/// closures to the tracking view is view wiring, and so is *which* slot boolean
/// `micHintPointerEnteredMic` hands over; a view cannot be asked what it renders or what it wired.
/// The founder's manual items are the verification for those. What is reachable is everything from
/// the tracking view inward, which is an `NSView` a test can build and send real enter/exit events
/// to, and the model it feeds.
@Suite
@MainActor
struct MicHoverArrivalTests {
    /// A real `NSEvent` of the kind AppKit delivers, so these tests enter through
    /// `mouseEntered(with:)`/`mouseExited(with:)` themselves rather than through a seam added for
    /// their benefit.
    private static func crossing(_ type: NSEvent.EventType) -> NSEvent? {
        NSEvent.enterExitEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )
    }

    /// A tracking view wired the way `FloatingWidgetView` wires one: `onEnter` calls
    /// `pointerArrived` with the slot's answer and a closure that resolves the hint, `onExit` calls
    /// `dismiss`. Nothing here reaches past `pointerArrived` into `show`, because the app does not.
    ///
    /// The slot is free throughout this suite — what it does when taken is
    /// `anArrivalWithTheSlotTakenShowsNothingAndClearsWhatWasUp`'s, and it needs no event to say it.
    private static func trackerFeeding(
        _ model: MicHoverHintModel
    ) -> AlwaysActiveHoverTracker.TrackingNSView {
        let tracker = AlwaysActiveHoverTracker.TrackingNSView()
        tracker.onEnter = {
            model.pointerArrived(slotIsFree: true) {
                WidgetMicHoverHintTests.reminder(
                    clearingAfter: WidgetMicHoverHintTests.noSoonerThanTheTestEnds
                )
            }
        }
        tracker.onExit = { model.dismiss() }
        return tracker
    }

    /// The bug, reproduced as the sequence that produced it: two arrivals with no departure
    /// delivered between them, because the mic was taken away and given back under a pointer that
    /// never moved.
    ///
    /// The second arrival is the hover the founder lost. It must show the hint and it must arm a
    /// *different* countdown — "there is a countdown" would still be true if the second arrival had
    /// done nothing at all and left the first one's running.
    ///
    /// It travels the app's own route to get there — `TrackingNSView.mouseEntered` to `onEnter` to
    /// `pointerArrived` — so a repeat swallowed at *either* end fails this, which is the whole of
    /// what F1 corrected.
    @Test
    func anArrivalWhoseDepartureWasNeverDeliveredStillShowsTheHint() throws {
        let model = MicHoverHintModel()
        let tracker = Self.trackerFeeding(model)

        let arrival = try #require(Self.crossing(.mouseEntered))

        tracker.mouseEntered(with: arrival)
        let first = try #require(model.dismissCountdown, "the first hover must show the hint")

        // No `mouseExited` in between — that is the whole point. AppKit never delivered one because
        // the pointer never crossed anything: the mic went away underneath it.
        tracker.mouseEntered(with: arrival)

        #expect(model.visibleHint != nil, "the second hover showed nothing — SONNY-179's bug")
        #expect(
            model.dismissCountdown != first,
            "and it must be a fresh countdown, not the one the first hover left running"
        )
    }

    /// The departure still ends the hint, which is the half the fix must not have cost. Asserted
    /// after an arrival rather than on its own, so a tracker that simply never called `onEnter`
    /// could not satisfy it.
    @Test
    func aDepartureClearsTheHintAndLeavesNothingCounting() throws {
        let model = MicHoverHintModel()
        let tracker = Self.trackerFeeding(model)

        tracker.mouseEntered(with: try #require(Self.crossing(.mouseEntered)))
        #expect(model.visibleHint != nil)

        tracker.mouseExited(with: try #require(Self.crossing(.mouseExited)))

        #expect(model.visibleHint == nil, "the pointer left and the hint stayed")
        #expect(model.dismissCountdown == nil, "a countdown outlived the hint it was counting for")
    }

    /// The routing on its own, counted, with the hint out of the picture entirely: two arrivals in
    /// a row are two arrivals, and a departure is not one of them.
    ///
    /// **What this adds over the two above, stated no larger than it is.** Both of those would
    /// already fail against a tracker that swapped its handlers or called both from one override —
    /// they drive a real model and its state answers for the routing. What they cannot do is say
    /// *how many* times an arrival arrived, because `show` is idempotent enough that a second call
    /// and a missing one look alike from the outside once the countdown identity has been checked.
    /// This says it in the only terms that can: a counter per override.
    @Test
    func eachOverrideCallsOnlyItsOwnHandler() throws {
        var arrivals = 0
        var departures = 0
        let tracker = AlwaysActiveHoverTracker.TrackingNSView()
        tracker.onEnter = { arrivals += 1 }
        tracker.onExit = { departures += 1 }

        tracker.mouseEntered(with: try #require(Self.crossing(.mouseEntered)))
        #expect((arrivals, departures) == (1, 0))

        tracker.mouseExited(with: try #require(Self.crossing(.mouseExited)))
        #expect((arrivals, departures) == (1, 1))

        tracker.mouseEntered(with: try #require(Self.crossing(.mouseEntered)))
        tracker.mouseEntered(with: try #require(Self.crossing(.mouseEntered)))
        #expect(
            (arrivals, departures) == (3, 1),
            "every arrival is an arrival, including one that repeats the last one"
        )
    }
}
