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

    // MARK: - A live screen-control session, both routes into it (PR #237's F1)

    /// **Route one: a screen-control run with nothing to approve.** `dispatch` turns `isRunning`
    /// on, which drops the flag and minimises; the session then reports progress and `widgetState`
    /// becomes `.controlling`. Before the founders' decision of 2026-09-12 this left a live session
    /// behind a pill reading "Sonny is working on: …" — no app named, no action, no Stop — with the
    /// panel that carries all three hidden for the length of the session. The pill is the HUD now.
    @Test
    func aScreenControlRunMinimisesIntoTheControllingPillAndKeepsTheHudsWholeStatement() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        #expect(fixture.viewModel.isWidgetMinimised)

        fixture.viewModel.visionSessionProgress = VisionSessionProgress(
            appDisplayName: "Notes",
            iteration: 2,
            maximumIterations: 12,
            currentAction: "Clicking the New Note button"
        )

        // Still minimised — option B, deliberately: the session does not bring the widget back.
        #expect(fixture.viewModel.isWidgetMinimised)
        let pill = try #require(fixture.viewModel.runPillPresentation)
        #expect(pill.kind == .controlling, "a live session must not read as an ordinary run")
        #expect(pill.tint == .controlling)
        #expect(pill.glyph == "cursorarrow.rays")
        #expect(pill.words == "Sonny is controlling Notes")

        // Every clause of `WidgetControllingPanel`'s stated requirement, in the corner.
        let controlling = try #require(pill.controlling, "the controlling pill carries no controls")
        #expect(controlling.appDisplayName == "Notes")
        #expect(controlling.currentAction == "Clicking the New Note button")
        #expect(controlling.stepLine == "Step 2 of 12")
        // A control nobody knows about is not a control: the way out is spoken too. The controls
        // themselves are the shared `WidgetSessionPauseButton` and `WidgetSessionStopButton`, whose
        // words have one owner and whose wiring `RunPillControlsReceiveClicksTests` clicks.
        #expect(pill.accessibilityLabel.contains(ScreenControlSessionPresentation.stopLabel))
        #expect(pill.accessibilityLabel.contains(ScreenControlSessionPresentation.hotkeyLine))
    }

    // Route two — a session approved first, where approving re-enters the run and drops the minimise
    // flag again — is driven through the real approval door in
    // `VisionSessionRunTests.approvingAScreenControlSessionThroughTheRealDoorReMinimisesIntoTheControllingPill`.
    // It lived here until PR #237's delta review (N9) found that the version in this file set
    // `isRunning` by hand after parking a *clarification*, so it entered downstream of the approval
    // path its own doc said it covered.

    /// A parked question still outranks the session and still expands the widget — the controlling
    /// pill changes what a *progressing* session looks like and nothing about how a question is
    /// answered. Nothing is auto-approved.
    @Test
    func aQuestionParkedInsideASessionStillReadsAsNeedsYouAndStaysParked() throws {
        let fixture = try makePillFixture()
        defer { fixture.cleanUp() }
        fixture.viewModel.isRunning = true
        fixture.viewModel.visionSessionProgress = VisionSessionProgress(
            appDisplayName: "Notes",
            iteration: 3,
            maximumIterations: 12,
            currentAction: "Typing the line"
        )
        #expect(fixture.viewModel.runPillPresentation?.kind == .controlling)

        fixture.viewModel.visionSessionPause = VisionSessionPause(
            appDisplayName: "Notes",
            reason: .userPaused,
            iteration: 3
        )

        let pill = try #require(fixture.viewModel.runPillPresentation)
        #expect(pill.kind == .needsYou, "a parked continuation outranks a progress report, as it always has")
        #expect(pill.controlling == nil)
        #expect(fixture.viewModel.visionSessionPause != nil, "the pill answered nothing")
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
