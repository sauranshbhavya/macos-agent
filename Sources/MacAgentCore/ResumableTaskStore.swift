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
    /// The file the last finished unit produced, if any — the value `executeChain` carries from one
    /// unit of a chain to the next and reports on `CompletedRunUnit`.
    ///
    /// Recorded because a resumed run starts in the middle of that carry. A chain's bare "reveal it
    /// in Finder" step has no path of its own and is filled in from whatever the previous unit
    /// wrote; dropping this would resume that step pointing at nothing.
    ///
    /// **Nothing here applies it, deliberately.** `remainingPlan()` returns the steps and no more;
    /// the caller hands this value to `AgentActionExecutor.execute(resumedArtifactPath:)`, which
    /// seeds its own carry with it and then applies its own rule. A second copy of that rule living
    /// here is the shape this repository consolidates away — the rule would then have two homes and
    /// only one of them would get changed.
    public var chainedArtifactPath: String?
    public var startedAt: Date
    /// The idle clock. Written on creation and on every unit boundary, and read by
    /// `ResumableTaskStore.loadAll(now:)` to drop a record nobody came back to.
    public var updatedAt: Date
    public var stopReason: ResumableTaskStopReason
    /// When the user told the widget to stop offering this task, or `nil` while they have not
    /// (SONNY-282, founder decision 2026-08-25).
    ///
    /// **A declined flag rather than a deletion, and the difference is the whole decision.** The
    /// widget's cross used to mean "not now": the offer came back at the next launch, and the next,
    /// until the task was resumed or deleted from Command Center — the founder pressed it three
    /// times across three relaunches expecting an effect it never had. Deleting on the cross was
    /// considered and rejected, so that no control in the widget can lose work irreversibly. So the
    /// cross now writes this, the offer filters on it, and the record itself is untouched: still
    /// listed under Memory's Unfinished tasks, still deletable there, and still resumable from there.
    ///
    /// **It does not touch `updatedAt`, deliberately.** Declining is "stop asking me", not activity
    /// on the task; bumping the idle clock would give a declined task a fresh fortnight and move it to
    /// the top of the Memory list, when the founder's lifecycle — completes, deleted, or goes idle —
    /// is exactly what should still end it.
    ///
    /// A date rather than a flag for the same reason the record's other lifecycle facts are dates:
    /// it answers "when" as well as "whether" at no extra cost, and a file written before this field
    /// existed decodes as never declined.
    public var declinedAt: Date?
    /// The items of a job over many items that this run tried and could not do (SONNY-235). Empty
    /// for every record that is not a job, and for a job in which nothing has failed.
    ///
    /// **The one thing about a job's progress that is stored rather than derived.** Which items
    /// finished is already `completedStepIDs` read through the plan's own `AgentStep.itemIndex` —
    /// see `ItemJobProgress` — so recording it here as well would be two homes for one fact.
    /// A failed item is indistinguishable from an item that never ran by that route: neither has
    /// completed steps. So the failures are written, and the completions are computed.
    ///
    /// **A resume starts this empty rather than carrying it forward.** A failed item's steps are
    /// still in `remainingPlan()`, so Continue re-attempts it — which is what Continue means for a
    /// job that is not finished — and a failure carried across that retry would describe an attempt
    /// that has been replaced.
    public var itemJobFailures: [ItemJobFailure]

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
        stopReason: ResumableTaskStopReason = .interrupted,
        declinedAt: Date? = nil,
        itemJobFailures: [ItemJobFailure] = []
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
        self.declinedAt = declinedAt
        self.itemJobFailures = itemJobFailures
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
        case declinedAt
        case itemJobFailures
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
            stopReason: try container.decode(ResumableTaskStopReason.self, forKey: .stopReason),
            // `decodeIfPresent`, so every record written before SONNY-282 reads as never declined
            // rather than failing to decode — which would take the whole file, and every other
            // unfinished task in it, down with it.
            declinedAt: try container.decodeIfPresent(Date.self, forKey: .declinedAt),
            // `decodeIfPresent` for `declinedAt`'s reason: a record written before SONNY-235 reads
            // as a job that has failed nothing rather than failing to decode, which would take the
            // whole file and every other unfinished task in it down with it.
            itemJobFailures: try container.decodeIfPresent([ItemJobFailure].self, forKey: .itemJobFailures) ?? []
        )
    }

    /// Whether the user has told the widget to stop offering this task. The offer reads this; the
    /// Memory list and `mayBeOfferedForResume` deliberately do not — see `declinedAt`.
    public var isDeclined: Bool { declinedAt != nil }

    /// How far this job over many items got, or `nil` when this record is not one (SONNY-235).
    /// Everything it reports is computed from this record's own plan, its completed step ids and its
    /// failures — see `ItemJobProgress`.
    public var itemJobProgress: ItemJobProgress? {
        ItemJobProgress.of(plan: plan, completedStepIDs: completedStepIDs, failures: itemJobFailures)
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

    /// Whether Sonny may offer to carry this on **by itself** (PR #105 review F5).
    ///
    /// **The record is written and listed either way; only the offer is withheld.** Resuming re-runs
    /// the unit that was in flight, because nothing can know how far into an adapter call the power
    /// went — so a remainder containing something that must not happen twice is a remainder Sonny
    /// does not volunteer. The user can still ask for the task again in their own words, which is a
    /// fresh run through the ordinary gate rather than a repeat of a half-done one, and the record
    /// stays visible and deletable under Memory.
    ///
    /// **Conservative on purpose, and it withholds more than strictly necessary.** Only the *first*
    /// remaining unit can repeat; a later one never ran at all. This asks the question of every
    /// remaining step instead, because unit boundaries are the executor's to compute and a rule that
    /// re-derived them here would be a second copy of `chainSegments`. The cost is that a plan whose
    /// remaining work contains a Shortcut is never offered even when the Shortcut is not the part
    /// that would repeat; the benefit is that the answer cannot be wrong in the direction that
    /// double-sends. Stated so nobody widens it by accident.
    ///
    /// **`isDeclined` is deliberately not a term here** (SONNY-282). This is the *safety* rule — what
    /// Sonny may do on its own — and it gates both the widget's offer and every Continue, including
    /// the one under Memory. A decline is the user's *preference* about the widget's offer alone, so
    /// it is a second filter on that offer and on nothing else: a declined task is one the user can
    /// still choose to continue from Memory, which is the founder's whole reason for keeping it.
    public var mayBeOfferedForResume: Bool {
        isResumable && remainingSteps.allSatisfy { $0.operation.resumeRepeatSafety == .safeToRepeat }
    }

    /// The remaining steps Sonny will not repeat on its own, in plan order — empty exactly when
    /// `mayBeOfferedForResume` is true for a resumable record. Exists so a caller can say *which*
    /// step withheld the offer rather than only that something did.
    public var stepsThatMustNotRepeatSilently: [AgentStep] {
        remainingSteps.filter { $0.operation.resumeRepeatSafety == .mustNotRepeatSilently }
    }

    /// What a resume actually executes: the same plan with the finished steps removed.
    ///
    /// **The summary is kept verbatim.** It describes the task the user asked for, which is what the
    /// offer names and what the history row for the resumed run should say; rewriting it here would
    /// invent a sentence no planner wrote.
    ///
    /// The remaining steps begin at a unit boundary by construction — only whole units are ever
    /// recorded as complete — so re-segmenting the remainder produces exactly the units that had not
    /// run. `theRemainderOfAPlanSegmentsIntoTheUnitsThatHadNotRun` pins that.
    ///
    /// **`itemJob` is carried, and dropping it was this branch's own blocking defect** (PR #185, F1).
    /// This is the one door in the tree that reassembles an expanded plan, and rebuilding it from
    /// three fields let the fourth default to `nil` — so the remainder kept every step's `itemIndex`
    /// and stopped being a job. Everything that makes a job a job was then absent on the second
    /// attempt and silent about it: an unpreviewable item killed the whole resumed run at `prepare`
    /// again, skip-and-continue was gone, no progress line appeared on either surface, the widget drew
    /// one row per remaining item in the approval prompt, and a second interruption wrote a record
    /// that had forgotten it was ever a job.
    ///
    /// **What is carried is the declaration and the whole item list, not a recomputed one**, so a
    /// failure's `itemIndex` still points at the same item it always did. What must *not* be taken
    /// from the whole list is the job's **size**: `ItemJobProgress` and `AgentActionExecutor`'s job
    /// summary both count the items this plan is responsible for — the ones with steps, plus the ones
    /// recorded unavailable — so a resume that does the last two of forty says "2 of 2" rather than
    /// claiming it worked through all forty. That was the trap in the obvious one-line fix.
    public func remainingPlan() -> AgentPlan {
        AgentPlan(
            summary: plan.summary,
            requiresConfirmation: plan.requiresConfirmation,
            steps: remainingSteps,
            // **The declaration and the whole item list, with the earlier attempt's unavailable items
            // cleared** — the same rule, and the same reason, as `itemJobFailures` starting empty on a
            // resume. Those items were reported by the run that met them; carrying them would make the
            // remainder report a failure it never experienced and count itself larger than it is.
            itemJob: plan.itemJob.map { job in
                var carried = job
                carried.unavailableItems = []
                return carried
            }
        )
    }

    /// The file the last finished unit produced, offered to a resume **only when it cannot cross an
    /// item boundary** (PR #185, F2(b) and the review's third door on R4).
    ///
    /// `AgentViewModel`'s Continue bakes this onto the remainder's leading step through
    /// `ChainedArtifactCarry.applying`, which is a cross-item carry that no in-loop reset can undo —
    /// the value is in the plan before `executeChain` ever runs. For an ordinary plan that is exactly
    /// right and is unchanged. For a job it is right only when the unit that produced the file and the
    /// step about to consume it belong to the same item; otherwise item N+1 would open item N's file
    /// and the run would report success.
    ///
    /// Answered from this record's own two fields rather than by storing a third: the last completed
    /// step names its item, the first remaining step names its own, and a carry between different
    /// items is withheld. A job whose remainder starts a fresh item simply begins with nothing
    /// carried, which is what `executeChain`'s own item-boundary reset would have done had the value
    /// not arrived pre-applied.
    public var chainedArtifactPathForRemainder: String? {
        guard plan.itemJob != nil else {
            return chainedArtifactPath
        }
        let done = Set(completedStepIDs)
        let lastCompletedItem = plan.steps.last { done.contains($0.id) }?.itemIndex
        let nextItem = remainingSteps.first?.itemIndex
        guard lastCompletedItem == nextItem else {
            return nil
        }
        return chainedArtifactPath
    }

    private static func cappedCommand(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCommandCharacters else {
            return trimmed
        }
        return String(trimmed.prefix(maxCommandCharacters - 1)) + "\u{2026}"
    }
}

