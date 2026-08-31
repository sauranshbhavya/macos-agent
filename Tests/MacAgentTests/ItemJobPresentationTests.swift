import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// What a job over many items says on the surfaces a person actually reads (row 13, SONNY-235).
///
/// The founder's decision of 2026-08-31 approves a whole job in one press **on the condition** that
/// the user can see it moving and stop it. The stop already existed (`cancelCurrentRun`); these are
/// the seeing. Both surfaces read one `ItemJobProgressPresentation`, so a test of the sentence is a
/// test of what both of them show.
@Suite
struct ItemJobPresentationTests {
    // MARK: - The row that stands in for the whole expansion

    /// **A job shows what it does to one item and how many items there are** — not one row per item,
    /// which is the forty-row approval prompt the founder's decision rejected.
    @Test
    func aJobIsOneRowNamingTheWorkAndTheCount() throws {
        let plan = expandedJob(items: (1...40).map { "/tmp/report-\($0).pdf" }, kind: .files)
        let row = try #require(ItemJobProgressPresentation.summaryRow(for: plan))

        #expect(row == "Run the Shortcut on this file. — 40 files")
        // The control that makes "one row" mean something: the plan really does hold forty groups.
        #expect(plan.steps.count == 40)
    }

    /// A plan that is not a job has no such row, so both panels keep the per-step rendering they had.
    @Test
    func aPlanThatIsNotAJobHasNoJobRow() {
        let plan = AgentPlan(
            summary: "Open a page.",
            requiresConfirmation: false,
            steps: [AgentStep(id: "url", operation: .openURL, description: "Open the page.", targetURL: "https://example.com")]
        )
        #expect(ItemJobProgressPresentation.summaryRow(for: plan) == nil)
    }

    /// An unresolved job has no row either — there is no count to state yet, and a row saying
    /// "0 files" would be a claim about a list nothing has read.
    @Test
    func anUnresolvedJobHasNoRowBecauseThereIsNoCountYet() {
        let plan = AgentPlan(
            summary: "Summarise each of these.",
            requiresConfirmation: true,
            steps: [AgentStep(id: "run", operation: .invokeShortcut, description: "Run it.", shortcutName: "Summarise")],
            itemJob: PlanItemJob(source: .folder, folderPath: "/tmp", itemKind: .files, itemField: .shortcutInput)
        )
        #expect(ItemJobProgressPresentation.summaryRow(for: plan) == nil)
    }

    /// One item reads as one item rather than "1 files".
    @Test
    func aJobOfOneItemIsNamedInTheSingular() throws {
        let plan = expandedJob(items: ["/tmp/only.pdf"], kind: .files)
        #expect(try #require(ItemJobProgressPresentation.summaryRow(for: plan)).hasSuffix("— 1 file"))
    }

    /// **The choice a panel makes, held by value.** R14 of the battery at `369cbc3` deleted the job
    /// arm from `WidgetWorkingPanel` — putting forty rows back into the approval prompt — and the
    /// whole suite passed, because the branch lived inside a SwiftUI body and nothing here tests one.
    /// The decision moved out; this is what holds it.
    @Test
    func theRowsAJobDrawsAreOneRowRatherThanOnePerItem() {
        let job = expandedJob(items: (1...40).map { "/tmp/report-\($0).pdf" }, kind: .files)
        let progress = ItemJobProgress(
            itemKind: .files,
            items: (1...40).map { "/tmp/report-\($0).pdf" },
            completedItemIndexes: Array(0..<12),
            failures: []
        )
        #expect(
            ItemJobProgressPresentation.rows(for: job, progress: progress)
                == .job(title: "Run the Shortcut on this file. — 40 files", progressLine: "12 of 40 files done")
        )

