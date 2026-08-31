import Foundation

/// **How a plan says "for each of these" — the decision SONNY-235 turns on.**
///
/// A job over many items is declared **once, on the plan**, and is resolved into ordinary steps
/// before anything else in the system sees it. `AgentActionExecutor.prepare` reads this declaration,
/// resolves it into a concrete, ordered list of items, and expands the plan's steps into one copy
/// per item (`PlanItemJobExpansion`). Everything downstream — `preview`, `assessRisk`, the approval
/// gate, `chainSegments`, unit dispatch, and SONNY-210's `completedStepIDs` record — receives a plan
/// of ordinary steps and learns nothing at all about iteration. **No capability adapter changes, and
/// none can be made to change by adding a new kind of job.**
///
/// **The two alternatives the ticket names, and why each was rejected.**
///
/// *A new step operation* (`for_each`, carrying a nested plan) was rejected on the resume granularity
/// it destroys. The executor's finest "this is done" boundary is a **unit** — one adapter call — and a
/// `for_each` step is one unit however many items it walks, so `completedStepIDs` could express
/// nothing about item 17 of 40 and the whole point of this ticket would need a second, parallel
/// progress mechanism threaded into one privileged adapter. It also needs an adapter that can run
/// arbitrary work, which is `AgentActionExecutor.execute` under another name.
///
/// *A property of an existing step* (`AgentStep.items`) was rejected on exactly the cost the ticket
/// warns about. The item has to land in a *field*, and which field depends on the operation — so
/// either every adapter learns "if this step carries items, loop and substitute", or the executor
/// grows a per-operation table of substitution fields, which is adapter knowledge kept somewhere
/// else. It also cannot express a unit of more than one step: `[scan_docx, convert]` is one adapter
/// call across two steps, and iterating one of them means nothing.
///
/// **What expansion buys that is not obvious, and it is the founder's decision of 2026-08-31.** One
/// approval for the whole job — "Rename all 40?" rather than forty prompts — is not implemented
/// here at all. The expanded plan is one plan, so `RiskApprovalPolicy` assesses it once and asks
/// once, exactly as it does for every other plan. That is the founder's "a scope the rule can
/// already express", and it is why this branch touches neither the risk engine nor the consequence
/// rule: making the approval cover a job is a consequence of the shape, not a change to the rule.
///
/// **Resolved once and pinned, for `pinningSelectedDirectoryInput`'s reason.** `items` is written by
/// the resolution and then travels inside the plan, so preview, assessment and execution all act on
/// the same forty files the user saw when they approved. A job whose items were re-read at each
/// phase could be approved over one list and run over another.
public struct PlanItemJob: Codable, Equatable, Sendable {
    /// Where the items come from.
    public var source: PlanItemSource
    /// The folder to read, for `.folder`. Ignored — and required absent — for every other source.
    public var folderPath: String?
    /// Whether this job's items are files or folders.
    public var itemKind: PlanItemKind
    /// File extensions, without dots, that an item must match. `nil` or empty means every file.
    ///
    /// Meaningful only for `.files`. A folder job that names extensions is refused rather than
    /// having them ignored — a filter that silently does nothing is how a user ends up believing a
    /// job was narrower than it was.
    public var fileExtensions: [String]?
    /// Which field of each expanded step the item is written into.
    ///
    /// **A declared field rather than a per-operation rule**, because the field genuinely differs:
    /// a document conversion reads its folder from `inputPath`, and a Shortcut takes its per-file
    /// input as `shortcutInput`. Declaring it keeps the knowledge in the plan, where a reader can
    /// see it, instead of in a table the executor would have to keep in step with the adapters.
    ///
    /// Two cases is the whole set today, and a third is a decision rather than a default — see
    /// `PlanItemField`.
    public var itemField: PlanItemField
    /// The items, in the order they will be worked through — **resolved, not authored**.
    ///
    /// Empty on every plan a planner produces, filled in exactly once by
    /// `PlanItemJobResolver.resolving(_:...)`, and then carried inside the plan for the rest of the
    /// run and into SONNY-210's stored record. It is deliberately absent from
    /// `AgentPlanDecoder.itemJobKeys`, so a model cannot name the forty paths a job will act on —
    /// the same rule, and the same reason, as `AgentStep.resolvedFromFinderSelection`.
    public var items: [String]
    /// The items that could not even be **previewed**, and are therefore not in the plan's steps at
    /// all (SONNY-235).
    ///
    /// **Why a job can lose an item before it starts, and why the loss is recorded here.** `prepare`
    /// previews every unit before anything is approved, and a preview reaches into the item: a
    /// document conversion scans the folder it was handed and refuses one with nothing to convert, a
    /// zip enumerates the folder's files. So a forty-folder job in which one folder holds no Word
    /// document used to die at `prepare` with a message about that one folder — no approval, no
    /// partial run, thirty-nine folders untouched. That contradicts skip-and-continue in the
    /// direction the user notices most, so an item that cannot be previewed is dropped from the plan
    /// and recorded here instead, and the other thirty-nine are previewed, approved and run.
    ///
    /// **Dropped rather than merely reported, and the difference is a safety property.** Leaving the
    /// item's steps in the plan would leave `assessRisk` to throw on them next — assessment reaches
    /// the item too, `LargestFilesZipCapabilityAdapter.assessRisk` validates the folder it is about
    /// to read — and isolating *that* would let an item the assessment never saw run under an
    /// approval it was never part of, if the world moved between the two. With the steps gone,
    /// preview, assessment and execution are all about exactly the items that will be attempted.
    ///
    /// **Resolver-written**: absent from `AgentPlanDecoder.itemJobKeys`, like `items`, so a model
    /// cannot assert that an item was unavailable.
    public var unavailableItems: [ItemJobFailure]

