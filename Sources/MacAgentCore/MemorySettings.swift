import Foundation

/// A kind of thing Sonny remembers, as the user meets it in Command Center's Memory section.
///
/// **These are the stores that already exist, not a new memory engine** (founder, 2026-08-21, on
/// SONNY-17). §6.10's required memory types were already on disk as Sonny's local stores; what was
/// missing was one place to see them and four controls over each. So this enum names the *rows* of
/// that surface, and `LocalStore.memoryCategory` says which store's contents each row shows —
/// several rows show more than one file.
///
/// Deliberately not a case for user preferences. §6.10 lists preferences as a memory type and the
/// founder's answer is that they are the existing Settings surfaced under Memory rather than a new
/// store — so the Memory page links to Settings for them, and nothing here records, disables or
/// deletes them.
public enum MemoryCategory: String, CaseIterable, Identifiable, Sendable {
    case routines
    case workspaces
    case taskHistory
    case recentArtifacts
    /// Where the user's outputs land — §6.10's "common output locations" (SONNY-209).
    ///
    /// **A row of its own rather than folded into `recentArtifacts`, and that was the decision.**
    /// The two are neighbours: one store notes the file a run produced, the other the folder it
    /// produced it in, and both are `.trace`. Three things settled it apart anyway.
    ///
    /// It answers a different question. Recent artifacts is a list Sonny offers *back* — "open the
    /// thing you just made". Output locations is what Sonny offers *forward*, as a destination for
    /// something not made yet. A person deciding whether Sonny should keep suggesting folders is not
    /// deciding whether it should remember files it created, and one switch would make them answer
    /// both at once.
    ///
    /// It has a different lifetime. A recent artifact ages out at thirty days and points at a
    /// specific file that may since have been deleted or moved; a folder someone has used for a year
    /// is more valuable the longer it has been used, and `OutputLocationStore` keeps it accordingly.
    /// Sharing a row would mean one Delete button taking both, which is the wrong grouping for two
    /// stores that go stale at different rates.
    ///
    /// And the founder named it as one of §6.10's missing memory *types* (2026-08-21, SONNY-17),
    /// alongside preferences and long-running task state. A type the decision names and the surface
    /// does not show is the gap that decision was taken to close.
    case outputLocations
    /// **The one category whose own switch predates this enum.** Clipboard recording is turned on
    /// and off through `ClipboardHistorySettings.isEnabled`, which the monitor already fails closed
    /// on, so nothing here duplicates it — `MemorySettingsStore` never writes a per-category flag
    /// for this case, and `MemoryRecordingSettings.allowsRecording(in:)` expresses only the master
    /// switch and the enterprise policy for it. A second switch over the same behaviour is how a
    /// surface ends up saying "on" while recording is off.
    case clipboardHistory
    case snippets
    case approvedApps
    /// Runs that began and did not finish (row 13, SONNY-210).
    ///
    /// **Its own row rather than folded under `.taskHistory`, and the lifecycle is what decides
    /// it.** The three stores that *are* folded under task history — plan details, the vision
    /// journal, Shortcut run history — each hang off a history row: they are parts of a finished
    /// task, deleted with it and reachable through it. An unfinished run has no history row at all,
    /// because a row is written when a run terminates and this is the store for runs that have not.
    /// Folding it in would put its entries behind a page that cannot show them and a delete that
    /// cannot reach them, and the founder's lifecycle for this store — it lives until the task
    /// completes **or the user deletes it** — needs a delete the user can actually press.
    case resumableTasks
    /// The skills the user added on the Skills page (SONNY-452). Its own row, under "Saved by you":
    /// every entry is a press of Add, and the row's View opens that page rather than a sheet, since
    /// the page is where adding and removing already live.
    case skills

    public var id: String { rawValue }

    /// The row's name. Product vocabulary, matched to the words the rest of the app already uses
    /// for these stores (Settings' Delete-Local-Data list, and `LocalStorageLoadFailureSource`'s
    /// labels) rather than to the file names.
    public var title: String {
        switch self {
        case .routines:
            return "Routines"
        case .workspaces:
            return "Workspaces"
        case .taskHistory:
            return "Task history"
        case .recentArtifacts:
            return "Recent artifacts"
        case .outputLocations:
            // "Output locations", not "Folders" or "Destinations": it is the vocabulary §6.10 and
            // the founder's own decision use, and it says which folders these are — the ones Sonny's
            // work comes out into — where a bare "Folders" would read as every folder Sonny has ever
            // seen.
            return "Output locations"
        case .clipboardHistory:
            return "Clipboard history"
        case .snippets:
            return "Snippets"
        case .approvedApps:
            return "Allowed apps"
        case .resumableTasks:
            // What the user would call these, not what the store is called. "Unfinished tasks" is
            // the same sentence the widget's offer makes ("you were partway through X"), so the row
            // and the offer name one thing.
            return "Unfinished tasks"
        case .skills:
            return "Skills"
        }
    }

