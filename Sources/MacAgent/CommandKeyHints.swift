import Foundation

/// Whether Command Center should show a glimpse of what each ⌘-shortcut does while the user holds
/// ⌘ alone — the founders' ask (2026-09-10), pointing at the Claude desktop app's own behaviour:
/// "when I hold the Command key, it shows inside the app what I will press after holding the
/// Command key." Fed by a local `NSEvent` monitor `AppWindowCoordinator` installs on the Command
/// Center window; this model only knows the delay and the flag, never AppKit.
///
/// **Held-and-delayed, not held-and-immediate.** An ordinary ⌘-chord press holds ⌘ for a blink
/// before landing on its second key, and showing the hints for that blink would flash them on every
/// shortcut a user already knows how to press. `holdDelay` (0.35 seconds by default — the same
/// order of magnitude as `MicHoverHintModel`'s countdowns, injectable and cancellable rather than a
/// bare literal a test has to sleep past) is long enough that an ordinary chord never trips it and a
/// genuine pause does.
///
/// **Never awaited as a task's own `.value` from a test.** Phase 12's receipt rework hit exactly
/// this: two tests awaited a cancelled task's value, a mutant that dropped the cancellation left the
/// old sleep still running, and the battery stalled rather than reporting a kill. This model's hold
/// task is read only through the published flag, on a bounded real wait, for the same reason —
/// dropping the cancel here must read as "hints came on late or stayed on", never as a hang.
@MainActor
final class CommandKeyHintModel: ObservableObject {
    static let defaultHoldDelay: TimeInterval = 0.35

    /// Whether the hints are on screen right now.
    @Published private(set) var isShowingHints = false

    private let holdDelay: TimeInterval

    /// The most recently armed hold, exposed so a test can cancel it in its own teardown rather than
    /// let it outlive the test that started it — the same reason `MicHoverHintModel.dismissCountdown`
    /// is `private(set)` rather than private.
    private(set) var holdTask: Task<Void, Never>?

    init(holdDelay: TimeInterval = CommandKeyHintModel.defaultHoldDelay) {
        self.holdDelay = holdDelay
    }

    /// Fed by the coordinator's monitor on every `.flagsChanged`. `commandHeldAlone` is true only
    /// while ⌘ is down and no other modifier is — Shift, Option or Control joining hides the hints
    /// at once rather than after the delay, since a modifier chord is not what this glimpse is for.
    ///
    /// Cancels whatever the previous flags-change had scheduled first, so a hold that is released
    /// and re-pressed inside the delay window starts a fresh wait rather than finishing an old one.
    func flagsChanged(commandHeldAlone: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard commandHeldAlone else {
            isShowingHints = false
            return
        }
        holdTask = Task { [weak self, holdDelay] in
            try? await Task.sleep(for: .seconds(holdDelay))
            guard !Task.isCancelled else { return }
            self?.isShowingHints = true
        }
    }

    /// Any key going down while a hold is armed or the hints are already showing ends both at once —
    /// a ⌘-shortcut firing must never leave its badge lingering over the page that shortcut opened.
    func otherKeyPressed() {
        holdTask?.cancel()
        holdTask = nil
        isShowingHints = false
    }
}