/// The collections `resumable-tasks.json` holds, and what Settings' wipe sentence calls each of
/// them.
///
/// **This exists because one derivation is not reachable and the gap it leaves is a data-loss
/// disclosure** (SONNY-236). The wipe's sentence is built from `LocalStore.allCases`, and a second
/// collection inside an existing store's file adds no case there — so watchers would be deleted by a
/// press whose own sentence never named them, which is exactly the defect
/// `theWipesOwnSentenceNamesEveryStoreItDeletes` was written to make impossible for a *store*.
/// Nothing in the type system connects "this file gained a stored property" to "the sentence gained
/// a phrase", so this enum is the declaration that stands in for it, and
/// `theWipesOwnSentenceNamesEveryCollectionInEveryStore` binds the two by counting
/// `ResumableTaskFile`'s stored properties against these cases: a third collection makes the counts
/// disagree and fails there rather than arriving unnamed.
///
/// **The count assertion is the load-bearing half, not the switch.** An exhaustive switch only
/// guarantees that every *case* has a name; it says nothing about a stored property that never
/// became a case, which is the direction this actually has to cover. `ProductShellTests`' stored-
/// property classifier is the same trick against the same blindness.
enum ResumableTaskFileCollection: CaseIterable {
    case tasks
    case watchers

    /// Lower case and standing alone, the rule `LocalStore.deletionCopyNames` states: each of these
    /// lands mid-list in a sentence naming fourteen things.
    var wipeCopyName: String {
        switch self {
        case .tasks:
            return "unfinished tasks"
        case .watchers:
            // "watchers", not "standing watchers": the neighbouring items in that sentence are bare
            // plurals of the product's own nouns — routines, workspaces, snippets — and "standing"
            // is the ticket's word for the shape rather than the user's word for the thing.
            return "watchers"
        }
    }
}

