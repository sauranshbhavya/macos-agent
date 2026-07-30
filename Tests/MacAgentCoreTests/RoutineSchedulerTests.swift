import Foundation
import Testing
@testable import MacAgentCore

/// Branch 10 checkpoint 3 — the pure date math only. No timers, no execution.
///
/// Everything here runs on a fixed `America/New_York` calendar rather than `Calendar.current`, so
/// the suite means the same thing on any machine and the DST cases are real rather than incidental.
/// 2026 US DST: spring forward Sunday 8 March (02:00 → 03:00), fall back Sunday 1 November
/// (01:00 happens twice).
@Suite
struct RoutineSchedulerTests {
    // MARK: - Finding the most recent occurrence

    @Test
    func dailyBeforeTheRunTimeResolvesToYesterdaysOccurrence() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)
        let now = try date(2026, 7, 15, 7, 30, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence == (try date(2026, 7, 14, 9, 0, calendar)))
    }

    @Test
    func dailyAfterTheRunTimeResolvesToTodaysOccurrence() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)
        let now = try date(2026, 7, 15, 10, 30, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence == (try date(2026, 7, 15, 9, 0, calendar)))
    }

    /// Exactly at the scheduled minute counts as that occurrence having arrived, not as still
    /// waiting for it — otherwise a tick landing precisely on 09:00:00 would resolve to yesterday
    /// and fire a day-old catch-up instead of today's run.
    @Test
    func dailyExactlyAtTheRunTimeResolvesToTodaysOccurrence() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)
        let now = try date(2026, 7, 15, 9, 0, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence == now)
    }

    @Test
    func weeklyResolvesToTheMostRecentMatchingWeekday() throws {
        let calendar = try easternCalendar()
        // weekday 4 == Wednesday under Calendar's Sunday == 1 convention.
        let schedule = RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 4, isEnabled: true)

        // Friday 17 July 2026 → back to Wednesday the 15th.
        let friday = try date(2026, 7, 17, 12, 0, calendar)
        #expect(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: friday, calendar: calendar)
                == (try date(2026, 7, 15, 9, 0, calendar))
        )

        // Wednesday before the hour → back a full week, not to today.
        let wednesdayEarly = try date(2026, 7, 15, 8, 0, calendar)
        #expect(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: wednesdayEarly, calendar: calendar)
                == (try date(2026, 7, 8, 9, 0, calendar))
        )
    }

    /// "Run on the 31st" is a legitimate ask that CP2 deliberately accepts at save time. A 30-day
    /// month has no 31st, so it clamps to the last day rather than skipping the month entirely —
    /// picking day 31 reads as "end of month", and silently not running in April, June, September
    /// and November would be the more surprising behavior.
    @Test
    func monthlyClampsToTheLastDayOfShortMonthsRatherThanSkippingThem() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 31, isEnabled: true)

        // June has 30 days.
        #expect(
            RoutineScheduler.mostRecentOccurrence(
                of: schedule,
                atOrBefore: try date(2026, 6, 30, 23, 0, calendar),
                calendar: calendar
            ) == (try date(2026, 6, 30, 9, 0, calendar))
        )

        // Non-leap February has 28.
        #expect(
            RoutineScheduler.mostRecentOccurrence(
                of: schedule,
                atOrBefore: try date(2026, 2, 28, 23, 0, calendar),
                calendar: calendar
            ) == (try date(2026, 2, 28, 9, 0, calendar))
        )
    }

    @Test
    func monthlyClampsToTheTwentyNinthInALeapFebruary() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 31, isEnabled: true)

        let occurrence = RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: try date(2028, 2, 29, 23, 0, calendar),
            calendar: calendar
        )

        #expect(occurrence == (try date(2028, 2, 29, 9, 0, calendar)))
    }

    @Test
    func monthlyBeforeTheDayResolvesIntoThePreviousMonth() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 15, isEnabled: true)

        let occurrence = RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: try date(2026, 7, 3, 12, 0, calendar),
            calendar: calendar
        )

        #expect(occurrence == (try date(2026, 6, 15, 9, 0, calendar)))
    }

    // MARK: - DST

    /// 02:30 does not exist on 8 March 2026 in New York — the clock jumps 02:00 → 03:00. The
    /// occurrence must still resolve to a real instant on that day rather than returning nil and
    /// silently skipping the routine, or vanishing into the previous day.
    @Test
    func springForwardDoesNotLoseAnOccurrenceWhoseWallClockTimeDoesNotExist() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 2, minute: 30, isEnabled: true)
        let now = try date(2026, 3, 8, 12, 0, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        // Whatever instant the calendar picks, it must be on 8 March and at or before `now`.
        #expect(occurrence <= now)
        #expect(calendar.isDate(occurrence, inSameDayAs: now))
    }

    /// 01:30 happens twice on 1 November 2026. Either instant is defensible; what matters is that
    /// exactly one occurrence is produced and it is that day's, so the routine runs once and not
    /// twice.
    @Test
    func fallBackProducesASingleOccurrenceForTheRepeatedHour() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 1, minute: 30, isEnabled: true)
        let now = try date(2026, 11, 1, 12, 0, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence <= now)
        #expect(calendar.isDate(occurrence, inSameDayAs: now))

        // And it must not still be considered outstanding once it has been handled.
        var handled = schedule
        handled.lastRunAt = occurrence
        #expect(
            RoutineScheduler.decision(for: handled, now: now, calendar: calendar) == .notDue
        )
    }

    /// A daily routine must produce exactly one occurrence per calendar day across a DST boundary —
    /// the 23-hour spring-forward day is where a naive "subtract 86,400 seconds" implementation
    /// silently skips or double-counts a day.
    @Test
    func dailyOccurrencesStayOncePerCalendarDayAcrossSpringForward() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)

        let saturday = RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: try date(2026, 3, 7, 12, 0, calendar),
            calendar: calendar
        )
        let sunday = RoutineScheduler.mostRecentOccurrence(
            of: schedule,
            atOrBefore: try date(2026, 3, 8, 12, 0, calendar),
            calendar: calendar
        )

        #expect(saturday == (try date(2026, 3, 7, 9, 0, calendar)))
        #expect(sunday == (try date(2026, 3, 8, 9, 0, calendar)))
        // 23 hours apart in real time, one calendar day apart in wall-clock terms.
        let gap = try #require(sunday).timeIntervalSince(try #require(saturday))
        #expect(gap == 23 * 60 * 60)
    }

    /// The case that actually separates walking calendar days from subtracting 86,400 seconds.
    ///
    /// The obvious DST assertions do not: resolving "yesterday" then setting the hour re-normalizes
    /// to that day, so an hour of drift is invisible — unless the drift crosses midnight. Just
    /// after midnight on the day following spring forward, a fixed-seconds step lands on 23:30 two
    /// days back and skips the intervening day's occurrence entirely. That is the real failure
    /// mode: a routine that silently does not run on the day the clocks change.
    @Test
    func steppingBackADayJustAfterMidnightFollowingSpringForwardDoesNotSkipADay() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)
        // Spring forward was Sunday 8 March 2026; this is 00:30 on Monday the 9th, before that
        // day's 09:00 has arrived, so the answer must be Sunday's occurrence.
        let now = try date(2026, 3, 9, 0, 30, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence == (try date(2026, 3, 8, 9, 0, calendar)))
    }

    /// The same trap on the other side: the fall-back day is 25 hours long, so fixed-seconds
    /// arithmetic lands short and can resolve to the same day it started from.
    @Test
    func steppingBackADayJustAfterMidnightFollowingFallBackDoesNotRepeatADay() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)
        // Fall back was Sunday 1 November 2026; this is 00:30 on Monday the 2nd.
        let now = try date(2026, 11, 2, 0, 30, calendar)

        let occurrence = try #require(
            RoutineScheduler.mostRecentOccurrence(of: schedule, atOrBefore: now, calendar: calendar)
        )

        #expect(occurrence == (try date(2026, 11, 1, 9, 0, calendar)))
    }

    // MARK: - Decisions

    @Test
    func aDisabledScheduleIsNeverDue() throws {
        let calendar = try easternCalendar()
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.lastRunAt = try date(2026, 7, 1, 9, 0, calendar)

        let decision = RoutineScheduler.decision(
            for: schedule,
            now: try date(2026, 7, 15, 9, 30, calendar),
            calendar: calendar
        )

        #expect(decision == .notDue)
    }

    /// The CP2 anchor invariant, now proven end to end: enabling a 9am daily routine at 3pm must
    /// not read as "this morning was missed". Without the anchor, turning scheduling on would
    /// itself trigger an unattended run.
    @Test
    func enablingAtAnOffHourDoesNotImmediatelyFireACatchUp() throws {
        let calendar = try easternCalendar()
        let threePM = try date(2026, 7, 15, 15, 0, calendar)
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.setEnabled(true, now: threePM)

        #expect(RoutineScheduler.decision(for: schedule, now: threePM, calendar: calendar) == .notDue)

        // And still nothing that evening — the next real occurrence is tomorrow at 09:00.
        let elevenPM = try date(2026, 7, 15, 23, 0, calendar)
        #expect(RoutineScheduler.decision(for: schedule, now: elevenPM, calendar: calendar) == .notDue)
    }

    @Test
    func anOccurrenceInsideTheCatchUpWindowIsDue() throws {
        let calendar = try easternCalendar()
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))
        let occurrence = try date(2026, 7, 15, 9, 0, calendar)

        let decision = RoutineScheduler.decision(
            for: schedule,
            now: try date(2026, 7, 15, 11, 0, calendar),
            calendar: calendar
        )

        #expect(decision == .due(occurrence: occurrence))
    }

    /// The window boundary in both directions. Daily tolerates 3 hours: a morning routine at 11am
    /// is fine, at 11pm it is not, and "the rest of the day" was rejected precisely because it
    /// would allow the latter.
    @Test
    func theCatchUpWindowIsInclusiveAtItsEdgeAndMissedJustPastIt() throws {
        let calendar = try easternCalendar()
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))
        let occurrence = try date(2026, 7, 15, 9, 0, calendar)

        let atEdge = occurrence.addingTimeInterval(RoutineCadence.daily.catchUpWindow)
        #expect(
            RoutineScheduler.decision(for: schedule, now: atEdge, calendar: calendar)
                == .due(occurrence: occurrence)
        )

        let justPast = atEdge.addingTimeInterval(1)
        #expect(
            RoutineScheduler.decision(for: schedule, now: justPast, calendar: calendar)
                == .missed(occurrence: occurrence)
        )
    }

    /// The laptop-shut-all-day case: the occurrence is real but far too stale to run now.
    @Test
    func anOccurrenceLongPastTheWindowIsMissedRatherThanDue() throws {
        let calendar = try easternCalendar()
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))

        let decision = RoutineScheduler.decision(
            for: schedule,
            now: try date(2026, 7, 15, 23, 0, calendar),
            calendar: calendar
        )

        #expect(decision == .missed(occurrence: try date(2026, 7, 15, 9, 0, calendar)))
    }

    /// Handling an occurrence — whether it ran or was skipped — must stop it being reconsidered on
    /// the next tick, or the timer would retry a tier-3 routine or re-report a missed one every
    /// 60 seconds forever.
    @Test
    func anAlreadyHandledOccurrenceIsNotDueAgain() throws {
        let calendar = try easternCalendar()
        var schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        schedule.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))
        let occurrence = try date(2026, 7, 15, 9, 0, calendar)
        let now = try date(2026, 7, 15, 10, 0, calendar)
        #expect(RoutineScheduler.decision(for: schedule, now: now, calendar: calendar) == .due(occurrence: occurrence))

        schedule.lastRunAt = occurrence

        #expect(RoutineScheduler.decision(for: schedule, now: now, calendar: calendar) == .notDue)
        // ...and tomorrow's occurrence is picked up normally rather than being swallowed too.
        let tomorrow = try date(2026, 7, 16, 9, 30, calendar)
        #expect(
            RoutineScheduler.decision(for: schedule, now: tomorrow, calendar: calendar)
                == .due(occurrence: try date(2026, 7, 16, 9, 0, calendar))
        )
    }

    /// A hand-edited or otherwise malformed file could leave an enabled schedule with no baseline.
    /// Treating that as "no baseline" must not resurrect every historical occurrence — the window
    /// bound is what keeps it to at most one recent run.
    @Test
    func anEnabledScheduleWithNoBaselineIsStillWindowBounded() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true, lastRunAt: nil)

        #expect(
            RoutineScheduler.decision(
                for: schedule,
                now: try date(2026, 7, 15, 10, 0, calendar),
                calendar: calendar
            ) == .due(occurrence: try date(2026, 7, 15, 9, 0, calendar))
        )
        #expect(
            RoutineScheduler.decision(
                for: schedule,
                now: try date(2026, 7, 15, 23, 0, calendar),
                calendar: calendar
            ) == .missed(occurrence: try date(2026, 7, 15, 9, 0, calendar))
        )
    }

    // MARK: - Selecting across many routines

    @Test
    func dueRoutinesReturnsOnlyTheEnabledOutstandingOnes() throws {
        let calendar = try easternCalendar()
        let anchoredYesterday = try date(2026, 7, 14, 12, 0, calendar)
        var enabled = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        enabled.setEnabled(true, now: anchoredYesterday)
        var alreadyRan = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        alreadyRan.setEnabled(true, now: anchoredYesterday)
        alreadyRan.lastRunAt = try date(2026, 7, 15, 9, 0, calendar)
        var disabled = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        disabled.lastRunAt = anchoredYesterday

        let routines = [
            StoredRoutine(name: "Due", steps: [.fixture], schedule: enabled),
            StoredRoutine(name: "Already ran", steps: [.fixture], schedule: alreadyRan),
            StoredRoutine(name: "Disabled", steps: [.fixture], schedule: disabled),
            StoredRoutine(name: "Unscheduled", steps: [.fixture]),
        ]

        let outstanding = RoutineScheduler.outstanding(
            in: routines,
            now: try date(2026, 7, 15, 10, 0, calendar),
            calendar: calendar
        )

        #expect(outstanding.map(\.routine.name) == ["Due"])
        #expect(outstanding.first?.decision == .due(occurrence: try date(2026, 7, 15, 9, 0, calendar)))
    }

    /// Ordering is by occurrence, oldest first, so a backlog is worked through in the order it
    /// actually happened rather than in whatever order the store's dictionary iterates — which is
    /// not stable between loads.
    @Test
    func outstandingRoutinesComeBackOldestOccurrenceFirst() throws {
        let calendar = try easternCalendar()
        var earlier = RoutineSchedule(cadence: .daily, hour: 7, minute: 0)
        earlier.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))
        var later = RoutineSchedule(cadence: .daily, hour: 9, minute: 0)
        later.setEnabled(true, now: try date(2026, 7, 14, 12, 0, calendar))

        let outstanding = RoutineScheduler.outstanding(
            in: [
                StoredRoutine(name: "Nine", steps: [.fixture], schedule: later),
                StoredRoutine(name: "Seven", steps: [.fixture], schedule: earlier),
            ],
            now: try date(2026, 7, 15, 9, 30, calendar),
            calendar: calendar
        )

        #expect(outstanding.map(\.routine.name) == ["Seven", "Nine"])
    }

    // MARK: - Helpers

    private func easternCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        _ calendar: Calendar
    ) throws -> Date {
        try #require(
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))
        )
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
