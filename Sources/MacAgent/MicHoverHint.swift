import Foundation
import SwiftUI

// MARK: - What the hint says, and how long it stays

/// The floating widget's mic hover hint, resolved: the sentence, and whether it clears itself.
///
/// **Resolved by `AgentViewModel`, never by the view.** The choice between the two variants below
/// turns on voice readiness, and a view is not allowed to read that — a view that branches on it
/// can hide or refuse a control for a reason it never shows, which is the bug SONNY-173 fixed and
/// `WidgetVoiceEntryTests.theCompositeVoiceReadinessIsReadInOneFileOnly` now forbids by scanning
/// this whole directory. That scan reads comments as well as code, which is why this comment
/// describes the rule rather than naming the properties it is about.
///
/// **The delay travels with the message because the two variants differ in kind, not in wording.**
/// The shortcut reminder is a reminder, and a reminder that will not leave is nagging, so it goes
/// after four seconds even if the pointer never moves. The configuration message reports something
/// broken and what to do about it, so it stays for as long as the pointer does — exactly like the
/// message the same condition shows when the mic is actually pressed. Keeping the duration beside
/// the text rather than in a separate constant is what stops a third variant from being added with
/// nobody deciding which of the two it behaves like.
struct MicHoverHintPresentation: Equatable {
    let message: String
    /// `nil` when the hint stays for as long as the pointer does.
    let autoDismissDelay: Duration?
}

// MARK: - Whether the hint is on screen

/// Owns "the hint is showing", which stopped being the same fact as "the pointer is on the mic" the
/// moment the reminder started clearing itself under a stationary pointer (SONNY-177). The view
/// keeps the pointer's own boolean; this keeps the hint's, and re-entry is the difference between
/// them — a hover that has already been served looks identical to one that has not, if you only
/// have the one boolean.
///
/// **A separate object rather than more `@State` on `FloatingWidgetView`, for the reason the mic's
/// `.disabled` predicate moved onto the view model (SONNY-173): a view cannot be asked what it
/// renders.** A countdown written inline in a view is enforced by nothing but a reader noticing.
/// Here the countdown is the whole of what this ticket changes, so it lives where a test can drive
/// it and await the real task instead of sleeping and hoping.
///
/// **The mechanism is `FloatingWidgetView`'s existing auto-collapse timer, not a second invention**
/// — a cancellable `Task`, `try? await Task.sleep(for:)`, `guard !Task.isCancelled`. Only the
/// duration differs, and it arrives with the hint.
///
/// **What that mechanism does under this panel's unusual conditions**, since this window is always
/// visible and rarely key, so a timer here does not live in ordinary circumstances:
/// - *The app being inactive changes nothing.* This is Swift concurrency, not a run-loop timer, so
///   it is tied to neither key-window status nor an event-tracking run-loop mode — the two ways a
///   naive `Timer` would have stalled here exactly when the widget is most likely to be hovered.
/// - *Across machine sleep the countdown keeps counting.* `Task.sleep(for:)` measures on
///   `ContinuousClock`, which advances while the Mac is asleep, so four seconds spent asleep are
///   four seconds spent: the hint is already gone on the first frame after wake rather than
///   resuming a countdown the user has long since walked away from. That is the wanted behaviour
///   for a reminder, and it is the default rather than something arranged.
/// - *Occlusion is not a state anything here observes.* A countdown started before another window
///   covered the widget still fires on time, so the hint is gone by the time the widget is visible
///   again. The reverse case cannot arise: a covered widget receives no mouse-entered event, so
///   there is nothing to start.
@MainActor
final class MicHoverHintModel: ObservableObject {
    /// Non-`nil` exactly when the hint is on screen — the hint's own truth, deliberately not the
    /// pointer's.
    @Published private(set) var visibleHint: MicHoverHintPresentation?

    /// The live countdown, exposed so a test awaits the real task rather than sleeping and hoping.
    /// `nil` whenever nothing is counting, which includes while a hint that never times out is up.
    private(set) var dismissCountdown: Task<Void, Never>?

    /// The pointer entered the mic and the hint's slot is free.
    ///
    /// Always restarts the countdown: hovering away and back is a fresh hover and gets fresh
    /// seconds, which is the whole of the re-arm.
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

    /// The pointer left, the panel took the slot, or the view went away.
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
