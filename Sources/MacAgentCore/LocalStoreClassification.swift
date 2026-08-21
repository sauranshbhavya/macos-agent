import Foundation

/// What a local store holds, from the point of view of a task running with "Don't save this task"
/// on.
///
/// The founder's decision of 2026-08-16 (recorded on SONNY-14): the reach of "Don't save this
/// task" is defined by a rule, not by a list. A task writes to most of the local stores, and a
/// reach defined by whichever leak someone happened to notice will miss the rest — this
/// repository's recurring enumerate-before-you-subtract failure. So every store is classified, and
/// `LocalStore` makes going unclassified impossible in both directions: the compiler refuses a new
/// case without a classification, and the suite refuses a new store file without a case.
public enum LocalStoreKind: CaseIterable, Hashable, Sendable {
    /// An incidental record of what happened — **suppressed** while "Don't save this task" is on.
    /// Nobody asked for these; they exist so the product can show its own history back.
    case trace

    /// The thing the user actually asked for — **never suppressed**. Someone who says "save this
    /// as a routine" with the switch on still wants the routine, and the switch never promised
    /// otherwise: it cannot hide a task's effects, and a saved routine is an effect.
    case artifact

    /// **Nothing for a task to suppress.** No task writes here, so there is no trace to withhold
    /// and no output to keep; suppressing it would mean suppressing the user's own preference.
    ///
    /// This third case exists because the founder's own trace/artifact enumeration named eight of
    /// the nine stores that existed when it was made. Without it the classification cannot be
    /// exhaustive, and an exhaustive classification is the whole point. (Planning session's
    /// addition, recorded on SONNY-14 rather than silently inserted.)
    case notWrittenByTasks
}

/// Every local store on disk, each classified exactly once.
///
/// Two independent mechanisms keep this exhaustive, because a store that quietly defaults to
/// "recorded" is exactly how "Don't save this task" stops being true:
///
/// - `kind` switches over `self` with no `default`, so a **new case does not compile** until
///   somebody decides what it is.
/// - `LocalStorageSecurityTests.everyLocalStoreFileIsClassifiedExactlyOnce` matches these cases'
///   file URLs against `LocalDataDeletionService.defaultStoreFileURLs()`, so a **new store file
///   fails the suite** until it gets a case here. Row E's `task-plan-details.json` and row J's
///   `approved-apps.json` are the tenth and eleventh, and both arrived exactly that way: the suite
///   failed until each was classified here. The twelfth will fail the same way.
///
/// `fileURL(fileManager:)` delegates to the store types themselves rather than repeating their
/// filenames, so the two lists cannot drift apart: a store that moves moves in both.
public enum LocalStore: CaseIterable, Hashable, Sendable {
    case visionSessionJournal
    case routines
    case workspaces
    case clipboardHistory
    case clipboardHistorySettings
    case snippets
    case recentArtifacts
    case shortcutRunHistory
    case taskHistory
    case taskPlanDetails
    case approvedApps

