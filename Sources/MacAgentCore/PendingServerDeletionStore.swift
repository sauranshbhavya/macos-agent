import Foundation

/// One task the user deleted on this Mac whose server-side copy has not been confirmed gone
/// (SONNY-333).
///
/// **An obligation, not a memory.** Every other local store holds something Sonny remembers about
/// the user; this holds something Sonny still owes them. The distinction decides three things about
/// it — that it has no Memory row, that the memory master switch cannot suppress it, and that its
/// only content is a key with nothing readable in it.
///
/// **The key is `CompletedTaskRecord.id`, which is the backend's `task_id`** (contract §5.1). That
/// join is the whole reason this record can exist at all: the local row is gone by the time anything
/// reads this, so the id is the only thing left that names the content on the server.
public struct PendingServerDeletion: Codable, Equatable, Sendable, Identifiable {
    /// The task's id — `CompletedTaskRecord.id`, and the `{task_id}` of
    /// `DELETE /v1/tasks/{task_id}`.
    public var taskID: String

    /// When the user pressed Delete.
    ///
    /// Read for two things and neither is display: the total order the queue is delivered in, and
    /// which entry the cap drops when the queue is full. **Nothing renders it**, which is why it is
    /// the only field here besides the key — a queue entry that carried the command text, or the
    /// time a task ran, would be a record of the deleted task surviving the deletion.
    public var deletedAt: Date

    public var id: String { taskID }

    public init(taskID: String, deletedAt: Date) {
        self.taskID = taskID
        self.deletedAt = deletedAt
    }
}

/// The fourteenth local store: task deletions this Mac owes the server (SONNY-333).
///
/// **Why it exists at all.** The founder decision of 2026-08-16 (SONNY-14) is that delete means
/// deleted everywhere — the local record and the backend's retained copy. The founders' decision of
/// 2026-08-30 on SONNY-333 says how: delete locally at once so the button is never blocked on the
/// network, queue the server-side delete, and retry it. A queue is required rather than convenient,
/// because the local row is what carried the id and it is gone the moment the button is pressed.
///
/// **A store of its own rather than a collection inside an existing file**, which the founders'
/// comment asked to be considered. Two candidates were weighed and both rejected:
///
/// - `resumable-tasks.json` already holds two collections and has the machinery for a third
///   (`ResumableTaskFileCollection`), so it is the cheap answer. It is the wrong one: that file is
///   owned by the resume machinery and is injected into `AgentActionExecutor`, so putting an outbox
///   in it would make a running task's executor hold the deletion queue. Collections that share a
///   file should share an owner.
/// - `task-history.json` reads best of all — the tombstones of rows that file held — and fails on
///   the Memory page: `LocalStore.rowDeletionScope` would have to become
///   `.collectionWithinASharedFile` for the Task history row, and a row Delete that *kept* the
///   tombstones while deleting the rows is right, while one that took them would cancel deletions
///   the user had already asked for. That is a live hazard on the row a user presses most.
///
/// **What the whole wipe does to it, stated rather than left to be found.**
/// `LocalDataDeletionService.deleteAllLocalData()` reaches this file like every other, so a user who
/// presses "Delete Sonny local data" with deliveries still owed abandons them. That is deliberate:
/// a file under `~/Library/Application Support/Sonny/` that the wipe does not reach would be a new
/// class of thing, and the wipe's own copy says it is "a promise about the whole directory rather
/// than about the parts a reader thinks of first". It is also consistent rather than a hole — after
/// that wipe no task's server copy is deleted, including the hundreds the user never deleted
/// individually, because "Delete Sonny local data" has never been a promise about the server. The
/// bigger question it raises — whether that wipe, the Memory Task-history row's Delete and
/// "Delete what Sonny did on screen" should reach the server too — is SONNY-404's, filed rather
/// than answered here.
///
/// On the shared `LocalStorageEncryption` pattern exactly: AES-GCM under the `SONNYENC1` header and
/// the transparent legacy-plaintext migration every other store performs on its first load. There
/// are no legacy plaintext files for this store and there never will be — it is younger than the
/// encryption — but the pattern is followed rather than trimmed, for the reason `CLAUDE.md` gives:
/// a store that invents a variant is a store the next reader has to read twice.
public struct PendingServerDeletionStore: @unchecked Sendable {
    /// How many deliveries this file will hold.
    ///
    /// **A cap is the answer to the founders' named failure mode** — "a queue that grows forever and
    /// never tells anyone" — and it is the only bound available: the client cannot know when the
    /// server's own content clock will take a task, because `CONTENT_RETENTION_DAYS` is server
    /// configuration (30 by default, up to 365) and is served to nobody. An age bound guessed on
    /// this side would drop entries while their content was still held.
    ///
    /// **200 rather than a smaller number, because reaching it takes real effort**: the queue only
    /// grows while the app cannot reach the gateway at all, so 200 is 200 deletions performed
    /// entirely offline or signed out, with no session in between. It is also small enough that the
    /// file stays a few tens of kilobytes.
    ///
    /// **The oldest go first when it is full, and the reason first written here was half false**
    /// (PR #194 review, F5). It argued that the oldest entry's content is likeliest to have expired
    /// on the server's own 30-day clock, so the least is lost by dropping it. That is true of the
    /// *live* content and false of the half this endpoint exists to reach: `expireSnapshots` selects
    /// `WHERE expires_at IS NOT NULL`, and `snapshot.ts` records that `expiresAt` is `undefined` on
    /// every snapshot the builder makes because no founder has set a lifecycle — so
    /// training-snapshot members never age out, and **an entry the cap drops leaves a snapshot copy
    /// indefinitely**. This file's own account of what the whole wipe costs says exactly that, two
    /// screens away, and the two paragraphs had never met.
    ///
    /// **Restated honestly, the choice still stands and is now a choice between two losses.** Every
    /// entry the cap drops is an obligation abandoned, whichever end it is taken from; nothing about
    /// age makes one safe. What age does decide is which is *likelier* to be already partly
    /// satisfied — the oldest has had the most chances to expire on the live-content clock, so
    /// dropping it loses the snapshot half alone where dropping the newest loses both halves of a
    /// deletion somebody pressed for seconds ago. That is a weaker argument than the one it
    /// replaces and it is the true one.
    ///
    /// **The eviction is silent, and that is recorded rather than fixed here.** Nothing counts it,
    /// notices it or reports it. It belongs on the same SONNY-109 list as the founders' "never
    /// tells anyone" half, and it is on it.
    public static let maxItems = 200

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption
    /// Serialises this file's load-modify-write cycles. See `lock(forFileAt:)`.
    private let lock: NSLock

