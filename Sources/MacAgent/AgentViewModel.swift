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
    @Published var clipboardHistoryEnabled: Bool = true
    @Published var priorTaskContext: PriorTaskContext?
    @Published var taskUsageSummary: TaskUsageSummary = .empty
    @Published var taskHistoryRecords: [CompletedTaskRecord] = []
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
    /// real resolution points, should ever flip it.
    @Published private(set) var hasCompletedFirstApproval: Bool = false {
        didSet {
            userDefaults.set(hasCompletedFirstApproval, forKey: UserDefaultsKeys.hasCompletedFirstApproval)
        }
    }

    let logStore = AgentLogStore()

    private var preparedRun: PreparedAgentRun?
    private var runner: AgentRunner?
    private var currentTask: Task<Void, Never>?
    private let audioRecorder: AudioCommandRecorder
    private let permissionReadinessService: PermissionReadinessService
    private let routineStore: RoutineStore
    private let workspaceStore: WorkspaceStore
    private let snippetStore: SnippetStore
    private let recentArtifactStore: RecentArtifactStore
    private let shortcutCatalog: any ShortcutCatalogProviding
    private let shortcutRunHistoryStore: ShortcutRunHistoryStore
    private let taskHistoryStore: TaskHistoryStore
    private let clipboardHistorySettingsStore: ClipboardHistorySettingsStore
    private let clipboardHistoryMonitor: ClipboardHistoryMonitor
    private let localDataDeletionService: LocalDataDeletionService
    private let priorTaskContextStore: PriorTaskContextStore
    private let taskUsageRecorder: TaskUsageRecorder
    private let userDefaults: UserDefaults
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
    /// Which surface's mic button started the in-progress recording — `toggleVoiceRecording()` is
    /// called identically from both Command Center's composer and the floating widget's own mic
    /// button, so this is set explicitly by the caller rather than inferred. Read back when voice
    /// transcription auto-submits, so that submission is attributed correctly.
    private var voiceRecordingOrigin: TaskOrigin = .commandCenter
    /// The last command text actually submitted for real execution — tracked on the shared view
    /// model (not as widget-local UI state) so both the widget's own retry button and a system
    /// notification's "Retry" action, which fires from outside SwiftUI entirely, can resubmit it.
    private var lastCommand = ""
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
        case snippets
        case recentArtifacts

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
            case .snippets:
                return "snippets"
            case .recentArtifacts:
                return "recent artifacts"
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
    }

    init(
        audioRecorder: AudioCommandRecorder = AudioCommandRecorder(),
        permissionReadinessService: PermissionReadinessService = PermissionReadinessService(),
        routineStore: RoutineStore = RoutineStore(),
        workspaceStore: WorkspaceStore = WorkspaceStore(),
        snippetStore: SnippetStore = SnippetStore(),
        recentArtifactStore: RecentArtifactStore = RecentArtifactStore(),
        shortcutCatalog: any ShortcutCatalogProviding = ProcessShortcutCatalog(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore = ShortcutRunHistoryStore(),
        taskHistoryStore: TaskHistoryStore = TaskHistoryStore(),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore = ClipboardHistorySettingsStore(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor? = nil,
        localDataDeletionService: LocalDataDeletionService = LocalDataDeletionService(),
        priorTaskContextStore: PriorTaskContextStore = PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder = TaskUsageRecorder(),
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        usePointerCursors = userDefaults.object(forKey: UserDefaultsKeys.usePointerCursors) as? Bool ?? true
        displayFullNames = userDefaults.object(forKey: UserDefaultsKeys.displayFullNames) as? Bool ?? false
        hasCompletedFirstApproval = userDefaults.object(forKey: UserDefaultsKeys.hasCompletedFirstApproval) as? Bool ?? false
        self.audioRecorder = audioRecorder
        self.permissionReadinessService = permissionReadinessService
        self.routineStore = routineStore
        self.workspaceStore = workspaceStore
        self.snippetStore = snippetStore
        self.recentArtifactStore = recentArtifactStore
        self.shortcutCatalog = shortcutCatalog
        self.shortcutRunHistoryStore = shortcutRunHistoryStore
        self.taskHistoryStore = taskHistoryStore
        self.clipboardHistorySettingsStore = clipboardHistorySettingsStore
        self.clipboardHistoryMonitor = clipboardHistoryMonitor
            ?? ClipboardHistoryMonitor(settingsStore: clipboardHistorySettingsStore)
        self.localDataDeletionService = localDataDeletionService
        self.priorTaskContextStore = priorTaskContextStore
        self.taskUsageRecorder = taskUsageRecorder
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

    var canSubmit: Bool {
        if isAwaitingApproval {
            return !isRunning && preparedRun != nil && runner != nil
        }
        return !isRunning && !isTranscribingVoice && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCancel: Bool {
        isAwaitingApproval || (isRunning && currentTask != nil)
    }

    var canUseVoice: Bool {
        hasAPIKey && !isAwaitingApproval && !isRunning && !isPreparingVoiceRecording && !isTranscribingVoice
    }

    var isAwaitingApproval: Bool {
        approvalRequest != nil
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
    func start(autoExecute: Bool = false, origin: TaskOrigin = .commandCenter) {
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

        currentTask?.cancel()
        isRunning = true
        currentTask = Task {
            await performStart(submittedCommand: submittedCommand, autoExecute: autoExecute, origin: origin)
        }
    }

    /// `currentTask?.cancel()` doesn't guarantee the in-flight work throws Swift's own
    /// `CancellationError` — a cancelled `URLSession` request (the planner/transcriber's network
    /// calls) can surface as `URLError(.cancelled)` instead, depending on exactly where the
    /// cancellation lands. Catching only `CancellationError` meant a cancel that happened mid-network-
    /// call fell through to the generic failure path: styled red, a Retry button, "cancelled" as the
    /// error text — a deliberate user cancellation rendered as if it were a real failure.
    private func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func performStart(submittedCommand: String, autoExecute: Bool, origin: TaskOrigin) async {
        activeTaskOrigin = origin
        errorMessage = nil
        finalSummary = ""
        plan = nil
        suggestions = []
        clarificationQuestion = nil
        clarificationAnswer = ""
        preparedRun = nil
        approvalRequest = nil
        stepStatuses = [:]
        pendingTaskHistoryStartedAt = nil

        if preserveUsageForNextStart {
            preserveUsageForNextStart = false
            publishTaskUsageSummary()
        } else {
            taskUsageRecorder.reset()
            taskUsageSummary = .empty
        }

        defer {
            publishTaskUsageSummary()
            isRunning = false
            currentTask = nil
        }

        let taskHistoryStartedAt = Date()
        let priorContextForPlanner = priorTaskContextStore.currentContext()
        priorTaskContext = priorContextForPlanner

        do {
            let executor = makeExecutor()
            let runner: AgentRunner
            let prepared: PreparedAgentRun

            if let resolution = makeInstantCommandResolver().resolve(command: submittedCommand) {
                runner = AgentRunner(
                    planner: InstantOnlyFallbackPlanner(),
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStore
                )
                switch resolution {
                case .plan(let localPlan), .clarify(let localPlan):
                    prepared = try runner.prepare(plan: localPlan, source: .instantResolver)
                }
            } else {
                let planner = try OpenAIPlanner(usageRecorder: taskUsageRecorder)
                runner = AgentRunner(
                    planner: planner,
                    executor: executor,
                    logStore: logStore,
                    recentArtifactStore: recentArtifactStore
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

            if let question = prepared.clarificationQuestion {
                clarificationQuestion = question
                clarificationAutoExecute = autoExecute
                clarificationOrigin = origin
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

            let request = try runner.approvalRequest(for: prepared, logAssessment: true)
            switch request.requirement {
            case .autoRun:
                break
            case .lightweightConfirmation, .explicitApproval:
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
            case .previewOnly:
                // Unreachable today: nothing in the app ever builds a `RiskApprovalPolicy` with
                // `tier2Mode == .previewOnly`, so `AgentRunner` always uses `.default`. The case
                // still has to be handled because the requirement is public API. It reports
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

            let result = try await executePreparedRun(
                preparedRun: prepared,
                runner: runner,
                approvalDecision: .notRequested,
                confirmationMessage: autoExecute ? "Voice command auto-approved execution" : "Typed command auto-approved execution",
                logRiskAssessment: false
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            recordPriorTaskContext(
                command: submittedCommand,
                preparedRun: prepared,
                status: .completed,
                summary: result.summary,
                startedAt: taskHistoryStartedAt
            )
            refreshSavedItems()
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
            return
        }

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
    /// `errorMessage` and `finalSummary`/`suggestions` unconditionally — whichever pair wasn't
    /// actually active is already empty, so clearing it too is harmless. Deliberately scoped here,
    /// not a broader `reset()`. `FloatingWidgetView`'s timer only ever calls this for `.result`, or
    /// for `.failure` when `errorIsPersistent` is false, so a real configuration problem never gets
    /// silently cleared out from under the user.
    func clearStaleTaskOutcome() {
        errorMessage = nil
        finalSummary = ""
        suggestions = []
    }

    /// The one place `errorMessage` should be set (never assign it directly) — forces every call
    /// site to make an explicit, visible choice about `persistent` rather than silently inheriting
    /// whatever the last call happened to leave behind. Defaults to `false` (transient) since most
    /// errors in this app are one-off task/validation outcomes, not environment problems; the small
    /// number of genuinely persistent cases (missing API key, denied mic permission, unavailable
    /// hotkey) pass `persistent: true` explicitly.
    private func setError(_ message: String, persistent: Bool = false) {
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
        guard !lastCommand.isEmpty, !isRunning, !isAwaitingApproval else {
            return
        }
        command = lastCommand
        start(origin: origin)
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
        clarificationAutoExecute = false
        clarificationOrigin = .commandCenter
        clarificationQuestion = nil
        clarificationAnswer = ""
        start(autoExecute: shouldAutoExecute, origin: shouldUseOrigin)
    }

    /// - Parameter origin: Which surface's mic button this is — `toggleVoiceRecording()` is called
    ///   identically from Command Center's composer and the floating widget's own mic button, so
    ///   the caller states which one explicitly rather than it being inferred.
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
            if !hasAPIKey {
                setError("OPENAI_API_KEY is not set. Export it before launching Sonny, then relaunch the app.", persistent: true)
            }
            return
        }

        isPushToTalkHotKeyDown = true
        // The global hotkey always brings the floating widget forward first (see
        // `AppDelegate.handlePushToTalkPress()`), so a hotkey-triggered recording is always a
        // widget interaction regardless of which surface happened to be focused.
        startVoiceRecording(trigger: .hotKey, origin: .widget)
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

    /// Snippets, recent artifacts, and clipboard items are otherwise only read through `try?`
    /// paths (the instant resolver's trigger/artifact lookups and the 1s clipboard poll), so a
    /// corrupt file there is invisible: the feature just silently stops working. These stores
    /// have no UI list of their own to surface a load failure, so probe them here.
    private func refreshSilentlyReadStoreHealth() {
        checkStoreHealth(.snippets) { _ = try snippetStore.loadAll() }
        checkStoreHealth(.recentArtifacts) { _ = try recentArtifactStore.loadAll() }
        checkStoreHealth(.clipboardHistoryItems) { try clipboardHistoryMonitor.verifyHistoryReadable() }
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
    /// `isEnabled` and `unattendedTrusted` carry over from the existing schedule: neither is part
    /// of the draft, since both are separate decisions about a schedule rather than fields of one
    /// being composed.
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
    func setRoutineScheduleEnabled(_ routine: StoredRoutine, to isEnabled: Bool) {
        guard var schedule = routine.schedule else {
            return
        }
        schedule.setEnabled(isEnabled, now: Date())
        applySchedule(schedule, to: routine.name)
    }

    /// Turns the per-routine unattended-run opt-in on or off, returning advisory copy when the
    /// routine currently assesses at tier 3+ and therefore could not run unattended anyway.
    ///
    /// The advisory is a heads-up, never a gate — blocking the opt-in here would be the save-time
    /// tier gating this branch explicitly rejected. It is also best-effort: tiers escalate from
    /// real run-time conditions, so a routine that reads clean today can still be skipped later.
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
        command = "Run my \(routine.name) routine"
        start(autoExecute: true)
    }

    func openWorkspaceWidget(_ workspace: StoredWorkspace) {
        command = "Open my \(workspace.name) workspace"
        start(autoExecute: true)
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
    /// Guarded on the full "task in flight" condition, not just `isRunning`: a run paused at an
    /// approval still holds a prepared plan that re-reads the store when approved, so deleting out
    /// from under it has the same failure as deleting mid-run. `isRunning || isAwaitingApproval`
    /// is what `checkScheduledRoutines` and every running-indicator gate already treat as "in
    /// flight"; `deleteLocalData`'s narrower `isRunning`-only guard predates that convention and
    /// is left as it is here.
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

    private func clearInMemoryLocalDataState() {
        plan = nil
        suggestions = []
        approvalRequest = nil
        stepStatuses = [:]
        priorTaskContext = nil
        taskUsageSummary = .empty
        taskHistoryRecords = []
        clarificationQuestion = nil
        clarificationAnswer = ""
        clarificationAutoExecute = false
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
        localStorageNotice = "Sonny could not load encrypted local data. A local data file exists but could not be decrypted or decoded. \(details)"
    }

    /// A local-store *write* failure, which needs its own accurate wording — the load-failure
    /// text ("could not be decrypted or decoded") describes the wrong problem entirely.
    private func recordLocalStorageWriteFailure(_ description: String) {
        localStorageNotice = description
    }

    private func makeInstantCommandResolver() -> InstantCommandResolver {
        InstantCommandResolver(
            snippetStore: snippetStore,
            recentArtifactStore: recentArtifactStore,
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            shortcutCatalog: shortcutCatalog
        )
    }

    private func makeExecutor() -> AgentActionExecutor {
        AgentActionExecutor(
            routineStore: routineStore,
            workspaceStore: workspaceStore,
            // `try?` is the degradation path, not error swallowing: construction only throws for
            // a missing TAVILY_API_KEY, and nil falls back to `UnavailableWebSearchProvider`'s
            // existing "Web search provider not configured." error. Constructed per executor like
            // everything else here, so a key exported after launch works on the next run.
            webSearchProvider: try? TavilySearchProvider(),
            usageRecorder: taskUsageRecorder,
            snippetStore: snippetStore,
            recentArtifactStore: recentArtifactStore,
            shortcutCatalog: shortcutCatalog,
            shortcutRunHistoryStore: shortcutRunHistoryStore,
            hotKeyReady: { [weak self] in self?.voiceHotKeyReady ?? true }
        )
    }

    private func startVoiceRecording(trigger: VoiceRecordingTrigger, origin: TaskOrigin) {
        guard canUseVoice else {
            if !hasAPIKey {
                setError("OPENAI_API_KEY is not set. Export it before launching Sonny, then relaunch the app.", persistent: true)
            }
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
                command = result.text
                finalSummary = ""
                isTranscribingVoice = false
                preserveUsageForNextStart = true
                logStore.append(.observe, "Transcript ready. Sonny will act now.")
                start(autoExecute: true, origin: voiceRecordingOrigin)
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
            logRiskAssessment: logRiskAssessment
        )
        markAllSteps(.complete)
        // The task itself succeeded; a bookkeeping failure is a storage notice, not a task error.
        if let artifactFailure = runner.lastRecentArtifactFailure {
            recordLocalStorageWriteFailure(artifactFailure)
        }
        return result
    }

    private func approvePendingRun() {
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
        }

        do {
            let result = try await executePreparedRun(
                preparedRun: preparedRun,
                runner: runner,
                approvalDecision: .approved(approvalRequest.assessment.effectiveTier),
                confirmationMessage: "User approved \(approvalRequest.assessment.effectiveTier.displayName) action",
                logRiskAssessment: true
            )
            finalSummary = result.summary
            suggestions = result.suggestions
            if let pendingCommandForPriorTaskContext {
                recordPriorTaskContext(
                    command: pendingCommandForPriorTaskContext,
                    preparedRun: preparedRun,
                    status: .completed,
                    summary: result.summary,
                    startedAt: pendingTaskHistoryStartedAt
                )
            }
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

    private func recordPriorTaskContext(
        command: String,
        preparedRun: PreparedAgentRun,
        status: PriorTaskOutcomeStatus,
        summary: String,
        startedAt: Date? = nil
    ) {
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
        recordTaskHistoryIfTerminal(command: command, status: status, startedAt: startedAt, workspaceName: workspaceName)
    }

    private func recordPriorTaskContext(
        command: String,
        status: PriorTaskOutcomeStatus,
        summary: String,
        startedAt: Date? = nil
    ) {
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
        recordTaskHistoryIfTerminal(command: command, status: status, startedAt: startedAt, workspaceName: workspaceName)
    }

    private func recordTaskHistoryIfTerminal(
        command: String,
        status: PriorTaskOutcomeStatus,
        startedAt: Date?,
        workspaceName: String?
    ) {
        guard [.completed, .failed, .canceled].contains(status),
              let startedAt else {
            return
        }

        do {
            try taskHistoryStore.record(
                CompletedTaskRecord(
                    command: command,
                    startedAt: startedAt,
                    completedAt: Date(),
                    outcomeStatus: status,
                    workspaceName: workspaceName,
                    // Derived from origin rather than threaded through every call site — origin
                    // already records who started this run, and a second parameter saying the same
                    // thing is a second thing to forget to pass.
                    trigger: activeTaskOrigin == .scheduled ? .scheduled : .manual
                )
            )
            refreshTaskHistory()
        } catch {
            setError("Could not save task history: \(error.localizedDescription)")
            logStore.append(.observe, "Could not record task history: \(error.localizedDescription)")
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
        guard !isRunning, !isAwaitingApproval else {
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
            let executor = makeExecutor()
            let runner = AgentRunner(
                planner: InstantOnlyFallbackPlanner(),
                executor: executor,
                logStore: logStore,
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

            let result = try await runner.execute(
                prepared,
                approvalDecision: .approved(.tier2),
                confirmationMessage: "Scheduled run approved by this routine's unattended-run setting"
            )
            recordScheduledRunInHistory(name: name, at: occurrence)
            recordScheduledTaskHistory(status: .completed, startedAt: startedAt)
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
            // `.previewOnly` (a preview-only tier-2 policy) and `.refused` (tier 4) are equally
            // permanent for a run with nobody present to approve anything, and leaving either one
            // on the old skip-forever path would keep this bug alive in two of the three branches
            // that can reach it.
            logStore.append(.summarize, "Scheduled run paused: \(error.localizedDescription)")
            pauseSchedule(routineNamed: name, because: scheduledRunPauseCause(for: error))
        } catch {
            logStore.append(.summarize, "Scheduled run failed: \(error.localizedDescription)")
            recordScheduledTaskHistory(status: .failed, startedAt: startedAt)
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
    private func recordScheduledTaskHistory(status: PriorTaskOutcomeStatus, startedAt: Date) {
        guard let command = scheduledRunDisplayCommand else {
            return
        }
        do {
            try taskHistoryStore.record(
                CompletedTaskRecord(
                    command: command,
                    startedAt: startedAt,
                    completedAt: Date(),
                    outcomeStatus: status,
                    trigger: .scheduled
                )
            )
            refreshTaskHistory()
        } catch {
            recordLocalStorageWriteFailure(
                "Sonny could not save this scheduled run to task history: \(error.localizedDescription)"
            )
        }
    }

    /// Marks an occurrence handled so the next tick moves past it. Applies to every outcome — ran,
    /// refused, skipped, missed — because any of them leaving the baseline untouched would make the
    /// scheduler retry the same occurrence every 30 seconds.
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
