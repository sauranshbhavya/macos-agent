import Foundation
import Testing
@testable import MacAgent
import MacAgentCore

/// SONNY-85, the view-model half. The registry's own selection/fallback contract is pinned in
/// `PlannerProviderRegistryTests` (MacAgentCoreTests); what belongs here is the behavior only
/// `performStart` can exhibit: the selection actually decides who plans a dispatched task, a
/// fallback publishes `plannerFallbackNotice` for the widget strip, and the notice clears on
/// the next dispatch instead of outliving the run it describes.
///
/// Every command used here is free text the instant resolver has no pattern for, so each
/// dispatch reaches the planner branch; each stub planner answers with a clarify plan whose
/// question names the provider, so "who planned this" is observable without executing
/// anything.
@Suite
@MainActor
struct PlannerSelectionTests {
    @Test
    func honoredSelectionPlansWithTheSelectedProvider() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, plannerSelection: "alternate")

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.clarificationQuestion == "Planned by alternate — which penguin?")
        #expect(viewModel.plannerFallbackNotice == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test
    func absentSelectionPlansWithTheDefaultProviderWithoutANotice() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, plannerSelection: nil)

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.clarificationQuestion == "Planned by primary — which penguin?")
        #expect(viewModel.plannerFallbackNotice == nil)
    }

    @Test
    func unknownSelectionFallsBackToTheDefaultAndPublishesTheNotice() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, plannerSelection: "mystery")

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // The default provider planned it, and the swap was said out loud.
        #expect(viewModel.clarificationQuestion == "Planned by primary — which penguin?")
        #expect(viewModel.plannerFallbackNotice
            == "Sonny doesn't have a planner called “mystery”, so it used Primary instead. Available planners: primary, alternate.")
    }

    /// The notice describes one task's planning. A later dispatch whose selection is honored
    /// must clear it — a strip still claiming "Sonny used Primary instead" over a task the
    /// selected provider really planned would be the silent-swap bug inverted.
    @Test
    func theNextHonoredDispatchClearsTheFallbackNotice() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = try makeViewModel(root: root, plannerSelection: "mystery")

        viewModel.command = "tell me something delightful about penguins"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(viewModel.plannerFallbackNotice != nil)

        // Abandon the clarification pause the way the UI's dismiss does — `canSubmit`
        // (correctly) refuses a fresh dispatch while a clarification is still pending.
        viewModel.clarificationQuestion = nil
        viewModel.plannerSelection = "alternate"
        viewModel.command = "tell me something delightful about albatrosses"
        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.plannerFallbackNotice == nil)
        #expect(viewModel.clarificationQuestion == "Planned by alternate — which penguin?")
    }
}

// MARK: - Fixture

/// Two stub providers behind a real registry: enough to tell "selection honored" apart from
/// "selection fell back" by who answers.
@MainActor
private func makeStubRegistry() -> PlannerProviderRegistry {
    var registry = PlannerProviderRegistry(
        defaultProvider: PlannerProvider(id: "primary", displayName: "Primary") { _ in
            ClarifyingStubPlanner(marker: "primary")
        }
    )
    registry.register(
        PlannerProvider(id: "alternate", displayName: "Alternate") { _ in
            ClarifyingStubPlanner(marker: "alternate")
        }
    )
    return registry
}

@MainActor
private final class ClarifyingStubPlanner: Planning {
    let marker: String

    init(marker: String) {
        self.marker = marker
    }

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Ask before acting.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify",
                    operation: .clarify,
                    description: "Ask which one.",
                    question: "Planned by \(marker) — which penguin?"
                )
            ]
        )
    }
}

@MainActor
private func makeViewModel(root: URL, plannerSelection: String?) throws -> AgentViewModel {
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
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
            encryption: encryption
        ),
        approvedAppStore: ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
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
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        plannerProviderRegistry: makeStubRegistry(),
        plannerSelection: plannerSelection,
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
