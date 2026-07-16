import Foundation
import Testing
@testable import MacAgentCore

struct WorkspaceTaskBreakdownTests {
    @Test
    func countsOnlyCompletedTaggedRecordsWithinTheTrailingThirtyDayWindow() throws {
        let calendar = utcISOCalendar()
        let now = try date("2026-07-15T12:00:00Z")
        let records = [
            record("research a", completedAt: try date("2026-07-10T09:00:00Z"), outcome: .completed, workspaceName: "Research"),
            record("research b", completedAt: try date("2026-07-05T09:00:00Z"), outcome: .completed, workspaceName: "Research"),
            record("client a", completedAt: try date("2026-07-01T09:00:00Z"), outcome: .completed, workspaceName: "Client Alpha"),
            // Outside the 30-day window (more than 30 days before `now`) — must be excluded.
            record("research too old", completedAt: try date("2026-05-01T09:00:00Z"), outcome: .completed, workspaceName: "Research"),
            // Failed, not completed — must be excluded even though it's tagged and recent.
            record("research failed", completedAt: try date("2026-07-12T09:00:00Z"), outcome: .failed, workspaceName: "Research"),
            // Completed and recent, but not tagged to any workspace — must be excluded.
            record("untagged", completedAt: try date("2026-07-11T09:00:00Z"), outcome: .completed, workspaceName: nil)
        ]

        let entries = WorkspaceTaskBreakdown.summarize(records: records, now: now, calendar: calendar)

        let research = try #require(entries.first { $0.workspaceName == "Research" })
        let clientAlpha = try #require(entries.first { $0.workspaceName == "Client Alpha" })
        #expect(entries.count == 2)
        #expect(research.completedCount == 2)
        #expect(clientAlpha.completedCount == 1)
        #expect(research.fractionOfTotal == 2.0 / 3.0)
        #expect(clientAlpha.fractionOfTotal == 1.0 / 3.0)
    }

    @Test
    func emptyInputProducesAnEmptyResult() {
        let entries = WorkspaceTaskBreakdown.summarize(records: [], now: Date(), calendar: utcISOCalendar())
        #expect(entries.isEmpty)
    }

    @Test
    func windowBoundaryHandlesAMonthCrossingCorrectly() throws {
        // `now` is March 5 — the trailing 30-day window crosses back through all of February
        // (28 days in 2026, a non-leap year) into early March, exercising real month-boundary
        // arithmetic rather than a same-month happy path.
        let calendar = utcISOCalendar()
        let now = try date("2026-03-05T12:00:00Z")
        let startOfToday = calendar.startOfDay(for: now)
        let windowStart = try #require(calendar.date(byAdding: .day, value: -30, to: startOfToday))
        let justOutsideWindow = try #require(calendar.date(byAdding: .day, value: -1, to: windowStart))

        let records = [
            // Exactly at the window's start boundary — the filter uses `>=`, so this is included.
            record("just inside", completedAt: windowStart, outcome: .completed, workspaceName: "Research"),
            // One calendar day earlier — must be excluded.
            record("just outside", completedAt: justOutsideWindow, outcome: .completed, workspaceName: "Research")
        ]

        let entries = WorkspaceTaskBreakdown.summarize(records: records, now: now, calendar: calendar)

        let research = try #require(entries.first { $0.workspaceName == "Research" })
        #expect(entries.count == 1)
        #expect(research.completedCount == 1)
    }

    @Test
    func windowBoundaryIsDSTSafeAcrossASpringForwardTransition() throws {
        // America/New_York observes DST; 2026's "spring forward" is March 8 (clocks jump 2am -> 3am,
        // that calendar day is only 23 hours long in wall-clock terms). `now` is 12 days after that
        // transition, so the trailing 30-day window's start lands 18 days *before* it, crossing the
        // transition — meaning the correct calendar-based windowStart and a naive fixed-seconds
        // computation land exactly 1 hour apart, not on different calendar days. A record placed a
        // full day away from the correct boundary would land on the same side of `>=` under either
        // computation and wouldn't actually distinguish them; this test instead places a record
        // strictly inside that 1-hour gap, which only a genuine regression to raw TimeInterval math
        // would wrongly include.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4

        let now = try date("2026-03-20T12:00:00-04:00")
        let startOfToday = calendar.startOfDay(for: now)
        let correctWindowStart = try #require(
            calendar.date(byAdding: .day, value: -WorkspaceTaskBreakdown.windowDayCount, to: startOfToday)
        )
        let naiveWindowStart = startOfToday.addingTimeInterval(-Double(WorkspaceTaskBreakdown.windowDayCount) * 86400)

        // Confirms this date/timezone combination genuinely crosses a DST transition — if these
        // were equal, the test below wouldn't be exercising anything meaningful.
        #expect(naiveWindowStart != correctWindowStart)

        // Strictly inside the gap: after the naive (wrong) boundary, before the correct one. Wrongly
        // included if the code used naive TimeInterval math; correctly excluded under the actual,
        // calendar-based implementation.
        let insideTheGap = naiveWindowStart.addingTimeInterval(1800)

        let records = [
            record("inside the DST gap", completedAt: insideTheGap, outcome: .completed, workspaceName: "Research")
        ]

        let entries = WorkspaceTaskBreakdown.summarize(records: records, now: now, calendar: calendar)

        #expect(entries.isEmpty)
    }

    private func record(
        _ command: String,
        completedAt: Date,
        duration: TimeInterval = 60,
        outcome: PriorTaskOutcomeStatus,
        workspaceName: String?
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-duration),
            completedAt: completedAt,
            outcomeStatus: outcome,
            workspaceName: workspaceName
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func utcISOCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
