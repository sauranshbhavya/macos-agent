import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// The Tasks page's two empty states. Kept out of the SwiftUI body for the same reason as the delete
/// copy: this repository has no view-rendering tests.
struct TaskSearchPresentationTests {
    /// **The criterion, and why it is not pedantry.** A user with four hundred tasks who types a
    /// word none of them contains must not be told they have never run a task — the never-ran copy
    /// tells them to go and run something, which is wrong and faintly insulting when their history
    /// is full.
    @Test
    func aQueryThatMatchesNothingIsNotTheSameStateAsHavingNeverRunAnything() {
        let noMatches = TaskSearchPresentation.emptyState(query: "zzzz")
        let neverRan = TaskSearchPresentation.emptyState(query: "")

        #expect(noMatches != neverRan)
        #expect(noMatches.title != neverRan.title)
        #expect(noMatches.detail != neverRan.detail)
        #expect(neverRan == TaskSearchPresentation.neverRanAnything)
        #expect(noMatches == TaskSearchPresentation.noMatches)
    }

    @Test
    func aWhitespaceOnlyQueryIsNotSearching() {
        // Same rule the list uses, so the two cannot disagree about whether a search is happening.
        #expect(TaskSearchPresentation.emptyState(query: "   ") == TaskSearchPresentation.neverRanAnything)
        #expect(TaskSearchPresentation.emptyState(query: "\n\t") == TaskSearchPresentation.neverRanAnything)
    }

    /// Neither state may explain the window, the cap, or where results come from. That would be the
    /// how-it-works copy the founder's decision of 2026-08-14 rules out, and it would smuggle in the
    /// completeness claim SONNY-119 forbids.
    @Test
    func neitherEmptyStateExplainsItselfOrClaimsCompleteness() {
        for state in [TaskSearchPresentation.noMatches, TaskSearchPresentation.neverRanAnything] {
            let text = "\(state.title) \(state.detail)".lowercased()
            // "complete" is deliberately not on this list as a bare substring: "No completed tasks
            // yet" is the outcome status, not a claim about coverage. The phrases below are the
            // claim.
            for forbidden in [
                "30 day", "30-day", "90 day", "thirty", "ninety", "window", "older than",
                "everything", "all tasks", "however old", "complete history", "the complete",
                "limit", "cap", "evict", "deleted"
            ] {
                #expect(!text.contains(forbidden), "empty-state copy should not mention \"\(forbidden)\": \(text)")
            }
        }
    }

    @Test
    func theFieldPromptNamesWhatIsSearchedWithoutPromisingHowMuch() {
        let prompt = TaskSearchPresentation.fieldPrompt.lowercased()
        #expect(!prompt.isEmpty)
        #expect(prompt.contains("task"))
        for forbidden in ["all", "everything", "every", "however old", "complete"] {
            #expect(!prompt.contains(forbidden))
        }
    }
}
