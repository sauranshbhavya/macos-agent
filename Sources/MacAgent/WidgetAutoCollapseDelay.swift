import Foundation

/// How long the floating widget leaves a state alone before it collapses to its capsule and, for
/// an outcome, clears it (SONNY-446).
///
/// **Two figures where there was one.** `FloatingWidgetView` ran one six-second timer for both the
/// idle collapse and the outcome clear, and six seconds is the idle figure — a widget nobody is
/// using shrinks out of the way, per Wispr Flow's bubble. A result is something the user is reading
/// and may act on: the founders' pass zipped the largest files and reported that the result had
/// collapsed before they could do anything, and a collapsed result is a cleared one, not a hidden
/// one (`shouldClearOutcomeOnDismiss`). So an outcome counts down from its own, longer figure. A
/// value type rather than two literals in the view, so a test holds both numbers and their order.
///
/// What this does not change: a notified outcome never collapses (SONNY-121) and a persistent
/// failure is never cleared — those rules live in the view's `isCollapsible`, which is read before
/// this is ever asked — and typing restarts the countdown, which the view does in its
/// `.onChange(of: viewModel.command)` by re-arming the timer (PR #231's fresh review, F5). The
/// states that never collapse on a timer answer `nil` here as well as in `isCollapsible`; those
/// are two hand-written switches the compiler makes exhaustive but does not make agree, and
/// `WidgetAutoCollapseDelayTests` holds them in agreement by pinning every case here (F1).
///
/// **The outcome figure is for an outcome the user can see** (F2). `WidgetState` answers
/// `.result` whenever a summary is set, whatever started the run, and the widget draws that
/// result only for a run it started itself (`AgentViewModel.hasVisibleWidgetPanel`); a Command
/// Center run's result leaves the widget showing its composer, which is idle to the eye, and
/// holding it open for twenty seconds was the idle rule broken. So the caller says whether the
/// panel is on screen, and an outcome nobody can see counts down from the idle figure.
enum WidgetAutoCollapseDelay {
    /// Nothing needs attention and nothing was typed: shrink out of the way.
    static let idle: Duration = .seconds(6)
    /// A result or a transient failure landed: long enough to read it and press what it offers.
    static let outcome: Duration = .seconds(20)

    /// The delay a state collapses on, or `nil` for a state that never collapses on a timer;
    /// `showsPanel` is whether the widget is drawing the outcome the state describes.
    static func delay(for state: WidgetState, showsPanel: Bool) -> Duration? {
        switch state {
        case .result, .failure:
            return showsPanel ? outcome : idle
        case .idle, .resumeOffer, .working, .tooOld, .updateAvailable:
            return idle
        case .permission, .clarification, .captureReview, .delegationReview, .sessionPaused, .controlling:
            return nil
        }
    }
}
