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

    /// **An undecodable file is set aside and the queue starts again** (PR #194 review, F1).
    ///
    /// The store's own doc carries the reasoning; what this pins is the pair of consequences.
    /// Propagating the failure instead would make `enqueue` — which loads before it writes — fail
    /// for *every* future Delete, with no Memory row and no load-failure banner to clear it from,
    /// so one corrupt file would orphan every server copy from then on. Setting it aside keeps the
    /// bytes under a quarantined sibling, which Settings' Data page counts and can remove, and is
    /// the only surface this failure has — **the readability probe is not one**, because
    /// `unreadableStores` is consumed through `MemoryCategory.stores` and this store is in no
    /// category (PR #194 review, F6).
    @Test
    func anUndecodableFileIsSetAsideAndTheQueueStartsFresh() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)
        try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)

        try Data("not this store's bytes".utf8).write(to: store.fileURL, options: .atomic)

        // The read heals rather than throwing, and reports the empty queue that is now the truth.
        #expect(try store.loadAll().isEmpty)
        // The bytes are kept beside it rather than destroyed.
        let setAside = LocalDataQuarantine().quarantinedSiblings(of: store.fileURL)
        #expect(setAside.count == 1)
        #expect(try Data(contentsOf: try #require(setAside.first)) == Data("not this store's bytes".utf8))
        // And the queue works again immediately — which is the point, since the alternative was
        // every future Delete failing to record its obligation.
        try store.enqueue(taskID: "task-b", deletedAt: Self.epoch)
        #expect(try store.loadAll().map(\.taskID) == ["task-b"])
    }

    /// **A `bytea`-shaped read failure is not a decode failure and must not heal.**
    ///
    /// The heal above is justified by the contents being unrecoverable; a file that is merely
    /// unreadable *right now* — a busy disk, a permission change — may be perfectly good, and
    /// setting it aside would destroy live obligations over a transient. Driven through a store
    /// whose file is a directory, which is the cheapest read failure that is not a decode failure.
    @Test
    func aReadFailureThatIsNotADecodeFailurePropagates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) { _ = try store.loadAll() }
        #expect(LocalDataQuarantine().quarantinedSiblings(of: store.fileURL).isEmpty)
    }

    /// **The cap's tie-break has to agree with the delivery order's** (PR #194 review, F4).
    ///
    /// `loadAll` orders oldest-first with ties on ascending id; `capped` sorts newest-first, so its
    /// tie-break has to run the *other* way or the entries it keeps inside a tie group are the ones
    /// that come first in delivery order. With whole-second `.iso8601` dates a tie group is what a
    /// burst of deletes produces, so this is the reachable shape rather than a curiosity — and the
    /// cap test above cannot see it, because its timestamps are a minute apart.
    ///
    /// Three entries at a cap of two, two of them sharing an instant: the oldest by the documented
    /// order is `t0/a`, so that is the one that must go.
    @Test
    func theCapDropsTheOldestEvenWhenTwoEntriesShareASecond() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(at: root)

        for index in 0..<(PendingServerDeletionStore.maxItems - 1) {
            try store.enqueue(
                taskID: "filler-\(String(format: "%04d", index))",
                deletedAt: Self.epoch.addingTimeInterval(60)
            )
        }
        // Two at one instant, older than every filler above, and one newer than all of them.
        try store.enqueue(taskID: "tie-a", deletedAt: Self.epoch)
        try store.enqueue(taskID: "tie-b", deletedAt: Self.epoch)

        let queued = try store.loadAll()
        #expect(queued.count == PendingServerDeletionStore.maxItems)
        // `tie-a` is first in delivery order, so it is the oldest, so it is the one the cap takes.
        #expect(!queued.map(\.taskID).contains("tie-a"))
        #expect(queued.map(\.taskID).contains("tie-b"))
    }

    /// **The load-modify-write cycles are serialised, per file** (PR #194 review, F2).
    ///
    /// The store has two writers that do not share an executor — `deleteTask`'s synchronous
    /// `enqueue` on the main actor, and the delivery pass's `remove` off it — so an unguarded
    /// read-modify-write loses whichever update lands inside the other's window, silently and
    /// permanently. The reviewer measured 24 obligations destroyed in 60 deliberately overlapped
    /// runs against 0 in 60 serialised.
    ///
    /// **Two independently constructed stores over one path**, which is what makes this a test of
    /// the *file's* guarantee rather than of one instance's: an instance-held lock passes every
    /// other assertion here and fails this one.
    ///
    /// **Not a wall-clock bet.** Nothing here sleeps or races a threshold; the assertion is that no
    /// update is lost, which is deterministic with the lock and overwhelmingly not without it — a
    /// hundred unguarded concurrent read-modify-write cycles over one file do not all survive.
    @Test
    func concurrentWritesThroughTwoStoresOverOneFileLoseNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = makeStore(at: root)
        let other = makeStore(at: root)
        let count = 100

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let store = index.isMultiple(of: 2) ? writer : other
            try? store.enqueue(
                taskID: "task-\(String(format: "%03d", index))",
                deletedAt: Self.epoch.addingTimeInterval(Double(index))
            )
        }

        #expect(try makeStore(at: root).loadAll().count == count)
    }

    /// The same property in the direction that actually destroys an obligation: a press interleaved
    /// with the delivery pass's `remove`.
    @Test
    func anEnqueueInterleavedWithARemoveSurvivesIt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pressing = makeStore(at: root)
        let delivering = makeStore(at: root)
        let rounds = 50

        for round in 0..<rounds {
            let delivered = "delivered-\(round)"
            let pressed = "pressed-\(round)"
            try pressing.enqueue(taskID: delivered, deletedAt: Self.epoch)

            DispatchQueue.concurrentPerform(iterations: 2) { which in
                if which == 0 {
                    try? delivering.remove(taskID: delivered)
                } else {
                    try? pressing.enqueue(taskID: pressed, deletedAt: Self.epoch.addingTimeInterval(1))
                }
            }

            let queued = try pressing.loadAll().map(\.taskID)
            #expect(queued == [pressed], "round \(round) lost or resurrected an entry: \(queued)")
            try pressing.remove(taskID: pressed)
        }
    }
}
