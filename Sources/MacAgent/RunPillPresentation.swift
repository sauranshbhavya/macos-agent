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
        case needsYou
        case done
        case failed
    }

    /// Which `WidgetTheme` colour the pill's glyph takes. Named here and resolved in
    /// `RunPillView`, so this type owes SwiftUI nothing and a test compares enum cases rather
    /// than colours.
    enum Tint: Equatable {
        case action
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

    /// How much of a command, summary or failure the pill carries: the first line, cut at this
    /// many characters with an ellipsis. A pill is a glance, and the widget has the whole text.
    static let wordLimit = 48
    static let runningFallback = "Sonny is working"
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
                accessibilityLabel: "\(needsYouWords). Click to answer."
            )
        case .working, .controlling:
            let words = trimmed(command, fallback: runningFallback)
            return RunPillPresentation(
                kind: .running,
                glyph: nil,
                words: words,
                tint: .action,
                accessibilityLabel: spoken("Sonny is working on: \(words)", then: "Click to expand.")
            )
        case .result(let summary, _):
            let words = trimmed(summary, fallback: doneFallback)
            return RunPillPresentation(
                kind: .done,
                glyph: "checkmark.circle.fill",
                words: words,
                tint: .allow,
                accessibilityLabel: spoken("Done: \(words)", then: "Click to expand.")
            )
        case .failure(let message):
            let words = trimmed(message, fallback: failedFallback)
            return RunPillPresentation(
                kind: .failed,
                glyph: "xmark.octagon.fill",
                words: words,
                tint: .error,
                accessibilityLabel: spoken("Failed: \(words)", then: "Click to expand.")
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

    /// The first line of `text`, trimmed, cut at `wordLimit` characters with an ellipsis; the
    /// fallback when nothing is left.
    static func trimmed(_ text: String, fallback: String) -> String {
        let firstLine = text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else {
            return fallback
        }
        guard line.count > wordLimit else {
            return line
        }
        return String(line.prefix(wordLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
