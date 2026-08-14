import Foundation
import Testing
@testable import MacAgentCore

// MARK: - Fixtures

private struct FixedKeyManager: LocalStorageKeyManaging {
    let bytes = Data(repeating: 0x42, count: 32)

    func keyData() throws -> Data {
        bytes
    }
}

private func makeStore(root: URL) -> AIEgressStore {
    AIEgressStore(
        fileURL: root.appendingPathComponent("ai-egress-ledger.json"),
        encryption: LocalStorageEncryption(keyManager: FixedKeyManager())
    )
}

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-egress-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func entry(
    kind: AIEgressEntry.Kind = .plannerPrompt,
    sentAt: Date = Date(timeIntervalSince1970: 1_000),
    providerID: String = "openai",
    model: String? = "gpt-5.5"
) -> AIEgressEntry {
    AIEgressEntry(
        kind: kind,
        sentAt: sentAt,
        providerID: providerID,
        providerName: providerID.capitalized,
        model: model,
        retentionPosture: .retainedTemporarily,
        payloadSizeClass: .underOneKB,
        contextSources: ["command"]
    )
}

private final class SpyEgressRecorder: AIEgressRecording, @unchecked Sendable {
    private(set) var entries: [AIEgressEntry] = []
    /// Interleaved event log so ordering claims ("recorded before delegation") are pinned by
    /// data, not by assumption.
    private(set) var events: [String] = []

    func record(_ entry: AIEgressEntry) async {
        entries.append(entry)
        events.append("recorded:\(entry.kind.rawValue)")
    }

    func noteDelegation() {
        events.append("delegated")
    }
}

private final class ScriptedPlanner: Planning, @unchecked Sendable {
    let modelIdentifier: String?
    let error: Error?
    var onPlan: (() -> Void)?

    init(modelIdentifier: String? = "stub-model", error: Error? = nil) {
        self.modelIdentifier = modelIdentifier
        self.error = error
    }

    var plannerModelIdentifier: String? { modelIdentifier }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        onPlan?()
        if let error { throw error }
        return AgentPlan(summary: "Planned \(command).", requiresConfirmation: false, steps: [])
    }
}

private struct PlannerBlewUp: Error {}

// MARK: - Store pattern

struct AIEgressStoreTests {
    @Test
    func aRunSendingNPayloadsProducesExactlyNEntriesInOneRecord() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 5_000)

        try store.append(entry(sentAt: Date(timeIntervalSince1970: 5_001)), runID: runID, runStartedAt: startedAt)
        try store.append(entry(sentAt: Date(timeIntervalSince1970: 5_002)), runID: runID, runStartedAt: startedAt)
        try store.append(entry(sentAt: Date(timeIntervalSince1970: 5_003)), runID: runID, runStartedAt: startedAt)

        let records = try store.loadAll()
        #expect(records.count == 1)
        #expect(records.first?.runID == runID)
        #expect(records.first?.runStartedAt == startedAt)
        #expect(records.first?.entries.count == 3)
        #expect(records.first?.entries.map(\.sentAt.timeIntervalSince1970) == [5_001, 5_002, 5_003])
    }

    @Test
    func differentRunsKeepSeparateRecords() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let firstRun = UUID()
        let secondRun = UUID()

        try store.append(entry(), runID: firstRun, runStartedAt: Date(timeIntervalSince1970: 1))
        try store.append(entry(), runID: secondRun, runStartedAt: Date(timeIntervalSince1970: 2))

        let records = try store.loadAll()
        #expect(records.count == 2)
        #expect(Set(records.map(\.runID)) == [firstRun, secondRun])
    }

    @Test
    func theJoinReadFindsARunsRecordAndAnswersNilForAZeroEgressRun() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let startedAt = Date(timeIntervalSince1970: 9_000)
        try store.append(entry(), runID: UUID(), runStartedAt: startedAt)

        let joined = try store.record(forRunStartedAt: startedAt)
        #expect(joined?.entries.count == 1)

        // The honest empty record: a run that sent nothing has no record at all.
        #expect(try store.record(forRunStartedAt: Date(timeIntervalSince1970: 12_345)) == nil)
    }

    @Test
    func theLedgerFileOnDiskIsEncryptedWithTheSharedHeader() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        try store.append(entry(), runID: UUID(), runStartedAt: Date())

        let raw = try Data(contentsOf: store.fileURL)
        #expect(raw.prefix(LocalStorageEncryption.fileHeader.count) == LocalStorageEncryption.fileHeader)
        #expect(!String(decoding: raw, as: UTF8.self).contains("planner_prompt"))
    }

    @Test
    func legacyPlaintextLedgerMigratesToEncryptedOnLoad() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        let record = AIEgressRecord(runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 700), entries: [entry()])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([record]).write(to: store.fileURL, options: .atomic)

        let loaded = try store.loadAll()
        #expect(loaded == [record])

        let rawAfter = try Data(contentsOf: store.fileURL)
        #expect(rawAfter.prefix(LocalStorageEncryption.fileHeader.count) == LocalStorageEncryption.fileHeader)
    }

    @Test
    func aCorruptLedgerFileThrowsOnLoadInsteadOfDefaultingToEmpty() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        var corrupt = LocalStorageEncryption.fileHeader
        corrupt.append(Data(repeating: 0x00, count: 64))
        try corrupt.write(to: store.fileURL, options: .atomic)

        #expect(throws: (any Error).self) {
            _ = try store.loadAll()
        }
    }

    @Test
    func theCapEvictsOldestRunsFirst() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)

        // Overfill via a direct oversized write path: append maxItems + 2 runs would be slow at
        // 10k, so pin the capping rule at the same mechanism with a small, direct check of the
        // eviction order instead — oldest runStartedAt goes first.
        var records: [AIEgressRecord] = []
        for index in 0..<(AIEgressStore.maxItems + 2) {
            records.append(AIEgressRecord(
                runID: UUID(),
                runStartedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                entries: []
            ))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: store.fileURL, options: .atomic)

        try store.append(entry(), runID: UUID(), runStartedAt: Date(timeIntervalSince1970: 999_999))

        let survivors = try store.loadAll()
        #expect(survivors.count == AIEgressStore.maxItems)
        // The two oldest pre-existing runs and nothing else fell off.
        #expect(survivors.first?.runStartedAt.timeIntervalSince1970 == 3)
        #expect(survivors.last?.runStartedAt.timeIntervalSince1970 == 999_999)
    }

    @Test
    func theLocalDataWipeReachesTheLedgerFile() {
        let urls = LocalDataDeletionService.defaultStoreFileURLs()
        #expect(urls.contains(AIEgressStore().fileURL))
        // Ninth store: the wipe's enumeration grew with it.
        #expect(urls.count == 9)
    }
}