    /// The row's count with the thing it counts named — "1 folder", "184 tasks".
    ///
    /// **Every row said "N saved", and that word is unitless** (SONNY-243). The founder read the
    /// Output locations row as `1 saved` and its sheet as `Desktop · ~/Desktop · 2 times`, and
    /// reported the pair as a bug within a minute of first seeing it. Both numbers were right and
    /// they measure different things: the row counts the folders Sonny remembers — which is exactly
    /// the number of rows the sheet then lists — and `2 times` is one of those folders' own use
    /// count. Nothing on either surface said which was which, so the only reading available was that
    /// one of them was wrong.
    ///
    /// **Naming the unit is the repair, and it is applied to every row rather than to the one that
    /// was reported.** A single row reading "1 folder" among neighbours reading "N saved" is the same
    /// defect the report is about — words that differ from their neighbours' for a reason the reader
    /// cannot see. And "saved" was not merely unitless: this page groups its rows by
    /// `LocalStoreKind`, and for the whole `.trace` half nobody saved anything — a task history row,
    /// a copied item, an allowed app and an unfinished run are recorded rather than saved.
    ///
    /// The nouns are the row's own vocabulary, so `title` and this cannot describe different things;
    /// `MemorySettingsTests.everyMemoryRowsCountNamesTheThingItCounts` walks the population.
    public func countedEntries(_ count: Int) -> String {
        "\(count) \(count == 1 ? singularNoun : pluralNoun)"
    }

    /// What one entry under this row is called. Lower-case: it is read mid-sentence, after a number.
    var singularNoun: String {
        switch self {
        case .routines:
            return "routine"
        case .workspaces:
            return "workspace"
        case .taskHistory:
            return "task"
        case .recentArtifacts:
            return "artifact"
        case .outputLocations:
            // The founder's own word for these on SONNY-243. `title` says *which* folders these are;
            // a count does not have room to and does not need to.
            return "folder"
        case .clipboardHistory:
            // "copied item", not "item": it is the noun the row's own delete confirmation already
            // uses ("every copied item Sonny has recorded"), so the count and the confirmation name
            // one thing.
            return "copied item"
        case .snippets:
            return "snippet"
        case .approvedApps:
            return "app"
        case .resumableTasks:
            // "unfinished task" rather than "task", even though the row is already titled
            // "Unfinished tasks" and the repetition is audible. Task history's rows are also tasks,
            // the two sit on one page, and the stores are disjoint by construction — a history row
            // is written when a run terminates and this store holds the runs that have not — so a
            // bare "1 task" beside "184 tasks" invites the one arithmetic the page cannot support.
            return "unfinished task"
        case .skills:
            // The ticket's proposed noun, matching the sidebar page it counts. Founders to confirm
            // (SONNY-452).
            return "skill"
        }
    }

    /// The plural of `singularNoun`. Spelled out rather than derived: an "-s" rule is a guess about
    /// English that happens to hold for every noun here today and for no reason that will keep
    /// holding.
    var pluralNoun: String {
        switch self {
        case .routines:
            return "routines"
        case .workspaces:
            return "workspaces"
        case .taskHistory:
            return "tasks"
        case .recentArtifacts:
            return "artifacts"
        case .outputLocations:
            return "folders"
        case .clipboardHistory:
            return "copied items"
        case .snippets:
            return "snippets"
        case .approvedApps:
            return "apps"
        case .resumableTasks:
            return "unfinished tasks"
        case .skills:
            return "skills"
        }
    }

    /// Every store whose contents this row covers, in `LocalStore.allCases` order.
    ///
    /// Derived from `LocalStore.memoryCategory` rather than listed here, so the mapping exists once
    /// and a store cannot appear under one row and be classified under another.
    public var stores: [LocalStore] {
        LocalStore.allCases.filter { $0.memoryCategory == self }
    }

