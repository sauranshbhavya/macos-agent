import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

@Suite
struct TaskSectionCollapseStateTests {
    @Test
    func everySectionStartsExpanded() {
        let state = TaskSectionCollapseState()

        #expect(state.collapsedSectionIDs.isEmpty)
        #expect(state.isExpanded("Done"))
        #expect(state.isExpanded("Failed"))
        #expect(state.isExpanded("Canceled"))
        #expect(state.isExpanded(TaskSectionCollapseState.inProgressSectionID))
        // A section this state has never heard of is expanded too — the default has to hold for
        // sections that did not exist when the preference was written.
        #expect(state.isExpanded("Some Future Section"))
    }

    @Test
    func togglingCollapsesThenExpandsTheSameSection() {
        var state = TaskSectionCollapseState()

        state.toggle("Done")
        #expect(state.isExpanded("Done") == false)
        #expect(state.collapsedSectionIDs == ["Done"])

        state.toggle("Done")
        #expect(state.isExpanded("Done"))
        #expect(state.collapsedSectionIDs.isEmpty)
    }

    @Test
    func collapsingOneSectionLeavesTheOthersExpanded() {
        var state = TaskSectionCollapseState()

        state.toggle("Done")

        #expect(state.isExpanded("Done") == false)
        #expect(state.isExpanded("Failed"))
        #expect(state.isExpanded("Canceled"))
        #expect(state.isExpanded(TaskSectionCollapseState.inProgressSectionID))
        #expect(state.collapsedSectionIDs == ["Done"])
    }

    @Test
    func sectionsCollapseIndependentlyAndAccumulate() {
        var state = TaskSectionCollapseState()

        state.toggle("Done")
        state.toggle(TaskSectionCollapseState.inProgressSectionID)

        #expect(state.collapsedSectionIDs == ["Done", "In Progress"])

        state.toggle("Done")

        #expect(state.collapsedSectionIDs == ["In Progress"])
        #expect(state.isExpanded("Done"))
        #expect(state.isExpanded(TaskSectionCollapseState.inProgressSectionID) == false)
    }

    @Test
    func setExpandedIsIdempotentInBothDirections() {
        var state = TaskSectionCollapseState()

        state.setExpanded(true, for: "Done")
        #expect(state.collapsedSectionIDs.isEmpty)

        state.setExpanded(false, for: "Done")
        state.setExpanded(false, for: "Done")
        #expect(state.collapsedSectionIDs == ["Done"])

        state.setExpanded(true, for: "Done")
        state.setExpanded(true, for: "Done")
        #expect(state.collapsedSectionIDs.isEmpty)
    }

    @Test
    func theInProgressIdentifierMatchesTheHeaderTitleItRenders() {
        // The live group is not one of `TaskHistoryGrouping`'s sections, so nothing else pins this
        // string. The view uses it as both the header title and the persistence key.
        #expect(TaskSectionCollapseState.inProgressSectionID == "In Progress")
        // ...and it cannot collide with an outcome section, whose identity is its own title.
        let outcomeTitles = TaskHistoryGrouping.groupedByOutcome(records: [
            record("a", outcome: .completed),
            record("b", outcome: .failed),
            record("c", outcome: .canceled)
        ]).map(\.id)
        #expect(outcomeTitles == ["Done", "Failed", "Canceled"])
        #expect(outcomeTitles.contains(TaskSectionCollapseState.inProgressSectionID) == false)
    }
}

@Suite
struct TaskSectionCollapseStoreTests {
    @Test
    func anUnwrittenPreferenceLoadsEverythingExpanded() throws {
        try withDefaults { defaults in
            let loaded = TaskSectionCollapseStore(userDefaults: defaults).load()

            #expect(loaded == TaskSectionCollapseState())
            #expect(loaded.isExpanded("Done"))
            #expect(loaded.collapsedSectionIDs.isEmpty)
        }
    }

