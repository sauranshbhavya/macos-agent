import Foundation

/// Tasks page display window, inspired by Wispr Flow's ~90-day home-page history. Display-only, by
/// deliberate decision (2026-07-21): nothing is ever deleted here — `TaskHistoryStore` keeps every
/// record, and every other consumer (Insights' stats/streak/breakdown math, `TaskLogDetailDialog`)
/// still sees the complete, un-windowed history. Only the Tasks page's own history list applies
/// this filter. If a real retention/deletion policy is ever wanted instead, that's a distinct,
/// separate decision — see `LocalDataDeletionService` for how deletion is handled today (always an
/// explicit, user-initiated action, never automatic).
public enum TaskHistoryDisplayWindow {
    public static let windowDays = 90

    /// `now` is a parameter, not `Date()` internally, so this stays deterministic and testable —
    /// same pattern as `TaskHistoryInsights`.
    public static func withinWindow(_ records: [CompletedTaskRecord], now: Date) -> [CompletedTaskRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) else {
            return records
        }
        return records.filter { $0.completedAt >= cutoff }
    }
}
