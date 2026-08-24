import Foundation
import MacAgentCore

/// The Tasks page's search copy and its empty states, kept out of the SwiftUI body so the suite can
/// reach them. Same reasoning as `TaskDeletePresentation`: this repository has no view-rendering
/// tests, so anything left inside a `body` is guarded only by the manual checklist.
enum TaskSearchPresentation {
    static let fieldPrompt = "Search tasks"

    /// What an empty list says, and **why there are two of these rather than one.**
    ///
    /// A user with four hundred tasks who types a word none of them contains must not be told they
    /// have never run a task. That is not a nicety: the never-ran copy tells them to go and run
    /// something, which is advice that is both wrong and slightly insulting when their history is
    /// full.
    ///
    /// Both are states, not explanations. Neither mentions the window, the cap, or where results
    /// come from — that would be the how-it-works copy the founder's decision of 2026-08-14 rules
    /// out, and it would also be the completeness claim SONNY-119 forbids, arriving by the back door.
    struct EmptyState: Equatable {
        var title: String
        var detail: String
    }

    static let neverRanAnything = EmptyState(
        title: "No completed tasks yet",
        detail: "Run or cancel a Sonny task and it will appear here."
    )

    static let noMatches = EmptyState(
        title: "No matching tasks",
        detail: "Try a different word, or clear the search."
    )

    /// One decision point, so the list and its empty state cannot disagree about whether the user is
    /// searching — or about whether the file can be read at all.
    ///
    /// **The unreadable case wins over the search, and that order is the point** (PR #110 fix-round
    /// review). A store that will not decode publishes zero records, so *every* query matches
    /// nothing; "Try a different word, or clear the search." is then advice that cannot work, in the
    /// same family as telling somebody with four hundred tasks that they have never run one. The
    /// wording comes from `MemoryDeletionCopy` rather than a third copy of it, so this page and the
    /// Memory row it hangs off say the same thing.
    ///
    /// This page is one of the three `MemoryRowDestination.page` rows, which is the population that
    /// had this gap: `MemoryEntriesSheet` got the can't-be-read state and the three pages kept
    /// telling the user to go and make some.
    static func emptyState(query: String, readability: MemoryRowReadability) -> EmptyState {
        guard readability == .readable else {
            return EmptyState(
                title: MemoryDeletionCopy.emptyStateTitle(for: .taskHistory, readability: readability),
                detail: MemoryDeletionCopy.emptyStateMessage(for: .taskHistory, readability: readability)
            )
        }
        return TaskHistorySearch.isSearching(query) ? noMatches : neverRanAnything
    }
}
