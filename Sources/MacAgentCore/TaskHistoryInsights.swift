import Foundation

/// What the Insights page shows about the finished tasks on this Mac.
///
/// V1 also averaged each task's cycle time here. A V2 `FinishedTask` keeps no start time, and the
/// page never showed that figure (it was dropped from the design on 2026-07-18), so it is gone.
public struct TaskHistoryInsightsSummary: Equatable, Sendable {
    public var weekInterval: DateInterval
    public var completedThisWeek: Int
    public var completionRate: Double
    public var currentStreakDays: Int
    public var hasCompletedToday: Bool
    public var weeklyCompletedCounts: [Int]
    public var previousWeekCompleted: Int
    public var previousWeekCompletionRate: Double

    public init(
        weekInterval: DateInterval,
        completedThisWeek: Int,
        completionRate: Double,
        currentStreakDays: Int,
        hasCompletedToday: Bool,
        weeklyCompletedCounts: [Int],
        previousWeekCompleted: Int,
        previousWeekCompletionRate: Double
    ) {
        self.weekInterval = weekInterval
        self.completedThisWeek = completedThisWeek
        self.completionRate = completionRate
        self.currentStreakDays = currentStreakDays
        self.hasCompletedToday = hasCompletedToday
        self.weeklyCompletedCounts = weeklyCompletedCounts
        self.previousWeekCompleted = previousWeekCompleted
        self.previousWeekCompletionRate = previousWeekCompletionRate
    }
}

/// Summarises `TaskDesk.history`. A private task is never written to that history (decision 10),
/// so it never counts here either.
public enum TaskHistoryInsights {
    public static func summarize(
        history: [FinishedTask],
        now: Date,
        calendar rawCalendar: Calendar = Calendar(identifier: .iso8601)
    ) -> TaskHistoryInsightsSummary {
        var calendar = rawCalendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let week = currentMondayWeek(containing: now, calendar: calendar)
        let previousWeek = DateInterval(
            start: calendar.date(byAdding: .day, value: -7, to: week.start) ?? week.start,
            end: week.start
        )
        let weekTasks = history.filter { contains($0.finishedAt, in: week) }
        let previousWeekTasks = history.filter { contains($0.finishedAt, in: previousWeek) }
        let completedWeekTasks = weekTasks.filter { $0.outcome == .completed }
        let today = calendar.startOfDay(for: now)
        let startedByThePerson = startedByThePerson(history)

        return TaskHistoryInsightsSummary(
            weekInterval: week,
            completedThisWeek: completedWeekTasks.count,
            completionRate: completionRate(in: weekTasks),
            // Streak and "completed today" deliberately ignore scheduled and watcher runs — see
            // `startedByThePerson(_:)`. Every other stat here counts them, because those are claims
            // about what Sonny did rather than about what the person did.
            currentStreakDays: currentStreakDays(tasks: startedByThePerson, now: now, calendar: calendar),
            hasCompletedToday: startedByThePerson.contains {
                $0.outcome == .completed && calendar.startOfDay(for: $0.finishedAt) == today
            },
            weeklyCompletedCounts: weeklyCompletedCounts(in: completedWeekTasks, week: week, calendar: calendar),
            previousWeekCompleted: previousWeekTasks.filter { $0.outcome == .completed }.count,
            previousWeekCompletionRate: completionRate(in: previousWeekTasks)
        )
    }

    /// Tasks that represent something the person actually did.
    ///
    /// A daily scheduled routine would otherwise guarantee a permanent streak and a permanently
    /// lit "completed today" — both stats would stop carrying any information, since they would be
    /// true whether or not the person ever opened Sonny. A streak is a claim about a habit, so
    /// automation cannot be allowed to earn it. The counts, completion rate and weekly chart
    /// deliberately keep unattended runs: those describe Sonny's output, which such a run genuinely is.
    private static func startedByThePerson(_ tasks: [FinishedTask]) -> [FinishedTask] {
        tasks.filter { !$0.origin.isUnattended }
    }

    private static func currentMondayWeek(containing date: Date, calendar: Calendar) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    /// Every finished task has ended one way or another, so each one is in the denominator.
    private static func completionRate(in tasks: [FinishedTask]) -> Double {
        guard !tasks.isEmpty else {
            return 0
        }
        return Double(tasks.filter { $0.outcome == .completed }.count) / Double(tasks.count)
    }

    private static func weeklyCompletedCounts(
        in tasks: [FinishedTask],
        week: DateInterval,
        calendar: Calendar
    ) -> [Int] {
        (0..<7).map { dayOffset in
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: week.start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return 0
            }
            let day = DateInterval(start: dayStart, end: dayEnd)
            return tasks.filter { contains($0.finishedAt, in: day) }.count
        }
    }

    private static func currentStreakDays(tasks: [FinishedTask], now: Date, calendar: Calendar) -> Int {
        let completedDays = Set(
            tasks
                .filter { $0.outcome == .completed }
                .map { calendar.startOfDay(for: $0.finishedAt) }
        )

        // One-day grace period: if today has no completion yet but yesterday does,
        // keep the streak alive from yesterday instead of zeroing it. It only breaks
        // once a full day passes with no activity at all.
        let today = calendar.startOfDay(for: now)
        var day: Date
        if completedDays.contains(today) {
            day = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  completedDays.contains(yesterday) {
            day = yesterday
        } else {
            return 0
        }

        var streak = 0
        while completedDays.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
                break
            }
            day = previous
        }
        return streak
    }

    private static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }
}

/// The finished tasks Insights lists under "Recently completed".
public enum RecentCompletedTasks {
    /// Completed ones only, matching the panel's title, newest first whatever order they arrive in.
    public static func recent(from history: [FinishedTask], limit: Int) -> [FinishedTask] {
        Array(
            history
                .filter { $0.outcome == .completed }
                .sorted { $0.finishedAt > $1.finishedAt }
                .prefix(limit)
        )
    }
}

extension TaskOrigin {
    /// Started with nobody at the Mac: a schedule or a watcher.
    public var isUnattended: Bool {
        self == .schedule || self == .watcher
    }
}
