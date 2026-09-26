import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore
import MacAgentTestSupport

/// The Memory page over V2's stores: what each row counts and says, where View leads, and that
/// every Delete removes the entries from the store they live in and nothing else.
@Suite(.serialized)
@MainActor
struct MemoryPageTests {
    // MARK: - Deleting

    /// Each row's Delete empties its own V2 store and leaves every other kind alone.
    @Test(arguments: MemoryCategory.allCases)
    func aRowsDeleteEmptiesItsOwnStoreAndNoOther(category: MemoryCategory) async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        try await fixture.seedOneOfEach()
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()
        for other in MemoryCategory.allCases {
            #expect(memory.count(for: other) == 1, "\(other.title) wasn't seeded")
        }

        await memory.deleteAll(in: category)

        #expect(try await fixture.storedCount(category) == 0)
        #expect(memory.count(for: category) == 0)
        #expect(memory.deletionStatus == MemoryStatus(text: "Deleted \(category.title.lowercased()).", isSuccess: true))
        for other in MemoryCategory.allCases where other != category {
            #expect(try await fixture.storedCount(other) == 1, "deleting \(category.title) took \(other.title)")
            #expect(memory.count(for: other) == 1, "\(other.title)")
        }
    }

    /// A file its store can't read is kept, whatever Delete is pressed on: it may be data a key
    /// would still open, and V2 keeps unreadable files rather than replacing them.
    @Test(arguments: [MemoryCategory.snippets, .recentArtifacts, .clipboardHistory, .approvedApps])
    func aDeleteLeavesAFileItsStoreCantReadExactlyAsItWas(category: MemoryCategory) async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let url: URL = switch category {
        case .snippets: fixture.stores.snippets.fileURL
        case .recentArtifacts: fixture.stores.recentFiles.fileURL
        case .clipboardHistory: fixture.stores.clipboard.fileURL
        default: fixture.stores.approvedApps.fileURL
        }
        let junk = Data("not a store this Mac can read".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try junk.write(to: url)
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()

        await memory.deleteAll(in: category)

        #expect(try Data(contentsOf: url) == junk)
        #expect(memory.deletionStatus == MemoryStatus(text: "Could not delete \(category.title.lowercased()).", isSuccess: false))
    }

    /// Deleting allowed apps from Memory is the same list Settings shows, so Settings sees it too.
    @Test
    func deletingAllowedAppsFromMemoryEmptiesTheListSettingsShows() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        try await fixture.seedOneOfEach()
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()
        #expect(fixture.app.approvedApps.count == 1)

        await memory.deleteAll(in: .approvedApps)

        #expect(fixture.app.approvedApps.isEmpty)
    }

    /// One entry out of the sheet, from each type the sheet lists, and only that entry.
    @Test(arguments: [MemoryCategory.snippets, .recentArtifacts, .clipboardHistory, .approvedApps])
    func aPerEntryDeleteRemovesThatOneRecordFromItsStore(category: MemoryCategory) async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        try await fixture.seedOneOfEach(now: now)
        try fixture.stores.snippets.save(StoredSnippet(trigger: ";addr", expansion: "1 Main St", updatedAt: now))
        try fixture.stores.clipboard.record("second copy", copiedAt: now.addingTimeInterval(1))
        try fixture.stores.approvedApps.approve(bundleIdentifier: "com.apple.Safari", displayName: "Safari", approvedAt: now)
        let second = fixture.folder.appendingPathComponent("notes.txt")
        try "notes".write(to: second, atomically: true, encoding: .utf8)
        try fixture.stores.recentFiles.record(path: second.path, recordedAt: now.addingTimeInterval(1))
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()
        let entries = memory.entries(for: category)
        #expect(entries.count == 2)
        let removed = try #require(entries.first)

        memory.delete(removed, in: category)

        #expect(try await fixture.storedCount(category) == 1)
        #expect(memory.entries(for: category).map(\.id) == [try #require(entries.last).id])
        #expect(memory.count(for: category) == 1)
        #expect(memory.entryFailure == nil)
    }

    /// Routines and task history are removed on their own pages; asking the sheet does nothing.
    @Test
    func theSheetsDeleteDoesNothingForTheTypesThatHaveTheirOwnPages() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        try await fixture.seedOneOfEach()
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()
        let routine = try #require(fixture.app.desk.routines.first)
        let task = try #require(fixture.app.desk.history.first)

        memory.delete(MemoryEntryPresentation(id: routine.id.uuidString, title: routine.name, detail: ""), in: .routines)
        memory.delete(MemoryEntryPresentation(id: "\(task.id)", title: task.goal, detail: ""), in: .taskHistory)

        #expect(try await fixture.storedCount(.routines) == 1)
        #expect(try await fixture.storedCount(.taskHistory) == 1)
    }

    /// A running task may be about to write the store a row's Delete removes, so the Delete waits.
    @Test
    func aRowsDeleteIsRefusedWhileATaskIsRunning() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        try await fixture.seedOneOfEach()
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()
        _ = await fixture.app.desk.ask("Summarise my inbox")
        _ = try await fixture.started()
        #expect(await eventually { fixture.app.isTaskRunning })

        await memory.deleteAll(in: .snippets)

        #expect(memory.deletionStatus == MemoryDeletionCopy.busy)
        #expect(try await fixture.storedCount(.snippets) == 1)
    }

    /// Clipboard history's switch is the setting Settings shows, not a second flag beside it.
    @Test
    func theClipboardRowsSwitchIsTheClipboardSetting() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let memory = MemoryModel(app: fixture.app)

        memory.setRecording(false, for: .clipboardHistory)

        #expect(try fixture.stores.clipboardSettings.load().isEnabled == false)
        #expect(!fixture.app.clipboardHistoryOn)
        #expect(memory.row(for: .clipboardHistory).isRecording == false)

        memory.setRecording(true, for: .clipboardHistory)
        #expect(try fixture.stores.clipboardSettings.load().isEnabled)
        #expect(memory.row(for: .clipboardHistory).isRecording == true)

        // No other row has a switch in V2, so none shows one.
        for category in MemoryCategory.allCases where category != .clipboardHistory {
            #expect(memory.row(for: category).isRecording == nil, "\(category.title)")
        }
    }

    // MARK: - What the rows say

    @Test
    func aRowsCountAndNewestLineComeFromTheRealStores() throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        try fixture.stores.snippets.save(StoredSnippet(trigger: ";sig", expansion: "signature", updatedAt: now.addingTimeInterval(-3600)))
        try fixture.stores.snippets.save(StoredSnippet(trigger: ";addr", expansion: "address", updatedAt: now))
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()

        let row = memory.row(for: .snippets, now: now)

        #expect(row.title == "Snippets")
        #expect(row.count == 2)
        #expect(row.canDelete)
        // The newest of the two, not the first written.
        #expect(row.detailText == "2 snippets · newest \(TaskHistoryDateFormatter.relativeTimestamp(for: now, now: now))")
    }

    @Test
    func everyEmptyRowNamesWhatItCountsAndHasNothingToDelete() throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()

        for category in MemoryCategory.allCases {
            let row = memory.row(for: category)
            #expect(row.count == 0, "\(category.title)")
            #expect(row.detailText == "0 \(category.pluralNoun)", "\(category.title)")
            #expect(!row.canDelete, "\(category.title)")
            #expect(row.moreActionsAccessibilityLabel == "More actions for \(category.title)")
        }
    }

    /// A saved routine shows its count and no date, as it did in V1; task history carries one.
    @Test
    func routinesCarryNoNewestTimestamp() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        try await fixture.seedOneOfEach()
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()

        #expect(memory.row(for: .routines).detailText == "1 routine")
        #expect(memory.newestEntryDate(for: .taskHistory) != nil)
    }

    @Test
    func viewLeadsSomewhereSpecificForEveryMemoryType() {
        let expected: [MemoryCategory: MemoryRowDestination] = [
            .routines: .page(.routines),
            .taskHistory: .page(.tasks),
            .recentArtifacts: .entriesSheet,
            .clipboardHistory: .entriesSheet,
            .snippets: .entriesSheet,
            .approvedApps: .entriesSheet
        ]
        #expect(Set(expected.keys) == Set(MemoryCategory.allCases))
        for category in MemoryCategory.allCases {
            #expect(MemoryRowDestination.of(category) == expected[category], "\(category.title)")
        }
    }

    /// Every confirmation says what it takes; an empty one asks a question and answers nothing.
    @Test
    func everyDestructiveConfirmationAndEmptyStateHasRealWords() {
        for category in MemoryCategory.allCases {
            #expect(!MemoryDeletionCopy.message(for: category).isEmpty, "\(category.title)")
            let opensTheSheet = MemoryRowDestination.of(category) == .entriesSheet
            #expect(MemoryDeletionCopy.entryMessage(for: category).isEmpty == !opensTheSheet, "\(category.title)")
            #expect(MemoryDeletionCopy.emptyMessage(for: category).isEmpty == !opensTheSheet, "\(category.title)")
            #expect(MemoryDeletionCopy.emptyTitle(for: category).hasPrefix("No "), "\(category.title)")
        }
        #expect(MemoryDeletionCopy.message(for: .recentArtifacts).contains("files themselves are not deleted"))
        #expect(MemoryDeletionCopy.message(for: .taskHistory).contains("Files those tasks created are not deleted"))
    }

    @Test
    func theEntriesSheetListsWhatTheStoresHold() async throws {
        let fixture = try PagesFixture()
        defer { fixture.cleanUp() }
        let now = Date()
        try await fixture.seedOneOfEach(now: now)
        try fixture.stores.snippets.save(StoredSnippet(trigger: ";multi", expansion: "line one\nline two", updatedAt: now))
        let memory = MemoryModel(app: fixture.app)
        memory.refresh()

        // Sorted by trigger, and a multi-line expansion is squeezed onto one line.
        let snippets = memory.entries(for: .snippets, now: now)
        #expect(snippets.map(\.title) == [";multi", ";sig"])
        #expect(snippets.first?.detail == "line one line two")

        let apps = memory.entries(for: .approvedApps, now: now)
        #expect(apps.map(\.title) == ["Notes"])
        #expect(apps.first?.id == "com.apple.Notes")
        #expect(try #require(apps.first).detail.hasPrefix("com.apple.Notes · allowed "))

        #expect(memory.entries(for: .clipboardHistory, now: now).map(\.title) == ["copied text"])
        #expect(memory.entries(for: .recentArtifacts, now: now).map(\.title) == ["report.txt"])

        for category in [MemoryCategory.routines, .taskHistory] {
            #expect(memory.entries(for: category).isEmpty, "\(category.title) has a page of its own")
        }
        // The sheet and the row read one source, so they can't disagree.
        for category in MemoryCategory.allCases where MemoryRowDestination.of(category) == .entriesSheet {
            #expect(memory.entries(for: category).count == memory.count(for: category), "\(category.title)")
        }
    }

    @Test
    func theEntriesSheetsMoreActionsLabelNamesTheEntry() {
        let entry = MemoryEntryPresentation(id: "1", title: "sonny.help", detail: "expands to a link")
        #expect(entry.moreActionsAccessibilityLabel == "More actions for sonny.help")
    }
}