/// What `resumable-tasks.json` holds: unfinished runs, and standing watchers beside them.
///
/// **Two collections in one file, because this store stays the thirteenth.** SONNY-210 built it,
/// SONNY-235 extends the task record and SONNY-236 adds watchers, and none of the three adds a
/// fourteenth `LocalStore` — a new file would need a case there, a URL in the wipe, a line in the
/// wipe's sentence, a Memory classification and the rest of the six-things-a-store-is list. The two
/// collections are siblings rather than one generalised record: a watcher has no plan, no steps and
/// nothing to resume, so folding it into `ResumableTask` would leave every reader of that type
/// needing a filter (see `StandingWatcher`'s own note).
///
/// **The file used to be a bare JSON array of tasks, and files written that way still decode.** The
/// legacy shape is recognised by its *shape* — a top-level array — and read as tasks with no
/// watchers. Nothing forces a rewrite on load: the store's expire-on-read, drop-on-write rule is
/// there because load is the path that has to stay cheap, and the container is produced by the next
/// write that happens for its own reasons. So a user who never starts a watcher and never
/// checkpoints a run keeps an array on disk forever, and that is correct rather than a migration
/// that has not run.
struct ResumableTaskFile: Codable, Equatable, Sendable {
    var tasks: [ResumableTask]
    var watchers: [StandingWatcher]

