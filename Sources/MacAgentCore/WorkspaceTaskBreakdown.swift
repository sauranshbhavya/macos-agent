import Foundation

public struct WorkspaceTaskBreakdownEntry: Equatable, Sendable, Identifiable {
    public var workspaceName: String
    public var completedCount: Int
    public var fractionOfTotal: Double

    public init(workspaceName: String, completedCount: Int, fractionOfTotal: Double) {
        self.workspaceName = workspaceName
        self.completedCount = completedCount
        self.fractionOfTotal = fractionOfTotal
    }

    public var id: String { workspaceName }
}

public enum WorkspaceTaskBreakdown {
    public static let windowDayCount = 30

    /// Counts `.completed` records only — a failed or canceled task didn't meaningfully "happen"
    /// in a workspace for a usage-breakdown chart, matching `TaskHistoryInsights.completedThisWeek`'s
    /// existing definition. This is a real assumption that changes a displayed number, not a
    /// cosmetic detail.
    public static func summarize(
        records: [CompletedTaskRecord],
        now: Date,
        calendar rawCalendar: Calendar = Calendar(identifier: .iso8601)
    ) -> [WorkspaceTaskBreakdownEntry] {
        var calendar = rawCalendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        // Calendar-day arithmetic off `startOfDay`, not raw `TimeInterval` subtraction — the same
        // pattern `TaskHistoryInsights`'s week-scoped helpers use, and for the same reason: a raw
        // `now.addingTimeInterval(-30 * 86400)` would land on the wrong side of midnight by an hour
        // whenever a DST transition falls within the 30-day span, since one of those days is
        // actually 23 or 25 hours long in wall-clock terms.
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -windowDayCount, to: startOfToday) ?? startOfToday

        let countedRecords = records.filter { record in
            record.outcomeStatus == .completed &&
                record.workspaceName != nil &&
                record.completedAt >= windowStart
        }

        guard !countedRecords.isEmpty else {
            return []
        }

        var countsByWorkspace: [String: Int] = [:]
        for record in countedRecords {
            guard let workspaceName = record.workspaceName else {
                continue
            }
            countsByWorkspace[workspaceName, default: 0] += 1
        }

        let total = countedRecords.count
        return countsByWorkspace
            .map { name, count in
                WorkspaceTaskBreakdownEntry(
                    workspaceName: name,
                    completedCount: count,
                    fractionOfTotal: Double(count) / Double(total)
                )
            }
            .sorted { lhs, rhs in
                if lhs.completedCount != rhs.completedCount {
                    return lhs.completedCount > rhs.completedCount
                }
                return lhs.workspaceName.localizedCaseInsensitiveCompare(rhs.workspaceName) == .orderedAscending
            }
    }
}