    /// The most items one job may hold.
    ///
    /// **A refusal rather than a truncation**, for `ResumableTaskStore.maxEncodedPlanBytes`' reason:
    /// a job silently cut to the first hundred of five hundred files is a *different* job from the
    /// one the user approved, and they would have no way to tell. Refusing names the number.
    ///
    /// **Fifty, and the number is the resumable store's budget rather than a round figure.** A job
    /// that cannot be checkpointed cannot remember its place, which is the whole of this feature, so
    /// the cap is set where the expanded plan still fits `ResumableTaskStore.maxEncodedPlanBytes`.
    /// Measured rather than reasoned about, by
    /// `aJobOfTheLargestPermittedSizeStillFitsTheResumableStoresPlanBudget`: a fifty-item job of the
    /// two-step template this product actually produces, over 120-character iCloud paths, encodes to
    /// **34962 bytes** against a 65536-byte budget, and the same shape at a hundred items encodes to
    /// **69717** — over it. Fifty is also comfortably above the founders' own example ("Rename all
    /// 40?") and below the point where an expanded plan stops being something a person can be shown
    /// before approving it.
    ///
    /// **What the cap does not bound, stated rather than implied.** A template's own size is
    /// unbounded — more steps, or a long `draftContent` — so no item count can guarantee the budget
    /// for every possible job. The residual degrades gracefully rather than silently: the store
    /// refuses an oversized plan on its own terms, the caller reports that as a write failure, and
    /// the run itself continues. What is lost is the offer to carry on, not the work.
    public static let maxItems = 50

    public init(
        source: PlanItemSource,
        folderPath: String? = nil,
        itemKind: PlanItemKind,
        fileExtensions: [String]? = nil,
        itemField: PlanItemField,
        items: [String] = [],
        unavailableItems: [ItemJobFailure] = []
    ) {
        self.source = source
        self.folderPath = folderPath
        self.itemKind = itemKind
        self.fileExtensions = fileExtensions
        self.itemField = itemField
        self.items = items
        self.unavailableItems = unavailableItems
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case folderPath
        case itemKind
        case fileExtensions
        case itemField
        case items
        case unavailableItems
    }

    /// Written out rather than synthesized so a record written before this field existed, or by a
    /// path that never resolved, decodes as an unresolved job instead of failing — which would take
    /// the whole encrypted file, and every other unfinished task in it, down with it. Same rule
    /// `ResumableTask.init(from:)` states for `declinedAt`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // **A null `source` is how the wire says "this is not a job"** — see
        // `AgentPlanSchema.itemJobSchema` for why the nullability had to move inside the object
        // rather than sitting on it. Signalled rather than returned, because a `Decodable`
        // initializer has no way to say "no value"; `AgentPlan.init(from:)` catches exactly this and
        // maps it to `nil`, and every other decode failure — a job with a source and no `itemField`,
        // say — still throws a real `DecodingError` and is refused rather than silently becoming an
        // ordinary plan that runs the template once.
        guard let source = try container.decodeIfPresent(PlanItemSource.self, forKey: .source) else {
            throw PlanItemJobDecodingSignal.notAJob
        }
        self.init(
            source: source,
            folderPath: try container.decodeIfPresent(String.self, forKey: .folderPath),
            itemKind: try container.decode(PlanItemKind.self, forKey: .itemKind),
            fileExtensions: try container.decodeIfPresent([String].self, forKey: .fileExtensions),
            itemField: try container.decode(PlanItemField.self, forKey: .itemField),
            items: try container.decodeIfPresent([String].self, forKey: .items) ?? [],
            unavailableItems: try container.decodeIfPresent([ItemJobFailure].self, forKey: .unavailableItems) ?? []
        )
    }

    /// Whether this job's items have been resolved yet.
    /// `PlanItemJobExpansion` is idempotent off
    /// this: a plan that has already been expanded — a resumed run's stored plan, or a second
    /// `prepare` of the same prepared run — passes through untouched rather than resolving a second,
    /// possibly different, list.
    public var isResolved: Bool { !items.isEmpty }
}

