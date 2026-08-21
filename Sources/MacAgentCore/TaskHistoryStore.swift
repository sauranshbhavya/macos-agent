import Foundation

/// What started a task. Scheduled runs are recorded in history like any other task — they are real
/// work Sonny did, and a scheduled run that failed has to be debuggable — but they are excluded
/// from the two Insights stats that are claims about the *user's* habit rather than about Sonny's
/// output. See `TaskHistoryInsights`.
public enum TaskTrigger: String, Codable, Equatable, Sendable {
    case manual
    case scheduled
}

public struct CompletedTaskRecord: Codable, Equatable, Sendable {
    /// This record's own identity, and the only safe way to address one.
    ///
    /// **Why a stored id rather than the natural key the app used to fake.** Before row D there was
    /// none, so the UI invented one twice — `TaskLogEntry.id` as
    /// `"\(startedAt.timeIntervalSince1970)-\(command)"` and the history list's `ForEach(id:)` on
    /// `startedAt` alone. Both are `(command, startedAt)` compound keys, and this store persists
    /// dates with plain `.iso8601` and no fractional-seconds option, which truncates to whole
    /// seconds. Two runs of the same command started inside one second therefore land on the same
    /// key, and a delete built on it can delete the wrong twin. That is demonstrated, not assumed:
    /// `twinsThatCollideOnTheOldCompoundKeyStillHaveSeparateIds` round-trips two runs started 400ms
    /// apart through this store and gets one timestamp back.
    ///
    /// **The precedent, at the strength the record actually supports.** The deleted egress ledger
    /// reached for the same `startedAt` join key and replaced it with an id, after mutation E10
    /// survived its battery "because both stores persist ISO8601 and whole-second truncation makes
    /// date equality unable to see sub-second drift" (`docs/sonny-v1-implementation-changelog.md`).
    /// Read that entry's PR #49 correction alongside it: finding F6, in the same document, records
    /// the E10 sentence as **overstated** — E10-as-written removed its own target once the join was
    /// an id, and the whole-second assertion it survived was deleted with the dispatch suite. So the
    /// precedent is that this key was abandoned here once for this reason, not that it is on record
    /// as having corrupted data. The reason to abandon it again is the collision above.
    ///
    /// **Why not just widen the timestamp.** Adding fractional seconds to the encoder was the
    /// obvious alternative and is the wrong fix, though not for the reason it first looks like:
    /// checked on this repo's toolchain at 6f89a5d (Apple Swift 6.3.3), `JSONDecoder`'s `.iso8601`
    /// strategy reads a fractional-seconds timestamp back happily, so the migration would in fact
    /// survive the files already on disk. It is the wrong fix because it does not buy identity.
    /// `(command, startedAt)` stays a *natural* key at any precision: it breaks the moment either
    /// field is edited, and two runs that genuinely begin at the same instant still collide. An id
    /// is identity; a timestamp is data that happens to be unique most of the time.
    ///
    /// Optional, per the twice-documented `AutomationStores.swift` decode rule and the precedent of
    /// `trigger` and `visionSessionID` below: every `task-history.json` written before this branch
    /// has no such key, and a non-Optional field with a Swift-side default would still throw
    /// `keyNotFound` on all of them. `nil` therefore means only "written before ids existed" —
    /// `TaskHistoryStore.loadAll()` backfills one and rewrites the file, so after a single
    /// successful load no record is left without an id.
    ///
    /// The initializer defaults to a fresh `UUID().uuidString` (evaluated per call), so every
    /// record written from here on has one before it ever reaches disk.
    public var id: String?
    public var command: String
    public var startedAt: Date
    public var completedAt: Date
    public var outcomeStatus: PriorTaskOutcomeStatus
    public var workspaceName: String?
    /// Optional so a task-history.json written before routine scheduling still decodes — the same
    /// `decodeIfPresent` reasoning as `StoredWorkspace.teamType`. Absent means manual, which is
    /// what every pre-existing record is.
    public var trigger: TaskTrigger?
    /// The screen-control session this task ran, if it ran one — the key into
    /// `VisionSessionJournalStore` (row I, SONNY-96).
    ///
    /// **The linkage decision, recorded here because rows D and E inherit it.** The alternatives were
    /// an optional field like this one and a pure side-store lookup keyed on the record's natural
    /// identity. The field wins on two grounds. First, `CompletedTaskRecord` has no id: a side-store
    /// lookup would have to key on `(command, startedAt)`, a compound natural key that two identical
    /// commands started in the same second collide on and that any future edit to either field
    /// silently breaks. Second, a task detail view has to know *whether* a journal exists before it
    /// can decide to offer the affordance, and with a pure side store that question costs a full
    /// decrypt-and-scan of every session on every row render.
    ///
    /// Optional, per the twice-documented `AutomationStores.swift` decode rule: every
    /// `task-history.json` written before row I has no such key, and a non-Optional field with a
    /// Swift-side default would throw `keyNotFound` on all of them. Absent means "this task ran no
    /// screen-control session", which is what every pre-existing record is.
    ///
    /// **The record holds the link, the side store holds the content** — deliberately, so deleting
    /// the journal (rows D/E) leaves task history intact and merely un-followable, rather than
    /// tearing rows out of a history the journal was never the point of.
    public var visionSessionID: String?
    /// What this task produced — the text the user was shown when it finished (SONNY-147).
    ///
    /// **Present on failures and cancellations too**, carrying the text that was actually shown:
    /// "Canceled." for a cancelled run, the error's own description for a failed one. A field that
    /// only survived clean finishes would be empty on exactly the runs someone most wants to read
    /// afterwards.
    ///
    /// Optional, per the twice-documented `AutomationStores.swift` decode rule and the precedent of
    /// `trigger`, `visionSessionID` and `id` above: every `task-history.json` written before row E
    /// has no such key, and a non-Optional field with a Swift-side default would throw
    /// `keyNotFound` on all of them. **`nil` means "recorded before Sonny kept results", which is
    /// every pre-existing record — and it is deliberately distinguishable from a result whose text
    /// is empty.** Nothing backfills it: that information is gone, and inventing it would be worse
    /// than its absence.
    ///
    /// **A `StoredTaskResult` and not a `String`**, so the writer has to say whether a model wrote
    /// the text. See that type for what the declaration buys and the one thing it cannot promise.
    ///
    /// **The plan that produced it is not here.** It lives in `TaskPlanDetailStore`, keyed on this
    /// record's `id` — the founder's decision of 2026-08-17, on measured size. The result stays on
    /// the row because it is small, because it is the first thing task detail renders, and because
    /// keeping it here means a task can say what it produced without a second file read.
    public var result: StoredTaskResult?