// MARK: - Recorder

struct AIEgressLedgerRecorderTests {
    @Test
    func recorderWritesUnderItsRunIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = makeStore(root: root)
        let runID = UUID()
        let startedAt = Date(timeIntervalSince1970: 42)
        let recorder = AIEgressLedgerRecorder(
            store: store,
            runID: runID,
            runStartedAt: startedAt,
            onWriteFailure: { _ in }
        )

        await recorder.record(entry())

        let records = try store.loadAll()
        #expect(records.count == 1)
        #expect(records.first?.runID == runID)
        #expect(records.first?.runStartedAt == startedAt)
    }

    @Test
    func aWriteFailureSurfacesThroughTheCallbackWithoutThrowing() async throws {
        // A directory where the ledger file should be makes every write fail.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedURL = root.appendingPathComponent("ai-egress-ledger.json")
        try FileManager.default.createDirectory(at: blockedURL, withIntermediateDirectories: true)
        let store = AIEgressStore(
            fileURL: blockedURL,
            encryption: LocalStorageEncryption(keyManager: FixedKeyManager())
        )

        let failure = CapturedFailure()
        let recorder = AIEgressLedgerRecorder(
            store: store,
            runID: UUID(),
            runStartedAt: Date(),
            onWriteFailure: { message in failure.message = message }
        )

        await recorder.record(entry())

        let message = await MainActor.run { failure.message }
        #expect(message?.contains("Data-Sent-to-AI") == true)
        // Accurate write-failure wording, never the load-banner's decrypt/decode copy.
        #expect(message?.contains("could not be decrypted or decoded") == false)
    }

    @MainActor
    private final class CapturedFailure {
        var message: String?
    }
}

// MARK: - The egress layer

@MainActor
struct EgressRecordingPlannerTests {
    @Test
    func aPlannerPromptIsRecordedBeforeDelegation() async throws {
        let spy = SpyEgressRecorder()
        let planner = ScriptedPlanner()
        planner.onPlan = { spy.noteDelegation() }
        let recording = EgressRecordingPlanner(
            wrapping: planner,
            provider: PlannerProvider(id: "openai", displayName: "OpenAI", retentionPosture: .retainedTemporarily) { _ in planner },
            recorder: spy
        )

        _ = try await recording.plan(command: "zip my downloads", priorTaskContext: nil)

        #expect(spy.events == ["recorded:planner_prompt", "delegated"])
    }

