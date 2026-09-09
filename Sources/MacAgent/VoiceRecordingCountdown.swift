import Foundation
import MacAgentCore

/// What the widget shows for how long Sonny will keep listening — the founders' ask on 2026-09-09:
/// "For the 3 minutes thing can we show a countdown of maximum recording time? So user knows how
/// long Sonny will listen to you."
///
/// Pure arithmetic and strings, deliberately: `AudioCommandRecorder` needs a real microphone and
/// cannot run inside `swift test`, so every number a test can hold has to be reachable without one.
enum VoiceRecordingCountdown {
    /// How long the widget lets a recording run before it stops the recording itself.
    ///
    /// **Three seconds under `VoiceRecordingLimit.maximumDurationSeconds`, not equal to it.** The
    /// cap refuses a recording whose *held* duration is past the limit (`VoiceRecordingLimit.isTooLong`,
    /// `duration > maximumDurationSeconds`; see `FinishedRecording`'s doc comment for why the held
    /// duration and not the file's length decides). The auto-stop is a `Task` sleeping on the main
    /// actor, and `AudioCommandRecorder.stop()` measures the held duration at the moment that task
    /// actually runs, so every millisecond the main thread is late is a millisecond added to the
    /// number the cap judges. A one-second margin covers ordinary scheduling; this repository has
    /// measured main-actor resumptions arriving seconds late under load (CLAUDE.md's wall-clock
    /// gotcha), and a recording the widget itself ended must not be the one that gets refused. Three
    /// seconds is the margin, so the countdown reads from 2:57 and the promise it makes, that Sonny
    /// stops listening at 0:00 and keeps what it heard, is one an auto-stopped recording keeps.
    static let listeningSeconds: TimeInterval = VoiceRecordingLimit.maximumDurationSeconds - 3

    /// At or under this many seconds remaining, the countdown reads as a warning.
    static let warningSeconds: TimeInterval = 30

    /// The widest the label ever gets ("9:59"), reserved so the composer row never shifts as the
    /// digits change width.
    static let labelReservedWidth: CGFloat = 34

    /// How many seconds are left of `listeningSeconds`, clamped so a recording held past the window
    /// (the auto-stop task races real scheduling too) never reads as negative.
    static func remaining(startedAt: Date, now: Date) -> TimeInterval {
        max(0, listeningSeconds - now.timeIntervalSince(startedAt))
    }

    static func isWarning(remaining: TimeInterval) -> Bool {
        remaining <= warningSeconds
    }

    /// "2:59", "0:07", "0:00" — minutes and seconds, seconds always two digits. Monospaced digits
    /// are the view's job (`.monospacedDigit()`), not this string's.
    static func label(remaining: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(remaining.rounded(.down)))
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// "2 minutes 59 seconds left", "1 second left", "0 seconds left" — read by VoiceOver from the
    /// mic button's accessibility value while a recording is running. Singular where the count is
    /// exactly one, on both units.
    static func accessibilityValue(remaining: TimeInterval) -> String {
        let wholeSeconds = max(0, Int(remaining.rounded(.down)))
        let minutes = wholeSeconds / 60
        let seconds = wholeSeconds % 60

        var parts: [String] = []
        if minutes > 0 {
            parts.append(minutes == 1 ? "1 minute" : "\(minutes) minutes")
        }
        if seconds > 0 || minutes == 0 {
            parts.append(seconds == 1 ? "1 second" : "\(seconds) seconds")
        }
        return parts.joined(separator: " ") + " left"
    }
}
