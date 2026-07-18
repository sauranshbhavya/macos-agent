import Foundation

public enum RecentCompletedTasks {
    /// Filters to `.completed` only, matching the panel's own "Recently completed" title and the
    /// wireframe's status dot (always green, never the failed/canceled colors) — a failed or
    /// canceled record showing up here would contradict both.
    public static func recent(from records: [CompletedTaskRecord], limit: Int) -> [CompletedTaskRecord] {
        Array(records.filter { $0.outcomeStatus == .completed }.prefix(limit))
    }
}