    @Test
    func aPromptThatLeavesAndThenFailsStillHasItsRecord() async {
        let spy = SpyEgressRecorder()
        let recording = EgressRecordingPlanner(
            wrapping: ScriptedPlanner(error: PlannerBlewUp()),
            provider: PlannerProvider(id: "openai", displayName: "OpenAI") { _ in ScriptedPlanner() },
            recorder: spy
        )

        await #expect(throws: PlannerBlewUp.self) {
            _ = try await recording.plan(command: "zip my downloads", priorTaskContext: nil)
        }
        #expect(spy.entries.count == 1)
    }

    @Test
    func theEntryCarriesProviderModelPostureSizeAndContextSources() async throws {
        let spy = SpyEgressRecorder()
        let sentAt = Date(timeIntervalSince1970: 77)
        let recording = EgressRecordingPlanner(
            wrapping: ScriptedPlanner(modelIdentifier: "gpt-5.5"),
            provider: PlannerProvider(id: "openai", displayName: "OpenAI", retentionPosture: .retainedTemporarily) { _ in ScriptedPlanner() },
            recorder: spy,
            now: { sentAt }
        )

        _ = try await recording.plan(command: "zip my downloads", priorTaskContext: nil)

        let recorded = try #require(spy.entries.first)
        #expect(recorded.kind == .plannerPrompt)
        #expect(recorded.sentAt == sentAt)
        #expect(recorded.providerID == "openai")
        #expect(recorded.providerName == "OpenAI")
        #expect(recorded.model == "gpt-5.5")
        #expect(recorded.retentionPosture == .retainedTemporarily)
        #expect(recorded.payloadSizeClass == .underOneKB)
        #expect(recorded.contextSources == ["command"])
        #expect(recorded.redactionSummary.isEmpty)
    }

    @Test
    func priorTaskContextJoinsTheContextSourcesAndTheSizeMeasurement() async throws {
        let spy = SpyEgressRecorder()
        let priorContext = PriorTaskContext(
            previousCommand: String(repeating: "z", count: 2_000),
            planSummary: "Did the thing.",
            steps: [],
            outcome: PriorTaskOutcome(status: .completed, summary: "Done."),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let recording = EgressRecordingPlanner(
            wrapping: ScriptedPlanner(),
            provider: PlannerProvider(id: "openai", displayName: "OpenAI") { _ in ScriptedPlanner() },
            recorder: spy
        )

        _ = try await recording.plan(command: "again please", priorTaskContext: priorContext)

        let recorded = try #require(spy.entries.first)
        #expect(recorded.contextSources == ["command", "prior task context"])
        // 2000+ bytes of prior-context text pushes the user-content measurement past 1 KB.
        #expect(recorded.payloadSizeClass == .underTenKB)
    }

    @Test
    func aPlannerWithNoStatedModelRecordsNilRatherThanInventingOne() async throws {
        let spy = SpyEgressRecorder()
        let recording = EgressRecordingPlanner(
            wrapping: ScriptedPlanner(modelIdentifier: nil),
            provider: PlannerProvider(id: "local", displayName: "Local") { _ in ScriptedPlanner() },
            recorder: spy
        )

        _ = try await recording.plan(command: "hello", priorTaskContext: nil)

        #expect(try #require(spy.entries.first).model == nil)
        #expect(try #require(spy.entries.first).retentionPosture == .unknown)
    }

    /// The registry cannot hand out an unwrapped planner on any of its three construction
    /// paths — and on the fallback path the entry names the provider that actually received the
    /// prompt, never the one the user asked for.
    @Test
    func everyRegistryConstructionPathRecordsThroughTheSuppliedRecorder() async throws {
        let spy = SpyEgressRecorder()
        var registry = PlannerProviderRegistry(
            defaultProvider: PlannerProvider(id: "primary", displayName: "Primary", retentionPosture: .retainedTemporarily) { _ in
                ScriptedPlanner(modelIdentifier: "primary-model")
            }
        )
        registry.register(
            PlannerProvider(id: "alternate", displayName: "Alternate", retentionPosture: .notRetained) { _ in
                ScriptedPlanner(modelIdentifier: "alternate-model")
            }
        )
        registry.register(
            PlannerProvider(id: "broken", displayName: "Broken") { _ in
                throw PlannerBlewUp()
            }
        )

        // Path 1: default selection.
        _ = try await registry
            .makePlanner(selection: nil, usageRecorder: NoopTaskUsageRecorder.shared, egressRecorder: spy)
            .planner.plan(command: "one")
        // Path 2: honored non-default selection.
        _ = try await registry
            .makePlanner(selection: "alternate", usageRecorder: NoopTaskUsageRecorder.shared, egressRecorder: spy)
            .planner.plan(command: "two")
        // Path 3: unavailable selection falling back to the default.
        _ = try await registry
            .makePlanner(selection: "broken", usageRecorder: NoopTaskUsageRecorder.shared, egressRecorder: spy)
            .planner.plan(command: "three")

        #expect(spy.entries.count == 3)
        #expect(spy.entries.map(\.providerID) == ["primary", "alternate", "primary"])
        #expect(spy.entries.map(\.model) == ["primary-model", "alternate-model", "primary-model"])
        #expect(spy.entries.map(\.retentionPosture) == [.retainedTemporarily, .notRetained, .retainedTemporarily])
    }

    @Test
    func payloadSizeClassBucketsAreStable() {
        #expect(AIEgressPayloadSizeClass(byteCount: 0) == .underOneKB)
        #expect(AIEgressPayloadSizeClass(byteCount: 1_023) == .underOneKB)
        #expect(AIEgressPayloadSizeClass(byteCount: 1_024) == .underTenKB)
        #expect(AIEgressPayloadSizeClass(byteCount: 10_239) == .underTenKB)
        #expect(AIEgressPayloadSizeClass(byteCount: 10_240) == .underHundredKB)
        #expect(AIEgressPayloadSizeClass(byteCount: 102_400) == .overHundredKB)
    }

    @Test
    func realPlannersAreConstructedOnlyInsideTheirProviderDescriptors() throws {
        // The "bug by construction" claim rests on the registry being the sole production path
        // to a network planner. This enumerates it: within Sources/, `OpenAIPlanner(` and
        // `CerebrasPlanner(` appear only in their own files (each in its provider descriptor),
        // so nothing can reach a network planner around the egress-recording wrap.
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourcesDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil)!

        var constructingFiles: Set<String> = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let codeLines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n")
                // Comment lines mention the constructors as prose (AgentViewModel narrates the
                // call the registry replaced); the claim under pin is about code.
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            if codeLines.contains(where: { $0.contains("OpenAIPlanner(") || $0.contains("CerebrasPlanner(") }) {
                constructingFiles.insert(file.lastPathComponent)
            }
        }
        #expect(constructingFiles == ["OpenAIPlanner.swift", "CerebrasPlanner.swift"])
    }
}

