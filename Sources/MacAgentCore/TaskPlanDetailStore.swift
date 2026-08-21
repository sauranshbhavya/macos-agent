import Foundation

/// The plan a finished task ran, kept so a follow-up on that task has something to correct against
/// (SONNY-147).
///
/// **Not rendered to anyone.** These are context for the planner, not a step log on a user-facing
/// receipt — the surface the founder rejected on 2026-07-18. `TaskLogDetailDialog` shows what the
/// task *produced*, which lives on the record itself as `CompletedTaskRecord.result`.
///
/// **Every stored field is model-authored**, uniformly: `planSummary` is `AgentPlan.summary`, which
/// a planner wrote, and each step's description and details come from the plan's own steps. There
/// is no provenance flag here for the reason there is one on `StoredTaskResult` — that type carries
/// a mixture and has to say which it holds, while this one has no code-authored case to be confused
/// with. Everything here reaches a planner only through `PriorTaskContext`, whose
/// `plannerContextText` escapes every field it interpolates.
public struct StoredTaskPlanDetail: Codable, Equatable, Sendable {
    /// The `CompletedTaskRecord.id` this detail belongs to.
    ///
    /// Keyed on the id and never on `(command, startedAt)`. That compound key collides — the history
    /// store persists dates with plain `.iso8601`, which truncates to whole seconds, so two runs of
    /// one command inside one second are indistinguishable under it. `CompletedTaskRecord.id` exists
    /// precisely because of that, and `TaskHistoryDeletionTests` constructs the collision rather
    /// than assuming it away.
    public var taskID: String
    /// The task's own `completedAt`, copied here so this store can evict by the same rule and the
    /// same clock the history store does rather than by a second one that could drift.
    public var completedAt: Date
    public var planSummary: String
    public var steps: [PriorTaskStepContext]

    /// No single stored string may exceed this, in characters.
    ///
    /// Applies to the plan summary, to each step's description, and to each of a step's detail
    /// strings — the last of which matters most, because `PriorTaskStepContext.init(step:)` folds
    /// `sourceURLs` into one joined value and a plan carrying a dozen long URLs would otherwise put
    /// all of them in one field.
    public static let maxFieldCharacters = 400

    /// The whole entry's text budget, in characters: the plan summary plus every step's description
    /// and details, summed.
    ///
    /// **One budget rather than a product of per-field caps**, because a product is a bound nobody
    /// can hold in their head. Twenty steps at 400 characters of description plus sixteen details of
    /// 400 each is 136 kB an entry and over a gigabyte at this store's cap — technically bounded,
    /// practically unbounded. A single running total is a number a reader can check against the
    /// file size. Steps are kept whole and the remainder is dropped once the budget is spent, so a
    /// truncated plan is a prefix of the real one rather than a mangled version of all of it.
    ///
    /// 2,500 is roughly ten times a real plan: SONNY-119 measured eight steps with no details at
    /// about 1.7 kB encoded (at `36cef9e`), and the plans this product actually produces are two to
    /// four steps whose descriptions are a short sentence each.
    public static let maxTotalCharacters = 2_500

    public init(taskID: String, completedAt: Date, planSummary: String, steps: [PriorTaskStepContext]) {
        self.taskID = taskID
        self.completedAt = completedAt

        let summary = Self.capField(planSummary)
        var remaining = Self.maxTotalCharacters - summary.count
        var kept: [PriorTaskStepContext] = []
        for step in steps {
            let capped = PriorTaskStepContext(
                operation: step.operation,
                description: Self.capField(step.description),
                details: step.details.map(Self.capField)
            )
            let cost = capped.description.count + capped.details.reduce(0) { $0 + $1.count }
            guard cost <= remaining else {
                break
            }
            remaining -= cost
            kept.append(capped)
        }

        self.planSummary = summary
        self.steps = kept
    }

    /// The plan a run produced, as it will be stored.
    public init(taskID: String, completedAt: Date, plan: AgentPlan) {
        self.init(
            taskID: taskID,
            completedAt: completedAt,
            planSummary: plan.summary,
            steps: plan.steps.map(PriorTaskStepContext.init(step:))
        )
    }

    private enum CodingKeys: String, CodingKey {
        case taskID
        case completedAt
        case planSummary
        case steps
    }

    /// Written out rather than synthesized so a decoded entry runs through the same budget a written
    /// one does. Same reasoning as `StoredTaskResult.init(from:)`: a cap the decode path skips is a
    /// cap on one direction only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            taskID: try container.decode(String.self, forKey: .taskID),
            completedAt: try container.decode(Date.self, forKey: .completedAt),
            planSummary: try container.decode(String.self, forKey: .planSummary),
            steps: try container.decode([PriorTaskStepContext].self, forKey: .steps)
        )
    }

    private static func capField(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxFieldCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maxFieldCharacters - 1)) + "\u{2026}"
    }
}

