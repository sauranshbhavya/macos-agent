import Foundation
import MacAgentCore

/// What a job over many items says on the two surfaces that render a run (row 13, SONNY-235).
///
/// **One home for the copy because two surfaces show it and they must not disagree.** The widget's
/// working panel and Command Center's running indicator are written independently — different design
/// systems, different layouts — and the sentence a user reads about "17 of 40" is the same fact in
/// both. `CommandCenterAttentionPanel`'s own precedence problem is the precedent: two surfaces
/// deriving one state separately is how they end up saying different things about the same run.
///
/// **The job's row replaces the per-item rows rather than joining them.** A forty-item job expands
/// to forty step groups, and both panels render one row per step — so the approval prompt the
/// founder's decision of 2026-08-31 describes as "Rename all 40?" would have been forty rows the
/// user scrolls, which is the per-item prompt that decision rejected wearing different clothes. A
/// job shows what it does to one item, and how many items there are.
enum ItemJobProgressPresentation {
    /// What the job does, once, with the number of items it does it to — the row that stands in for
    /// the whole expansion.
    ///
    /// Built from the **first item's** steps, which are the template every other item repeats: the
    /// expansion copies one group per item, so item one's steps carry the same operations and the
    /// same descriptions as item forty's. Returns `nil` for a plan that is not a job, which is what
    /// keeps both callers' ordinary path untouched.
    static func summaryRow(for plan: AgentPlan) -> String? {
        guard let job = plan.itemJob, job.isResolved else {
            return nil
        }
        let firstItemSteps = plan.steps.filter { $0.itemIndex == plan.steps.first?.itemIndex }
        let what = firstItemSteps
            .map(AgentActivityPresentation.planStepTitle)
            .joined(separator: ", ")
        let count = job.items.count
        let noun = count == 1 ? singular(job.itemKind) : job.itemKind.pluralNoun
        guard !what.isEmpty else {
            return "\(count) \(noun)"
        }
        return "\(what) — \(count) \(noun)"
    }

    /// How far it has got, or `nil` before anything has settled.
    ///
    /// **Both halves, always, once either is non-zero.** "Thirty-eight summaries and two failures is
    /// a real outcome" is the ticket's own sentence, and a line reporting only what worked is the
    /// flat success this exists to replace. Nothing is said at all while the count is still zero:
    /// "0 of 40 done" beside a spinner tells the user less than the spinner does.
    static func progressLine(for progress: ItemJobProgress) -> String? {
        guard progress.settledCount > 0 else {
            return nil
        }
        let noun = progress.itemCount == 1 ? singular(progress.itemKind) : progress.itemKind.pluralNoun
        var line = "\(progress.completedCount) of \(progress.itemCount) \(noun) done"
        if progress.failedCount > 0 {
            line += " · \(progress.failedCount) couldn't be done"
        }
        return line
    }

    private static func singular(_ kind: PlanItemKind) -> String {
        switch kind {
        case .files:
            return "file"
        case .folders:
            return "folder"
        }
    }
}
