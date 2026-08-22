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
    /// **The one category whose own switch predates this enum.** Clipboard recording is turned on
    /// and off through `ClipboardHistorySettings.isEnabled`, which the monitor already fails closed
    /// on, so nothing here duplicates it — `MemorySettingsStore` never writes a per-category flag
    /// for this case, and `MemoryRecordingSettings.allowsRecording(in:)` expresses only the master
    /// switch and the enterprise policy for it. A second switch over the same behaviour is how a
    /// surface ends up saying "on" while recording is off.
    case clipboardHistory
    case snippets
    case approvedApps

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
        case .clipboardHistory:
            return "Clipboard history"
        case .snippets:
            return "Snippets"
        case .approvedApps:
            return "Allowed apps"
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
    /// Exhaustive with no `default`, the same guard `kind` uses and for the same reason: a twelfth
    /// store must not be able to arrive on disk, be wiped by Delete Local Data, and be invisible in
    /// the one surface built to show the user what Sonny remembers.
    /// `MemorySettingsTests.everyLocalStoreIsPlacedUnderExactlyOneMemoryCategoryOrExcluded` pins the
    /// union.
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
            // never had one; grouped with the other records of what tasks did rather than given an
            // eighth row the founder's enumeration does not name.
            return .taskHistory
        case .recentArtifacts:
            return .recentArtifacts
        case .clipboardHistory:
            return .clipboardHistory
        case .snippets:
            return .snippets
        case .approvedApps:
            return .approvedApps
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