    /// Whether this row holds things the user asked Sonny to save, or records of what happened.
    ///
    /// **`LocalStoreKind`, not a second taxonomy.** The Memory section groups its rows, and the
    /// grouping had to come from something real rather than from a reading invented for the page —
    /// this is the classification SONNY-115 already built, the same one "Don't save this task"
    /// decides suppression by. Every category's stores happen to share one kind, which is a fact
    /// about the mapping rather than a guarantee of it, so
    /// `MemorySettingsTests.everyMemoryRowsStoresShareOneKindSoTheRowCanBeGroupedByIt` asserts it
    /// and `.notWrittenByTasks` is unreachable here (its one store is excluded from every row).
    ///
    /// Returns `.trace` for an empty `stores`, which cannot happen — `everyMemoryRowCoversAtLeastOneStore`
    /// pins that — and is the conservative answer if it ever did.
    public var storeKind: LocalStoreKind {
        stores.first?.kind ?? .trace
    }
}

extension LocalStore {
    /// Which Memory row this store's contents appear under, or `nil` when it holds nothing the
    /// Memory section shows.
    ///
    /// Exhaustive with no `default`, the same guard `kind` uses and for the same reason: a new store
    /// must not be able to arrive on disk, be wiped by Delete Local Data, and be invisible in
    /// the one surface built to show the user what Sonny remembers. Row 13's output locations is the
    /// first store to arrive since this mapping existed, and SONNY-210's unfinished runs are the
    /// second; both arrived that way.
    /// `MemorySettingsTests.everyLocalStoreIsPlacedUnderExactlyOneMemoryCategoryOrDeliberatelyExcluded`
    /// pins the union. (That reference read `…OrExcluded` until SONNY-209 — no such test, and the
    /// same renamed-symbol staleness this ticket found four instances of elsewhere.)
    public var memoryCategory: MemoryCategory? {
        switch self {
        case .routines:
            return .routines
        case .workspaces:
            return .workspaces
        case .taskHistory:
            return .taskHistory
        case .taskPlanDetails:
            // What each finished task planned. It hangs off a history row, is capped with it,
            // suppressed with it and deleted with it — so it is part of that row rather than a
            // memory type of its own.
            return .taskHistory
        case .visionSessionJournal:
            // What the screen-control loop did during a task. Already reachable only through the
            // task it belongs to (`AgentViewModel.deleteScreenRecord(for:)` deletes exactly one
            // task's), so it belongs to that task's row here too.
            return .taskHistory
        case .shortcutRunHistory:
            // Which Shortcuts have been observed to run cleanly — a record of past runs, kept so a
            // known-good Shortcut is not re-assessed from scratch. It has no surface of its own and
            // never had one; grouped with the other records of what tasks did rather than given a
            // row of its own that the founder's enumeration does not name. (That last clause said
            // "an eighth row" when there were seven; SONNY-209 added one and the ordinal would have
            // gone stale for the second time, so it is gone rather than incremented.)
            return .taskHistory
        case .recentArtifacts:
            return .recentArtifacts
        case .outputLocations:
            return .outputLocations
        case .clipboardHistory:
            return .clipboardHistory
        case .snippets:
            return .snippets
        case .approvedApps:
            return .approvedApps
        case .resumableTasks:
            return .resumableTasks
        case .addedSkills:
            return .skills
        case .pendingServerDeletions:
            // **Not memory — an obligation** (SONNY-333). This file holds the ids of tasks the user
            // has already deleted, kept only until the gateway confirms their retained copy is gone.
            // It is the one store here that records nothing Sonny remembers *about* the user, so
            // there is no memory type for it to be, and its entries have no meaning a row could
            // show: an opaque key and the moment a delete was pressed.
            //
            // **A row would also carry a Delete, and that press would cancel a deletion the user
            // asked for** — leaving their content on the server while the button that was supposed
            // to remove it reports success. That is a worse failure than the absence of a row, and
            // it is the reason this is `nil` rather than a row with the button hidden.
            return nil
        case .clipboardHistorySettings:
            // **Not memory — the clipboard switch itself.** This file holds whether clipboard
            // history runs and whether its first-run notice was answered. Deleting it would reset a
            // preference rather than forget anything, and re-enable recording the user had turned
            // off; showing it as a memory type would offer to delete the switch. It is the store
            // `LocalStoreClassification` already calls `.notWrittenByTasks` for the same reason.
            return nil
        }
    }
}

/// An administrator's standing instruction about memory — §6.10's "enterprise policy can disable
/// memory".
///
/// **Present and inert.** Nothing in the product produces a managed policy today; the only provider
/// that ships is `UnmanagedMemoryPolicyProvider`, so `disablesMemory` is always false and the switch
/// behaves exactly as if this type did not exist. Row 19 supplies a real provider and this composes
/// without any of the readers below changing — which is the whole reason the hook lands with the
/// surface it governs rather than after it.
public struct MemoryEnterprisePolicy: Equatable, Sendable {
    /// No administrator has said anything. Every shipping code path resolves to this today.
    public static let unmanaged = MemoryEnterprisePolicy(isManaged: false, disablesMemory: false)

