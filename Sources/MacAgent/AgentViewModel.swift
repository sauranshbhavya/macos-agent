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
    @Published var showPermissionPanel: Bool = false
    @Published var permissionItems: [PermissionReadinessItem] = []
    @Published var savedRoutines: [StoredRoutine] = []
    @Published var savedWorkspaces: [StoredWorkspace] = []
    @Published var approvalRequest: RiskApprovalRequest?
    @Published var showClipboardHistoryNotice: Bool = false
    @Published var clipboardHistoryEnabled: Bool = true
    @Published var priorTaskContext: PriorTaskContext?
    @Published var taskUsageSummary: TaskUsageSummary = .empty
    @Published var localDataDeletionStatusMessage: String?
    @Published var usePointerCursors: Bool = true {
        didSet {
            userDefaults.set(usePointerCursors, forKey: UserDefaultsKeys.usePointerCursors)
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

        var label: String {
            switch self {
            case .savedRoutines:
                return "saved routines"
            case .savedWorkspaces:
                return "saved workspaces"
            case .clipboardHistorySettings:
                return "clipboard history settings"
            }
        }
    }

    private enum VoiceRecordingTrigger {
        case button
        case hotKey
    }

    private enum UserDefaultsKeys {
        static let usePointerCursors = "com.sonny.preferences.usePointerCursors"
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

    var setupStatus: String {
        hasAPIKey ? "Ready - \(modelName); voice - \(transcriptionModelName)" : "Missing OPENAI_API_KEY"
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

    func start(autoExecute: Bool = false) {
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
            await performStart(autoExecute: autoExecute)
        }
    }

    private func performStart(autoExecute: Bool) async {
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
                clarificationAutoExecute = autoExecute || !dryRun
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

            if dryRun {
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
        clarificationAutoExecute = false
        clarificationQuestion = nil
        clarificationAnswer = ""
        start(autoExecute: shouldAutoExecute)
    }

    func toggleVoiceRecording() {
        if isRecordingVoice {
            stopVoiceRecordingAndTranscribe()
        } else {
            startVoiceRecording(trigger: .button)
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
        startVoiceRecording(trigger: .hotKey)
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

    func togglePermissionPanel() {
        refreshPermissions()
        showPermissionPanel.toggle()
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
        showClipboardHistoryNotice = !settings.noticeDismissed

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
            showClipboardHistoryNotice = false
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
        command = "Run my \(routine.name) routine."
        dryRun = false
        start(autoExecute: true)
    }

    func openWorkspaceWidget(_ workspace: StoredWorkspace) {
        command = "Open my \(workspace.name) workspace."
        dryRun = false
        start(autoExecute: true)
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
        showPermissionPanel = false
        refreshPermissions()
        refreshSavedItems()
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

    private func startVoiceRecording(trigger: VoiceRecordingTrigger) {
        guard canUseVoice else {
            if !hasAPIKey {
                errorMessage = "OPENAI_API_KEY is not set. Export it before launching Sonny, then relaunch the app."
            }
            return
        }

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
                start(autoExecute: true)
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
        recordTaskHistoryIfTerminal(command: command, status: status, startedAt: startedAt)
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
        recordTaskHistoryIfTerminal(command: command, status: status, startedAt: startedAt)
    }

    private func recordTaskHistoryIfTerminal(
        command: String,
        status: PriorTaskOutcomeStatus,
        startedAt: Date?
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
                    outcomeStatus: status
                )
            )
        } catch {
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
