import Foundation

/// Why a run stopped without finishing.
///
/// Two cases rather than one because they are arrived at by opposite mechanisms, and only one of
/// them is ever *written*. `.failed` is stamped by the terminal that saw the error. `.interrupted`
/// is the value a record is created with and keeps when nothing ever settles it — the laptop
/// closing, a quit, a crash — so it is the honest description of "the app stopped and this run was
/// still live", which no code path is present to record at the time.
public enum ResumableTaskStopReason: String, Codable, Equatable, Sendable {
    /// Nothing settled this run. It was live when the app stopped being able to run it.
    case interrupted
    /// The run ended in an error. Its completed steps are still completed.
    case failed
}

/// One run that began and did not finish, kept so Sonny can offer to carry on with what is left.
///
/// **This is not `PriorTaskContext`, and §6.10's own note is why the two exist separately.** Row E's
/// context is the ten-minute, in-memory, single-slot thing that lets "use ~/Downloads instead"
/// correct the task that just *finished*. This is a durable record of a task that did *not* finish,
/// it survives relaunches, there can be several, and nothing here is ever handed to a planner. They
/// are not merged, this does not reuse that expiry, and the resume path below re-executes a plan
/// rather than re-planning from a sentence.
///
/// **What "the step it reached" means, stated exactly, because the executor's granularity is not the
/// plan's.** `AgentActionExecutor` dispatches a plan as *units* — maximal runs of consecutive steps
/// belonging to one workflow (`chainSegments(in:)`) — and one unit is one adapter call that may
/// service several steps together. So the finest boundary at which "this is done" is a fact rather
/// than a guess is the end of a unit, and `completedStepIDs` holds exactly the steps of units that
/// returned. A plan of one unit therefore has no partial state to record and resuming it re-runs it
/// whole; that is not a gap in this type, it is what the plan's own shape means.
///
/// **A unit that was in flight when the interruption landed is re-run, deliberately.** Nothing can
/// know how far into an adapter call the power went, so the safe direction is to treat an unfinished
/// unit as not done. The cost is bounded — at most one unit repeats — and a repeat goes through the
/// same risk assessment and the same approval gate any other run does, because resuming dispatches
/// the remaining plan through the ordinary path rather than around it.
///
/// **SONNY-235 and SONNY-236 extend this record; neither adds a fourteenth store.** A job that
/// remembers its place through a list of items needs a notion of progress this type does not carry
/// (a plan is a sequence of steps, not an iteration), and a standing watcher needs a waking
/// condition; both are additions to this record and this store, and the split is recorded on
/// SONNY-210's founder comment of 2026-08-22.
public struct ResumableTask: Codable, Equatable, Sendable, Identifiable {
    /// This record's own identity, minted when the run is first checkpointed.
    ///
    /// Its own id rather than the task-history row's, and the reason is a lifetime rather than a
    /// preference: a history row is written when a run *terminates*, and this record exists
    /// precisely while one has not. There is no row to key on at the moment this is created, and for
    /// an interrupted run there never will be one.
    public var id: String
    /// What the user asked for, as the offer names it back to them. A label — nothing re-plans from
    /// it, and `remainingPlan()` below is what actually runs.
    public var command: String
    /// The whole plan as it was prepared, steps included.
    ///
    /// **Stored whole and never truncated**, unlike `StoredTaskPlanDetail`, whose text budget is safe
    /// because that store feeds a planner's context. This one feeds an *executor*: a plan cut to fit
    /// a budget would run a different task from the one the user started, so the size rule is a
    /// refusal rather than a trim — see `ResumableTaskStore.maxEncodedPlanBytes`.
    public var plan: AgentPlan
    /// The ids of steps belonging to units that finished. A subset of `plan.steps`' ids, in plan
    /// order.
    public var completedStepIDs: [String]
    /// The file the last finished unit produced, if any — the value
    /// `AgentActionExecutor.chainedArtifactPath(after:)` carries from one unit of a chain to the
    /// next.
    ///
    /// Recorded because a resumed run starts in the middle of that carry. A chain's bare "reveal it
    /// in Finder" step has no path of its own and is filled in from whatever the previous unit
    /// wrote; dropping this would resume that step pointing at nothing. `remainingPlan()` applies it
    /// through the executor's own rule rather than a second copy of it.
    public var chainedArtifactPath: String?
    public var startedAt: Date
    /// The idle clock. Written on creation and on every unit boundary, and read by
    /// `ResumableTaskStore.loadAll(now:)` to drop a record nobody came back to.
    public var updatedAt: Date
    public var stopReason: ResumableTaskStopReason

    /// The longest `command` this keeps, in characters. Display-only text, so trimming it is safe in
    /// the way trimming the plan is not.
    public static let maxCommandCharacters = 400