    public init(
        id: String? = UUID().uuidString,
        command: String,
        startedAt: Date,
        completedAt: Date,
        outcomeStatus: PriorTaskOutcomeStatus,
        workspaceName: String? = nil,
        trigger: TaskTrigger? = nil,
        visionSessionID: String? = nil,
        result: StoredTaskResult? = nil
    ) {
        self.id = id
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.outcomeStatus = outcomeStatus
        self.workspaceName = workspaceName
        self.trigger = trigger
        self.visionSessionID = visionSessionID
        self.result = result
    }

    public var effectiveTrigger: TaskTrigger {
        trigger ?? .manual
    }
}

public struct TaskHistoryStore: @unchecked Sendable {
    /// Bounded by record count (eviction drops oldest-first via `completedAt`), not by a fixed
    /// duration — this is still a recency-based cutoff, just parameterized by count rather than
    /// age. Today every `TaskHistoryInsights` stat (current streak, `hasCompletedToday`,
    /// this-week/previous-week) only reads a recent window, so eviction never touches data those
    /// stats need. Any future all-time/lifetime stat (total tasks ever, longest streak on record)
    /// would need to revisit this cap before shipping.
    ///
    /// **The cap stays, and nothing claims more than it delivers (SONNY-119).** The founder's
    /// instruction of 2026-08-16 was to raise it, surface it, or state it — the promise and the code
    /// have to agree — because row D adds a search box, and a search box implies that what it does
    /// not return is not there. Of the three, stating it is the only one that costs nothing:
    ///
    /// - **Raising is not free**, and the price is paid on every finished task rather than once.
    ///   `record(_:)` decodes and re-encrypts the whole file per call. Measured at `36cef9e` on an
    ///   M-series Mac, with a history sitting at this cap: a 3.53 MiB file, `record(_:)` **130 ms**
    ///   median over five runs. There is no other brake on growth, so removing this one makes every
    ///   task slower, permanently.
    /// - **Surfacing it is forbidden.** A sentence in the app explaining that older tasks are
    ///   removed is exactly the how-it-works copy the founder's decision of 2026-08-14 rules out.
    /// - **Stating it is true and cheap.** 10,000 records is roughly sixteen months at twenty tasks
    ///   a day. The guarantee is kept by never writing the completeness sentence at all — not in the
    ///   app, not in a changelog, not in a PR body. The product never promises search finds
    ///   everything, so there is nothing to walk back.
    ///
    /// **Which record size that measurement assumes, and what row E actually did to it.** 130 ms is
    /// today's eight-field record: 374 bytes encoded, 3.78 MiB at the cap (measured at `36cef9e`).
    /// SONNY-119 then measured the shape row E was approved on — a stored result *plus* the plan
    /// summary and the plan's steps, all on this record — at roughly 4.1 kB per record, 40 MiB at
    /// this cap and **307 ms** median for `record(_:)`: about **11x** the bytes, not the "roughly
    /// triples" that ticket's own note estimated, for 2.4 times the time, because encryption and I/O
    /// throughput dominate the per-record JSON work at these sizes.
    ///
    /// That measurement is why the shape changed. The founder's decision of 2026-08-17 moved the
    /// plan summary and steps into `TaskPlanDetailStore`, leaving this record one new field —
    /// `result`, capped at 1,000 characters. Record size is additive in it (SONNY-119's own "+
    /// result 200 chars, 8 steps" row is exactly 374 + 200 + its 1,729 B of steps), so the worst
    /// case here is about **1.4 kB** a record and **13 MiB** at this cap, and the typical case is a
    /// few hundred bytes above today's 374. The 40 MiB and 307 ms figures describe the design that
    /// was not built; they are kept because they are the reason it was not.
    ///
    /// Every figure argues the same way — keep the cap.
    ///
    /// **The shipped number, and the only one any production path uses.** Enumerated at `5bbe380`:
    /// the three places that build a `TaskHistoryStore` outside tests — `AgentViewModel`'s default
    /// parameter, `LocalDataDeletionService.defaultStoreFileURLs()` and
    /// `LocalStore.fileURL(fileManager:)` — all take this default and none passes a cap.
    public static let defaultMaxItems = 10_000

