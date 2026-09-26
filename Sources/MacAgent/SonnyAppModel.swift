import AppKit
import Combine
import MacAgentCore

/// What the widget and the Command Center show and do, as thin presentation over `TaskDesk` (V2
/// plan section 6, "UI"). Every request goes through the desk; approvals, answers and stops are
/// routed by task and action id, never by which window is in front.
@MainActor
final class SonnyAppModel: ObservableObject {
    enum VoiceState: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing
    }

    /// An earlier task the next composer request follows up on.
    struct FollowUp: Equatable {
        let task: TaskID
        let goal: String
    }

    // The composer.
    @Published var composerText = ""
    /// "Don't save this task": the next request is private (decision 10). Resets once it's sent.
    @Published var isPrivate = false
    @Published private(set) var followUp: FollowUp?
    @Published var mode: AgentInteractionMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    /// The task the widget follows: the latest one the person started themselves.
    @Published private(set) var followedTask: TaskID?
    @Published private(set) var voice: VoiceState = .idle
    @Published private(set) var voiceProblem: String?
    @Published private(set) var clientVersion: ClientVersionState = .current
    @Published private(set) var credits: CreditBalance?
    @Published private(set) var isSettingAutoTopUp = false
    @Published private(set) var autoTopUpFailure: BillingSettingFailure?
    @Published private(set) var approvedApps: [ApprovedApp] = []
    @Published private(set) var clipboardHistoryOn = false
    @Published private(set) var permissions: [PermissionReadinessItem] = []
    @Published private(set) var voiceHotKeyReady = true
    /// Bumped to bring the widget forward and expanded.
    @Published private(set) var widgetRequests = 0

    let desk: TaskDesk
    let stores: KernelStores
    private let client: SonnyBackendClient
    private let creditService: CreditBalanceService
    private let clipboardMonitor: ClipboardHistoryMonitor
    private let recorder = AudioCommandRecorder()
    private let permissionService = PermissionReadinessService()
    private let defaults: UserDefaults
    private var pulse: Timer?
    private var clipboardTimer: Timer?
    /// Whether a private task was running at the clipboard's last poll.
    private var privateRanAtLastPoll = false
    private var voiceLimit: Task<Void, Never>?
    /// The private setting when listening began; the transcription and the task both keep it.
    private var voicePrivate = false
    private var forwarding: Set<AnyCancellable> = []
    /// The private task the toggle is on for; the toggle resets when it ends.
    private var privateTask: TaskID?

    static let modeKey = "SonnyV2InteractionMode"
    /// How often schedules and watchers are checked.
    static let pulseInterval: TimeInterval = 30

    init(
        desk: TaskDesk,
        stores: KernelStores,
        client: SonnyBackendClient,
        defaults: UserDefaults = .standard,
        pasteboard: any PasteboardReading = SystemPasteboardReader()
    ) {
        self.desk = desk
        self.stores = stores
        self.client = client
        self.defaults = defaults
        creditService = CreditBalanceService(client: client)
        clipboardMonitor = ClipboardHistoryMonitor(reader: pasteboard, store: stores.clipboard, settingsStore: stores.clipboardSettings)
        mode = defaults.string(forKey: Self.modeKey).flatMap(AgentInteractionMode.init(rawValue:)) ?? .normal
        // The views read the desk and the controller through this model, so their changes are
        // this model's changes.
        desk.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        desk.controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &forwarding)
        desk.controller.$tasks.sink { [weak self] _ in
            Task { @MainActor in self?.resetPrivateIfSettled() }
        }.store(in: &forwarding)
    }

    var controller: TaskController { desk.controller }

    // MARK: Starting

    func start() async {
        await controller.launch()
        await desk.load()
        clipboardHistoryOn = (try? stores.clipboardSettings.load().isEnabled) ?? false
        clipboardMonitor.resynchronize()
        refreshApprovedApps()
        refreshPermissions()
        pulse = Timer.scheduledTimer(withTimeInterval: Self.pulseInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSchedulesAndWatchers() }
        }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollClipboard() }
        }
        Task { await checkSchedulesAndWatchers() }
        Task { await watchClientVersion() }
    }

    func stop() async {
        pulse?.invalidate()
        clipboardTimer?.invalidate()
        await controller.shutDown()
    }

    /// Clipboard history keeps what's copied, except while a private task runs: those copies are
    /// marked as seen and never kept, then and after it ends. One more tick is skipped after the
    /// last private task ends, so a copy made in its final second isn't kept either.
    func pollClipboard() {
        let privateRunning = controller.tasks.contains { $0.isPrivate && !$0.phase.isTerminal }
        if privateRunning || privateRanAtLastPoll {
            clipboardMonitor.resynchronize()
        } else {
            _ = try? clipboardMonitor.poll()
        }
        privateRanAtLastPoll = privateRunning
    }

    private func checkSchedulesAndWatchers() async {
        await desk.runDueRoutines()
        await desk.checkWatchers()
    }

    private func watchClientVersion() async {
        for await state in await client.clientVersionUpdates() {
            clientVersion = state
        }
    }

    // MARK: What the widget shows

    /// A task waiting on the person, whichever way it started; else the one they started last.
    var widgetTask: TaskSnapshot? {
        controller.tasks.last { $0.needsThePerson } ?? followedTask.flatMap { controller.snapshot($0) }
    }

    var isTaskRunning: Bool {
        controller.tasks.contains { !$0.phase.isTerminal }
    }

    var canSubmit: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && voice == .idle
    }

    // MARK: Asking

    func submitComposer() {
        let text = composerText
        guard canSubmit else { return }
        composerText = ""
        ask(text, origin: .composer)
    }

    /// The private toggle stays as it was for the whole task and resets once the task settles.
    private func ask(_ text: String, origin: TaskOrigin, isPrivate: Bool? = nil) {
        let isPrivate = isPrivate ?? self.isPrivate
        let prior = followUp?.task
        followUp = nil
        Task {
            guard let submission = await desk.ask(text, origin: origin, isPrivate: isPrivate, followingUp: prior) else { return }
            followedTask = submission.task
            if isPrivate {
                privateTask = submission.task
                self.isPrivate = true
            }
            resetPrivateIfSettled()
        }
    }

    private func resetPrivateIfSettled() {
        guard let id = privateTask, controller.snapshot(id)?.phase.isTerminal ?? true else { return }
        privateTask = nil
        isPrivate = false
    }

    func followUp(on task: TaskID, goal: String) {
        followUp = FollowUp(task: task, goal: goal)
        widgetRequests += 1
    }

    /// True while the task the widget follows is still going; the composer and the buttons that
    /// start another followed task wait for it.
    var isFollowedTaskRunning: Bool {
        followedTask.flatMap { controller.snapshot($0) }.map { !$0.phase.isTerminal } ?? false
    }

    /// Asks for the same thing again, as a new task.
    func runAgain(_ goal: String) {
        guard !isFollowedTaskRunning else { return }
        widgetRequests += 1
        ask(goal, origin: .composer)
    }

    func clearFollowUp() {
        followUp = nil
    }

    func run(_ routine: RoutineGoal) {
        guard !isFollowedTaskRunning else { return }
        widgetRequests += 1
        Task { followedTask = await desk.run(routine).task }
    }

    /// Clears a finished task from the widget.
    func dismissFinishedTask() {
        guard let task = widgetTask, task.phase.isTerminal else { return }
        followedTask = nil
    }

    func showWidget() {
        widgetRequests += 1
    }

    // MARK: Answering a task

    func decide(_ commit: PreparedCommit, approved: Bool) {
        Task { await controller.decide(task: commit.task, action: commit.action, commit: commit.commitID, approved: approved) }
    }

    func answer(_ task: TaskID, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await controller.answer(task: task, text: trimmed) }
    }

    func resolvePause(_ task: TaskID, _ choice: PauseChoice) {
        Task { await controller.resolvePause(task: task, choice: choice) }
    }

    func cancel(_ task: TaskID) {
        Task { await controller.cancel(task) }
    }

    /// The Stop control, the menu's Stop and the emergency-stop hotkey: every live task stops.
    func stopEverything() {
        for task in controller.tasks where !task.phase.isTerminal {
            Task { await controller.cancel(task.id) }
        }
        cancelVoice()
    }

    // MARK: Voice

    /// The widget's microphone: the first press listens, the second sends what was heard.
    func toggleVoice() {
        switch voice {
        case .idle: beginVoice()
        case .recording: finishVoice()
        case .transcribing: break
        }
    }

    func beginVoice() {
        guard voice == .idle else { return }
        voiceProblem = nil
        voicePrivate = isPrivate
        Task {
            guard await AudioCommandRecorder.requestMicrophonePermission() else {
                voiceProblem = "Sonny needs the microphone. Allow it in System Settings › Privacy & Security › Microphone."
                return
            }
            do {
                try recorder.start()
                let startedAt = Date()
                voice = .recording(startedAt: startedAt)
                widgetRequests += 1
                voiceLimit = Task {
                    try? await Task.sleep(for: .seconds(VoiceRecordingLimit.maximumDurationSeconds))
                    guard !Task.isCancelled, voice == .recording(startedAt: startedAt) else { return }
                    finishVoice()
                }
            } catch {
                voiceProblem = "Sonny couldn't start listening."
            }
        }
    }

    func finishVoice() {
        guard case .recording = voice else { return }
        voiceLimit?.cancel()
        let recording: FinishedRecording
        do {
            recording = try recorder.stop()
        } catch {
            voice = .idle
            voiceProblem = "Sonny couldn't finish the recording."
            return
        }
        voice = .transcribing
        let transcriber = OpenAITranscriber(
            client: client,
            taskContext: BackendTaskContext(taskID: UUID().uuidString, retention: voicePrivate ? .notStored : .standard)
        )
        Task {
            defer { try? FileManager.default.removeItem(at: recording.url) }
            do {
                let result = try await transcriber.transcribe(audioFileURL: recording.url, recordedDuration: recording.heldFor)
                voice = .idle
                let heard = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !heard.isEmpty else {
                    voiceProblem = "Sonny didn't hear anything."
                    return
                }
                ask(heard, origin: .voice, isPrivate: voicePrivate)
            } catch {
                voice = .idle
                voiceProblem = (error as? LocalizedError)?.errorDescription ?? "Sonny couldn't understand the recording."
            }
        }
    }

    func cancelVoice() {
        guard case .recording = voice else { return }
        voiceLimit?.cancel()
        recorder.cancel()
        voice = .idle
    }

    func markVoiceHotKeyUnavailable() {
        voiceHotKeyReady = false
        refreshPermissions()
    }

    // MARK: Settings

    func setClipboardHistory(_ on: Bool) {
        do {
            var settings = try stores.clipboardSettings.load()
            settings.isEnabled = on
            try stores.clipboardSettings.save(settings)
            clipboardHistoryOn = on
            clipboardMonitor.resynchronize()
        } catch {
            clipboardHistoryOn = (try? stores.clipboardSettings.load().isEnabled) ?? false
        }
    }

    func refreshApprovedApps() {
        approvedApps = (try? stores.approvedApps.loadAll()) ?? []
    }

    func approve(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        _ = try? stores.approvedApps.approve(bundleIdentifier: bundleID, displayName: app.localizedName ?? bundleID)
        refreshApprovedApps()
    }

    func forget(_ app: ApprovedApp) {
        try? stores.approvedApps.forget(bundleIdentifier: app.bundleIdentifier)
        refreshApprovedApps()
    }

    /// Installed by `main.swift`: the account model's one entitlement service confirming the plan.
    var entitlementConfirmation: (@Sendable () async -> EntitlementDecision)?
    private var modelAccess: ModelAccessReadiness = .undetermined
    private var planAccess: PlanReadiness = .undetermined

    func refreshPermissions() {
        recomputePermissions()
        Task {
            do {
                modelAccess = try await client.restoredIdentity() == nil ? .signedOut : .signedIn
            } catch {
                modelAccess = .undetermined
            }
            if let entitlementConfirmation {
                switch await entitlementConfirmation() {
                case .entitled: planAccess = .confirmed
                case .refused(let refusal): planAccess = .unconfirmed(refusal)
                }
            } else {
                planAccess = .undetermined
            }
            recomputePermissions()
        }
    }

    private func recomputePermissions() {
        permissions = permissionService.currentStatus(
            modelAccess: modelAccess,
            planAccess: planAccess,
            hotKeyReady: voiceHotKeyReady
        )
    }

    func refreshCredits() async {
        credits = try? await creditService.fetch()
    }

    func forgetCredits() {
        credits = nil
    }

    func setAutoTopUp(_ enabled: Bool) async {
        isSettingAutoTopUp = true
        autoTopUpFailure = nil
        defer { isSettingAutoTopUp = false }
        do {
            credits = try await creditService.setAutoTopUp(enabled)
        } catch let error as SonnyBackendError {
            autoTopUpFailure = BillingSettingFailure(error)
        } catch {
            autoTopUpFailure = .cannotBeChanged
        }
    }
}

extension TaskSnapshot {
    /// Waiting on the person: an approval, a question, or an action that may already have run.
    var needsThePerson: Bool {
        switch phase {
        case .awaitingApproval, .awaitingAnswer, .paused: true
        default: false
        }
    }
}