    public init(
        id: String = UUID().uuidString,
        command: String,
        plan: AgentPlan,
        completedStepIDs: [String] = [],
        chainedArtifactPath: String? = nil,
        startedAt: Date,
        updatedAt: Date,
        stopReason: ResumableTaskStopReason = .interrupted
    ) {
        self.id = id
        self.command = Self.cappedCommand(command)
        self.plan = plan
        // Filtered against the plan rather than stored as handed in: an id naming no step would
        // subtract nothing from `remainingSteps` while making the record read as further along than
        // it is, and a decoded record has to obey the same rule a written one does.
        let known = Set(plan.steps.map(\.id))
        self.completedStepIDs = completedStepIDs.filter { known.contains($0) }
        self.chainedArtifactPath = chainedArtifactPath
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.stopReason = stopReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case plan
        case completedStepIDs
        case chainedArtifactPath
        case startedAt
        case updatedAt
        case stopReason
    }

    /// Written out rather than synthesized so a decoded record runs through the same command cap and
    /// the same completed-id filter a written one does. `StoredTaskPlanDetail` states the reason
    /// this shape exists: a rule the decode path skips is a rule that holds in one direction only.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            command: try container.decode(String.self, forKey: .command),
            plan: try container.decode(AgentPlan.self, forKey: .plan),
            completedStepIDs: try container.decode([String].self, forKey: .completedStepIDs),
            chainedArtifactPath: try container.decodeIfPresent(String.self, forKey: .chainedArtifactPath),
            startedAt: try container.decode(Date.self, forKey: .startedAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            stopReason: try container.decode(ResumableTaskStopReason.self, forKey: .stopReason)
        )
    }

    /// The steps this run has not finished, in plan order.
    public var remainingSteps: [AgentStep] {
        let done = Set(completedStepIDs)
        return plan.steps.filter { !done.contains($0.id) }
    }

    /// Whether there is anything left to carry on with.
    ///
    /// False for a plan whose every step is accounted for — which a settled record never is, since
    /// a run that got through its last unit completed and had its record deleted. It is reachable
    /// through a hand-written record, and an offer to continue nothing is worse than no offer.
    public var isResumable: Bool { !remainingSteps.isEmpty }

    /// What a resume actually executes: the same plan with the finished steps removed.
    ///
    /// **The summary is kept verbatim.** It describes the task the user asked for, which is what the
    /// offer names and what the history row for the resumed run should say; rewriting it here would
    /// invent a sentence no planner wrote.
    ///
    /// The remaining steps begin at a unit boundary by construction — only whole units are ever
    /// recorded as complete — so re-segmenting the remainder produces exactly the units that had not
    /// run. `theRemainderOfAPlanSegmentsIntoTheUnitsThatHadNotRun` pins that.
    public func remainingPlan() -> AgentPlan {
        AgentPlan(
            summary: plan.summary,
            requiresConfirmation: plan.requiresConfirmation,
            steps: remainingSteps
        )
    }

    private static func cappedCommand(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCommandCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maxCommandCharacters - 1)) + "\u{2026}"
    }
}

/// The **thirteenth** local store, on the shared pattern exactly: runs that began and did not finish.
///
/// **Lifecycle, as the founder decided it on 2026-08-22:** a record lives until its task completes
/// or the user deletes it, *and* expires after a stretch with no activity. The third condition was
/// chosen over the ticket's original done-or-deleted because a task abandoned months ago is not one
/// anyone returns to, and over a hard count cap because a cap silently drops something the user did
/// mean to come back to. The count cap below is therefore a safety rail against unbounded growth
/// rather than the lifecycle rule; the idle period is.
///
/// **The idle period is 14 days, and it is one named constant so it is one edit to change.** The
/// reasoning, since the founder left the number to the implementer: the period has to be long enough
/// that a genuine intention to come back survives it — a fortnight covers a working week plus a week
/// away, which is the longest ordinary gap between being interrupted and returning. It also has to
/// be short enough that resuming is still safe to offer: a resumed plan re-executes against the file
/// system and the web as they are *now*, and the older the plan, the more likely its world has moved
/// under it. Two weeks is the point where those two pressures meet. The two neighbouring anchors
/// this repository already has bracket it from both sides — `PriorTaskContext` expires in ten
/// minutes, and `ClipboardHistoryStore` ages entries out after seven days.
///
/// **Expiry is applied on read, and dropped from disk on the next write.** A record past its idle
/// period is invisible to every reader the moment it expires, which is the property that matters;
/// physically removing it needs a write, and a store that rewrote itself on load would pay the
/// largest cost it has on the path that must be cheapest. `ClipboardHistoryStore.capped(_:now:)`
/// makes the same trade for the same reason.
public struct ResumableTaskStore: @unchecked Sendable {
    /// How long a record survives with nothing happening to it. Fourteen days — the reasoning is on
    /// the type above, and this is the one place the number lives.
    public static let defaultIdleExpiry: TimeInterval = 14 * 24 * 60 * 60

    /// The safety rail. Not the lifecycle — see the type's doc comment for why a cap is explicitly
    /// *not* how a record ends.
    ///
    /// Twenty is far above anything reachable in ordinary use: only one run is ever in flight
    /// (`checkScheduledRoutines` and `canSubmit` both refuse a second), so a record is added at most
    /// once per task and removed again the moment that task finishes. Reaching twenty means twenty
    /// separate tasks were each abandoned unfinished inside one idle period.
    public static let defaultMaxTasks = 20