/// The one thing `PlanItemJob.init(from:)` has to say that a `Decodable` initializer cannot return:
/// the object it was handed describes no job at all.
///
/// Its own type rather than a `DecodingError` case so that `AgentPlan.init(from:)` can catch exactly
/// this and nothing else — catching a `DecodingError` there would swallow a malformed job as well,
/// which is the silent failure this whole shape exists to avoid.
enum PlanItemJobDecodingSignal: Error {
    case notAJob
}

/// Where a job's items come from.
///
/// **A literal list is deliberately not one of them.** A planner has not seen the user's files, so a
/// list it wrote would be invented; and a user who names three files by hand is asking for a
/// three-step plan, which this repository already expresses without a job at all. Both sources here
/// are read from the machine at resolve time, which is what makes the list the user's rather than a
/// model's.
public enum PlanItemSource: String, Codable, CaseIterable, Equatable, Sendable {
    /// Everything in one folder, non-recursively — see `PlanItemJobResolver` for why not recursively.
    case folder
    /// Whatever the user has selected in Finder right now, read through the same whitelisted reader
    /// `get_finder_selection` uses.
    case finderSelection = "finder_selection"
}

/// Whether a job walks files or folders.
///
/// Both are real: "summarise each of these forty PDFs" is a job over files, and "convert the Word
/// documents in each of these folders" is a job over folders, where each item is handed to a
/// capability that scans it. Deriving one from the presence of an extension filter was rejected as
/// magic — a job says which it means.
public enum PlanItemKind: String, Codable, CaseIterable, Equatable, Sendable {
    case files
    case folders

    /// How this job's items are named to a person, plural. Used in the one place a job's own
    /// sentence is authored — the run summary — so a count reads as "38 of 40 files".
    public var pluralNoun: String {
        switch self {
        case .files:
            return "files"
        case .folders:
            return "folders"
        }
    }
}

/// Which field of an expanded step carries the item.
///
/// **Two cases, and a third is a decision.** Each one is a field some adapter already reads as "the
/// thing to act on", and adding a case means checking that the adapter validates whatever a job
/// would put there — `inputPath` goes through `PathWhitelist`, and `shortcutInput` is text the
/// Shortcuts bridge quotes. A case added without that check would be a way to put an unvalidated
/// value into a field by declaring a job over it, which is the one thing this enum must not become.
public enum PlanItemField: String, Codable, CaseIterable, Equatable, Sendable {
    /// The path field every file- and folder-consuming capability reads.
    case inputPath
    /// The text a Shortcut is run with, which for a per-file job is the file's path.
    case shortcutInput

    /// How this field is named in the one sentence a user reads when a job declares one no step of
    /// its template reads.
    var displayNoun: String {
        switch self {
        case .inputPath:
            return "file or folder"
        case .shortcutInput:
            return "Shortcut input"
        }
    }
}

