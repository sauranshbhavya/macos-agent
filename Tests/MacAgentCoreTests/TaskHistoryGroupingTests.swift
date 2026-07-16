import Foundation
import Testing
@testable import MacAgentCore

struct TaskHistoryGroupingTests {
    @Test
    func recordsAreBucketedByOutcomeStatus() throws {
        let completed = record("completed one", outcome: .completed)
        let failed = record("failed one", outcome: .failed)
        let canceled = record("canceled one", outcome: .canceled)

        let sections = TaskHistoryGrouping.groupedByOutcome(records: [completed, failed, canceled])

        let completedSection = try #require(sections.first { $0.title == "Completed" })
        let failedSection = try #require(sections.first { $0.title == "Failed" })
        let canceledSection = try #require(sections.first { $0.title == "Canceled" })

        #expect(completedSection.records == [completed])
        #expect(failedSection.records == [failed])
        #expect(canceledSection.records == [canceled])
    }

    @Test
    func sectionCountsReflectTheFullInputNotASubset() throws {
        let records = (0..<12).map { record("completed \($0)", outcome: .completed) }
            + [record("failed one", outcome: .failed)]

        let sections = TaskHistoryGrouping.groupedByOutcome(records: records)

        let completedSection = try #require(sections.first { $0.title == "Completed" })
        let failedSection = try #require(sections.first { $0.title == "Failed" })

        #expect(completedSection.records.count == 12)
        #expect(failedSection.records.count == 1)
    }

    @Test
    func sectionsWithNoMatchingRecordsAreDropped() {
        let records = [record("completed one", outcome: .completed)]

        let sections = TaskHistoryGrouping.groupedByOutcome(records: records)

        #expect(sections.map(\.title) == ["Completed"])
    }

    @Test
    func emptyInputProducesAnEmptyResult() {
        let sections = TaskHistoryGrouping.groupedByOutcome(records: [])

        #expect(sections.isEmpty)
    }

    private func record(
        _ command: String,
        outcome: PriorTaskOutcomeStatus
    ) -> CompletedTaskRecord {
        let completedAt = Date(timeIntervalSince1970: 0)
        return CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt,
            outcomeStatus: outcome
        )
    }
}
