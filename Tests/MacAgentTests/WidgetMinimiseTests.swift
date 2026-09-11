import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// SONNY-450. The widget minimises into the run pill when a run starts, stays minimised until the
/// user expands it, holds the outcome meanwhile, and comes back on its own when there is no pill
/// left to stand in for it. All of it is derived state on `AgentViewModel`, so it is held here
/// against the published properties the windows read, with no window in the process.
@Suite(.serialized)
@MainActor
struct WidgetMinimiseTests {
    @Test
    func aRunStartingMinimisesTheWidgetIntoARunningPill() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        #expect(!fixture.viewModel.isWidgetMinimised)
        #expect(fixture.viewModel.runPillPresentation == nil)

        fixture.viewModel.isRunning = true

        #expect(fixture.viewModel.isWidgetMinimised)
        let pill = try #require(fixture.viewModel.runPillPresentation)
        #expect(pill.kind == .running)
    }

    @Test
    func theOutcomeOfAMinimisedRunHoldsUntilTheWidgetIsExpanded() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        fixture.viewModel.isRunning = false
        fixture.viewModel.finalSummary = "Zipped 3 files."

        #expect(fixture.viewModel.isWidgetMinimised)
        #expect(fixture.viewModel.runPillPresentation?.kind == .done)
        #expect(fixture.viewModel.outcomeHolds, "a done pill must never point at a result that has cleared itself")

        let requestsBefore = fixture.viewModel.widgetPresentationRequest
        fixture.viewModel.expandWidgetFromPill()

        #expect(!fixture.viewModel.isWidgetMinimised)
        #expect(!fixture.viewModel.outcomeHolds)
        #expect(fixture.viewModel.widgetPresentationRequest == requestsBefore + 1)
        // The outcome itself is untouched by expanding: the widget shows it and counts down from there.
        #expect(fixture.viewModel.finalSummary == "Zipped 3 files.")
    }

    @Test
    func aSummonFromAnywhereExpandsTheWidget() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        #expect(fixture.viewModel.isWidgetMinimised)

        // The hotkey, the status menu and a Command Center row all bump this counter.
        fixture.viewModel.widgetPresentationRequest += 1

        #expect(!fixture.viewModel.isWidgetMinimised)
        #expect(fixture.viewModel.widgetWasExpandedForThisRun)
    }

    @Test
    func aParkedClarificationReadsAsNeedsYouOnThePill() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        fixture.viewModel.isRunning = false
        fixture.viewModel.clarificationQuestion = "Which file did you mean?"

        #expect(fixture.viewModel.isWidgetMinimised)
        #expect(fixture.viewModel.runPillPresentation?.kind == .needsYou)
        // The attention panel reads the same state: nothing is answered by the pill.
        #expect(fixture.viewModel.clarificationQuestion == "Which file did you mean?")
    }

    /// A scheduled routine's outcome goes to its notice and never to the widget's result panel, so
    /// its run drains back to idle with no pill to show; the widget comes back on its own rather
    /// than leaving the user with neither surface. The flag stays down — nobody expanded — and
    /// the derived state is what answers.
    @Test
    func aRunWhoseStateDrainsToIdleBringsTheWidgetBackOnItsOwn() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        #expect(fixture.viewModel.isWidgetMinimised)

        fixture.viewModel.isRunning = false

        #expect(fixture.viewModel.runPillPresentation == nil)
        #expect(!fixture.viewModel.isWidgetMinimised)
        #expect(!fixture.viewModel.widgetWasExpandedForThisRun)
    }

    @Test
    func theNextRunMinimisesAgainAfterAnExpansion() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        fixture.viewModel.expandWidgetFromPill()
        fixture.viewModel.isRunning = false
        #expect(!fixture.viewModel.isWidgetMinimised)

        fixture.viewModel.isRunning = true

        #expect(fixture.viewModel.isWidgetMinimised)
    }

    /// SONNY-121's hold is untouched: a notified outcome holds with or without a pill.
    @Test
    func aNotifiedOutcomeStillHoldsOnItsOwn() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.finalSummary = "Done."
        #expect(!fixture.viewModel.isWidgetMinimised)
        #expect(!fixture.viewModel.outcomeHolds)

        fixture.viewModel.markOutcomeAsNotified()

        #expect(fixture.viewModel.outcomeHolds)
    }
}

private struct PillFixture {
    let viewModel: AgentViewModel
    let root: URL

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makePillFixture() throws -> PillFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WidgetMinimiseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encryption = LocalStorageEncryption(keyManager: PillFixtureKeyManager())
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: UnreachableLocalStores.routines(),
        workspaceStore: UnreachableLocalStores.workspaces(),
        snippetStore: UnreachableLocalStores.snippets(),
        recentArtifactStore: UnreachableLocalStores.recentArtifacts(),
        finderRevealer: { _ in },
        shortcutRunHistoryStore: UnreachableLocalStores.shortcutRunHistory(),
        taskHistoryStore: UnreachableLocalStores.taskHistory(),
        taskPlanDetailStore: UnreachableLocalStores.taskPlanDetails(),
        visionSessionJournalStore: UnreachableLocalStores.visionSessionJournal(),
        clipboardHistorySettingsStore: clipboardSettingsStore,
        approvedAppStore: UnreachableLocalStores.approvedApps(),
        outputLocationStore: UnreachableLocalStores.outputLocations(),
        resumableTaskStore: UnreachableLocalStores.resumableTasks(),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            store: UnreachableLocalStores.clipboardHistory(),
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        backendClient: makeHermeticBackendClient(),
        userDefaults: UserDefaults(suiteName: "WidgetMinimiseTests-\(UUID().uuidString)") ?? .standard
    )
    return PillFixture(viewModel: viewModel, root: root)
}

private struct PillFixtureKeyManager: LocalStorageKeyManaging {
    func keyData() throws -> Data {
        Data(repeating: 0x5E, count: 32)
    }
}
