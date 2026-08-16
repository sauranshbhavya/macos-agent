import CoreGraphics
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-96: the action journal — the store's own pattern conformance, and what an entry records.
@Suite
struct VisionSessionJournalStoreTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func entry(target: String = "Send") -> VisionActionJournalEntry {
        VisionActionJournalEntry(
            timestamp: Date(timeIntervalSince1970: 1_000),
            appDisplayName: "Discord",
            appBundleIdentifier: "com.hnc.Discord",
            actionType: "click",
            targetDescription: target,
            imageX: 400,
            imageY: 300,
            riskTier: CapabilityRiskTier.tier3,
            consequence: CapabilityRiskEscalation.Consequence.affectsOthers,
            approvalState: VisionActionJournalEntry.ApprovalState.approved,
            observationAfter: "Clicked at screen point (500, 400)."
        )
    }

    private static func record(id: String = "session-1", goal: String = "send a message") -> VisionSessionRecord {
        VisionSessionRecord(
            id: id,
            goal: goal,
            appDisplayName: "Discord",
            startedAt: Date(timeIntervalSince1970: 900),
            entries: [entry()]
        )
    }

    // MARK: - The shared store pattern

    /// **Encrypted on disk, like every other store.** The journal is a record of everything Sonny
    /// clicked and typed inside the user's apps, which makes it one of the more sensitive files this
    /// product writes — plaintext here would be worse than plaintext in most of the others.
    @Test
    func theJournalEncryptsRawFileBytesAndRoundTrips() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "sensitive goal \(UUID().uuidString)"
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )

        try store.save(Self.record(goal: marker))

        try expectEncryptedFile(store.fileURL, hiding: marker)
        #expect(try store.record(withID: "session-1")?.goal == marker)
    }

    /// The legacy-plaintext migration path, shared with every other store: a file written before
    /// encryption decodes once and is rewritten encrypted.
    @Test
    func aPlaintextJournalMigratesOnItsNextLoad() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("vision-sessions.json")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([Self.record()]).write(to: url)

        let store = VisionSessionJournalStore(fileURL: url, encryption: testEncryption())
        #expect(try store.loadAll().count == 1)
        // Migrated in place: the same bytes are now encrypted.
        try expectEncryptedFile(url, hiding: "send a message")
        #expect(try store.record(withID: "session-1")?.entries.count == 1)
    }

    /// A missing file is an empty journal, never an error — a user who has never run a session has
    /// no file, and that is not a failure.
    @Test
    func aMissingFileLoadsAsAnEmptyJournal() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )
        #expect(try store.loadAll().isEmpty)
        #expect(try store.record(withID: "nope") == nil)
    }

    /// Saving the same id twice replaces rather than duplicating — the loop saves a session's record
    /// once at the end today, and a future incremental writer must not accumulate copies.
    @Test
    func savingTheSameSessionTwiceReplacesIt() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )

        try store.save(Self.record())
        var updated = Self.record()
        updated.entries.append(Self.entry(target: "Delete"))
        try store.save(updated)

        #expect(try store.loadAll().count == 1)
        #expect(try store.record(withID: "session-1")?.entries.count == 2)
    }

    /// Retention parity: oldest-first eviction at the cap, the same rule task history uses.
    @Test
    func theOldestSessionsAreEvictedAtTheCap() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )

        for index in 0..<(VisionSessionJournalStore.maxSessions + 5) {
            try store.save(
                VisionSessionRecord(
                    id: "session-\(index)",
                    goal: "g",
                    appDisplayName: "Discord",
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index))
                )
            )
        }

        let all = try store.loadAll()
        #expect(all.count == VisionSessionJournalStore.maxSessions)
        // The oldest five are gone; the newest survive.
        #expect(try store.record(withID: "session-0") == nil)
        #expect(try store.record(withID: "session-4") == nil)
        #expect(try store.record(withID: "session-5") != nil)
        #expect(try store.record(withID: "session-\(VisionSessionJournalStore.maxSessions + 4)") != nil)
    }

    @Test
    func deletingTheJournalRemovesTheFileAndIsSafeWhenThereIsNothingToDelete() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )

        try store.deleteAll()
        try store.save(Self.record())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.deleteAll()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.loadAll().isEmpty)
    }

    // MARK: - What an entry records (§13.6)

    /// Every field §13.6 names, round-tripped — a record that lost its tier or its approval state on
    /// the way to disk would be a record that cannot answer the question it exists for.
    @Test
    func everyFieldSpecThirteenSixNamesSurvivesARoundTrip() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: testEncryption()
        )

        try store.save(Self.record())
        let loaded = try #require(try store.record(withID: "session-1")?.entries.first)

        #expect(loaded.timestamp == Date(timeIntervalSince1970: 1_000))
        #expect(loaded.appDisplayName == "Discord")
        #expect(loaded.appBundleIdentifier == "com.hnc.Discord")
        #expect(loaded.actionType == "click")
        #expect(loaded.targetDescription == "Send")
        #expect(loaded.imageX == 400)
        #expect(loaded.imageY == 300)
        #expect(loaded.riskTier == .tier3)
        #expect(loaded.consequence == .affectsOthers)
        #expect(loaded.approvalState == .approved)
        #expect(loaded.observationAfter.contains("500, 400"))
    }

    /// The three approval states are distinct and all reachable — "it ran without asking", "you
    /// allowed it" and "an earlier approval covered it" are three different things a user needs told
    /// apart, and collapsing them would make the record less honest than the run.
    @Test
    func theThreeApprovalStatesAreDistinct() {
        #expect(VisionActionJournalEntry.ApprovalState.allCases.count == 3)
        #expect(Set(VisionActionJournalEntry.ApprovalState.allCases.map(\.rawValue)).count == 3)
    }

    /// The link a task-history row carries is Optional, so every record written before row I still
    /// decodes — the twice-documented `AutomationStores.swift` rule.
    @Test
    func aTaskRecordWrittenBeforeRowIStillDecodes() throws {
        let legacy = """
        {"command":"open Safari","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:00:01Z","outcomeStatus":"completed"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(CompletedTaskRecord.self, from: Data(legacy.utf8))

        #expect(record.visionSessionID == nil)
        #expect(record.command == "open Safari")
    }
}
