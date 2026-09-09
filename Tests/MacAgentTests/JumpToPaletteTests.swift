import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// The ⌘K jump-to palette's pure matching and grouping (phase 5), driven with no view host — the
/// same reason `TaskSectionCollapseStateTests` drives its presentation type directly.
@Suite
struct JumpToPaletteTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private static func routine(_ name: String) -> StoredRoutine {
        StoredRoutine(name: name, steps: [])
    }

    private static func workspace(_ name: String) -> StoredWorkspace {
        StoredWorkspace(name: name, apps: [], urls: [])
    }

    private static func task(_ command: String, minutesAgo: Double, id: String? = nil) -> CompletedTaskRecord {
        let startedAt = now.addingTimeInterval(-minutesAgo * 60)
        return CompletedTaskRecord(
            id: id ?? command,
            command: command,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(5),
            outcomeStatus: .completed
        )
    }

    @Test
    func anEmptyQueryShowsPagesFirstAndFillsEveryOtherGroupWithItsFiveMostRecent() {
        let presentation = JumpToPalettePresentation.results(
            query: "",
            pages: CommandCenterDestination.allCases,
            routines: (1...7).map { Self.routine("Routine \($0)") },
            workspaces: [Self.workspace("Personal")],
            tasks: (1...3).map { Self.task("Task \($0)", minutesAgo: Double($0)) },
            now: Self.now
        )

        #expect(presentation.groups.map(\.label) == ["Pages", "Routines", "Workspaces", "Tasks"])
        #expect(presentation.groups[0].rows.count == CommandCenterDestination.allCases.count)
        #expect(presentation.groups[0].rows.map(\.title) == CommandCenterDestination.allCases.map(\.title))
        // Seven routines saved, an empty query shows the five most recent — the last five in
        // insertion order, newest first.
        #expect(presentation.groups[1].rows.map(\.title) == ["Routine 7", "Routine 6", "Routine 5", "Routine 4", "Routine 3"])
    }

    @Test
    func substringMatchingIsCaseInsensitiveOnTheRowsOwnTitle() {
        let presentation = JumpToPalettePresentation.results(
            query: "wORKspACE",
            pages: CommandCenterDestination.allCases,
            routines: [],
            workspaces: [Self.workspace("Client Workspace"), Self.workspace("Personal")],
            tasks: [],
            now: Self.now
        )

        // "Workspaces" (the page) and "Client Workspace" (the workspace) both match the query
        // case-insensitively; "Personal" does not.
        let titles = Set(presentation.groups.flatMap { $0.rows.map(\.title) })
        #expect(titles == ["Workspaces", "Client Workspace"])
    }

    @Test
    func eachGroupIsCappedAtEightRowsUnderANonEmptyQuery() {
        let presentation = JumpToPalettePresentation.results(
            query: "routine",
            pages: [],
            routines: (1...12).map { Self.routine("Routine \($0)") },
            workspaces: [],
            tasks: [],
            now: Self.now
        )

        #expect(presentation.groups.count == 1)
        #expect(presentation.groups[0].rows.count == JumpToPalettePresentation.groupCap)
    }

    @Test
    func aTaskRowsTrailingTextComesFromTheSharedRelativeTimestampFormatter() {
        let record = Self.task("Send the invoice", minutesAgo: 30)
        let presentation = JumpToPalettePresentation.results(
            query: "invoice",
            pages: [],
            routines: [],
            workspaces: [],
            tasks: [record],
            now: Self.now
        )

        let row = try? #require(presentation.groups.first?.rows.first)
        #expect(row?.trailing == TaskHistoryDateFormatter.relativeTimestamp(for: record.startedAt, now: Self.now))
    }

    @Test
    func onlyTheMostRecentTwentyTasksAreEverSearched() {
        // Twenty-five tasks, oldest first; the query matches all of them, so only the window size
        // proves whether the twenty-first-oldest was ever considered.
        let tasks = (1...25).map { Self.task("Command \($0)", minutesAgo: Double(26 - $0)) }
        let presentation = JumpToPalettePresentation.results(
            query: "Command",
            pages: [],
            routines: [],
            workspaces: [],
            tasks: tasks,
            now: Self.now
        )

        let titles = presentation.groups.first?.rows.map(\.title) ?? []
        // The most recent twenty are commands 6 through 25; the oldest five (1 through 5) fall
        // outside the search window and must not appear even though the substring matches.
        #expect(!titles.contains("Command 1"))
        #expect(!titles.contains("Command 5"))
        #expect(titles.contains("Command 25"))
        // And within the window the newest task leads: the sort is by `startedAt`, not array order.
        #expect(titles.first == "Command 25")
    }

    /// A query of only whitespace is the empty query: the field is focused on appear, and a stray
    /// space must not turn the pages list into "Nothing matches".
    @Test
    func aWhitespaceOnlyQueryReadsAsEmpty() {
        let presentation = JumpToPalettePresentation.results(
            query: "   ",
            pages: CommandCenterDestination.allCases,
            routines: [],
            workspaces: [],
            tasks: [],
            now: Self.now
        )

        #expect(presentation.groups.map(\.label) == ["Pages"])
        #expect(presentation.groups[0].rows.count == CommandCenterDestination.allCases.count)
    }

    @Test
    func aQueryThatMatchesNothingIsEmptyRatherThanFallingBackToPages() {
        let presentation = JumpToPalettePresentation.results(
            query: "xyzzy-does-not-exist-anywhere",
            pages: CommandCenterDestination.allCases,
            routines: [Self.routine("Morning")],
            workspaces: [Self.workspace("Personal")],
            tasks: [Self.task("Send the invoice", minutesAgo: 5)],
            now: Self.now
        )

        #expect(presentation.isEmpty)
        #expect(presentation.groups.isEmpty)
    }

    @Test
    func pagesKeepTheirSidebarOrdinalEvenWhenFilteringDropsAnEarlierPage() {
        // Filtering to "o" drops "Insights" (no "o") from the front, so the ordinals of the pages
        // that remain must still read as their real sidebar position, not their position in the
        // filtered list.
        let presentation = JumpToPalettePresentation.results(
            query: "o",
            pages: CommandCenterDestination.allCases,
            routines: [],
            workspaces: [],
            tasks: [],
            now: Self.now
        )

        let workspacesRow = presentation.groups.first?.rows.first { $0.title == "Workspaces" }
        #expect(workspacesRow?.trailing == "⌘4")
    }
}
