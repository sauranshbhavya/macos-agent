import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
import MacAgentCore

/// The two fields every content-bearing request carries, from the run they describe (SONNY-130).
///
/// `docs/sonny-backend-api-contract.md` §2.4 requires `task_id` and `retention` on all five model
/// routes and defaults neither. The client-side halves of that are here: where the id comes from,
/// that it is the *same* id the local `CompletedTaskRecord` is filed under — §5.1, and what
/// `DELETE /v1/tasks/{task_id}` will join on — and that the retention answer is the one the run was
/// actually assessed under rather than whatever the published switch happens to say.
///
/// The planner stub is what makes the context observable: `PlannerProvider`'s gateway shape hands
/// the run's `BackendTaskContext` to the constructor, so a provider that records it sees exactly
/// what a real one would be built with.
@Suite
@MainActor
struct BackendTaskIdentityTests {
    @Test
    func theRecordATaskWritesCarriesTheIdItsRequestsWereFiledUnder() async throws {
        // §5.1's whole point. A `CompletedTaskRecord` whose id defaults to a fresh UUID at write
        // time names a task no request ever mentioned, so the backend's retained content and this
        // row would be filed under different keys and nothing could join them.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = CapturedTaskContexts()
        let viewModel = try makeViewModel(root: root, capturing: seen)

        try await run(viewModel, command: "do something no resolver has a pattern for")

        let context = try #require(seen.contexts.first)
        #expect(viewModel.currentTaskID == context.taskID)
        let record = try #require(viewModel.taskHistoryRecords.first)
        #expect(record.id == context.taskID)
    }

    @Test
    func eachRunGetsItsOwnTaskID() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = CapturedTaskContexts()
        let viewModel = try makeViewModel(root: root, capturing: seen)

        try await run(viewModel, command: "first command with no resolver pattern")
        try await run(viewModel, command: "second command with no resolver pattern")

