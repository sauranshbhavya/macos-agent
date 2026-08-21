import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// The delete surface's logic, pulled out of the SwiftUI body so the suite can reach it.
///
/// This repository has no view-rendering tests and no view-inspection dependency, so anything left
/// inside a `body` is guarded only by the manual checklist. Everything a test *can* hold — the two
/// labels, the row identity, the gating, the sheet height, the confirmation copy — lives in
/// `TaskDeletePresentation` for that reason. What remains unpinned is enumerated on SONNY-117's
/// closing comment rather than left for someone to discover.
struct TaskDeletePresentationTests {
    // MARK: - Naming

    /// The founder's rule of 2026-08-16: a precise label is not explanation, and the label carries
    /// the whole meaning because no sentence may sit beside it. Two delete actions near each other
    /// have to be distinguishable at a glance, so bare "Delete" cannot appear twice with different
    /// reach.
    @Test
    func theTwoDeleteLabelsAreDistinguishableAndNeitherIsBareDelete() {
        let task = TaskDeletePresentation.taskActionLabel
        let screenRecord = TaskDeletePresentation.screenRecordActionLabel

        #expect(task != screenRecord)
        #expect(task != "Delete")
        #expect(screenRecord != "Delete")
        // Each names its own object, so neither can be read as the other with words left off.
        #expect(task == "Delete task")
        #expect(screenRecord == "Delete what Sonny did on screen")
        // The confirm buttons are distinguishable too — a dialog is where a bare "Delete" would be
        // easiest to reach for and hardest to tell apart.
        #expect(TaskDeletePresentation.taskConfirmButtonLabel != TaskDeletePresentation.screenRecordConfirmButtonLabel)
        #expect(TaskDeletePresentation.taskConfirmButtonLabel != "Delete")
        #expect(TaskDeletePresentation.screenRecordConfirmButtonLabel != "Delete")
    }

