import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// The pure selection logic behind the Tasks page's list-and-pane layout (row 11, the founders' ask
/// of 2026-09-09).
@Suite
struct TasksSelectionPresentationTests {
    // MARK: - next(after:in:)

    @Test
    func nextMovesForwardThroughVisibleRowsAcrossSectionBoundaries() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let c = record("c", outcome: .failed)
        let sections = sections(for: [a, b, c])

        // Within a section…
        #expect(TasksSelectionPresentation.next(after: a.taskRowIdentity, in: sections) == b.taskRowIdentity)
        // …and across the boundary into the next one.
        #expect(TasksSelectionPresentation.next(after: b.taskRowIdentity, in: sections) == c.taskRowIdentity)
    }

    @Test
    func nextStopsAtTheLastRowRatherThanWrapping() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let sections = sections(for: [a, b])

        #expect(TasksSelectionPresentation.next(after: b.taskRowIdentity, in: sections) == b.taskRowIdentity)
    }

    @Test
    func nextAnswersTheFirstRowWhenNothingIsSelectedOrTheCurrentRowIsGone() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let sections = sections(for: [a, b])

        #expect(TasksSelectionPresentation.next(after: nil, in: sections) == a.taskRowIdentity)
        #expect(TasksSelectionPresentation.next(after: "some-deleted-id", in: sections) == a.taskRowIdentity)
    }

    @Test
    func nextSkipsTheRowsOfACollapsedSection() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let c = record("c", outcome: .failed)
        var collapse = TaskSectionCollapseState()
        collapse.toggle("Done")
        let sections = TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: [a, b, c]),
            collapse: collapse
        )

        // "Done" (a, b) is collapsed, so its rows are invisible to both directions — the only
        // visible row is "c" in "Failed".
        #expect(TasksSelectionPresentation.next(after: nil, in: sections) == c.taskRowIdentity)
        #expect(TasksSelectionPresentation.next(after: c.taskRowIdentity, in: sections) == c.taskRowIdentity)
    }

    @Test
    func nextAndPreviousAnswerNothingWhenThereIsNoHistoryAtAll() {
        #expect(TasksSelectionPresentation.next(after: nil, in: []) == nil)
        #expect(TasksSelectionPresentation.previous(before: nil, in: []) == nil)
    }

    // MARK: - previous(before:in:)

    @Test
    func previousMovesBackwardThroughVisibleRowsAcrossSectionBoundaries() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let c = record("c", outcome: .failed)
        let sections = sections(for: [a, b, c])

        #expect(TasksSelectionPresentation.previous(before: c.taskRowIdentity, in: sections) == b.taskRowIdentity)
        #expect(TasksSelectionPresentation.previous(before: b.taskRowIdentity, in: sections) == a.taskRowIdentity)
    }

    @Test
    func previousStopsAtTheFirstRowRatherThanWrapping() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let sections = sections(for: [a, b])

        #expect(TasksSelectionPresentation.previous(before: a.taskRowIdentity, in: sections) == a.taskRowIdentity)
    }

    @Test
    func previousAnswersTheFirstRowWhenNothingIsSelectedOrTheCurrentRowIsGone() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)
        let sections = sections(for: [a, b])

        #expect(TasksSelectionPresentation.previous(before: nil, in: sections) == a.taskRowIdentity)
        #expect(TasksSelectionPresentation.previous(before: "some-deleted-id", in: sections) == a.taskRowIdentity)
    }

    // MARK: - selectionAfterRefresh(current:records:)

    @Test
    func selectionAfterRefreshKeepsASelectionThatStillExists() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)

        #expect(
            TasksSelectionPresentation.selectionAfterRefresh(current: a.taskRowIdentity, records: [a, b])
                == a.taskRowIdentity
        )
    }

    @Test
    func selectionAfterRefreshClearsASelectionThatIsGone() {
        let a = record("a", outcome: .completed)
        let b = record("b", outcome: .completed)

        // "a" was deleted; the refreshed history is only "b".
        #expect(TasksSelectionPresentation.selectionAfterRefresh(current: a.taskRowIdentity, records: [b]) == nil)
        #expect(TasksSelectionPresentation.selectionAfterRefresh(current: a.taskRowIdentity, records: []) == nil)
    }

    @Test
    func selectionAfterRefreshWithNoCurrentSelectionStaysNil() {
        let a = record("a", outcome: .completed)

        #expect(TasksSelectionPresentation.selectionAfterRefresh(current: nil, records: [a]) == nil)
    }

    // MARK: - sectionContaining(taskID:sections:)

    @Test
    func sectionContainingFindsATaskWhicheverSectionHoldsIt() {
        let done = record("finished", outcome: .completed)
        let failed = record("broke", outcome: .failed)
        let canceled = record("stopped", outcome: .canceled)
        let historySections = TaskHistoryGrouping.groupedByOutcome(records: [done, failed, canceled])

        #expect(
            TasksSelectionPresentation.sectionContaining(taskID: done.taskRowIdentity, sections: historySections)
                == "Done"
        )
        #expect(
            TasksSelectionPresentation.sectionContaining(taskID: failed.taskRowIdentity, sections: historySections)
                == "Failed"
        )
        #expect(
            TasksSelectionPresentation.sectionContaining(taskID: canceled.taskRowIdentity, sections: historySections)
                == "Canceled"
        )
    }

    /// The reason this takes `TaskHistorySection` and not `TaskSectionPresentation`: a task inside
    /// a section the user folded away is still findable, because `TaskHistorySection.records` is
    /// never filtered by collapse the way `visibleRecords` is.
    @Test
    func sectionContainingFindsATaskEvenWhenItsSectionIsCollapsed() {
        let done = record("finished", outcome: .completed)
        let historySections = TaskHistoryGrouping.groupedByOutcome(records: [done])
        var collapse = TaskSectionCollapseState()
        collapse.toggle("Done")
        // The collapsed presentation really does hide the row — proving the test is not vacuous.
        let collapsedPresentation = TaskSectionPresentation.sections(for: historySections, collapse: collapse)
        #expect(collapsedPresentation.first?.visibleRecords.isEmpty == true)

        #expect(
            TasksSelectionPresentation.sectionContaining(taskID: done.taskRowIdentity, sections: historySections)
                == "Done"
        )
    }

    @Test
    func sectionContainingAnswersNilForATaskInNoSection() {
        let done = record("finished", outcome: .completed)
        let historySections = TaskHistoryGrouping.groupedByOutcome(records: [done])

        #expect(TasksSelectionPresentation.sectionContaining(taskID: "no-such-task", sections: historySections) == nil)
    }

    // MARK: - Fixtures

    private func sections(for records: [CompletedTaskRecord]) -> [TaskSectionPresentation] {
        TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: records),
            collapse: TaskSectionCollapseState()
        )
    }

    private func record(
        _ id: String,
        outcome: PriorTaskOutcomeStatus,
        completedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            id: id,
            command: id,
            startedAt: completedAt.addingTimeInterval(-30),
            completedAt: completedAt,
            outcomeStatus: outcome
        )
    }
}
