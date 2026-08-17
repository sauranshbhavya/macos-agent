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
    /// searching.
    static func emptyState(query: String) -> EmptyState {
        TaskHistorySearch.isSearching(query) ? noMatches : neverRanAnything
    }
}
