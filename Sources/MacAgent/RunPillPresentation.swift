import Foundation

/// What the run pill says about the one run this app has (SONNY-450).
///
/// When a run starts the floating widget minimises into a small pill at the top-right of the
/// screen the cursor is on, so the user keeps working while Sonny runs. The pill is read off
/// `WidgetState` — the widget's own precedence, hoisted onto `AgentViewModel.widgetState` — and
/// nothing else, so the pill, the widget's panel and Command Center's attention panel can never
/// disagree about whether something needs the user: a parked question is `.needsYou` here for
/// exactly the states the widget would draw a question for.
///
/// **One pill for one run.** `AgentViewModel` holds a single run (`isRunning`, `plan`,
/// `approvalRequest`, `clarificationQuestion`, one parked continuation), so there is one pill;
/// a pill per concurrent task is the follow-up the founders' feature text names and this branch
/// files rather than half-builds.
///
/// A value type so a test holds every state without a window.
struct RunPillPresentation: Equatable {
    enum Kind: Equatable {
        case running
        /// A screen-control session is live and this pill is its HUD (SONNY-450, founder decision
        /// 2026-09-12 on PR #237's F1). Its own case rather than a flavour of `.running`, because
        /// the two must never be told apart by reading their words: the ordinary running pill says
        /// Sonny is working and carries no controls, and this one says Sonny is *controlling* a
        /// named app and carries Pause and Stop. Folding the two together is what that finding
        /// found, and `mutation/plans/feature/the-widget-minimises-while-sonny-runs.txt`'s P7 is
        /// the mutant that folds them back — as a fold that compiles, because a `where` on this
        /// case leaves `make`'s switch non-exhaustive and a mutant that does not build measures
        /// nothing (PR #237's delta review, N1).
        case controlling
        case needsYou
        case done
        case failed
    }

    /// Everything `WidgetControllingPanel` is required to show, carried to the corner (SONNY-450,
    /// founder decision 2026-09-12: option B — a screen-control session still minimises, and the
    /// pill carries what that panel carries, so in effect the panel relocates rather than hides).
    ///
    /// The panel's own doc comment states the requirement this exists to keep: *"While Sonny
    /// controls an app it says so, says which app, says what it is doing right now, and puts Stop
    /// where the user can reach it… a product requirement rather than a courtesy."*
    ///
    /// **Only what varies from one session to the next is carried here** (PR #237's delta review,
    /// N8). The fixed words — Pause, Stop, their spoken names and the line naming the emergency key —
    /// have one owner, `ScreenControlSessionPresentation`, and one view each,
    /// `WidgetSessionPauseButton` and `WidgetSessionStopButton`, which the widget's HUD and this pill
    /// both render. This payload used to copy all five in, which gave the corner a second spelling of
    /// each that nothing tied to the panel's.
    struct Controlling: Equatable {
        let appDisplayName: String
        /// What Sonny is doing right now, cut to `actionLimit` — measured against the pill's real
        /// width with AppKit's own text layout in `RunPillControllingLayoutTests`, not chosen.
        let currentAction: String
        let stepLine: String
    }

    /// Which `WidgetTheme` colour the pill's glyph takes. Named here and resolved in
    /// `RunPillView`, so this type owes SwiftUI nothing and a test compares enum cases rather
    /// than colours.
    enum Tint: Equatable {
        case action
        /// The amber `WidgetSessionIdentityLine` already draws its cursor glyph in — the same
        /// token, so the identity line reads the same in the corner as it does in the panel, and
        /// distinct from both the action blue of an ordinary run and the attention amber of a
        /// parked question.
        case controlling
        case attention
        case allow
        case error
    }

    let kind: Kind
    /// SF Symbol name, or `nil` while running — the pill draws a spinner there, because a static
    /// glyph on a running task reads as a finished one.
    let glyph: String?
    let words: String
    let tint: Tint
    let accessibilityLabel: String
    /// The visible tooltip, which is the label without its instruction sentence (PR #237's F7).
    /// The action belongs in `accessibilityLabel`, where a screen reader needs it; a tooltip that
    /// tells the user to click is explanatory copy on a product surface, and the nearest precedent
    /// — the compact capsule, which uses the identical two-channel pattern — carries the two words
    /// "Open Sonny" and no instruction.
    let tooltip: String
    /// Non-`nil` exactly when `kind` is `.controlling`, and the only kind that carries controls.
    let controlling: Controlling?

