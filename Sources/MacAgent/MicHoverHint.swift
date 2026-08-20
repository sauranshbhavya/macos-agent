import Foundation
import SwiftUI

// MARK: - What the hint says, and how long it stays

/// The floating widget's mic hover hint, resolved: the sentence, and whether it clears itself.
///
/// **Resolved by `AgentViewModel`, never by the view.** The choice between the two variants below
/// turns on voice readiness, and a view is not allowed to read that — a view that branches on it
/// can hide or refuse a control for a reason it never shows, which is the bug SONNY-173 fixed and
/// `WidgetVoiceEntryTests.theCompositeVoiceReadinessIsReadInOneFileOnly` now forbids. That scan
/// reads comments as well as code, which is why this comment describes the rule rather than naming
/// the properties it is about. It enumerates `Sources/MacAgent` one level deep, so it covers every
/// Swift file sitting directly in this directory — all of them today, since none live in a
/// subdirectory — rather than the subtree.
///
/// **What that guard reaches, and what it does not.** It stops a view working out *which* variant
/// applies, which is what makes resolving one here the only way to get a correct hint. It cannot
/// stop a view ignoring the resolved value and rendering a literal of its own: a view cannot be
/// asked what it renders, the same boundary SONNY-173 recorded rather than a new one.
///
/// **The delay travels with the message because the two variants differ in kind, not in wording.**
/// The shortcut reminder is a reminder, and a reminder that will not leave is nagging, so it goes
/// after three seconds even if the pointer never moves. The configuration message reports something
/// broken and what to do about it, so it stays for the whole hover — and it is the same sentence
/// the same condition shows when the mic is actually pressed, which is deliberately persistent for
/// the same reason.
///
/// **What that buys, stated no larger than it is.** `autoDismissDelay` has no default, so a third
/// variant cannot be written without its author putting either a duration or `nil` in front of
/// themselves. It does *not* pin that this model counts for the duration it was handed — a mutant
/// replacing the sleep with a hardcoded three seconds survives the suite, recorded as residual A on
/// SONNY-177 by PR #74's review and still open. Harmless today, because
/// `micHoverReminderDismissDelay` is the only non-`nil` delay any caller passes; the gap is real the
/// moment a second one exists.
struct MicHoverHintPresentation: Equatable {
    let message: String
    /// `nil` when the hint has no countdown at all, so nothing but a dismissal ends it — which for
    /// the shipping caller means it lasts the whole hover.
    let autoDismissDelay: Duration?
}

// MARK: - Whether the hint is on screen

