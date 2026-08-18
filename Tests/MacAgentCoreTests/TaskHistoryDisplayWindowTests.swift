import Foundation
import Testing
@testable import MacAgentCore

struct TaskHistoryDisplayWindowTests {
    /// Rewritten rather than deleted when the window went 90 → 30 (SONNY-118, the founder's
    /// decision of 2026-08-16). A test whose name says 90 and whose body says 30 is worse than
    /// either, so the names moved with the number.
    @Test
    func keepsRecordsWithinTheLast30Days() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("today", completedAt: now),
            record("10 days ago", completedAt: try date("2026-07-11T12:00:00Z")),
            record("29 days ago", completedAt: try date("2026-06-22T12:00:00Z"))
        ]

        let windowed = TaskHistoryDisplayWindow.withinWindow(records, now: now)

        #expect(windowed.map(\.command) == ["today", "10 days ago", "29 days ago"])
    }

    @Test
    func excludesRecordsOlderThan30Days() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("within window", completedAt: try date("2026-07-11T12:00:00Z")),
            record("31 days ago", completedAt: try date("2026-06-20T12:00:00Z")),
            // What used to be inside the window and now is not — the change this ticket made,
            // asserted rather than implied.
            record("89 days ago", completedAt: try date("2026-04-23T12:00:00Z")),
            record("a year ago", completedAt: try date("2025-07-21T12:00:00Z"))
        ]

        let windowed = TaskHistoryDisplayWindow.withinWindow(records, now: now)

        #expect(windowed.map(\.command) == ["within window"])
    }

    @Test
    func theWindowIsThirtyDays() {
        #expect(TaskHistoryDisplayWindow.windowDays == 30)
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