        // The question panels pass no progress, because none of them reports how far a run got.
        #expect(
            ItemJobProgressPresentation.rows(for: job, progress: nil)
                == .job(title: "Run the Shortcut on this file. — 40 files", progressLine: nil)
        )

        // The control, and the half R14 flipped: an ordinary plan still draws one row per step.
        let steps = [
            AgentStep(id: "calc", operation: .calculateUtility, description: "Add up.", searchQuery: "2 + 2"),
            AgentStep(id: "url", operation: .openURL, description: "Open it.", targetURL: "https://example.com")
        ]
        let ordinary = AgentPlan(summary: "Two things.", requiresConfirmation: false, steps: steps)
        #expect(ItemJobProgressPresentation.rows(for: ordinary, progress: nil) == .steps(steps))

        // And nothing at all to draw stays nothing.
        #expect(ItemJobProgressPresentation.rows(for: nil, progress: nil) == nil)
        #expect(
            ItemJobProgressPresentation.rows(
                for: AgentPlan(summary: "Empty.", requiresConfirmation: false, steps: []),
                progress: nil
            ) == nil
        )
    }

    // MARK: - The progress line

    /// **Both halves, once either is non-zero.** "Thirty-eight summaries and two failures is a real
    /// outcome", and a line reporting only the successes is the flat success this exists to replace.
    @Test
    func theProgressLineNamesWhatWorkedAndWhatDidNot() throws {
        let done = ItemJobProgress(
            itemKind: .files,
            items: (1...40).map { "/tmp/report-\($0).pdf" },
            completedItemIndexes: Array(0..<38),
            failures: [
                failure(at: 38, "Word would not open it."),
                failure(at: 39, "The file is locked.")
            ]
        )
        #expect(ItemJobProgressPresentation.progressLine(for: done) == "38 of 40 files done · 2 couldn't be done")

        // The control: the same job with nothing failing says only the first half, so the failure
        // clause is a thing the data produces rather than a thing the sentence always carries.
        let clean = ItemJobProgress(
            itemKind: .files,
            items: (1...40).map { "/tmp/report-\($0).pdf" },
            completedItemIndexes: Array(0..<38),
            failures: []
        )
        #expect(ItemJobProgressPresentation.progressLine(for: clean) == "38 of 40 files done")
    }

    /// Nothing is said while nothing has settled: "0 of 40 done" beside a spinner tells the user
    /// less than the spinner does.
    @Test
    func aJobThatHasSettledNothingSaysNothingYet() {
        let starting = ItemJobProgress(
            itemKind: .folders,
            items: ["/tmp/a", "/tmp/b"],
            completedItemIndexes: [],
            failures: []
        )
        #expect(ItemJobProgressPresentation.progressLine(for: starting) == nil)

        // The control, and the boundary: one settled item is enough to speak.
        let started = ItemJobProgress(
            itemKind: .folders,
            items: ["/tmp/a", "/tmp/b"],
            completedItemIndexes: [0],
            failures: []
        )
        #expect(ItemJobProgressPresentation.progressLine(for: started) == "1 of 2 folders done")
    }

    /// A job whose only settled item failed still speaks, and says so — the case a "count the
    /// successes" line would have stayed silent through.
    @Test
    func aJobWhoseOnlySettledItemFailedStillReportsIt() {
        let progress = ItemJobProgress(
            itemKind: .files,
            items: ["/tmp/a.pdf", "/tmp/b.pdf", "/tmp/c.pdf"],
            completedItemIndexes: [],
            failures: [failure(at: 0, "The file is locked.")]
        )
        #expect(ItemJobProgressPresentation.progressLine(for: progress) == "0 of 3 files done · 1 couldn't be done")
    }

    // MARK: - Fixtures

    private func failure(at index: Int, _ message: String) -> ItemJobFailure {
        ItemJobFailure(
            itemIndex: index,
            item: "/tmp/item-\(index)",
            message: message,
            failedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func expandedJob(items: [String], kind: PlanItemKind) -> AgentPlan {
        PlanItemJobResolver.expanding(
            AgentPlan(
                summary: "Summarise each of these.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "run",
                        operation: .invokeShortcut,
                        description: "Run the Shortcut on this file.",
                        shortcutName: "Summarise"
                    )
                ]
            ),
            over: PlanItemJob(
                source: .folder,
                folderPath: "/tmp",
                itemKind: kind,
                itemField: .shortcutInput,
                items: items
            )
        )
    }
}