    /// The screen-record label reuses the section title it sits beside, so the object of the verb is
    /// literally on screen next to the action rather than described in a sentence.
    @Test
    func theScreenRecordLabelNamesTheSectionItSitsBeside() {
        let title = TaskDeletePresentation.screenRecordSectionTitle
        #expect(title == "What Sonny did on screen")
        #expect(
            TaskDeletePresentation.screenRecordActionLabel.lowercased()
                .contains(title.lowercased())
        )
    }

    // MARK: - Identity

    /// What the old compound keys could not do. Both the sheet's `TaskLogEntry.id` and the list's
    /// `ForEach(id: \.startedAt)` collide for these two, because the store persists whole-second
    /// timestamps — the sheet would open the wrong twin and the list would show one row for two.
    @Test
    func rowIdentityTellsApartTwinsThatCollideOnTheOldCompoundKey() {
        let sameSecond = Date(timeIntervalSince1970: 1_700_000_000)
        let first = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: sameSecond,
            completedAt: sameSecond.addingTimeInterval(2),
            outcomeStatus: .completed
        )
        let second = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: sameSecond,
            completedAt: sameSecond.addingTimeInterval(2),
            outcomeStatus: .failed
        )

        // The old keys really do collide, asserted rather than assumed.
        #expect(first.startedAt == second.startedAt)
        let oldEntryKey = { (r: CompletedTaskRecord) in "\(r.startedAt.timeIntervalSince1970)-\(r.command)" }
        #expect(oldEntryKey(first) == oldEntryKey(second))

        #expect(first.taskRowIdentity != second.taskRowIdentity)
        #expect(TaskDeletePresentation.rowIdentity(for: first) == first.taskRowIdentity)
    }

    @Test
    func rowIdentityIsTheRecordIdAndFallsBackOnlyWhenThereIsNone() throws {
        var record = CompletedTaskRecord(
            command: "open Safari",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_010),
            outcomeStatus: .completed
        )
        let realID = try #require(record.id)
        #expect(record.taskRowIdentity == realID)

        // Reachable only if SONNY-115's backfill could not write. The fallback is the old key, and
        // it is deliberately no better than what it replaces — but it is stable across renders,
        // which a fresh identity per render would not be.
        record.id = nil
        #expect(record.taskRowIdentity == "legacy-1700000000.0-open Safari")
        #expect(record.taskRowIdentity == record.taskRowIdentity)
    }

    // MARK: - What the sheet shows once the screen record is gone

    /// The criterion this ticket exists to keep: a task whose screen record was deleted and a task
    /// that never ran one render identically. Asserted on all three things that decide the
    /// rendering — the state, whether the section appears, and the sheet's own height. The height
    /// matters as much as the section: keyed on `visionSessionID` instead, a task whose session was
    /// deleted would open a 560-tall sheet with a gap where the section used to be.
    @Test
    func aDeletedScreenRecordRendersLikeATaskThatNeverRanOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = journalStore(root: root)
        try journal.save(
            VisionSessionRecord(
                id: "session-1",
                goal: "reply in Discord",
                appDisplayName: "Discord",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let ranASession = record(visionSessionID: "session-1")
        let neverRanOne = record(visionSessionID: nil)

        // While the session is there the two differ, so the equality below is not vacuous.
        let whilePresent = TaskDeletePresentation.resolveScreenRecord(for: ranASession, journalStore: journal)
        #expect(whilePresent != .none)
        #expect(TaskDeletePresentation.showsScreenRecordSection(whilePresent))

        try journal.delete(id: "session-1")

        let afterDelete = TaskDeletePresentation.resolveScreenRecord(for: ranASession, journalStore: journal)
        let neverHad = TaskDeletePresentation.resolveScreenRecord(for: neverRanOne, journalStore: journal)

        #expect(afterDelete == .none)
        #expect(afterDelete == neverHad)
        #expect(!TaskDeletePresentation.showsScreenRecordSection(afterDelete))
        #expect(
            TaskDeletePresentation.showsScreenRecordSection(afterDelete)
                == TaskDeletePresentation.showsScreenRecordSection(neverHad)
        )
        // The sheet is the same sheet, section for section and point for point (row E moved the
        // height to `TaskDetailPresentation`, which sums over the sections present rather than
        // branching on this one state).
        let noResult = record(visionSessionID: "session-1")
        #expect(
            TaskDetailPresentation.sections(for: noResult, screenRecord: afterDelete)
                == TaskDetailPresentation.sections(for: noResult, screenRecord: neverHad)
        )
        #expect(
            TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: afterDelete)
                == TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: neverHad)
        )
        #expect(
            TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: afterDelete)
                != TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: whilePresent)
        )
        // And no delete action for a section that is not there.
        #expect(!TaskDeletePresentation.showsScreenRecordDeleteAction(afterDelete))
    }

    /// The third route to the same state, tying this to SONNY-119's differential lifetime: a
    /// screen record that aged out at the journal's cap has to be indistinguishable from one the
    /// user deleted, because the product may not explain the difference.
    @Test
    func anEvictedScreenRecordResolvesToTheSameStateAsADeletedOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = journalStore(root: root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Seeded straight into the file, then one `save(_:)` to trigger eviction. Calling `save(_:)`
        // 501 times would be 501 decrypt-modify-re-encrypt cycles, and this suite runs in parallel
        // with timing-sensitive vision-session tests that a second of stolen CPU makes flaky.
        // Eviction lives in `save(_:)`, so the path under test is still the real one.
        let seeded = (0..<VisionSessionJournalStore.maxSessions).map { index in
            VisionSessionRecord(
                id: index == 0 ? "oldest" : "later-\(index)",
                goal: "g",
                appDisplayName: "Discord",
                startedAt: Date(timeInterval: TimeInterval(index), since: base)
            )
        }
        try seedJournal(seeded, root: root)
        try journal.save(
            VisionSessionRecord(
                id: "newest",
                goal: "g",
                appDisplayName: "Discord",
                startedAt: Date(timeInterval: TimeInterval(VisionSessionJournalStore.maxSessions), since: base)
            )
        )
        // The seed really did go over the cap and "oldest" really was the one to go.
        #expect(try journal.loadAll().count == VisionSessionJournalStore.maxSessions)
        #expect(try journal.record(withID: "newest") != nil)

        let evicted = TaskDeletePresentation.resolveScreenRecord(
            for: record(visionSessionID: "oldest"),
            journalStore: journal
        )
        let neverRan = TaskDeletePresentation.resolveScreenRecord(
            for: record(visionSessionID: nil),
            journalStore: journal
        )

        #expect(evicted == .none)
        #expect(evicted == neverRan)
        let noResult = record(visionSessionID: "oldest")
        #expect(
            TaskDetailPresentation.sections(for: noResult, screenRecord: evicted)
                == TaskDetailPresentation.sections(for: noResult, screenRecord: neverRan)
        )
        #expect(
            TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: evicted)
                == TaskDetailPresentation.sheetHeight(for: noResult, screenRecord: neverRan)
        )
    }

    /// An unreadable journal is deliberately *not* folded into "gone". It keeps the load-failure
    /// wording it has always had, and it offers no delete — the store's delete is a
    /// read-modify-write, so it would fail on exactly the file that would not read.
    @Test
    func anUnreadableJournalKeepsItsLoadFailureWordingAndOffersNoDelete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption(byte: 0x42)
        ).save(
            VisionSessionRecord(
                id: "session-1",
                goal: "g",
                appDisplayName: "Discord",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        // A different key: the file is there and will not read back.
        let wrongKey = journalStore(root: root, byte: 0x99)

        let state = TaskDeletePresentation.resolveScreenRecord(
            for: record(visionSessionID: "session-1"),
            journalStore: wrongKey
        )

        guard case .unreadable(let message) = state else {
            Issue.record("Expected .unreadable, got \(state)")
            return
        }
        #expect(message.hasPrefix("This session's record could not be decrypted or decoded"))
        #expect(state != .none)
        // It renders — an unreadable journal is a real problem the user is entitled to see.
        #expect(TaskDeletePresentation.showsScreenRecordSection(state))
        #expect(
            TaskDetailPresentation.sheetHeight(for: record(visionSessionID: "session-1"), screenRecord: state) == 560
        )
        // But it offers no delete.
        #expect(!TaskDeletePresentation.showsScreenRecordDeleteAction(state))
    }

    // MARK: - Confirmation copy

    @Test
    func theTaskConfirmationNamesTheScreenRecordOnlyWhenThereIsOne() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = journalStore(root: root)
        try journal.save(
            VisionSessionRecord(
                id: "session-1",
                goal: "g",
                appDisplayName: "Discord",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let present = TaskDeletePresentation.resolveScreenRecord(
            for: record(visionSessionID: "session-1"),
            journalStore: journal
        )

        #expect(TaskDeletePresentation.taskConfirmationMessage(for: present) != nil)
        #expect(TaskDeletePresentation.taskConfirmationMessage(for: TaskScreenRecordState.none) == nil)
        // The row's variant reads the link alone, so it needs no journal read at all.
        #expect(TaskDeletePresentation.taskConfirmationMessage(for: record(visionSessionID: "session-1")) != nil)
        #expect(TaskDeletePresentation.taskConfirmationMessage(for: record(visionSessionID: nil)) == nil)
    }

    @Test
    func theConfirmationTitleQuotesTheCommandAndSurvivesAnEmptyOrVeryLongOne() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let ordinary = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: base,
            completedAt: base,
            outcomeStatus: .completed
        )
        #expect(TaskDeletePresentation.taskConfirmationTitle(for: ordinary) == "Delete “archive the inbox”?")

        let empty = CompletedTaskRecord(command: "   ", startedAt: base, completedAt: base, outcomeStatus: .completed)
        #expect(TaskDeletePresentation.taskConfirmationTitle(for: empty) == "Delete this task?")

        let long = CompletedTaskRecord(
            command: String(repeating: "a", count: 300),
            startedAt: base,
            completedAt: base,
            outcomeStatus: .completed
        )
        let title = TaskDeletePresentation.taskConfirmationTitle(for: long)
        #expect(title.hasSuffix("…”?"))
        #expect(title.count < 100)
    }

    @Test
    func theScreenRecordConfirmationSaysWhatSurvives() {
        // The fact that distinguishes this action from the other one, in the one place a user is
        // deciding between them.
        #expect(TaskDeletePresentation.screenRecordConfirmationMessage == "The task stays in your history.")
        #expect(TaskDeletePresentation.screenRecordConfirmationTitle == "Delete what Sonny did on screen?")
    }

    // MARK: - Fixtures

    private func record(visionSessionID: String?) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: "reply in Discord",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_030),
            outcomeStatus: .completed,
            visionSessionID: visionSessionID
        )
    }

    private func journalStore(root: URL, byte: UInt8 = 0x42) -> VisionSessionJournalStore {
        VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption(byte: byte)
        )
    }

    private func encryption(byte: UInt8) -> LocalStorageEncryption {
        LocalStorageEncryption(keyManager: FixedKeyManager(bytes: Data(repeating: byte, count: 32)))
    }

    /// Mirrors `VisionSessionJournalStore`'s own encoder settings, so the seeded file is one the
    /// store reads back exactly as if it had written it.
    private func seedJournal(_ records: [VisionSessionRecord], root: URL, byte: UInt8 = 0x42) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encryption(byte: byte)
            .encode(records, encoder: encoder)
            .write(to: root.appendingPathComponent("vision-sessions.json"), options: .atomic)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskDeletePresentationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct FixedKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}