public extension AgentOperation {
    /// Which of a job's item fields this operation actually reads (SONNY-235, PR #185 F2).
    ///
    /// **Why this table has to exist, inside the one design chosen to avoid tables like it.** The
    /// plan-level shape moves "which field carries the item" out of the adapters and into the plan,
    /// which is the decision and is right. What it also does is make a *wrong* declaration silently
    /// executable: a `[invoke_shortcut]` template declaring `itemField: .inputPath` expanded cleanly,
    /// ran the Shortcut once per item with **no input at all**, recorded zero failures and reported
    /// "Worked through all 3 files" — a job that touched none of its items and called itself a
    /// complete success, which is the one direction of failure this branch's whole partial-outcome
    /// design exists to prevent.
    ///
    /// So: one table, in the plan language rather than in an adapter, read **only** to refuse a
    /// declaration and to decide where the item is written. Nothing dispatches off it, and no adapter
    /// consults it — an adapter still reads whatever field it always read.
    ///
    /// **Exhaustive, with no `default`**, so a new operation cannot reach the tree without being
    /// classified. `theItemFieldTableMatchesWhatTheAdaptersActuallyRead` is the backstop that keeps
    /// it in step with the adapters rather than leaving it to memory.
    var itemFieldsRead: Set<PlanItemField> {
        switch self {
        // The folder- and file-consuming capabilities, reading `inputPath` directly or through
        // `FinderSelectionResolver.selectedDirectoryPath`'s primary/secondary pooling.
        case .scanSelectLargestFiles, .createZip, .scanDocx, .convertDocxToPDF:
            return [.inputPath]
        // `outputPath ?? inputPath` — which is why an item written into `inputPath` reaches them, and
        // why writing one into a *trailing* consuming step is exactly what stops it consuming.
        case .revealInFinder, .openGeneratedArtifact:
            return [.inputPath]
        case .invokeShortcut:
            return [.shortcutInput]
        case .openHackerNews, .fetchHNHeadlines, .writeMarkdown, .webToMarkdown, .openApp,
             .openAppSearchURL, .openURL, .playMedia, .getFinderSelection, .showPermissionReadiness,
             .saveRoutine, .runRoutine, .createWorkspace, .editWorkspace, .openWorkspace,
             .createLocalDraft, .calculateUtility, .lookupClipboardHistory, .expandSnippet,
             .saveSnippet, .switchRunningApp, .lookupRecentArtifacts, .visionSession, .clarify,
             .unsupported:
            return []
        }
    }
}

/// One item of a job that could not be done, and why.
///
/// **Failures are recorded and completions are not, and that asymmetry is deliberate.** Which items
/// finished is already a fact of SONNY-210's record — the completed units' step ids, mapped back
/// through `AgentStep.itemIndex` — so storing it again would be a second home for one fact, which is
/// the shape this repository consolidates away. Which items *failed* is derivable from nothing: a
/// failed item's steps are simply not among the completed ones, exactly like an item that never ran.
public struct ItemJobFailure: Codable, Equatable, Sendable {
    /// This item's position in `PlanItemJob.items`, zero-based.
    public var itemIndex: Int
    /// The item itself, as the job resolved it. Copied rather than looked up, because this value
    /// travels to the widget and to a stored record where the plan may not be at hand.
    public var item: String
    /// What went wrong, as the user is told it.
    public var message: String
    public var failedAt: Date

    public init(itemIndex: Int, item: String, message: String, failedAt: Date) {
        self.itemIndex = itemIndex
        self.item = item
        self.message = message
        self.failedAt = failedAt
    }
}

/// The failures a job declaration can have that are the plan's fault rather than the file system's.
///
/// Its own type rather than new `AgentExecutionError` cases: that enum is switched over in several
/// places, and these are all "this job cannot be run as declared", which reads as one thing.
public enum PlanItemJobError: Error, Equatable, LocalizedError {
    case missingFolderPath
    case folderPathOnNonFolderSource
    case fileExtensionsOnFolderItems
    case noItems(String)
    case tooManyItems(count: Int, limit: Int)
    /// A job reached `assessRisk` or `execute` without having been through
    /// `AgentActionExecutor.prepare` — see `refuseUnresolvedItemJob(in:)` for why that is a refusal
    /// rather than a second resolution.
    case notPrepared
    /// No step of the template reads the field the job says carries the item, so the item would
    /// reach nothing and every item would be reported done (PR #185, F2).
    case noStepReadsTheItemField(String)
    /// Not one item of the job could even be previewed, so there is nothing to ask approval for. The
    /// associated value is the first item's own error, which is the message that explains what is
    /// wrong with what the user pointed at.
    case everyItemUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingFolderPath:
            return "This job says to work through a folder but does not say which folder."
        case .folderPathOnNonFolderSource:
            return "This job names a folder but does not take its items from one."
        case .fileExtensionsOnFolderItems:
            return "This job works through folders, so a file-type filter would do nothing."
        case .noItems(let detail):
            return detail
        case .tooManyItems(let count, let limit):
            return "That is \(count) items, and Sonny works through at most \(limit) in one job. Narrow it down and ask again."
        case .notPrepared:
            return "Sonny could not work out which items this job covers."
        case .noStepReadsTheItemField(let detail):
            return detail
        case .everyItemUnavailable(let detail):
            return detail
        }
    }
}

