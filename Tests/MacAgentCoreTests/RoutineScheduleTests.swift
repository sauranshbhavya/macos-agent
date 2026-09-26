import Foundation
import Testing
@testable import MacAgentCore

/// Branch 10 checkpoint 2 — the schedule data model only. Nothing fires yet; the scheduler that
/// reads these fields lands in checkpoint 3.
@Suite
struct RoutineScheduleTests {
    // MARK: - Legacy decode



    /// SONNY-31 added `pausedReason`, so the same legacy question applies to it: a routines.json
    /// written before this field existed has no key for it, and a non-Optional property would have
    /// thrown `keyNotFound` on every load rather than defaulting. Written as a schedule *with*
    /// every other key present, because the field this pins was added to `RoutineSchedule` — the
    /// no-schedule-at-all case is already covered above and would not exercise this decode path.
    @Test
    func scheduleJSONWrittenBeforePausingStillDecodes() throws {
        let legacy = """
        {
          "cadence": "daily",
          "hour": 9,
          "minute": 0,
          "isEnabled": true,
          "unattendedTrusted": true
        }
        """

        let schedule = try JSONDecoder().decode(RoutineSchedule.self, from: Data(legacy.utf8))

        #expect(schedule.pausedReason == nil)
        #expect(schedule.isEnabled)
        #expect(schedule.unattendedTrusted)
        #expect(schedule.cadence == .daily)
    }


    // MARK: - Pausing (SONNY-31)

    /// `pause` is not `setEnabled(false,)`: the field exists precisely to tell "the user switched
    /// this off" apart from "Sonny switched this off, and here is why". It also must not disturb
    /// the catch-up baseline — the occurrence that triggered the pause was already resolved by the
    /// caller, and re-anchoring happens on the way back on.
    @Test
    func pausingDisablesTheScheduleRecordsWhyAndLeavesTheBaselineAlone() {
        let anchored = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true, lastRunAt: anchored)

        schedule.pause(reason: "Snippet trigger ;sig already exists and would be replaced.")

