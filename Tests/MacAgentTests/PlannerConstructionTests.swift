import Foundation
import Testing
import MacAgentTestSupport
@testable import MacAgent
import MacAgentCore

/// How a run's planner is built, now that which *provider* serves it is the server's to decide
/// (SONNY-132).
///
/// **This file was `PlannerSelectionTests` and its subject no longer exists.** SONNY-85 gave the
/// client a registry, a `SONNY_PLANNER` selection, a fallback to the default when a selection could
/// not be honored, and a widget strip announcing the swap. All four are deleted: `MODEL_ROUTE_PLAN`
/// on the gateway names the chain, `docs/sonny-backend-api-contract.md` §4.2 forbids the response
/// from naming which provider answered, and there is one planner on this side. Its four tests are
/// migrated rather than dropped — what each became is written on the test that replaced it, and the
/// two that pinned copy for a state that can no longer occur are recorded below the suite.
///
/// What is left worth holding is the seam itself: `performStart` builds its planner through the
/// injected factory, hands it *this run's* facts, and a delegated vision instruction goes through
/// the same one. Every command used here is free text the instant resolver has no pattern for, so
/// each dispatch reaches the planner branch; the stub answers with a clarify plan whose question
/// names it, so "who planned this" is observable without executing anything.
@Suite
@MainActor
struct PlannerConstructionTests {
    @Test
    func aDispatchedTaskIsPlannedByTheInjectedFactory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root)

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.clarificationQuestion == "Planned by the injected factory — which penguin?")
        #expect(viewModel.errorMessage == nil)
    }

    /// Migrated from `PlannerProviderRegistryTests.makePlannerHandsTheCallersUsageRecorderToThe`
    /// `ProviderConstructor`, which pinned the same property one layer down. Provider obligation 1
    /// — usage recording is opt-in through the recorder the caller supplies — has a seam only if the
    /// recorder the run owns is the recorder the planner is built with. Pinned by identity, not by
    /// effect, so a factory handed some *other* recorder fails here rather than in whichever usage
    /// summary later reads zero.
    @Test
    func theFactoryIsHandedTheRunsOwnUsageRecorder() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = RecorderCapture()
        let recorder = TaskUsageRecorder()
        let viewModel = try makeViewModel(root: root, usageRecorder: recorder) { _, seen in
            capture.identifier = ObjectIdentifier(seen as AnyObject)
        }

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(capture.identifier == ObjectIdentifier(recorder))
    }

    /// **What a run records reaches `taskUsageSummary`, so the local per-task summary cannot
    /// silently go blank** (SONNY-133).
    ///
    /// The acceptance criterion is the ticket's own, and the contract states the rule it protects
    /// (§11): "Server-side metering is the billable truth; where the two disagree the server is
    /// authoritative, and the local summary must not silently go blank." The server half now writes
    /// a metering event per call, which is what makes the second clause worth pinning — this side is
    /// an approximation, and an approximation that quietly stopped populating would look exactly
    /// like a task that cost nothing.
    ///
    /// The test above pins the recorder's *identity* one layer up; this pins the effect all the way
    /// out to the published property, through a real `performStart` and its `defer`. Both are worth
    /// having: a factory handed the right recorder whose values never reach the surface passes the
    /// first and fails this.
    @Test
    func whatARunRecordsReachesThePublishedUsageSummary() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(
            root: root,
            // A screen-control record, because that is the kind this row of work exists for: the
            // most expensive call the product makes, and the one nothing recorded before SONNY-131.
            plannerUsage: AIUsageRecord(
                kind: .screenControl,
                model: "screen.analyze",
                tokenSource: .reported,
                tokenCounts: AIUsageTokenCounts(inputTokens: 1_900, outputTokens: 40, totalTokens: 1_940)
            )
        )

        // Empty before the run, so the assertion below is about this run rather than about a field
        // that was never cleared.
        #expect(viewModel.taskUsageSummary.requestCount == 0)

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let summary = viewModel.taskUsageSummary
        #expect(summary.requestCount == 1)
        #expect(summary.records.first?.kind == .screenControl)
        #expect(summary.reportedTotalTokens == 1_940)
        #expect(summary.estimatedTotalTokens == 0)
        #expect(summary.hasUsageDetails)
    }

    /// The run's own `BackendTaskContext` reaches the factory — this task's id, and the retention
    /// answer §2.4.2 forbids anyone from guessing.
    ///
    /// `BackendTaskIdentityTests` owns the *content* of that context across a whole run — when the
    /// id is minted, that it survives a clarification, that "Don't save this task" reaches it — and
    /// is not duplicated here. What this pins is narrower and is this file's: the value the factory
    /// receives is the view model's current one rather than a fresh or defaulted one.
    @Test
    func theFactoryIsHandedThisRunsTaskContext() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ContextCapture()
        let viewModel = try makeViewModel(root: root) { context, _ in
            capture.contexts.append(context)
        }

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(capture.contexts.count == 1)
        #expect(capture.contexts.first?.taskID == viewModel.currentTaskID)
        #expect(capture.contexts.first?.retention == .standard)
    }

    /// A delegated vision instruction is planned by the same factory a typed command is — the
    /// property `makeDelegationRunner()`'s doc claims by construction, checked rather than trusted.
    ///
    /// `VisionSessionRunTests` drives a whole delegated session; this asserts the one thing that
    /// would break silently if `makeDelegationRunner` ever grew a planner of its own.
    @Test
    func aDelegatedInstructionGoesThroughTheSameFactory() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ContextCapture()
        let viewModel = try makeViewModel(root: root) { context, _ in
            capture.contexts.append(context)
        }

        let runner = viewModel.makeDelegationRunner()
        let plan = try await runner.prepare(command: "open the settings pane", priorTaskContext: nil)

        #expect(plan.plan.steps.first?.question == "Planned by the injected factory — which penguin?")
        #expect(capture.contexts.count == 1)
        #expect(capture.contexts.first?.taskID == viewModel.currentTaskID)
    }
}