    /// Runs inside the critical section — after the load, and before the write where there is one.
    ///
    /// (There is no write in `loadAll`, so "between a load and its write" was not true of all three
    /// doors; PR #194 cycle-3's residuals. Harmless for the assertion, which only asks whether the
    /// lock is held, and corrected because a comment that is true of two of three call sites is how
    /// a reader concludes the third is different on purpose.)
    ///
    /// **A test-only seam, and it exists because the property it proves cannot be raced for**
    /// (PR #194's fix round). Mutual exclusion is an interleaving property, and the obvious test —
    /// hammer the file from several threads and assert nothing is lost — turned out to *pass* with
    /// the lock removed whenever the machine was busy: it detects the mutant under a `--filter` and
    /// misses it inside a full-suite run, which is the worst possible shape, since the run that
    /// misses it is the one this repository gates on. Measured that way, by a battery: the mutant
    /// dropping this lock from `enqueue` survived 2800 tests.
    ///
    /// So the assertion is not about outcomes at all. From inside this closure a test asks the
    /// *file's* lock whether it is held — `NSLock` is not recursive, so `try()` answers `false` on
    /// the thread that already owns it — which is deterministic, needs no threads, and fails for a
    /// door that takes no lock or takes a lock of its own.
    ///
    /// `internal`, so it is invisible to the app target, and defaulted to `nil`, so no shipping path
    /// can set it.
    let insideTheCriticalSection: (@Sendable () -> Void)?

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.init(
            fileURL: fileURL,
            fileManager: fileManager,
            encryption: encryption,
            insideTheCriticalSection: nil
        )
    }

    init(
        fileURL: URL,
        fileManager: FileManager,
        encryption: LocalStorageEncryption,
        insideTheCriticalSection: (@Sendable () -> Void)?
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
        self.insideTheCriticalSection = insideTheCriticalSection
        self.lock = Self.lock(forFileAt: fileURL)
    }

    /// The lock this file's load-modify-write cycles are serialised by, for the tests that prove
    /// each door takes it. Internal for the reason `insideTheCriticalSection` is.
    static func lockForTests(forFileAt fileURL: URL) -> NSLock {
        lock(forFileAt: fileURL)
    }

    /// **One lock per file, process-wide** (PR #194 review, F2).
    ///
    /// Every public method here is a read-modify-write — `loadKeyed()`, mutate, `write()` — and this
    /// store has two writers that do not share an executor. `AgentViewModel.deleteTask` calls
    /// `enqueue` **synchronously on the main actor**; `SonnyTaskDeletionService.deliverPendingDeletions()`
    /// is a nonisolated `async` method, so a `Task { @MainActor in await service… }` releases the
    /// main actor for the whole pass, `remove` included. A press landing inside a pass's `remove`
    /// window therefore loses its own entry outright — the obligation is destroyed, silently and
    /// permanently, which is the same outcome as never queueing it.
    ///
    /// **This was measured rather than reasoned about.** The reviewer drove the real store with the
    /// two operations deliberately overlapped: **60 runs, 24 obligations destroyed, 36 deliveries
    /// resurrected, 0 clean**, against **60 of 60 clean** with the same two operations serialised.
    /// The window is `remove()`'s own duration — 0.47 ms over a one-entry queue and 2.07 ms at the
    /// cap — and it opens the instant a DELETE's response lands, which is exactly when somebody
    /// working down a list of tasks is pressing again.
    ///
    /// **Keyed on the path rather than held per instance, which is the difference between closing
    /// the property and closing the reachable half of it.** An instance lock would cover the
    /// shipping app, where one store value is constructed in `atItsRealStoreLocations()` and copied
    /// into the service — a copied struct shares the same `NSLock` reference. It would not cover two
    /// stores independently constructed over one path, which is a shape tests take and which nothing
    /// forbids. Keying on the standardised path costs a dictionary lookup once per store and makes
    /// the guarantee unconditional, so the doc above can be read as written.
    ///
    /// **Not an `actor`, and not `@MainActor` on the pass.** An actor would make `enqueue`
    /// asynchronous, and `enqueue` has to run *before* `deleteTask`'s local deletes, synchronously,
    /// which is the ordering the whole feature turns on. Annotating the pass `@MainActor` would work
    /// today and rests on every store call inside it happening to be synchronous — a guarantee that
    /// lives at the call site rather than in the type that needs it, and one the next `await` breaks
    /// silently.
    private static func lock(forFileAt fileURL: URL) -> NSLock {
        let key = fileURL.standardizedFileURL.path
        locksGuard.lock()
        defer { locksGuard.unlock() }
        if let existing = locksByPath[key] {
            return existing
        }
        let created = NSLock()
        locksByPath[key] = created
        return created
    }

    private static let locksGuard = NSLock()
    /// Never pruned. One `NSLock` per distinct store path, and the shipping app has exactly one;
    /// a test process accumulates one per temp directory it invents, which is a few bytes each and
    /// dies with the process. Pruning would need to know that no store value still holds a path,
    /// which is what a lock is for in the first place.
    nonisolated(unsafe) private static var locksByPath: [String: NSLock] = [:]

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("pending-server-deletions.json")
    }

    /// Records that this task's server copy is owed. **Synchronous, and called before the local
    /// records go.**
    ///
    /// Both halves of that sentence are the decision. `AgentViewModel.deleteTask` deletes three
    /// local records in a deliberate order and its doc comment already reasons about which
    /// half-failure is worse; this is a fourth step with a failure neither half has, and the
    /// ordering that bounds it is *this one first*. If the local delete ran first and this throw
    /// landed, the id would be gone from every file on the Mac and the server's copy could never be
    /// named again — a permanent, unrecoverable failure of the 2026-08-16 rule. This way round the
    /// worst case is a server copy deleted for a row the user still has locally, which is the safe
    /// direction for a rule that says delete means delete, and which the user can finish by pressing
    /// Delete again.
    ///
    /// Keyed on the task id, so pressing Delete twice on a row whose local delete failed the first
    /// time leaves one entry rather than two.
    public func enqueue(taskID: String, deletedAt: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try loadKeyed()
        insideTheCriticalSection?()
        // `deletedAt` is left as the first press wrote it when an entry is already here. The field
        // orders the queue and decides what the cap drops, and re-stamping it would move a delivery
        // that has been owed for a week to the back of the queue and to the front of the survivors.
        if entries[taskID] == nil {
            entries[taskID] = PendingServerDeletion(taskID: taskID, deletedAt: deletedAt)
        }
        try write(capped(entries))
    }

    /// Everything still owed, **oldest first** — the order it is delivered in, so a delivery that
    /// stops part-way has taken the ones that have waited longest.
    ///
    /// Ties break on the task id so the order is total: two deletions inside one second land on the
    /// same `deletedAt`, because these files persist dates with whole-second `.iso8601` like every
    /// other store here.
    public func loadAll() throws -> [PendingServerDeletion] {
        lock.lock()
        defer { lock.unlock() }
        insideTheCriticalSection?()
        return Array(try loadKeyed().values).sorted { left, right in
            if left.deletedAt != right.deletedAt {
                return left.deletedAt < right.deletedAt
            }
            return left.taskID < right.taskID
        }
    }

    /// Forgets one obligation — because it was delivered, or because it never can be.
    ///
    /// A task id that is not queued is a no-op rather than an error, matching every other
    /// per-entry delete in this codebase.
    public func remove(taskID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try loadKeyed()
        insideTheCriticalSection?()
        guard entries.removeValue(forKey: taskID) != nil else {
            return
        }
        try write(entries)
    }

    /// **A file that will not decode is set aside and the queue starts again, and this store is the
    /// one place in the app where that is the right answer** (PR #194 review, F1).
    ///
    /// Every other store propagates a decode failure, because the bytes are the user's — a routine,
    /// a workspace, a task's own history — and a later key migration may hand them back. Nothing
    /// here is recoverable in that sense: the file holds opaque ids of tasks that are *already gone
    /// locally*, so an unreadable queue's contents cannot be reconstructed by anything, ever.
    ///
    /// **What propagating it instead would cost is the whole feature, not one press.** `enqueue`
    /// loads before it writes, so an undecodable file makes *every subsequent* Delete fail to queue
    /// — and with `memoryCategory` `nil` there is no Memory row to clear it from, and no
    /// `LocalStorageLoadFailureSource` case to raise the banner. The only way out would be Settings'
    /// whole wipe or deleting the file by hand, which is the dead end `CLAUDE.md`'s poisoned-store
    /// note records, reached again through a new door. Healing turns a permanent systemic failure
    /// into a one-time loss of whatever was outstanding.
    ///
    /// **Set aside rather than unlinked**, through the same `LocalDataQuarantine` the Memory rows
    /// use, so the bytes survive under `<name>.unreadable-<stamp>` and Settings' Data page counts
    /// them and can remove them. That is also the only surface this failure has — worth knowing
    /// rather than assuming otherwise, and it is the honest one: the count is a number the user can
    /// act on, where a banner about an outbox would not be.
    ///
    /// **Only a file this Mac has a key for heals**, which is two conditions rather than one and was
    /// one until PR #194's cycle-3 R1. An I/O failure propagates, because the file may be perfectly
    /// good. So does anything that arrives while there is **no usable key** — a locked Keychain, a
    /// denied prompt — because that says nothing about the file and the key comes back.
    /// `.invalidKeyLength` propagates too, but through the guard's *first* clause rather than this
    /// one: it is a `LocalStorageEncryptionError` that is not `.undecodableLocalData`, so the case
    /// check turns it away and `hasAUsableKey` is never asked (PR #194 cycle-4's residuals).
    /// `hasAUsableKey` is the question that separates those from a file that will not
    /// read under a key that works, and it is needed because `decode` wraps a Keychain failure into
    /// the same case a corrupt file produces.
    ///
    /// **A wrong but valid-length key does heal**, deliberately; `hasAUsableKey` carries that
    /// decision and what it costs.
    ///
    /// A quarantine that itself fails re-throws the original decode error rather than its own, so
    /// the caller is told the thing that actually happened first.
    private func loadKeyed() throws -> [String: PendingServerDeletion] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded: LocalStorageDecoded<[String: PendingServerDeletion]>
        do {
            decoded = try encryption.decode(
                [String: PendingServerDeletion].self,
                from: data,
                decoder: .pendingServerDeletionISO8601
            )
        } catch let decodeFailure as LocalStorageEncryptionError {
            guard case .undecodableLocalData = decodeFailure, hasAUsableKey else { throw decodeFailure }
            do {
                _ = try LocalDataQuarantine(fileManager: fileManager).moveAside(fileURL)
            } catch {
                // **The original decode error, not the move's** (PR #194 cycle-3, R2). The doc above
                // has always said so and a bare `try` said otherwise: a failed `moveItem` reached
                // `deleteTask`, which renders `error.localizedDescription`, so the user was told the
                // file could not be moved instead of that it could not be read. The move failure is
                // the second thing that went wrong, and the caller is owed the first.
                throw decodeFailure
            }
            return [:]
        }
        return decoded.migratingLegacyPlaintext(store: "pending server deletions", write: write)
    }

    /// Whether this store can encrypt right now — in other words, whether it has a key at all.
    ///
    /// **The heal's precondition, and it is here because `decode` cannot tell the two apart**
    /// (PR #194 cycle-3, R1). `LocalStorageEncryption.decode` wraps every non-`LocalStorageEncryptionError`
    /// thrown inside its own `do` into `.undecodableLocalData`, and `key()` is called *inside* that
    /// block — so a Keychain that will not answer (`KeychainSecretStoreError.unexpectedStatus`, from
    /// a locked keychain or a denied prompt) arrives at the guard wearing the same case a corrupt
    /// file does. The reviewer measured the consequence against the real store: a file written
    /// seconds earlier with a good key, holding one owed deletion, was moved aside on a key-manager
    /// throw, `loadAll()` answered zero and did not throw, and nothing anywhere reported it. **The
    /// file was fine and the obligation was gone** — over a transient, which is the one thing three
    /// separate records promised could not happen.
    ///
    /// `encode` is the question that separates them, because **it does not wrap**: it calls `key()`
    /// outside any `catch`, so a key failure propagates raw and a success proves a usable key
    /// exists. An empty dictionary, so the answer costs one small `AES.GCM.seal` and touches no
    /// file.
    ///
    /// **A wrong but valid-length key still heals, and that is a decision rather than an oversight.**
    /// `encode` succeeds under any 32-byte key, so a file this Mac cannot open because it was
    /// written under a *different* key reaches the heal and is set aside. That is right for this
    /// store on its own argument — the alternative is every future Delete failing to record an
    /// obligation for as long as the key stays wrong, which is the systemic failure the heal exists
    /// to end — and it is the behaviour `LocalDataQuarantineTests.theOnlySelfHealingStoreIsTheOutbox`
    /// already pins, since that suite writes under one 32-byte key and reads under another. What is
    /// lost is real: those obligations are unrecoverable in practice even though the bytes are kept,
    /// because nothing ever reads a quarantined sibling. The three records that said a bad key
    /// propagates were wrong and say this instead.
    ///
    /// **What it cannot separate**, stated rather than left: a key that is wrong from bytes that are
    /// corrupt. Both answer "usable key, unreadable file", and both heal. Telling them apart needs
    /// `LocalStorageEncryption` to raise a distinct case for a key-acquisition failure — correct at
    /// the root, since that type's own comment already claims key-material failures are "deliberately
    /// *not* wrapped", which is true only of `.invalidKeyLength` — and that changes a type all
    /// fourteen stores decode through, which is not this ticket's to move.
    private var hasAUsableKey: Bool {
        ((try? encryption.encode([String: PendingServerDeletion]())) != nil)
    }

    /// Keeps the `maxItems` newest entries. See `maxItems` for why it is the oldest that go.
    ///
    /// **The tie-break runs the opposite way from `loadAll`'s and has to** (PR #194 review, F4). This
    /// sorts newest-first and keeps a prefix; `loadAll` sorts oldest-first, breaking ties on
    /// ascending id. Reversing only the date left the id half pointing the same way, so inside a
    /// tie group straddling the cut the entries kept were the ones that come *first* in delivery
    /// order — with `X(t0,"a")`, `Y(t0,"b")`, `Z(t1)` and a cap of two, the oldest by the documented
    /// order is `X` and the dropped entry was `Y`. **These files persist whole-second `.iso8601`
    /// dates**, so a same-second group is what a burst of deletes produces and this was the
    /// reachable form rather than a curiosity; the test that covered the cap used timestamps a
    /// minute apart and could not see it.
    private func capped(
        _ entries: [String: PendingServerDeletion]
    ) -> [String: PendingServerDeletion] {
        guard entries.count > Self.maxItems else {
            return entries
        }
        let kept = entries
            .sorted { left, right in
                if left.value.deletedAt != right.value.deletedAt {
                    return left.value.deletedAt > right.value.deletedAt
                }
                return left.key > right.key
            }
            .prefix(Self.maxItems)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func write(_ entries: [String: PendingServerDeletion]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(entries, encoder: .pendingServerDeletionPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pendingServerDeletionPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var pendingServerDeletionISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
