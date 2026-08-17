import Foundation

/// Search over task history: which records a query matches, and what the Tasks list shows.
///
/// A pure function over `[CompletedTaskRecord]` so the rule is testable without a view — including
/// the one that matters most, that **a query reaches past the display window**. That rule lives here
/// rather than in `TasksFoundationView` precisely because a view could not be tested for it, and it
/// is the rule the whole feature rests on.
public enum TaskHistorySearch {
    /// The records a query matches, in the order given.
    ///
    /// **What it searches: the command the user typed, and the workspace name.** Nothing else on the
    /// record is text a person would search by — the timestamps, the outcome and the ids are not
    /// words anyone types into a box.
    ///
    /// **What it deliberately does not search: screen records.** Two independent reasons, both real.
    /// That text is model-authored description of what was on the user's screen, so putting it into
    /// a result list would surface screen content somewhere the user did not ask for it. And it
    /// would cost a decrypt-and-scan of up to 500 journal sessions *per keystroke* — the same cost
    /// the detail sheet already refuses to pay for a single row.
    ///
    /// An empty or whitespace-only query matches everything, so callers can pass the raw field
    /// contents without special-casing.
    public static func matching(_ records: [CompletedTaskRecord], query rawQuery: String) -> [CompletedTaskRecord] {
        let query = SearchText.normalizedQuery(rawQuery)
        guard !query.isEmpty else {
            return records
        }
        return records.filter { searchableText(for: $0).contains(query) }
    }

    /// What the Tasks list shows, for a given query.
    ///
    /// **The two halves of the founder's decision of 2026-08-16 in one place.** An empty field shows
    /// the last `TaskHistoryDisplayWindow.windowDays` days; a query searches **everything the store
    /// holds**, ignoring the window entirely. That second half is what makes the first one safe:
    /// shortening the window without search would strand every older task with no way to reach it,
    /// which is a regression wearing a feature's clothes.
    ///
    /// Note what this does *not* claim. Search reaches past the window, not past the store — task
    /// history evicts at its cap, so "everything the store holds" is the honest phrase and
    /// "everything" is not. See `TaskHistoryStore.maxItems`.
    public static func visibleRecords(
        _ records: [CompletedTaskRecord],
        query rawQuery: String,
        now: Date
    ) -> [CompletedTaskRecord] {
        guard !SearchText.normalizedQuery(rawQuery).isEmpty else {
            return TaskHistoryDisplayWindow.withinWindow(records, now: now)
        }
        return matching(records, query: rawQuery)
    }

    /// Whether a query is active at all — one definition, so the list, the section counts and the
    /// empty state cannot disagree about whether the user is searching.
    public static func isSearching(_ rawQuery: String) -> Bool {
        !SearchText.normalizedQuery(rawQuery).isEmpty
    }

    private static func searchableText(for record: CompletedTaskRecord) -> String {
        SearchText.normalized("\(record.command) \(record.workspaceName ?? "")")
    }
}
