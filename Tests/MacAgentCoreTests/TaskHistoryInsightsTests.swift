import Foundation
import Testing
@testable import MacAgentCore

struct TaskHistoryInsightsTests {
    @Test
    func weeklyStatsUseCurrentMondayThroughSundayWindow() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("previous sunday", completedAt: try date("2026-07-12T23:00:00Z"), outcome: .completed),
            record("monday", completedAt: try date("2026-07-13T09:00:00Z"), duration: 60, outcome: .completed),
            record("tuesday", completedAt: try date("2026-07-14T10:00:00Z"), duration: 120, outcome: .completed),
            record("wednesday", completedAt: try date("2026-07-15T11:00:00Z"), duration: 180, outcome: .completed),
            record("failed wednesday", completedAt: try date("2026-07-15T11:30:00Z"), duration: 300, outcome: .failed),
            record("next monday", completedAt: try date("2026-07-20T00:00:00Z"), outcome: .completed)
        ]

        let summary = TaskHistoryInsights.summarize(records: records, now: now, calendar: calendar)
        let expectedWeekStart = try date("2026-07-13T00:00:00Z")
        let expectedWeekEnd = try date("2026-07-20T00:00:00Z")

        #expect(summary.weekInterval.start == expectedWeekStart)
        #expect(summary.weekInterval.end == expectedWeekEnd)
        #expect(summary.completedThisWeek == 3)
        #expect(summary.weeklyCompletedCounts == [1, 1, 1, 0, 0, 0, 0])
        #expect(summary.completionRate == 0.75)
        #expect(summary.averageCompletedCycleTime == 120)
        #expect(summary.currentStreakDays == 4)
        #expect(summary.hasCompletedToday == true)
    }

    @Test
    func currentStreakStopsAtFirstCalendarDayGap() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("today", completedAt: try date("2026-07-15T09:00:00Z"), outcome: .completed),
            record("monday", completedAt: try date("2026-07-13T09:00:00Z"), outcome: .completed)
        ]

        let summary = TaskHistoryInsights.summarize(records: records, now: now, calendar: calendar)

        #expect(summary.currentStreakDays == 1)
        #expect(summary.hasCompletedToday == true)
    }

    @Test
    func currentStreakCarriesOverDuringGracePeriodWhenTodayHasNoCompletionYet() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("yesterday", completedAt: try date("2026-07-14T09:00:00Z"), outcome: .completed),
            record("today failed", completedAt: try date("2026-07-15T09:00:00Z"), outcome: .failed)
        ]

        let summary = TaskHistoryInsights.summarize(records: records, now: now, calendar: calendar)

        #expect(summary.currentStreakDays == 1)
        #expect(summary.hasCompletedToday == false)
    }

    @Test
    func currentStreakResetsToZeroAfterAFullMissedDay() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("monday", completedAt: try date("2026-07-13T09:00:00Z"), outcome: .completed)
        ]

        let summary = TaskHistoryInsights.summarize(records: records, now: now, calendar: calendar)

        #expect(summary.currentStreakDays == 0)
        #expect(summary.hasCompletedToday == false)
    }

    @Test
    func previousWeekStatsAreSeparatedForDeltaPresentation() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("this monday", completedAt: try date("2026-07-13T09:00:00Z"), duration: 120, outcome: .completed),
            record("this failed", completedAt: try date("2026-07-14T09:00:00Z"), outcome: .failed),
            record("previous monday", completedAt: try date("2026-07-06T09:00:00Z"), duration: 240, outcome: .completed),
            record("previous canceled", completedAt: try date("2026-07-07T09:00:00Z"), outcome: .canceled)
        ]

        let summary = TaskHistoryInsights.summarize(records: records, now: now, calendar: calendar)

        #expect(summary.completedThisWeek == 1)
        #expect(summary.previousWeekCompleted == 1)
        #expect(summary.completionRate == 0.5)
        #expect(summary.previousWeekCompletionRate == 0.5)
        #expect(summary.averageCompletedCycleTime == 120)
        #expect(summary.previousWeekAverageCompletedCycleTime == 240)
    }

    private func record(
        _ command: String,
        completedAt: Date,
        duration: TimeInterval = 60,
        outcome: PriorTaskOutcomeStatus
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-duration),
            completedAt: completedAt,
            outcomeStatus: outcome
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func utcISOCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
