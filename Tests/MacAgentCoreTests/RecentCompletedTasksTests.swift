import Foundation
import Testing
@testable import MacAgentCore

@Suite
struct RecentCompletedTasksOrderingTests {
    /// `TaskHistoryStore.loadAll()` returns records in append (oldest-first) order, so a caller
    /// that doesn't pre-sort used to get the *oldest* completed tasks under a "recent" label.
    @Test
    func recentReturnsNewestFirstEvenWhenInputIsOldestFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            CompletedTaskRecord(
                command: "oldest",
                startedAt: base,
                completedAt: base,
                outcomeStatus: .completed
            ),
            CompletedTaskRecord(
                command: "middle",
                startedAt: base,
                completedAt: base.addingTimeInterval(3_600),
                outcomeStatus: .completed
            ),
            CompletedTaskRecord(
                command: "newest",
                startedAt: base,
                completedAt: base.addingTimeInterval(7_200),
                outcomeStatus: .completed
            )
        ]

        let recent = RecentCompletedTasks.recent(from: records, limit: 2)

        #expect(recent.map(\.command) == ["newest", "middle"])
    }
}

struct RecentCompletedTasksTests {
    @Test
    func excludesFailedAndCanceledRecordsEvenWhenMoreRecentThanCompletedOnes() throws {
        let records = [
            record("failed most recent", completedAt: try date("2026-07-15T09:00:00Z"), outcome: .failed),
            record("canceled", completedAt: try date("2026-07-14T09:00:00Z"), outcome: .canceled),
            record("completed a", completedAt: try date("2026-07-13T09:00:00Z"), outcome: .completed),
            record("completed b", completedAt: try date("2026-07-12T09:00:00Z"), outcome: .completed)
        ]

        let recent = RecentCompletedTasks.recent(from: records, limit: 6)

        #expect(recent.map(\.command) == ["completed a", "completed b"])
    }

    @Test
    func respectsTheLimitAfterFiltering() throws {
        let records = (0..<10).map { index in
            record("completed \(index)", completedAt: try! date("2026-07-15T09:00:00Z"), outcome: .completed)
        }

        let recent = RecentCompletedTasks.recent(from: records, limit: 3)

        #expect(recent.count == 3)
    }

    @Test
    func emptyInputProducesAnEmptyResult() {
        #expect(RecentCompletedTasks.recent(from: [], limit: 6).isEmpty)
    }

    private func record(
        _ command: String,
        completedAt: Date,
        duration: TimeInterval = 60,
        outcome: PriorTaskOutcomeStatus
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-duration),
            completedAt: completedAt,
            outcomeStatus: outcome,
            workspaceName: nil
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