    init(tasks: [ResumableTask], watchers: [StandingWatcher]) {
        self.tasks = tasks
        self.watchers = watchers
    }

    private enum CodingKeys: String, CodingKey {
        case tasks
        case watchers
    }

    init(from decoder: Decoder) throws {
        // **Shape first, not try-and-fall-back.** Deciding by catching a keyed decode's failure
        // would make every genuine error inside the container — a corrupt watcher, a plan that will
        // not decode — look like a legacy file, and the fallback would then fail with a message
        // about the wrong shape entirely. `unkeyedContainer()` succeeds only when the top level
        // really is an array, so this asks the one question that separates the two formats and
        // lets every other failure propagate as itself.
        if var array = try? decoder.unkeyedContainer() {
            var decoded: [ResumableTask] = []
            while !array.isAtEnd {
                decoded.append(try array.decode(ResumableTask.self))
            }
            self.init(tasks: decoded, watchers: [])
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tasks: try container.decode([ResumableTask].self, forKey: .tasks),
            // `decodeIfPresent`, so a container written before watchers existed reads as none rather
            // than failing — which would take every unfinished task in the file down with it.
            watchers: try container.decodeIfPresent([StandingWatcher].self, forKey: .watchers) ?? []
        )
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
    /// The standing-watcher cap. Injectable for tests exactly as `idleExpiry` and `maxTasks` are,
    /// and for the same reason: reaching `maxActive` otherwise means creating the shipped number of
    /// real watchers. `noProductionPathBuildsItsOwnStandingWatcherLimits` pins that nothing in `Sources/`
    /// passes anything but `.standard`.
    public let limits: StandingWatcherLimits
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
        fileURL: URL,
        fileManager: FileManager = .default,
        encryption: LocalStorageEncryption = .shared,
        idleExpiry: TimeInterval = ResumableTaskStore.defaultIdleExpiry,
        maxTasks: Int = ResumableTaskStore.defaultMaxTasks,
        limits: StandingWatcherLimits = .standard
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encryption = encryption
        self.idleExpiry = max(1, idleExpiry)
        self.maxTasks = max(1, maxTasks)
        // Already floored by `StandingWatcherLimits.init`, so nothing is re-floored here — a second
        // copy of that rule is the shape this repository consolidates away.
        self.limits = limits
    }

