import AppKit
import Foundation
import MacAgentCore

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var command: String = ""
    @Published var dryRun: Bool = true
    @Published var isRunning: Bool = false
    @Published var plan: AgentPlan?
    @Published var previews: [ActionPreview] = []
    @Published var finalSummary: String = ""
    @Published var errorMessage: String?
    @Published var clarificationQuestion: String?
    @Published var clarificationAnswer: String = ""
    @Published var suggestions: [RunSuggestion] = []
    @Published var stepStatuses: [String: AgentStepStatus] = [:]
    @Published var voiceTranscript: String = ""
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
    private var clarificationForcesRealExecution = false
    /// Preserves the original task's origin across the clarification pause, same pattern as
    /// `clarificationAutoExecute`/`clarificationForcesRealExecution` — `submitClarification()`
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

    var recentTaskAffordanceText: String? {
        priorTaskContext?.shortDisplayText
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

    var primaryButtonTitle: String {
        if isAwaitingApproval {
            return "Approve"
        }
        return dryRun ? "Preview" : "Run"
    }

    var primaryButtonIcon: String {
        if isAwaitingApproval {
            return "checkmark.shield"
        }
        return dryRun ? "eye" : "play"
    }

    /// - Parameter forceRealExecution: Bypasses the `dryRun` preview-only gate for this run without
    ///   mutating the shared `dryRun` toggle itself, so a caller (the floating widget, which has no
    ///   dry-run UI of its own) can always act for real while leaving Command Center's own composer
    ///   toggle exactly as the user left it.
    /// - Parameter origin: Which surface is submitting this — see `TaskOrigin`. Defaults to
    ///   `.commandCenter` so every existing call site (Command Center's own composer) needs no
    ///   change; the floating widget's own call sites pass `.widget` explicitly.
    func start(autoExecute: Bool = false, forceRealExecution: Bool = false, origin: TaskOrigin = .commandCenter) {
        if isAwaitingApproval {
            approvePendingRun()
            return
        }

        guard canSubmit else {
            if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorMessage = "Enter a natural-language command first."
            }
            return
        }

        currentTask?.cancel()
        isRunning = true
        currentTask = Task {
            await performStart(autoExecute: autoExecute, forceRealExecution: forceRealExecution, origin: origin)
        }
    }

    private func performStart(autoExecute: Bool, forceRealExecution: Bool, origin: TaskOrigin) async {
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

        let submittedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        lastCommand = submittedCommand
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
                clarificationAutoExecute = autoExecute || !dryRun || forceRealExecution
                clarificationForcesRealExecution = forceRealExecution
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

            if dryRun && !forceRealExecution {
                markAllSteps(.complete)
                finalSummary = "Dry run complete. No files were written, no apps were opened, and no documents were converted."
                logStore.append(.summarize, finalSummary)
                recordPriorTaskContext(
                    command: submittedCommand,
                    preparedRun: prepared,
                    status: .dryRun,
                    summary: finalSummary
                )
            } else {
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
                    errorMessage = "Sonny refused this action under the current approval policy."
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
            }
        } catch is CancellationError {
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
        } catch {
            markAllSteps(.failed)
            errorMessage = error.localizedDescription
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
    /// exactly those cases. Exposed as a bool rather than exposing `lastCommand` itself, since
    /// callers only need the yes/no, not the text.
    var hasRetryableCommand: Bool {
        !lastCommand.isEmpty
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
        start(forceRealExecution: true, origin: .widget)
    }

    func submitClarification() {
        guard let question = clarificationQuestion else {
            return
        }

        let answer = clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            errorMessage = "Enter an answer before continuing."
            return
        }

        command = """
        \(command.trimmingCharacters(in: .whitespacesAndNewlines))

        Clarification question: \(question)
        Clarification answer: \(answer)
        """
        let shouldAutoExecute = clarificationAutoExecute
        let shouldForceRealExecution = clarificationForcesRealExecution
        let shouldUseOrigin = clarificationOrigin
        clarificationAutoExecute = false
        clarificationForcesRealExecution = false
        clarificationOrigin = .commandCenter
        clarificationQuestion = nil
        clarificationAnswer = ""
        start(autoExecute: shouldAutoExecute, forceRealExecution: shouldForceRealExecution, origin: shouldUseOrigin)
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
                errorMessage = "OPENAI_API_KEY is not set. Export it before launching Sonny, then relaunch the app."
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
        errorMessage = message
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
            errorMessage = "Could not save clipboard history setting: \(error.localizedDescription)"
        }
    }

    func deleteLocalData() {
        guard !isRunning else {
            errorMessage = "Stop the current run before deleting local data."
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
            errorMessage = message
        }
    }

    func runRoutineWidget(_ routine: StoredRoutine) {
        command = "Run my \(routine.name) routine"
        dryRun = false
        start(autoExecute: true)
    }

    func openWorkspaceWidget(_ workspace: StoredWorkspace) {
        command = "Open my \(workspace.name) workspace"
        dryRun = false
        start(autoExecute: true)
    }

    func markWorkspaceAsTeam(_ workspace: StoredWorkspace) {
        var updated = workspace
        updated.teamType = .team
        do {
            try workspaceStore.save(updated)
            refreshSavedItems()
        } catch {
            errorMessage = "Could not update workspace: \(error.localizedDescription)"
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

    func reset() {
        currentTask?.cancel()
        audioRecorder.cancel()
        command = ""
        dryRun = true
        isRunning = false
        plan = nil
        previews = []
        finalSummary = ""
        errorMessage = nil
        localDataDeletionStatusMessage = nil
        clarificationQuestion = nil
        clarificationAnswer = ""
        clarificationAutoExecute = false
        clarificationForcesRealExecution = false
        approvalRequest = nil
        suggestions = []
        stepStatuses = [:]
        priorTaskContext = nil
        taskUsageSummary = .empty
        voiceTranscript = ""
        isPreparingVoiceRecording = false
        isRecordingVoice = false
        isTranscribingVoice = false
        isPushToTalkHotKeyDown = false
        refreshPermissions()
        refreshSavedItems()
        refreshTaskHistory()
        refreshClipboardHistoryNotice()
        preparedRun = nil
        runner = nil
        pendingCommandForPriorTaskContext = nil
        pendingTaskHistoryStartedAt = nil
        preserveUsageForNextStart = false
        priorTaskContextStore.clear()
        taskUsageRecorder.reset()
        logStore.reset()
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
        clarificationForcesRealExecution = false
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
        errorMessage = message
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
                errorMessage = "OPENAI_API_KEY is not set. Export it before launching Sonny, then relaunch the app."
            }
            return
        }

        voiceRecordingOrigin = origin
        isPreparingVoiceRecording = true

        Task {
            let granted = await AudioCommandRecorder.requestMicrophonePermission()
            guard granted else {
                isPreparingVoiceRecording = false
                errorMessage = "Microphone permission was denied. Allow microphone access for the launching app, then try again."
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
                voiceTranscript = ""
                finalSummary = ""
                errorMessage = nil
                let recordingMessage = trigger == .hotKey
                    ? "Recording voice command from hotkey"
                    : "Recording voice command"
                logStore.append(.observe, recordingMessage)
            } catch {
                isPreparingVoiceRecording = false
                errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
                voiceTranscript = result.text
                dryRun = false
                finalSummary = ""
                isTranscribingVoice = false
                preserveUsageForNextStart = true
                logStore.append(.observe, "Transcript ready. Sonny will act now.")
                start(autoExecute: true, origin: voiceRecordingOrigin)
            } catch {
                isTranscribingVoice = false
                errorMessage = error.localizedDescription
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
        } catch is CancellationError {
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
            errorMessage = error.localizedDescription
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
            errorMessage = "Could not save task history: \(error.localizedDescription)"
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
