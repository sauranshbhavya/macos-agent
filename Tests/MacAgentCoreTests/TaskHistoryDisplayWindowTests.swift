import Foundation
import Testing
@testable import MacAgentCore

struct TaskHistoryDisplayWindowTests {
    @Test
    func keepsRecordsWithinTheLast90Days() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("today", completedAt: now),
            record("30 days ago", completedAt: try date("2026-06-21T12:00:00Z")),
            record("89 days ago", completedAt: try date("2026-04-23T12:00:00Z"))
        ]

        let windowed = TaskHistoryDisplayWindow.withinWindow(records, now: now)

        #expect(windowed.map(\.command) == ["today", "30 days ago", "89 days ago"])
    }

    @Test
    func excludesRecordsOlderThan90Days() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("within window", completedAt: try date("2026-06-21T12:00:00Z")),
            record("91 days ago", completedAt: try date("2026-04-21T12:00:00Z")),
            record("a year ago", completedAt: try date("2025-07-21T12:00:00Z"))
        ]

        let windowed = TaskHistoryDisplayWindow.withinWindow(records, now: now)

        #expect(windowed.map(\.command) == ["within window"])
    }

    @Test
    func emptyInputProducesAnEmptyResult() {
        #expect(TaskHistoryDisplayWindow.withinWindow([], now: Date(timeIntervalSince1970: 0)).isEmpty)
    }

    private func record(_ command: String, completedAt: Date) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt,
            outcomeStatus: .completed,
            workspaceName: nil
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