    /// This store's cap, defaulting to `defaultMaxItems`.
    ///
    /// **Injectable for one reason: so a test can exercise eviction without ten thousand records**
    /// (SONNY-161). Pinning the eviction had cost about 0.33 s of solid CPU per test — four JSON
    /// passes over a few megabytes — and two such tests running inside a parallel suite stole enough
    /// time to break the wall-clock deadlines in `VisionSessionRunTests`. Eviction logic does not
    /// care what the number is, so the tests now use a small one and
    /// `theShippedCapIsTenThousandAndNoProductionPathOverridesIt` pins the real value separately.
    ///
    /// This is not a way to change the shipped cap. That value is the founder's decision of
    /// 2026-08-16 (SONNY-119), and it is `defaultMaxItems` above.
    ///
    /// Floored at 1: a store built with 0 would evict everything on the next write, which is silent
    /// data loss rather than a small cap. Clamping keeps a mistyped test cheap instead of crashing
    /// an app that never passes this argument at all.
    public let maxItems: Int

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared,
        maxItems: Int = Self.defaultMaxItems
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        self.maxItems = max(1, maxItems)
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("task-history.json")
        }
    }

    /// Appends one record, evicting the oldest once the cap is passed.
    ///
    /// - Returns: the ids of the records this call evicted, oldest-first, so a caller can drop
    ///   whatever hangs off them. `TaskPlanDetailStore` is the one dependent today, and this return
    ///   value is what makes its "same cap, same eviction" claim a built property rather than a
    ///   coincidence that holds only while every row happens to have a plan. Discardable, because
    ///   the tests and the scheduled path that write rows with nothing hanging off them should not
    ///   have to say so.
    @discardableResult
    public func record(_ record: CompletedTaskRecord) throws -> [String] {
        var records = try loadAll()
        records.append(record)
        let (kept, evicted) = cappedAndEvicted(records)
        try write(kept)
        return evicted.compactMap(\.id)
    }

    /// Removes one record by its `id`, leaving every other record exactly as it was.
    ///
    /// Addressed by `id` and nothing else. The `(command, startedAt)` key the UI used to fake an
    /// identity from cannot do this job: whole-second truncation makes two runs of one command
    /// started inside the same second collide, so a delete keyed on it can take the wrong twin —
    /// which is why `CompletedTaskRecord.id` exists at all. `TaskHistoryRetentionTests` and
    /// `TaskHistoryDeletionTests` both construct that collision rather than assume it away.
    ///
    /// **Deleting something already gone is not an error**, and it does not rewrite the file
    /// either. A delete that re-encrypted a 3.5 MiB history to change nothing would be paying the
    /// whole cost of a write for no effect.
    public func delete(id: String) throws {
        let records = try loadAll()
        let remaining = records.filter { $0.id != id }
        guard remaining.count != records.count else {
            return
        }
        try write(remaining)
    }

    public func loadAll() throws -> [CompletedTaskRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [CompletedTaskRecord].self,
            from: data,
            decoder: .taskHistoryISO8601
        )
        let migrated = decoded.migratingLegacyPlaintext(store: "task history", write: write)
        return backfillingMissingIDs(migrated)
    }

    /// Gives every record written before `CompletedTaskRecord.id` existed one, and rewrites the
    /// file so the id is stable from then on. After one *successful* load nothing is left without an
    /// id, which is what makes a record addressable at all — see the field's own doc comment for
    /// why the compound natural key it replaces could not be addressed safely.
    ///
    /// The stability is bought by the rewrite, so a store whose rewrite keeps failing hands out a
    /// fresh id per load rather than a stable one. That is the honest consequence of the retry
    /// contract below and not a second failure mode to design around: the only thing that keeps a
    /// rewrite failing is a store directory nothing can write to, and a task history nothing can
    /// write to has already stopped recording tasks.
    ///
    /// Deliberately shaped like `migratingLegacyPlaintext`, including its behaviour when the
    /// rewrite fails: **a failed rewrite is not a load failure and must not be reported as one.**
    /// The decode succeeded, so the data is intact and usable; writes are atomic, so a failed one
    /// leaves the original file exactly as it was; and the backfill retries for free on the next
    /// load. Throwing here would make callers discard records that had just decoded correctly and
    /// show the "could not be decrypted or decoded" banner, which is wrong on both counts.
    ///
    /// The two upgrades are separate writes rather than one because they are separate conditions —
    /// a file can need either, both, or neither. A file needing both is written twice on that one
    /// load, both times atomically, and only on that load.
    private func backfillingMissingIDs(_ records: [CompletedTaskRecord]) -> [CompletedTaskRecord] {
        guard records.contains(where: { $0.id == nil }) else {
            return records
        }

        let backfilled = records.map { record -> CompletedTaskRecord in
            guard record.id == nil else {
                return record
            }
            var withID = record
            withID.id = UUID().uuidString
            return withID
        }

        do {
            try write(backfilled)
        } catch {
            LocalStorageMigrationLog.recordDeferredIDBackfill(store: "task history", error: error)
        }
        return backfilled
    }

    private func cappedAndEvicted(
        _ records: [CompletedTaskRecord]
    ) -> (kept: [CompletedTaskRecord], evicted: [CompletedTaskRecord]) {
        guard records.count > maxItems else {
            return (records, [])
        }
        let ordered = records.sorted { $0.completedAt < $1.completedAt }
        return (Array(ordered.suffix(maxItems)), Array(ordered.dropLast(maxItems)))
    }

    private func write(_ records: [CompletedTaskRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(records, encoder: .taskHistoryPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var taskHistoryPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var taskHistoryISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
