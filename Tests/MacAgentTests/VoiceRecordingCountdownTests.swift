import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// Phase 11's voice lane. Pure arithmetic and strings, so every one of these runs with no
/// microphone and no recorder — `AudioCommandRecorder` needs a real one and cannot run inside
/// `swift test`, which is exactly why the widget's countdown is built on a value type in the first
/// place.
@Suite
struct VoiceRecordingCountdownTests {
    /// `listeningSeconds` is under `VoiceRecordingLimit.maximumDurationSeconds` by exactly one
    /// second, not equal to it — see `VoiceRecordingCountdown`'s own doc comment for why equal to
    /// the cap would still be refusable.
    @Test
    func listeningSecondsIsUnderTheCapByThree() {
        #expect(
            VoiceRecordingCountdown.listeningSeconds
                == VoiceRecordingLimit.maximumDurationSeconds - 3
        )
    }

    /// The first label a recording shows, the moment it starts (no time elapsed yet).
    @Test
    func theFirstLabelIsTwoFiftySeven() {
        let startedAt = Date()
        let remaining = VoiceRecordingCountdown.remaining(startedAt: startedAt, now: startedAt)
        #expect(VoiceRecordingCountdown.label(remaining: remaining) == "2:57")
    }

    /// At zero and below, the label reads "0:00" rather than going negative.
    @Test
    func theLabelAtZeroAndBelowIsZeroZero() {
        #expect(VoiceRecordingCountdown.label(remaining: 0) == "0:00")
        #expect(VoiceRecordingCountdown.label(remaining: -4) == "0:00")
    }

    /// The warning flips exactly at thirty seconds remaining, not a moment before or after.
    @Test
    func theWarningFlipsExactlyAtThirty() {
        #expect(VoiceRecordingCountdown.isWarning(remaining: 31) == false)
        #expect(VoiceRecordingCountdown.isWarning(remaining: 30))
        #expect(VoiceRecordingCountdown.isWarning(remaining: 0))
    }

    /// One second reads singular on both units.
    @Test
    func theAccessibilityValueAtOneSecondReadsSingular() {
        #expect(VoiceRecordingCountdown.accessibilityValue(remaining: 1) == "1 second left")
        #expect(VoiceRecordingCountdown.accessibilityValue(remaining: 61) == "1 minute 1 second left")
    }

    /// The rest of the accessibility phrasing: plural minutes and seconds together, and the zero
    /// case, which still says something rather than reading as an empty sentence.
    @Test
    func theAccessibilityValueHandlesPluralsAndZero() {
        #expect(VoiceRecordingCountdown.accessibilityValue(remaining: 179) == "2 minutes 59 seconds left")
        #expect(VoiceRecordingCountdown.accessibilityValue(remaining: 120) == "2 minutes left")
        #expect(VoiceRecordingCountdown.accessibilityValue(remaining: 0) == "0 seconds left")
    }

    /// `remaining` clamps at zero rather than going negative once `now` is past the window.
    @Test
    func remainingClampsAtZero() {
        let startedAt = Date()
        let farFuture = startedAt.addingTimeInterval(VoiceRecordingCountdown.listeningSeconds + 30)
        #expect(VoiceRecordingCountdown.remaining(startedAt: startedAt, now: farFuture) == 0)
    }
}