    /// The largest plan this will store, encoded, in bytes.
    ///
    /// **A refusal rather than a trim, and that is the whole point.** Every other store in this
    /// repository caps by truncating text, which is safe because the text is read back to be
    /// *shown* or *summarised*. This plan is read back to be **executed**: a plan cut to fit would
    /// run a different task from the one the user started, silently and with the user's approval
    /// attached to it. So an oversized plan produces no record at all and no offer — the run simply
    /// is not resumable, which is a smaller loss than resuming something else.
    ///
    /// 64 KiB is roughly forty times a real plan. SONNY-119 measured eight steps at about 1.7 kB
    /// encoded (at `36cef9e`), and the plans this product produces are two to four steps; the
    /// headroom is for `draftContent`, the one field whose size the user's own command decides.
    public static let maxEncodedPlanBytes = 64 * 1024

    public let fileURL: URL
    public let idleExpiry: TimeInterval
    public let maxTasks: Int
    private let fileManager: FileManager
    private let encryption: LocalStorageEncryption

    /// `idleExpiry` and `maxTasks` are injectable for the reason `TaskPlanDetailStore.maxDetails`
    /// is: so a test can reach the expiry and the cap without waiting a fortnight or writing
    /// twenty-one records. Neither is a way to change the shipped values, which are the two static
    /// constants above; `noProductionPathPassesAnIdleExpiryOrCapToTheResumableStore` pins that
    /// nothing in `Sources/` passes either.
    ///
    /// Floored at 1 for `maxTasks`, like its siblings: a store built with 0 would evict everything
    /// on the next write, which is silent data loss rather than a small cap. `idleExpiry` is floored
    /// above zero for the same shape of reason — a zero expiry would make every record vanish on the
    /// read that follows its own write, which is not a short lifetime but a broken store.
    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared,
        idleExpiry: TimeInterval = ResumableTaskStore.defaultIdleExpiry,
        maxTasks: Int = ResumableTaskStore.defaultMaxTasks
    ) {
        self.fileManager = fileManager
        self.encryption = encryption
        self.idleExpiry = max(1, idleExpiry)
        self.maxTasks = max(1, maxTasks)
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
                .appendingPathComponent("resumable-tasks.json")
        }
    }

    /// Every unfinished task that has not gone idle, newest activity first.
    ///
    /// The order is the offer's order: the thing the user was doing most recently is the thing to
    /// raise first.
    public func loadAll(now: Date = Date()) throws -> [ResumableTask] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            [ResumableTask].self,
            from: data,
            decoder: .resumableTaskISO8601
        )
        return decoded
            .migratingLegacyPlaintext(store: "unfinished tasks", write: write)
            .filter { !hasGoneIdle($0, now: now) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Inserts or replaces one record, dropping anything that has gone idle in the same write.
    ///
    /// Throws `ResumableTaskStoreError.planTooLarge` rather than storing a plan above
    /// `maxEncodedPlanBytes` — see that constant for why an oversized plan is refused instead of
    /// trimmed. The caller reports it as a write failure and the run continues; what is lost is the
    /// offer, not the task.
    public func save(_ task: ResumableTask, now: Date = Date()) throws {
        let encodedPlan = try JSONEncoder.resumableTaskPrettySorted.encode(task.plan)
        guard encodedPlan.count <= Self.maxEncodedPlanBytes else {
            throw ResumableTaskStoreError.planTooLarge(bytes: encodedPlan.count, limit: Self.maxEncodedPlanBytes)
        }

        var tasks = try loadAll(now: now)
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        try write(capped(tasks))
    }

    /// Forgets one unfinished task.
    ///
    /// Deleting something already gone is a silent no-op that does not rewrite the file — the same
    /// rule `TaskPlanDetailStore.delete(ids:)` follows, and it matters on the hottest path this
    /// store has: every run that finishes cleanly settles a record that a suppressed or
    /// memory-disabled run never wrote, and re-encrypting the file to change nothing on each of
    /// those would be a write per task for no effect.
    public func delete(id: String) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let tasks = try loadAll()
        let remaining = tasks.filter { $0.id != id }
        guard remaining.count != tasks.count else {
            return
        }
        try write(remaining)
    }

    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func hasGoneIdle(_ task: ResumableTask, now: Date) -> Bool {
        now.timeIntervalSince(task.updatedAt) > idleExpiry
    }

    /// Oldest activity first out, matching `loadAll`'s ordering rule from the other end.
    private func capped(_ tasks: [ResumableTask]) -> [ResumableTask] {
        guard tasks.count > maxTasks else {
            return tasks
        }
        return Array(tasks.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxTasks))
    }

    private func write(_ tasks: [ResumableTask]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(tasks, encoder: .resumableTaskPrettySorted)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// The one failure this store has that is not a file-system or encryption failure.
public enum ResumableTaskStoreError: Error, Equatable, LocalizedError {
    case planTooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .planTooLarge(let bytes, let limit):
            return "This task's plan is \(bytes) bytes, over the \(limit)-byte limit for resuming, so Sonny did not keep it."
        }
    }
}

private extension JSONEncoder {
    static var resumableTaskPrettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var resumableTaskISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
