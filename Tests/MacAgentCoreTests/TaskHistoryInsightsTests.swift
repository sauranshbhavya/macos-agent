import Foundation
import Testing
@testable import MacAgentCore

/// V1's Insights summary tests, over V2's `FinishedTask`.
struct TaskHistoryInsightsTests {
    @Test
    func weeklyStatsUseCurrentMondayThroughSundayWindow() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let history = [
            finished("previous sunday", at: try date("2026-07-12T23:00:00Z"), outcome: .completed),
            finished("monday", at: try date("2026-07-13T09:00:00Z"), outcome: .completed),
            finished("tuesday", at: try date("2026-07-14T10:00:00Z"), outcome: .completed),
            finished("wednesday", at: try date("2026-07-15T11:00:00Z"), outcome: .completed),
            finished("failed wednesday", at: try date("2026-07-15T11:30:00Z"), outcome: .failed),
            finished("next monday", at: try date("2026-07-20T00:00:00Z"), outcome: .completed)
        ]

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: calendar)

        #expect(summary.weekInterval.start == (try date("2026-07-13T00:00:00Z")))
        #expect(summary.weekInterval.end == (try date("2026-07-20T00:00:00Z")))
        #expect(summary.completedThisWeek == 3)
        #expect(summary.weeklyCompletedCounts == [1, 1, 1, 0, 0, 0, 0])
        #expect(summary.completionRate == 0.75)
        #expect(summary.currentStreakDays == 4)
        #expect(summary.hasCompletedToday == true)
    }

    @Test
    func currentStreakStopsAtFirstCalendarDayGap() throws {
        let now = try date("2026-07-15T12:00:00Z")
        let history = [
            finished("today", at: try date("2026-07-15T09:00:00Z"), outcome: .completed),
            finished("monday", at: try date("2026-07-13T09:00:00Z"), outcome: .completed)
        ]

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.currentStreakDays == 1)
        #expect(summary.hasCompletedToday == true)
    }

    @Test
    func currentStreakCarriesOverDuringGracePeriodWhenTodayHasNoCompletionYet() throws {
        let now = try date("2026-07-15T12:00:00Z")
        let history = [
            finished("yesterday", at: try date("2026-07-14T09:00:00Z"), outcome: .completed),
            finished("today failed", at: try date("2026-07-15T09:00:00Z"), outcome: .failed)
        ]

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.currentStreakDays == 1)
        #expect(summary.hasCompletedToday == false)
    }

    @Test
    func currentStreakResetsToZeroAfterAFullMissedDay() throws {
        let now = try date("2026-07-15T12:00:00Z")
        let history = [finished("monday", at: try date("2026-07-13T09:00:00Z"), outcome: .completed)]

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.currentStreakDays == 0)
        #expect(summary.hasCompletedToday == false)
    }

    @Test
    func previousWeekStatsAreSeparatedForDeltaPresentation() throws {
        let now = try date("2026-07-15T12:00:00Z")
        let history = [
            finished("this monday", at: try date("2026-07-13T09:00:00Z"), outcome: .completed),
            finished("this failed", at: try date("2026-07-14T09:00:00Z"), outcome: .failed),
            finished("previous monday", at: try date("2026-07-06T09:00:00Z"), outcome: .completed),
            finished("previous cancelled", at: try date("2026-07-07T09:00:00Z"), outcome: .cancelled)
        ]

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.completedThisWeek == 1)
        #expect(summary.previousWeekCompleted == 1)
        #expect(summary.completionRate == 0.5)
        #expect(summary.previousWeekCompletionRate == 0.5)
    }

    /// A streak is a claim about the person's habit, so automation must not be able to earn one. A
    /// daily scheduled routine would otherwise guarantee a permanent streak and a permanently lit
    /// "completed today". A watcher's run is automation in the same way.
    @Test(arguments: [TaskOrigin.schedule, .watcher])
    func unattendedRunsDoNotEarnAStreakOrLightUpCompletedToday(origin: TaskOrigin) throws {
        let now = try date("2026-07-15T18:00:00Z")
        let history = (0..<5).map { dayOffset in
            finished(
                "scheduled morning routine",
                at: now.addingTimeInterval(Double(-dayOffset) * 86_400),
                outcome: .completed,
                origin: origin
            )
        }

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.currentStreakDays == 0)
        #expect(summary.hasCompletedToday == false)
        // ...while the stats that describe Sonny's output still count them.
        #expect(summary.completedThisWeek > 0)
        #expect(summary.completionRate == 1)
    }

    /// The other half: an unattended run must not break a real streak either, and a routine the
    /// person ran themselves counts as theirs.
    @Test
    func runsThePersonStartedStillEarnAStreakAlongsideScheduledOnes() throws {
        let now = try date("2026-07-15T18:00:00Z")
        var history: [FinishedTask] = []
        let personStarted: [TaskOrigin] = [.composer, .voice, .routine]
        for dayOffset in 0..<3 {
            let day = now.addingTimeInterval(Double(-dayOffset) * 86_400)
            history.append(finished("mine", at: day, outcome: .completed, origin: personStarted[dayOffset]))
            history.append(finished("scheduled", at: day, outcome: .completed, origin: .schedule))
        }

        let summary = TaskHistoryInsights.summarize(history: history, now: now, calendar: utcISOCalendar())

        #expect(summary.currentStreakDays == 3)
        #expect(summary.hasCompletedToday)
    }

    // MARK: Recently completed

    /// History arrives newest first today, but the panel must not rely on it: an oldest-first caller
    /// once got the oldest tasks under a "recent" label.
    @Test
    func recentReturnsNewestFirstEvenWhenInputIsOldestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let history = [
            finished("oldest", at: base, outcome: .completed),
            finished("middle", at: base.addingTimeInterval(3_600), outcome: .completed),
            finished("newest", at: base.addingTimeInterval(7_200), outcome: .completed)
        ]

        #expect(RecentCompletedTasks.recent(from: history, limit: 2).map(\.goal) == ["newest", "middle"])
    }

    @Test
    func recentExcludesFailedAndCancelledTasksEvenWhenMoreRecentThanCompletedOnes() throws {
        let history = [
            finished("failed most recent", at: try date("2026-07-15T09:00:00Z"), outcome: .failed),
            finished("cancelled", at: try date("2026-07-14T09:00:00Z"), outcome: .cancelled),
            finished("completed a", at: try date("2026-07-13T09:00:00Z"), outcome: .completed),
            finished("completed b", at: try date("2026-07-12T09:00:00Z"), outcome: .completed)
        ]

        #expect(RecentCompletedTasks.recent(from: history, limit: 6).map(\.goal) == ["completed a", "completed b"])
    }

    @Test
    func recentRespectsTheLimitAfterFiltering() throws {
        let at = try date("2026-07-15T09:00:00Z")
        let history = (0..<10).map { finished("completed \($0)", at: at, outcome: .completed) }

        #expect(RecentCompletedTasks.recent(from: history, limit: 3).count == 3)
        #expect(RecentCompletedTasks.recent(from: [], limit: 6).isEmpty)
    }

    // MARK: Helpers

    private func finished(
        _ goal: String,
        at finishedAt: Date,
        outcome: FinishedTask.Outcome,
        origin: TaskOrigin = .composer
    ) -> FinishedTask {
        let snapshot = TaskSnapshot(
            id: TaskID(),
            goal: goal,
            origin: origin,
            isPrivate: false,
            phase: .completed(summary: "Done."),
            progress: nil,
            actions: []
        )
        var task = FinishedTask(snapshot: snapshot, finishedAt: finishedAt)
        task.outcome = outcome
        return task
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
