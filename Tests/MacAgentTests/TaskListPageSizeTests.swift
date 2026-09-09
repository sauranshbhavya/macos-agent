import Foundation
import MacAgentCore
import Testing
@testable import MacAgent

/// The Tasks page's "how many to show" preference (the founders' ask of 2026-09-09: "users can
/// filter or sort the given list by how many items they want to see... like Gmail").
@Suite
struct TaskListPageSizeTests {
    // MARK: - visible(_:size:)

    @Test
    func visibleCapsToTheSizesLimitAndKeepsOrder() {
        let records = (0..<10).map { record("\($0)") }

        let shown = TaskListPageSize.visible(records, size: .ten)

        #expect(shown.count == 10)
        #expect(shown == records)
    }

    @Test
    func visibleCapsAShorterListToItsOwnLength() {
        let records = (0..<3).map { record("\($0)") }

        let shown = TaskListPageSize.visible(records, size: .fifty)

        #expect(shown == records)
    }

    @Test
    func visibleTakesOnlyTheFirstLimitRecordsInTheGivenOrder() {
        let records = (0..<10).map { record("\($0)") }

        let shown = TaskListPageSize.visible(records, size: .ten)
        let over = (0..<11).map { record("\($0)") }
        let shownOver = TaskListPageSize.visible(over, size: .ten)

        #expect(shown.map(\.command) == (0..<10).map { "\($0)" })
        #expect(shownOver.map(\.command) == (0..<10).map { "\($0)" })
        #expect(shownOver.count == 10)
    }

    @Test
    func allCapsNothingHoweverManyRecordsThereAre() {
        let records = (0..<500).map { record("\($0)") }

        #expect(TaskListPageSize.visible(records, size: .all) == records)
        #expect(TaskListPageSize.visible([], size: .all).isEmpty)
    }

    @Test
    func limitIsNilOnlyForAll() {
        #expect(TaskListPageSize.ten.limit == 10)
        #expect(TaskListPageSize.twentyFive.limit == 25)
        #expect(TaskListPageSize.fifty.limit == 50)
        #expect(TaskListPageSize.oneHundred.limit == 100)
        #expect(TaskListPageSize.all.limit == nil)
    }

    // MARK: - footer(shown:total:)

    @Test
    func footerNamesHowManyAreShownOutOfTheTotal() {
        #expect(TaskListPageSize.footer(shown: 25, total: 69) == "25 of 69 shown")
        #expect(TaskListPageSize.footer(shown: 10, total: 11) == "10 of 11 shown")
    }

    @Test
    func footerIsNilWhenNothingIsHidden() {
        #expect(TaskListPageSize.footer(shown: 69, total: 69) == nil)
        #expect(TaskListPageSize.footer(shown: 0, total: 0) == nil)
        // Shown can never exceed total in real use, but the guard reads `<` rather than `!=`, so an
        // impossible "shown more than total" is also not reported as something hidden.
        #expect(TaskListPageSize.footer(shown: 70, total: 69) == nil)
    }

    // MARK: - title

    @Test
    func everyCaseHasItsOwnTitle() {
        #expect(TaskListPageSize.allCases.map(\.title) == ["10", "25", "50", "100", "All"])
    }

    // MARK: - TaskListPageSizeStore

    @Test
    func anUnwrittenPreferenceLoadsAsTheDefault() throws {
        try withDefaults { defaults in
            #expect(TaskListPageSizeStore(userDefaults: defaults).load() == .twentyFive)
            #expect(TaskListPageSize.defaultSize == .twentyFive)
        }
    }

    @Test
    func aSavedSizeSurvivesAReload() throws {
        try withDefaults { defaults in
            TaskListPageSizeStore(userDefaults: defaults).save(.fifty)

            // A second store over the same defaults stands in for the next app launch.
            #expect(TaskListPageSizeStore(userDefaults: defaults).load() == .fifty)
        }
    }

    @Test
    func everyCaseRoundTripsThroughTheStoreIncludingAll() throws {
        try withDefaults { defaults in
            let store = TaskListPageSizeStore(userDefaults: defaults)
            for size in TaskListPageSize.allCases {
                store.save(size)
                #expect(store.load() == size)
            }
        }
    }

    @Test
    func anUnknownStoredValueReadsAsTheDefault() throws {
        try withDefaults { defaults in
            // A size this build no longer offers (or a corrupted value) — not one of the five raw
            // values above.
            defaults.set(999, forKey: TaskListPageSizeStore.defaultsKey)

            #expect(TaskListPageSizeStore(userDefaults: defaults).load() == .defaultSize)
        }
    }

    @Test
    func aValueOfTheWrongTypeFallsBackToTheDefault() throws {
        try withDefaults { defaults in
            defaults.set("fifty", forKey: TaskListPageSizeStore.defaultsKey)

            #expect(TaskListPageSizeStore(userDefaults: defaults).load() == .defaultSize)
        }
    }

    @Test
    func theDefaultsKeyIsTheDocumentedOne() {
        #expect(TaskListPageSizeStore.defaultsKey == "com.sonny.preferences.tasksPageSize")
    }

    // MARK: - Fixtures

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "TaskListPageSizeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func record(
        _ command: String,
        completedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-30),
            completedAt: completedAt,
            outcomeStatus: .completed
        )
    }
}