        #expect(schedule.isEnabled == false)
        #expect(schedule.pausedReason == "Snippet trigger ;sig already exists and would be replaced.")
        #expect(schedule.lastRunAt == anchored)
    }

    /// The user's own disable stays anonymous. If this ever recorded a reason, every manually
    /// switched-off routine would grow a "Sonny paused this" caption it never earned.
    @Test
    func theUsersOwnDisableRecordsNoPauseReason() {
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)

        schedule.setEnabled(false, now: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(schedule.isEnabled == false)
        #expect(schedule.pausedReason == nil)
    }

    /// Re-enabling is the acknowledgement, so it clears the reason *and* re-anchors — a routine
    /// paused for a fortnight must not treat that fortnight as a backlog the moment it comes back.
    @Test
    func reEnablingAPausedScheduleClearsTheReasonAndReAnchorsTheBaseline() {
        let anchored = Date(timeIntervalSince1970: 1_700_000_000)
        let resumedAt = anchored.addingTimeInterval(14 * 24 * 60 * 60)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true, lastRunAt: anchored)
        schedule.pause(reason: "Zip output already exists at /tmp/a.zip.")

        schedule.setEnabled(true, now: resumedAt)

        #expect(schedule.isEnabled)
        #expect(schedule.pausedReason == nil)
        #expect(schedule.lastRunAt == resumedAt)
    }

    /// PR #27 review finding F9. `newlyCreated` assigns `pausedReason` *before* calling
    /// `setEnabled`, so the one rule about clearing a pause lives in `setEnabled` and nowhere else.
    /// That ordering was asserted as load-bearing in three places and pinned by none: moving the
    /// assignment after the `setEnabled` call left the whole suite green, because the only
    /// production caller that passes a reason (`commitScheduleDraft`) also passes the existing
    /// schedule's `isEnabled`, and a schedule carrying a reason is always disabled — so the
    /// enabled-plus-reason combination never reaches `newlyCreated` through the UI at all.
    ///
    /// Pinned here, at the level the ordering actually lives, rather than through a view-model path
    /// that cannot reach it. Nothing is wrong with the defensive ordering; it just had no test.
    @Test
    func newlyCreatedClearsAPassedPauseReasonWhenItBuildsAnEnabledSchedule() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let enabled = RoutineSchedule.newlyCreated(
            cadence: .daily,
            hour: 9,
            minute: 0,
            isEnabled: true,
            pausedReason: "Snippet trigger ;sig already exists and would be replaced.",
            now: now
        )
        // Enabling clears the pause, whoever asks for it and by whichever door.
        #expect(enabled.isEnabled)
        #expect(enabled.pausedReason == nil)
        #expect(enabled.lastRunAt == now)

        let stillPaused = RoutineSchedule.newlyCreated(
            cadence: .daily,
            hour: 9,
            minute: 0,
            isEnabled: false,
            pausedReason: "Snippet trigger ;sig already exists and would be replaced.",
            now: now
        )
        // ...and staying disabled keeps it, which is what makes a schedule edit non-destructive.
        #expect(stillPaused.isEnabled == false)
        #expect(stillPaused.pausedReason == "Snippet trigger ;sig already exists and would be replaced.")
    }



    // MARK: - The catch-up anchor

    /// The correctness requirement behind `lastRunAt`, not a nicety. Enabling a 9am daily routine
    /// at 3pm must not read as "this morning's 9am run was missed" — otherwise turning scheduling
    /// on is itself the trigger for an unattended run, which is exactly the surprise the whole
    /// per-routine opt-in exists to prevent. The anchor starts at the moment of enabling.
    @Test
    func enablingScheduleAnchorsTheCatchUpBaselineToTheMomentItWasEnabled() {
        let threePM = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        #expect(schedule.lastRunAt == nil)

        schedule.setEnabled(true, now: threePM)

        #expect(schedule.isEnabled)
        #expect(schedule.lastRunAt == threePM)
    }

    /// Re-enabling re-anchors: a routine disabled for three weeks and switched back on must not
    /// treat those three weeks as a backlog of missed occurrences.
    @Test
    func reEnablingReAnchorsRatherThanKeepingTheStaleBaseline() {
        let firstEnable = Date(timeIntervalSince1970: 1_700_000_000)
        let reEnable = firstEnable.addingTimeInterval(21 * 24 * 60 * 60)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)

        schedule.setEnabled(true, now: firstEnable)
        schedule.setEnabled(false, now: firstEnable.addingTimeInterval(60))
        schedule.setEnabled(true, now: reEnable)

        #expect(schedule.lastRunAt == reEnable)
    }

    /// Only an off → on transition re-anchors. Calling `setEnabled(true)` on an already-enabled
    /// schedule (an idempotent UI write, a re-save from some other edit) must leave the baseline
    /// alone, or every incidental save would silently erase the pending catch-up window.
    @Test
    func enablingAnAlreadyEnabledScheduleLeavesTheBaselineAlone() {
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        schedule.setEnabled(true, now: enabledAt)

        schedule.setEnabled(true, now: enabledAt.addingTimeInterval(9 * 60 * 60))

        #expect(schedule.lastRunAt == enabledAt)
    }

    /// Disabling keeps the old anchor rather than clearing it — clearing would make a
    /// disable/re-enable pair indistinguishable from a never-enabled schedule, and `setEnabled`'s
    /// re-anchor on the way back on is what actually protects the catch-up window.
    @Test
    func disablingDoesNotClearTheBaseline() {
        let enabledAt = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        schedule.setEnabled(true, now: enabledAt)

        schedule.setEnabled(false, now: enabledAt.addingTimeInterval(3_600))

        #expect(schedule.lastRunAt == enabledAt)
    }

    // MARK: - Creation

    /// The trap the creation path exists to avoid. `init` leaves `lastRunAt` nil, and
    /// `RoutineScheduler.decision` reads a nil baseline as `.distantPast` — so a daily 9am schedule
    /// built with `isEnabled: true` at 3pm resolves *this morning's* 09:00 as outstanding and
    /// either fires an unattended run or reports a missed one, for a schedule seconds old.
    @Test
    func aFreshlyCreatedEnabledScheduleHasNothingOutstanding() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let threePM = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 15, minute: 0))
        )

        let created = RoutineSchedule.newlyCreated(cadence: .daily, hour: 9, minute: 0, now: threePM)

        #expect(created.isEnabled)
        #expect(created.lastRunAt == threePM)
        #expect(RoutineScheduler.decision(for: created, now: threePM, calendar: calendar) == .notDue)
        // Still nothing that evening — the first real run is tomorrow morning.
        let elevenPM = threePM.addingTimeInterval(8 * 60 * 60)
        #expect(RoutineScheduler.decision(for: created, now: elevenPM, calendar: calendar) == .notDue)
        // And it does fire on the next real occurrence rather than being suppressed forever.
        let tomorrow = threePM.addingTimeInterval(19 * 60 * 60)
        #expect(RoutineScheduler.decision(for: created, now: tomorrow, calendar: calendar) != .notDue)
    }

    /// Creating one disabled leaves no baseline, which is correct — a disabled schedule has no
    /// outstanding occurrence, and enabling it later is what anchors it.
    @Test
    func creatingADisabledScheduleLeavesTheBaselineUnsetUntilItIsEnabled() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        var created = RoutineSchedule.newlyCreated(
            cadence: .daily,
            hour: 9,
            minute: 0,
            isEnabled: false,
            now: now
        )
        #expect(created.lastRunAt == nil)

        let later = now.addingTimeInterval(3_600)
        created.setEnabled(true, now: later)
        #expect(created.lastRunAt == later)
    }


    // MARK: - Catch-up windows

    /// Bounded by duration, deliberately not "the rest of the scheduled period": for a daily 9am
    /// routine the latter would still allow a catch-up fire at 11:59pm, which is the same
    /// unexpected-unattended-firing problem that ruled out unbounded catch-up in the first place.
    /// A morning routine at 11am is fine; at 11pm it is not.
    @Test
    func catchUpWindowsAreBoundedByDurationAndGrowWithCadence() {
        #expect(RoutineCadence.daily.catchUpWindow == 3 * 60 * 60)
        #expect(RoutineCadence.weekly.catchUpWindow == 24 * 60 * 60)
        #expect(RoutineCadence.monthly.catchUpWindow == 3 * 24 * 60 * 60)

        // The ordering is the actual invariant — a longer cadence tolerates a longer delay before
        // a catch-up stops making sense in the context it was scheduled for.
        let windows = RoutineCadence.allCases.map(\.catchUpWindow)
        #expect(windows == windows.sorted())
        // No window may reach its own cadence length, or catch-up degenerates into "fire whenever".
        #expect(RoutineCadence.daily.catchUpWindow < 24 * 60 * 60)
    }

    // MARK: - Validation






    // MARK: - Run history





    // MARK: - Redefining an existing routine






    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutineScheduleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension AgentStep {
    static let fixture = AgentStep(
        id: "open",
        operation: .openApp,
        description: "Open Safari.",
        appName: "Safari"
    )
}