    /// How much of a command, summary or failure the pill carries: the first line, cut at this
    /// many characters with an ellipsis. A pill is a glance, and the widget has the whole text.
    static let wordLimit = 48
    /// How much of the session's action line the pill carries. Measured rather than chosen:
    /// `RunPillControllingLayoutTests` lays a sentence of this length out at the controlling
    /// pill's real width in its real font with AppKit's own text layout and asserts it fits the
    /// two lines the view allows — the instrument PR #228 (SONNY-441) used for the widget's own
    /// summary, applied to this surface because a founder decision asked for the action line to be
    /// readable at the pill's real width rather than by eye.
    static let actionLimit = 64
    static let runningFallback = "Sonny is working"
    static let controllingActionFallback = "Looking at the screen"
    static let needsYouWords = "Sonny needs you"
    static let doneFallback = "Done"
    static let failedFallback = "Failed"

    /// The pill for a widget state, or `nil` for a state that shows no pill — idle, a resume offer,
    /// and the two client-version prompts, none of which is a run in flight or its outcome.
    static func make(state: WidgetState, command: String) -> RunPillPresentation? {
        switch state {
        case .permission, .clarification, .captureReview, .delegationReview, .sessionPaused:
            return RunPillPresentation(
                kind: .needsYou,
                glyph: "exclamationmark.bubble.fill",
                words: needsYouWords,
                tint: .attention,
                accessibilityLabel: "\(needsYouWords). Click to answer.",
                tooltip: needsYouWords,
                controlling: nil
            )
        case .controlling(let progress):
            // **A live screen-control session gets its own pill, and it is the HUD** (founder
            // decision 2026-09-12 on PR #237's F1, option B). This arm used to be folded into
            // `.working` below, which put a session behind a pill reading "Sonny is working on: …"
            // in the same action blue as a file zip — naming no app, showing no action, and
            // offering neither Pause, Stop nor the hotkey line, while the widget that carries all
            // four was hidden for the length of the session. That is the one shape
            // `WidgetControllingPanel`'s own doc says this feature must never take.
            let identity = ScreenControlSessionPresentation.controllingMessage(
                appDisplayName: progress.appDisplayName
            )
            let action = trimmed(
                progress.currentAction,
                fallback: controllingActionFallback,
                limit: actionLimit
            )
            return RunPillPresentation(
                kind: .controlling,
                glyph: "cursorarrow.rays",
                words: identity,
                tint: .controlling,
                // Everything a screen reader needs in the order a person needs it: what is
                // happening, to which app, what it is doing now, and the way out that works
                // without the pointer — which during a session is not the user's to aim.
                accessibilityLabel: spoken(
                    "\(identity). \(action)",
                    then: "\(ScreenControlSessionPresentation.stopLabel) and "
                        + "\(ScreenControlSessionPresentation.pauseLabel) are on this pill. "
                        + ScreenControlSessionPresentation.hotkeyLine
                ),
                tooltip: identity,
                controlling: Controlling(
                    appDisplayName: progress.appDisplayName,
                    currentAction: action,
                    stepLine: ScreenControlSessionPresentation.stepLine(
                        iteration: progress.iteration,
                        maximumIterations: progress.maximumIterations
                    )
                )
            )
        case .working:
            let words = trimmed(command, fallback: runningFallback)
            return RunPillPresentation(
                kind: .running,
                glyph: nil,
                words: words,
                tint: .action,
                accessibilityLabel: spoken("Sonny is working on: \(words)", then: "Click to expand."),
                tooltip: "Sonny is working on: \(words)",
                controlling: nil
            )
        case .result(let summary, _):
            let words = trimmed(summary, fallback: doneFallback)
            return RunPillPresentation(
                kind: .done,
                glyph: "checkmark.circle.fill",
                words: words,
                tint: .allow,
                accessibilityLabel: spoken("Done: \(words)", then: "Click to expand."),
                tooltip: "Done: \(words)",
                controlling: nil
            )
        case .failure(let message):
            let words = trimmed(message, fallback: failedFallback)
            return RunPillPresentation(
                kind: .failed,
                glyph: "xmark.octagon.fill",
                words: words,
                tint: .error,
                accessibilityLabel: spoken("Failed: \(words)", then: "Click to expand."),
                tooltip: "Failed: \(words)",
                controlling: nil
            )
        case .idle, .resumeOffer, .tooOld, .updateAvailable:
            return nil
        }
    }

    /// Two sentences for a screen reader, without doubling a full stop the first already ends
    /// with: a summary such as "Zipped 3 files." keeps its own, and a command keeps none.
    static func spoken(_ first: String, then second: String) -> String {
        let terminal: Set<Character> = [".", "!", "?", "…"]
        let separator = first.last.map { terminal.contains($0) } == true ? " " : ". "
        return first + separator + second
    }

    /// The first line of `text`, trimmed, cut at `limit` characters with an ellipsis (the pill's
    /// `wordLimit` unless a caller names its own, which the action line does); the fallback when
    /// nothing is left.
    static func trimmed(_ text: String, fallback: String, limit: Int = wordLimit) -> String {
        let firstLine = text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            return fallback
        }
        guard line.count > limit else {
            return line
        }
        return String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