/// **Two of this file's four original tests pinned user-facing copy for states that cannot occur,
/// and neither has a replacement.** `unknownSelectionFallsBackToTheDefaultAndPublishesTheNotice` and
/// `theNextHonoredDispatchClearsTheFallbackNotice` asserted the exact sentence of
/// `plannerFallbackNotice` and that it cleared on the next dispatch. There is no selection to be
/// unknown and no second provider on this side to fall back from, so there is no notice — the
/// enumeration of where all four of its states went is in `AgentViewModel`, where the published
/// property used to be. Recorded here rather than left as a gap in a diff, because "two tests were
/// deleted" and "two tests were deleted for a reason" read identically in a file listing.

// MARK: - Fixture

/// A planner that pauses at a clarification, so "who planned this" is observable without executing
/// anything and without a network.
@MainActor
private final class ClarifyingStubPlanner: Planning {
    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Ask before acting.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify",
                    operation: .clarify,
                    description: "Ask which one.",
                    question: "Planned by the injected factory — which penguin?"
                )
            ]
        )
    }
}

/// A planner that records one usage record as it plans, the way every real one does.
///
/// `OpenAIPlanner`, `WebResearchSynthesizer`, `OpenAITranscriber` and `SonnyVisionModelClient` all
/// call `usageRecorder.record(...)` beside their own reply parsing; this is that call and nothing
/// else, so a test can assert what reaches `taskUsageSummary` without a network, a provider or a
/// gateway.
private final class RecordingStubPlanner: Planning {
    private let usage: AIUsageRecord
    private let recorder: any TaskUsageRecording

    init(usage: AIUsageRecord, recorder: any TaskUsageRecording) {
        self.usage = usage
        self.recorder = recorder
    }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        recorder.record(usage)
        return AgentPlan(
            summary: "Ask before acting.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify",
                    operation: .clarify,
                    description: "Ask which one.",
                    question: "Planned by the injected factory — which penguin?"
                )
            ]
        )
    }
}

@MainActor
private final class RecorderCapture {
    var identifier: ObjectIdentifier?
}

@MainActor
private final class ContextCapture {
    var contexts: [BackendTaskContext] = []
}

@MainActor
private func makeViewModel(
    root: URL,
    usageRecorder: TaskUsageRecorder = TaskUsageRecorder(),
    plannerUsage: AIUsageRecord? = nil,
    observe: @escaping @MainActor (BackendTaskContext, any TaskUsageRecording) -> Void = { _, _ in }
) throws -> AgentViewModel {
    let suiteName = "PlannerSelectionTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    let encryption = LocalStorageEncryption(
        keyManager: FixedLocalStorageKeyManager(bytes: Data(repeating: 0x5A, count: 32))
    )
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json"), encryption: encryption),
        workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"), encryption: encryption),
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json"), encryption: encryption),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: EmptyShortcutCatalog(),
        // Hermetic seams (fakes in ProductShellTests.swift, same test target). These tests
        // pause at a clarification and execute nothing, but hermeticity stays structural, not
        // a property of today's fixture plans.
        browserOpener: HermeticBrowserOpener(),
        appOpener: HermeticAppOpener(),
        fileOpener: HermeticFileOpener(),
        finderRevealer: hermeticFinderRevealer,
        mediaOpener: HermeticMediaOpener(),
        runningAppSwitcher: HermeticRunningAppSwitcher(),
        shortcutInvoker: HermeticShortcutInvoker(),
        finderContextReader: HermeticFinderContextReader(),
        documentConverter: HermeticDocumentConverter(),
        zipArchiver: HermeticZipArchiver(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
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
            reader: FakePasteboardReader(),
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
        taskUsageRecorder: usageRecorder,
        makePlanner: { context, recorder in
            observe(context, recorder)
            guard let plannerUsage else {
                return ClarifyingStubPlanner()
            }
            // Handed the recorder the factory was given rather than the one the test holds, so the
            // test asserts the path the run actually uses instead of a value it planted itself.
            return RecordingStubPlanner(usage: plannerUsage, recorder: recorder)
        },
        userDefaults: userDefaults
    )
}

private struct FixedLocalStorageKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class FakePasteboardReader: PasteboardReading {
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
        .appendingPathComponent("PlannerSelectionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
