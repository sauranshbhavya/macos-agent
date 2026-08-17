import Foundation
import Testing
@testable import MacAgentCore

/// Search over task history, and the rule that makes the shorter list window safe.
struct TaskHistorySearchTests {
    // MARK: - The rule the whole feature rests on

    /// **The criterion that proves this feature exists.** A record older than the display window is
    /// invisible with the field empty and reachable the moment something is typed. A test that only
    /// searches recent records would pass against a search box wired to the windowed list, which is
    /// exactly the bug worth catching.
    @Test
    func aQueryReachesPastTheDisplayWindowAndAnEmptyFieldDoesNot() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("recent deploy", completedAt: try date("2026-07-01T12:00:00Z")),
            record("ancient deploy", completedAt: try date("2026-06-11T12:00:00Z"))
        ]
        // 40 days back: outside the 30-day window, well inside the store.
        #expect(TaskHistoryDisplayWindow.withinWindow(records, now: now).map(\.command) == ["recent deploy"])

        let idle = TaskHistorySearch.visibleRecords(records, query: "", now: now)
        let searching = TaskHistorySearch.visibleRecords(records, query: "ancient", now: now)

        #expect(idle.map(\.command) == ["recent deploy"])
        #expect(searching.map(\.command) == ["ancient deploy"])
    }

    @Test
    func clearingTheQueryReturnsTheListToTheWindow() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("recent", completedAt: try date("2026-07-01T12:00:00Z")),
            record("old", completedAt: try date("2026-01-01T12:00:00Z"))
        ]

        #expect(TaskHistorySearch.visibleRecords(records, query: "old", now: now).count == 1)
        // Cleared, and also whitespace-only, which a user produces by selecting all and typing a space.
        #expect(TaskHistorySearch.visibleRecords(records, query: "", now: now).map(\.command) == ["recent"])
        #expect(TaskHistorySearch.visibleRecords(records, query: "   ", now: now).map(\.command) == ["recent"])
    }

    @Test
    func isSearchingAgreesWithWhatTheListDoes() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let old = [record("old", completedAt: try date("2026-01-01T12:00:00Z"))]

        #expect(!TaskHistorySearch.isSearching(""))
        #expect(!TaskHistorySearch.isSearching("  \n "))
        #expect(TaskHistorySearch.isSearching("a"))
        // The agreement itself: whenever isSearching is false the window applies, and when it is
        // true it does not. These two must never disagree — the empty state reads one and the list
        // reads the other.
        #expect(TaskHistorySearch.visibleRecords(old, query: "   ", now: now).isEmpty)
        #expect(TaskHistorySearch.visibleRecords(old, query: "old", now: now).count == 1)
    }

    // MARK: - What matches

    @Test
    func matchingIsCaseAndDiacriticInsensitiveOnCommandAndWorkspace() {
        let records = [
            record("Café résumé polish", completedAt: .fixture),
            record("unrelated", completedAt: .fixture, workspaceName: "Björk Sessions"),
            record("nothing here", completedAt: .fixture)
        ]

        // A real diacritic pair in both directions — plain query against accented text, and the
        // reverse — rather than an ASCII pair that would pass on case-folding alone.
        #expect(TaskHistorySearch.matching(records, query: "cafe").map(\.command) == ["Café résumé polish"])
        #expect(TaskHistorySearch.matching(records, query: "CAFÉ").map(\.command) == ["Café résumé polish"])
        #expect(TaskHistorySearch.matching(records, query: "resume").map(\.command) == ["Café résumé polish"])
        // The workspace name is searchable too, and with the same folding.
        #expect(TaskHistorySearch.matching(records, query: "bjork").map(\.command) == ["unrelated"])
        #expect(TaskHistorySearch.matching(records, query: "BJÖRK").map(\.command) == ["unrelated"])
    }

    @Test
    func aQueryMatchingNothingReturnsNothingRatherThanEverything() {
        let records = [
            record("deploy the site", completedAt: .fixture),
            record("archive the inbox", completedAt: .fixture)
        ]

        #expect(TaskHistorySearch.matching(records, query: "zzzz").isEmpty)
    }

    @Test
    func anEmptyQueryMatchesEverythingSoCallersNeedNoSpecialCase() {
        let records = [
            record("one", completedAt: .fixture),
            record("two", completedAt: .fixture)
        ]

        #expect(TaskHistorySearch.matching(records, query: "").count == 2)
        #expect(TaskHistorySearch.matching(records, query: "  ").count == 2)
    }

    @Test
    func aRecordWithNoWorkspaceIsSearchableAndDoesNotMatchTheEmptyWorkspaceName() {
        let records = [record("solo task", completedAt: .fixture, workspaceName: nil)]

        #expect(TaskHistorySearch.matching(records, query: "solo").count == 1)
        // The nil workspace becomes "" in the searchable text; a query of a single space must not
        // match through it, and is treated as no query at all.
        #expect(TaskHistorySearch.matching(records, query: " ").count == 1)
    }

    @Test
    func matchingPreservesTheOrderItWasGiven() {
        let records = [
            record("alpha task", completedAt: .fixture),
            record("beta task", completedAt: .fixture),
            record("gamma task", completedAt: .fixture)
        ]

        #expect(TaskHistorySearch.matching(records, query: "task").map(\.command)
            == ["alpha task", "beta task", "gamma task"])
    }

    /// Screen records are deliberately unsearchable — the text is a model's description of the
    /// user's screen, and reading it would cost a decrypt of up to 500 journal sessions per
    /// keystroke. The link is on the record; searching for it must find nothing.
    @Test
    func screenRecordsAreNotSearchable() {
        let records = [
            record("open Discord", completedAt: .fixture, visionSessionID: "session-abc123")
        ]

        #expect(TaskHistorySearch.matching(records, query: "session-abc123").isEmpty)
        #expect(TaskHistorySearch.matching(records, query: "abc123").isEmpty)
        // The record itself is still findable by the words the user typed.
        #expect(TaskHistorySearch.matching(records, query: "discord").count == 1)
    }

    // MARK: - The invariant most likely to break

    /// Search and the window are display-only. Every statistic reads the un-windowed, unsearched
    /// set, so typing must not move a single number on Insights, the workspace breakdown, or the
    /// per-workspace counts. Asserted directly, because this is the one that would break silently.
    @Test
    func searchingDoesNotMoveAnyInsightsNumber() throws {
        let now = try date("2026-07-21T12:00:00Z")
        let records = [
            record("deploy the site", completedAt: try date("2026-07-20T12:00:00Z"), workspaceName: "Client"),
            record("archive the inbox", completedAt: try date("2026-07-19T12:00:00Z"), workspaceName: "Client"),
            record("old deploy", completedAt: try date("2026-01-02T12:00:00Z"), workspaceName: "Client"),
            record("older still", completedAt: try date("2025-12-02T12:00:00Z"), workspaceName: "Other")
        ]

        let before = TaskHistoryInsights.summarize(records: records, now: now)
        let breakdownBefore = WorkspaceTaskBreakdown.summarize(records: records, now: now)

        // What the page renders changes...
        let listWhileIdle = TaskHistorySearch.visibleRecords(records, query: "", now: now)
        let listWhileSearching = TaskHistorySearch.visibleRecords(records, query: "deploy", now: now)
        // Contents, not counts — these two happen to be the same length, and comparing lengths
        // would have let a no-op "search" pass.
        #expect(listWhileIdle.map(\.command) == ["deploy the site", "archive the inbox"])
        #expect(listWhileSearching.map(\.command) == ["deploy the site", "old deploy"])
        #expect(listWhileIdle.map(\.command) != listWhileSearching.map(\.command))

        // ...and every statistic is computed from the same records it always was.
        #expect(TaskHistoryInsights.summarize(records: records, now: now) == before)
        #expect(WorkspaceTaskBreakdown.summarize(records: records, now: now) == breakdownBefore)
    }

    // MARK: - Fixtures

    private func record(
        _ command: String,
        completedAt: Date,
        workspaceName: String? = nil,
        visionSessionID: String? = nil
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-60),
            completedAt: completedAt,
            outcomeStatus: .completed,
            workspaceName: workspaceName,
            visionSessionID: visionSessionID
        )
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