// MARK: - Bidirectional egress classification

/// The forcing function for SONNY-32's bidirectional rule, stated at
/// `AgentActionExecutor.dataEgressOperations`: an operation is in the set (or in
/// `stepLeavesDevice`'s switch) if and only if executing it can send anything off the device.
/// The switch below has no `default`, so a new `AgentOperation` case fails compilation right
/// here until someone classifies it — landing an operation without deciding is the one path
/// this removes.
@MainActor
struct EgressClassificationTests {
    private enum ExpectedEgress {
        /// Sends something off the device on every execution → must be in `dataEgressOperations`.
        case alwaysLeavesDevice
        /// Egress depends on saved content the step merely names → handled by
        /// `stepLeavesDevice`'s switch, never the static set.
        case dependsOnSavedContent
        /// Cannot send anything off the device → must be in neither.
        case neverLeavesDevice
    }

    private func expectedClassification(for operation: AgentOperation) -> ExpectedEgress {
        switch operation {
        case .openHackerNews, .fetchHNHeadlines, .webToMarkdown, .openAppSearchURL, .openURL,
             .playMedia, .invokeShortcut:
            return .alwaysLeavesDevice
        case .openWorkspace, .runRoutine:
            return .dependsOnSavedContent
        case .scanSelectLargestFiles, .createZip, .scanDocx, .convertDocxToPDF, .openApp,
             .getFinderSelection, .revealInFinder, .showPermissionReadiness, .saveRoutine,
             .createWorkspace, .editWorkspace, .openGeneratedArtifact, .createLocalDraft,
             .calculateUtility, .lookupClipboardHistory, .expandSnippet, .saveSnippet,
             .switchRunningApp, .lookupRecentArtifacts, .clarify, .unsupported:
            return .neverLeavesDevice
        // `.writeMarkdown` is a local file write. It reads "no" honestly only because the
        // solitary-step shape can no longer be silently promoted into the Hacker News preset
        // (SONNY-32's false-"no", fixed with SONNY-88) — the companion pins live in
        // `SolitaryWriteMarkdownTests`.
        case .writeMarkdown:
            return .neverLeavesDevice
        }
    }