    /// Deliberately one `case` per store rather than three grouped ones: each line is a separate
    /// classification decision, and a reviewer should be able to disagree with exactly one of them.
    public var kind: LocalStoreKind {
        switch self {
        case .visionSessionJournal:
            // Row I's action journal: what the screen-control loop did and what it observed after
            // each action. A record *of* the run, never the point of it — and the most sensitive
            // trace of the eleven.
            return .trace
        case .routines:
            // "Save this as a routine" is the ask itself. Suppressing it would break the task.
            return .artifact
        case .workspaces:
            // A created workspace is the task's output, not a note about the task.
            return .artifact
        case .clipboardHistory:
            // A rolling log of copied text. Paused entirely while the switch is on — including
            // text the user copied by hand, an accepted cost of the founder's 2026-08-16 decision:
            // `ClipboardHistoryMonitor` polls `changeCount`
            // (Sources/MacAgentCore/ClipboardHistoryService.swift:261), so it cannot tell Sonny's
            // copies from the user's.
            return .trace
        case .clipboardHistorySettings:
            // The user's own preference — whether clipboard history runs at all, and whether its
            // notice was dismissed. Enumerated at 6f89a5d: the only two `save(_:)` call sites are
            // `applyClipboardHistoryNoticeChoice` (Sources/MacAgent/AgentViewModel.swift:1495), a
            // user preference action, and the store's own legacy-plaintext re-encrypt
            // (Sources/MacAgentCore/ClipboardHistoryService.swift:171). No task path reaches it.
            return .notWrittenByTasks
        case .snippets:
            // A saved snippet is what was asked for.
            return .artifact
        case .recentArtifacts:
            // A list of files a task touched, kept so the product can offer them back. The files
            // themselves still exist — this suppresses the note, which is all it ever claimed to.
            return .trace
        case .shortcutRunHistory:
            // Which Shortcuts have been observed to run cleanly. A record of what happened.
            return .trace
        case .taskHistory:
            // The command, its outcome and its timings. The trace this feature is named after.
            return .trace
        case .taskPlanDetails:
            // What each finished task planned, kept so a follow-up on it has something to correct
            // against (row E, SONNY-147). A record *of* the run, exactly like the row it hangs off
            // — and it is suppressed for the same reason and at the same moment, since a suppressed
            // run writes no row for a detail to belong to.
            return .trace
        case .approvedApps:
            // Row J's per-app control grants (SONNY-140). An `.artifact`, and the reasoning is the
            // one place this classification could plausibly have gone the other way, so it is
            // written out rather than asserted.
            //
            // It is not `.notWrittenByTasks`: a task *is* what writes here. The grant is minted
            // when the user answers a mid-run approval, so the write happens inside the run that
            // "Don't save this task" is switched on for — which is exactly the situation the third
            // case says does not arise.
            //
            // It is not `.trace` either, and that is the decision. What lands here is not a record
            // *of* what happened; it is the user's own answer to a question Sonny asked them.
            // Suppressing it would mean a person allows an app, the switch silently drops the
            // grant, and Sonny asks the identical question on the next run with no way to say why —
            // a consent decision quietly discarded, which is a worse failure than the trace the
            // switch was built to withhold. The founder's ground for the `.artifact` case covers it
            // exactly: the switch cannot hide a task's effects, and a grant the user gave on
            // purpose is an effect.
            //
            // Row D flagged this store as the first to reach this test and left the call here
            // rather than making it on row J's behalf (SONNY-140, comment of 2026-08-17).
            return .artifact
        }
    }

    /// The file this store persists to, resolved through the store type itself so it is the same
    /// URL `LocalDataDeletionService.defaultStoreFileURLs()` resolves — by construction, not by a
    /// duplicated filename literal.
    public func fileURL(fileManager: FileManager = .default) -> URL {
        switch self {
        case .visionSessionJournal:
            return VisionSessionJournalStore(fileManager: fileManager).fileURL
        case .routines:
            return RoutineStore(fileManager: fileManager).fileURL
        case .workspaces:
            return WorkspaceStore(fileManager: fileManager).fileURL
        case .clipboardHistory:
            return ClipboardHistoryStore(fileManager: fileManager).fileURL
        case .clipboardHistorySettings:
            return ClipboardHistorySettingsStore(fileManager: fileManager).fileURL
        case .snippets:
            return SnippetStore(fileManager: fileManager).fileURL
        case .recentArtifacts:
            return RecentArtifactStore(fileManager: fileManager).fileURL
        case .shortcutRunHistory:
            return ShortcutRunHistoryStore(fileManager: fileManager).fileURL
        case .taskHistory:
            return TaskHistoryStore(fileManager: fileManager).fileURL
        case .taskPlanDetails:
            return TaskPlanDetailStore(fileManager: fileManager).fileURL
        case .approvedApps:
            return ApprovedAppStore(fileManager: fileManager).fileURL
        }
    }
}
