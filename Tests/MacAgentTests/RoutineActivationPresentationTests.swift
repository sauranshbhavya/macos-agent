import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-46's user-visible half: the Routines row can no longer say the opposite of the truth.
///
/// A separate file from `ScheduledRoutineRunTests` on purpose — that suite is SONNY-31's, and this
/// ticket's measure is that it passes unchanged. `aPausedRoutineRowShowsNeedsAttentionWhileAUser`
/// `DisabledOneDoesNot` there already covers the three legal states; what it could not cover is the
/// illegal one, because before the fold the only way to reach it was to construct it, and after the
/// fold it cannot be constructed at all. So the route in is the decoder — a `routines.json` already
/// holding the broken shape, which is exactly how a real user would meet it.
@Suite
struct RoutineActivationPresentationTests {
    /// The bug, stated as a test. An enabled schedule carrying a stale pause reason used to paint
    /// "Paused" on a routine that was still firing on time, *and* suppress the next-run caption
    /// that slot exists for — the row reporting that automation needed attention while it quietly
    /// kept running. Decoding now repairs the state, so the row tells the truth: not paused, with
    /// its real next run showing.
    @Test
    func aRoutineWhoseStoredScheduleWasEnabledAndPausedAtOnceRendersAsRunning() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let routine = try decodeRoutine(isEnabled: true, pausedReason: "Snippet trigger ;sig already exists and would be replaced.")

        let presentation = RoutineRowPresentation(routine: routine, now: now)

        #expect(presentation.isPaused == false)
        #expect(presentation.isEnabled)
        // The caption the "Paused" state used to displace is back where it belongs.
        #expect(presentation.nextRunText != nil)
    }

    /// The counterpart, so the test above cannot pass by the row simply never saying "Paused":
    /// a genuinely paused schedule still reports needs-attention, and a user's own disable still
    /// does not.
    @Test
    func genuinelyPausedAndUserDisabledSchedulesStillRenderAsTheyDid() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paused = try decodeRoutine(isEnabled: false, pausedReason: "Draft output already exists at /tmp/weekly.md.")
        let userDisabled = try decodeRoutine(isEnabled: false, pausedReason: nil)

        #expect(RoutineRowPresentation(routine: paused, now: now).isPaused)
        #expect(RoutineRowPresentation(routine: paused, now: now).isEnabled == false)
        #expect(RoutineRowPresentation(routine: paused, now: now).nextRunText == nil)
        #expect(RoutineRowPresentation(routine: userDisabled, now: now).isPaused == false)
        #expect(RoutineRowPresentation(routine: userDisabled, now: now).isEnabled == false)
    }

    private func decodeRoutine(isEnabled: Bool, pausedReason: String?) throws -> StoredRoutine {
        let reasonLine = pausedReason.map { ",\n      \"pausedReason\": \"\($0)\"" } ?? ""
        let json = """
        {
          "name": "Morning",
          "steps": [
            { "id": "open", "operation": "open_app", "description": "Open Safari.", "appName": "Safari" }
          ],
          "schedule": {
            "cadence": "daily",
            "hour": 9,
            "minute": 0,
            "isEnabled": \(isEnabled),
            "unattendedTrusted": true,
            "lastRunAt": \(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate)\(reasonLine)
          }
        }
        """
        return try JSONDecoder().decode(StoredRoutine.self, from: Data(json.utf8))
    }
}