    @Test
    func everyAgentOperationIsClassifiedAgainstTheBidirectionalRule() {
        for operation in AgentOperation.allCases {
            let inSet = AgentActionExecutor.dataEgressOperations.contains(operation)
            switch expectedClassification(for: operation) {
            case .alwaysLeavesDevice:
                #expect(inSet, "\(operation.rawValue) always egresses and must be in dataEgressOperations")
            case .dependsOnSavedContent, .neverLeavesDevice:
                #expect(!inSet, "\(operation.rawValue) must not be in dataEgressOperations")
            }
        }
        #expect(AgentActionExecutor.dataEgressOperations.count == 7)
    }
}

// MARK: - The solitary write_markdown fix (SONNY-32, absorbed by SONNY-88)

@MainActor
struct SolitaryWriteMarkdownTests {
    private final class CountingBrowserOpener: BrowserOpening {
        private(set) var openedURLs: [URL] = []

        func open(_ url: URL, using browser: MacApp?) async throws {
            openedURLs.append(url)
        }
    }

    private final class CountingHackerNewsFetcher: HackerNewsFetching {
        private(set) var fetchCount = 0

        func topHeadlines(limit: Int) async throws -> [HackerNewsHeadline] {
            fetchCount += 1
            return [HackerNewsHeadline(title: "Headline")]
        }
    }

    private func makeExecutor(root: URL, browserOpener: BrowserOpening, fetcher: HackerNewsFetching) -> AgentActionExecutor {
        AgentActionExecutor(
            whitelist: PathWhitelist(roots: [root]),
            browserOpener: browserOpener,
            hackerNewsFetcher: fetcher,
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json")),
            clipboardHistoryStore: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard.json")),
            snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
            recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("artifacts.json")),
            shortcutCatalog: EmptyShortcutCatalog(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(fileURL: root.appendingPathComponent("shortcuts.json"))
        )
    }

    private struct EmptyShortcutCatalog: ShortcutCatalogProviding {
        func shortcutNames() throws -> [String] { [] }
    }

    private func solitaryWriteMarkdownPlan(output: URL) -> AgentPlan {
        AgentPlan(
            summary: "Save to a Markdown file.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "write",
                    operation: .writeMarkdown,
                    description: "Write Markdown.",
                    outputPath: output.path,
                    count: 5
                )
            ]
        )
    }

    /// SONNY-32's concrete failure, pinned shut: the solitary plan used to disclose "Data leaves
    /// device: no", then open news.ycombinator.com and fetch headlines. Now it never prepares —
    /// rejected with an error naming the real problem — and nothing reaches the network.
    @Test
    func aSolitaryWriteMarkdownPlanIsRejectedAsIncompleteBeforeAnythingRuns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = CountingBrowserOpener()
        let fetcher = CountingHackerNewsFetcher()
        let executor = makeExecutor(root: root, browserOpener: browser, fetcher: fetcher)
        let plan = solitaryWriteMarkdownPlan(output: root.appendingPathComponent("note.md"))

        #expect(throws: AgentExecutionError.invalidPlan(
            "write_markdown needs a content source in the same plan — fetch_hn_headlines for the Hacker News digest, or web_to_markdown for a research note."
        )) {
            _ = try executor.prepare(plan: plan)
        }

        // The execute path is equally closed, and no network collaborator was ever touched.
        await #expect(throws: (any Error).self) {
            _ = try await executor.execute(plan: plan) { _, _ in }
        }
        #expect(browser.openedURLs.isEmpty)
        #expect(fetcher.fetchCount == 0)
    }

    /// The planner-instructed three-step shape is untouched: still the preset, still disclosing
    /// its egress through its two genuinely network-touching steps.
    @Test
    func theThreeStepHackerNewsShapeStillPreparesAsThePreset() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, browserOpener: CountingBrowserOpener(), fetcher: CountingHackerNewsFetcher())
        let plan = AgentPlan(
            summary: "Save Hacker News headlines.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "open", operation: .openHackerNews, description: "Open Hacker News."),
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 5),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: root.appendingPathComponent("hn.md").path, count: 5)
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        #expect(prepared.previews.first?.title == "Fetch Hacker News top 5")
    }

    @Test
    func aFetchPlusWritePairIsStillThePresetToo() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = makeExecutor(root: root, browserOpener: CountingBrowserOpener(), fetcher: CountingHackerNewsFetcher())
        let plan = AgentPlan(
            summary: "Save Hacker News headlines.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "fetch", operation: .fetchHNHeadlines, description: "Fetch headlines.", count: 3),
                AgentStep(id: "write", operation: .writeMarkdown, description: "Write Markdown.", outputPath: root.appendingPathComponent("hn.md").path, count: 3)
            ]
        )

        let prepared = try executor.prepare(plan: plan)
        #expect(prepared.previews.first?.title == "Fetch Hacker News top 3")
    }
}
