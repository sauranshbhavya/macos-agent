import Foundation

/// How far back the Tasks page's own list reaches. **Display-only: nothing here deletes anything.**
///
/// Thirty days since the founder's decision of 2026-08-16, down from ninety. The two halves of that
/// decision ship together and neither is safe alone: the list shows a short recent window, and the
/// page's search box reaches past it over everything the store holds (`TaskHistorySearch`).
/// Shortening the window without search would strand every older task with no way to reach it.
///
/// (The ninety came from Wispr Flow's home-page history and the deliberate 2026-07-21 decision that
/// this be display-only. That second half is unchanged and is the invariant below.)
///
/// **The invariant this type exists to keep.** Only the Tasks page's own history list applies this
/// filter. `TaskHistoryInsights`' stats, streak and week maths, `WorkspaceTaskBreakdown`, the
/// per-workspace task counts and the task detail sheet all read the un-windowed set, so narrowing
/// the window moves no number anywhere else. `searchingDoesNotMoveAnyInsightsNumber` pins it.
///
/// **What this type must not be read as promising, corrected here (SONNY-118).** This comment
/// previously said `TaskHistoryStore` "keeps every record", that other consumers see "the complete,
/// un-windowed history", and that deletion is "always an explicit, user-initiated action, never
/// automatic". All three were false and had been since long before row D. `TaskHistoryStore` evicts
/// oldest-first at `maxItems`, automatically and silently, and the vision journal does the same at
/// its own cap. What is true is the narrower thing those sentences were reaching for: **this window
/// deletes nothing, and every other consumer sees the whole store rather than this slice.** The
/// distinction matters because row D added a search box, and a search box implies that what it does
/// not return is not there — so nothing may claim completeness. See `TaskHistoryStore.maxItems`,
/// which states the cap and the reasoning for keeping it.
public enum TaskHistoryDisplayWindow {
    public static let windowDays = 30

    /// `now` is a parameter, not `Date()` internally, so this stays deterministic and testable —
    /// same pattern as `TaskHistoryInsights`.
    public static func withinWindow(_ records: [CompletedTaskRecord], now: Date) -> [CompletedTaskRecord] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) else {
            return records
        }
        return records.filter { $0.completedAt >= cutoff }
    }
}