    /// Where the shipping app keeps this store.
    ///
    /// The rule that makes this a named call rather than an initializer default is on
    /// `ClipboardHistoryStore.defaultDirectory` (SONNY-350).
    public static func realFileURL(fileManager: FileManager = .default) -> URL {
        ClipboardHistoryStore.defaultDirectory(fileManager: fileManager)
            .appendingPathComponent("resumable-tasks.json")
    }

    /// Every unfinished task that has not gone idle, newest activity first.
    ///
    /// The order is the offer's order: the thing the user was doing most recently is the thing to
    /// raise first.
    public func loadAll(now: Date = Date()) throws -> [ResumableTask] {
        try loadFile()
            .tasks
            .filter { !hasGoneIdle($0, now: now) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every standing watcher, oldest first.
    ///
    /// **Nothing is filtered out here, unlike `loadAll`.** A task that has gone idle is dropped
    /// silently because nobody is waiting to be told about it; a watcher whose lifetime has run out
    /// is the opposite — its expiry is a thing the user is owed a sentence about
    /// (`StandingWatcherStopReason.expired`), so it has to reach the checker rather than vanish on
    /// the read that would have found it. Retiring an expired watcher is the checker's job and it
    /// notifies while doing it.
    ///
    /// Oldest first, which is check order: the watcher that has been waiting longest is looked at
    /// first when a pulse can only get through some of them.
    public func loadWatchers() throws -> [StandingWatcher] {
        try loadFile().watchers.sorted { $0.createdAt < $1.createdAt }
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

        let file = try loadFile()
        var tasks = file.tasks.filter { !hasGoneIdle($0, now: now) }
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        // `file.watchers` carried through untouched. A task write that dropped the watchers sharing
        // this file would end every standing watcher the moment any run checkpointed, which is
        // silent in both directions — nothing fails, and the user is simply never told again.
        try write(ResumableTaskFile(tasks: capped(tasks), watchers: file.watchers))
    }

    /// Forgets one unfinished task.
    ///
    /// Deleting something already gone is a silent no-op that does not rewrite the file — the same
    /// rule `TaskPlanDetailStore.delete(ids:)` follows, and it matters on the hottest path this
    /// store has: every run that finishes cleanly settles a record that a suppressed or
    /// memory-disabled run never wrote, and re-encrypting the file to change nothing on each of
    /// those would be a write per task for no effect.
    /// `now` is explicit here for the same reason it is on `save` and `loadAll`, and it is not
    /// decorative: this reads through `loadAll`, so the idle period decides what it can see. A record
    /// already past that period is invisible to this call and is therefore *not* rewritten out — it
    /// is already gone as far as every reader is concerned, and it leaves the file on the next write
    /// that touches it, which is the same expire-on-read, drop-on-write rule the store states above.
    public func delete(id: String, now: Date = Date()) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let file = try loadFile()
        let tasks = file.tasks.filter { !hasGoneIdle($0, now: now) }
        let remaining = tasks.filter { $0.id != id }
        guard remaining.count != tasks.count else {
            return
        }
        try write(ResumableTaskFile(tasks: remaining, watchers: file.watchers))
    }

    /// **Every unfinished task, and nothing else in this file.**
    ///
    /// This is what Command Center's Memory row presses (SONNY-236, founder decision 2026-08-31),
    /// and it exists because that row is labelled *Unfinished tasks* while the file underneath it
    /// also holds standing watchers. The row used to delete through
    /// `LocalDataDeletionService.deleteStoreFilesOnly()`, which unlinks the file — correct while the
    /// file held one kind of thing, and a mislabelled delete the moment it held two. A user pressing
    /// Delete on a row named for unfinished tasks has no reason to expect their watchers to be in
    /// scope, and CLAUDE.md's account of PR #110's F2 is that calling the wrong deletion door is
    /// silent in every direction.
    ///
    /// **Rewrites rather than unlinks**, which is the whole difference from `deleteAll()` below, and
    /// the reason the two are named apart rather than sharing one door with a flag: a caller that
    /// picks the wrong one loses data it promised to keep, so the choice should be visible in the
    /// call.
    public func deleteAllTasks() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let file = try loadFile()
        guard !file.tasks.isEmpty else {
            // Nothing to remove, so nothing is rewritten. The same no-op rule `delete(id:)` follows,
            // and here it also means a press on an empty row cannot re-encrypt the watchers for no
            // reason.
            return
        }
        try write(ResumableTaskFile(tasks: [], watchers: file.watchers))
    }

