import Foundation

public enum RecentCompletedTasks {
    /// Filters to `.completed` only, matching the panel's own "Recently completed" title and the
    /// wireframe's status dot (always green, never the failed/canceled colors) — a failed or
    /// canceled record showing up here would contradict both.
    /// Sorts here rather than trusting the caller: `TaskHistoryStore.loadAll()` returns records
    /// in append (oldest-first) order, so relying on an external sort meant any caller that
    /// forgot one would silently get the *oldest* completed tasks under a "recent" label.
    public static func recent(from records: [CompletedTaskRecord], limit: Int) -> [CompletedTaskRecord] {
        Array(
            records
                .filter { $0.outcomeStatus == .completed }
                .sorted { $0.completedAt > $1.completedAt }
                .prefix(limit)
        )
    }
}