/// How far a job over many items has got — **derived, never stored twice** (SONNY-235).
///
/// The inputs are all facts something else already owns: the job's item list and the step-to-item
/// map live inside the plan, which SONNY-210's record stores whole; which steps are finished is that
/// record's `completedStepIDs`, written by the unit checkpoint that knows nothing about items; and
/// the failures are the one thing neither of those can answer, which is why `ItemJobFailure` is
/// stored and completion is not.
///
/// The same type answers for a run in flight and for a record on disk, because both hold the same
/// three inputs — the widget's progress line and the Memory row's "38 of 40" are the same
/// computation rather than two that have to agree.
public struct ItemJobProgress: Equatable, Sendable {
    public var itemKind: PlanItemKind
    /// Every item of the job, in the order it is worked through.
    public var items: [String]
    /// The indexes into `items` **this plan is responsible for** — the ones whose steps it holds,
    /// plus the ones it recorded unavailable. Ascending.
    ///
    /// **The job's size for this run, and it is not `items.count`** (PR #185, F1). A fresh job covers
    /// its whole list. A *resumed* one covers only what was left: carrying `itemJob` into
    /// `remainingPlan()` without this makes a resume that did the last two of forty report "40",
    /// which was the trap in the obvious one-line fix for that finding. `items` stays the whole list
    /// so a failure's `itemIndex` keeps pointing at the item it always did; only the count is scoped.
    public var coveredItemIndexes: [Int]
    /// Indexes into `items` whose every step is finished, ascending.
    public var completedItemIndexes: [Int]
    /// The items that were tried and could not be done.
    public var failures: [ItemJobFailure]

    public init(
        itemKind: PlanItemKind,
        items: [String],
        coveredItemIndexes: [Int],
        completedItemIndexes: [Int],
        failures: [ItemJobFailure]
    ) {
        self.itemKind = itemKind
        self.items = items
        self.coveredItemIndexes = coveredItemIndexes
        self.completedItemIndexes = completedItemIndexes
        self.failures = failures
    }

    /// The two kinds of failure a job has, in item order and never counted twice: the items that
    /// could not be prepared (`PlanItemJob.unavailableItems`, which the plan carries) and the items
    /// that failed while running (which the run reports and the checkpoint stores). An item cannot be
    /// both — an unavailable one has no steps to run — and the dedup is a belt on that rather than a
    /// live case.
    static func merged(_ unavailable: [ItemJobFailure], _ atRuntime: [ItemJobFailure]) -> [ItemJobFailure] {
        var seen: Set<Int> = []
        return (unavailable + atRuntime)
            .filter { seen.insert($0.itemIndex).inserted }
            .sorted { $0.itemIndex < $1.itemIndex }
    }

    public var itemCount: Int { coveredItemIndexes.count }
    public var completedCount: Int { completedItemIndexes.count }
    public var failedCount: Int { failures.count }
    /// Everything the job has settled one way or the other. What is left is `itemCount` minus this.
    public var settledCount: Int { completedCount + failedCount }

    /// **An item counts as done when every step of it is done, and that is the only definition that
    /// survives a unit boundary being coarser than a step.** SONNY-210 records whole units, and a
    /// unit may hold several of an item's steps; an item whose first unit finished and whose second
    /// did not is not done, and saying otherwise would let a resume skip work that never happened.
    ///
    /// Returns `nil` for a plan that is not a job, so a caller can ask any plan and get an honest
    /// "there is no job here" rather than a zero that reads like an empty one.
    public static func of(
        plan: AgentPlan,
        completedStepIDs: [String],
        failures: [ItemJobFailure]
    ) -> ItemJobProgress? {
        guard let job = plan.itemJob, job.isResolved else {
            return nil
        }
        let completed = Set(completedStepIDs)
        var stepsPerItem: [Int: [String]] = [:]
        for step in plan.steps {
            guard let index = step.itemIndex else {
                continue
            }
            stepsPerItem[index, default: []].append(step.id)
        }
        let completedIndexes = stepsPerItem
            .filter { _, ids in !ids.isEmpty && ids.allSatisfy { completed.contains($0) } }
            .keys
            .sorted()
        let merged = Self.merged(job.unavailableItems, failures)
        // What this plan is responsible for: every item it holds steps for, plus every item it
        // recorded unavailable — those have no steps by construction and must still be counted, or a
        // job that dropped one at `prepare` would report "38 of 39".
        let covered = Set(stepsPerItem.keys).union(job.unavailableItems.map(\.itemIndex)).sorted()
        return ItemJobProgress(
            itemKind: job.itemKind,
            items: job.items,
            coveredItemIndexes: covered,
            completedItemIndexes: completedIndexes,
            failures: merged.filter { covered.contains($0.itemIndex) }
        )
    }
}