    /// **The whole file: every unfinished task and every standing watcher.**
    ///
    /// Not the Memory row's door — that is `deleteAllTasks()` above, and the distinction is
    /// load-bearing. This is the file-level delete, and what reaches it is
    /// `LocalDataDeletionService` doing Settings' whole wipe, which is the one control that says it
    /// takes everything.
    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }

    /// Inserts or replaces one standing watcher.
    ///
    /// **The cap is enforced here, and it refuses rather than evicts** (`StandingWatcherLimits.maxActive`).
    /// Every other cap in this repository's stores drops the oldest record — `capped(_:)` directly
    /// below does exactly that for tasks — and that is right for a record nobody asked for, which is
    /// what an unfinished-task checkpoint is. A watcher is the opposite: the user said the sentence
    /// that created it, so silently ending one to make room for another is losing something they
    /// asked for, with no notification and no trace. Refusing is a sentence Sonny can say instead.
    ///
    /// **Only an insert is capped.** An update is how a check records its own result, so refusing one
    /// at the cap would freeze every watcher's state the moment the fifth was created — and the
    /// record that then failed to save is the one carrying the reading that would have fired.
    public func saveWatcher(_ watcher: StandingWatcher) throws {
        let file = try loadFile()
        var watchers = file.watchers
        if let index = watchers.firstIndex(where: { $0.id == watcher.id }) {
            watchers[index] = watcher
        } else {
            guard watchers.count < limits.maxActive else {
                throw StandingWatcherStoreError.tooManyWatchers(limit: limits.maxActive)
            }
            watchers.append(watcher)
        }
        try write(ResumableTaskFile(tasks: file.tasks, watchers: watchers))
    }

    /// Forgets one standing watcher — what the user's Stop press does, and what the checker does to a
    /// watcher that has finished.
    ///
    /// Deleting something already gone is a silent no-op that does not rewrite the file, the rule
    /// every other delete in this store follows.
    public func deleteWatcher(id: String) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        let file = try loadFile()
        let remaining = file.watchers.filter { $0.id != id }
        guard remaining.count != file.watchers.count else {
            return
        }
        try write(ResumableTaskFile(tasks: file.tasks, watchers: remaining))
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

    /// The file as it is on disk, both collections, before any expiry or ordering rule is applied.
    ///
    /// One reader for both collections rather than two, so a task write and a watcher write cannot
    /// come to different conclusions about what the file currently holds.
    private func loadFile() throws -> ResumableTaskFile {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ResumableTaskFile(tasks: [], watchers: [])
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try encryption.decode(
            ResumableTaskFile.self,
            from: data,
            decoder: .resumableTaskISO8601
        )
        return decoded.migratingLegacyPlaintext(store: "unfinished tasks", write: write)
    }

    private func write(_ file: ResumableTaskFile) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encryption.encode(file, encoder: .resumableTaskPrettySorted)
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

/// The one failure the watcher half of this store has that is not a file-system or encryption
/// failure.
///
/// Its own type rather than a case on `ResumableTaskStoreError`, because the two are read by
/// different callers about different things and only one of them is a task: a caller catching "this
/// plan is too big to resume" has no sensible branch for "you already have five watchers".
public enum StandingWatcherStoreError: Error, Equatable, LocalizedError {
    case tooManyWatchers(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyWatchers(let limit):
            // Says what to do, because there is something to do. The cap is deliberately small
            // enough that a person can name what their five watchers are for, so "stop one" is a
            // real instruction rather than the product refusing and leaving them there.
            return "Sonny is already watching \(limit) things, which is the most it will watch at once. Stop one of them and ask again."
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
