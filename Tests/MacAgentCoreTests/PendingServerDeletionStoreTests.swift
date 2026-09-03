import Foundation
import Testing
@testable import MacAgentCore

/// The queue of task deletions this Mac owes the gateway (SONNY-333).
///
/// The behaviours here are the ones the rest of the feature rests on: that an id survives a
/// relaunch, that pressing Delete twice does not queue twice, that the order the deliveries go out
/// in is total, and that the file cannot grow without bound.
@Suite
struct PendingServerDeletionStoreTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonny-pending-deletions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeStore(at root: URL) -> PendingServerDeletionStore {
        PendingServerDeletionStore(fileURL: root.appendingPathComponent("pending-server-deletions.json"))
    }

    private static let epoch = Date(timeIntervalSince1970: 1_772_000_000)

    @Test
    func anEnqueuedDeletionSurvivesAFreshStoreOverTheSameFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeStore(at: root).enqueue(taskID: "task-a", deletedAt: Self.epoch)

        // A second store over the same URL is the relaunch: nothing is carried in memory, so this
        // reads what was actually written. That is the whole reason this is a file at all.
        let reread = try makeStore(at: root).loadAll()
        #expect(reread.map(\.taskID) == ["task-a"])
        #expect(reread.first?.deletedAt == Self.epoch)
    }

    @Test
    func aMissingFileIsAnEmptyQueueRatherThanAFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try makeStore(at: root).loadAll().isEmpty)
    }

    /// **Encrypted, like every other store on the shared pattern.** The contents are opaque ids, so
    /// this is not the most sensitive file in the directory — but a store that quietly wrote
    /// plaintext would be the variant `CLAUDE.md` forbids, and the header is the one byte-level
    /// property that says which door it went through.
    @Test
    func theFileOnDiskIsEncrypted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)

        let bytes = try Data(contentsOf: store.fileURL)
        #expect(bytes.starts(with: LocalStorageEncryption.fileHeader))
        // And the id is not sitting in the file in the clear, which is the claim the header implies
        // and does not by itself establish.
        #expect(!(String(data: bytes, encoding: .utf8) ?? "").contains("task-a"))
    }

    /// Pressing Delete on a row whose local delete failed, then pressing it again.
    ///
    /// **The first press's timestamp is the one that is kept**, and that is not cosmetic:
    /// `deletedAt` orders the queue and decides what the cap drops, so re-stamping would move a
    /// delivery that has been owed for a week to the back of the queue and to the front of the
    /// survivors.
    @Test
    func enqueuingTheSameTaskTwiceKeepsOneEntryAtTheFirstPressesTime() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)
        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch.addingTimeInterval(3600))

        let queued = try store.loadAll()
        #expect(queued.count == 1)
        #expect(queued.first?.deletedAt == Self.epoch)
    }

    /// Oldest first, and total.
    ///
    /// The tie-break is the reason this is asserted rather than assumed: these files persist dates
    /// with whole-second `.iso8601`, so two deletions inside one second land on the same
    /// `deletedAt`, and a dictionary's values arrive in no defined order. Without the id tie-break
    /// two loads of identical data could disagree, and a delivery pass that stopped early would take
    /// a different pair each time.
    @Test
    func theQueueIsDeliveredOldestFirstWithATotalOrder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try store.enqueue(taskID: "later", deletedAt: Self.epoch.addingTimeInterval(60))
        try store.enqueue(taskID: "b-same-second", deletedAt: Self.epoch)
        try store.enqueue(taskID: "a-same-second", deletedAt: Self.epoch)

        #expect(try store.loadAll().map(\.taskID) == ["a-same-second", "b-same-second", "later"])
        // Twice, over a fresh store, because the hazard is an order that is stable within one load
        // and not between two.
        #expect(try makeStore(at: root).loadAll().map(\.taskID) == ["a-same-second", "b-same-second", "later"])
    }

    /// The bound. See `PendingServerDeletionStore.maxItems` for why it is the oldest that go.
    @Test
    func theQueueStopsAtItsCapAndTheOldestEntriesAreTheOnesDropped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        // One past the cap, oldest first, so the entry that must go is the first one written.
        for index in 0...PendingServerDeletionStore.maxItems {
            try store.enqueue(
                taskID: "task-\(index)",
                deletedAt: Self.epoch.addingTimeInterval(Double(index) * 60)
            )
        }

        let queued = try store.loadAll()
        #expect(queued.count == PendingServerDeletionStore.maxItems)
        #expect(!queued.map(\.taskID).contains("task-0"))
        #expect(queued.first?.taskID == "task-1")
        #expect(queued.last?.taskID == "task-\(PendingServerDeletionStore.maxItems)")
    }

    @Test
    func removingADeliveredEntryLeavesTheRestAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)
        try store.enqueue(taskID: "task-b", deletedAt: Self.epoch.addingTimeInterval(60))

        try store.remove(taskID: "task-a")

        #expect(try makeStore(at: root).loadAll().map(\.taskID) == ["task-b"])
    }

    /// A no-op rather than a throw, matching every other per-entry delete here — and it matters for
    /// this store specifically, because the delivery pass removes an entry after the server has
    /// answered and two passes racing would otherwise turn a duplicate removal into a failure.
    @Test
    func removingSomethingThatIsNotQueuedChangesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)
        try store.remove(taskID: "task-never-queued")

        #expect(try store.loadAll().map(\.taskID) == ["task-a"])
    }

    /// An unreadable file is a load failure and not silently an empty queue.
    ///
    /// The delivery pass answers "nothing owed" for it deliberately — there is nothing it could
    /// deliver and no channel to report on — but that is the *caller's* decision, and this pins that
    /// the store itself still tells the truth. `AgentViewModel.refreshStoreReadability()` reads this
    /// same door, so a store that swallowed the failure would report a damaged file as readable and
    /// the whole wipe would then unlink it instead of setting it aside.
    @Test
    func anUnreadableFileThrowsRatherThanReadingAsEmpty() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        try Data("not this store's bytes".utf8).write(to: store.fileURL, options: .atomic)

        #expect(throws: (any Error).self) { _ = try store.loadAll() }
    }
}
