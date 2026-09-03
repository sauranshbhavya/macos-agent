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
    /// **The oldest go first when it is full**, which is not the arbitrary half of the choice. An
    /// entry's content is on the server's own 30-day clock, so the oldest entry is the one whose
    /// content is likeliest to have expired without anybody deleting it — the least is lost by
    /// dropping it. Dropping the newest would discard the deletion the user just asked for while
    /// keeping ones from weeks ago.
    public static let maxItems = 200

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
    }

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
    @discardableResult
    public func enqueue(taskID: String, deletedAt: Date = Date()) throws -> PendingServerDeletion {
        let entry = PendingServerDeletion(taskID: taskID, deletedAt: deletedAt)
        var entries = try loadKeyed()
        // `deletedAt` is left as the first press wrote it when an entry is already here. The field
        // orders the queue and decides what the cap drops, and re-stamping it would move a delivery
        // that has been owed for a week to the back of the queue and to the front of the survivors.
        if entries[taskID] == nil {
            entries[taskID] = entry
        }
        try write(capped(entries))
        return entries[taskID] ?? entry
    }

    /// Everything still owed, **oldest first** — the order it is delivered in, so a delivery that
    /// stops part-way has taken the ones that have waited longest.
    ///
    /// Ties break on the task id so the order is total: two deletions inside one second land on the
    /// same `deletedAt`, because these files persist dates with whole-second `.iso8601` like every
    /// other store here.
    public func loadAll() throws -> [PendingServerDeletion] {
        Array(try loadKeyed().values).sorted { left, right in
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
        var entries = try loadKeyed()
        guard entries.removeValue(forKey: taskID) != nil else {
            return
        }
        try write(entries)
    }

    private func loadKeyed() throws -> [String: PendingServerDeletion] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [String: PendingServerDeletion].self,
            from: data,
            decoder: .pendingServerDeletionISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "pending server deletions", write: write)
    }

    /// Keeps the `maxItems` newest entries. See `maxItems` for why it is the oldest that go.
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
                return left.key < right.key
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