/// Owns "the hint is showing", which stopped being the same fact as "the pointer is on the mic" the
/// moment the reminder started clearing itself under a stationary pointer (SONNY-177). This is the
/// only one of the two facts anything keeps: SONNY-179 deleted the view's copy of the pointer's
/// position, because a copy AppKit corrects only by delivering a boundary crossing goes wrong the
/// first time the mic is taken away under a stationary pointer, and stays wrong until a crossing
/// spends itself repairing it. The view now hears the pointer *arrive* and shows a hint, so a
/// second hover and a first are the same event and neither can be swallowed.
///
/// **A separate object rather than more `@State` on `FloatingWidgetView`, for the reason the mic's
/// `.disabled` predicate moved onto the view model (SONNY-173): a view cannot be asked what it
/// renders.** A countdown written inline in a view is enforced by nothing but a reader noticing.
/// The countdown is the behaviour SONNY-177 adds, so it lives where a test can drive it and await
/// the real task instead of sleeping and hoping.
///
/// **The mechanism is `FloatingWidgetView`'s existing auto-collapse timer, not a second invention**
/// — a cancellable `Task`, `try? await Task.sleep(for:)`, `guard !Task.isCancelled`. The shape is
/// what is shared, and only the shape: this one runs for a duration that arrives with each hint
/// (and may be absent entirely, where the auto-collapse delay is one constant), it clears a hint
/// rather than collapsing the widget, and it lives here rather than in `@State`.
///
/// **What that mechanism does under this panel's unusual conditions**, since this window is always
/// visible and rarely key, so a timer here does not live in ordinary circumstances. None of the
/// three is exercised by the suite — no test process can sleep a Mac, occlude a window, or provoke
/// App Nap — so each is argued from the mechanism and measured by nothing:
/// - *The app being inactive changes nothing.* This is Swift concurrency, not a run-loop timer, so
///   it is subject to neither key-window status nor a run-loop mode. Those are two different
///   hazards and only the second belongs to a `Timer`: a run-loop timer stalls outside the modes it
///   was scheduled in, while key-window dependence is `NSTrackingArea`'s failure mode — the one
///   `AlwaysActiveHoverTracker` exists for, and the reason hover here needs `.activeAlways` at all.
/// - *Across machine sleep the countdown keeps counting.* `Task.sleep(for:)` measures on
///   `ContinuousClock`, which advances while the Mac is asleep, so three seconds spent asleep are
///   three seconds spent: the hint is already gone on the first frame after wake rather than
///   resuming a countdown the user has long since walked away from. That is the wanted behaviour
///   for a reminder, and it is the default rather than something arranged.
/// - *Occlusion is not a state anything here observes.* A countdown started before another window
///   covered the widget keeps counting and fires while covered — that is the claim, not the larger
///   one that being covered clears the hint. A hint whose seconds run out behind that window is
///   gone when the widget is revealed; one covered for less time than it had left is still there,
///   correctly. The reverse case cannot arise: a covered widget receives no mouse-entered event, so
///   there is nothing to start.
@MainActor
final class MicHoverHintModel: ObservableObject {
    /// The hint this model says should be showing, `nil` when there is none — the hint's own truth,
    /// deliberately not the pointer's.
    ///
    /// **Not the same as "on screen".** The row also needs its slot, so `FloatingWidgetView`
    /// renders this only while neither the panel nor the compact capsule owns that slot, and
    /// dismisses it when either takes one. Non-`nil` and unrendered is therefore reachable — for
    /// the frame between a slot being taken and the change hook firing, and for the whole of a unit
    /// test, where there is no view at all.
    @Published private(set) var visibleHint: MicHoverHintPresentation?

    /// The most recently armed countdown, exposed so a test awaits the real task rather than
    /// sleeping and hoping.
    ///
    /// **It is not a live-countdown flag, and the obvious reading of it is wrong.** Nothing clears
    /// this when a countdown finishes on its own — the task writes `visibleHint` and stops — so
    /// after a reminder times out normally this still holds that finished task while `visibleHint`
    /// is `nil`. It is `nil` before anything has been shown, after `dismiss()`, and after showing a
    /// hint that has no countdown; non-`nil` otherwise, whether running or long since finished.
    ///
    /// What it never holds is a *cancelled* task: every path that cancels one either clears this or
    /// replaces it within the same call. That is the property worth relying on — at most one
    /// uncancelled countdown exists at a time, and it is this one. Nothing in `Sources/` reads it;
    /// only tests do. (PR #74's review recorded the earlier sentence here — "`nil` whenever nothing
    /// is counting" — as residual B, false for exactly the finished-task case.)
    private(set) var dismissCountdown: Task<Void, Never>?

    /// Called when the pointer arrives on the mic and the hint's slot is free. The caller
    /// establishes both of those; this does not check either.
    ///
    /// Restarts the countdown whenever the hint being shown has one — hovering away and back is a
    /// fresh hover and gets fresh seconds, which is the whole of the re-arm. A hint with no delay
    /// arms nothing, so there "restarting" is only the cancelling: whatever was counting stops, and
    /// nothing takes its place.
    func show(_ hint: MicHoverHintPresentation) {
        dismissCountdown?.cancel()
        visibleHint = hint
        guard let delay = hint.autoDismissDelay else {
            dismissCountdown = nil
            return
        }
        dismissCountdown = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.visibleHint = nil
        }
    }

    /// Every way a hint stops being wanted, which is four call sites in `FloatingWidgetView`: the
    /// pointer left; the pointer arrived while the panel or the compact capsule already owned the
    /// slot, where there is nothing to show and the call does nothing; the slot was taken while a
    /// hint was up; and the view went away.
    ///
    /// Cancelling here is the load-bearing half, not the clearing: a countdown left running
    /// outlives the hint it was counting for and clears whichever hint is up when it lands, which
    /// is a hint disappearing early for no reason the user can see.
    func dismiss() {
        dismissCountdown?.cancel()
        dismissCountdown = nil
        visibleHint = nil
    }
}
