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
/// **Tests wait on the hold task itself, and that is safe only while the holds they arm are short**
/// (SONNY-458). The hold's last line is the one that sets the flag, so a test that runs it to its end
/// reads the model's decision rather than racing a clock for it — the 90-second poll this replaced
/// went red under load with a correct model. Phase 12's receipt rework is why the tests once
/// forbade it: two tests awaited a cancelled task whose sleep was a day, and the battery stalled on
/// the mutant that dropped the cancellation. `CommandKeyHintsTests` arms holds of 20 ms and half a
/// second, so the same mutant here costs that long and then reads as the hints coming on.
@MainActor
final class CommandKeyHintModel: ObservableObject {
    static let defaultHoldDelay: TimeInterval = 0.35

    /// Whether the hints are on screen right now.
    @Published private(set) var isShowingHints = false

    private let holdDelay: TimeInterval

    /// The most recently armed hold, exposed so a test can run it to its last line and read what it
    /// decided, and cancel it in its own teardown rather than let it outlive the test that started
    /// it — the same reason `MicHoverHintModel.dismissCountdown` is `private(set)` rather than private.
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
        cancelHoldAndHide()
    }

    /// The window losing key status — the widget's panel coming forward, another app — while a hold
    /// is counting or the hints are showing. The coordinator's local monitor receives nothing once
    /// another window is key, so without this a glimpse that was on screen when focus left would
    /// stay there until this window's next event.
    func focusLost() {
        cancelHoldAndHide()
    }

    private func cancelHoldAndHide() {
        holdTask?.cancel()
        holdTask = nil
        isShowingHints = false
    }
}
