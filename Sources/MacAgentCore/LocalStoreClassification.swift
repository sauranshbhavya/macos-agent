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

/// How Command Center's per-row Delete removes one store's contents.
///
/// **Two answers because a store is a *file* and a file can hold more than one kind of thing**
/// (SONNY-236, founder decision 2026-08-31). Every row deleted through
/// `LocalDataDeletionService.deleteStoreFilesOnly()` until `resumable-tasks.json` gained a second
/// collection, at which point a row labelled *Unfinished tasks* would have unlinked the file and
/// destroyed the user's standing watchers with it — a mislabelled delete, and one whose damage is
/// invisible in every direction: nothing fails, and the user is simply never told about a watched
/// page again. `CLAUDE.md`'s account of PR #110's F2 is that calling the wrong deletion door is
/// silent exactly this way.
///
/// **The unreadable case is deliberately not covered by this and must not be.** A collection-scoped
/// delete rewrites the file, which means decoding it — precisely what has failed for a store that
/// will not read. So an unreadable store goes to `LocalDataQuarantine` at file level whatever this
/// says. It is `deleteStoreFilesOnly()`'s own readable/unreadable asymmetry reaching one door
/// further.
///
/// **"Nothing is lost" is a claim about bytes and this comment used to make it without that
/// qualifier** (PR #184 review, F5). The bytes survive — quarantine keeps the file rather than
/// destroying it, so the watchers inside are set aside alongside the tasks. What does not survive is
/// the *watching*: the file leaves the path the checker reads, so every standing watcher in it stops
/// permanently and **none of the four endings fires**. That is a fifth, quiet ending, and it
/// contradicts the rule stated in three places — that a watcher which stops says so, because one
/// that dies quietly leaves the user believing it is still watching. It is also not `.cancelled`:
/// the user pressed a control about unfinished tasks. Recorded on SONNY-236 as a founder call rather
/// than decided here, since it is the same shape decision A ruled on for the readable path.
public enum LocalStoreRowDeletionScope: Equatable, Sendable {
    /// The row owns the whole file, so the press unlinks it. Twelve of the thirteen.
    case wholeFile
    /// The row owns one collection inside a file it shares, so the press rewrites the file without
    /// that collection and leaves the rest of it alone.
    case collectionWithinASharedFile
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
///   failed until each was classified here. Row 13's `output-locations.json` is the twelfth and
///   `resumable-tasks.json` the thirteenth (SONNY-209 and SONNY-210), and both arrived the same
///   way. The fourteenth will too.
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
    case outputLocations
    case resumableTasks

    /// Deliberately one `case` per store rather than three grouped ones: each line is a separate
    /// classification decision, and a reviewer should be able to disagree with exactly one of them.
    public var kind: LocalStoreKind {
        switch self {
        case .visionSessionJournal:
            // Row I's action journal: what the screen-control loop did and what it observed after
            // each action. A record *of* the run, never the point of it — and the most sensitive
            // trace of the twelve.
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
        case .outputLocations:
            // Row 13's common output locations (SONNY-209): which folders this run's files landed
            // in, kept so Sonny can offer a destination instead of guessing one. Nobody asked Sonny
            // to remember it — it is derived from where a task's own outputs went — which is the
            // founder's ground for `.trace` exactly.
            //
            // The same reading as `.recentArtifacts`, one level up: that store notes the file, this
            // one notes the folder, and both are notes *about* a run rather than the thing the run
            // was for. Suppressing it costs the user nothing they asked for: the files are still
            // written and still where they put them, and only the note about the folder is withheld.
            return .trace
        case .resumableTasks:
            // Row 13's unfinished runs (SONNY-210): what a task was partway through, kept so Sonny
            // can offer to carry on. A record *of* a run, and nobody asked for it — the same shape
            // as task history, which is what this hangs beside.
            //
            // The consequence is the one that decides it: a run with "Don't save this task" on
            // leaves no record, so it leaves no offer either. The alternative would have Sonny
            // raise "you were partway through X, continue?" for a task the user explicitly asked it
            // not to remember, which is the switch failing out loud rather than quietly.
            return .trace
        }
    }

    /// The file this store persists to, resolved through the store type itself so it is the same
    /// URL `LocalDataDeletionService.defaultStoreFileURLs()` resolves — by construction, not by a
    /// duplicated filename literal.
    public func fileURL(fileManager: FileManager = .default) -> URL {
        switch self {
        case .visionSessionJournal:
            return VisionSessionJournalStore.realFileURL(fileManager: fileManager)
        case .routines:
            return RoutineStore.realFileURL(fileManager: fileManager)
        case .workspaces:
            return WorkspaceStore.realFileURL(fileManager: fileManager)
        case .clipboardHistory:
            return ClipboardHistoryStore.realFileURL(fileManager: fileManager)
        case .clipboardHistorySettings:
            return ClipboardHistorySettingsStore.realFileURL(fileManager: fileManager)
        case .snippets:
            return SnippetStore.realFileURL(fileManager: fileManager)
        case .recentArtifacts:
            return RecentArtifactStore.realFileURL(fileManager: fileManager)
        case .shortcutRunHistory:
            return ShortcutRunHistoryStore.realFileURL(fileManager: fileManager)
        case .taskHistory:
            return TaskHistoryStore.realFileURL(fileManager: fileManager)
        case .taskPlanDetails:
            return TaskPlanDetailStore.realFileURL(fileManager: fileManager)
        case .approvedApps:
            return ApprovedAppStore.realFileURL(fileManager: fileManager)
        case .outputLocations:
            return OutputLocationStore.realFileURL(fileManager: fileManager)
        case .resumableTasks:
            return ResumableTaskStore.realFileURL(fileManager: fileManager)
        }
    }

