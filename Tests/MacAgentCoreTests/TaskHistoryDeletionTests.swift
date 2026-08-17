import Foundation
import Testing
@testable import MacAgentCore

/// Per-record deletion in both stores a task writes to.
///
/// Before this, nothing in Sonny deleted one thing: `TaskHistoryStore`'s whole surface was
/// `record(_:)` and `loadAll()`, the journal had `deleteAll()` and no delete-by-id, and the only
/// deletion anywhere was the nine-store wipe.
struct TaskHistoryDeletionTests {
    @Test
    func deletingByIdRemovesExactlyThatRecordAndLeavesTheOthersUntouched() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        let first = taskRecord(command: "first", offset: 0)
        let doomed = taskRecord(command: "doomed", offset: 60)
        let last = taskRecord(command: "last", offset: 120)
        for record in [first, doomed, last] {
            try store.record(record)
        }

        try store.delete(id: try #require(doomed.id))

        // Read the file back rather than count: every surviving field has to be what it was.
        let onDisk = try readTaskRecords(at: url, encryption: encryption)
        #expect(onDisk == [first, last])
        #expect(onDisk.map(\.id) == [first.id, last.id])
        // And the deleted record's own text is gone from the bytes, not merely from the array.
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("doomed".utf8)) == nil)
    }

    /// The reason `CompletedTaskRecord.id` exists, asserted where it pays off. Two runs of one
    /// command started inside the same second come back from disk sharing a timestamp, so the
    /// `(command, startedAt)` key the UI used to fake an identity from cannot tell them apart — a
    /// delete built on it takes the wrong twin, or both.
    @Test
    func deletingOneOfTwoTwinsThatCollideOnTheOldKeyLeavesTheOther() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        // 400ms apart — inside one second, which is all the encoded timestamp resolves.
        let survivor = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002),
            outcomeStatus: .completed
        )
        let doomed = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.4),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002.4),
            outcomeStatus: .failed
        )
        try store.record(survivor)
        try store.record(doomed)

        // The collision is real, not assumed: after the round trip both share a timestamp and the
        // old faked key is identical for the two of them.
        let before = try store.loadAll()
        #expect(before[0].startedAt == before[1].startedAt)
        let oldFakeIDs = before.map { "\($0.startedAt.timeIntervalSince1970)-\($0.command)" }
        #expect(oldFakeIDs[0] == oldFakeIDs[1])

        try store.delete(id: try #require(doomed.id))

        let after = try readTaskRecords(at: url, encryption: encryption)
        #expect(after.count == 1)
        #expect(after.first?.id == survivor.id)
        // The survivor is the one that was meant to survive, not just "one of them".
        #expect(after.first?.outcomeStatus == .completed)
    }

    @Test
    func deletingATaskThatIsAlreadyGoneRaisesNothingAndDoesNotRewriteTheFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        try store.record(taskRecord(command: "kept", offset: 0))
        let before = try Data(contentsOf: url)

        try store.delete(id: "no-such-id")

        // AES-GCM seals with a fresh nonce each time, so identical bytes prove no rewrite happened
        // rather than merely proving the content is unchanged.
        #expect(try Data(contentsOf: url) == before)
        #expect(try store.loadAll().count == 1)
    }

    @Test
    func deletingFromAHistoryThatWasNeverWrittenRaisesNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: testEncryption()
        )

        try store.delete(id: "no-such-id")

        #expect(try store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - The journal half

    @Test
    func deletingOneSessionLeavesTheRestOfTheJournalUntouched() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )
        for id in ["kept-1", "doomed", "kept-2"] {
            try store.save(
                VisionSessionRecord(
                    id: id,
                    goal: "goal \(id)",
                    appDisplayName: "Discord",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        }

        try store.delete(id: "doomed")

        #expect(try store.record(withID: "doomed") == nil)
        #expect(try store.record(withID: "kept-1")?.goal == "goal kept-1")
        #expect(try store.record(withID: "kept-2")?.goal == "goal kept-2")
        #expect(try store.loadAll().count == 2)
        let raw = try Data(contentsOf: store.fileURL)
        #expect(raw.range(of: Data("goal doomed".utf8)) == nil)
    }

    @Test
    func deletingASessionThatIsAlreadyGoneRaisesNothingAndDoesNotRewriteTheFile() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )
        try store.save(
            VisionSessionRecord(
                id: "kept",
                goal: "goal",
                appDisplayName: "Discord",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let before = try Data(contentsOf: store.fileURL)

        try store.delete(id: "no-such-session")

        #expect(try Data(contentsOf: store.fileURL) == before)
        #expect(try store.record(withID: "kept") != nil)
    }

    /// Deleting a session must not touch the task row that pointed at it — the dangling link is a
    /// designed state (row I, SONNY-96), and it is also what makes a deleted screen record
    /// indistinguishable from one that aged out.
    @Test
    func deletingASessionLeavesTheTaskRowAndItsLinkAlone() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let historyURL = root.appendingPathComponent("task-history.json")
        let history = TaskHistoryStore(fileURL: historyURL, encryption: encryption)
        let journal = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        )
        try journal.save(
            VisionSessionRecord(
                id: "session-1",
                goal: "reply in Discord",
                appDisplayName: "Discord",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        let linked = CompletedTaskRecord(
            command: "reply in Discord",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_030),
            outcomeStatus: .completed,
            visionSessionID: "session-1"
        )
        try history.record(linked)

        try journal.delete(id: "session-1")

        let onDisk = try readTaskRecords(at: historyURL, encryption: encryption)
        #expect(onDisk == [linked])
        #expect(onDisk.first?.visionSessionID == "session-1")
        #expect(try journal.record(withID: "session-1") == nil)
    }

    // MARK: - Fixtures

    private func taskRecord(command: String, offset: TimeInterval) -> CompletedTaskRecord {
        let completedAt = Date(timeInterval: offset, since: .deletionFixture)
        return CompletedTaskRecord(
            command: command,
            startedAt: completedAt.addingTimeInterval(-5),
            completedAt: completedAt,
            outcomeStatus: .completed
        )
    }

    private func readTaskRecords(
        at url: URL,
        encryption: LocalStorageEncryption
    ) throws -> [CompletedTaskRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try encryption.decode([CompletedTaskRecord].self, from: Data(contentsOf: url), decoder: decoder).value
    }
}

private extension Date {
    static let deletionFixture = Date(timeIntervalSince1970: 1_700_000_000)
}
