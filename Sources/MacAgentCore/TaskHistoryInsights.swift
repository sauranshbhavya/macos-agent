import Foundation

public struct TaskHistoryInsightsSummary: Equatable, Sendable {
    public var weekInterval: DateInterval
    public var completedThisWeek: Int
    public var completionRate: Double
    public var averageCompletedCycleTime: TimeInterval?
    public var currentStreakDays: Int
    public var hasCompletedToday: Bool
    public var weeklyCompletedCounts: [Int]
    public var previousWeekCompleted: Int
    public var previousWeekCompletionRate: Double
    public var previousWeekAverageCompletedCycleTime: TimeInterval?

    public init(
        weekInterval: DateInterval,
        completedThisWeek: Int,
        completionRate: Double,
        averageCompletedCycleTime: TimeInterval?,
        currentStreakDays: Int,
        hasCompletedToday: Bool,
        weeklyCompletedCounts: [Int],
        previousWeekCompleted: Int,
        previousWeekCompletionRate: Double,
        previousWeekAverageCompletedCycleTime: TimeInterval?
    ) {
        self.weekInterval = weekInterval
        self.completedThisWeek = completedThisWeek
        self.completionRate = completionRate
        self.averageCompletedCycleTime = averageCompletedCycleTime
        self.currentStreakDays = currentStreakDays
        self.hasCompletedToday = hasCompletedToday
        self.weeklyCompletedCounts = weeklyCompletedCounts
        self.previousWeekCompleted = previousWeekCompleted
        self.previousWeekCompletionRate = previousWeekCompletionRate
        self.previousWeekAverageCompletedCycleTime = previousWeekAverageCompletedCycleTime
    }
}

public enum TaskHistoryInsights {
    public static func summarize(
        records: [CompletedTaskRecord],
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
        let weekRecords = records.filter { contains($0.completedAt, in: week) }
        let previousWeekRecords = records.filter { contains($0.completedAt, in: previousWeek) }
        let completedWeekRecords = weekRecords.filter { $0.outcomeStatus == .completed }
        let previousCompletedRecords = previousWeekRecords.filter { $0.outcomeStatus == .completed }
        let today = calendar.startOfDay(for: now)

        return TaskHistoryInsightsSummary(
            weekInterval: week,
            completedThisWeek: completedWeekRecords.count,
            completionRate: completionRate(in: weekRecords),
            averageCompletedCycleTime: averageCycleTime(in: completedWeekRecords),
            currentStreakDays: currentStreakDays(records: records, now: now, calendar: calendar),
            hasCompletedToday: records.contains {
                $0.outcomeStatus == .completed && calendar.startOfDay(for: $0.completedAt) == today
            },
            weeklyCompletedCounts: weeklyCompletedCounts(in: completedWeekRecords, week: week, calendar: calendar),
            previousWeekCompleted: previousCompletedRecords.count,
            previousWeekCompletionRate: completionRate(in: previousWeekRecords),
            previousWeekAverageCompletedCycleTime: averageCycleTime(in: previousCompletedRecords)
        )
    }

    private static func currentMondayWeek(containing date: Date, calendar: Calendar) -> DateInterval {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday + 5) % 7
        let start = calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private static func completionRate(in records: [CompletedTaskRecord]) -> Double {
        let terminalRecords = records.filter { [.completed, .failed, .canceled].contains($0.outcomeStatus) }
        guard !terminalRecords.isEmpty else {
            return 0
        }
        let completedCount = terminalRecords.filter { $0.outcomeStatus == .completed }.count
        return Double(completedCount) / Double(terminalRecords.count)
    }

    private static func averageCycleTime(in records: [CompletedTaskRecord]) -> TimeInterval? {
        guard !records.isEmpty else {
            return nil
        }
        let total = records.reduce(TimeInterval(0)) { partial, record in
            partial + max(0, record.completedAt.timeIntervalSince(record.startedAt))
        }
        return total / Double(records.count)
    }

    private static func weeklyCompletedCounts(
        in records: [CompletedTaskRecord],
        week: DateInterval,
        calendar: Calendar
    ) -> [Int] {
        (0..<7).map { dayOffset in
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: week.start),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                return 0
            }
            let day = DateInterval(start: dayStart, end: dayEnd)
            return records.filter { contains($0.completedAt, in: day) }.count
        }
    }

    private static func currentStreakDays(
        records: [CompletedTaskRecord],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let completedDays = Set(
            records
                .filter { $0.outcomeStatus == .completed }
                .map { calendar.startOfDay(for: $0.completedAt) }
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