    @Test
    func collapsedSectionsSurviveAReload() throws {
        try withDefaults { defaults in
            var state = TaskSectionCollapseState()
            state.toggle("Done")
            state.toggle(TaskSectionCollapseState.inProgressSectionID)
            TaskSectionCollapseStore(userDefaults: defaults).save(state)

            // A second store over the same defaults stands in for the next app launch.
            let reloaded = TaskSectionCollapseStore(userDefaults: defaults).load()

            #expect(reloaded == state)
            #expect(reloaded.collapsedSectionIDs == ["Done", "In Progress"])
            #expect(reloaded.isExpanded("Done") == false)
            #expect(reloaded.isExpanded(TaskSectionCollapseState.inProgressSectionID) == false)
            #expect(reloaded.isExpanded("Canceled"))
        }
    }

    @Test
    func expandingAgainIsPersistedTooRatherThanLeavingTheSectionCollapsedForever() throws {
        try withDefaults { defaults in
            let store = TaskSectionCollapseStore(userDefaults: defaults)

            var state = TaskSectionCollapseState()
            state.toggle("Done")
            store.save(state)
            #expect(store.load().isExpanded("Done") == false)

            state.toggle("Done")
            store.save(state)

            #expect(store.load().isExpanded("Done"))
            #expect(store.load().collapsedSectionIDs.isEmpty)
            #expect(defaults.object(forKey: TaskSectionCollapseStore.defaultsKey) as? [String] == [])
        }
    }