    /// What this store's contents are called in the sentence Settings uses to say what the wipe
    /// takes (SONNY-233).
    ///
    /// **A list rather than a name, because a store is a *file* and a file can hold more than one
    /// kind of thing** (SONNY-236). Twelve of the thirteen return one phrase and always will; the
    /// thirteenth holds unfinished tasks and standing watchers in one file, and naming only the
    /// first would put the second inside an irreversible press with nothing on screen to say so.
    /// The alternative — one phrase reading "unfinished tasks and standing watchers" — keeps the
    /// property's old shape and produces "…, common output locations, and unfinished tasks and
    /// standing watchers", two conjunctions deep at the end of the one sentence in the product that
    /// most needs to be read.
    ///
    /// **The sentence was written by hand twice and was false both times.** Settings' detail line
    /// named ten of the thirteen stores the wipe deleted then and the confirmation dialog named nine —
    /// two surfaces describing one destructive action, disagreeing with each other and with the
    /// wipe. Neither omission was noticed when it happened, because nothing connected the words to
    /// `LocalDataDeletionService.defaultStoreFileURLs()`: a store was added, its file was added to
    /// the wipe, and the sentence stayed as it was. The three that had gone missing by the time this
    /// was written are what past tasks planned (row E), allowed apps (row J) and unfinished tasks
    /// (row 13); common output locations was missing from the dialog alone.
    ///
    /// **So the sentence is derived rather than maintained.** This switch is exhaustive with no
    /// `default`, the same guard `kind` and `memoryCategory` use, so a fourteenth store cannot reach
    /// the tree without being named here — and `theWipeReachesEveryLocalStore` already pins that
    /// `allCases` and the wipe's own file list are the same population, which closes the chain from
    /// the words to the files.
    ///
    /// **Lower case and standing alone**, because the sentence puts each of these mid-list. The
    /// wording is the user's rather than the file's, in the vocabulary the rest of the product
    /// already uses for these stores — the same choice `LocalStorageLoadFailureSource.label` makes.
    ///
    /// **Where the two overlap they agree on seven of eleven and differ on four, each deliberately**
    /// (PR #155 review, F3; this said they "say the same thing", which is false and invites a
    /// well-meant repair). The four are `routines` and `workspaces`, which the banner calls *saved
    /// routines* and *saved workspaces*; `clipboardHistorySettings`, *clipboard history settings*
    /// there and *clipboard settings* here; and `outputLocations`, *where your outputs usually go*
    /// there and *common output locations* here. **A banner names a thing standing alone and this
    /// sentence puts it mid-list among twelve others**, so the two want different lengths — "saved"
    /// distributes over the whole list here and cannot in a banner, and a sentence naming thirteen
    /// things has no room for a clause. Neither vocabulary is the other's to restore.
    public var deletionCopyNames: [String] {
        switch self {
        case .visionSessionJournal:
            return ["records of what Sonny did on screen"]
        case .routines:
            return ["routines"]
        case .workspaces:
            return ["workspaces"]
        case .clipboardHistory:
            return ["clipboard history"]
        case .clipboardHistorySettings:
            return ["clipboard settings"]
        case .snippets:
            return ["snippets"]
        case .recentArtifacts:
            return ["recent artifacts"]
        case .shortcutRunHistory:
            // Capitalised because Apple's app is: it is the name of a product, not of a Sonny
            // feature, and it is the one item in this list that is.
            return ["Shortcut run history"]
        case .taskHistory:
            return ["task history"]
        case .taskPlanDetails:
            // Named for what the user would notice going missing — a follow-up on a past task with
            // less to go on — rather than for the file. The same words
            // `LocalStorageLoadFailureSource` uses when this file will not read.
            return ["what past tasks planned"]
        case .approvedApps:
            return ["allowed apps"]
        case .outputLocations:
            return ["common output locations"]
        case .resumableTasks:
            // **Two phrases from one store, and it is the only one** (SONNY-236). This store's file
            // holds two collections — unfinished tasks and standing watchers — so a single name for
            // it would leave the wipe taking something its own sentence never mentions. Derived from
            // `ResumableTaskFileCollection.allCases` rather than written here, so a third collection
            // in that file reaches this sentence by existing; `theWipesOwnSentenceNamesEveryCollectionInEveryStore`
            // is what fails if one arrives without a name.
            return ResumableTaskFileCollection.allCases.map(\.wipeCopyName)
        }
    }

    /// What Command Center's per-row Delete does to this store, and the reasoning is on
    /// `LocalStoreRowDeletionScope`.
    ///
    /// Exhaustive with no `default`, the same guard `kind`, `memoryCategory` and `deletionCopyNames`
    /// use: a fourteenth store cannot reach the tree without somebody deciding whether its row owns
    /// its file. Answering that wrongly in the `.wholeFile` direction is how a row deletes a
    /// neighbour's data.
    public var rowDeletionScope: LocalStoreRowDeletionScope {
        switch self {
        case .visionSessionJournal,
             .routines,
             .workspaces,
             .clipboardHistory,
             .clipboardHistorySettings,
             .snippets,
             .recentArtifacts,
             .shortcutRunHistory,
             .taskHistory,
             .taskPlanDetails,
             .approvedApps,
             .outputLocations:
            return .wholeFile
        case .resumableTasks:
            // The one store whose file holds a second collection: `ResumableTaskFile` carries
            // standing watchers beside the unfinished tasks this row is named for.
            return .collectionWithinASharedFile
        }
    }
}
