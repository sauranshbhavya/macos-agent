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

    /// **A read failure that is not a decode failure must not heal.**
    ///
    /// The heal above is justified by the contents being unrecoverable; a file that is merely
    /// unreadable *right now* — a busy disk, a permission change, a Keychain that will not answer —
    /// may be perfectly good, and setting it aside would destroy live obligations over a transient.
    ///
    /// **"A Keychain item a restore is about to put back" stood here and is the wrong example**
    /// (PR #194 cycle-4). That phrase is this repository's own vocabulary for the *wrong-key* case —
    /// `LocalDataQuarantine` uses it verbatim, for a user who "had their Keychain item replaced" and
    /// whose key "a restore can reinstall" — and the wrong-key case **heals**, which
    /// `aFileWrittenUnderADifferentKeyHealsRatherThanBlockingEveryFutureDelete` asserts seventy-odd
    /// lines below. What must not heal is a Keychain that cannot be read *at all*, which is a
    /// different failure and the one the third shape below drives.
    ///
    /// **Three shapes, because they take three different roads and each tests something else**
    /// (the first two found by this branch's own battery, the third by PR #194's cycle-3 R1). A file
    /// that is a *directory* fails in `Data(contentsOf:)`, so it never reaches the
    /// `LocalStorageEncryptionError` catch at all and says nothing about what that catch does. A
    /// **short encryption key** does reach it: `key()` throws `.invalidKeyLength`, which is a
    /// `LocalStorageEncryptionError` that is not `.undecodableLocalData`, so the first half of the
    /// guard turns it away.
    ///
    /// **The third is the one this test was named for and did not have.** A key manager that
    /// *throws* — a locked Keychain, a denied prompt, `KeychainSecretStoreError.unexpectedStatus` —
    /// is not a `LocalStorageEncryptionError` at all, so `decode` wraps it into
    /// `.undecodableLocalData` and it walks straight past a guard that only reads the case. The
    /// reviewer measured the consequence: a file written seconds earlier with a good key, holding
    /// one owed deletion, moved aside, `loadAll()` answering zero without throwing, and nothing
    /// reporting it. **The file was fine and the obligation was gone**, over a transient — which is
    /// exactly what this test's own doc had been promising could not happen while covering the two
    /// cases that are not it.
    @Test
    func aReadFailureThatIsNotADecodeFailurePropagates() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Not reachable through the decode path at all.
        let directoryStore = makeStore(at: root)
        try FileManager.default.createDirectory(
            at: directoryStore.fileURL,
            withIntermediateDirectories: true
        )
        #expect(throws: (any Error).self) { _ = try directoryStore.loadAll() }
        #expect(LocalDataQuarantine().quarantinedSiblings(of: directoryStore.fileURL).isEmpty)

        // 2. The one that exercises the guard: a real `SONNYENC1` file this store cannot key.
        let keyed = root.appendingPathComponent("keyed")
        try FileManager.default.createDirectory(at: keyed, withIntermediateDirectories: true)
        let good = PendingServerDeletionStore(
            fileURL: keyed.appendingPathComponent("pending-server-deletions.json")
        )
        try good.enqueue(taskID: "task-a", deletedAt: Self.epoch)

        let badKey = PendingServerDeletionStore(
            fileURL: good.fileURL,
            fileManager: .default,
            encryption: LocalStorageEncryption(keyManager: ShortKeyManager()),
            insideTheCriticalSection: nil
        )
        #expect(throws: LocalStorageEncryptionError.self) { _ = try badKey.loadAll() }
        // The file is left exactly where it was, so the key that can open it still can.
        #expect(LocalDataQuarantine().quarantinedSiblings(of: good.fileURL).isEmpty)
        #expect(try good.loadAll().map(\.taskID) == ["task-a"])

        // 3. No key at all — the case that walked past the guard, over a file that is provably fine.
        let unreachableKey = PendingServerDeletionStore(
            fileURL: good.fileURL,
            fileManager: .default,
            encryption: LocalStorageEncryption(keyManager: ThrowingKeyManager()),
            insideTheCriticalSection: nil
        )
        #expect(throws: (any Error).self) { _ = try unreachableKey.loadAll() }
        #expect(LocalDataQuarantine().quarantinedSiblings(of: good.fileURL).isEmpty)
        // And the obligation is still owed, read back through the key that works.
        #expect(try good.loadAll().map(\.taskID) == ["task-a"])
    }

    /// **A wrong but valid-length key heals, and that is written down as a decision.**
    ///
    /// The counterpart to the arm above, and the pair is the whole of the rule: `hasAUsableKey`
    /// answers "can this store encrypt", not "is this the right key", so a file written under a
    /// *different* 32-byte key reaches the heal. Right for this store on its own argument — the
    /// alternative is every future Delete failing to record an obligation for as long as the key
    /// stays wrong — and what it costs is real, since a quarantined sibling is never read again.
    ///
    /// Asserted here rather than left to `LocalDataQuarantineTests`, which pins the same behaviour
    /// as a side effect of writing under one key and reading under another. Three records used to
    /// say the opposite of this.
    @Test
    func aFileWrittenUnderADifferentKeyHealsRatherThanBlockingEveryFutureDelete() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("pending-server-deletions.json")
        let written = PendingServerDeletionStore(
            fileURL: fileURL,
            fileManager: .default,
            encryption: LocalStorageEncryption(keyManager: FixedKeyManager(byte: 0x42)),
            insideTheCriticalSection: nil
        )
        try written.enqueue(taskID: "task-a", deletedAt: Self.epoch)

        let otherKey = PendingServerDeletionStore(
            fileURL: fileURL,
            fileManager: .default,
            encryption: LocalStorageEncryption(keyManager: FixedKeyManager(byte: 0x99)),
            insideTheCriticalSection: nil
        )

        #expect(try otherKey.loadAll().isEmpty)
        #expect(LocalDataQuarantine().quarantinedSiblings(of: fileURL).count == 1)
        // Service is restored: the next Delete records its obligation instead of failing forever.
        try otherKey.enqueue(taskID: "task-b", deletedAt: Self.epoch)
        #expect(try otherKey.loadAll().map(\.taskID) == ["task-b"])
    }

    /// **A quarantine that fails re-throws the decode error, not its own** (PR #194 cycle-3, R2).
    ///
    /// A bare `try` on `moveAside` sent `moveItem`'s error to `deleteTask`, which renders
    /// `error.localizedDescription` — so the user was told the file could not be moved rather than
    /// that it could not be read. The move failure is the second thing that went wrong.
    @Test
    func aQuarantineThatFailsReportsTheDecodeFailureRatherThanItsOwn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json"),
            fileManager: MoveRefusingFileManager(),
            encryption: .shared,
            insideTheCriticalSection: nil
        )
        try Data("not this store's bytes".utf8).write(to: store.fileURL, options: .atomic)

        #expect(throws: LocalStorageEncryptionError.self) { _ = try store.loadAll() }
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

    /// **Every door holds the file's lock while it is between its load and its write**
    /// (PR #194 review, F2; this shape from the fix round's own battery).
    ///
    /// The store has two writers that do not share an executor — `deleteTask`'s synchronous
    /// `enqueue` on the main actor, and the delivery pass's `remove` off it — so an unguarded
    /// read-modify-write loses whichever update lands inside the other's window, silently and
    /// permanently. The reviewer measured 24 obligations destroyed in 60 deliberately overlapped
    /// runs against 0 in 60 serialised.
    ///
    /// **This does not race for that, and the first version of this test did.** Hammering the file
    /// from several threads and asserting nothing is lost detects the missing lock under a
    /// `--filter` and **misses it inside a full-suite run** — measured, by a battery: the mutant
    /// removing the lock from `enqueue` survived all 2800 tests, and the mutant giving each store
    /// its own lock survived too. A test that only finds a defect when the machine is idle reads as
    /// coverage and is not, and the run it fails to protect is the one this repository gates on.
    ///
    /// **So the assertion is about the lock rather than about outcomes.** `NSLock` is not recursive,
    /// so `try()` answers `false` on a thread that already owns it: from inside the critical section
    /// the *file's* lock must be unavailable, and outside any operation it must be free. No threads,
    /// no timing, and it fails for a door that takes no lock **and** for a door that takes a lock of
    /// its own rather than the file's.
    ///
    /// **What it does not prove**, stated rather than implied: that the locking is *correct* under
    /// real interleaving. It proves each door is inside the one lock that all of them share, which
    /// is what the defect was; it cannot prove the absence of a deadlock or of a window somewhere
    /// this seam does not sit.
    @Test
    func everyDoorHoldsTheFilesLockWhileItIsBetweenLoadAndWrite() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("pending-server-deletions.json")
        let fileLock = PendingServerDeletionStore.lockForTests(forFileAt: fileURL)

        // The control, and it fires: outside any operation the lock is free, so a `false` below is
        // the door holding it rather than `try()` always answering no.
        #expect(fileLock.try())
        fileLock.unlock()

        for door in ["enqueue", "loadAll", "remove"] {
            let heldDuring = LockObservation()
            let store = PendingServerDeletionStore(
                fileURL: fileURL,
                fileManager: .default,
                encryption: .shared,
                insideTheCriticalSection: {
                    // `try()` from the thread that owns a non-recursive lock answers false.
                    if fileLock.try() {
                        fileLock.unlock()
                        heldDuring.record(false)
                    } else {
                        heldDuring.record(true)
                    }
                }
            )

            switch door {
            case "enqueue":
                try store.enqueue(taskID: "task-a", deletedAt: Self.epoch)
            case "loadAll":
                _ = try store.loadAll()
            default:
                try store.remove(taskID: "task-a")
            }

            #expect(heldDuring.observed == true, "\(door) ran its critical section without the file's lock")
        }

        // And free again afterwards, so no door leaks it.
        #expect(fileLock.try())
        fileLock.unlock()
    }

    /// **Two stores over one path share one lock**, which is the difference between closing the
    /// property and closing the reachable half of it (PR #194 review, F2).
    ///
    /// An instance-held lock covers the shipping app, where one store value is constructed in
    /// `atItsRealStoreLocations()` and copied into the service — a copied struct shares the same
    /// `NSLock` reference. It covers nothing about two stores constructed independently over one
    /// file, which is a shape tests take and nothing forbids, and which the doc on the store claims
    /// to handle.
    @Test
    func storesOverOnePathShareOneLockAndStoresOverDifferentPathsDoNot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("pending-server-deletions.json")
        let observed = LockObservation()

        let holder = PendingServerDeletionStore(fileURL: fileURL)
        let other = PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("./pending-server-deletions.json"),
            fileManager: .default,
            encryption: .shared,
            insideTheCriticalSection: {
                // Asked of the lock the *first* store was built with. Same file, so it must be the
                // same object, so it must be unavailable while this second store is inside its own
                // critical section.
                let free = PendingServerDeletionStore.lockForTests(forFileAt: fileURL).try()
                if free { PendingServerDeletionStore.lockForTests(forFileAt: fileURL).unlock() }
                observed.record(!free)
            }
        )
        _ = holder

        try other.enqueue(taskID: "task-a", deletedAt: Self.epoch)

        #expect(observed.observed == true, "two stores over one path did not share a lock")
        // The other direction, so this cannot pass by every store sharing one global lock.
        #expect(
            PendingServerDeletionStore.lockForTests(forFileAt: fileURL)
                !== PendingServerDeletionStore.lockForTests(
                    forFileAt: root.appendingPathComponent("something-else.json")
                )
        )
    }
}

/// What a critical-section seam saw, readable after the operation returns.
private final class LockObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var observed: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ held: Bool) {
        lock.lock()
        value = held
        lock.unlock()
    }
}

/// A key manager whose material is the wrong length, so `LocalStorageEncryption.key()` throws
/// `.invalidKeyLength` — a `LocalStorageEncryptionError` that is not `.undecodableLocalData`.
private struct ShortKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x5A, count: 16)
    }
}

/// A key manager that cannot answer at all — a locked Keychain, a denied prompt. Its error is not a
/// `LocalStorageEncryptionError`, which is exactly what `decode` wraps into `.undecodableLocalData`.
private struct ThrowingKeyManager: LocalStorageKeyManaging {
    struct Unavailable: Error {}

    func keyData() throws -> Data {
        throw Unavailable()
    }
}

/// A valid key of a chosen byte, for the two-different-keys case.
private struct FixedKeyManager: LocalStorageKeyManaging {
    let byte: UInt8

    func keyData() throws -> Data {
        Data(repeating: byte, count: 32)
    }
}

/// Refuses to move anything, so the quarantine inside the heal fails.
private final class MoveRefusingFileManager: FileManager, @unchecked Sendable {
    struct Refused: Error {}

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw Refused()
    }
}
