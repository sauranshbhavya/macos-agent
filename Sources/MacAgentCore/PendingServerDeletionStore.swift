import CryptoKit
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
    /// Which of the server's three delete routes settles this obligation (SONNY-404).
    ///
    /// **A scope rather than a route name**, so the file records what the user asked for rather than
    /// which path this version of the app happened to call. The queue outlives the version that
    /// wrote it, and a route can move; what the user pressed cannot.
    public enum Scope: String, Codable, Sendable, CaseIterable {
        /// Everything the server kept for these tasks — §4.6 for one, §4.6.1 for several. The
        /// *Delete task* button and *Memory › Task history › Delete*.
        case wholeTask
        /// This task's screenshots and nothing else — §4.6.2. *Delete what Sonny did on screen*,
        /// whose local half removes the vision-session record and leaves the task standing.
        case screenshotsOnly
        /// **Everything the servers retain under this account — §4.6.3 — and it names no task**
        /// (SONNY-404, founder decision 2026-09-04 restated 2026-09-05). Settings' whole wipe is a
        /// promise about the account, so when it cannot reach the gateway this is the one obligation
        /// it may leave on disk: a queue file holding it carries no task id, no command and no
        /// timestamp of anything the user did, so it leaks nothing a privacy wipe exists to remove.
        ///
        /// It is also strictly wider than the other two, which is what makes leaving it behind
        /// *sufficient*: an account-wide delete reaches everything every queued per-task obligation
        /// named, so the wipe can drop those and keep only this one without losing an obligation.
        case everythingUnderTheAccount
    }

    /// Whether this scope's obligation is about particular tasks.
    ///
    /// Exhaustive and with no `default`, so a fourth scope has to answer it rather than inheriting
    /// an answer — the difference decides whether an entry may carry no ids, and an entry that
    /// carries none when it should is an obligation no request can discharge.
    public static func namesTasks(_ scope: Scope) -> Bool {
        switch scope {
        case .wholeTask, .screenshotsOnly:
            return true
        case .everythingUnderTheAccount:
            return false
        }
    }

    /// The tasks this obligation covers — `CompletedTaskRecord.id`, which is the backend's
    /// `task_id` (contract §5.1). Never empty.
    ///
    /// **A list rather than one id, and the cap is the reason** (SONNY-404). *Task history › Delete*
    /// removes every row at once, up to `TaskHistoryStore.defaultMaxItems` — ten thousand — and
    /// `maxItems` here is two hundred. One entry per row would drop nine thousand eight hundred
    /// obligations to the eviction below, silently, from the one press that asks for the most. The
    /// founder's decision of 2026-09-05 that the press sends one bulk call and this shape are the
    /// same decision seen from the two ends.
    public var taskIDs: [String]

    /// What the delete reached on the Mac, and therefore what it has to reach on the server.
    public var scope: Scope

    /// When the user pressed Delete.
    ///
    /// Read for two things and neither is display: the total order the queue is delivered in, and
    /// which entry the cap drops when the queue is full. **Nothing renders it**, which is why it is
    /// the only field here besides the keys — a queue entry that carried the command text, or the
    /// time a task ran, would be a record of the deleted task surviving the deletion.
    public var deletedAt: Date

    /// The dictionary key this entry is filed under. Derived, never stored.
    ///
    /// A single-task obligation keys on its own id, so pressing Delete twice on a row whose local
    /// delete failed the first time still leaves one entry — the property SONNY-333 built and the
    /// one this generalises rather than replaces. A many-task obligation keys on a digest of its
    /// ids, so an identical press coalesces the same way while two different sets stay two
    /// obligations. The scope is part of every key: a task can owe both a whole-task delete and a
    /// screenshots-only one, and those are different asks.
    public var id: String { Self.key(scope: scope, taskIDs: taskIDs) }

    public init(taskIDs: [String], scope: Scope, deletedAt: Date) {
        self.taskIDs = taskIDs
        self.scope = scope
        self.deletedAt = deletedAt
    }

    public init(taskID: String, deletedAt: Date) {
        self.init(taskIDs: [taskID], scope: .wholeTask, deletedAt: deletedAt)
    }

    static func key(scope: Scope, taskIDs: [String]) -> String {
        guard namesTasks(scope) else {
            // One obligation of this kind ever, so a second wipe that could not reach the gateway
            // coalesces onto the first rather than queueing a duplicate of a request that is
            // idempotent anyway.
            return scope.rawValue
        }
        guard taskIDs.count != 1 else {
            return "\(scope.rawValue):\(taskIDs[0])"
        }
        return "\(scope.rawValue):#\(digest(of: taskIDs))"
    }

    /// A stable name for a *set* of task ids.
    ///
    /// Sorted first, so the same set named in a different order is the same obligation — the ids
    /// arrive in whatever order the history file happened to hold them, and two presses over one
    /// history must not queue two entries. SHA-256 rather than the ids joined, for the reason
    /// `StandingWatcherEvaluator.digest(of:)` gives: the key stays a fixed small size whatever the
    /// press covered, and a dictionary key naming ten thousand deleted tasks would be the deleted
    /// tasks written down twice.
    private static func digest(of taskIDs: [String]) -> String {
        let joined = taskIDs.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case taskIDs
        case scope
        case deletedAt
    }

    /// **Reads a file written before this store knew about scopes or about more than one id**
    /// (SONNY-404). Such a file holds `taskID` and `deletedAt` and nothing else, and every entry in
    /// it is a whole-task obligation, because that was the only kind there was.
    ///
    /// Written as a decoder rather than left to a `Codable` default because there is no such thing:
    /// a missing required key is a decode failure, and a decode failure in *this* store is healed by
    /// quarantining the file — so the upgrade would have thrown the user's outstanding obligations
    /// away and reported nothing. That is the one failure this whole ticket exists to prevent,
    /// arriving through the door built to prevent it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deletedAt = try container.decode(Date.self, forKey: .deletedAt)
        scope = try container.decodeIfPresent(Scope.self, forKey: .scope) ?? .wholeTask
        if let ids = try container.decodeIfPresent([String].self, forKey: .taskIDs) {
            taskIDs = ids
        } else {
            taskIDs = [try container.decode(String.self, forKey: .taskID)]
        }
    }

    /// Writes today's shape only. The legacy `taskID` is read and never written, so a file rewritten
    /// once is a file in the current shape — and a reader older than SONNY-404 meeting it fails to
    /// decode, which this store heals rather than propagates.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(taskIDs, forKey: .taskIDs)
        try container.encode(scope, forKey: .scope)
        try container.encode(deletedAt, forKey: .deletedAt)
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
/// **What the whole wipe does to this file, and it is not what this paragraph used to say**
/// (SONNY-404, founder decision 2026-09-04 restated 2026-09-05). It said the wipe reaches this file
/// like every other and therefore *abandons* whatever was owed — "deliberate", because "Delete Sonny
/// local data has never been a promise about the server". That is superseded. The wipe **is** a
/// promise about the account, and the rule is now:
///
/// 1. **The queue is drained before this file is removed.** That is the founder's own condition on
///    the decision, in those words.
/// 2. **Everything the gateway retains for the account is deleted** — `DELETE /v1/account/content`,
///    contract §4.6.3 — which reaches everything every queued per-task obligation named. The account
///    itself stays open.
/// 3. **This file is then deleted with every other store**, so no task id survives the press.
/// 4. **If step 2 could not reach the gateway, one obligation is written back**:
///    `.everythingUnderTheAccount`, which **names no task**. That is what makes it safe for the one
///    file a privacy wipe leaves behind to be this one — it carries no id, no command and no time of
///    anything the user did — and what makes it *sufficient* is that it is strictly wider than every
///    obligation the wipe just discarded.
///
/// So nothing owed is abandoned by the press, with one exception written down at
/// `AgentViewModel.deleteLocalData`: an entry the drain kept on a `404`, meaning a task belonging to
/// a **different** account signed into this same Mac. The account-wide delete cannot reach it and
/// the file cannot keep it, because keeping it would mean leaving a file that names a task.
///
/// **The other two answers of 2026-09-05 stand.** The Memory Task-history row's Delete queues every
/// row's deletion, as one entry naming many ids and one bulk call. And "Delete what Sonny did on
/// screen" got a route of its own, because `DELETE /v1/tasks/{task_id}` takes a task's whole content
/// and that button names one part of it.
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
        try enqueue(taskIDs: [taskID], scope: .wholeTask, deletedAt: deletedAt)
    }

    /// Records an obligation covering one task or many, in one of the two scopes (SONNY-404).
    ///
    /// **Many ids are one entry and not many, and the cap is why.** *Task history › Delete* names
    /// every row the Mac holds — up to ten thousand — against a queue that keeps two hundred. As
    /// separate entries the eviction below would take nine thousand eight hundred of them without
    /// saying so, from the one press that asks for the most; as one entry it is one obligation the
    /// cap counts once and one call the founder decided on.
    ///
    /// **Empty is a no-op rather than an error.** *Task history › Delete* pressed on an empty history
    /// deletes nothing locally and owes nothing on the server, and an empty entry would be an
    /// obligation naming nothing that every future pass would deliver as a request about no tasks.
    ///
    /// **The two scopes do not subsume one another, deliberately.** A task can owe both — the user
    /// deletes its screen record offline and then deletes the task itself — and the two entries are
    /// delivered independently. Neither order is a hazard: whichever lands second finds its content
    /// already gone and answers a success with a count of zero, which is §4.6's own rule that a
    /// delete which is already true is not an error. Collapsing them would mean deciding which ask
    /// wins, and there is no reading under which the narrower one should cancel the wider.
    public func enqueue(
        taskIDs: [String],
        scope: PendingServerDeletion.Scope,
        deletedAt: Date = Date()
    ) throws {
        // Trimmed-empty rather than empty, matching the server's own `z.string().trim().min(1)`:
        // an id of spaces names nothing the gateway will accept, so an obligation carrying one is an
        // obligation no request can ever discharge. The id itself is kept as it was — this decides
        // what to drop, not what to send.
        let unique = PendingServerDeletion.namesTasks(scope)
            ? Array(Set(taskIDs.filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }))
            // **An account-wide obligation carries no ids and any it was handed are dropped here**
            // (SONNY-404). It is about the account and not about tasks, and the whole reason the
            // wipe may leave it on disk is that the file it sits in then names nothing the user did.
            : []
        guard !unique.isEmpty || !PendingServerDeletion.namesTasks(scope) else {
            return
        }
        let entry = PendingServerDeletion(taskIDs: unique, scope: scope, deletedAt: deletedAt)
        lock.lock()
        defer { lock.unlock() }
        var entries = try loadKeyed()
        insideTheCriticalSection?()
        // `deletedAt` is left as the first press wrote it when an entry is already here. The field
        // orders the queue and decides what the cap drops, and re-stamping it would move a delivery
        // that has been owed for a week to the back of the queue and to the front of the survivors.
        if entries[entry.id] == nil {
            entries[entry.id] = entry
        }
        try write(capped(entries))
    }

    /// Everything still owed, **oldest first** — the order it is delivered in, so a delivery that
    /// stops part-way has taken the ones that have waited longest.
    ///
    /// Ties break on the entry's own key so the order is total: two deletions inside one second land
    /// on the same `deletedAt`, because these files persist dates with whole-second `.iso8601` like
    /// every other store here. (The key was the task id until SONNY-404 gave an entry more than one
    /// of those; it is `scope:id` for a single task and `scope:#digest` for a set, so it is still a
    /// total order over the same population.)
    public func loadAll() throws -> [PendingServerDeletion] {
        lock.lock()
        defer { lock.unlock() }
        insideTheCriticalSection?()
        return Array(try loadKeyed().values).sorted { left, right in
            if left.deletedAt != right.deletedAt {
                return left.deletedAt < right.deletedAt
            }
            return left.id < right.id
        }
    }

    /// Forgets one obligation — because it was delivered, or because it never can be.
    ///
    /// An obligation that is not queued is a no-op rather than an error, matching every other
    /// per-entry delete in this codebase.
    public func remove(_ entry: PendingServerDeletion) throws {
        try remove(key: entry.id)
    }

    /// Forgets the whole-task obligation for one id — the withdrawal `deleteTask` performs when its
    /// local delete throws after the enqueue succeeded.
    public func remove(taskID: String) throws {
        try remove(key: PendingServerDeletion.key(scope: .wholeTask, taskIDs: [taskID]))
    }

    private func remove(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entries = try loadKeyed()
        insideTheCriticalSection?()
        guard entries.removeValue(forKey: key) != nil else {
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
        return rekeyed(decoded.migratingLegacyPlaintext(store: "pending server deletions", write: write))
    }

    /// Files every decoded entry under the key its own contents give it.
    ///
    /// **The keys on disk are not trusted, and that is what makes the file's shape upgradable**
    /// (SONNY-404). A file written before this store knew about scopes keys a whole-task obligation
    /// under the bare task id; today's key is `wholeTask:<id>`. Re-deriving means the old file's
    /// obligations arrive filed the way `enqueue` and `remove` look for them, rather than sitting in
    /// the dictionary under names nothing will ever ask for again.
    ///
    /// **A collision keeps the older entry**, which is the same direction `enqueue` takes when an
    /// obligation is already present: `deletedAt` orders delivery and decides what the cap drops, and
    /// the older stamp is the one that has been waiting. Reachable only from a file two keys of which
    /// name one obligation, which is a hand-edited file or a version that wrote both shapes.
    private func rekeyed(
        _ entries: [String: PendingServerDeletion]
    ) -> [String: PendingServerDeletion] {
        Dictionary(
            entries.values
                .filter { !PendingServerDeletion.namesTasks($0.scope) || !$0.taskIDs.isEmpty }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, second in first.deletedAt <= second.deletedAt ? first : second }
        )
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