        let ids = seen.contexts.map(\.taskID)
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
        // And each row is filed under the run that wrote it, not under the latest one.
        #expect(Set(viewModel.taskHistoryRecords.compactMap(\.id)) == Set(ids))
    }

    @Test
    func aRunStartedWithDontSaveThisTaskSendsRetentionNone() async throws {
        // §10.1: `"none"` is what the app sends for a run started with "Don't save this task" on.
        // Observed at the planner's own construction, which is where a real request would read it.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let seen = CapturedTaskContexts()
        let viewModel = try makeViewModel(root: root, capturing: seen)
        viewModel.taskRecordingPolicy = .suppressTraces

        try await run(viewModel, command: "a private command with no resolver pattern")

        #expect(seen.contexts.first?.retention == .notStored)
        // And task history is a trace store, so the suppressed run leaves no row at all — which is
        // why the id has to be observed at the planner rather than at the record here.
        #expect(viewModel.taskHistoryRecords.isEmpty)
    }

    @Test
    func theRetentionAnswerIsReadOffThePolicyTheRunWasAssessedUnderAndNotThePublishedSwitch() throws {
        // **The distinction `makeExecutor` already draws for `recordingPolicy`, applied to the wire
        // field.** A scheduled run deliberately passes `.record` — the switch cannot have been
        // pressed for a run the user did not start — so deriving retention from the published
        // property would send `retention: "none"` for a routine that happened to fire while the
        // user had the switch on for something they were composing.
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, capturing: CapturedTaskContexts())
        viewModel.taskRecordingPolicy = .suppressTraces

        #expect(viewModel.backendTaskContext(recordingPolicy: .record).retention == .standard)
        #expect(viewModel.backendTaskContext(recordingPolicy: .suppressTraces).retention == .notStored)
        #expect(viewModel.backendTaskContext(recordingPolicy: .record).taskID == viewModel.currentTaskID)
    }

    @Test
    func theExecutorAndTheWireFieldReadOneResolvedPolicy() throws {
        // A scan, because the hazard is two expressions drifting rather than one being wrong: the
        // executor's `recordingPolicy` and the task context's `retention` must come from the same
        // resolved value, or a scheduled run writes local traces under one answer and sends the
        // other.
        let source = try MacAgentSource.read("AgentViewModel.swift")
        // `region` rather than `braceBlock`, because the signature spans lines and `braceBlock`
        // wants an opening brace on the anchor line.
        let factory = try MacAgentSource.region(
            of: source,
            from: "        visionSession: VisionSessionEnvironment?\n    ) -> AgentActionExecutor {",
            to: "    private func startVoiceRecording("
        )
        #expect(MacAgentSource.count(
            of: "let resolvedRecordingPolicy = recordingPolicy ?? taskRecordingPolicy",
            inText: factory
        ) == 1)
        #expect(MacAgentSource.count(
            of: "backendTaskContext(recordingPolicy: resolvedRecordingPolicy)",
            inText: factory
        ) == 1)
        #expect(MacAgentSource.count(of: "recordingPolicy ?? taskRecordingPolicy", inText: factory) == 1)
    }

    @Test
    func theVoiceRouteRefusesOnHowLongTheKeyWasHeldRatherThanOnTheFilesLength() throws {
        // `AVAudioRecorder` stops itself at the ceiling, so the file is shorter than the hold. The
        // refusal is about the hold — it is what the founder's manual item does — and a check that
        // read the file's length would transcribe every over-long recording as an ordinary one.
        // A scan rather than a run, because starting a real recorder needs a microphone.
        let source = try MacAgentSource.read("AgentViewModel.swift")
        #expect(MacAgentSource.count(of: "recordedDuration: recording.heldFor", inText: source) == 1)
        #expect(MacAgentSource.count(of: "recording = try audioRecorder.stop()", inText: source) == 1)

        // The ceiling bounds the file and sits above the cap, so a recording never lands on the
        // boundary where a few milliseconds decide whether the user is refused or charged.
        #expect(AudioCommandRecorder.fileCeilingSeconds > VoiceRecordingLimit.maximumDurationSeconds)
        let recorderSource = try MacAgentSource.read("AudioCommandRecorder.swift")
        #expect(MacAgentSource.count(
            of: "recorder.record(forDuration: Self.fileCeilingSeconds)",
            inText: recorderSource
        ) == 1)
        // And no unbounded `record()` remains, which is the thing the cap exists to end.
        #expect(MacAgentSource.count(of: "recorder.record()", inText: recorderSource) == 0)
    }

    @Test
    func stoppingWithNoRecordingInFlightStillReportsItself() throws {
        #expect(throws: VoiceRecordingError.noActiveRecording) {
            _ = try AudioCommandRecorder().stop()
        }
    }

    // MARK: - Harness

    private func run(_ viewModel: AgentViewModel, command: String) async throws {
        viewModel.command = command
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Every `BackendTaskContext` the registry handed a planner, in order.
private final class CapturedTaskContexts: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BackendTaskContext] = []

    func append(_ context: BackendTaskContext) {
        lock.lock()
        recorded.append(context)
        lock.unlock()
    }

    var contexts: [BackendTaskContext] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A planner that records the context it was built with and produces a plan that runs to a terminal
/// state without touching anything — `unsupported` is refused by the executor, which is a terminal
/// failure and therefore writes a task-history row.
@MainActor
private final class RecordingStubPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Nothing Sonny can do.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "unsupported",
                    operation: .unsupported,
                    description: "Not a supported request."
                )
            ]
        )
    }
}

private func makeRegistry(capturing seen: CapturedTaskContexts) -> PlannerProviderRegistry {
    PlannerProviderRegistry(
        defaultProvider: PlannerProvider(
            id: "primary",
            displayName: "Primary",
            throughTheGateway: { taskContext, _ in
                seen.append(taskContext)
                return RecordingStubPlanner()
            }
        )
    )
}

@MainActor
private func makeViewModel(root: URL, capturing seen: CapturedTaskContexts) throws -> AgentViewModel {
    let suiteName = "BackendTaskIdentityTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let encryption = LocalStorageEncryption(
        keyManager: FixedIdentityKeyManager(bytes: Data(repeating: 0x3C, count: 32))
    )
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: NoShortcutsCatalog(),
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: { _ in },
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcut-run-history.json"),
            encryption: encryption
        ),
        taskHistoryStore: TaskHistoryStore(
            fileURL: root.appendingPathComponent("task-history.json"),
            encryption: encryption
        ),
        taskPlanDetailStore: TaskPlanDetailStore(
            fileURL: root.appendingPathComponent("task-plan-details.json"),
            encryption: encryption
        ),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: encryption
        ),
        approvedAppStore: ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: encryption
        ),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            encryption: encryption
        ),
        resumableTaskStore: ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: encryption
        ),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: SilentPasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
                encryption: encryption
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: makeRegistry(capturing: seen),
        plannerSelection: nil,
        userDefaults: userDefaults
    )
}

private struct FixedIdentityKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct NoShortcutsCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class SilentPasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackendTaskIdentityTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
