import Foundation
import Testing
@testable import MacAgentCore

/// Branch 10 checkpoint 4. The Routines row's yellow badge, and the schedule text under each name.
@Suite
struct RoutineStreakTests {
    /// The wireframe (`11-MainAppRoutines.svg`) shows 12 for a daily routine, 4 for a weekly one
    /// and 3 for a monthly one. Those numbers only make sense if a streak counts *occurrences*
    /// rather than calendar days — a day streak would pin every weekly routine at 1 forever.
    @Test
    func streakCountsOccurrencesNotDaysSoWeeklyAndMonthlyRoutinesCanHaveOne() throws {
        let calendar = try easternCalendar()
        let now = try date(2026, 7, 15, 12, 0, calendar)

        let weekly = routine(
            schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 4, isEnabled: true),
            runDates: [
                try date(2026, 7, 15, 9, 0, calendar),
                try date(2026, 7, 8, 9, 0, calendar),
                try date(2026, 7, 1, 9, 0, calendar),
                try date(2026, 6, 24, 9, 0, calendar),
            ]
        )
        #expect(RoutineStreak.current(for: weekly, now: now, calendar: calendar) == 4)

        let monthly = routine(
            schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 1, isEnabled: true),
            runDates: [
                try date(2026, 7, 1, 9, 0, calendar),
                try date(2026, 6, 1, 9, 0, calendar),
                try date(2026, 5, 1, 9, 0, calendar),
            ]
        )
        #expect(RoutineStreak.current(for: monthly, now: now, calendar: calendar) == 3)
    }

    @Test
    func aGapBreaksTheStreakAtTheMostRecentMissedOccurrence() throws {
        let calendar = try easternCalendar()
        let now = try date(2026, 7, 15, 12, 0, calendar)
        let daily = routine(
            schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true),
            runDates: [
                try date(2026, 7, 15, 9, 0, calendar),
                try date(2026, 7, 14, 9, 0, calendar),
                // 13 July missing.
                try date(2026, 7, 12, 9, 0, calendar),
                try date(2026, 7, 11, 9, 0, calendar),
            ]
        )

        #expect(RoutineStreak.current(for: daily, now: now, calendar: calendar) == 2)
    }

    /// Before the day's run has happened, the streak must not read 0 — that says "you lost it"
    /// when the truth is "it hasn't run yet". The pending occurrence is skipped while it is still
    /// inside its catch-up window.
    @Test
    func anOccurrenceThatHasNotRunYetDoesNotBreakTheStreak() throws {
        let calendar = try easternCalendar()
        let daily = routine(
            schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true),
            runDates: [
                try date(2026, 7, 14, 9, 0, calendar),
                try date(2026, 7, 13, 9, 0, calendar),
            ]
        )

        // 09:30, half an hour after today's occurrence and well inside the 3-hour window.
        let pending = try date(2026, 7, 15, 9, 30, calendar)
        #expect(RoutineStreak.current(for: daily, now: pending, calendar: calendar) == 2)

        // Past the window, today counts as genuinely missed and the streak is gone.
        let missed = try date(2026, 7, 15, 20, 0, calendar)
        #expect(RoutineStreak.current(for: daily, now: missed, calendar: calendar) == 0)
    }

    @Test
    func anUnscheduledOrNeverRunRoutineHasNoStreak() throws {
        let calendar = try easternCalendar()
        let now = try date(2026, 7, 15, 12, 0, calendar)

        #expect(
            RoutineStreak.current(
                for: StoredRoutine(name: "Morning", steps: [.fixture]),
                now: now,
                calendar: calendar
            ) == 0
        )
        #expect(
            RoutineStreak.current(
                for: routine(
                    schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true),
                    runDates: []
                ),
                now: now,
                calendar: calendar
            ) == 0
        )
    }

    // MARK: - Row text

    @Test
    func cadenceLabelsMatchTheWireframesThreeForms() throws {
        let calendar = try easternCalendar()

        #expect(
            RoutineScheduleDisplay.cadenceLabel(
                for: RoutineSchedule(cadence: .daily, hour: 9, minute: 0),
                calendar: calendar
            ) == "Daily"
        )
        // weekday 2 == Monday under Calendar's Sunday == 1 convention.
        #expect(
            RoutineScheduleDisplay.cadenceLabel(
                for: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 2),
                calendar: calendar
            ) == "Weekly · Mon"
        )
        #expect(
            RoutineScheduleDisplay.cadenceLabel(
                for: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 1),
                calendar: calendar
            ) == "Monthly · 1st"
        )
    }

    @Test
    func nextRunTextUsesTodayForTheSameDayAndADateOtherwise() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)

        // Before today's 09:00 — the next run is later today.
        let earlyText = try #require(
            RoutineScheduleDisplay.nextRunText(
                for: schedule,
                now: try date(2026, 7, 15, 7, 0, calendar),
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            )
        )
        #expect(earlyText.hasPrefix("Today, "))
        #expect(earlyText.contains("9"))

        // After it — the next run is tomorrow, so a date rather than "Today".
        let laterText = try #require(
            RoutineScheduleDisplay.nextRunText(
                for: schedule,
                now: try date(2026, 7, 15, 10, 0, calendar),
                calendar: calendar,
                locale: Locale(identifier: "en_US")
            )
        )
        #expect(laterText.hasPrefix("Today") == false)
        #expect(laterText.contains("16"))
    }

    /// A saved-but-disabled schedule shows no next-run text — there is no next run.
    @Test
    func aDisabledScheduleHasNoNextRunText() throws {
        let calendar = try easternCalendar()

        #expect(
            RoutineScheduleDisplay.nextRunText(
                for: RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false),
                now: try date(2026, 7, 15, 7, 0, calendar),
                calendar: calendar
            ) == nil
        )
    }

    // MARK: - Grouping

    /// Sections follow the wireframe's own order, empty ones are dropped, and unscheduled routines
    /// get their own heading last rather than disappearing.
    @Test
    func routinesGroupByCadenceInWireframeOrderWithUnscheduledLast() throws {
        let calendar = try easternCalendar()
        _ = calendar
        let sections = RoutineGrouping.groupedByCadence(routines: [
            StoredRoutine(name: "Zeta", steps: [.fixture], schedule: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 1)),
            StoredRoutine(name: "Alpha", steps: [.fixture], schedule: RoutineSchedule(cadence: .daily, hour: 9, minute: 0)),
            StoredRoutine(name: "Loose", steps: [.fixture]),
            StoredRoutine(name: "Beta", steps: [.fixture], schedule: RoutineSchedule(cadence: .daily, hour: 7, minute: 0)),
        ])

        #expect(sections.map(\.title) == ["Daily", "Monthly", "Unscheduled"])
        #expect(sections[0].routines.map(\.name) == ["Alpha", "Beta"])
        #expect(sections[2].routines.map(\.name) == ["Loose"])
    }

    /// A disabled schedule still groups under its cadence. Dropping it into "Unscheduled" would
    /// make flipping the toggle off look like it deleted the schedule.
    @Test
    func aDisabledScheduleStillGroupsUnderItsCadence() {
        let sections = RoutineGrouping.groupedByCadence(routines: [
            StoredRoutine(
                name: "Paused",
                steps: [.fixture],
                schedule: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 2, isEnabled: false)
            )
        ])

        #expect(sections.map(\.title) == ["Weekly"])
    }

    // MARK: - Helpers

    private func routine(schedule: RoutineSchedule, runDates: [Date]) -> StoredRoutine {
        StoredRoutine(name: "Morning", steps: [.fixture], schedule: schedule, recentRunDates: runDates.sorted())
    }

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
