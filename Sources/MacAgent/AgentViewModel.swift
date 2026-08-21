import AppKit
import Foundation
import MacAgentCore

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var command: String = ""
    @Published var isRunning: Bool = false
    @Published var plan: AgentPlan?
    @Published var finalSummary: String = ""
    @Published var errorMessage: String?
    /// Whether the current `errorMessage` is a persistent configuration problem (missing API key,
    /// denied mic permission, unavailable hotkey) that will keep being true until the user actually
    /// fixes their setup — as opposed to a transient, one-off outcome (a failed task, an empty
    /// transcription, a validation nudge) that's fully resolved by simply trying again. Only the
    /// latter auto-clears (see `FloatingWidgetView`'s failure-timeout) — the widget is a permanent,
    /// undismissable overlay, so a persistent problem needs to keep saying so, but a transient one
    /// sitting there forever after the moment has passed is exactly as stale as the bug this was
    /// built to fix. Set via `setError(_:persistent:)`, never assigned directly.
    @Published private(set) var errorIsPersistent: Bool = false
    @Published var clarificationQuestion: String?
    @Published var clarificationAnswer: String = ""
    @Published var suggestions: [RunSuggestion] = []
    @Published var stepStatuses: [String: AgentStepStatus] = [:]
    @Published var isPreparingVoiceRecording: Bool = false
    @Published var isRecordingVoice: Bool = false
    @Published var isTranscribingVoice: Bool = false
    @Published var voiceHotKeyStatus: String = "Hold Ctrl-Opt-Space"
    @Published var voiceHotKeyReady: Bool = true
    @Published var permissionItems: [PermissionReadinessItem] = []
    @Published var savedRoutines: [StoredRoutine] = []
    @Published var savedWorkspaces: [StoredWorkspace] = []
    @Published var approvalRequest: RiskApprovalRequest?
    /// The Safe-mode capture preview waiting for an answer, or `nil`. Safe mode only — founder
    /// decision 2 (2026-08-14) has Safe show each capture before it is sent.
    @Published var visionCapturePreview: VisionCapturePreview?
    /// What the running vision session is doing, for the HUD. `nil` when no session is live.
    @Published var visionSessionProgress: VisionSessionProgress?
    /// The delegation waiting for a Safe-mode answer, or `nil`. Safe mode only — founder decision 4
    /// (2026-08-14) has Safe ask before a delegation fires while Normal and Power never do.
    @Published var visionDelegationRequest: VisionDelegationRequest?
    /// A session paused because the user stopped being at the Mac, or `nil`. Resuming is an explicit
    /// action (SONNY-94): nothing here resolves on a timer or on the screen simply unlocking.
    @Published var visionSessionPause: VisionSessionPause?
    /// The ran-without-asking trace for the last completed run (SONNY-99, reshaped by the
    /// consequence rule 2026-08-13), or `nil` when the run's silence was ordinary — tier 0/1, a
    /// prompt that was answered, or a routine covered by its own trust toggle. The sentence itself
    /// comes from `AgentActivityPresentation.ranWithoutAskingLine` — pure and tested, because no
    /// SwiftUI inspection harness exists to pin what a view renders. Set only after a silent run
    /// actually executed (a run that drifted to a prompt was disclosed by the prompt), cleared at
    /// the start of every task, and untouched by the scheduled path, which never writes it.
    @Published private(set) var ranWithoutAskingTrace: String?
    @Published var clipboardHistoryEnabled: Bool = true
    @Published var priorTaskContext: PriorTaskContext?
    @Published var taskUsageSummary: TaskUsageSummary = .empty
    @Published var taskHistoryRecords: [CompletedTaskRecord] = []
    /// The Tasks page's search query.
    ///
    /// On the view model rather than local to the view, per `.claude/rules/macagent-ui-conventions.md`'s
    /// shared-state rule: both surfaces observe this one instance, and new page state lives here even
    /// when it feels surface-local. It also outlives a page switch, so a query survives a trip to
    /// Insights and back rather than silently clearing.
    ///
    /// Deliberately not persisted. A search is a thing the user is doing now, not a preference —
    /// reopening Sonny to a filtered task list with no memory of having typed anything would read as
    /// a bug.
    @Published var taskHistoryQuery: String = ""

    /// "Don't save this task" — whether the next run leaves traces (SONNY-120).
    ///
    /// **Per task, and reachable only before dispatch.** A Settings switch that stays on was
    /// declined by the founder on 2026-08-16: it is easy to forget and silently loses weeks of
    /// history for unrelated tasks. Flipping it mid-run is refused for a harder reason — it would
    /// promise to un-write records already on disk, which it cannot do. The widget enforces that by
    /// not offering the control while a task is in flight; `finishRecordingPolicyIfSettled()` is
    /// what puts it back to `.record` afterwards.
    ///
    /// Never applies to scheduled runs. A scheduled run passes through no composer, so there is no
    /// switch to have been left on — stated here so its absence does not read as a gap.
    @Published var taskRecordingPolicy: TaskRecordingPolicy = .record

    /// A finished run's summary, published for the notification fallback (SONNY-56).
    ///
    /// **Written only for a successful run whose origin is Command Center**, and that narrowness is
    /// the design rather than an oversight:
    ///
    /// - *Widget-origin runs* already show their result in the widget's own panel, which is a
    ///   permanent overlay and therefore on screen even while the user works elsewhere. Notifying
    ///   would be the duplicate the origin gate exists to prevent.
    /// - *Scheduled runs* have `scheduledRunNotice`, which already carries their summary and already
    ///   has its own notification subscription.
    /// - *Failures* already reach the user through `errorMessage`, which has its own subscription.
    ///   Publishing them here too would notify twice for one run.
    ///
    /// That leaves exactly the case the founder resolved on 2026-08-06: a run started from a Command
    /// Center row action, which reports its outcome on no surface at all.
    ///
    /// Transient — set at the moment a run succeeds and not persisted. SONNY-121 owns making a
    /// notified outcome survive until the user acknowledges it, and this is the signal it builds on.
    @Published var completedRunNotice: CompletedRunNotice?

    /// A request to open one task's detail dialog, set when the user clicks a finished-run
    /// notification (PR #67 review, F4). `CommandCenterView`'s Tasks page observes it and presents
    /// the same sheet a click on a history row opens.
    ///
    /// Published state rather than a direct call because the sheet is driven by view-local state the
    /// app delegate cannot reach, and `.claude/rules/macagent-ui-conventions.md`'s shared-state rule
    /// puts new cross-surface state on the one view model.
    @Published var taskDetailRequest: TaskDetailRequest?

    /// Opens a task's detail dialog by id, if that task is still in history.
    ///
    /// Returns `false` when the id resolves to nothing — a task deleted between the notification
    /// arriving and the click, or a suppressed run that never wrote a row. The caller decides what
    /// to do with that; this does not invent a fallback of its own.
    @discardableResult
    func requestTaskDetail(taskID: String) -> Bool {
        guard taskHistoryRecords.contains(where: { $0.id == taskID }) else {
            return false
        }
        taskDetailRequest = TaskDetailRequest(taskID: taskID)
        return true
    }

    /// Whether the outcome currently on screen is one the user was **notified** about (SONNY-121).
    ///
    /// The founder's decision of 2026-08-04: a notified outcome persists until acknowledged. The
    /// widget is a permanent overlay, so an outcome nobody acknowledged used to auto-collapse after
    /// six seconds and then be wiped by `clearStaleTaskOutcome()` — which is fine for an outcome the
    /// user watched happen, and wrong for one they were pulled away from. Clicking the notification
    /// after that landed on a compact capsule with nothing in it.
    ///
    /// **Why this is a flag and not a rule the view model can derive.** Being notified is a fact
    /// about the *user's attention* — Sonny was not the app they were working in — and only
    /// `AppDelegate` knows that, because the answer lives in `NSApp.isActive` and the widget panel's
    /// key state (see `SonnyAttention`). So the delegate that posts the notification is what records
    /// that it happened.
    ///
    /// **Acknowledged means the user acted**, not that the widget came forward: it clears when they
    /// retry or submit another command, and deliberately *not* when the panel is merely fronted.
    /// Being on screen is not the same as being read, which is this ticket's whole premise.
    @Published private(set) var outcomeWasNotified: Bool = false

    /// Records that the outcome now on screen reached the user as a notification. Called by
    /// `AppDelegate` immediately after it posts one, because the gate that decided to post is its
    /// to evaluate.
    func markOutcomeAsNotified() {
        outcomeWasNotified = true
    }
    /// Local-storage health, kept deliberately separate from `errorMessage`: a corrupt store or
    /// a failed save is about Sonny's own data, not about the task the user just ran, and must
    /// never make a successful task read as failed. Rendered as its own notice on both surfaces.
    @Published var localStorageNotice: String?
    /// What the scheduler did while nobody was watching — a routine ran, or was skipped and why.
    ///
    /// Its own channel rather than `errorMessage` or `localStorageNotice`, following the split this
    /// project already draws: `errorMessage` means "the task *you ran* failed", and a scheduled run
    /// is not one; `localStorageNotice` means "something ambient needs your attention", which is the
    /// right shape but the wrong subject. A user has to be able to tell "my 9am routine didn't run"
    /// apart from "your snippets file is corrupt", because the two need different actions.
    ///
    /// Carries successes too, not just skips: an action taken with nobody watching should be
    /// visible after the fact, which is the whole reason unattended execution needs a surface.
    @Published var scheduledRunNotice: String?
    /// The planner router could not honor the configured planner selection and used the
    /// default instead — who actually planned the task, and why (SONNY-85). Its own channel
    /// for the same reason `scheduledRunNotice` has one: the subject is neither a failed task
    /// (`errorMessage` — the task went on to run) nor Sonny's own data (`localStorageNotice`).
    /// Set by `performStart` when the registry reports a fallback, cleared at the next
    /// dispatch — the notice describes the current task's planning, and a stale one would
    /// claim a swap that never happened. A planner swap must never be silent, so the widget
    /// renders this as its own dismissible strip.
    @Published var plannerFallbackNotice: String?
    @Published var localDataDeletionStatusMessage: String?
    /// Set on every `start()`. Approving a pending run genuinely does not touch it —
    /// `performApproval` reuses the existing prepared run. A clarification answer *does* go back
    /// through `start()` and reassign this, but `submitClarification()` passes the preserved
    /// original origin, so the observable value still doesn't change across the pause. See
    /// `TaskOrigin`.
    @Published private(set) var activeTaskOrigin: TaskOrigin = .commandCenter
    /// Bump counter every hand-driven "bring the widget forward and take focus" entry point goes
    /// through — Command Center's "New routine"/"Create workspace" quick actions (which pre-fill
    /// `command` with a starting phrase and need somewhere for the user to finish typing it, now
    /// that Command Center has no composer of its own), the status menu's "New Task" item, and the
    /// push-to-talk hotkey (both via `AppDelegate.requestWidgetPresentation()`). `AppDelegate`
    /// observes this to call `widgetController.show()`; `FloatingWidgetView` observes it to focus
    /// its text field — every caller reacting through the same shared state rather than reaching
    /// into AppKit/the widget directly, since `show()` alone cannot move keyboard focus.
    @Published var widgetPresentationRequest: Int = 0
    @Published var usePointerCursors: Bool = true {
        didSet {
            userDefaults.set(usePointerCursors, forKey: UserDefaultsKeys.usePointerCursors)
        }
    }
    @Published var displayFullNames: Bool = false {
        didSet {
            userDefaults.set(displayFullNames, forKey: UserDefaultsKeys.displayFullNames)
        }
    }
    /// Gates the widget's one-time first-approval explainer copy (branch 9 checkpoint 8, split
    /// 2026-07-24 — see `docs/sonny-founder-design-decisions.md`). Flips permanently the first time
    /// the user resolves *any* approval, allow or deny — "shown once, ever," not "shown until
    /// dismissed." `private(set)`: only `performApproval`/`cancelCurrentRun`'s deny branch, the two
    /// real resolution points, should ever flip it — plus `markFirstApprovalCompleted()`, the third,
    /// added by row I for a mid-loop vision approval. The setter stays `private(set)` and that third
    /// point is a named door rather than a widened setter, so the list of things that may flip this
    /// is still enumerable by reading this comment.
    @Published private(set) var hasCompletedFirstApproval: Bool = false {
        didSet {
            userDefaults.set(hasCompletedFirstApproval, forKey: UserDefaultsKeys.hasCompletedFirstApproval)
        }
    }

    let logStore = AgentLogStore()

    private var preparedRun: PreparedAgentRun?
    private var runner: AgentRunner?
    private var currentTask: Task<Void, Never>?
    /// The parked mid-loop vision approval, and the parked Safe-mode capture preview.
    ///
    /// `var` rather than `private var` so the vision extension in
    /// `AgentViewModel+VisionSession.swift` can reach them — Swift's `private` is file-scoped, and
    /// the alternative was putting 200 lines of vision code in this 2,600-line file.
    var visionApprovalContinuation: CheckedContinuation<RiskApprovalDecision?, Never>?
    var visionCaptureContinuation: CheckedContinuation<Bool, Never>?
    var visionDelegationContinuation: CheckedContinuation<Bool, Never>?
    var visionResumeContinuation: CheckedContinuation<Bool, Never>?
    /// The wrapper the HUD's Pause writes to, held so the resume path can clear it. Set when the
    /// vision environment is built; `nil` in a build with no screen-control wiring.
    var visionUserPauseMonitor: UserPausableAttentionMonitor?
    /// Registered only while a session is live — a permanently-held global shortcut is a key
    /// combination taken from every other app forever, in exchange for a control that matters for
    /// the seconds Sonny is actually moving the cursor.
    var visionEmergencyStopHotKey: (any EmergencyStopHotKeyRegistering)?
    /// How the emergency-stop hotkey is built. Injected so a test can pin the *wiring* — that a live
    /// session really registers one and every exit releases it — without any test taking a real
    /// global shortcut. Defaults to the real Carbon registration.
    var visionEmergencyStopHotKeyFactory: (@MainActor (@escaping @MainActor () -> Void) throws -> any EmergencyStopHotKeyRegistering) = { onStop in
        try EmergencyStopHotKey(onStop: onStop)
    }
    /// The journal id of the session this task is running, or `nil`. Read once when the task's
    /// history row is written, then cleared with the rest of the per-task state.
    var activeVisionSessionID: String?
    private let audioRecorder: AudioCommandRecorder
    private let permissionReadinessService: PermissionReadinessService
    private let routineStore: RoutineStore
    private let workspaceStore: WorkspaceStore
    private let snippetStore: SnippetStore
    private let recentArtifactStore: RecentArtifactStore
    private let shortcutCatalog: any ShortcutCatalogProviding
    // Every seam `AgentActionExecutor` exposes that reaches the real machine. Held here and
    // forwarded in `makeExecutor()` so a test can supply fakes: before this, `makeExecutor` passed
    // none of them, so each fell to its production default and any view-model test that *executed*
    // a plan drove the real system — a user watching the suite run saw Safari launch and real URLs
    // open in their browser. `AgentActionExecutor` already had every one of these as an injectable
    // parameter; only this construction path was skipping them.
    private let browserOpener: any BrowserOpening
    private let appOpener: any AppOpening
    private let fileOpener: any FileOpening
    private let mediaOpener: any MediaOpening
    private let runningAppSwitcher: any RunningAppSwitching
    private let shortcutInvoker: any ShortcutInvoking
    private let finderContextReader: any FinderContextReading
    private let documentConverter: any DocumentConverting
    private let zipArchiver: any ZipArchiving
    private let shortcutRunHistoryStore: ShortcutRunHistoryStore
    private let taskHistoryStore: TaskHistoryStore
    /// What each finished task planned (row E, SONNY-147) — the heavy half of a task's record, kept
    /// beside `task-history.json` rather than inside it so the file that is read on every list
    /// render, search and Insights pass stays small. Not `private`: SONNY-150's follow-up reads it
    /// back to rehydrate a `PriorTaskContext`, and the tests read it to assert what was written.
    let taskPlanDetailStore: TaskPlanDetailStore
    /// The action journal (row I, SONNY-96). Injected like every other store so a test writes to its
    /// own file rather than the user's.
    let visionSessionJournalStore: VisionSessionJournalStore
    private let clipboardHistorySettingsStore: ClipboardHistorySettingsStore
    /// Row J's per-app control grants (SONNY-140). Injected like every other store so a test writes
    /// to its own file rather than the user's. Nothing gates on it yet — SONNY-143 is what reads it
    /// — so the only thing this view model does with it today is probe it for load failures, which
    /// is the same wiring the other silently-read stores get.
    private let approvedAppStore: ApprovedAppStore
    private let clipboardHistoryMonitor: ClipboardHistoryMonitor
    private let localDataDeletionService: LocalDataDeletionService
    private let priorTaskContextStore: PriorTaskContextStore
    private let taskUsageRecorder: TaskUsageRecorder
    private let plannerProviderRegistry: PlannerProviderRegistry
    /// Which registered planner provider plans tasks. Environment-backed in production
    /// (`SONNY_PLANNER`, read once at init — the environment cannot change under a running
    /// process); mutable so tests can drive both the honored and fallback selection paths
    /// through one view model.
    var plannerSelection: String?
    private let userDefaults: UserDefaults
    /// The one whitelist every path this view model owns reasons with. Injectable so the
    /// ProductShell suite can drive the *real* dispatch path against a temp directory — the class
    /// of end-to-end coverage whose absence let a mapping-level green suite coexist with a live
    /// app that behaved differently (the 2026-08-13 manual-pass finding). `makeExecutor()` and
    /// `resolveTaskScope` both read it, so the assessment and the scope agree on what a path is.
    private let whitelist: PathWhitelist
    private var clipboardHistoryTimer: Timer?
    private var routineScheduleTimer: Timer?
    /// Label for the currently-running scheduled routine. Separate from `lastCommand` so a
    /// background run can drive the running indicator without becoming the retry or follow-up
    /// target — see `performScheduledRun`.
    private var scheduledRunDisplayCommand: String?
    private var wakeObserver: (any NSObjectProtocol)?
    private var clarificationAutoExecute = false
    /// Preserves the original task's origin across the clarification pause, same pattern as
    /// `clarificationAutoExecute` — `submitClarification()`
    /// re-calls `start()`, which would otherwise silently reset origin to its default.
    private var clarificationOrigin: TaskOrigin = .commandCenter
    /// The workspace this **in-flight task** is bound to, and the value handed to both
    /// `AgentRunner.approvalRequest` and `AgentRunner.execute`.
    ///
    /// Per task, never a mode. The persistent "active workspace" concept was considered and
    /// rejected (see the changelog's task-to-workspace-association entry, and the note at
    /// `CommandCenterView.swift:381-384`) because it silently mis-tags unrelated one-off tasks and
    /// leaks across surfaces — a voice command in the widget inheriting whatever workspace was last
    /// open in Command Center. **The entire difference between this and the rejected design is
    /// lifecycle**, so the lifecycle is written down rather than implied: set once per task in
    /// `performStart` after the plan exists, held across an approval or clarification pause because
    /// those are the same task resuming, and cleared at every terminal state.
    /// `private(set)` internal rather than fully private, matching `activeTaskOrigin`: the lifecycle
    /// *is* the feature here, so it has to be assertable. Nothing outside this type may set it.
    /// `@Published` because the widget's binding chip renders off it through `boundWorkspaceName`.
    /// It was `private(set) var` alone, and the chip's disappearance at task end worked only because
    /// every `activeTaskScope = .unscoped` site happens to sit in the same synchronous scope as some
    /// other published write (`isRunning`, `approvalRequest`). Nothing in the type system held that
    /// pairing, so the chip's correctness was incidental.
    @Published private(set) var activeTaskScope: TaskWorkspaceScope = .unscoped
    /// The scope the most recent task was *assessed* under, kept after `activeTaskScope` is cleared.
    ///
    /// `activeTaskScope` is the live binding and is `.unscoped` again the moment a task terminates,
    /// which is correct but makes the value unobservable exactly when a test wants to check it. This
    /// records what the run actually used. Not consumed by any view — it exists so the binding's
    /// behaviour is assertable rather than inferred from a side effect.
    private(set) var lastAssessedScope: TaskWorkspaceScope = .unscoped

    /// The workspace the composer is currently bound to, for the widget's indicator — the in-flight
    /// binding once a task is running, otherwise the one a card dispatch queued for the next
    /// command. `nil` means unbound, and the indicator disappears.
    var boundWorkspaceName: String? {
        if case .scoped(let scope) = activeTaskScope {
            return scope.workspaceName
        }
        return pendingWorkspaceBinding
    }
    /// A binding supplied by a dispatch that already knows its workspace — B4's workspace-card
    /// action. Wins over the free-text path when both are present.
    ///
    /// `nil` means "no dispatch named one", which is honestly the case for every caller today and is
    /// why this default is safe where a defaulted `scope:` would not be: `nil` does not switch a
    /// check off, it hands the question to `WorkspaceTaskTagging` instead.
    private var explicitWorkspaceBinding: String?
    /// Preserves the explicit binding across a clarification pause, exactly as
    /// `clarificationOrigin` preserves the origin — `submitClarification()` re-enters `start()`,
    /// which would otherwise drop it.
    private var clarificationWorkspaceBinding: String?
    /// The workspace a card dispatch named for the **next** command, before one has been typed.
    ///
    /// A pre-dispatch slot, not a second lifecycle: `start()` consumes it into SONNY-38's
    /// `explicitWorkspaceBinding` — the same slot the free-text path already loses to — and clears
    /// it in the same breath, after which the binding is the in-flight one and clears where every
    /// other terminal clear happens. `boundWorkspaceName` reads whichever of the two is live, so the
    /// widget's indicator survives the hand-off without either value having to know about the other.
    ///
    /// Published because the widget renders it; deliberately *not* persisted and deliberately not
    /// readable anywhere outside the in-flight composer — the rejected persistent-active-workspace
    /// design is exactly what this must not become.
    @Published var pendingWorkspaceBinding: String?
    /// Which surface's mic button started the in-progress recording, set explicitly by the caller
    /// rather than inferred. Read back when voice transcription auto-submits, so that submission is
    /// attributed correctly.
    ///
    /// **There is one mic button, the widget's.** This used to say `toggleVoiceRecording()` "is
    /// called identically from both Command Center's composer and the floating widget's own mic
    /// button"; that composer was deleted on 2026-07-21 and the sentence outlived it. Corrected by
    /// PR #73's review (F3), which caught it precisely because SONNY-173 had corrected the *same*
    /// claim at the method's own doc comment 1200 lines below and left this copy standing — a
    /// compiler probe enumerates call sites, and no probe reads prose. A repo-wide sweep at that
    /// point found no third copy: every other mention of that composer already says it is gone.
    ///
    /// The `.commandCenter` initial value is never observed — `startVoiceRecording` assigns this
    /// before the single read in `stopVoiceRecordingAndTranscribe`'s completion — and is kept only
    /// to match `toggleVoiceRecording(origin:)`'s own default, which is documented there as the
    /// direction that consumes no pending workspace-card binding.
    private var voiceRecordingOrigin: TaskOrigin = .commandCenter
    /// The last command text actually submitted for real execution — tracked on the shared view
    /// model (not as widget-local UI state) so both the widget's own retry button and a system
    /// notification's "Retry" action, which fires from outside SwiftUI entirely, can resubmit it.
    /// `private(set)` rather than `private`: the setter stays inside this type, but the getter is
    /// readable so a test can assert what a dispatch actually *submitted*. `start` clears `command`
    /// synchronously right after capturing it, so the live property is empty by the time any caller
    /// returns — this is the only observable record of the text a run was started with.
    private(set) var lastCommand = ""
    private var isPushToTalkHotKeyDown = false
    private var pendingCommandForPriorTaskContext: String?
    private var pendingTaskHistoryStartedAt: Date?
    private var preserveUsageForNextStart = false
    private var localStorageLoadFailures: [LocalStorageLoadFailureSource: String] = [:]
    /// Last clipboard-poll failure text, so a repeating 1s failure is reported once, not 60×/min.
    private var clipboardHistoryPollFailure: String?

    private enum LocalStorageLoadFailureSource: CaseIterable, Hashable {
        case savedRoutines
        case savedWorkspaces
        case clipboardHistorySettings
        case clipboardHistoryItems
        case taskHistory
        case taskPlanDetails
        case snippets
        case recentArtifacts
        case approvedApps

        var label: String {
            switch self {
            case .savedRoutines:
                return "saved routines"
            case .savedWorkspaces:
                return "saved workspaces"
            case .clipboardHistorySettings:
                return "clipboard history settings"
            case .clipboardHistoryItems:
                return "clipboard history"
            case .taskHistory:
                return "task history"
            case .taskPlanDetails:
                // Named for what the user would notice if it will not read: a follow-up on a past
                // task with less to go on. "Task plan details" is the file's name, not theirs.
                return "what past tasks planned"
            case .snippets:
                return "snippets"
            case .recentArtifacts:
                return "recent artifacts"
            case .approvedApps:
                return "allowed apps"
            }
        }
    }

    private enum VoiceRecordingTrigger {
        case button
        case hotKey
    }

    /// Which surface actually submitted the currently-relevant task — the shared `AgentViewModel`
    /// has no such concept until now, which was the real cause of the floating widget rendering
    /// its own duplicate progress/result panel for tasks submitted through Command Center's own
    /// composer: both surfaces observe the exact same `isRunning`/`finalSummary`/etc. with no way
    /// to tell which one actually initiated the current activity.
    enum TaskOrigin {
        case commandCenter
        case widget
        /// Started by the routine scheduler with nobody watching. Deliberately its own case rather
        /// than borrowing `.commandCenter`: the widget gates its working/result panel on
        /// `.widget`, so a scheduled run correctly shows no progress panel there while its
        /// permission/clarification/failure states — the ones that actually need a human — still
        /// surface on both surfaces. It also drives the `.scheduled` task-history trigger, which
        /// keeps automated runs out of the Insights streak.
        case scheduled
    }

    private enum UserDefaultsKeys {
        static let usePointerCursors = "com.sonny.preferences.usePointerCursors"
        static let displayFullNames = "com.sonny.preferences.displayFullNames"
        static let hasCompletedFirstApproval = "com.sonny.state.hasCompletedFirstApproval"
        static let interactionMode = "com.sonny.preferences.interactionMode"
    }

    /// The environment variable naming which registered planner provider plans tasks —
    /// same env-backed shape as `OPENAI_API_KEY`/`OPENAI_MODEL`, and the same variable name
    /// the experiment era used, so the founder's existing launch incantation keeps working.
    /// Unset means the registry default (OpenAI).
    nonisolated static let plannerSelectionEnvironmentKey = "SONNY_PLANNER"

    init(
        audioRecorder: AudioCommandRecorder = AudioCommandRecorder(),
        permissionReadinessService: PermissionReadinessService = PermissionReadinessService(),
        routineStore: RoutineStore = RoutineStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        snippetStore: SnippetStore = SnippetStore(),
        recentArtifactStore: RecentArtifactStore = RecentArtifactStore(),
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        browserOpener: any BrowserOpening = WorkspaceBrowserOpener(),
        appOpener: any AppOpening = WorkspaceAppOpener(),
        fileOpener: any FileOpening = WorkspaceFileOpener(),
        mediaOpener: any MediaOpening = NativeMediaOpener(),
        runningAppSwitcher: any RunningAppSwitching = WorkspaceRunningAppSwitcher(),
        shortcutInvoker: any ShortcutInvoking = ProcessShortcutInvoker(),
        finderContextReader: any FinderContextReading = AppleScriptFinderContextReader(),
        documentConverter: any DocumentConverting = AutoDocumentConverter(),
        zipArchiver: any ZipArchiving = ProcessZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore = ShortcutRunHistoryStore(),
        taskHistoryStore: TaskHistoryStore = TaskHistoryStore(),
        taskPlanDetailStore: TaskPlanDetailStore = TaskPlanDetailStore(),
        visionSessionJournalStore: VisionSessionJournalStore = VisionSessionJournalStore(),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore = ClipboardHistorySettingsStore(),
        approvedAppStore: ApprovedAppStore = ApprovedAppStore(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor? = nil,
        localDataDeletionService: LocalDataDeletionService = LocalDataDeletionService(),
        priorTaskContextStore: PriorTaskContextStore = PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder = TaskUsageRecorder(),
        plannerProviderRegistry: PlannerProviderRegistry = .default,
        plannerSelection: String? = ProcessInfo.processInfo
            .environment[AgentViewModel.plannerSelectionEnvironmentKey],
        userDefaults: UserDefaults = .standard,
        whitelist: PathWhitelist = PathWhitelist()
    ) {
        self.userDefaults = userDefaults
        usePointerCursors = userDefaults.object(forKey: UserDefaultsKeys.usePointerCursors) as? Bool ?? true
        displayFullNames = userDefaults.object(forKey: UserDefaultsKeys.displayFullNames) as? Bool ?? false
        hasCompletedFirstApproval = userDefaults.object(forKey: UserDefaultsKeys.hasCompletedFirstApproval) as? Bool ?? false
        // Missing or unrecognized raw value falls to Normal — the ratified product default, so
        // the missing-key default and the product default agree (the reason the boolean
        // predecessor deviated from the `?? true` preference convention, carried forward).
        interactionMode = AgentInteractionMode(
            rawValue: userDefaults.string(forKey: UserDefaultsKeys.interactionMode) ?? ""
        ) ?? .normal
        self.audioRecorder = audioRecorder
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.snippetStore = snippetStore
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.browserOpener = browserOpener
        self.appOpener = appOpener
        self.fileOpener = fileOpener
        self.mediaOpener = mediaOpener
        self.runningAppSwitcher = runningAppSwitcher
        self.shortcutInvoker = shortcutInvoker
        self.finderContextReader = finderContextReader
        self.documentConverter = documentConverter
        self.zipArchiver = zipArchiver
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.taskHistoryStore = taskHistoryStore
        self.taskPlanDetailStore = taskPlanDetailStore
        self.visionSessionJournalStore = visionSessionJournalStore
        self.clipboardHistorySettingsStore = clipboardHistorySettingsStore
        self.approvedAppStore = approvedAppStore
        self.clipboardHistoryMonitor = clipboardHistoryMonitor
            ?? ClipboardHistoryMonitor(settingsStore: clipboardHistorySettingsStore)
        self.localDataDeletionService = localDataDeletionService
        self.priorTaskContextStore = priorTaskContextStore
        self.taskUsageRecorder = taskUsageRecorder
        self.plannerProviderRegistry = plannerProviderRegistry
        self.plannerSelection = plannerSelection
        self.whitelist = whitelist
    }

    var hasAPIKey: Bool {
        !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var modelName: String {
        ProcessInfo.processInfo.environment["OPENAI_MODEL"] ?? "gpt-5.5"
    }

    var transcriptionModelName: String {
        ProcessInfo.processInfo.environment["OPENAI_TRANSCRIBE_MODEL"] ?? "gpt-4o-mini-transcribe"
    }

    /// True while a task occupies the app: running, waiting on an approval, or **paused on a
    /// clarification the user has not answered**.
    ///
    /// The third term is the one that keeps getting left out. A clarification pause looks idle from
    /// the outside — `performStart`'s defer sets `isRunning = false` and `approvalRequest` is nil —
    /// so a gate written as `isRunning || isAwaitingApproval` is live during exactly the state where
    /// a second dispatch destroys the first task's continuation.
    ///
    /// `FloatingWidgetView` computes this same expression privately. It is not consolidated here as
    /// part of this change because that file is on SONNY-41's never-touch list; hoisting the
    /// widget's copy onto this property is that file's owner's call, and the two agree today.
    var isTaskInFlight: Bool {
        isRunning || isAwaitingApproval || clarificationQuestion != nil
    }

    /// Hands `start` a command on behalf of a *programmatic* caller, and guarantees that a refused
    /// dispatch leaves no text behind.
    ///
    /// **The invariant: after any refused dispatch, a subsequent `submitClarification` interpolates
    /// only the question and the answer.** `submitClarification` wraps its Q&A around whatever
    /// `command` currently holds, so any caller that writes `command` and *then* gets refused turns
    /// the next continuation into a hybrid — re-planned, under the paused task's own captured
    /// binding, against the wrong workspace's boundary. Adding the clarification term to `canSubmit`
    /// fixed the discard at every door and moved this residue to three of them.
    ///
    /// **One mechanism, chosen over moving each assignment above its guard.** A caller cannot
    /// evaluate the real guard before assigning: `canSubmit`'s own emptiness term reads `command`,
    /// so a pre-assignment check would have to be a *partial* copy of the rule at every call site —
    /// the per-surface duplication that let this class reach the assembled head twice already.
    /// Detecting the outcome needs no copy of the rule at all, and it covers refusal reasons nobody
    /// has enumerated yet: `start` clears `command` synchronously the instant it accepts a dispatch,
    /// so finding the text still there means the guard refused and the text is residue.
    ///
    /// **A programmatic dispatch is never an approval.** `start()`'s first branch turns a call made
    /// while `isAwaitingApproval` into `approvePendingRun()` — correct for the composer's Send
    /// button, which is the control the widget relabels for exactly that job, and wrong for every
    /// caller here, none of which is that button.
    ///
    /// **The five doors, enumerated, because a guard in a shared helper is a claim about all of
    /// them** — and the first version of this comment named two:
    /// - `dispatchTranscribedCommand` — **the one with the most at stake.** `canUseVoice` blocks
    ///   *starting* a recording while an approval is pending, but an approval can land during the
    ///   recording or the transcription, and the finished transcript then went straight into
    ///   `start()`. A sentence the user spoke about something else would have landed as a silent
    ///   *allow* on whatever tier-3 action was waiting.
    /// - `openWorkspaceWidget`, `runRoutineWidget` — behaviour-changed, neither gated for this
    ///   before. `runRoutineWidget`'s button lives in `RoutineDetailView`, a different file.
    /// - `dispatchWorkspaceScopeEdit` — the sheet's door, the one this ticket built.
    /// - `retryLastCommand` — **unaffected.** Its own `!isTaskInFlight` guard is a strict superset
    ///   of this one and fires before `dispatch` is reached.
    ///
    /// **What makes it reachable is timing, not an unattended run.** An earlier telling of this said
    /// a scheduled routine raises approvals with nobody watching; it does not. `performScheduledRun`
    /// executes with `approvalDecision: .approved(.tier2)` and routes every `RiskApprovalError` to
    /// `pauseSchedule` plus a notice — SONNY-31's ratified notify-and-pause design — so it never
    /// writes `approvalRequest` at all. The real routes are both in the foreground: any run a user
    /// started pausing at its approval (`performStart`), and `performApproval`'s stale-approval
    /// re-arm when a re-assessment lands higher than the tier already approved. Either can arrive
    /// between a render and a tap, which is all this needs — a cheap structural guard on a trust
    /// boundary does not need an exotic trigger, and claiming one it does not have made the guard
    /// look better-motivated than the evidence supports. (PR #40 review, F4.)
    ///
    /// The guard is here, at the one helper every programmatic caller shares, rather than as a
    /// fifth copy on a fifth button.
    ///
    /// - Returns: whether the dispatch was accepted, so a caller can tell a refusal apart from a
    ///   submission without re-deriving `canSubmit`'s rule.
    @discardableResult
    private func dispatch(
        command commandText: String,
        autoExecute: Bool = false,
        origin: TaskOrigin = .commandCenter,
        workspaceBinding: String? = nil,
        fromComposer: Bool = false,
        prebuiltPlan: AgentPlan? = nil,
        prebuiltPlanSource: PreparedPlanSource = .directUserAction
    ) -> Bool {
        guard !isAwaitingApproval else {
            logStore.append(.observe, "Not started: an approval is still waiting for your answer.")
            return false
        }
        command = commandText
        start(
            autoExecute: autoExecute,
            origin: origin,
            workspaceBinding: workspaceBinding,
            fromComposer: fromComposer,
            prebuiltPlan: prebuiltPlan,
            prebuiltPlanSource: prebuiltPlanSource
        )
        guard command == commandText else {
            return true
        }
        command = ""
        // Every refused dispatch leaves a trace, at the one place every programmatic door passes
        // through. Three of the five doors logged a refusal of their own and two did not — voice
        // being the one that mattered, since it discards this result and its caller had already
        // announced that Sonny was about to act. A per-door copy is what produced that gap; this is
        // the same choke-point argument the clarification term is placed by.
        //
        // Cause-neutral on purpose. `canSubmit` refuses for a running task, an open clarification, a
        // transcription in flight, and an empty command — and the last of those already has its own
        // user-facing error from `start`. A line naming one cause would be wrong for the others,
        // which is the defect the sheet's own removed message had. (PR #40 review, F5.)
        logStore.append(.observe, "Not started: Sonny was not ready to begin another task.")
        return false
    }

    /// Fills the widget composer with a ready-made command and brings the widget forward, refusing
    /// while a clarification is open.
    ///
    /// The compose half of the same invariant. These callers never reach `start`, so `dispatch`
    /// cannot cover them — but they write `command` just the same, and a partial command
    /// ("Create a workspace called ") left in a live pause corrupts the continuation exactly as a
    /// refused dispatch would. Guard first, assign second — the ordering the sheet's own
    /// `composeWorkspaceScopeEdit` had, which was the one door genuinely closed at the time. That
    /// function is gone as of SONNY-64 (the sheet dispatches now), so this is the last door of that
    /// shape left, and the ordering is its own reason rather than a sibling's precedent.
    func composeCommand(_ commandText: String) {
        guard clarificationQuestion == nil else {
            logStore.append(.observe, "Composer prefill ignored while a clarification is open.")
            return
        }
        command = commandText
        widgetPresentationRequest += 1
    }

    /// **The clarification term lives here, at the dispatch choke point, rather than on each
    /// surface's button gate.**
    ///
    /// `start(...)` is the only route into `performStart`, and it is the only caller — so one term
    /// here refuses every dispatch that would otherwise discard an unanswered clarification:
    /// `openWorkspaceWidget`, `runRoutineWidget` (whose button lives in a different file entirely),
    /// the composer submit, and any dispatch added later. The alternative — a term on each card gate
    /// — is one copy per surface and a silent gap the first time a fourth card action is added,
    /// which is how this reached the assembled head with the voice half closed and the card half
    /// open.
    ///
    /// It does not break the continuation: `submitClarification` clears `clarificationQuestion`
    /// *before* re-entering `start`, so answering proceeds exactly as it did. And it is what makes
    /// `performStart`'s unconditional `clarificationQuestion = nil` unreachable by bypass rather
    /// than merely unreached — every path to it now passes this guard.
    var canSubmit: Bool {
        if isAwaitingApproval {
            return !isRunning && preparedRun != nil && runner != nil
        }
        return !isRunning && clarificationQuestion == nil && !isTranscribingVoice
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `cancelCurrentRun()` would actually end something — true in exactly the states it
    /// has a branch for, so the predicate and the function cannot disagree.
    ///
    /// **The clarification term is SONNY-166's, and its absence was the bug's sharpest edge.** A
    /// clarification pause has `isRunning == false` (`performStart`'s defer has fired) and
    /// `approvalRequest == nil`, so the old two-term expression was false throughout it: the view
    /// model did not merely fail to *offer* a way out, it reported that there was none. The exit now
    /// exists, so the predicate says so.
    ///
    /// **This adds no control to Command Center's running indicator, deliberately.**
    /// `CommandCenterRunningIndicator` is the only reader, and all four of its call sites are
    /// wrapped in `if viewModel.isRunning || viewModel.isAwaitingApproval` — both false during a
    /// clarification — so the indicator does not render at all in this state and its Cancel button
    /// cannot appear. That is the right outcome twice over: the indicator would otherwise say
    /// "Running: …" about a task that is not running, and the clarification's own exit lives on the
    /// panel that is asking the question, on both surfaces. Pinned by
    /// `theRunningIndicatorStaysAbsentDuringAClarification`.
    var canCancel: Bool {
        isAwaitingApproval || clarificationQuestion != nil || (isRunning && currentTask != nil)
    }

    /// The message shown when voice is asked for and the app is not configured to do it.
    ///
    /// One copy, because three surfaces must say the same thing: the widget's mic button, the
    /// push-to-talk hotkey, and — since SONNY-177 — the mic's hover hint, which reaches it through
    /// `micHoverHintPresentation` rather than holding a second string of its own. The first two said
    /// the same thing by coincidence — two identical literals — until one of them stopped saying
    /// anything at all (SONNY-173).
    ///
    /// **Provider-neutral by founder decision, 2026-08-19 (SONNY-177), wording approved the same
    /// day.** No provider name and no environment-variable name: other providers are coming, and
    /// SONNY-136 deletes every provider environment variable, so anything more specific written here
    /// is copy already scheduled for deletion. Naming the variable was the more actionable sentence
    /// today and that cost was accepted deliberately — the audience is two founders who already know
    /// what it means, and the specificity survives in one place, the Settings › Security & Access
    /// readiness row, which is SONNY-136's to rewrite. What the trade may not cost is the
    /// instruction: this still names the action class — add a key, relaunch — so a reader is left
    /// with something to do rather than a statement of fact.
    static let missingAPIKeyVoiceMessage =
        "No API key is set up. Add one, then relaunch Sonny."

    /// What the mic's hover hint says when voice actually works. It lives here, rather than as a
    /// literal in `FloatingWidgetView`, so that *choosing* between this and the configuration
    /// message happens in one place — see `micHoverHintPresentation`.
    ///
    /// **The founder's own wording, given verbatim on SONNY-179, 2026-08-19.** It replaces "Speak
    /// your command — or hold Ctrl-Opt-Space anywhere". The em dash goes, and no comma takes its
    /// place: two clauses this short do not need one. Copy is his, so this string is not a sentence
    /// to improve on session judgment.
    static let micHoverShortcutReminder = "Click to speak or hold Ctrl-Opt-Space."

    /// How long the shortcut reminder stays, and nothing else. The configuration message has no
    /// delay at all rather than a longer one, which is why this is not a general "hint duration".
    ///
    /// Three seconds since SONNY-179, down from the four SONNY-177 shipped — the founder's pass at
    /// the packaged app, and his call to make.
    static let micHoverReminderDismissDelay: Duration = .seconds(3)

    /// The mic's hover hint, resolved: the sentence to render and whether it clears itself.
    ///
    /// **Resolved here for the same reason `isVoiceControlDisabled` is.** A view may read neither
    /// half of voice readiness, so it cannot pick between these two messages for itself; it receives
    /// the answer already made. The guard is `theCompositeVoiceReadinessIsReadInOneFileOnly`.
    ///
    /// **The unconfigured variant renders the very text the mic press shows, rather than a second
    /// string of its own.** One condition on one control must not speak with two voices, and taking
    /// the words from the same place the press takes them makes that structural instead of a
    /// convention someone has to keep remembering — a rewrite cannot leave the hover and the press
    /// disagreeing, because there is only one sentence. It also means SONNY-136 changes one constant
    /// and all three surfaces follow.
    var micHoverHintPresentation: MicHoverHintPresentation {
        if let blocker = voiceConfigurationBlocker {
            return MicHoverHintPresentation(message: blocker, autoDismissDelay: nil)
        }
        return MicHoverHintPresentation(
            message: Self.micHoverShortcutReminder,
            autoDismissDelay: Self.micHoverReminderDismissDelay
        )
    }

    /// Lets a test state what the *configuration* half of voice readiness should answer, instead of
    /// inheriting whatever the process that launched the test suite happened to export.
    ///
    /// The live answer reads `ProcessInfo.processInfo.environment` through `hasAPIKey`, which a test
    /// cannot set for itself: `setenv` is process-global and the suite runs its tests in parallel.
    /// The same reason `visionSessionEnvironment` is a seam — a test must be able to describe the
    /// world rather than hope for it. Before this existed the repo's own comment on
    /// `voiceCannotConsumeAnArmWhileAClarificationIsPending` recorded the consequence plainly: "that
    /// half is readable, not testable, and its proof is the declaration." It is testable now.
    ///
    /// `nil` in the shipping app, and nothing in `Sources/` assigns it. Deliberately not
    /// `@Published`: a test sets it once before reading, and production never changes it, so there
    /// is no view to invalidate.
    var voiceConfigurationBlockerOverride: (() -> String?)?

    /// **The actionable half of voice readiness** — something the user can go and fix, and the
    /// message that says so. `nil` when configuration is fine.
    ///
    /// Actionable failures are the ones a control may never swallow. That is the whole of
    /// SONNY-173: the mic button was `.disabled` on the *composite* `canUseVoice`, a disabled
    /// SwiftUI button never runs its action, and so the guard that already had the right message
    /// was unreachable from the one surface most people press. The hotkey, gated by no SwiftUI
    /// state at all, reached its copy of the guard and explained itself. Same failure, two answers.
    ///
    /// **This split outlives its current contents.** SONNY-136 deletes every provider environment
    /// variable, and `hasAPIKey` goes with it — what that changes is the body of this property, not
    /// the rule it exists to state: an actionable refusal explains itself, a transient one stays
    /// quiet, and only the transient half is ever allowed into a `.disabled` predicate.
    var voiceConfigurationBlocker: String? {
        if let voiceConfigurationBlockerOverride {
            return voiceConfigurationBlockerOverride()
        }
        return hasAPIKey ? nil : Self.missingAPIKeyVoiceMessage
    }

    /// **The transient half of voice readiness** — the app is busy, and refusing in silence is the
    /// correct answer. Nothing here is something the user could go and fix; each clears on its own.
    ///
    /// `clarificationQuestion == nil` restores parity with the typed route, which `isTaskInFlight`
    /// has always blocked during a clarification pause. Voice lacking the same term was asymmetry by
    /// omission, and it was reachable: a clarification pause holds `activeTaskScope` (the same task
    /// is resuming), so the chip shows the *paused* task's workspace while a card arm sits invisible
    /// behind it — and both voice entry points dispatch with `origin: .widget`, so the transcription
    /// completion consumed that arm. The task then ran scoped to a workspace the chip never named,
    /// and the paused task's unanswered clarification was silently discarded by `performStart`'s
    /// per-task reset.
    ///
    /// Voice answering a clarification is a real feature and this does not foreclose it; it is a
    /// separate ticket, and the gate has to exist first.
    var isVoiceTransientlyBusy: Bool {
        clarificationQuestion != nil || isAwaitingApproval || isRunning
            || isPreparingVoiceRecording || isTranscribingVoice
    }

    var canUseVoice: Bool {
        voiceConfigurationBlocker == nil && !isVoiceTransientlyBusy
    }

    /// The mic control's whole `.disabled` predicate, **the transient half only** — and it lives
    /// here, not in the view, so it is something a test can hold.
    ///
    /// A view cannot be asked what it renders, so a `.disabled` expression written inline in
    /// `FloatingWidgetView` is enforced by nothing but a reader noticing. That is how the
    /// configuration term got into it. Stated as a property, the rule "only transient reasons
    /// disable a control" has one address, one doc comment, and a test that fails when it moves.
    ///
    /// `!isRecordingVoice` is the stop half, carried over unchanged: once a recording is running the
    /// button is Stop, and it stays pressable even if something transient arrives mid-recording —
    /// an approval landing while the user is mid-sentence must not trap them in a live microphone.
    var isVoiceControlDisabled: Bool {
        isVoiceTransientlyBusy && !isRecordingVoice
    }

    var isAwaitingApproval: Bool {
        approvalRequest != nil
    }

    /// Where the plan of the **most recently prepared** run came from, or `nil` when there is none.
    /// SONNY-64's origin signal, as the rest of the app sees it.
    ///
    /// "Most recently prepared", not "in flight": `performStart` clears `preparedRun` when the next
    /// run begins and `cancelCurrentRun` clears it on cancel, but a run that *completes* leaves it
    /// set, so this keeps describing that run until another starts. Stated exactly because the
    /// reader who matters is row C, which will consult it while a run is being assessed — where the
    /// two readings coincide — and a doc claiming a narrower lifetime than the property has is the
    /// kind of thing that gets believed at the one call site where it is false.
    ///
    /// Derived from `preparedRun` rather than kept in its own slot, deliberately. A second stored
    /// property would need adding to `performStart`'s per-task reset, to the terminal `defer`, and
    /// to `clearInMemoryLocalDataState`'s hand-written enumeration — and that enumeration has been
    /// missed twice on this class already (`explicitWorkspaceBinding`, then `pendingWorkspaceBinding`
    /// one ticket later). A slot that cannot go stale is worth more here than a saved property read.
    ///
    /// Read-only on purpose: row C will consume this, and nothing may set it. The only writer is
    /// `AgentRunner.prepare`.
    var activeTaskPlanSource: PreparedPlanSource? {
        preparedRun?.source
    }

    var activeTaskCount: Int {
        isRunning || isAwaitingApproval ? 1 : 0
    }

    /// Whether the floating widget currently has real content to show — a permission/clarification/
    /// failure state (the only place either is actionable at all, regardless of which surface
    /// submitted the task), or a working/result state for a task the widget itself submitted.
    /// Single source of truth for both `FloatingWidgetView`'s own panel rendering and
    /// `FloatingWidgetWindowController`'s decision to composite into Command Center — compositing
    /// whenever Command Center merely has key focus, regardless of this, was the real cause of the
    /// widget silently vanishing right after launch: Command Center takes key-window focus first,
    /// the widget composited in immediately while still idle, and an idle+composited render showed
    /// literally nothing (no compact capsule, no pill), with no way to click back into it. Mirrors
    /// `FloatingWidgetView`'s private `state`/`showsPanel` precedence exactly — keep both in sync if
    /// either changes.
    var hasVisibleWidgetPanel: Bool {
        // Row I's two Safe-mode questions, first for the same reason the three below them are
        // unconditional: each is a parked continuation waiting on a human, and a session whose
        // question the widget declined to render would simply hang.
        if visionCapturePreview != nil || visionDelegationRequest != nil || visionSessionPause != nil {
            return true
        }
        if approvalRequest != nil {
            return true
        }
        if clarificationQuestion != nil {
            return true
        }
        if errorMessage != nil && !isRunning {
            return true
        }
        if isRunning {
            return activeTaskOrigin == .widget
        }
        if !finalSummary.isEmpty {
            return activeTaskOrigin == .widget
        }
        return false
    }

    var voiceButtonTitle: String {
        if isPreparingVoiceRecording {
            return "Starting"
        }
        if isRecordingVoice {
            return "Stop"
        }
        if isTranscribingVoice {
            return "Transcribing"
        }
        return "Speak"
    }

    var voiceButtonIcon: String {
        isRecordingVoice ? "stop.circle" : "mic"
    }

    /// - Parameter origin: Which surface is submitting this — see `TaskOrigin`. Defaults to
    ///   `.commandCenter`; the floating widget's own call sites pass `.widget` explicitly.
    /// - Parameter workspaceBinding: A workspace named by the dispatch itself rather than by the
    ///   command text — B4's workspace-card action. Wins over the free-text match.
    /// - Parameter fromComposer: Whether this dispatch is the widget composer submitting what the
    ///   user typed or spoke into it. **Only a composer dispatch may consume a pending card
    ///   binding**; every other entry point kills it instead. Defaults to `false` so a call site
    ///   added later inherits the safe direction — a new dispatch that forgets to say anything
    ///   drops the arm rather than silently scoping itself with it.
    /// - Parameter prebuiltPlan: An exact plan a screen already constructed — SONNY-64. Supplying it
    ///   replaces *planning only*: the run skips both the instant resolver and the planner and
    ///   executes this plan verbatim, then rejoins the identical path at `prepare`, so the
    ///   assessment, the gate, the approval prompt, the events, and the history row are the ones the
    ///   equivalent typed command would have produced. It is not a way past anything, and there is
    ///   nowhere in this function or the next where it could become one — the only thing it changes
    ///   is who wrote the plan.
    func start(
        autoExecute: Bool = false,
        origin: TaskOrigin = .commandCenter,
        workspaceBinding: String? = nil,
        fromComposer: Bool = false,
        prebuiltPlan: AgentPlan? = nil,
        // Which surface built `prebuiltPlan`. Defaulted to `.directUserAction` so SONNY-64's
        // existing callers read unchanged; a vision session passes its own case, because
        // `PreparedPlanSource`'s own rule is that a surface needing to be told apart adds a case
        // rather than overloading one. See `PreparedPlanSource.visionSession` for why the two are
        // different claims, and for what happened to the second, stronger reason SONNY-81 gave.
        prebuiltPlanSource: PreparedPlanSource = .directUserAction
    ) {
        if isAwaitingApproval {
            approvePendingRun()
            return
        }

        guard canSubmit else {
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setError("Enter a natural-language command first.")
            }
            return
        }

        // Captured now, synchronously, rather than re-read from `command` inside `performStart`.
        // `performStart` is the body of an unstructured `Task` — it only actually begins running on
        // a later main-actor turn, not synchronously with this call — and a caller is free to clear
        // `command` immediately after calling `start()`. Reading the live property from inside
        // `performStart` meant every widget text submission ran with an already-cleared empty
        // command: a silently dropped real command, an "Enter a natural-language command first"
        // failure, and a blank "Untitled task" history record instead of what was typed.
        let submittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Set here, synchronously, not inside `performStart` — `CommandCenterRunningIndicator`
        // needs a correct "what's actually running" label the instant `isRunning` flips true, not
        // a render or two later once the scheduled `Task` catches up.
        lastCommand = submittedCommand
        // Cleared centrally, for every caller, rather than leaving each call site (voice, routine/
        // workspace quick actions, retry, clarification-resume) responsible for remembering to do
        // it themselves — that inconsistency was the actual bug: voice and the quick actions never
        // cleared it, so a stale command sat in the widget's own field (and got misread as "what's
        // running" by the display below) long after the real submission had already moved on.
        command = ""

        // **A pending card binding may bind exactly one task: the next composer dispatch.**
        //
        // It used to be consumed by *any* `start()`, which meant an armed-but-never-submitted chip
        // was inherited by the next Command Center row action — click "New task" on Drafting, get
        // distracted, then click Open on Research, and Research opened under Drafting's boundary
        // and raised a scope prompt naming a workspace the user never mentioned. A slot with one
        // setter, two death paths and no abandonment path outlives the dispatch that created it.
        //
        // Now: a composer dispatch consumes it; every other dispatch kills it without inheriting.
        // Either way it dies here, so it can never reach a second task. An explicit
        // `workspaceBinding:` argument still wins over both, which is what keeps SONNY-38's
        // precedence rule (card beats a workspace named in the command text) a single slot.
        explicitWorkspaceBinding = workspaceBinding ?? (fromComposer ? pendingWorkspaceBinding : nil)
        pendingWorkspaceBinding = nil
        currentTask?.cancel()
        isRunning = true
        currentTask = Task {
            await performStart(
                submittedCommand: submittedCommand,
                autoExecute: autoExecute,
                origin: origin,
                prebuiltPlan: prebuiltPlan,
                prebuiltPlanSource: prebuiltPlanSource
            )
        }
    }

    /// `currentTask?.cancel()` doesn't guarantee the in-flight work throws Swift's own
    /// `CancellationError` — a cancelled `URLSession` request (the planner/transcriber's network
    /// calls) can surface as `URLError(.cancelled)` instead, depending on exactly where the
    /// cancellation lands. Catching only `CancellationError` meant a cancel that happened mid-network-
    /// call fell through to the generic failure path: styled red, a Retry button, "cancelled" as the
    /// error text — a deliberate user cancellation rendered as if it were a real failure.
    func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func performStart(
        submittedCommand: String,
        autoExecute: Bool,
        origin: TaskOrigin,
        prebuiltPlan: AgentPlan? = nil,
        prebuiltPlanSource: PreparedPlanSource = .directUserAction
    ) async {
        activeTaskOrigin = origin
        // Submitting anything is an acknowledgement of whatever was on screen — this one line covers
        // both "the user retried" and "the user typed something else", because `retryLastCommand`
        // reaches here through `dispatch` like every other submission.
        outcomeWasNotified = false
        errorMessage = nil
        finalSummary = ""
        plan = nil
        suggestions = []
        clarificationQuestion = nil
        clarificationAnswer = ""
        preparedRun = nil
        approvalRequest = nil
        stepStatuses = [:]
        // Both halves of the pause carry-over, not just one. These two are always written together
        // (an approval pause sets both, and as of SONNY-166 so does a clarification pause) and read
        // together, so clearing only the date left the command able to outlive the run that set it.
        // Nothing read the stale value on any live path — every reader is inside a branch that
        // rewrites both first — but a pair whose reset covers one member is the shape a later reader
        // gets wrong, and the clarification exit's whole correctness argument is that the pair
        // describes *this* run.
        pendingCommandForPriorTaskContext = nil
        pendingTaskHistoryStartedAt = nil
        plannerFallbackNotice = nil

        if preserveUsageForNextStart {
            preserveUsageForNextStart = false
            publishTaskUsageSummary()
        } else {
            taskUsageRecorder.reset()
            taskUsageSummary = .empty
        }

        activeTaskScope = .unscoped
        // A new task starts with no trace: the line describes the run it completed with, and a
        // previous task's trace surviving into this one would claim a silence that has not
        // happened yet.
        ranWithoutAskingTrace = nil
        // Same reasoning as the trace: the HUD line describes a session that is live, and a
        // previous session's line surviving into a new task would claim Sonny is controlling an app
        // it is not.
        visionSessionProgress = nil

        // Clipboard history pauses for the whole of a suppressed run, and the cost was chosen
        // knowingly by the founder on 2026-08-16: anything the user copies *by hand* during the task
        // is not saved either. It cannot be avoided by being cleverer — `ClipboardHistoryMonitor` is
        // a pasteboard poller watching `changeCount`, so it cannot tell text Sonny copied from text
        // the user copied.
        //
        // A run that ends by crash or quit never reaches the resume in `finishRecordingPolicyIfSettled()`.
        // That is survivable rather than silent: monitoring is restarted from settings at launch by
        // `refreshClipboardHistoryNotice()`, so the worst case is clipboard history staying off until
        // the next launch, never a setting silently rewritten.
        if taskRecordingPolicy.suppressesTraces {
            stopClipboardHistoryMonitoring()
        }

        defer {
            publishTaskUsageSummary()
            isRunning = false
            currentTask = nil
            // Cleared on *every* exit of this function, unlike the scope below — a paused vision
            // session does not reach here at all (the loop is still suspended inside `execute`), so
            // reaching this line always means the session is over, however it ended.
            visionSessionProgress = nil
            visionCapturePreview = nil
            visionDelegationRequest = nil
            visionSessionPause = nil
            // The one place a session ends, whatever ended it — so the combination goes back to the
            // user's own apps on every exit, including the ones nobody planned for.
            releaseEmergencyStopHotKey()
            visionUserPauseMonitor?.clearPause()
            // Cleared *after* the history row is written by `recordTaskHistoryIfTerminal`, which
            // runs earlier in this same exit path — so the row carries the link and the next task
            // starts with none.
            activeVisionSessionID = nil
            // Per-task, cleared at every terminal exit — and deliberately *not* when the task is
            // merely paused. An approval or a clarification is the same task waiting on the user,
            // and it has to resume under the scope it was assessed with; clearing here would let
            // `performApproval` execute unscoped after the user approved a scoped assessment, which
            // is the stale-approval mismatch scoped requirement 4 exists to prevent. Every other
            // exit — completed, failed, cancelled, refused, preview-only — is terminal and clears.
            if approvalRequest == nil && clarificationQuestion == nil {
                activeTaskScope = .unscoped
                explicitWorkspaceBinding = nil
            }
            // Guarded internally on the same pause-versus-terminal test, so it is safe to call
            // unconditionally here and at every other terminal point.
            finishRecordingPolicyIfSettled()
        }

        let taskHistoryStartedAt = Date()
        let priorContextForPlanner = priorTaskContextStore.currentContext()
        // Arm, use once, gone (SONNY-150). Spent here, at the read, rather than left to the
        // `record(...)` that overwrites it at the end of every terminal path — "usually overwritten
        // later" is a different promise from "spent now", and the gap between them is a follow-up
        // silently attaching itself to the command after this one. A no-op for an ordinary context.
        priorTaskContextStore.consumeArmedContext()
        priorTaskContext = priorContextForPlanner

        // The decision this run will execute under when the user's standing per-routine trust
        // grant covers it (SONNY-54). Hoisted out of the `do` so the drift catch below can tell a
        // trusted execution apart from the ordinary auto-run path, whose failure behavior it must
        // not change.
        var routineTrustApproval = RiskApprovalDecision.notRequested

        do {
            let executor = makeExecutor()
            let runner: AgentRunner
            let prepared: PreparedAgentRun

            // **First, and it has to be first.** The two branches below both start from
            // `submittedCommand` — the resolver pattern-matches it, and anything it does not match
            // falls through to the registry-selected planner. A pre-built plan's command text is a
            // *label* for history and the running indicator, not an instruction, and the resolver
            // has no pattern for a workspace edit anyway; letting it reach either branch would send
            // a plan the screen already built to the planner to be re-derived from a sentence — the
            // exact round-trip this ticket removes, reintroduced one layer down and invisible,
            // because the run would still work. Ordering is the enforcement: there is no path from
            // here to a planner while `prebuiltPlan` is non-nil.
            if let prebuiltPlan {
                runner = AgentRunner(
                    planner: InstantOnlyFallbackPlanner(),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun
                )
                prepared = try runner.prepare(plan: prebuiltPlan, source: prebuiltPlanSource)
            } else if let resolution = makeInstantCommandResolver().resolve(command: submittedCommand) {
                runner = AgentRunner(
                    planner: InstantOnlyFallbackPlanner(),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun
                )
                switch resolution {
                case .plan(let localPlan), .clarify(let localPlan):
                    prepared = try runner.prepare(plan: localPlan, source: .instantResolver)
                }
            } else {
                // The registry, not this site, decides which provider plans the task
                // (SONNY-85): a new provider is a registration in MacAgentCore, never another
                // branch here. With the default selection this constructs exactly the
                // `OpenAIPlanner(usageRecorder:)` call that used to be written inline.
                let selected = try plannerProviderRegistry.makePlanner(
                    selection: plannerSelection,
                    usageRecorder: taskUsageRecorder
                )
                if let notice = selected.fallbackNotice {
                    plannerFallbackNotice = notice
                    logStore.append(.plan, notice)
                }
                runner = AgentRunner(
                    planner: selected.planner,
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStoreForThisRun
                )
                prepared = try await runner.prepare(
                    command: submittedCommand,
                    priorTaskContext: priorContextForPlanner
                )
            }
            self.runner = runner

            preparedRun = prepared
            plan = prepared.plan
            initializeStepStatuses(for: prepared.plan)

            // Resolved once, after the plan exists and before the first assessment, so that both
            // `approvalRequest` below and `execute` inside `executePreparedRun` see the same value.
            // The plan matters: `WorkspaceTaskTagging` reads `open_workspace`/`create_workspace`
            // steps' own `workspaceName` before it ever looks at the command text, which is how a
            // workspace-card dispatch resolves without needing the explicit binding at all.
            activeTaskScope = resolveTaskScope(command: submittedCommand, plan: prepared.plan)
            lastAssessedScope = activeTaskScope

            if let question = prepared.clarificationQuestion {
                clarificationQuestion = question
                clarificationAutoExecute = autoExecute
                clarificationOrigin = origin
                clarificationWorkspaceBinding = explicitWorkspaceBinding
                // The same two values the approval pause below preserves, for the same reason and
                // now for a second one (SONNY-166). A pause is not a terminal state, so no history
                // row is written here — `recordPriorTaskContext` is called without `startedAt:`
                // just below, and `recordTaskHistoryIfTerminal`'s own guards refuse a
                // `.clarificationNeeded` status anyway. But abandoning the question *is* terminal,
                // and a row needs the instant the run began and the text the user actually
                // submitted. Neither survives the pause otherwise: `command` was cleared
                // synchronously by `start()`, and `taskHistoryStartedAt` is local to this call.
                pendingCommandForPriorTaskContext = submittedCommand
                pendingTaskHistoryStartedAt = taskHistoryStartedAt
                finalSummary = "Clarification needed before I can act."
                logStore.append(.summarize, "Clarification needed: \(question)")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .clarificationNeeded,
                    summary: finalSummary
                )
                return
            }

            let request = try runner.approvalRequest(
                for: prepared,
                logAssessment: true,
                scope: activeTaskScope,
                context: approvalContext()
            )
            switch request.requirement {
            case .autoRun:
                break
            case .lightweightConfirmation, .explicitApproval:
                // SONNY-54: a routine the user marked trusted carries the same `.approved(.tier2)`
                // decision on a manual run that its scheduled runs already carry — the toggle was
                // always a per-routine trust grant, and presence is the safer case, not the riskier
                // one. This asks `AgentRunner.execute`'s own gate the same question rather than
                // restating it — before SONNY-62 it was a hand-written copy of the tier comparison,
                // and a copy of a gate is a gate that drifts. `execute` still re-assesses and
                // enforces it structurally; this check only decides pause-versus-proceed, so a
                // tier-3+ assessment pauses at this prompt exactly as it did before trust covered
                // manual runs. A standing grant is a tier ceiling, so the reason half of that gate
                // is vacuous here by construction.
                //
                // Safe mode gates this shortcut (SONNY-90): the dial is the user's opt-back-in to
                // being asked about every attended action, and a per-routine convenience grant
                // must not quietly override the global caution dial while the user is present to
                // answer. The unattended scheduled path is deliberately untouched — its standing
                // tier-2 ceiling and notify-and-pause are the ticket's "no new unattended prompt
                // class", and a schedule that Safe mode silently suspended would be one.
                let trustDecision = manualRoutineTrustDecision(for: prepared.plan)
                if interactionMode != .safe, trustDecision.authorizes(request) {
                    routineTrustApproval = trustDecision
                } else {
                    approvalRequest = request
                    pendingCommandForPriorTaskContext = submittedCommand
                    pendingTaskHistoryStartedAt = taskHistoryStartedAt
                    finalSummary = "Approval needed before Sonny can act."
                    logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: prepared,
                        status: .approvalNeeded,
                        summary: finalSummary
                    )
                    return
                }
            case .previewOnly:
                // Unreachable today: no path in the mapping produces `.previewOnly` since the
                // policy dials were deleted (2026-08-14) — the requirement enum keeps the case
                // as public API and the consent rank still orders it. It reports
                // through `errorMessage` rather than `finalSummary` so that *if* a policy
                // control ever makes it reachable, the outcome is actually visible — the widget
                // and Command Center both surface errors, but neither renders a `.prepared`
                // prior-task-context status.
                markAllSteps(.complete)
                setError("The current approval policy limits this action to a preview, so Sonny did not run it.")
                logStore.append(.summarize, "Preview-only approval policy")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .prepared,
                    summary: errorMessage ?? "Preview-only approval policy",
                    startedAt: taskHistoryStartedAt
                )
                return
            case .refuse:
                markAllSteps(.failed)
                setError("Sonny refused this action under the current approval policy.")
                logStore.append(.summarize, "Refused by approval policy")
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .failed,
                    summary: errorMessage ?? "Refused by approval policy",
                    startedAt: taskHistoryStartedAt
                )
                return
            }

            let autoApprovalMessage: String
            if routineTrustApproval == .notRequested {
                // Read off the prepared run's own source rather than off `autoExecute`, which
                // describes how the *text* arrived and says nothing true about a run that had no
                // text to arrive. The `.directUserAction` branch below is the workspace sheet's
                // ordinary confirmation message — under the consequence rule every sheet edit
                // auto-runs (tier 2, or tier 3 with only advisory escalations), so every
                // screen-built dispatch passes through here. The vision envelope remains the next
                // *caller*; it is no longer the first.
                if prepared.source == .directUserAction {
                    autoApprovalMessage = "Screen-built action auto-approved execution"
                } else {
                    autoApprovalMessage = autoExecute ? "Voice command auto-approved execution" : "Typed command auto-approved execution"
                }
            } else {
                autoApprovalMessage = "Manual run approved by this routine's trust setting"
            }
            let result = try await executePreparedRun(
                preparedRun: prepared,
                runner: runner,
                approvalDecision: routineTrustApproval,
                confirmationMessage: autoApprovalMessage,
                logRiskAssessment: false
            )
            // Only after the run really executed: an auto-run that drifted to a prompt was
            // disclosed by the prompt, and tracing it as silent would be false. The line is nil
            // for the trust path (its requirement was an ask the toggle answered, not `.autoRun`)
            // and nil for tiers that always ran silently; the pure function owns both rules, and
            // it names the advisory reasons — the sentences the approval panel used to carry.
            ranWithoutAskingTrace = AgentActivityPresentation.ranWithoutAskingLine(
                requirement: request.requirement,
                effectiveTier: request.assessment.effectiveTier,
                advisoryReasons: request.assessment.escalations
                    .filter { $0.consequence == .advisory }
                    .map(\.reason)
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            let recordedTaskID = recordPriorTaskContext(
                command: submittedCommand,
                preparedRun: prepared,
                status: .completed,
                summary: result.summary,
                // Carried from the adapter that authored the text (SONNY-147) rather than assumed
                // here — a run that resolved to a screen-control session comes back
                // `.modelAuthored`, and so does a chain or a routine that contained one.
                resultProvenance: result.summaryProvenance,
                startedAt: taskHistoryStartedAt
            )
            refreshSavedItems()
            publishCompletedRunNoticeIfUnreported(result.summary, taskID: recordedTaskID)
        } catch RiskApprovalError.approvalRequired(let request) {
            // Whatever let this run proceed without a prompt — a routine's trust grant, or the
            // consequence rule mapping it to `.autoRun` — stopped covering it in the window
            // between the assessment above and `AgentRunner.execute`'s own re-assessment: the
            // state-drift class `performApproval` re-arms on ("the zip already exists" landing
            // mid-flight turns an advisory-only or escalation-free run into a destructive one).
            // Every dispatch through this function has a user present, so it prompts exactly as an
            // ordinary run would rather than failing. The `where routineTrustApproval !=
            // .notRequested` clause that used to scope this to the trust path is gone
            // deliberately: a plan that reached `.autoRun` on its own carries `.notRequested`, and
            // hard-failing the one drift a user could simply answer was the gap SONNY-97's
            // contract named. The unattended path is unaffected — it dispatches through
            // `performScheduledRun`, whose own `RiskApprovalError` catch pauses the schedule
            // instead (SONNY-31).
            markAllSteps(.pending)
            approvalRequest = request
            pendingCommandForPriorTaskContext = submittedCommand
            pendingTaskHistoryStartedAt = taskHistoryStartedAt
            finalSummary = "Approval needed before Sonny can act."
            logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
            if let preparedRun {
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: preparedRun,
                    status: .approvalNeeded,
                    summary: finalSummary
                )
            }
        } catch {
            if isCancellationError(error) {
                markAllSteps(.canceled)
                finalSummary = "Canceled."
                logStore.append(.summarize, "Canceled by user")
                if let preparedRun {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: preparedRun,
                        status: .canceled,
                        summary: finalSummary,
                        startedAt: taskHistoryStartedAt
                    )
                } else {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        status: .canceled,
                        summary: finalSummary,
                        startedAt: taskHistoryStartedAt
                    )
                }
            } else {
                markAllSteps(.failed)
                setError(error.localizedDescription)
                logStore.append(.summarize, "Stopped: \(error.localizedDescription)")
                if let preparedRun {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        preparedRun: preparedRun,
                        status: .failed,
                        summary: error.localizedDescription,
                        startedAt: taskHistoryStartedAt
                    )
                } else {
                    recordPriorTaskContext(
                        command: submittedCommand,
                        status: .failed,
                        summary: error.localizedDescription,
                        startedAt: taskHistoryStartedAt
                    )
                }
            }
        }
    }

    func cancelCurrentRun() {
        // **One press ends the run** — the experiment's Option A, ratified by the founder on
        // 2026-08-14 and inherited here as the semantics of the stop control. The continuation is
        // cleared and resumed *before* the cancel, so `requestVisionActionApproval`'s own handler
        // guards on the same property, finds nothing, and there is exactly one resume; the
        // `Task.checkCancellation()` after that await then turns this into the same
        // `CancellationError` a cancelled clarification throws, so the run ends with the same honest
        // "Stopped." rather than reading the `nil` as "the user declined this one action, carry on".
        //
        // A stop control that visibly fails to stop is the most expensive surprise a program moving
        // the user's real cursor can produce, which is why decline-and-continue is not folded in
        // here. The founder wants that capability back as a *labelled* "deny this step" control
        // beside a labelled stop (SONNY-80's standing note); when it lands it is a second, narrower
        // entry point that resumes `nil` without cancelling — not a change to this one.
        if let continuation = visionApprovalContinuation {
            visionApprovalContinuation = nil
            approvalRequest = nil
            markFirstApprovalCompleted()
            continuation.resume(returning: nil)
            currentTask?.cancel()
            return
        }
        // The Safe-mode capture preview is the other parked question a session can hold. Cancelling
        // it means "do not send this", which ends the session — there is no next step that does not
        // begin with sending a capture.
        if let continuation = visionCaptureContinuation {
            visionCaptureContinuation = nil
            visionCapturePreview = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }
        // The third parked question a session can hold. Cancelling it stops the run rather than
        // declining the delegation and carrying on, for the same reason the two above it do: a stop
        // control has to stop. Declining without stopping is `resolveVisionDelegation(allowing:)`,
        // which is a *different control* — the labelled deny SONNY-80's standing note asks for,
        // arriving here first because a delegation is the one place declining-and-continuing is
        // obviously useful and has an obvious label.
        if let continuation = visionDelegationContinuation {
            visionDelegationContinuation = nil
            visionDelegationRequest = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }
        // Stopping a paused session ends it, which is the only thing stop can honestly mean here:
        // the alternative reading — "stop pausing" — is what Resume is for, and it has its own
        // control.
        if let continuation = visionResumeContinuation {
            visionResumeContinuation = nil
            visionSessionPause = nil
            continuation.resume(returning: false)
            currentTask?.cancel()
            return
        }

        if isAwaitingApproval {
            if let preparedRun, let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: "Approval canceled. No action was taken.",
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            approvalRequest = nil
            hasCompletedFirstApproval = true
            preparedRun = nil
            runner = nil
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            markAllSteps(.canceled)
            finalSummary = "Approval canceled. No action was taken."
            logStore.append(.summarize, "Approval canceled by user")
            // The pause ends here rather than resuming, so the binding dies with it. Without this
            // the next command would inherit the cancelled task's workspace — the exact leak the
            // rejected persistent-active-workspace design was rejected for.
            activeTaskScope = .unscoped
            explicitWorkspaceBinding = nil
            // This function has no `defer`, and this branch returns without ever re-entering
            // `performStart` — so without this call a task cancelled at its approval prompt would
            // leave the switch on and clipboard history paused indefinitely.
            finishRecordingPolicyIfSettled()
            return
        }

        // **The fourth exit (SONNY-166): a clarification the user does not want to answer.**
        //
        // Before this, the only three ways out of a clarification pause were answering it, wiping
        // all local data, and quitting — `clarificationQuestion` had exactly those three clearing
        // sites. The pause looks idle from outside (`isRunning` is false, `approvalRequest` is nil),
        // so nothing that gates on those two could offer a way out, and the composer is disabled by
        // the in-flight term besides.
        //
        // **Cancelled, not failed, and "no action was taken" is literal.** A clarification is raised
        // inside `AgentRunner.prepare` and `performStart` returns on it before `executePreparedRun`
        // is reached at all, so every step is still `.pending` and nothing has executed. This is the
        // one pause where that is true of the whole plan rather than of the remaining steps.
        //
        // Placed after the approval branch for reading order only — it mirrors the two surfaces'
        // permission-over-clarification precedence. The two states are mutually exclusive by
        // construction: `performStart` returns on the clarification before it ever builds an
        // approval request, and `submitClarification` clears the question before re-entering
        // `start()`, so neither branch can shadow the other whichever came first.
        if clarificationQuestion != nil {
            // The row the Tasks list owes the user, on the founder's decision of 2026-08-20: the
            // same `.canceled` disposition cancelling at an approval prompt already writes, so the
            // two exits from a paused run leave the same trace. Both values were preserved across
            // the pause by `performStart`'s clarification branch — without them there is no
            // `startedAt`, and `recordTaskHistoryIfTerminal` refuses to write a row at all.
            // "Don't save this task" still suppresses it: that check lives inside
            // `recordTaskHistoryIfTerminal`, so this path inherits it rather than restating it.
            if let preparedRun, let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: ClarificationPresentation.canceledSummary,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            clarificationQuestion = nil
            clarificationAnswer = ""
            // The three values the pause held so that answering could resume the task the user
            // actually started. Nothing is going to resume, so they die with it — an origin or a
            // binding surviving into the next run is the leak `explicitWorkspaceBinding`'s own
            // lifecycle rules exist to prevent.
            clarificationAutoExecute = false
            clarificationOrigin = .commandCenter
            clarificationWorkspaceBinding = nil
            preparedRun = nil
            runner = nil
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            markAllSteps(.canceled)
            // `submitClarification` sets "Enter an answer before continuing." when Send is pressed
            // on an empty field, and that error outlives the question it was about. The widget's
            // and Command Center's shared precedence puts `.failure` above `.result`, so leaving it
            // would show the user a stale validation nudge where the cancellation belongs.
            errorMessage = nil
            finalSummary = ClarificationPresentation.canceledSummary
            logStore.append(.summarize, "Clarification canceled by user")
            // Same reason the approval branch clears these: the pause ends here rather than
            // resuming, so the boundary the paused task was assessed under must not be inherited by
            // whatever the user types next.
            activeTaskScope = .unscoped
            explicitWorkspaceBinding = nil
            // **The ticket's own requirement, and the reason it is the last line.** This function
            // has no `defer`, and `finishRecordingPolicyIfSettled` guards on
            // `approvalRequest == nil, clarificationQuestion == nil, !isRunning` — so calling it
            // before the clear above would return without doing anything, leaving "Don't save this
            // task" on and clipboard history paused until the next launch. That is the exact
            // consequence SONNY-120 recorded as a known limit and this ticket exists to close.
            //
            // **No `currentTask?.cancel()`, and the honest reason is the scheduler guard rather
            // than the defer.** This used to read "`performStart`'s defer set it to `nil` on the way
            // into the pause, so there is no task here to cancel", which was false in exactly one
            // window: `checkScheduledRoutines` could start a routine during the pause, and
            // `currentTask` was then that run — so cancelling a clarification would have killed a
            // scheduled run the user never started, and the reset below would have been refused
            // anyway because `isRunning` was true. `checkScheduledRoutines` now refuses to start
            // anything while a clarification is open (PR #80 review, F1), which is what makes the
            // claim true rather than the defer: no other path can put a task here while the question
            // stands. Pinned by `aPendingClarificationStopsTheSchedulerFromStartingAnything`.
            finishRecordingPolicyIfSettled()
            return
        }

        // Everything below is a *running* task being cancelled, which unwinds through
        // `performStart`'s defer and is settled there.
        currentTask?.cancel()
    }

    /// Whether `retryLastCommand()` would actually do anything. `errorMessage` also carries
    /// pre-flight errors that never reached a real submission (an empty-command validation
    /// message, a voice-transcription failure) — those leave `lastCommand` empty, so a UI that
    /// shows a Retry button for *any* `errorMessage` would show one that's silently a no-op for
    /// exactly those cases. Exposed as a bool here since retry-eligibility callers only need the
    /// yes/no, not the text — see `runningCommandDisplayText` below for the text itself.
    var hasRetryableCommand: Bool {
        !lastCommand.isEmpty
    }

    /// The real command driving the current/last run — `command` itself is cleared the instant
    /// `start()` captures it (see `start()`), so by the time a task is visibly `isRunning`, `command`
    /// is already empty again. A surface showing "what's actually running" (Command Center's
    /// running indicator) needs this instead of `command`, or it reads every task as "Untitled
    /// task" regardless of what was actually submitted.
    var runningCommandDisplayText: String {
        // A scheduled run needs a label for Command Center's running indicator without claiming
        // `lastCommand`, which belongs to whatever the user last submitted themselves.
        scheduledRunDisplayCommand ?? lastCommand
    }

    /// Called by the widget after a `.result` (including a clean "Canceled.") or a genuinely
    /// transient `.failure` has sat unacknowledged for a while (see `FloatingWidgetView`'s
    /// auto-clear timer) — the widget is a permanent, undismissable overlay, so with no timeout
    /// either would otherwise sit there indefinitely; merely collapsing to the small capsule
    /// doesn't help, since re-expanding it would show the exact same stale content again (this was
    /// a real, reported bug — a cancellation's "Canceled." banner survived collapsing the widget
    /// multiple times, because collapsing was the only thing this used to do). Clears both
    /// `errorMessage` and `finalSummary`/`suggestions`/`ranWithoutAskingTrace` unconditionally —
    /// whichever pair wasn't actually active is already empty, so clearing it too is harmless
    /// (see the trace's own note in the body). Deliberately scoped here,
    /// not a broader `reset()`. `FloatingWidgetView`'s timer only ever calls this for `.result`, or
    /// for `.failure` when `errorIsPersistent` is false, so a real configuration problem never gets
    /// silently cleared out from under the user.
    func clearStaleTaskOutcome() {
        // The marker describes the outcome, so it cannot outlive it — a stale `true` would make the
        // *next* outcome un-collapsible for a notification that was never sent about it.
        outcomeWasNotified = false
        errorMessage = nil
        finalSummary = ""
        suggestions = []
        // The trace rides on `finalSummary` and has no independent lifetime: `WidgetResultPanel` is
        // its only reader, and that panel exists only while `finalSummary` is non-empty. Clearing
        // one and not the other leaves a value that can never be shown with the run it describes and
        // can only reappear paired with someone else's summary — which is exactly how it reached
        // `deleteLocalData`'s deletion message (PR #48, F1).
        ranWithoutAskingTrace = nil
    }

    /// The one place `errorMessage` should be set (never assign it directly) — forces every call
    /// site to make an explicit, visible choice about `persistent` rather than silently inheriting
    /// whatever the last call happened to leave behind. Defaults to `false` (transient) since most
    /// errors in this app are one-off task/validation outcomes, not environment problems; the small
    /// number of genuinely persistent cases (missing API key, denied mic permission, unavailable
    /// hotkey) pass `persistent: true` explicitly.
    func setError(_ message: String, persistent: Bool = false) {
        errorMessage = message
        errorIsPersistent = persistent
    }

    /// Resubmits the last real command as-is. Used by the floating widget's task-level-failure
    /// retry button (§3.3.6), the error notification's "Retry" action, and Command Center's own
    /// failure row.
    ///
    /// - Parameter origin: Which surface's retry control this is. Defaults to `.widget` so the
    ///   two pre-existing call sites keep their original behavior. This used to be hardcoded
    ///   `.widget` on the reasoning that Command Center had no retry control — true until branch
    ///   10 checkpoint 1 gave it one. The retry action is a fresh interaction on whichever surface
    ///   the user pressed it, not an inheritance of the failed task's origin, so the caller states
    ///   it rather than it being inferred — same convention as `toggleVoiceRecording(origin:)`.
    func retryLastCommand(origin: TaskOrigin = .widget) {
        // `clarificationQuestion == nil` for the same reason every other in-flight term here exists:
        // a pause is a task the user has not finished answering, and retry is a *new* dispatch.
        // Without it, the notification's Retry — which fires from outside SwiftUI, so no view gate
        // can cover it — wrote the old command straight into a live pause.
        guard !lastCommand.isEmpty, !isTaskInFlight else {
            return
        }
        // Carries the original run's workspace. `lastAssessedScope` is the post-terminal record of
        // what the last task was assessed under and is deliberately never cleared, which is exactly
        // what makes it readable here — by retry time the live binding is long gone. Without this a
        // retry of a bound task runs unscoped, so a run whose first pass surfaced an out-of-scope
        // fact (once a prompt; an advisory trace line under the consequence rule) would repeat with
        // that fact silently missing — the two passes must be assessed under the same boundary.
        // Inherited from SONNY-38 rather than introduced here; fixed in-branch per fix-in-branch.
        //
        // Not `fromComposer`: a retry is a re-dispatch, so it still kills any card arm rather than
        // consuming it — the explicit binding below wins over the arm either way.
        var retryBinding: String?
        if case .scoped(let scope) = lastAssessedScope {
            retryBinding = scope.workspaceName
        }
        dispatch(command: lastCommand, origin: origin, workspaceBinding: retryBinding)
    }

    /// Runs a past task again by **re-asking Sonny with the same words**, never by replaying the
    /// plan the first run produced (row E, SONNY-149).
    ///
    /// **The reason replay is not on the table is the risk gate, not the stale coordinates.** Sonny's
    /// gate is pre-execution and whole-plan: `AgentRunner.execute` assesses once, up front, and
    /// `executeChain` runs every segment with no re-gating. So re-executing a previously approved
    /// plan would carry an approval granted for a world that has since changed — the file that did
    /// not exist then exists now, so the destructive escalation that should fire would not.
    /// Re-asking through the planner keeps every gate honest by construction rather than by anyone
    /// remembering. Two secondary reasons agree with it: nothing in this codebase replays a stored
    /// plan today, and a screen-control replay would click at coordinates that have moved.
    ///
    /// **What that means for the user, which reads like a regression and is not.** The workspace
    /// binding is re-resolved and any approval is re-requested, so a task that asked for permission
    /// the first time asks again. That is the same property that makes replay unsafe, seen from the
    /// other side. A run-again of a screen-control task starts a *fresh* session and never replays
    /// the journal's recorded actions — the journal is a record of what happened, not a script.
    ///
    /// **No `isTaskInFlight` guard of its own, deliberately.** `dispatch` refuses every in-flight
    /// state already — `isAwaitingApproval` at its own first line, and `isRunning`, an open
    /// clarification and a transcription in flight through `canSubmit` — and it logs the refusal at
    /// the one place every programmatic door passes through. A copy of that rule here would be a
    /// second place for it to drift, and a second refusal message for the same event, which the
    /// choke point's own comment rules out. The detail sheet disables the control while a task is in
    /// flight, the same way the workspace card does, so this path is the backstop rather than the
    /// user's experience of it.
    ///
    /// **A sibling of `retryLastCommand`, not a change to it.** That mechanism is the single-slot
    /// most-recent-command retry and keeps its own `lastCommand` and `lastAssessedScope`; this takes
    /// an arbitrary historical record and reads the binding off the record itself.
    ///
    /// - Returns: whether the dispatch was accepted, so the sheet can close on a real start and stay
    ///   open on a refusal rather than hiding the fact that nothing happened.
    @discardableResult
    func runTaskAgain(_ record: CompletedTaskRecord) -> Bool {
        dispatch(
            command: record.command,
            // Stated rather than defaulted, per `.claude/rules/macagent-ui-conventions.md`: a new
            // task-submitting entry point passes its own real origin. This one is pressed in
            // Command Center's task detail, so `.commandCenter` is the true answer and `dispatch`'s
            // default happening to match it is not a reason to leave it out.
            origin: .commandCenter,
            // The record's own stored workspace, which degrades safely on its own:
            // `resolveTaskScope` returns `.unscoped` for a name that no longer resolves to a stored
            // workspace, so running again a task whose workspace was deleted or renamed runs
            // unscoped rather than erroring or binding to an empty boundary.
            workspaceBinding: record.workspaceName
        )
    }

    /// Reopens a past task into the widget so the user can say the next thing about it (row E,
    /// SONNY-150) — "use the other folder instead", "do that again but for March" — without
    /// restating the whole command.
    ///
    /// **What it installs, and why it is built rather than assembled.** A `PriorTaskContext` from
    /// what that task stored: its command, the plan summary and steps `TaskPlanDetailStore` kept,
    /// and an outcome built from the row's status and stored result. Built through
    /// `PriorTaskContext`'s own initialiser, so every field reaches the planner through
    /// `plannerContextText` and inherits `escapeForPlanner` structurally. **No prompt string is
    /// assembled from a stored record anywhere, here or elsewhere** — that is the row I lesson this
    /// row is most exposed to, since persistence removes the ten-minute bound that made the original
    /// omission survivable.
    ///
    /// **A task with no stored plan still works, with less to go on.** Every record written before
    /// row E is in that case, and it is the common one on day one: the context carries the command
    /// and the outcome, and `plannerContextText` says the plan was not recorded rather than
    /// inventing a cause for its absence.
    ///
    /// **The arm is a live intention, not a stored one.** It is exempt from the ten-minute expiry
    /// because the user pointed at this task on purpose, and it is consumed by the next dispatch —
    /// `performStart` spends it the moment it reads it. Nothing persists it across launches.
    ///
    /// The widget comes forward with an **empty** composer, through the same
    /// `command` + `widgetPresentationRequest` mechanism `composeCommand` uses: the user is about to
    /// say the new thing, not re-edit the old one.
    ///
    /// - Returns: whether the task was armed, so the sheet can close on success and stay open on a
    ///   refusal.
    @discardableResult
    func followUpOnTask(_ record: CompletedTaskRecord) -> Bool {
        // Refused for the same reason `composeCommand` refuses a prefill during a clarification, and
        // then some: a partial command left in a live pause corrupts the continuation, and this
        // leaves a *trusted block* behind as well, which is worse. `isTaskInFlight` is the superset —
        // running, awaiting approval, or paused on an unanswered clarification.
        guard !isTaskInFlight else {
            logStore.append(.observe, "Follow-up ignored while a task is in flight.")
            return false
        }

        let detail = storedPlanDetail(for: record)
        let context = PriorTaskContext(
            armedFollowUpOn: record.command,
            planSummary: detail?.planSummary ?? "",
            steps: detail?.steps ?? [],
            outcome: PriorTaskOutcome(
                status: record.outcomeStatus,
                // The stored result, or nothing. `PriorTaskOutcome.plannerText` already falls back
                // to the bare status for an empty summary, so a record from before row E reads as
                // "completed" rather than as "completed - " with a dangling separator.
                summary: record.result?.text ?? ""
            ),
            completedAt: record.completedAt
        )
        priorTaskContextStore.replace(with: context)
        priorTaskContext = context

        // The follow-up runs inside the same workspace the original did, through the plumbing the
        // workspace card already uses — `start()` consumes this on a composer submit, and
        // `resolveTaskScope` degrades a name that no longer resolves to `.unscoped` on its own.
        pendingWorkspaceBinding = record.workspaceName

        // Empty, deliberately. `composeCommand("")` is not called directly because its own
        // clarification guard would be a second, weaker copy of the one above — this uses the same
        // two lines it does.
        command = ""
        widgetPresentationRequest += 1
        return true
    }

    /// Drops an armed follow-up. The chip's dismiss affordance, and nothing else.
    ///
    /// Clears the store as well as the published copy: leaving the context installed while the chip
    /// disappeared would be the invisible trusted block the chip exists to prevent, arrived at from
    /// the other direction.
    func clearArmedFollowUp() {
        guard priorTaskContext?.isArmed == true else {
            return
        }
        priorTaskContextStore.clear()
        priorTaskContext = nil
    }

    /// The plan this task ran, or `nil` — for a task recorded before row E, for one whose run never
    /// reached a plan, and for a store that will not read.
    ///
    /// **A load failure is reported and then treated as "no plan".** It goes to the same
    /// load-failure channel every other unreadable store uses, so the user sees the banner naming
    /// it; the follow-up still arms, with the command and the outcome. Refusing to arm because a
    /// side store would not decode would trade a degraded feature for no feature, and the founder's
    /// objection to a shorter-lived detail store was precisely that follow-ups must not quietly get
    /// weaker — a visible banner is the opposite of quietly.
    private func storedPlanDetail(for record: CompletedTaskRecord) -> StoredTaskPlanDetail? {
        guard let id = record.id else {
            return nil
        }
        do {
            let detail = try taskPlanDetailStore.detail(forTaskID: id)
            clearLocalStorageLoadFailure(.taskPlanDetails)
            return detail
        } catch {
            recordLocalStorageLoadFailure(.taskPlanDetails, error: error)
            return nil
        }
    }

    /// Submits the clarification answer as a **new** run, not a resume: this appends the Q&A to
    /// the command and calls `start()`, which clears `plan`/`stepStatuses`/`preparedRun` and
    /// re-plans from scratch. (Approval is the real resume — it reuses the existing prepared
    /// run.) The auto-execute flag and origin are carried across the pause deliberately so the
    /// continuation behaves like the task the user actually started.
    func submitClarification() {
        guard let question = clarificationQuestion else {
            return
        }

        let answer = clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            setError("Enter an answer before continuing.")
            return
        }

        command = """
        \(command.trimmingCharacters(in: .whitespacesAndNewlines))

        Clarification question: \(question)
        Clarification answer: \(answer)
        """
        let shouldAutoExecute = clarificationAutoExecute
        let shouldUseOrigin = clarificationOrigin
        let shouldUseBinding = clarificationWorkspaceBinding
        clarificationAutoExecute = false
        clarificationOrigin = .commandCenter
        clarificationWorkspaceBinding = nil
        clarificationQuestion = nil
        clarificationAnswer = ""
        start(autoExecute: shouldAutoExecute, origin: shouldUseOrigin, workspaceBinding: shouldUseBinding)
    }

    /// - Parameter origin: Which surface's mic button this is.
    ///
    /// **One call site today**, `FloatingWidgetView.micButton`, which passes `.widget` explicitly.
    /// The Command Center composer this method was written to also serve was deleted in
    /// `feature/ui-ux-wireframe-fidelity` (2026-07-21), and the doc comment kept describing it until
    /// SONNY-173 checked — a deprecation probe over the compiled package, since grep cannot resolve
    /// a receiver. The count is the compiler's, not a search's.
    ///
    /// The `.commandCenter` default therefore has no caller and is kept on purpose, as the *safe*
    /// direction for a call site added later: the origin reaches `dispatchTranscribedCommand`, where
    /// `fromComposer: origin == .widget` decides whether the dispatch may consume a pending
    /// workspace-card binding. A new caller that forgets to say which surface it is gets the answer
    /// that consumes nothing — the same reasoning `dispatch(fromComposer:)` states for its own
    /// default. A caller that really is the widget composer says so, exactly as this one does.
    func toggleVoiceRecording(origin: TaskOrigin = .commandCenter) {
        if isRecordingVoice {
            stopVoiceRecordingAndTranscribe()
        } else {
            startVoiceRecording(trigger: .button, origin: origin)
        }
    }

    func beginPushToTalkVoice() {
        guard !isPushToTalkHotKeyDown else {
            return
        }
        guard canUseVoice else {
            reportVoiceRefusal()
            return
        }

        isPushToTalkHotKeyDown = true
        // The global hotkey always brings the floating widget forward first (see
        // `AppDelegate.handlePushToTalkPress()`), so a hotkey-triggered recording is always a
        // widget interaction regardless of which surface happened to be focused.
        startVoiceRecording(trigger: .hotKey, origin: .widget)
    }

    /// Says an *actionable* refusal out loud and says nothing about a transient one — the single
    /// copy both voice entry points call, so the mic button and the hotkey cannot answer the same
    /// question differently again.
    ///
    /// Called after the `canUseVoice` guard has already failed, so it is only ever reached on a
    /// refusal; it stays silent when the refusal was transient.
    private func reportVoiceRefusal() {
        guard let blocker = voiceConfigurationBlocker else {
            return
        }
        setError(blocker, persistent: true)
    }

    func endPushToTalkVoice() {
        guard isPushToTalkHotKeyDown else {
            return
        }

        isPushToTalkHotKeyDown = false
        guard isRecordingVoice else {
            return
        }

        stopVoiceRecordingAndTranscribe()
    }

    func markVoiceHotKeyUnavailable(_ message: String) {
        voiceHotKeyReady = false
        voiceHotKeyStatus = "Hotkey unavailable"
        setError(message, persistent: true)
        refreshPermissions()
    }

    func refreshPermissions() {
        permissionItems = permissionReadinessService.currentStatus(
            hasAPIKey: hasAPIKey,
            hotKeyReady: voiceHotKeyReady
        )
    }

    func refreshSavedItems() {
        do {
            savedRoutines = try routineStore.loadAll().values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            clearLocalStorageLoadFailure(.savedRoutines)
        } catch {
            recordLocalStorageLoadFailure(.savedRoutines, error: error)
        }

        do {
            savedWorkspaces = try workspaceStore.loadAll().values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            clearLocalStorageLoadFailure(.savedWorkspaces)
        } catch {
            recordLocalStorageLoadFailure(.savedWorkspaces, error: error)
        }

        refreshSilentlyReadStoreHealth()
    }

    /// Snippets, recent artifacts, clipboard items and row J's allowed apps are otherwise only read
    /// through `try?` paths, or through no product path at all (the instant resolver's
    /// trigger/artifact lookups, the 1s clipboard poll), so a corrupt file there is invisible: the
    /// feature just silently stops working. These stores have no UI list of their own to surface a
    /// load failure, so probe them here.
    private func refreshSilentlyReadStoreHealth() {
        checkStoreHealth(.snippets) { _ = try snippetStore.loadAll() }
        checkStoreHealth(.recentArtifacts) { _ = try recentArtifactStore.loadAll() }
        checkStoreHealth(.clipboardHistoryItems) { try clipboardHistoryMonitor.verifyHistoryReadable() }
        // Row J's grants belong here for a sharper version of the same reason: a store nothing can
        // read is a store whose grants have all silently vanished, and the visible symptom is Sonny
        // asking about apps the user already allowed — which reads as the feature working badly
        // rather than as a file that will not open. It has no list of its own to fail in until the
        // revocation surface lands, so this probe is the only place it can say so.
        checkStoreHealth(.approvedApps) { _ = try approvedAppStore.loadAll() }
    }

    private func checkStoreHealth(
        _ source: LocalStorageLoadFailureSource,
        load: () throws -> Void
    ) {
        do {
            try load()
            clearLocalStorageLoadFailure(source)
        } catch {
            recordLocalStorageLoadFailure(source, error: error)
        }
    }

    /// The vision journal this run may write to, or `nil` when it may not.
    ///
    /// Internal and separated from its one call site for the same reason
    /// `recentArtifactStoreForThisRun` is (PR #67 review, F1): the decision was previously inline in
    /// `makeLiveVisionEnvironment()`, which **no test in this repository can execute** — under test
    /// `makeVisionEnvironment` returns `nil` without an API key, and the vision tests inject
    /// `visionSessionEnvironment` directly, bypassing the function. So a mutation handing over the
    /// store regardless of policy survived the whole suite. Asserting the decision *is* asserting
    /// the suppression, because row I built a `nil` journal store as "run the session, record
    /// nothing".
    ///
    /// It is a `.trace` store — the sixth, since row E's plan details — and the one
    /// `LocalStoreClassification` calls the most sensitive of the ten; it had no seam test, no
    /// mutation and no entry under Known limits, while the other traces were each closed or
    /// recorded.
    var visionSessionJournalStoreForThisRun: VisionSessionJournalStore? {
        taskRecordingPolicy.allowsWriting(to: .visionSessionJournal) ? visionSessionJournalStore : nil
    }

    /// The recent-artifacts store this run may write to, or `nil` when it may not.
    ///
    /// Withholding the store rather than checking a flag at the writing site, because `AgentRunner`
    /// already treats a `nil` store as "record nothing" — the same seam row I gave the vision
    /// journal. One definition, read by every `AgentRunner` this view model builds, so a new runner
    /// call site cannot forget the check by omitting it.
    ///
    /// Internal rather than private so the suite can assert the decision directly. Running a real
    /// task through the fixture cannot reach it: the fixture's deterministic planner has no command
    /// that generates an artifact, so a suppressed run leaves this store untouched either way and
    /// the acceptance test passes for the wrong reason. A mutation battery caught exactly that.
    var recentArtifactStoreForThisRun: RecentArtifactStore? {
        taskRecordingPolicy.allowsWriting(to: .recentArtifacts) ? recentArtifactStore : nil
    }

    /// Puts "Don't save this task" back to off and lets clipboard history resume — but only once the
    /// run is really over.
    ///
    /// **Called from each terminal point rather than from one `defer`, because no single `defer`
    /// covers them.** `cancelCurrentRun()` has none at all and is the app-wide deny/cancel entry
    /// point; the two that do exist, in `performStart` and `performApproval`, also fire for *pauses*
    /// — approval needed, clarification needed — where the run is still going and the switch must
    /// stay on. The guard below is what tells those apart, using the same
    /// `approvalRequest == nil && clarificationQuestion == nil` test this file already uses.
    private func finishRecordingPolicyIfSettled() {
        guard approvalRequest == nil, clarificationQuestion == nil, !isRunning else {
            return
        }
        guard taskRecordingPolicy != .record else {
            return
        }
        taskRecordingPolicy = .record
        // Resynchronise *before* monitoring restarts. `poll()` records whenever the pasteboard's
        // change count differs from the last one it saw, and that counter survived the pause — so
        // without this the first poll after a suppressed run records exactly what the user copied
        // during it. Measured: it did.
        clipboardHistoryMonitor.resynchronize()
        // Restored from settings rather than unconditionally started, so a user who has clipboard
        // history switched off does not get it switched on by ending a suppressed task.
        refreshClipboardHistoryNotice()
    }

    /// Publishes a finished run's summary for the notification fallback, when nothing else will
    /// report it. See `completedRunNotice` for why this is the only case.
    /// Internal rather than private so the suite can reach the empty-summary guard. No command the
    /// test fixtures can run produces an empty summary, so a mutation removing that guard survived
    /// an end-to-end battery — the guard matters because an empty notification body would be a
    /// notification that says nothing.
    func publishCompletedRunNoticeIfUnreported(_ summary: String, taskID: String?) {
        guard activeTaskOrigin == .commandCenter else {
            return
        }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        // `taskID` is the id `recordTaskHistoryIfTerminal` returned, handed down from the call
        // site, so a click opens *that* task's detail (PR #67 review, F4).
        //
        // It is passed in rather than re-derived here, and that is the fix for a real defect rather
        // than a preference (PR #67 cycle-3, defect B). This line used to read
        // `taskHistoryRecords.first?.id` — "the newest row must be the one we just wrote". It is
        // not: `completedAt` persists at whole-second resolution, so two runs finishing in the same
        // second compare equal, and `refreshTaskHistory`'s `sorted(by:)` is not stable, so the head
        // can be the earlier row. The notification would then name the wrong task. Whole-second
        // truncation is the same hazard `CompletedTaskRecord.id` exists to defeat (SONNY-115), and
        // it re-entered through the phrase "the most recent row"; the id the write returned cannot
        // tie with anything.
        //
        // `nil` when a suppressed run wrote no row: there is nothing to open, and the notification
        // still tells the user the task finished. An accepted limit, recorded rather than answered
        // with a second behaviour.
        completedRunNotice = CompletedRunNotice(summary: trimmed, taskID: taskID)
    }

    func refreshTaskHistory() {
        do {
            taskHistoryRecords = try taskHistoryStore.loadAll()
                .sorted { $0.completedAt > $1.completedAt }
            clearLocalStorageLoadFailure(.taskHistory)
        } catch {
            taskHistoryRecords = []
            recordLocalStorageLoadFailure(.taskHistory, error: error)
        }
    }

    /// Deletes a task completely — its history row and every record hanging off it.
    ///
    /// **Dependents first, the row last, and the order is not interchangeable.** The row is the only
    /// thing that makes the records hanging off it reachable through the product, so a half-failure
    /// has to leave the row standing:
    ///
    /// - *Dependent gone, row delete failed* → a row whose link resolves to nothing. That is the
    ///   designed dangling-link state row I already ships and the detail view already handles, and
    ///   the user can simply try the delete again.
    /// - *Row gone, dependent delete failed* → a record nobody can reach through the product at all.
    ///   The founder named exactly this as the real defect when declining the never-coupled design
    ///   (SONNY-14, 2026-08-16).
    ///
    /// **This reaches two records today and has to reach three.** The founder moved row E's plan
    /// summary and steps into their own store on 2026-08-17 (SONNY-147, superseding the 2026-08-16
    /// decision to put them on the record). That store shares this row's retention exactly — same
    /// cap, same eviction, deleted together, suppressed together — so when it lands its delete goes
    /// **in the dependents block below, above the row**: not after the row, and not in a second
    /// method a caller could forget to call.
    func deleteTask(_ record: CompletedTaskRecord) {
        guard let id = record.id else {
            // Unreachable in practice — every record `loadAll()` hands out has an id, backfilled if
            // the file predates them. Reachable only if that backfill's rewrite failed, so the
            // message points at the retry that fixes it rather than at the missing field.
            setError("Could not delete this task: its saved copy has no identifier yet. Try again in a moment.")
            return
        }

        do {
            // Dependents first. Row E's detail store joined this block as SONNY-116's own comment
            // said it would.
            if let visionSessionID = record.visionSessionID {
                try visionSessionJournalStore.delete(id: visionSessionID)
            }
            try taskPlanDetailStore.delete(id: id)
            // The row, last.
            try taskHistoryStore.delete(id: id)
        } catch {
            // A delete is a write, so this gets its own accurate wording and never
            // `recordLocalStorageLoadFailure`, whose banner is hardcoded to "could not be decrypted
            // or decoded" and would be simply wrong here.
            setError("Could not delete this task: \(error.localizedDescription)")
            return
        }

        refreshTaskHistory()
    }

    /// Deletes only the screen record, leaving the task row and its `visionSessionID` in place.
    ///
    /// The dangling link this leaves behind is a designed state rather than an error. It is also
    /// deliberately indistinguishable from a screen record that simply aged out at the journal's
    /// cap — pinned by
    /// `TaskHistoryRetentionTests.aDeletedScreenRecordAndAnEvictedOneLeaveTheSameThingBehind`,
    /// because the product cannot tell the two apart without explaining itself and the
    /// no-explanatory-copy rule forbids the explanation.
    ///
    /// **No `refreshTaskHistory()` here, deliberately.** That call exists so `taskHistoryRecords`
    /// agrees with the file, and this delete does not touch task history — the row is byte-identical
    /// afterwards. Calling it anyway would decrypt and decode the whole history file (130 ms at the
    /// cap, measured at `36cef9e`) to reload records that did not change.
    func deleteScreenRecord(for record: CompletedTaskRecord) {
        guard let visionSessionID = record.visionSessionID else {
            return
        }

        do {
            try visionSessionJournalStore.delete(id: visionSessionID)
        } catch {
            setError("Could not delete this task's screen record: \(error.localizedDescription)")
        }
    }

    func refreshClipboardHistoryNotice() {
        let settings: ClipboardHistorySettings
        do {
            settings = try clipboardHistorySettingsStore.load()
            clearLocalStorageLoadFailure(.clipboardHistorySettings)
        } catch {
            stopClipboardHistoryMonitoring()
            recordLocalStorageLoadFailure(.clipboardHistorySettings, error: error)
            return
        }

        clipboardHistoryEnabled = settings.isEnabled

        if settings.noticeDismissed && settings.isEnabled {
            startClipboardHistoryMonitoring()
        } else {
            stopClipboardHistoryMonitoring()
        }
    }

    func applyClipboardHistoryNoticeChoice() {
        let settings = ClipboardHistorySettings(
            noticeDismissed: true,
            isEnabled: clipboardHistoryEnabled
        )
        do {
            try clipboardHistorySettingsStore.save(settings)
            if clipboardHistoryEnabled {
                startClipboardHistoryMonitoring()
            } else {
                stopClipboardHistoryMonitoring()
            }
        } catch {
            setError("Could not save clipboard history setting: \(error.localizedDescription)")
        }
    }

    func deleteLocalData() {
        guard !isRunning else {
            setError("Stop the current run before deleting local data.")
            return
        }

        do {
            stopClipboardHistoryMonitoring()
            let result = try localDataDeletionService.deleteAllLocalData()
            clearInMemoryLocalDataState()
            let noun = result.deletedFileCount == 1 ? "local data file" : "local data files"
            let message = "Deleted \(result.deletedFileCount) \(noun)."
            errorMessage = nil
            localDataDeletionStatusMessage = message
            finalSummary = message
            logStore.append(.observe, message)
        } catch {
            let message = "Could not delete local data: \(error.localizedDescription)"
            localDataDeletionStatusMessage = message
            setError(message)
        }
    }

    /// Creates, replaces, or removes a routine's schedule. Passing nil unschedules it.
    ///
    /// The two methods below can only *modify* an existing schedule — both open with a
    /// `guard let schedule = routine.schedule` — so this is the only path that brings one into
    /// existence. Callers should build the schedule with `RoutineSchedule.newlyCreated(...)`
    /// rather than the initializer, so the catch-up baseline is anchored; see that factory for
    /// what goes wrong otherwise.
    func setRoutineSchedule(_ routine: StoredRoutine, to schedule: RoutineSchedule?) {
        applySchedule(schedule, to: routine.name)
    }

    /// Commits an edited schedule from the detail view's draft.
    ///
    /// Takes the fields rather than a built `RoutineSchedule` on purpose: the view never
    /// constructs one, so the catch-up-baseline invariant cannot drift back into the UI where it
    /// was a trap. Everything goes through `RoutineSchedule.newlyCreated`, which is the single
    /// anchoring path.
    ///
    /// **Editing re-anchors the baseline, and that is deliberate.** Changing a daily routine from
    /// 9am to 7am in the afternoon would otherwise leave the old baseline in place, making today's
    /// 07:00 look outstanding and firing a run — or reporting a missed one — for a time the user
    /// just set. It is the same hazard creation has, reached through a different door. Anchoring at
    /// confirm time means a schedule always starts counting from the moment it became real.
    ///
    /// `isEnabled`, `unattendedTrusted` and `pausedReason` all carry over from the existing
    /// schedule: none is part of the draft, since each is a separate decision about a schedule
    /// rather than a field of one being composed.
    ///
    /// `pausedReason` carrying over matters more than it looks. Editing rebuilds the schedule from
    /// scratch, so before SONNY-31's review this door silently dropped it: changing a paused
    /// routine's run time left the routine switched off with the "Paused" caption and its
    /// explanation gone, which is exactly the unexplained-dead-routine state pausing exists to
    /// end, reached through the editor instead of the scheduler. Enabling remains the only thing
    /// that clears a pause — `newlyCreated` routes this through the same `setEnabled` as every
    /// other path, so an edit that also switches the schedule on still clears it.
    func commitScheduleDraft(
        for routine: StoredRoutine,
        cadence: RoutineCadence,
        hour: Int,
        minute: Int,
        weekday: Int,
        dayOfMonth: Int,
        now: Date = Date()
    ) {
        let existing = routine.schedule
        applySchedule(
            .newlyCreated(
                cadence: cadence,
                hour: hour,
                minute: minute,
                // Both are passed regardless of cadence so switching back and forth in the draft
                // does not silently discard a choice; `validate()` only checks the one that
                // applies.
                weekday: weekday,
                dayOfMonth: dayOfMonth,
                isEnabled: existing?.isEnabled ?? true,
                unattendedTrusted: existing?.unattendedTrusted ?? false,
                pausedReason: existing?.pausedReason,
                now: now
            ),
            to: routine.name
        )
    }

    /// Turns a routine's schedule on or off from the Routines row.
    ///
    /// Goes through `RoutineSchedule.setEnabled(_:now:)` rather than assigning `isEnabled`, because
    /// that is what re-anchors the catch-up baseline — enabling a 9am routine at 3pm must not read
    /// as "this morning was missed" and fire an immediate unattended run.
    /// Takes `now` for the same reason `commitScheduleDraft` and `checkScheduledRoutines` do: the
    /// re-anchor this performs is the thing under test in the resume path, and a test that cannot
    /// name the instant it anchored to has to compare against the wall clock.
    func setRoutineScheduleEnabled(_ routine: StoredRoutine, to isEnabled: Bool, now: Date = Date()) {
        guard var schedule = routine.schedule else {
            return
        }
        schedule.setEnabled(isEnabled, now: now)
        applySchedule(schedule, to: routine.name)
    }

    /// Turns the per-routine trust opt-in on or off — the grant that lets this routine's runs,
    /// scheduled and manual alike (SONNY-54), carry a tier-2 approval instead of pausing to ask —
    /// returning advisory copy when the routine currently assesses at tier 3+ and the grant
    /// therefore cannot cover it anyway.
    ///
    /// The advisory is a heads-up, never a gate — blocking the opt-in here would be the save-time
    /// tier gating this branch explicitly rejected. It is also best-effort: tiers escalate from
    /// real run-time conditions, so a routine that reads clean today can still pause its schedule
    /// (or prompt on a manual run) later.
    @discardableResult
    func setRoutineUnattendedTrust(_ routine: StoredRoutine, to isTrusted: Bool) -> String? {
        guard var schedule = routine.schedule else {
            return nil
        }
        schedule.unattendedTrusted = isTrusted
        applySchedule(schedule, to: routine.name)
        guard isTrusted else {
            return nil
        }
        return UnattendedTrustAdvisory.warning(forRoutineNamed: routine.name, executor: makeExecutor())
    }

    /// The approval decision a manual dispatch may carry on the user's standing per-routine trust
    /// grant: `.approved(.tier2)` when the prepared plan is exactly the canonical single-step
    /// run-routine shape and the named routine is trusted, `.notRequested` otherwise (SONNY-54).
    ///
    /// The routine is re-derived from the plan, never taken from a call site: the planner path
    /// only ever holds the step's `routineName` string, and `runRoutineWidget` deliberately
    /// round-trips through the same text command a user would type. The lookup goes through
    /// `routineStore.routine(named:)` — the identical normalized lookup
    /// `RunRoutineCapabilityAdapter` performs at execute time — so the routine this check reads
    /// and the routine that actually runs cannot resolve differently. Every failure (no such
    /// routine, unreadable store, missing name) yields `.notRequested`: a trust check that cannot
    /// complete relaxes nothing.
    ///
    /// Single-step on purpose: the grant covers the routine's own saved steps, so a planner-built
    /// plan wrapping `run_routine` alongside anything else keeps the full prompt — the extra steps
    /// were never part of what the user marked trusted.
    ///
    /// Internal rather than private so tests can pin the shape rules directly — the planner is not
    /// injectable at this level, so a mixed plan cannot be produced end-to-end in a test.
    func manualRoutineTrustDecision(for plan: AgentPlan) -> RiskApprovalDecision {
        guard plan.steps.count == 1,
              let step = plan.steps.first,
              step.operation == .runRoutine,
              let routineName = step.routineName,
              let routine = try? routineStore.routine(named: routineName),
              routine.schedule?.unattendedTrusted == true else {
            return .notRequested
        }
        return .approved(.tier2)
    }

    private func applySchedule(_ schedule: RoutineSchedule?, to routineName: String) {
        do {
            try routineStore.setSchedule(routineNamed: routineName, to: schedule)
            refreshSavedItems()
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's schedule: \(error.localizedDescription)"
            )
        }
    }

    func runRoutineWidget(_ routine: StoredRoutine) {
        dispatch(command: "Run my \(routine.name) routine", autoExecute: true)
    }

    /// The workspace card's "New task here" action: bring the widget forward with an empty
    /// composer, bound to this workspace.
    ///
    /// Distinct from `openWorkspaceWidget` below, which synthesizes a literal command and runs it.
    /// This one starts nothing — it queues the binding and hands the user a cursor, which is the
    /// half of the founder decision ("started from its card") that had no affordance at all.
    ///
    /// Summons through `widgetPresentationRequest`, never `FloatingWidgetWindowController.show()`:
    /// SONNY-25 exists to remove the remaining direct callers and this must not add one.
    func beginTaskInWorkspace(_ workspace: StoredWorkspace) {
        pendingWorkspaceBinding = workspace.name
        command = ""
        widgetPresentationRequest += 1
    }

    /// Drops a queued card binding before anything has been submitted.
    ///
    /// Only ever clears the *pending* slot. A task already in flight keeps the scope it was
    /// assessed under — un-scoping mid-run would mean the approval the user answered and the
    /// execution that follows it disagreed about the boundary.
    func clearPendingWorkspaceBinding() {
        pendingWorkspaceBinding = nil
    }

    func openWorkspaceWidget(_ workspace: StoredWorkspace) {
        dispatch(command: "Open my \(workspace.name) workspace", autoExecute: true)
    }

    /// Submits one boundary change the workspace detail sheet already knows exactly — SONNY-64.
    ///
    /// **This dispatches where its predecessor composed, and that is the whole ticket.** Until now
    /// the sheet handed the widget composer a ready-made sentence and stopped, because
    /// `AgentViewModel` had no way to run a plan that a screen had built: the only routes to
    /// execution started from text, so "run this edit" meant "have the planner read this sentence
    /// back", and a planner misreading of *remove the folder ~/Documents/X* is a boundary change
    /// nobody typed. The pre-built path removes the reading step instead of trusting it. What the
    /// user approves is now, exactly and provably, what the row said.
    ///
    /// **It still writes nothing itself.** Every scope mutation goes through `edit_workspace`, so
    /// the tier-2 add and tier-3 remove consents — including SONNY-40's "no longer restricts … at
    /// all" — are the ones the command line raises, unchanged and unshortened. A store call here
    /// would be the second write path SONNY-41 adjudicated against; the sheet's one direct write is
    /// still `markWorkspaceAsTeam`, a display badge rather than a boundary.
    ///
    /// **It is not `fromComposer`, so an accepted dispatch kills any armed card binding** rather than
    /// inheriting one. An edit dispatched from workspace B's sheet while "New task here" is armed on
    /// workspace A would otherwise run bound to A while editing B, under a chip naming A. `start`
    /// does the killing; it is named here because the reason is this function's, not `start`'s.
    ///
    /// A *refused* dispatch leaves the arm alone, and that is the correct rule rather than a gap in
    /// this one. The arm's contract is that it binds the next composer dispatch, and a refusal means
    /// no dispatch happened — so the user's earlier "New task here on A" is still unconsumed and
    /// still what they asked for. Killing it here would silently discard an intent because an
    /// unrelated button was pressed at an unlucky moment.
    ///
    /// The arm is not hidden, but it is not necessarily on screen at the moment of the refusal
    /// either: `boundWorkspaceName` prefers the *in-flight* task's binding and falls back to the
    /// arm, so while the task that caused the refusal is still live the chip names that task's
    /// workspace and the arm reappears once it clears. Written out because "the arm stays visible"
    /// is the tempting summary and it is wrong for exactly the window this path runs in.
    ///
    /// **Refusals.** The clarification-pause door and the already-running door are both inherited
    /// rather than re-implemented: this goes through `dispatch`, so `canSubmit`'s terms apply to it
    /// exactly as they apply to the composer's own Send. That is deliberate — H1's lesson was that
    /// a per-surface copy of the rule is a gap waiting for the next surface, and a fourth copy here
    /// would be the fourth chance to write it slightly differently. The log line is the part that is
    /// this function's own, because a button that appears to do nothing needs a reason recorded
    /// somewhere.
    ///
    /// **Summons the widget on success, through `widgetPresentationRequest` and never
    /// `FloatingWidgetWindowController.show()`** (SONNY-25). Not decoration: under the consequence
    /// rule (2026-08-13) every sheet edit runs without asking, and the widget's result panel — with
    /// its ran-without-asking trace — is where that silent run is disclosed; the sheet is a modal
    /// over the very page whose Command Center surfaces would otherwise show it, and the floating
    /// widget is the one surface a modal cannot cover. (Before the rule, the same summon carried
    /// the approval prompt these edits used to raise; if a drift re-arm ever prompts mid-edit, it
    /// still does.)
    /// - Returns: whether the edit was submitted. The picker keeps itself open on `false` rather
    ///   than closing over a refusal — its controls are disabled while a task is in flight, so a
    ///   refusal here means the state changed between the render and the click, and dismissing would
    ///   leave the user with a dialog that closed and an edit that never happened.
    @discardableResult
    func dispatchWorkspaceScopeEdit(_ edit: WorkspaceScopeEditDispatch) -> Bool {
        let accepted = dispatch(
            command: edit.displayCommand,
            prebuiltPlan: EditWorkspaceCapabilityAdapter.plan(for: edit.request)
        )
        guard accepted else {
            // No message of its own any more: `dispatch` records the refusal for every door, and
            // this one's wording claimed "another task needs you", which is true of a pending
            // approval or an open clarification and false of a plain in-flight run where nothing
            // needs the user at all. One accurate line beats a specific inaccurate one. (PR #40
            // review, cycle 1 — the recorded observation, fixed while F5 was open in the same
            // function.)
            return false
        }
        widgetPresentationRequest += 1
        return true
    }

    func markWorkspaceAsTeam(_ workspace: StoredWorkspace) {
        var updated = workspace
        updated.teamType = .team
        do {
            try workspaceStore.save(updated)
            refreshSavedItems()
        } catch {
            setError("Could not update workspace: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a saved routine — steps, schedule, and run history all live under the
    /// same store key, so all three go together.
    ///
    /// Guarded on more than `isRunning`: a run paused at an approval still holds a prepared plan
    /// that re-reads the store when approved, so deleting out from under it has the same failure as
    /// deleting mid-run.
    ///
    /// **This guard is `isRunning || isAwaitingApproval`, which is the *running-indicator* gate, not
    /// the app's "task in flight" condition.** The doc used to call it the latter and cite
    /// `checkScheduledRoutines` as sharing it; that pointer went stale when the scheduler gained a
    /// third term (`clarificationQuestion == nil`, PR #80 review, F1), and it was loose even before
    /// — `isTaskInFlight` has always been the three-term property, and its own doc comment says the
    /// clarification term is the one that keeps getting left out. Corrected rather than widened:
    /// whether deleting a routine during a clarification pause should also be refused is a real
    /// question this round did not decide, and quietly changing the guard while fixing its comment
    /// would answer it by accident.
    ///
    /// `deleteLocalData`'s narrower `isRunning`-only guard predates even this convention and is left
    /// as it is here. `deleteWorkspace` points at this comment rather than repeating it.
    func deleteRoutine(_ routine: StoredRoutine) {
        guard !isRunning, !isAwaitingApproval else {
            setError("Finish or stop the current task before deleting this routine.")
            return
        }
        do {
            try routineStore.delete(routineNamed: routine.name)
            refreshSavedItems()
        } catch {
            setError("Could not delete routine: \(error.localizedDescription)")
        }
    }

    /// Permanently deletes a saved workspace. See `deleteRoutine` for the in-flight guard's
    /// rationale.
    func deleteWorkspace(_ workspace: StoredWorkspace) {
        guard !isRunning, !isAwaitingApproval else {
            setError("Finish or stop the current task before deleting this workspace.")
            return
        }
        do {
            try workspaceStore.delete(workspaceNamed: workspace.name)
            // An arm naming this workspace dies with it. The chip must never promise a boundary the
            // run will not apply: `resolveTaskScope` returns `.unscoped` for a name the store no
            // longer has, so leaving the arm alive would render "In X" over a task that runs
            // unscoped. Compared through the store's own folding rather than `==`, so the arm and
            // the record are matched the same way every other lookup matches them.
            if let armed = pendingWorkspaceBinding,
               (try? workspaceStore.workspace(named: armed)) == nil {
                pendingWorkspaceBinding = nil
            }
            refreshSavedItems()
        } catch {
            setError("Could not delete workspace: \(error.localizedDescription)")
        }
    }

    func runSuggestion(_ suggestion: RunSuggestion) {
        let url = URL(fileURLWithPath: suggestion.value)
        switch suggestion.kind {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFile:
            NSWorkspace.shared.open(url)
        }
    }

    func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(finalSummary, forType: .string)
    }

    /// Wipes the in-memory half of "delete all local data": every slot that describes a task, so
    /// nothing the deleted files were about survives them on screen.
    ///
    /// **This enumeration is hand-written, and it has now been missed three times — read the rule
    /// below before adding a stored property to this class.** A new field does not arrive here on
    /// its own, the compiler cannot notice its absence, and the failure mode is never a crash: it is
    /// a stale sentence rendered next to an unrelated summary, which reads as a statement about that
    /// summary. The three:
    ///
    /// 1. `explicitWorkspaceBinding` — filed by SONNY-38's review against this same function.
    /// 2. `pendingWorkspaceBinding` — a new binding field one ticket later, the identical omission,
    ///    which is why the list below is written out rather than trusted.
    /// 3. `ranWithoutAskingTrace` — SONNY-99's trace, filed by PR #48's review. `deleteLocalData`
    ///    writes its own `finalSummary`, and `WidgetResultPanel` renders the trace under whatever
    ///    summary is showing, so a surviving trace put "nothing here is destructive" beneath the one
    ///    deliberately destructive action in the app.
    ///
    /// **The rule, now enforced rather than remembered:** every stored property on this view model
    /// is classified into exactly one of three sets — cleared here, refreshed by one of the three
    /// `refresh…` calls at the end of this function, or deliberately kept (dependencies, settings,
    /// surface preferences). `everyAgentViewModelStoredPropertyIsClassifiedAgainstTheLocalDataWipe`
    /// (`ProductShellTests`) reflects over the real instance and fails by name on any property in
    /// none of the three, so a fourth omission is a red test rather than a fourth review finding.
    /// Adding a field is therefore a decision, not an oversight: put it in a set, with its reason.
    private func clearInMemoryLocalDataState() {
        plan = nil
        suggestions = []
        approvalRequest = nil
        stepStatuses = [:]
        priorTaskContext = nil
        taskUsageSummary = .empty
        taskHistoryRecords = []
        // A finished run's summary is residue of a run whose record the wipe just erased, so it
        // goes with it rather than lingering in memory.
        completedRunNotice = nil
        // A pending request to open a task's detail would point at a row the wipe has just erased.
        taskDetailRequest = nil
        // And the marker that describes an outcome goes with the outcome. `deleteLocalData` writes
        // its own message into `finalSummary` immediately after this returns, and a stale `true`
        // here would make *that* message un-collapsible for a notification nobody sent.
        outcomeWasNotified = false
        // Cleared with the records it filters, not left behind. A stale query over an emptied
        // history would put the Tasks page in its "No matching tasks — try a different word" state,
        // when the honest thing to tell someone who just erased everything is that there is nothing
        // there at all.
        taskHistoryQuery = ""
        clarificationQuestion = nil
        clarificationAnswer = ""
        clarificationAutoExecute = false
        clarificationWorkspaceBinding = nil
        activeTaskScope = .unscoped
        ranWithoutAskingTrace = nil
        explicitWorkspaceBinding = nil
        pendingWorkspaceBinding = nil
        preparedRun = nil
        runner = nil
        pendingCommandForPriorTaskContext = nil
        pendingTaskHistoryStartedAt = nil
        preserveUsageForNextStart = false
        priorTaskContextStore.clear()
        taskUsageRecorder.reset()
        logStore.reset()
        refreshSavedItems()
        refreshTaskHistory()
        refreshClipboardHistoryNotice()
    }

    private func startClipboardHistoryMonitoring() {
        guard clipboardHistoryTimer == nil else {
            return
        }

        pollClipboardHistory()
        clipboardHistoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboardHistory()
            }
        }
    }

    /// Surfaces a polling failure once rather than discarding it every second. Without this the
    /// clipboard toggle can read "on" while nothing is actually being recorded — a settings-read
    /// failure now fails closed in the monitor, so silence here would hide a privacy-relevant
    /// state from the user indefinitely.
    private func pollClipboardHistory() {
        do {
            _ = try clipboardHistoryMonitor.poll()
            if clipboardHistoryPollFailure != nil {
                clipboardHistoryPollFailure = nil
                localStorageNotice = nil
            }
        } catch {
            let description = error.localizedDescription
            guard clipboardHistoryPollFailure != description else {
                return
            }
            clipboardHistoryPollFailure = description
            recordLocalStorageWriteFailure(description)
        }
    }

    private func stopClipboardHistoryMonitoring() {
        clipboardHistoryTimer?.invalidate()
        clipboardHistoryTimer = nil
    }

    private func recordLocalStorageLoadFailure(_ source: LocalStorageLoadFailureSource, error: Error) {
        localStorageLoadFailures[source] = "\(source.label): \(error.localizedDescription)"
        publishLocalStorageLoadError()
    }

    private func clearLocalStorageLoadFailure(_ source: LocalStorageLoadFailureSource) {
        guard localStorageLoadFailures.removeValue(forKey: source) != nil else {
            return
        }
        publishLocalStorageLoadError()
    }

    /// Local-storage problems publish to `localStorageNotice`, never to `errorMessage`.
    /// `errorMessage` means "the task you just ran failed" — routing a corrupt-store notice
    /// there made a *successful* task render as a failure in the widget, since the widget picks
    /// `.failure` ahead of `.result`.
    private func publishLocalStorageLoadError() {
        guard !localStorageLoadFailures.isEmpty else {
            localStorageNotice = nil
            return
        }

        let details = LocalStorageLoadFailureSource.allCases
            .compactMap { localStorageLoadFailures[$0] }
            .joined(separator: "; ")
        // The headline names the *kind* of problem; each detail names the store and why that one
        // failed. It used to also hardcode "A local data file exists but could not be decrypted or
        // decoded.", which was the one distinguishing thing a detail carried back when the underlying
        // errors rendered as raw CryptoKit codes. SONNY-30 gave those errors that exact sentence as
        // their description, so the banner started saying it twice and the per-source detail
        // degraded to a repeat of the line above it (PR #41 cycle-3, R4). Dropping it here rather
        // than from the detail keeps the details distinguishable when two stores fail for *different*
        // reasons — a decrypt failure and a bad key are not the same problem and must not read alike.
        localStorageNotice = "Sonny could not load encrypted local data. \(details)"
    }

    /// A local-store *write* failure, which needs its own accurate wording — the load-failure
    /// text ("could not be decrypted or decoded") describes the wrong problem entirely.
    func recordLocalStorageWriteFailure(_ description: String) {
        localStorageNotice = description
    }

    func makeInstantCommandResolver() -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: snippetStore,
            recentArtifactStore: recentArtifactStore,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            shortcutCatalog: shortcutCatalog
        )
    }

    /// A test-supplied vision substrate, or `nil` to build the live one.
    ///
    /// Injected rather than defaulted for the same reason every other machine-touching seam on this
    /// class is: the live environment posts real mouse events, and a test that reached it would move
    /// the developer's cursor. No test in this repo may construct `SystemScreenActionSynthesizer`.
    var visionSessionEnvironment: VisionSessionEnvironment?

    /// Internal rather than `private` so the vision extension in another file can build the
    /// executor a delegated plan runs through — the *same* executor factory the ordinary path uses,
    /// which is what makes "a delegated command meets the gate a typed one would" true by
    /// construction rather than by a parallel wiring that has to be kept in step.
    /// The planner a delegated vision instruction is planned by — the same registry call, with the
    /// same selection, that plans a typed command.
    ///
    /// One named door rather than widening `plannerProviderRegistry`, `plannerSelection` and
    /// `taskUsageRecorder` to internal: what the vision extension needs is a planner, not three
    /// fields, and keeping the registry call in this file is what makes "a delegated instruction is
    /// planned by whatever would have planned the user's own sentence" true by construction. The
    /// fallback notice is surfaced here too, exactly as the ordinary path surfaces it.
    /// The whole runner a delegated instruction goes through — same executor factory, same planner
    /// registry, same log store, same artifact store as the ordinary path.
    func makeDelegationRunner() throws -> AgentRunner {
        AgentRunner(
            planner: try makeDelegationPlanner(),
            executor: makeExecutor(),
            logStore: logStore,
            recentArtifactStore: recentArtifactStoreForThisRun
        )
    }

    private func makeDelegationPlanner() throws -> any Planning {
        let selected = try plannerProviderRegistry.makePlanner(
            selection: plannerSelection,
            usageRecorder: taskUsageRecorder
        )
        if let notice = selected.fallbackNotice {
            plannerFallbackNotice = notice
            logStore.append(.plan, notice)
        }
        return selected.planner
    }

    /// Builds the live vision environment and keeps a handle on the pause wrapper the HUD writes to.
    ///
    /// The handle is why this is not inline: `pauseVisionSession()` needs the *same* monitor the
    /// running session is consulting, and a second one built later would be a Pause button wired to
    /// nothing.
    private func makeLiveVisionEnvironment() -> VisionSessionEnvironment? {
        let monitor = UserPausableAttentionMonitor(base: SystemSessionAttentionMonitor())
        guard let environment = Self.makeVisionEnvironment(
            interaction: self,
            userPauseMonitor: monitor,
            // The seam row I already built: `VisionSessionEnvironment.journalStore` is Optional, and
            // a nil one runs the session normally and records nothing. So "Don't save this task"
            // withholds the store rather than adding a branch inside the loop — which the ticket's
            // never-touch list forbids, and which would have been a second place to forget.
            journalStore: visionSessionJournalStoreForThisRun
        ) else {
            return nil
        }
        visionUserPauseMonitor = monitor
        return environment
    }

    /// - Parameter recordingPolicy: defaulted to this run's policy. The scheduled path passes
    ///   `.record` explicitly — see `performScheduledRun`.
    func makeExecutor(recordingPolicy: TaskRecordingPolicy? = nil) -> AgentActionExecutor {
        AgentActionExecutor(
            // A fresh executor per run, so this cannot leak into the next task.
            recordingPolicy: recordingPolicy ?? taskRecordingPolicy,
            whitelist: whitelist,
            zipArchiver: zipArchiver,
            documentConverter: documentConverter,
            browserOpener: browserOpener,
            appOpener: appOpener,
            fileOpener: fileOpener,
            mediaOpener: mediaOpener,
            finderContextReader: finderContextReader,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            // `try?` is the degradation path, not error swallowing: construction only throws for
            // a missing TAVILY_API_KEY, and nil falls back to `UnavailableWebSearchProvider`'s
            // existing "Web search provider not configured." error. Constructed per executor like
            // everything else here, so a key exported after launch works on the next run.
            webSearchProvider: try? TavilySearchProvider(),
            usageRecorder: taskUsageRecorder,
            snippetStore: snippetStore,
            runningAppSwitcher: runningAppSwitcher,
            recentArtifactStore: recentArtifactStore,
            shortcutCatalog: shortcutCatalog,
            shortcutInvoker: shortcutInvoker,
            shortcutRunHistoryStore: shortcutRunHistoryStore,
            hotKeyReady: { [weak self] in self?.voiceHotKeyReady ?? true },
            // `nil` when OPENCODE_API_KEY is unset — the same degradation shape as the Tavily key
            // above. A vision session dispatched into an executor built that way fails loudly with
            // `visionUnavailable` rather than half-running; `visionSessionEnvironment` is an
            // injectable seam so a test supplies its own substrate and never touches the machine.
            visionSession: visionSessionEnvironment ?? makeLiveVisionEnvironment()
        )
    }

    private func startVoiceRecording(trigger: VoiceRecordingTrigger, origin: TaskOrigin) {
        guard canUseVoice else {
            reportVoiceRefusal()
            return
        }

        voiceRecordingOrigin = origin
        isPreparingVoiceRecording = true

        Task {
            let granted = await AudioCommandRecorder.requestMicrophonePermission()
            guard granted else {
                isPreparingVoiceRecording = false
                setError("Microphone permission was denied. Allow microphone access for the launching app, then try again.", persistent: true)
                return
            }

            if trigger == .hotKey && !isPushToTalkHotKeyDown {
                isPreparingVoiceRecording = false
                return
            }

            do {
                try audioRecorder.start()
                if trigger == .hotKey && !isPushToTalkHotKeyDown {
                    audioRecorder.cancel()
                    isPreparingVoiceRecording = false
                    return
                }

                isPreparingVoiceRecording = false
                isRecordingVoice = true
                finalSummary = ""
                errorMessage = nil
                // A fresh recording is a fresh interaction — clear the *previous* task's leftovers
                // now, not only once a real submission reaches `performStart`. Otherwise, if this
                // new attempt fails before ever getting that far (e.g. transcription comes back
                // with no text), the failure panel reuses `WidgetExistingStepRows` and renders the
                // old, unrelated task's step rows above the new error — a real, reported bug.
                plan = nil
                stepStatuses = [:]
                suggestions = []
                let recordingMessage = trigger == .hotKey
                    ? "Recording voice command from hotkey"
                    : "Recording voice command"
                logStore.append(.observe, recordingMessage)
            } catch {
                isPreparingVoiceRecording = false
                setError(error.localizedDescription)
                logStore.append(.summarize, "Voice recording failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopVoiceRecordingAndTranscribe() {
        let audioURL: URL
        do {
            audioURL = try audioRecorder.stop()
            isRecordingVoice = false
        } catch {
            isRecordingVoice = false
            isPushToTalkHotKeyDown = false
            setError(error.localizedDescription)
            return
        }

        Task {
            taskUsageRecorder.reset()
            taskUsageSummary = .empty
            isTranscribingVoice = true
            errorMessage = nil
            logStore.append(.act, "Transcribing voice command")
            defer {
                publishTaskUsageSummary()
                try? FileManager.default.removeItem(at: audioURL)
            }

            do {
                let transcriber = try OpenAITranscriber(usageRecorder: taskUsageRecorder)
                let result = try await transcriber.transcribe(audioFileURL: audioURL)
                // Deliberately does *not* write `command` here. `dispatchTranscribedCommand` routes
                // through `dispatch`, which assigns it and clears it again if the dispatch is
                // refused — writing it first would reinstate exactly the residue this round removes,
                // for a transcription that completed into a clarification pause.
                finalSummary = ""
                isTranscribingVoice = false
                preserveUsageForNextStart = true
                // States only what is known here. "Sonny will act now" was written *before* the
                // dispatch and was contradicted by it whenever the dispatch was refused — a
                // transcription that completed into a pending approval left the spoken words gone,
                // no error set, and this sentence as the last thing said about them. What happens
                // next is `dispatch`'s to record, and it now does, on every door. (PR #40 review, F5.)
                logStore.append(.observe, "Transcript ready.")
                dispatchTranscribedCommand(result.text, origin: voiceRecordingOrigin)
            } catch {
                isTranscribingVoice = false
                // This is the bug that made the auto-clear timer feel broken: a failed
                // transcription (e.g. no speech captured) never calls `start()`, so it never
                // touches `lastCommand` — the old `hasRetryableCommand`-based gate treated that
                // exactly like a persistent config problem and refused to time it out. It isn't
                // one: try again and it's just as likely to work fine.
                setError(error.localizedDescription)
                logStore.append(.summarize, "Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    /// The dispatch a completed voice transcription issues — the one implementation, called by the
    /// real completion above and driven directly by tests.
    ///
    /// Internal rather than private so it is reachable without a real transcriber and an API key,
    /// which is what the live path needs. It is a seam, not a reimplementation: there is exactly one
    /// copy of the guard and one `start(...)` call, so a test that exercises this exercises what
    /// ships.
    ///
    /// **The guard is here as well as in `canUseVoice` for a reason, not by belt-and-braces habit.**
    /// `canUseVoice` gates the *entry* points — the mic button and push-to-talk — but a
    /// transcription already in flight when a clarification arrives would still land here. Refusing
    /// at the dispatch makes the guarantee independent of that timing.
    func dispatchTranscribedCommand(_ transcript: String, origin: TaskOrigin = .widget) {
        guard clarificationQuestion == nil else {
            logStore.append(.observe, "Voice command ignored while a clarification is open.")
            return
        }
        // Voice submitted from the widget's own mic *is* the composer, with the chip visible; from
        // anywhere else it is not. Routed through `dispatch` so a refusal for any *other* reason —
        // a run that started between the transcription and this call — leaves no residue either;
        // the guard above stays because it is the one this method's own contract names.
        dispatch(
            command: transcript,
            autoExecute: true,
            origin: origin,
            fromComposer: origin == .widget
        )
    }

    /// Resolves which workspace this task is in, and loads it into a scope.
    ///
    /// Two signals, in a fixed order. An **explicit binding** from a dispatch that already knows its
    /// workspace (B4's card action) wins; otherwise the name is resolved from the plan and command
    /// by `WorkspaceTaskTagging`, reused exactly as it stands. That resolver already matches
    /// `in [the|my] workspace X` — and, since SONNY-68, `in [the|my] X workspace` — against real
    /// saved names using the stores' own case/diacritic folding,
    /// with a documented leftmost-then-longest tie-break and deliberate non-`\b` boundary checks —
    /// writing a second matcher here would give one concept two behaviours, which is how "why did it
    /// tag that" bugs start. It is the same call `recordPriorTaskContext` already makes for task
    /// history; the difference is purely *when*, and that is the whole ticket: history tags after a
    /// task terminates, this runs before it is assessed.
    ///
    /// Returns `.unscoped` for a name that no longer resolves to a stored record — a workspace
    /// deleted between dispatch and assessment binds to nothing rather than to an empty boundary,
    /// because an empty `WorkspaceScope` would report `.unconstrained` for every kind and read as a
    /// workspace that restricts nothing rather than as no workspace at all.
    ///
    /// **A store that will not load is a different thing from a workspace that is not there, and this
    /// used to answer both the same way** (SONNY-78). The read was `try? workspaceStore.workspace(named:)`,
    /// which throws `.missingWorkspace` for absence and rethrows a file-read, AES-GCM authentication
    /// or JSON-decode failure — so an unreadable `workspaces.json` silently unbound the task, and
    /// `.unscoped` is not a smaller boundary but no boundary: `assessRisk` computes scope findings
    /// only when a workspace scope is present, so every out-of-scope advisory for that run vanished
    /// along with the sentence the ran-without-asking trace would have carried. `findWorkspace(named:)`
    /// (SONNY-30's primitive, added for exactly this distinction) answers `nil` only when the load
    /// succeeded and nothing matched.
    ///
    /// **A load failure says so and the run continues, rather than being refused.** It goes to this
    /// file's own load-failure channel, which publishes to `localStorageNotice` and never to
    /// `errorMessage` — a corrupt store is not this task failing. Refusing the dispatch was the
    /// alternative and is declined: since the consequence rule, a workspace scope gates no prompt at
    /// all (its escalation is `.advisory`), so a lost boundary costs legibility rather than
    /// permission, and blocking a task the user asked for in order to report a storage problem
    /// inverts escalate-never-block for no safety gain. What the user gets instead is the same
    /// banner every other unreadable store raises, naming this one.
    private func resolveTaskScope(command: String, plan: AgentPlan?) -> TaskWorkspaceScope {
        let resolvedName = explicitWorkspaceBinding ?? WorkspaceTaskTagging.resolvedWorkspaceName(
            command: command,
            plan: plan,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )
        // **A blank name is no name, and it must never reach the store** (PR #83, F1). `findWorkspace`
        // validates before it loads: `normalizedName` throws `.missingName` for a blank or
        // whitespace-only string *without touching the file*, so handing it one and reporting the
        // throw below would put "could not load encrypted local data" in front of a user whose store
        // is perfectly healthy.
        //
        // Reachable with no tampering at all. The planner schema requires a `workspaceName` slot on
        // every step and `""` is a valid value for it; nothing normalises blank to `nil` on the way
        // in; and `WorkspaceTaskTagging.directWorkspaceName` is `steps.compactMap(\.workspaceName).first`,
        // which reads the field off *any* operation rather than only the workspace ones. The
        // persisted form is worse than the transient one: `validateStepSafety` checks operations and
        // not fields, so a routine can be saved carrying a stray `""`, and `nestedRoutineWorkspaceName`
        // then reproduces it on every single run of that routine.
        //
        // Guarded here rather than caught below, so the store is never asked a question that has no
        // answer. It also leaves the `catch` honestly storage-only: `.missingName` is the one
        // non-storage error `findWorkspace` can raise, and this is what makes it unreachable from
        // there.
        guard let resolvedName,
              !resolvedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unscoped
        }

        let found: StoredWorkspace?
        do {
            found = try workspaceStore.findWorkspace(named: resolvedName)
            clearLocalStorageLoadFailure(.savedWorkspaces)
        } catch {
            recordLocalStorageLoadFailure(.savedWorkspaces, error: error)
            return .unscoped
        }

        guard let record = found else {
            return .unscoped
        }
        // The injected whitelist, not `WorkspaceScope`'s default: the scope's idea of a valid file
        // location and the executor's must come from one object, or a test-injected root would
        // assess under a scope that thinks the same path is inert.
        return .scoped(WorkspaceScope(workspace: record, whitelist: whitelist))
    }

    /// The product's one posture dial — Safe | Normal | Power, the founder's segmented control
    /// (SONNY-90 as amended 2026-08-14; wireframe `docs/wireframes/15-SegmentedControl.svg`).
    /// Safe asks before everything attended and is the only place the data-leaves-device label
    /// renders (E9's ratified §11.3 deviation); Normal is the consequence-rule default; Power is
    /// identical to Normal today — row 18's mode landing as a setting first, gating nothing (this
    /// sentence used to say row I's screen-control features gate on it; the founder decided on
    /// 2026-08-14 that screen control works in all three modes, and only Safe asks about it).
    /// Persisted so the dial survives relaunch — a posture that
    /// silently reset to Normal on restart would quietly un-dial itself. Defaults to Normal, the
    /// ratified product default.
    @Published var interactionMode: AgentInteractionMode = .normal {
        didSet {
            userDefaults.set(interactionMode.rawValue, forKey: UserDefaultsKeys.interactionMode)
        }
    }

    /// The authority context every dispatch threads into `AgentRunner`: Safe mode, and nothing
    /// else today (the consequence rule reads no origin — it gates on what an action does).
    ///
    /// **`interactionMode` is mapped to the engine here and nowhere else.** A second site
    /// reading its own value would be a second place that work has to find, and the one it
    /// misses would run a Safe-mode user's tasks under ordinary rules. The engine's input stays
    /// row C's boolean seam; Normal and Power both map false, and row I did not change that —
    /// screen control runs in every mode, so Safe's existing "ask about everything" posture is
    /// exactly what makes Safe the only mode that asks about a vision action.
    // Internal rather than `private`: the vision extension lives in another file and
    // `visionApprovalContext()` forwards to this one function, which is what keeps the
    // "mapped to the engine here and nowhere else" rule true across the split.
    /// The third real approval-resolution point: a user answering a mid-loop vision approval.
    ///
    /// It is a real resolution by the flag's own definition — "the first time the user resolves
    /// *any* approval, allow or deny" — and a vision session is where a user is most likely to meet
    /// their first approval, since it is the one capability that asks mid-run.
    func markFirstApprovalCompleted() {
        hasCompletedFirstApproval = true
    }

    func approvalContext() -> ApprovalContext {
        // The mode travels whole now (SONNY-142). It used to be folded through
        // `asksBeforeEveryAction` into a boolean here, which made Normal and Power indistinguishable
        // to the engine — correct while the engine distinguished two postures, and wrong the moment
        // row J gave Power a rule of its own.
        //
        // `appControl` is `.notApplicable` at every construction site until SONNY-143 resolves it,
        // which is deliberate and is why the parameter is not defaulted: every caller answers it.
        ApprovalContext(mode: interactionMode, appControl: .notApplicable)
    }

    private func executePreparedRun(
        preparedRun: PreparedAgentRun,
        runner: AgentRunner,
        approvalDecision: RiskApprovalDecision,
        confirmationMessage: String,
        logRiskAssessment: Bool
    ) async throws -> AgentRunResult {
        markAllSteps(.running)
        let result = try await runner.execute(
            preparedRun,
            approvalDecision: approvalDecision,
            confirmationMessage: confirmationMessage,
            logRiskAssessment: logRiskAssessment,
            // The same value the approval the user saw was built from. `execute` re-assesses fresh
            // on every call, so a `.unscoped` here against a scoped `approvalRequest` would have the
            // stale-approval guard comparing two different assessments. The context threads for the
            // same reason: one origin at the prompt and another at execution would derive two
            // different requirements from one run.
            scope: activeTaskScope,
            context: approvalContext()
        )
        markAllSteps(.complete)
        // The task itself succeeded; a bookkeeping failure is a storage notice, not a task error.
        if let artifactFailure = runner.lastRecentArtifactFailure {
            recordLocalStorageWriteFailure(artifactFailure)
        }
        return result
    }

    private func approvePendingRun() {
        // **The vision branch first, and it must be first.** A mid-loop vision approval writes the
        // same `approvalRequest` every other approval writes — deliberately, so one approval surface
        // serves both — which means every Allow control in the app routes here while a session is
        // paused. The guard below would then fall through to `isRunning`, which is *true* during a
        // session, and silently do nothing: the user would press Allow and watch nothing happen.
        // Worse, if it did not, `preparedRun` and `runner` are the vision plan's own, so approving
        // would start a second vision session on top of the paused one.
        if let approvalRequest, visionApprovalContinuation != nil {
            resolveVisionApproval(approving: approvalRequest)
            return
        }
        guard !isRunning, let preparedRun, let runner, let approvalRequest else {
            return
        }

        currentTask?.cancel()
        isRunning = true
        currentTask = Task {
            await performApproval(preparedRun: preparedRun, runner: runner, approvalRequest: approvalRequest)
        }
    }

    private func performApproval(
        preparedRun: PreparedAgentRun,
        runner: AgentRunner,
        approvalRequest: RiskApprovalRequest
    ) async {
        errorMessage = nil
        finalSummary = ""
        self.approvalRequest = nil
        hasCompletedFirstApproval = true

        defer {
            publishTaskUsageSummary()
            isRunning = false
            currentTask = nil
            // Guarded exactly as `performStart`'s is, and for the same reason: reaching this point
            // does *not* mean the task ended. `AgentRunner.execute` re-assesses on every call and
            // throws `.approvalRequired` whenever the re-assessed tier exceeds the tier the user
            // approved — the ordinary state-drift class, "the zip already exists" landing between
            // the approval and the execution. The catch below re-arms `approvalRequest`, which is a
            // second pause, not a terminal exit.
            //
            // Clearing there would hand the *second* approval's execution `.unscoped`: the run would
            // still proceed (an unscoped re-assessment can only be lower, so the stale-approval
            // guard still passes) but the workspace boundary would not be applied to it — no nested
            // forwarding, no scope escalation in the trace. That is the same outcome-invisible shape
            // as mutation B3, arriving on a real code path instead of a mutated one.
            // `self.` is load-bearing: this function's own parameter is also called
            // `approvalRequest` and is never nil, so an unqualified read here would shadow the
            // published property and the guard would never fire — the clear would stay effectively
            // unconditional while looking guarded.
            if self.approvalRequest == nil {
                activeTaskScope = .unscoped
                explicitWorkspaceBinding = nil
            }
            finishRecordingPolicyIfSettled()
        }

        do {
            let result = try await executePreparedRun(
                preparedRun: preparedRun,
                runner: runner,
                // `answering:` rather than a bare tier: the decision now carries the escalation
                // reasons this exact prompt showed, so `AgentRunner.execute`'s re-check can tell a
                // second, different tier-3 cause apart from the one the user actually read
                // (SONNY-62). The request passed here is the one that was on screen — the same
                // object `performApproval` received — which is what makes the recorded consent a
                // record of what was consented to rather than of what was merely true at the time.
                approvalDecision: .approved(answering: approvalRequest),
                confirmationMessage: "User approved \(approvalRequest.assessment.effectiveTier.displayName) action",
                logRiskAssessment: true
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            var recordedTaskID: String?
            if let pendingCommandForPriorTaskContext {
                recordedTaskID = recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .completed,
                    summary: result.summary,
                    // Same reason as `performStart`'s completed path: the provenance travels with
                    // the result, and an approved run reaches storage through this second door.
                    resultProvenance: result.summaryProvenance,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            publishCompletedRunNoticeIfUnreported(result.summary, taskID: recordedTaskID)
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
            refreshSavedItems()
        } catch let error where isCancellationError(error) {
            markAllSteps(.canceled)
            finalSummary = "Canceled."
            logStore.append(.summarize, "Canceled by user")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .canceled,
                    summary: finalSummary,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
        } catch RiskApprovalError.approvalRequired(let request) {
            markAllSteps(.pending)
            self.approvalRequest = request
            finalSummary = "Approval needed before Sonny can act."
            logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .approvalNeeded,
                    summary: finalSummary
                )
            }
        } catch {
            markAllSteps(.failed)
            setError(error.localizedDescription)
            logStore.append(.summarize, "Stopped: \(error.localizedDescription)")
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .failed,
                    summary: error.localizedDescription,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
            pendingCommandForPriorTaskContext = nil
            pendingTaskHistoryStartedAt = nil
        }
    }

    /// Returns the task-history row id this call wrote, or `nil` when it wrote none.
    ///
    /// - Parameter resultProvenance: who wrote `summary` (SONNY-147). Defaults to `.codeAuthored`,
    ///   which is correct for every caller here except the two that pass an `AgentRunResult`'s own
    ///   summary — those forward `result.summaryProvenance`, which the adapter that authored the
    ///   text set. The declaration is made where the text is written, not here; this parameter only
    ///   carries it the last hop to storage.
    @discardableResult
    private func recordPriorTaskContext(
        command: String,
        preparedRun: PreparedAgentRun,
        status: PriorTaskOutcomeStatus,
        summary: String,
        resultProvenance: StoredTaskResult.Provenance = .codeAuthored,
        startedAt: Date? = nil
    ) -> String? {
        priorTaskContextStore.record(
            command: command,
            plan: preparedRun.plan,
            outcome: PriorTaskOutcome(status: status, summary: summary)
        )
        priorTaskContext = priorTaskContextStore.currentContext()
        let workspaceName = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: command,
            plan: preparedRun.plan,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )
        return recordTaskHistoryIfTerminal(
            command: command,
            status: status,
            startedAt: startedAt,
            workspaceName: workspaceName,
            result: StoredTaskResult.declaring(resultProvenance, text: summary),
            plan: preparedRun.plan
        )
    }

    /// Returns the task-history row id this call wrote, or `nil` when it wrote none.
    ///
    /// The overload for a run that never reached a prepared plan. It stores the result the same way
    /// and stores no plan detail, which is exactly what a follow-up on such a task will find: the
    /// command and the outcome, and nothing about a plan that was never produced.
    @discardableResult
    private func recordPriorTaskContext(
        command: String,
        status: PriorTaskOutcomeStatus,
        summary: String,
        resultProvenance: StoredTaskResult.Provenance = .codeAuthored,
        startedAt: Date? = nil
    ) -> String? {
        priorTaskContextStore.record(
            command: command,
            outcome: PriorTaskOutcome(status: status, summary: summary)
        )
        priorTaskContext = priorTaskContextStore.currentContext()
        let workspaceName = WorkspaceTaskTagging.resolvedWorkspaceName(
            command: command,
            plan: nil,
            routineStore: routineStore,
            workspaceStore: workspaceStore
        )
        return recordTaskHistoryIfTerminal(
            command: command,
            status: status,
            startedAt: startedAt,
            workspaceName: workspaceName,
            result: StoredTaskResult.declaring(resultProvenance, text: summary),
            plan: nil
        )
    }

    /// Returns the id of the row it wrote, or `nil` when it wrote none — suppressed, non-terminal,
    /// or the write failed. The caller needs that id to name this run's task in a notification, and
    /// it must come from here: re-deriving it afterwards as "the newest row" is not sound, because
    /// `completedAt` persists at whole-second resolution and two runs finishing in the same second
    /// tie under a non-stable sort (PR #67 cycle-3, defect B).
    @discardableResult
    private func recordTaskHistoryIfTerminal(
        command: String,
        status: PriorTaskOutcomeStatus,
        startedAt: Date?,
        workspaceName: String?,
        result: StoredTaskResult,
        plan: AgentPlan?
    ) -> String? {
        guard [.completed, .failed, .canceled].contains(status),
              let startedAt else {
            return nil
        }

        // Task history is a `.trace` store, so a suppressed run writes no row at all. Note the
        // consequence for a screen-control run: with no row written there is nothing for a deleted
        // journal to dangle from, so suppression creates no dangling link.
        guard taskRecordingPolicy.allowsWriting(to: .taskHistory) else {
            return nil
        }

        let record = CompletedTaskRecord(
            command: command,
            startedAt: startedAt,
            completedAt: Date(),
            outcomeStatus: status,
            workspaceName: workspaceName,
            // Derived from origin rather than threaded through every call site — origin
            // already records who started this run, and a second parameter saying the same
            // thing is a second thing to forget to pass.
            trigger: activeTaskOrigin == .scheduled ? .scheduled : .manual,
            // The link, written on every terminal exit including the failures — a link
            // present only on clean finishes would be missing from exactly the runs someone
            // most wants to read afterwards. `nil` for every task that ran no session, which
            // is every task the product had before row I.
            visionSessionID: activeVisionSessionID,
            // What the run produced, on every terminal exit for the same reason (SONNY-147): a
            // failed run's text is the one a user most wants to read back, and a cancelled run
            // still says "Canceled." rather than nothing.
            result: result
        )

        do {
            let evictedTaskIDs = try taskHistoryStore.record(record)
            recordTaskPlanDetail(for: record, plan: plan, evictedTaskIDs: evictedTaskIDs)
            refreshTaskHistory()
            return record.id
        } catch {
            setError("Could not save task history: \(error.localizedDescription)")
            logStore.append(.observe, "Could not record task history: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes this task's plan beside its row, and drops the plans of the rows that write evicted.
    ///
    /// **After the row, never before.** The row is the only thing that makes a plan detail
    /// reachable — `TaskPlanDetailStore` is keyed on `CompletedTaskRecord.id` and has no other index
    /// — so a detail written first and then orphaned by a failed row write would be unreachable
    /// bytes nothing could ever delete through the product. This is the write-side mirror of
    /// `deleteTask`'s dependents-first rule, and it points the same way: the row bounds the
    /// dependent's reachability in both directions.
    ///
    /// **The eviction handoff is not an optimisation.** `TaskHistoryStore.record(_:)` returns the
    /// ids it evicted, and they are dropped in this same write. Without it the two stores would only
    /// stay level while every row had a plan — and a run that failed before preparing one writes a
    /// row with no detail, so the detail store would fill more slowly, evict later, and keep the
    /// plans of tasks the user can no longer see. "Same cap, same eviction" is the founder's
    /// requirement of 2026-08-17; this is what makes it true rather than approximately true.
    ///
    /// **A failure here is reported on the storage channel and never as this task failing** (PR #89
    /// cycle 2, F4). It is a *write* failure and gets write wording, and it goes to
    /// `recordLocalStorageWriteFailure` — `localStorageNotice` — exactly as its scheduled twin does.
    ///
    /// It used to call `setError`, and `publishLocalStorageLoadError`'s own doc comment already
    /// records what that costs: routing a storage notice into `errorMessage` makes a *successful*
    /// task render as a failure, because `FloatingWidgetView` picks `.failure` ahead of `.result`.
    /// So a task that ran, produced its result and wrote its row would show "Could not save this
    /// task's plan" where its result belonged. A plan-persistence failure is a **degraded
    /// follow-up**, not a failed task: the run happened, the row landed, and what is lost is that a
    /// later follow-up will have this task's command and outcome but not its plan. Reported rather
    /// than swallowed, because that consequence is narrow and worth saying — just not in the slot
    /// that means "the thing you asked for did not happen".
    private func recordTaskPlanDetail(
        for record: CompletedTaskRecord,
        plan: AgentPlan?,
        evictedTaskIDs: [String]
    ) {
        // Classified `.trace`, so it is withheld by the same switch that withheld the row. Asked
        // explicitly rather than inferred from having got past the row's own guard: the reach of
        // "Don't save this task" is a rule read off `LocalStore.kind`, and a store that relied on a
        // sibling's guard would be the one store the rule did not actually cover.
        guard taskRecordingPolicy.allowsWriting(to: .taskPlanDetails) else {
            return
        }

        do {
            guard let plan, let taskID = record.id else {
                try taskPlanDetailStore.delete(ids: evictedTaskIDs)
                return
            }
            try taskPlanDetailStore.save(
                StoredTaskPlanDetail(taskID: taskID, completedAt: record.completedAt, plan: plan),
                evictedTaskIDs: evictedTaskIDs
            )
        } catch {
            recordLocalStorageWriteFailure("Sonny could not save this task's plan: \(error.localizedDescription)")
            logStore.append(.observe, "Could not record this task's plan: \(error.localizedDescription)")
        }
    }

    // MARK: - Routine scheduling

    /// Poll interval. Far coarser than the clipboard monitor's 1s because nothing here is
    /// interactive — the worst case is starting a routine up to this late, which is irrelevant
    /// against catch-up windows measured in hours.
    private static let scheduleTickInterval: TimeInterval = 30

    /// Starts the schedule timer and the wake observer.
    ///
    /// The wake observer is not redundant with the timer: `Timer` does not fire while the machine
    /// is asleep and does not retroactively catch up on wake, and the app commonly stays running
    /// across a sleep — so checking only on launch and on tick would miss the single most common
    /// real scenario, a laptop closed overnight and opened in the morning.
    func startRoutineScheduling() {
        routineScheduleTimer?.invalidate()
        checkScheduledRoutines()
        routineScheduleTimer = Timer.scheduledTimer(
            withTimeInterval: Self.scheduleTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledRoutines()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkScheduledRoutines()
            }
        }
    }

    /// Handles at most one outstanding occurrence per call, oldest first.
    ///
    /// One at a time rather than draining the whole backlog: each run sets `isRunning`, which the
    /// guard below respects, so a backlog is worked through across ticks instead of firing several
    /// unattended routines at once — which is exactly the burst behavior that ruled out unbounded
    /// catch-up in the first place.
    func checkScheduledRoutines(now: Date = Date()) {
        // Never interrupt or race a task already in flight, whoever started it.
        //
        // **The third term is the founder's decision of 2026-08-20 (PR #80 review, F1), and it
        // closes a real overlap rather than a theoretical one.** A clarification pause looks idle
        // from out here — `performStart`'s defer has set `isRunning` false and a clarification never
        // writes `approvalRequest` — so the two-term guard let a routine fire on top of a user's
        // half-finished task. What that cost is specific: `finishRecordingPolicyIfSettled()` refuses
        // while `isRunning`, so a user cancelling their clarification during the scheduled run's
        // window got no reset at all — "Don't save this task" stayed on and clipboard history stayed
        // paused until relaunch, which is the exact failure SONNY-166 was filed to end, reintroduced
        // through a door that ticket never looked at.
        //
        // **A delay, not a loss.** The occurrence stays outstanding because nothing here resolves
        // it, and the 30-second tick (plus the wake observer) picks it up on the next pass, which is
        // the same catch-up path a routine firing during any other in-flight task already takes.
        //
        // Spelled out rather than written `!isTaskInFlight`, which is exactly these three terms
        // today. A background trigger's refusal set should not change because a UI predicate grows a
        // fourth term later; if a new state ought to block the scheduler, it gets added here on
        // purpose.
        guard !isRunning, !isAwaitingApproval, clarificationQuestion == nil else {
            return
        }

        // Read from the store, never from `savedRoutines`. An in-memory snapshot can outlive the
        // file — "delete all local data" wipes routines.json while the published array still holds
        // the old values, and `RoutineStore.delete(routineNamed:)` can now remove one routine the
        // same way. A fresh read narrows the window in which a fired routine can be missing by
        // run time, but no longer closes it: see `performScheduledRun`'s missing-routine comment
        // for the in-flight race that remains, and the guard there that fails it closed.
        let routines: [StoredRoutine]
        do {
            routines = Array(try routineStore.loadAll().values)
        } catch {
            recordLocalStorageLoadFailure(.savedRoutines, error: error)
            return
        }

        guard let next = RoutineScheduler.outstanding(in: routines, now: now).first,
              let occurrence = next.occurrence else {
            return
        }

        switch next.decision {
        case .notDue:
            return
        case .missed:
            resolveOccurrence(for: next.routine.name, at: occurrence)
            scheduledRunNotice = "“\(next.routine.name)” did not run at its scheduled time — too much time had passed by the time Sonny was available again."
        case .due:
            guard next.routine.schedule?.unattendedTrusted == true else {
                // An enabled schedule without unattended trust cannot run: the outer run-routine
                // gate is tier 2 and there is nobody to approve it. Skipping and saying so is
                // deliberate — pausing at the approval and waiting was considered for this branch
                // and rejected, because it reduces scheduling to "notify me it's ready, I'll
                // finish it myself".
                resolveOccurrence(for: next.routine.name, at: occurrence)
                scheduledRunNotice = "“\(next.routine.name)” was not run because it is not set to run unattended. Turn on unattended running for it, or run it yourself."
                return
            }
            isRunning = true
            // Deliberately does not touch `lastCommand`. That property is the user's own last
            // submission: it feeds `hasRetryableCommand` and `retryLastCommand()`, so overwriting
            // it here would point the widget's Retry button at a routine the user never ran.
            // `runningCommandDisplayText` reads the scheduled label separately while this runs.
            currentTask = Task {
                await performScheduledRun(next.routine, occurrence: occurrence)
            }
        }
    }

    /// Runs a routine with nobody watching, without disturbing anything that describes the user's
    /// own last task.
    ///
    /// That isolation is the whole design of this method, and it is why it does not reuse
    /// `performStart`'s state handling. Every property that surface UI reads as "your last task" —
    /// `errorMessage`, `finalSummary`, `suggestions`, `plan`, `stepStatuses`, `preparedRun`,
    /// `lastCommand`, `priorTaskContext`, the usage summary — is deliberately untouched here. A
    /// background event silently erasing an unresolved error, or an "open the file" suggestion the
    /// user had not acted on yet, is a worse failure than a scheduled run being under-reported: the
    /// user did not do anything, so nothing they were looking at should change.
    ///
    /// `isRunning` and `activeTaskOrigin` are the two exceptions, because both are needed *during*
    /// the run — one blocks re-entrancy and drives Command Center's running indicator, the other
    /// keeps the widget from raising a progress panel for a task the user never started. Origin is
    /// restored afterwards so the user's previous result stays visible in the widget.
    ///
    /// Everything this method has to say goes to `scheduledRunNotice`, task history, and the
    /// routine's own run history.
    private func performScheduledRun(_ routine: StoredRoutine, occurrence: Date) async {
        let previousOrigin = activeTaskOrigin
        activeTaskOrigin = .scheduled
        let startedAt = Date()
        let name = routine.name
        scheduledRunDisplayCommand = "Run my \(name) routine"
        defer {
            activeTaskOrigin = previousOrigin
            scheduledRunDisplayCommand = nil
            isRunning = false
            currentTask = nil
        }

        // Whatever happens below, this occurrence is handled. Advancing first means an unexpected
        // throw can't leave it outstanding for the next tick to retry 30 seconds later, forever.
        resolveOccurrence(for: name, at: occurrence)

        do {
            // `.record` explicitly, never this run's policy (PR #67 review, F2). A scheduled routine is
            // never suppressed — it passes through no composer, so there is no switch to have been
            // left on. Inheriting `taskRecordingPolicy` was wrong in one reachable window: a
            // foreground run paused at a *clarification* leaves `isRunning` false and the policy
            // still `.suppressTraces`, and `checkScheduledRoutines` only guards on `isRunning` and
            // `isAwaitingApproval` — so a routine firing then lost its Shortcut run history while
            // still writing its task-history row, which is a different writer. Stated here the same
            // way `recentArtifactStore` already is, rather than left to the policy happening to be
            // right.
            let executor = makeExecutor(recordingPolicy: .record)
            let runner = AgentRunner(
                planner: InstantOnlyFallbackPlanner(),
                executor: executor,
                logStore: logStore,
                // The real store, deliberately, not `recentArtifactStoreForThisRun`. Scheduled runs
                // are never suppressed — the switch is a per-task control on the widget's composer
                // and a scheduled run passes through no composer. Written out rather than left to
                // the policy happening to be `.record` here.
                recentArtifactStore: recentArtifactStore
            )
            self.runner = runner
            // The same plan a typed "run my X routine" produces — built directly rather than
            // round-tripped through the resolver or the planner, so a scheduled run is
            // deterministic and costs no model call.
            let prepared = try runner.prepare(
                plan: RunRoutineCapabilityAdapter.plan(forRoutineNamed: name),
                source: .instantResolver
            )
            // Reachable since routine deletion exists, not merely defensive.
            // `SaveRoutineCapabilityAdapter` still rejects open_workspace and run_routine steps at
            // save time, so a routine's own steps still cannot name a missing target — but the
            // routine itself is re-resolved *by name* in `prepare` above, and
            // `checkScheduledRoutines` spawning this method as a `Task` is a real suspension point
            // between reading the routine and this line running. Deleting the routine inside that
            // window makes `RunRoutineCapabilityAdapter`'s store read throw `.missingRoutine`,
            // which `AgentActionExecutor.prepare` converts into this clarification. Failing closed
            // rather than stalling on a question nobody is present to answer is correct for every
            // cause. Pinned by ScheduledRoutineRunTests.
            // aRoutineDeletedBetweenScheduleFireAndTaskStartBecomesAClarificationInstead. (A
            // delete landing later still fails closed: `runner.execute`'s own store read throws
            // into the generic catch below.)
            if let question = prepared.clarificationQuestion {
                scheduledRunNotice = "“\(name)” was not run because Sonny needed to ask something first: \(question)"
                return
            }

            // **Unattended vision: never — the belt** (SONNY-94, E7 as ratified under C8).
            //
            // The other two layers are structural and would each stop this on their own: a stored
            // routine cannot carry a vision step at all (`StoredRoutine.forbiddenStepOperations`),
            // and the `.approved(.tier2)` ceiling below cannot cover a tier-3 vision assessment.
            // This layer is neither — it is an *explicit* refusal that names the reason, and it
            // exists precisely because the other two are silent about theirs: a plan blocked by the
            // ceiling produces "approval required", a plan blocked by the routine store produces
            // "unsafe routine step", and neither tells a user that screen control is a thing Sonny
            // will not do while they are away.
            //
            // Three layers, three pins, so no single regression unbars unattended screen control.
            // This one is deliberately the least load-bearing and the most legible.
            //
            // A present human is an authority requirement, not an accuracy hedge: their presence is
            // the whole basis on which a program is allowed to move their cursor, and no amount of
            // model quality substitutes for it. So this refuses in *every* mode, Power included,
            // and there is no toggle anywhere that turns it off.
            // **Checked against the routine's own steps, not only the prepared plan** — and that
            // distinction is the whole reason this check needed writing twice. The scheduled path
            // prepares a one-step `run_routine` plan, so a vision step carried by the routine lives
            // *inside* the stored record and never appears in `prepared.plan.steps` at all. A belt
            // that looked only at the prepared plan would have been unreachable code that read like
            // a guarantee.
            let carriesVision = routine.steps.contains { $0.operation == .visionSession }
                || (routine.steps.compactMap(\.routineSteps).flatMap { $0 }).contains { $0.operation == .visionSession }
                || prepared.plan.steps.contains { $0.operation == .visionSession }
            if carriesVision {
                logStore.append(.summarize, "Scheduled run refused: screen control never runs unattended")
                pauseSchedule(
                    routineNamed: name,
                    because: "It needs to control an app on screen, and Sonny only does that while you are here."
                )
                return
            }

            let result = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Scheduled run approved by this routine's unattended-run setting",
                // `.unscoped` on purpose, not by omission. A scheduled run has no workspace binding
                // available: `SaveRoutineCapabilityAdapter.validateRoutineSteps` rejects both
                // `create_workspace` and `open_workspace` as routine steps, so a stored routine can
                // never name a workspace, and nothing else in a scheduled run carries one — there is
                // no command text a user typed and no dispatch that named one.
                //
                // Under the consequence rule this choice also carries the unattended ceiling's
                // advisory half: an unscoped assessment can produce no out-of-scope advisory, and
                // `StoredRoutine.forbiddenStepOperations` rejects `edit_workspace`, so no advisory
                // escalation of any kind is reachable here — every tier-3 an unattended run can
                // reach still asks, and the `.approved(.tier2)` ceiling below still refuses it.
                // Reachability, not a type-level guarantee; a test named for the hazard pins it.
                scope: .unscoped,
                context: approvalContext()
            )
            recordScheduledRunInHistory(name: name, at: occurrence)
            recordScheduledTaskHistory(
                status: .completed,
                startedAt: startedAt,
                // The result was dropped here until SONNY-147, while the very next line used it for
                // the notice — proof it was in scope and simply not threaded. `result.plan` is the
                // one-step `run_routine` plan this path prepares, which is what a follow-up on a
                // scheduled run gets to correct against.
                result: result.storedResult,
                plan: result.plan
            )
            scheduledRunNotice = "“\(name)” ran on schedule. \(result.summary)"
        } catch let error as RiskApprovalError {
            // The tier-3+ backstop firing. `AgentRunner` re-assesses at execute time and requires
            // the approved tier to be at least the effective tier, so a tier-2 unattended approval
            // simply cannot satisfy a tier-3 plan — the refusal is structural, not a policy check
            // written here that could drift out of sync with the real gate. The backstop itself is
            // untouched by SONNY-31; what changed is only what happens afterwards.
            //
            // Pause rather than skip. Every condition that reaches here is sticky: a file that
            // exists still exists tomorrow, a snippet whose text really did change still differs
            // next week, a tier-4 plan is tier 4 forever. Leaving the schedule enabled meant the
            // same refusal every single occurrence, each one posting the same notice that named no
            // cause — the user learned only that Sonny had stopped, never why. One notification
            // carrying the real reason, then silence, is the founder decision recorded on
            // SONNY-31 (chosen over keep-skipping-with-notice and hold-the-approval).
            //
            // All three `RiskApprovalError` cases pause, not just `.approvalRequired`.
            // `.previewOnly` (unproducible since the policy dials' 2026-08-14 deletion, but
            // still public API) and `.refused` (tier 4) are equally
            // permanent for a run with nobody present to approve anything, and leaving either one
            // on the old skip-forever path would keep this bug alive in two of the three branches
            // that can reach it.
            logStore.append(.summarize, "Scheduled run paused: \(error.localizedDescription)")
            pauseSchedule(routineNamed: name, because: scheduledRunPauseCause(for: error))
        } catch {
            logStore.append(.summarize, "Scheduled run failed: \(error.localizedDescription)")
            recordScheduledTaskHistory(
                status: .failed,
                startedAt: startedAt,
                // The same text the notice below shows, so a failed scheduled run's detail says what
                // went wrong instead of nothing. No plan: this catch is reachable before `prepare`
                // returns as well as after, so there is not always one to store.
                result: .codeAuthored(error.localizedDescription),
                plan: nil
            )
            scheduledRunNotice = "“\(name)” failed on its scheduled run: \(error.localizedDescription)"
        }
    }

    /// Records a scheduled run in task history *without* going through `recordPriorTaskContext`.
    ///
    /// The split is the point. History is a log of what Sonny did, and a scheduled run that failed
    /// has to be debuggable, so it belongs there. `PriorTaskContext` is a different thing: it is
    /// the last-task-only context that lets "use ~/Downloads instead" correct a just-finished task
    /// without restating it — a feature explicitly about correcting *your own* last action. Letting
    /// a background event become that target would silently redirect the next correction onto a
    /// task the user never started, with nothing in the phrasing to reveal it.
    ///
    /// A routine is also the wrong shape for that feature even setting the confusion aside: its
    /// steps are saved and fixed, so there is no command text for a correction to rewrite.
    private func recordScheduledTaskHistory(
        status: PriorTaskOutcomeStatus,
        startedAt: Date,
        result: StoredTaskResult,
        plan: AgentPlan?
    ) {
        guard let command = scheduledRunDisplayCommand else {
            return
        }
        let record = CompletedTaskRecord(
            command: command,
            startedAt: startedAt,
            completedAt: Date(),
            outcomeStatus: status,
            trigger: .scheduled,
            result: result
        )
        // **Two writes, two catches, matching the foreground path** (PR #89 review). One `do` around
        // both said "could not save this scheduled run to task history" when only the *plan* write
        // had failed — the row had landed — and skipped `refreshTaskHistory()`, so the row that did
        // land was missing from the list until something else refreshed it. Two failures with
        // different consequences need two messages and two recoveries; `recordTaskHistoryIfTerminal`
        // and `recordTaskPlanDetail` already split them this way for a foreground run, and these are
        // separate functions rather than one shared helper, so agreeing is something to do rather
        // than something inherited.
        let evictedTaskIDs: [String]
        do {
            evictedTaskIDs = try taskHistoryStore.record(record)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this scheduled run to task history: \(error.localizedDescription)"
            )
            return
        }

        do {
            // No `taskRecordingPolicy` check on either write, and deliberately: a scheduled run
            // passes through no composer, so there is no "Don't save this task" switch to have been
            // left on — the same reasoning already written above beside `makeExecutor(recordingPolicy:
            // .record)` and `recentArtifactStore`. `recordTaskPlanDetail` is not reused here for
            // exactly that reason; it asks the policy, which is right for a foreground run and wrong
            // for this one.
            if let plan, let taskID = record.id {
                try taskPlanDetailStore.save(
                    StoredTaskPlanDetail(taskID: taskID, completedAt: record.completedAt, plan: plan),
                    evictedTaskIDs: evictedTaskIDs
                )
            } else {
                try taskPlanDetailStore.delete(ids: evictedTaskIDs)
            }
        } catch {
            // A *write* failure, with its own accurate wording — never the load-failure banner,
            // whose text is hardcoded to "could not be decrypted or decoded" and would be wrong
            // twice over here. The honest consequence is narrow and worth saying: the run is in the
            // history, and a follow-up on it will have its command and its outcome but not its plan.
            recordLocalStorageWriteFailure(
                "Sonny could not save what this scheduled run planned: \(error.localizedDescription)"
            )
        }

        // Regardless of the plan write, because the row landed either way and the list has to agree
        // with the file. The foreground path refreshes on the same rule.
        refreshTaskHistory()
    }

    /// Switches a routine's schedule off after an approval refusal and says so, once.
    ///
    /// "Exactly one notification" is not enforced by a counter here — it falls out of pausing.
    /// `scheduledRunNotice` is published once per attempt and `AppDelegate` mirrors it to a
    /// notification; a disabled schedule produces no further attempts, so there is nothing left to
    /// post. A counter would have been a second source of truth for the same fact.
    ///
    /// A failed pause write still notifies. The store failure gets its own surfacing through
    /// `recordLocalStorageWriteFailure`, but suppressing the explanation as well would leave the
    /// user with a routine that stopped working, no reason, and a storage banner that does not
    /// mention the routine at all.
    private func pauseSchedule(routineNamed name: String, because cause: String) {
        do {
            try routineStore.pauseSchedule(routineNamed: name, reason: cause)
            refreshSavedItems()
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not pause this routine's schedule: \(error.localizedDescription)"
            )
        }
        scheduledRunNotice = "“\(name)” needs your approval to run, so Sonny paused its schedule instead of skipping it every time. \(cause) Run it yourself to review, then switch its schedule back on."
    }

    /// The user-facing reason a scheduled run was refused.
    ///
    /// Prefers the escalation reasons, because they are the only part of an assessment that names
    /// the *specific* condition — "Draft output already exists at …/weekly.md." is actionable in a
    /// way "This may affect external services or overwrite/destructively change data." is not.
    /// Falls back to the tier's generic risk reason when a refusal carries no escalations at all,
    /// which is the shape of a plan sitting at a high baseline tier rather than one raised into it.
    private func scheduledRunPauseCause(for error: RiskApprovalError) -> String {
        let request: RiskApprovalRequest
        switch error {
        case .approvalRequired(let value), .previewOnly(let value), .refused(let value):
            request = value
        }

        let escalationReasons = request.assessment.escalations
            .map(\.reason)
            .joined(separator: " ")
        return escalationReasons.isEmpty ? request.approvalCopy.riskReason : escalationReasons
    }

    /// Marks an occurrence handled so the next tick moves past it. Applies to every outcome — ran,
    /// refused, skipped, missed — because any of them leaving the baseline untouched would make the
    /// scheduler retry the same occurrence every 30 seconds.
    private func resolveOccurrence(for routineName: String, at occurrence: Date) {
        do {
            try routineStore.advanceScheduleBaseline(routineNamed: routineName, to: occurrence)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's schedule state: \(error.localizedDescription)"
            )
        }
    }

    private func recordScheduledRunInHistory(name: String, at occurrence: Date) {
        do {
            try routineStore.recordRun(routineNamed: name, at: occurrence)
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this routine's run history: \(error.localizedDescription)"
            )
        }
    }

    private func publishTaskUsageSummary() {
        taskUsageSummary = taskUsageRecorder.snapshot()
    }

    private func initializeStepStatuses(for plan: AgentPlan) {
        stepStatuses = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, AgentStepStatus.pending) })
    }

    private func markAllSteps(_ status: AgentStepStatus) {
        guard !stepStatuses.isEmpty else {
            return
        }
        stepStatuses = Dictionary(uniqueKeysWithValues: stepStatuses.keys.map { ($0, status) })
    }
}

enum AgentStepStatus: String {
    case pending
    case running
    case complete
    case failed
    case canceled
}

@MainActor
private struct InstantOnlyFallbackPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        throw PlannerError.missingAPIKey
    }
}
