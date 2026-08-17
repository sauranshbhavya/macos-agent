import Foundation
import Testing
@testable import MacAgentCore

/// What the two caps actually do, pinned.
///
/// `TaskHistoryStore.maxItems` had no test at all before this suite — verified at `36cef9e` by
/// `grep -rn "maxItems\|10_000\|10000" Tests/MacAgentCoreTests/*.swift Tests/MacAgentTests/*.swift`,
/// whose only `maxItems` hits were `ClipboardHistoryStore`'s and `RecentArtifactStore`'s. An
/// eviction nothing asserts is an eviction that can quietly change, and row D's search is about to
/// make a promise this cap bounds.
struct TaskHistoryRetentionTests {
    /// Seeded straight into the file rather than through `record(_:)` ten thousand times, because
    /// `record(_:)` decodes and re-encrypts the whole file per call — 10,000 of those is quadratic
    /// and would put minutes into the suite to exercise one `Array.suffix`. Eviction lives in
    /// `record(_:)`, so the test still goes through it, once, against a file already past the cap.
    ///
    /// The seed is written **newest-first**, deliberately. Eviction has to be by `completedAt` and
    /// not by position in the file: on a descending file, a `suffix(maxItems)` that skipped the sort
    /// would keep exactly the wrong end.
    @Test
    func writingPastTheCapEvictsTheOldestByCompletedAtWhateverOrderTheFileIsIn() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        let overflow = 5
        let seeded = (0..<(TaskHistoryStore.maxItems + overflow)).map { seededRecord(index: $0) }
        try seed(seeded.reversed(), to: url, encryption: encryption)
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)

        let newest = seededRecord(index: TaskHistoryStore.maxItems + overflow)
        try store.record(newest)

        let all = try store.loadAll()
        let survivingIDs = Set(all.compactMap(\.id))
        #expect(all.count == TaskHistoryStore.maxItems)

        // Six went over the cap, so the six oldest by completedAt are the six that left — asserted
        // by identity, since a count alone cannot tell which end was cut.
        for evictedIndex in 0...overflow {
            #expect(!survivingIDs.contains(seeded[evictedIndex].id ?? ""))
        }
        // The far side of the boundary: the first record the cut did not reach.
        #expect(survivingIDs.contains(seeded[overflow + 1].id ?? ""))
        // The oldest survivor and the newest, by name.
        #expect(all.first?.command == "task \(overflow + 1)")
        #expect(all.last?.command == newest.command)
        #expect(survivingIDs.contains(newest.id ?? ""))

        // Eviction re-sorts, so a file that went over the cap comes back ascending by completedAt
        // whatever order it was written in. Recorded because it is real behaviour a later reader
        // could otherwise mistake for insertion order.
        #expect(all.map(\.completedAt) == all.map(\.completedAt).sorted())
    }

    /// The boundary is `>` and not `>=`: a file sitting exactly at the cap loses nothing. Cheap, and
    /// it catches the off-by-one that would silently drop the user's oldest task one run early.
    @Test
    func aFileExactlyAtTheCapLosesNothing() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let url = root.appendingPathComponent("task-history.json")
        let seeded = (0..<(TaskHistoryStore.maxItems - 1)).map { seededRecord(index: $0) }
        try seed(seeded, to: url, encryption: encryption)
        let store = TaskHistoryStore(fileURL: url, encryption: encryption)

        try store.record(seededRecord(index: TaskHistoryStore.maxItems - 1))

        let all = try store.loadAll()
        #expect(all.count == TaskHistoryStore.maxItems)
        // The very oldest is still here, which is the whole point of the assertion.
        #expect(all.contains { $0.id == seeded[0].id })
        #expect(all.first?.command == "task 0")
    }

    // MARK: - The deliberate differential lifetime

    /// A task row whose screen record aged out and one whose screen record was deleted must be
    /// indistinguishable. The product cannot honestly tell those apart without explaining itself,
    /// and two states that look different for a reason the user is never told is worse than one.
    ///
    /// **What "renders identically" means here, stated exactly rather than approximately.** The task
    /// detail sheet's whole vision section is driven by three inputs and nothing else, enumerated
    /// from `CommandCenterView.swift`'s `visionSessionSection` at `36cef9e`: whether
    /// `record.visionSessionID` is non-nil (which decides both that the section appears and the
    /// sheet's height), the value of `journalStore.record(withID:)`, and the load-failure string set
    /// when that call throws. This test asserts all three are equal across the two routes, so the
    /// view has nothing left to differ on. What it does not do is execute the SwiftUI body — no
    /// agent can drive this app's UI, and the founder owns visual verification.
    @Test
    func aDeletedScreenRecordAndAnEvictedOneLeaveTheSameThingBehind() throws {
        let deleted = try visionSectionInputs(losingTheSessionBy: .deletion)
        let evicted = try visionSectionInputs(losingTheSessionBy: .eviction)

        #expect(deleted == evicted)
        // Spelled out, so a failure says which half moved rather than just "not equal".
        #expect(deleted.session == nil)
        #expect(evicted.session == nil)
        #expect(deleted.loadFailure == nil)
        #expect(evicted.loadFailure == nil)
        // The link stays on the record in both cases. A dangling visionSessionID is a designed
        // state (row I, SONNY-96) — clearing it would have made a delete a write to two stores, and
        // it is also what keeps these two routes from being told apart.
        #expect(deleted.hasVisionSessionID)
        #expect(evicted.hasVisionSessionID)
        #expect(deleted.record == evicted.record)
    }

    /// The three inputs `visionSessionSection` reads, and nothing else.
    private struct VisionSectionInputs: Equatable {
        var record: CompletedTaskRecord
        var session: VisionSessionRecord?
        var loadFailure: String?

        var hasVisionSessionID: Bool { record.visionSessionID != nil }
    }

    private enum SessionLoss {
        /// The only delete the journal has today. The per-session one arrives on SONNY-116, and
        /// when it does this test should gain a third route rather than swap this one out.
        case deletion
        /// Age-out: 500 later sessions push this one off the end.
        case eviction
    }

    private func visionSectionInputs(losingTheSessionBy loss: SessionLoss) throws -> VisionSectionInputs {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let encryption = testEncryption()
        let journal = VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        )
        let sessionID = "the-session"
        try journal.save(
            VisionSessionRecord(
                id: sessionID,
                goal: "reply in Discord",
                appDisplayName: "Discord",
                startedAt: .retentionFixture
            )
        )
        // One task row pointing at it, identical on both routes — the row is never rewritten by
        // either, which is half of why they cannot be told apart.
        let task = CompletedTaskRecord(
            id: "task-id",
            command: "reply in Discord",
            startedAt: .retentionFixture,
            completedAt: Date(timeInterval: 30, since: .retentionFixture),
            outcomeStatus: .completed,
            visionSessionID: sessionID
        )

        switch loss {
        case .deletion:
            try journal.deleteAll()
        case .eviction:
            // Seeded straight into the file, then one `save(_:)` to trigger eviction. Five hundred
            // `save(_:)` calls would be five hundred decrypt-modify-re-encrypt cycles, and a second
            // of stolen CPU makes the timing-sensitive vision-session suites flaky when the whole
            // suite runs in parallel. Eviction lives in `save(_:)`, so this still goes through it.
            //
            // Every seeded session starts after the one under test, so that one is the oldest and
            // the first to go.
            let later = (0..<(VisionSessionJournalStore.maxSessions - 1)).map { index in
                VisionSessionRecord(
                    id: "later-\(index)",
                    goal: "g",
                    appDisplayName: "Discord",
                    startedAt: Date(timeInterval: TimeInterval(index + 1), since: .retentionFixture)
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let existing = try journal.loadAll()
            try encryption.encode(existing + later, encoder: encoder)
                .write(to: journal.fileURL, options: .atomic)
            try journal.save(
                VisionSessionRecord(
                    id: "newest",
                    goal: "g",
                    appDisplayName: "Discord",
                    startedAt: Date(
                        timeInterval: TimeInterval(VisionSessionJournalStore.maxSessions),
                        since: .retentionFixture
                    )
                )
            )
        }

        var loadFailure: String?
        var session: VisionSessionRecord?
        do {
            session = try journal.record(withID: sessionID)
        } catch {
            loadFailure = "This session's record could not be decrypted or decoded: \(error.localizedDescription)"
        }
        return VisionSectionInputs(record: task, session: session, loadFailure: loadFailure)
    }

    // MARK: - Fixtures

    private func seededRecord(index: Int) -> CompletedTaskRecord {
        let completedAt = Date(timeInterval: TimeInterval(index), since: .retentionFixture)
        return CompletedTaskRecord(
            command: "task \(index)",
            startedAt: completedAt.addingTimeInterval(-1),
            completedAt: completedAt,
            outcomeStatus: .completed
        )
    }

    private func seed(
        _ records: some Sequence<CompletedTaskRecord>,
        to url: URL,
        encryption: LocalStorageEncryption
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encryption.encode(Array(records), encoder: encoder).write(to: url, options: .atomic)
    }
}

private extension Date {
    static let retentionFixture = Date(timeIntervalSince1970: 1_700_000_000)
}
