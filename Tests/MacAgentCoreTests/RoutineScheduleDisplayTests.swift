import Foundation
import Testing
@testable import MacAgentCore

/// The schedule line under each routine on the Routines page: its cadence, and when it runs next.
/// These tests lived in `RoutineStreakTests`, which went with V1's streaks in phase 7, although the
/// Routines page still shows this line.
@Suite
struct RoutineScheduleDisplayTests {
    @Test
    func theCadenceReadsDailyWeeklyWithItsDayOrMonthlyWithItsDate() throws {
        let calendar = try easternCalendar()
        #expect(RoutineScheduleDisplay.cadenceLabel(for: RoutineSchedule(cadence: .daily, hour: 9, minute: 0), calendar: calendar) == "Daily")
        // Weekday 2 is Monday in Calendar's numbering, where Sunday is 1.
        #expect(RoutineScheduleDisplay.cadenceLabel(for: RoutineSchedule(cadence: .weekly, hour: 9, minute: 0, weekday: 2), calendar: calendar) == "Weekly · Mon")
        #expect(RoutineScheduleDisplay.cadenceLabel(for: RoutineSchedule(cadence: .monthly, hour: 9, minute: 0, dayOfMonth: 1), calendar: calendar) == "Monthly · 1st")
    }

    @Test
    func theNextRunSaysTodayForLaterTodayAndADateOtherwise() throws {
        let calendar = try easternCalendar()
        let schedule = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: true)

        let early = try #require(RoutineScheduleDisplay.nextRunText(for: schedule, now: try date(2026, 7, 15, 7, calendar), calendar: calendar, locale: Locale(identifier: "en_US")))
        #expect(early.hasPrefix("Today, "))
        #expect(early.contains("9"))

        let late = try #require(RoutineScheduleDisplay.nextRunText(for: schedule, now: try date(2026, 7, 15, 10, calendar), calendar: calendar, locale: Locale(identifier: "en_US")))
        #expect(!late.hasPrefix("Today"))
        #expect(late.contains("16"))
    }

    @Test
    func aScheduleThatIsOffHasNoNextRun() throws {
        let calendar = try easternCalendar()
        let off = RoutineSchedule(cadence: .daily, hour: 9, minute: 0, isEnabled: false)
        #expect(RoutineScheduleDisplay.nextRunText(for: off, now: try date(2026, 7, 15, 7, calendar), calendar: calendar) == nil)
    }

    private func easternCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: 0)))
    }
}
