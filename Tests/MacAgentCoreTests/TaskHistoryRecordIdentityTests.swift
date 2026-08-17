import Foundation
import Testing
@testable import MacAgentCore

/// `CompletedTaskRecord.id` and the load-time backfill that gives one to every record written
/// before the field existed.
///
/// The fixtures here deliberately build pre-id files rather than describing them: a record encodes
/// its `id` with `encodeIfPresent`, so setting it to `nil` before writing produces a file with no
/// `id` key at all — byte-for-byte what a `task-history.json` written before this branch looks
/// like.
struct TaskHistoryRecordIdentityTests {
    @Test
    func aNewlyRecordedTaskCarriesAnIdOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let store = TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: encryption
        )

        try store.record(
            CompletedTaskRecord(
                command: "open Safari",
                startedAt: .fixture,
                completedAt: Date(timeInterval: 4, since: .fixture),
                outcomeStatus: .completed
            )
        )

        let onDisk = try readRecords(at: store.fileURL, encryption: encryption)
        #expect(onDisk.count == 1)
        #expect(onDisk[0].id?.isEmpty == false)
        // Not merely non-nil: two records made the same way must not share an identity.
        let second = CompletedTaskRecord(
            command: "open Safari",
            startedAt: .fixture,
            completedAt: Date(timeInterval: 4, since: .fixture),
            outcomeStatus: .completed
        )
        #expect(second.id != onDisk[0].id)
    }

    @Test
    func anEncryptedFileWrittenBeforeIdsDecodesAndIsBackfilledOnDisk() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        try writeFixture(withoutIDs: [
            record(command: "first", offset: 0),
            record(command: "second", offset: 60),
            record(command: "third", offset: 120)
        ], to: url, encryption: encryption, plaintext: false)

        // The fixture really is pre-id, so what follows is testing the backfill and not the writer.
        #expect(try readRecords(at: url, encryption: encryption).allSatisfy { $0.id == nil })

        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        let loaded = try store.loadAll()

        #expect(loaded.count == 3)
        #expect(loaded.allSatisfy { $0.id?.isEmpty == false })
        #expect(Set(loaded.compactMap(\.id)).count == 3)
        // Every other field survived the rewrite untouched.
        #expect(loaded.map(\.command) == ["first", "second", "third"])
        #expect(loaded.map(\.outcomeStatus) == [.completed, .completed, .completed])

        // Read the file back: the ids are on disk, not just in the returned value.
        let onDisk = try readRecords(at: url, encryption: encryption)
        #expect(onDisk.map(\.id) == loaded.map(\.id))
        #expect(onDisk == loaded)
    }

    @Test
    func aLegacyPlaintextFileWrittenBeforeIdsIsBothEncryptedAndBackfilled() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        try writeFixture(
            withoutIDs: [record(command: "legacy plaintext task", offset: 0)],
            to: url,
            encryption: encryption,
            plaintext: true
        )

        // The fixture's fidelity is what every test in this file rests on, so assert it rather than
        // claim it: this is exactly the key set a record written before row I carried — no `id`,
        // and no `trigger` or `visionSessionID` either, since Optionals encode with
        // `encodeIfPresent` and all three were absent.
        let rawBefore = try Data(contentsOf: url)
        #expect(!rawBefore.starts(with: LocalStorageEncryption.fileHeader))
        let asJSON = try #require(
            JSONSerialization.jsonObject(with: rawBefore) as? [[String: Any]]
        )
        #expect(asJSON.count == 1)
        #expect(Set(asJSON[0].keys) == ["command", "startedAt", "completedAt", "outcomeStatus"])

        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        let loaded = try store.loadAll()

        #expect(loaded.count == 1)
        #expect(loaded[0].id?.isEmpty == false)
        #expect(loaded[0].command == "legacy plaintext task")

        // Both pending upgrades landed: the file is encrypted now, and it carries the id.
        try expectEncryptedFile(url, hiding: "legacy plaintext task")
        #expect(try readRecords(at: url, encryption: encryption) == loaded)
    }

    @Test
    func backfilledIdsAreStableAcrossLoads() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        try writeFixture(
            withoutIDs: [record(command: "first", offset: 0), record(command: "second", offset: 60)],
            to: url,
            encryption: encryption,
            plaintext: false
        )
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)

        let first = try store.loadAll()
        let second = try store.loadAll()
        // A separate store instance over the same file, since a delete arrives on a later launch.
        let third = try TaskHistoryStore(fileURL: url, encryption: encryption).loadAll()

        #expect(first.compactMap(\.id).count == 2)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(third.map(\.id) == first.map(\.id))
    }

    @Test
    func appendingToABackfilledFileKeepsTheBackfilledIds() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        try writeFixture(
            withoutIDs: [record(command: "older", offset: 0)],
            to: url,
            encryption: encryption,
            plaintext: false
        )
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        let backfilledID = try #require(store.loadAll().first?.id)

        try store.record(
            CompletedTaskRecord(
                command: "newer",
                startedAt: Date(timeInterval: 600, since: .fixture),
                completedAt: Date(timeInterval: 610, since: .fixture),
                outcomeStatus: .failed
            )
        )

        let onDisk = try readRecords(at: url, encryption: encryption)
        #expect(onDisk.map(\.command) == ["older", "newer"])
        #expect(onDisk[0].id == backfilledID)
        #expect(onDisk[1].id?.isEmpty == false)
        #expect(onDisk[0].id != onDisk[1].id)
    }

    /// The reason this ticket exists. `TaskHistoryStore` persists dates with plain `.iso8601`, which
    /// truncates to whole seconds, so two runs of one command started inside the same second come
    /// back from disk indistinguishable under the `(command, startedAt)` key the UI used to fake an
    /// id from. The collision is constructed here rather than assumed away.
    @Test
    func twinsThatCollideOnTheOldCompoundKeyStillHaveSeparateIds() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let store = TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: encryption
        )
        // 400ms apart — inside one second, which is all the encoded timestamp can resolve.
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let secondStart = Date(timeIntervalSince1970: 1_700_000_000.4)
        let succeeded = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: firstStart,
            completedAt: firstStart.addingTimeInterval(2),
            outcomeStatus: .completed
        )
        let failed = CompletedTaskRecord(
            command: "archive the inbox",
            startedAt: secondStart,
            completedAt: secondStart.addingTimeInterval(2),
            outcomeStatus: .failed
        )
        #expect(firstStart != secondStart)

        try store.record(succeeded)
        try store.record(failed)
        let loaded = try store.loadAll()

        #expect(loaded.count == 2)
        // The truncation is real: the sub-second drift is gone once the file round-trips, so the
        // old fake id — "\(startedAt.timeIntervalSince1970)-\(command)" — collides.
        #expect(loaded[0].startedAt == loaded[1].startedAt)
        let oldFakeIDs = loaded.map { "\($0.startedAt.timeIntervalSince1970)-\($0.command)" }
        #expect(oldFakeIDs[0] == oldFakeIDs[1])

        // The real ids do not, and each addresses exactly one record.
        #expect(loaded[0].id != loaded[1].id)
        #expect(loaded.filter { $0.id == succeeded.id }.count == 1)
        #expect(loaded.filter { $0.id == succeeded.id }.first?.outcomeStatus == .completed)
        #expect(loaded.filter { $0.id == failed.id }.count == 1)
        #expect(loaded.filter { $0.id == failed.id }.first?.outcomeStatus == .failed)

        // What the collision cost: deleting one twin by id leaves the other, where deleting by the
        // old key would have taken both.
        let survivors = loaded.filter { $0.id != failed.id }
        #expect(survivors.count == 1)
        #expect(survivors.first?.outcomeStatus == .completed)
        #expect(loaded.filter { "\($0.startedAt.timeIntervalSince1970)-\($0.command)" != oldFakeIDs[1] }.isEmpty)
    }

    /// The `migratingLegacyPlaintext` contract, applied to the backfill: a rewrite that cannot land
    /// is not a load failure. Mirrors `failedLegacyMigrationRewriteStillReturnsTheDecodedData`.
    @Test
    func aFailedIdBackfillRewriteStillReturnsTheDecodedRecords() throws {
        let root = try makeDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        try writeFixture(
            withoutIDs: [record(command: "first", offset: 0), record(command: "second", offset: 60)],
            to: url,
            encryption: encryption,
            plaintext: false
        )
        let rawBefore = try Data(contentsOf: url)
        // Read-only directory: the file still reads, but the backfill rewrite cannot land.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let store = TaskHistoryStore(fileURL: url, encryption: encryption)
        let loaded = try store.loadAll()

        // No throw, no data loss, and the caller still gets usable ids for this session.
        #expect(loaded.map(\.command) == ["first", "second"])
        #expect(loaded.allSatisfy { $0.id?.isEmpty == false })
        // The original file is byte-identical, so the backfill retries on the next load.
        #expect(try Data(contentsOf: url) == rawBefore)
        #expect(try readRecords(at: url, encryption: encryption).allSatisfy { $0.id == nil })
    }

    // MARK: - Fixtures

    private func record(command: String, offset: TimeInterval) -> CompletedTaskRecord {
        CompletedTaskRecord(
            command: command,
            startedAt: Date(timeInterval: offset, since: .fixture),
            completedAt: Date(timeInterval: offset + 5, since: .fixture),
            outcomeStatus: .completed
        )
    }

    /// Writes what `task-history.json` looked like before `id` existed. Stripping the ids is what
    /// makes it a real pre-id file: synthesized `Encodable` uses `encodeIfPresent` for Optionals,
    /// so a `nil` id emits no key at all.
    private func writeFixture(
        withoutIDs records: [CompletedTaskRecord],
        to url: URL,
        encryption: LocalStorageEncryption,
        plaintext: Bool
    ) throws {
        let stripped = records.map { record -> CompletedTaskRecord in
            var copy = record
            copy.id = nil
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = plaintext
            ? try encoder.encode(stripped)
            : try encryption.encode(stripped, encoder: encoder)
        try data.write(to: url, options: .atomic)
    }

    private func readRecords(at url: URL, encryption: LocalStorageEncryption) throws -> [CompletedTaskRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try encryption.decode([CompletedTaskRecord].self, from: Data(contentsOf: url), decoder: decoder).value
    }
}

private extension Date {
    static let fixture = Date(timeIntervalSince1970: 1_700_000_000)
}