    @Test
    func thePersistedRepresentationIsASortedStringArrayUnderOneKey() throws {
        try withDefaults { defaults in
            var state = TaskSectionCollapseState()
            state.toggle("Failed")
            state.toggle("Canceled")
            state.toggle("Done")

            TaskSectionCollapseStore(userDefaults: defaults).save(state)

            #expect(TaskSectionCollapseStore.defaultsKey == "com.sonny.preferences.tasksCollapsedSections")
            // Sorted, not set-iteration order — an unstable representation would rewrite the
            // defaults on every save with no actual change.
            #expect(
                defaults.object(forKey: TaskSectionCollapseStore.defaultsKey) as? [String]
                    == ["Canceled", "Done", "Failed"]
            )
        }
    }

    @Test
    func aValueOfTheWrongTypeFallsBackToEverythingExpanded() throws {
        try withDefaults { defaults in
            defaults.set("Done", forKey: TaskSectionCollapseStore.defaultsKey)

            let loaded = TaskSectionCollapseStore(userDefaults: defaults).load()

            #expect(loaded == TaskSectionCollapseState())
            #expect(loaded.isExpanded("Done"))
        }
    }

    @Test
    func anUnknownPersistedSectionIsCarriedButAffectsNothingElse() throws {
        try withDefaults { defaults in
            // A section that no longer exists (renamed, removed) must not leak into a live one.
            defaults.set(["Retired Section"], forKey: TaskSectionCollapseStore.defaultsKey)

            let loaded = TaskSectionCollapseStore(userDefaults: defaults).load()

            #expect(loaded.isExpanded("Done"))
            #expect(loaded.isExpanded("Retired Section") == false)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "TaskSectionCollapseStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

@Suite
struct TaskSectionPresentationTests {
    @Test
    func anExpandedSectionExposesEveryRecordAndItsCount() throws {
        let done = record("finished", outcome: .completed)
        let sections = TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: [done]),
            collapse: TaskSectionCollapseState()
        )

        let section = try #require(sections.first)
        #expect(section.id == "Done")
        #expect(section.title == "Done")
        #expect(section.isExpanded)
        #expect(section.count == 1)
        #expect(section.visibleRecords == [done])
    }

    @Test
    func anExpandedSectionHandsBackTheGroupingsRecordsInOrder() throws {
        let first = record("first", outcome: .completed, completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = record("second", outcome: .completed, completedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = record("third", outcome: .completed, completedAt: Date(timeIntervalSince1970: 1_700_000_200))
        let grouped = TaskHistoryGrouping.groupedByOutcome(records: [first, second, third])
        let groupedRecords = try #require(grouped.first).records

        let section = try #require(
            TaskSectionPresentation.sections(for: grouped, collapse: TaskSectionCollapseState()).first
        )

        // Order is the grouping's, passed through untouched — no sort, no reverse, no filter.
        #expect(section.visibleRecords == groupedRecords)
        #expect(section.visibleRecords.map(\.command) == ["first", "second", "third"])
        #expect(section.count == 3)
    }

    @Test
    func aCollapsedSectionKeepsItsCountButRendersNoRows() throws {
        let records = (0..<4).map { record("finished \($0)", outcome: .completed) }
        var collapse = TaskSectionCollapseState()
        collapse.toggle("Done")

        let sections = TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: records),
            collapse: collapse
        )

        let section = try #require(sections.first)
        #expect(section.isExpanded == false)
        // The header count is the whole reason a collapsed section is still useful.
        #expect(section.count == 4)
        #expect(section.visibleRecords.isEmpty)
    }

    @Test
    func aTaskCompletingWhileTheSectionIsCollapsedBumpsTheCountWithoutExpandingIt() throws {
        var collapse = TaskSectionCollapseState()
        collapse.toggle("Done")
        let before = [record("first", outcome: .completed)]
        let after = before + [record("second", outcome: .completed)]

        let beforeSection = try #require(
            TaskSectionPresentation.sections(
                for: TaskHistoryGrouping.groupedByOutcome(records: before),
                collapse: collapse
            ).first
        )
        let afterSection = try #require(
            TaskSectionPresentation.sections(
                for: TaskHistoryGrouping.groupedByOutcome(records: after),
                collapse: collapse
            ).first
        )

        #expect(beforeSection.count == 1)
        #expect(afterSection.count == 2)
        #expect(afterSection.isExpanded == false)
        #expect(afterSection.visibleRecords.isEmpty)
    }

    @Test
    func collapsingOneSectionDoesNotHideAnother() throws {
        let done = record("finished", outcome: .completed)
        let failed = record("broke", outcome: .failed)
        let canceled = record("stopped", outcome: .canceled)
        var collapse = TaskSectionCollapseState()
        collapse.toggle("Done")

        let sections = TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: [done, failed, canceled]),
            collapse: collapse
        )

        #expect(sections.map(\.id) == ["Done", "Failed", "Canceled"])
        #expect(sections.map(\.isExpanded) == [false, true, true])
        #expect(sections.map(\.count) == [1, 1, 1])
        #expect(sections.map(\.visibleRecords) == [[], [failed], [canceled]])
    }

    @Test
    func sectionOrderAndIdentityComeStraightFromTheGrouping() {
        let records = [
            record("stopped", outcome: .canceled),
            record("finished", outcome: .completed),
            record("broke", outcome: .failed)
        ]
        let grouped = TaskHistoryGrouping.groupedByOutcome(records: records)

        let sections = TaskSectionPresentation.sections(for: grouped, collapse: TaskSectionCollapseState())

        #expect(sections.map(\.id) == grouped.map(\.id))
        #expect(sections.map(\.title) == grouped.map(\.title))
        #expect(sections.map(\.count) == grouped.map(\.records.count))
    }

    @Test
    func noSectionsMeansNoPresentations() {
        let sections = TaskSectionPresentation.sections(
            for: TaskHistoryGrouping.groupedByOutcome(records: []),
            collapse: TaskSectionCollapseState()
        )

        #expect(sections.isEmpty)
    }
}

private func record(
    _ command: String,
    outcome: PriorTaskOutcomeStatus,
    completedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> CompletedTaskRecord {
    CompletedTaskRecord(
        command: command,
        startedAt: completedAt.addingTimeInterval(-30),
        completedAt: completedAt,
        outcomeStatus: outcome
    )
}