    /// Whether this machine is under an administrator's policy at all. Separate from
    /// `disablesMemory` so a managed machine whose policy *allows* memory is distinguishable from
    /// an unmanaged one — the two look identical from the switch's behaviour and must not look
    /// identical to the surface that reports why a control is locked.
    public var isManaged: Bool

    /// Whether that policy turns memory off. Overrides the user's own switch in one direction only:
    /// it can disable, never enable.
    public var disablesMemory: Bool

    public init(isManaged: Bool, disablesMemory: Bool) {
        self.isManaged = isManaged
        self.disablesMemory = disablesMemory
    }
}

/// Where a `MemoryEnterprisePolicy` comes from. Row 19 replaces the implementation, not the readers.
public protocol MemoryPolicyProviding: Sendable {
    func currentPolicy() -> MemoryEnterprisePolicy
}

/// The only provider that ships today: no administrator, no restriction.
public struct UnmanagedMemoryPolicyProvider: MemoryPolicyProviding {
    public init() {}

    public func currentPolicy() -> MemoryEnterprisePolicy { .unmanaged }
}

/// Whether Sonny may record new memory, composed from the user's master switch, their per-type
/// switches, and the enterprise policy.
///
/// **The standing sibling of `TaskRecordingPolicy`, and deliberately a separate type.** That one
/// answers "does *this run* leave traces" and resets itself when the run ends; this one answers
/// "may Sonny remember this kind of thing at all" and outlives every run. Both are asked at the
/// same writing sites, and both must say yes — `CapabilityExecutionContext.allowsRecording(to:)`
/// and `AgentViewModel.allowsRecording(to:)` are the two places that conjunction is written.
///
/// **What it does not do: delete.** Turning memory off stops new entries and touches nothing
/// already stored, which is the founder's requirement verbatim. Deletion is its own control.
public struct MemoryRecordingSettings: Equatable, Sendable {
    /// Everything on, nobody managing it — the default for every existing construction site.
    public static let recordEverything = MemoryRecordingSettings()

    /// The master switch, as the user left it.
    public var isEnabledByUser: Bool

    /// The types the user switched off individually. Absent from this set means on, so a category
    /// added later defaults to recording rather than to silence.
    public var categoriesDisabledByUser: Set<MemoryCategory>

    /// The administrator's standing instruction. `.unmanaged` everywhere today.
    public var policy: MemoryEnterprisePolicy

    public init(
        isEnabledByUser: Bool = true,
        categoriesDisabledByUser: Set<MemoryCategory> = [],
        policy: MemoryEnterprisePolicy = .unmanaged
    ) {
        self.isEnabledByUser = isEnabledByUser
        self.categoriesDisabledByUser = categoriesDisabledByUser
        self.policy = policy
    }

    /// Whether an administrator has taken the switch away from the user.
    public var isDisabledByPolicy: Bool { policy.disablesMemory }

    /// The master switch's effective value — the user's answer, unless policy overrides it.
    public var isRecording: Bool { isEnabledByUser && !isDisabledByPolicy }

    /// Whether new entries of this kind may be recorded.
    public func allowsRecording(in category: MemoryCategory) -> Bool {
        isRecording && !categoriesDisabledByUser.contains(category)
    }

    /// Whether new entries may be written to `store`.
    ///
    /// A store outside every category — the clipboard switch's own file — answers `true`: there is
    /// no memory to withhold there, and returning `false` would let a memory switch turn off the
    /// user's ability to record their *preference* about memory.
    public func allowsRecording(to store: LocalStore) -> Bool {
        guard let category = store.memoryCategory else { return true }
        return allowsRecording(in: category)
    }
}

/// Raised when a task asks Sonny to remember something the user has switched memory off for.
///
/// **Refusing out loud, not dropping quietly.** The three writes that raise this — a saved routine,
/// a created workspace, a saved snippet — are things a person asked for by name, so a silent no-op
/// would report a save that did not happen. The trace stores are the opposite case and stay silent,
/// exactly as "Don't save this task" already does: nobody asked for those, so there is nothing to
/// report. Allowed apps is neither, and takes a third path: its write is refused by
/// `AgentViewModel.rememberAppControlGrant`, whose caller already has a fail-closed answer for a
/// grant it could not keep.
public struct MemoryDisabledError: Error, LocalizedError, Equatable {
    public var category: MemoryCategory

    public init(category: MemoryCategory) {
        self.category = category
    }

    public var errorDescription: String? {
        "\(category.title) memory is off, so nothing was saved. Turn it on in Memory."
    }
}
