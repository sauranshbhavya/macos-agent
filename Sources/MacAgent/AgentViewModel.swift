import AppKit
import Foundation
import MacAgentCore

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var command: String = ""
    @Published var isRunning: Bool = false
    @Published var plan: AgentPlan?
    @Published var previews: [ActionPreview] = []
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
    @Published var localDataDeletionStatusMessage: String?
    /// Set once at the start of each *new* task (not touched by approve/clarify continuations,
    /// which resume the same task rather than starting one) — see `TaskOrigin`.
    @Published private(set) var activeTaskOrigin: TaskOrigin = .commandCenter
    /// Bump counter Command Center uses to ask the widget to come forward and take focus — e.g.
    /// "New routine"/"Create workspace" pre-fill `command` with a starting phrase and need
    /// somewhere for the user to finish typing it, now that Command Center has no composer of its
    /// own. `AppDelegate` observes this to call `widgetController.show()`; `FloatingWidgetView`
    /// observes it to focus its text field — both surfaces reacting to the same shared state
    /// rather than Command Center reaching into AppKit/the widget directly.
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
    private var localStorageLoadErrorMessage: String?

    private enum LocalStorageLoadFailureSource: CaseIterable, Hashable {
        case savedRoutines
        case savedWorkspaces
        case clipboardHistorySettings
        case taskHistory

        var label: String {
            switch self {
            case .savedRoutines:
                return "saved routines"
            case .savedWorkspaces:
                return "saved workspaces"
            case .clipboardHistorySettings:
                return "clipboard history settings"
            case .taskHistory:
                return "task history"
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
    }

    private enum UserDefaultsKeys {
        static let usePointerCursors = "com.sonny.preferences.usePointerCursors"
        static let displayFullNames = "com.sonny.preferences.displayFullNames"
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

    var hasTaskActivity: Bool {
        isRunning
            || isAwaitingApproval
            || plan != nil
            || !previews.isEmpty
            || !finalSummary.isEmpty
            || errorMessage != nil
            || clarificationQuestion != nil
            || taskUsageSummary.requestCount > 0
            || !logStore.events.isEmpty
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
        previews = []
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
            previews = prepared.previews
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
                markAllSteps(.complete)
                finalSummary = "Preview complete. The current approval policy does not allow this action to run automatically."
                logStore.append(.summarize, finalSummary)
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .prepared,
                    summary: finalSummary
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
        lastCommand
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
    /// retry button (§3.3.6) and by the error notification's "Retry" action.
    func retryLastCommand() {
        guard !lastCommand.isEmpty, !isRunning, !isAwaitingApproval else {
            return
        }
        command = lastCommand
        // Retry only has a real UI in the widget's own failure panel and the error notification
        // (Command Center has no retry control) — tagging it `.widget` regardless of the original
        // failed task's origin reflects that the retry action itself is a widget interaction.
        start(origin: .widget)
    }

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
        // The global hotkey always shows the floating widget first (see AppDelegate's
        // pushToTalkHotKey.onPress), so a hotkey-triggered recording is always a widget
        // interaction regardless of which surface happened to be focused.
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
        previews = []
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

        _ = try? clipboardHistoryMonitor.poll()
        clipboardHistoryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                _ = try? self.clipboardHistoryMonitor.poll()
            }
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

    private func publishLocalStorageLoadError() {
        guard !localStorageLoadFailures.isEmpty else {
            if errorMessage == localStorageLoadErrorMessage {
                errorMessage = nil
            }
            localStorageLoadErrorMessage = nil
            return
        }

        let details = LocalStorageLoadFailureSource.allCases
            .compactMap { localStorageLoadFailures[$0] }
            .joined(separator: "; ")
        let message = "Sonny could not load encrypted local data. A local data file exists but could not be decrypted or decoded. \(details)"
        localStorageLoadErrorMessage = message
        setError(message, persistent: true)
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
            usageRecorder: taskUsageRecorder,
            snippetStore: snippetStore,
            recentArtifactStore: recentArtifactStore,
            shortcutCatalog: shortcutCatalog,
            shortcutRunHistoryStore: shortcutRunHistoryStore
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
                    workspaceName: workspaceName
                )
            )
            refreshTaskHistory()
        } catch {
            setError("Could not save task history: \(error.localizedDescription)")
            logStore.append(.observe, "Could not record task history: \(error.localizedDescription)")
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