/// The **tenth** local store, on the shared pattern exactly: what each finished task planned.
///
/// **Why the heavy half of row E lives beside `task-history.json` rather than inside it** (founder,
/// 2026-08-17, superseding his own decision of 2026-08-16 that all three new fields ride the
/// record). The earlier choice was made on a privacy argument that remains correct — a separate
/// store buys little when the backend retains the same content for 30–90 days, and the local copy
/// is the one the user can actually delete. What was missing was a measurement. SONNY-119's session
/// then took one at `36cef9e`: with the plan and its steps on the record, the history file reaches
/// 38.81 MiB at its 10,000-record cap and `record(_:)` costs 307 ms, against 3.53 MiB and 130 ms
/// today. These stores are whole-file encrypted, so that is ~39 MB decrypted on every read and
/// re-encrypted on every finished task. "Roughly triples" measured as about 11x.
///
/// **What the split actually buys, stated honestly, because it is not the write path.** A finished
/// task now writes two files instead of one and the summed bytes are similar. The gain is on the
/// reads: `TaskHistoryStore.loadAll()` runs several times per task — inside `record(_:)` itself,
/// again in `refreshTaskHistory()`, and again for the Tasks list, search and Insights — while this
/// store is read only when someone opens one task's detail or arms a follow-up on it. Moving the
/// ~1.7 kB of plan text per record out of the file that is read constantly and into the one that is
/// read almost never is where the time goes.
///
/// **Same life as the task row, and that is a requirement rather than a coincidence.** The founder's
/// objection to splitting was that "follow-ups on older tasks quietly get weaker with no way to say
/// so" — a silent degradation the product cannot explain under the no-explanatory-copy rule. That
/// objection binds only if this store outlives its rows by less, so it must not: same cap, same
/// oldest-first-by-`completedAt` rule, deleted with the row, suppressed with the row. A session that
/// gives this store a shorter life reintroduces exactly what was rejected; if a shorter life ever
/// looks attractive on size grounds, that is a founder question and not an implementation detail.
///
/// The alignment is **built, not assumed**: `TaskHistoryStore.record(_:)` returns the ids it
/// evicted, and `save(_:evictedTaskIDs:)` drops those details in the same write. Without that
/// handoff the two stores would only stay level while every row had a detail — and rows written by
/// runs that failed before a plan existed have none, so the detail store would lag behind and keep
/// entries for rows the user can no longer see.
public struct TaskPlanDetailStore: @unchecked Sendable {
    /// The same number `TaskHistoryStore` caps at, referenced rather than repeated so the two
    /// cannot drift apart in a later edit.
    public static var maxDetails: Int { TaskHistoryStore.defaultMaxItems }

    public let fileURL: URL
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("task-plan-details.json")
        }
    }

    public func loadAll() throws -> [StoredTaskPlanDetail] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [StoredTaskPlanDetail].self,
            from: data,
            decoder: .taskPlanDetailISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "task plan details", write: write)
    }

    public func detail(forTaskID taskID: String) throws -> StoredTaskPlanDetail? {
        try loadAll().first { $0.taskID == taskID }
    }

    /// Insert or replace one task's plan, and in the same write drop the details of rows the history
    /// store just evicted.
    ///
    /// One write, not two: the eviction handoff costs nothing extra because this file is being
    /// rewritten anyway, and doing it here is what keeps this store's contents equal to the details
    /// of the rows that still exist.
    public func save(_ detail: StoredTaskPlanDetail, evictedTaskIDs: [String] = []) throws {
        let dropped = Set(evictedTaskIDs)
        var details = try loadAll().filter { !dropped.contains($0.taskID) }
        if let index = details.firstIndex(where: { $0.taskID == detail.taskID }) {
            details[index] = detail
        } else {
            details.append(detail)
        }
        try write(evicted(details))
    }

    /// Removes the details of these tasks, leaving every other entry exactly as it was.
    ///
    /// Deleting something already gone is a silent no-op that **does not rewrite the file**. That
    /// matters more here than for the sibling stores: this one holds the bytes, so a delete that
    /// re-encrypted it to change nothing would pay the largest write in the product for no effect.
    public func delete(ids: [String]) throws {
        let doomed = Set(ids)
        guard !doomed.isEmpty else {
            return
        }
        let details = try loadAll()
        let remaining = details.filter { !doomed.contains($0.taskID) }
        guard remaining.count != details.count else {
            return
        }
        try write(remaining)
    }

    public func delete(id: String) throws {
        try delete(ids: [id])
    }

    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    /// Oldest-first by `completedAt` — `TaskHistoryStore.capped(_:)`'s rule, on the same field, at
    /// the same number. A backstop rather than the primary mechanism: the eviction handoff in
    /// `save(_:evictedTaskIDs:)` normally keeps this store at or below the history store's count
    /// already.
    private func evicted(_ details: [StoredTaskPlanDetail]) -> [StoredTaskPlanDetail] {
        guard details.count > Self.maxDetails else {
            return details
        }
        return Array(details.sorted { $0.completedAt < $1.completedAt }.suffix(Self.maxDetails))
    }

    private func write(_ details: [StoredTaskPlanDetail]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(details, encoder: .taskPlanDetailPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

private extension JSONEncoder {
    static var taskPlanDetailPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var taskPlanDetailISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
