import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacAgent
import MacAgentCore

@Suite(.serialized)
@MainActor
struct ProductShellTests {
    @Test
    func appSurfacesRetainTheSameInjectedViewModelReference() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let coordinator = AppWindowCoordinator(viewModel: viewModel)
        let widget = FloatingWidgetView(viewModel: viewModel)
        let commandCenter = CommandCenterView(viewModel: viewModel)

        #expect(coordinator.viewModel === viewModel)
        #expect(widget.viewModel === viewModel)
        #expect(commandCenter.viewModel === viewModel)
        #expect(widget.viewModel === commandCenter.viewModel)
    }

    @Test
    func commandCenterDestinationsKeepTheLockedSidebarOrder() {
        // Settings is no longer a sidebar destination (2026-07-18) — it moved to its own dialog,
        // opened from the bottom account row. See `SettingsDialogView`.
        #expect(
            CommandCenterDestination.allCases == [
                .tasks,
                .insights,
                .routines,
                .workspaces
            ]
        )
    }

    @Test
    func taskBadgeCountsOnlyAnActiveOrApprovalPendingTask() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        #expect(viewModel.activeTaskCount == 0)

        viewModel.isRunning = true
        #expect(viewModel.activeTaskCount == 1)

        viewModel.isRunning = false
        #expect(viewModel.activeTaskCount == 0)
    }

    @Test
    func pointerCursorPreferenceIsSharedInProcessAcrossSurfaces() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.userDefaultsSuiteName) }
        let viewModel = fixture.viewModel
        let widget = FloatingWidgetView(viewModel: viewModel)
        let commandCenter = CommandCenterView(viewModel: viewModel)

        #expect(viewModel.usePointerCursors)

        viewModel.usePointerCursors = false
        #expect(widget.viewModel.usePointerCursors == false)
        #expect(commandCenter.viewModel.usePointerCursors == false)

        viewModel.usePointerCursors = true
        #expect(widget.viewModel.usePointerCursors)
        #expect(commandCenter.viewModel.usePointerCursors)
    }

    @Test
    func pointerCursorPreferencePersistsThroughInjectedUserDefaults() throws {
        let suiteName = "ProductShellPointerCursors-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: firstLaunch.root) }
        #expect(firstLaunch.viewModel.usePointerCursors)

        firstLaunch.viewModel.usePointerCursors = false

        let secondLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: secondLaunch.root) }
        #expect(secondLaunch.viewModel.usePointerCursors == false)

        secondLaunch.viewModel.usePointerCursors = true

        let thirdLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: thirdLaunch.root) }
        #expect(thirdLaunch.viewModel.usePointerCursors)
    }

    @Test
    func displayFullNamesPreferenceIsSharedInProcessAcrossSurfaces() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.userDefaultsSuiteName) }
        let viewModel = fixture.viewModel
        let widget = FloatingWidgetView(viewModel: viewModel)
        let commandCenter = CommandCenterView(viewModel: viewModel)

        #expect(viewModel.displayFullNames == false)

        viewModel.displayFullNames = true
        #expect(widget.viewModel.displayFullNames)
        #expect(commandCenter.viewModel.displayFullNames)

        viewModel.displayFullNames = false
        #expect(widget.viewModel.displayFullNames == false)
        #expect(commandCenter.viewModel.displayFullNames == false)
    }

    @Test
    func displayFullNamesPreferencePersistsThroughInjectedUserDefaults() throws {
        let suiteName = "ProductShellDisplayFullNames-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let firstLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: firstLaunch.root) }
        #expect(firstLaunch.viewModel.displayFullNames == false)

        firstLaunch.viewModel.displayFullNames = true

        let secondLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: secondLaunch.root) }
        #expect(secondLaunch.viewModel.displayFullNames)

        secondLaunch.viewModel.displayFullNames = false

        let thirdLaunch = try makeProductShellFixture(
            userDefaults: userDefaults,
            userDefaultsSuiteName: suiteName
        )
        defer { try? FileManager.default.removeItem(at: thirdLaunch.root) }
        #expect(thirdLaunch.viewModel.displayFullNames == false)
    }

    @Test
    func primaryWindowActivationReturnsToAccessoryOnlyAfterTheLastWindowCloses() {
        let application = ProductShellActivationRecorder()
        let manager = PrimaryWindowActivationManager(application: application)
        let firstWindow = NSObject()
        let secondWindow = NSObject()

        manager.presentWindow(id: ObjectIdentifier(firstWindow))
        manager.presentWindow(id: ObjectIdentifier(secondWindow))
        #expect(application.regularActivationCount == 2)
        #expect(application.accessoryActivationCount == 0)

        manager.closeWindow(id: ObjectIdentifier(firstWindow))
        #expect(application.accessoryActivationCount == 0)

        manager.closeWindow(id: ObjectIdentifier(secondWindow))
        #expect(application.accessoryActivationCount == 1)
    }

    @Test(.enabled(if: ProductShellSmokeConfiguration.isEnabled))
    func coordinatorCreatesReusableCommandCenterWindowAndChangesActivationPolicy() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        defer { _ = application.setActivationPolicy(originalActivationPolicy) }
        let viewModel = fixture.viewModel
        let coordinator = AppWindowCoordinator(viewModel: viewModel)

        coordinator.showCommandCenter()
        let commandCenterWindow = try #require(coordinator.commandCenterWindow)
        #expect(commandCenterWindow.title == "Sonny")
        #expect(commandCenterWindow.minSize == NSSize(width: 900, height: 620))
        #expect(commandCenterWindow.styleMask.contains(.resizable))
        #expect(commandCenterWindow.isVisible)
        #expect(application.activationPolicy() == .regular)

        coordinator.showCommandCenter()
        #expect(coordinator.commandCenterWindow === commandCenterWindow)

        if let snapshotPath = ProcessInfo.processInfo.environment["SONNY_COMMAND_CENTER_SNAPSHOT"] {
            try render(window: commandCenterWindow, to: URL(fileURLWithPath: snapshotPath))
        }

        commandCenterWindow.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(application.activationPolicy() == .accessory)
    }

    @Test
    func sharedViewModelRunsAnInstantCommandThroughTheExistingPipeline() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "= 1 + 1"

        viewModel.start()
        while viewModel.isRunning {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.plan?.steps.first?.operation == .calculateUtility)
        #expect(viewModel.finalSummary.contains("2"))
        #expect(viewModel.taskUsageSummary.requestCount == 0)
        #expect(viewModel.activeTaskCount == 0)

        if let snapshotPath = ProcessInfo.processInfo.environment["SONNY_SHARED_TASK_SNAPSHOT"] {
            let coordinator = AppWindowCoordinator(viewModel: viewModel)
            coordinator.showCommandCenter()
            let window = try #require(coordinator.commandCenterWindow)
            try render(window: window, to: URL(fileURLWithPath: snapshotPath))
            window.close()
        }
    }

    @Test
    func completedTaskIsRecordedInPersistentHistory() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "= 1 + 1"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(records.count == 1)
        #expect(record.command == "= 1 + 1")
        #expect(record.outcomeStatus == .completed)
        #expect(record.completedAt >= record.startedAt)
        #expect(record.workspaceName == nil)
        #expect(viewModel.taskHistoryRecords.map(\.command) == ["= 1 + 1"])
    }

    @Test
    func failedTaskIsRecordedInPersistentHistory() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "calc apples"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(records.count == 1)
        #expect(record.command == "calc apples")
        #expect(record.outcomeStatus == .failed)
        #expect(record.completedAt >= record.startedAt)
        #expect(record.workspaceName == nil)
        #expect(viewModel.taskHistoryRecords.map(\.command) == ["calc apples"])
        #expect(viewModel.errorMessage?.contains("Could not calculate that expression") == true)
    }

    @Test
    func canceledApprovalTaskIsRecordedInPersistentHistory() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "snippet save ;history-test = Hello"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.approvalRequest != nil)

        viewModel.cancelCurrentRun()

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(records.count == 1)
        #expect(record.command == "snippet save ;history-test = Hello")
        #expect(record.outcomeStatus == .canceled)
        #expect(record.completedAt >= record.startedAt)
        #expect(record.workspaceName == nil)
        #expect(viewModel.taskHistoryRecords.map(\.command) == ["snippet save ;history-test = Hello"])
        #expect(viewModel.finalSummary == "Approval canceled. No action was taken.")
    }

    @Test
    func directWorkspaceDispatchTagsTheCompletedTaskRecord() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: [], urls: []))
        viewModel.refreshSavedItems()

        // Deliberately not `viewModel.openWorkspaceWidget(_:)` — that convenience method appends a
        // trailing period to the generated command, which defeats InstantCommandResolver's exact
        // suffix-stripping match and falls through to the real (unconfigured-in-tests) planner, a
        // pre-existing quirk unrelated to this checkpoint. Using the same plain command string
        // QuickDispatchTests already proves resolves instantly avoids relying on that code path.
        viewModel.command = "open research workspace"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.workspaceName == "Research")
    }

    @Test
    func routineThatOpensAWorkspaceTagsTheRecordEvenThoughTheCommandNeverMentionsIt() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: [], urls: []))
        let routine = StoredRoutine(
            name: "Morning Setup",
            steps: [
                AgentStep(
                    id: "open-workspace",
                    operation: .openWorkspace,
                    description: "Open workspace",
                    workspaceName: "Research"
                )
            ]
        )
        try fixture.routineStore.save(routine)
        viewModel.refreshSavedItems()

        viewModel.command = "run morning setup"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.approvalRequest != nil)

        viewModel.cancelCurrentRun()

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        #expect(record.outcomeStatus == .canceled)
        // The command text never mentions "Research" — this can only be tagged via the
        // routine-nested resolution reading the routine's own saved steps, not free-text matching.
        #expect(record.workspaceName == "Research")
    }

    // MARK: - Regression coverage for a separate, pre-existing bug surfaced while testing the
    // above (unrelated to task-to-workspace tagging itself): runRoutineWidget/openWorkspaceWidget
    // built commands ending in a trailing period, which defeated InstantCommandResolver's exact
    // suffix-stripping match and silently fell through to the real network planner instead of
    // resolving instantly and locally.

    @Test
    func runRoutineWidgetCommandInstantResolvesWithoutTrailingPunctuationBreakingTheMatch() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let routine = StoredRoutine(
            name: "Morning Setup",
            steps: [AgentStep(id: "open", operation: .openApp, description: "", appName: "Safari")]
        )
        try fixture.routineStore.save(routine)
        viewModel.refreshSavedItems()

        viewModel.runRoutineWidget(routine)
        try await waitForViewModelToBecomeIdle(viewModel)

        // run_routine's default tier (2) requires approval — reaching that state, rather than a
        // planner-missing-key failure, proves the command resolved instantly and locally, with no
        // network call attempted.
        #expect(viewModel.approvalRequest != nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test
    func openWorkspaceWidgetCommandInstantResolvesWithoutTrailingPunctuationBreakingTheMatch() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let workspace = StoredWorkspace(name: "Research", apps: [], urls: [])
        try fixture.workspaceStore.save(workspace)
        viewModel.refreshSavedItems()

        viewModel.openWorkspaceWidget(workspace)
        try await waitForViewModelToBecomeIdle(viewModel)

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        // open_workspace's default tier (1) auto-runs — completing successfully, rather than a
        // planner-missing-key failure, proves the command resolved instantly and locally.
        #expect(record.outcomeStatus == .completed)
        #expect(viewModel.errorMessage == nil)
    }

    @Test
    func activityPresentationHidesInternalOperationAndPhaseNames() {
        let step = AgentStep(
            id: "calculate",
            operation: .calculateUtility,
            description: ""
        )
        let localPlanEvent = AgentEvent(phase: .plan, message: "Resolved command locally")
        let riskEvent = AgentEvent(
            phase: .risk,
            message: "risk.assessed: Tier 2 (Local modification); approval: Lightweight confirmation"
        )

        #expect(AgentActivityPresentation.planStepTitle(step) == "Calculate")
        #expect(AgentActivityPresentation.planStepTitle(step) != AgentOperation.calculateUtility.rawValue)
        #expect(AgentActivityPresentation.eventTitle(localPlanEvent) == "Understanding")
        #expect(AgentActivityPresentation.eventTitle(localPlanEvent) != AgentPhase.plan.rawValue)
        #expect(AgentActivityPresentation.eventMessage(localPlanEvent) == "Understood this command on your Mac")
        #expect(AgentActivityPresentation.eventMessage(riskEvent) == "Safety check complete. Waiting for your approval.")
        #expect(AgentActivityPresentation.previewSideEffect("Write: /tmp/report.md") == "Creates /tmp/report.md")
    }

    @Test
    func savedCollectionPresentationsUseOnlyRealRoutineAndWorkspaceData() {
        let routine = StoredRoutine(
            name: "Morning planning",
            steps: [
                AgentStep(id: "browser", operation: .openApp, description: "", appName: "Safari"),
                AgentStep(id: "draft", operation: .createLocalDraft, description: ""),
                AgentStep(id: "reveal", operation: .revealInFinder, description: "")
            ]
        )
        let workspace = StoredWorkspace(
            name: "Research",
            apps: ["Safari", "Notes"],
            urls: ["https://www.example.com/reference"]
        )

        let routinePresentation = RoutineRowPresentation(routine: routine)
        #expect(routinePresentation.name == "Morning planning")
        #expect(routinePresentation.detailText == "Open Safari · Create draft · +1 more")

        let taskHistoryRecords = [
            CompletedTaskRecord(command: "a", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Research"),
            CompletedTaskRecord(command: "b", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Research"),
            CompletedTaskRecord(command: "c", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .failed, workspaceName: "Research"),
            CompletedTaskRecord(command: "d", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Other")
        ]

        let workspacePresentation = WorkspaceCardPresentation(
            workspace: workspace,
            taskHistoryRecords: taskHistoryRecords,
            iconResolver: NeverResolvingWorkspaceAppIconResolver()
        )
        #expect(workspacePresentation.name == "Research")
        #expect(workspacePresentation.effectiveTeamType == .solo)
        #expect(workspacePresentation.isDefaultTeamType == true)
        // Only the 2 .completed records tagged "Research" count — the .failed one and the one
        // tagged "Other" are both excluded.
        #expect(workspacePresentation.taskCount == 2)
        #expect(workspacePresentation.taskCountText == "2 tasks")
        #expect(workspacePresentation.appIcons.map(\.appName) == ["Safari", "Notes"])
        #expect(workspacePresentation.urlsText == "example.com")

        let teamWorkspace = StoredWorkspace(name: "Client Work", apps: [], urls: [], teamType: .team)
        let teamPresentation = WorkspaceCardPresentation(
            workspace: teamWorkspace,
            taskHistoryRecords: taskHistoryRecords,
            iconResolver: NeverResolvingWorkspaceAppIconResolver()
        )
        #expect(teamPresentation.effectiveTeamType == .team)
        #expect(teamPresentation.isDefaultTeamType == false)
        #expect(teamPresentation.appIcons.isEmpty)
        #expect(teamPresentation.taskCount == 0)
        #expect(teamPresentation.taskCountText == "0 tasks")
    }

    @Test
    func savedItemRefreshImmediatelyPublishesCreatesAndUpdatesToTheSharedViewModel() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)
        let commandCenter = CommandCenterView(viewModel: fixture.viewModel)

        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning planning",
                steps: [AgentStep(id: "browser", operation: .openApp, description: "", appName: "Safari")]
            )
        )
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://example.com"])
        )
        fixture.viewModel.refreshSavedItems()

        #expect(widget.viewModel === commandCenter.viewModel)
        #expect(widget.viewModel.savedRoutines.map(\.name) == ["Morning planning"])
        #expect(commandCenter.viewModel.savedWorkspaces.map(\.name) == ["Research"])

        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning planning",
                steps: [
                    AgentStep(id: "browser", operation: .openApp, description: "", appName: "Safari"),
                    AgentStep(id: "notes", operation: .openApp, description: "", appName: "Notes")
                ]
            )
        )
        try fixture.workspaceStore.save(
            StoredWorkspace(
                name: "Research",
                apps: ["Safari", "Notes"],
                urls: ["https://example.com"]
            )
        )
        fixture.viewModel.refreshSavedItems()

        #expect(widget.viewModel.savedRoutines.count == 1)
        #expect(widget.viewModel.savedRoutines.first?.steps.count == 2)
        #expect(commandCenter.viewModel.savedWorkspaces.count == 1)
        #expect(commandCenter.viewModel.savedWorkspaces.first?.apps == ["Safari", "Notes"])
    }

}

@MainActor
private func render(window: NSWindow, to fileURL: URL) throws {
    guard let contentView = window.contentView else {
        throw ProductShellSnapshotError.missingContentView
    }

    window.orderFrontRegardless()
    window.display()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))
    contentView.needsLayout = true
    contentView.needsDisplay = true
    contentView.layoutSubtreeIfNeeded()
    contentView.display()
    guard let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
        throw ProductShellSnapshotError.couldNotCreateBitmap
    }
    contentView.cacheDisplay(in: contentView.bounds, to: representation)
    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw ProductShellSnapshotError.couldNotEncodePNG
    }
    try png.write(to: fileURL, options: .atomic)
}

private enum ProductShellSnapshotError: Error {
    case missingContentView
    case couldNotCreateBitmap
    case couldNotEncodePNG
}

private enum ProductShellSmokeConfiguration {
    static let isEnabled = ProcessInfo.processInfo.environment["SONNY_UI_SMOKE"] == "1"
}

@MainActor
private final class ProductShellActivationRecorder: ApplicationActivationApplying {
    private(set) var regularActivationCount = 0
    private(set) var accessoryActivationCount = 0

    func activateAsRegularApplication() {
        regularActivationCount += 1
    }

    func returnToAccessoryApplication() {
        accessoryActivationCount += 1
    }
}

@MainActor
private func makeProductShellFixture() throws -> (
    viewModel: AgentViewModel,
    root: URL,
    routineStore: RoutineStore,
    workspaceStore: WorkspaceStore,
    taskHistoryStore: TaskHistoryStore,
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String
) {
    let userDefaultsSuiteName = "ProductShellTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
    return try makeProductShellFixture(userDefaults: userDefaults, userDefaultsSuiteName: userDefaultsSuiteName)
}

@MainActor
private func makeProductShellFixture(
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String? = nil
) throws -> (
    viewModel: AgentViewModel,
    root: URL,
    routineStore: RoutineStore,
    workspaceStore: WorkspaceStore,
    taskHistoryStore: TaskHistoryStore,
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String
) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProductShellTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encryption = LocalStorageEncryption(
        keyManager: ProductShellFixedKeyManager(bytes: Data(repeating: 0x42, count: 32))
    )
    let clipboardSettingsStore = ClipboardHistorySettingsStore(
        fileURL: root.appendingPathComponent("clipboard-history-settings.json"),
        encryption: encryption
    )

    let routineStore = RoutineStore(
        fileURL: root.appendingPathComponent("routines.json"),
        encryption: encryption
    )
    let workspaceStore = WorkspaceStore(
        fileURL: root.appendingPathComponent("workspaces.json"),
        encryption: encryption
    )
    let taskHistoryStore = TaskHistoryStore(
        fileURL: root.appendingPathComponent("task-history.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: routineStore,
        workspaceStore: workspaceStore,
        snippetStore: SnippetStore(
            fileURL: root.appendingPathComponent("snippets.json"),
            encryption: encryption
        ),
        recentArtifactStore: RecentArtifactStore(
            fileURL: root.appendingPathComponent("recent-artifacts.json"),
            encryption: encryption
        ),
        shortcutCatalog: ProductShellEmptyShortcutCatalog(),
        shortcutRunHistoryStore: ShortcutRunHistoryStore(
            fileURL: root.appendingPathComponent("shortcuts-run-history.json"),
            encryption: encryption
        ),
        taskHistoryStore: taskHistoryStore,
        clipboardHistorySettingsStore: clipboardSettingsStore,
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: ProductShellPasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
    let suiteName = userDefaultsSuiteName ?? "ProductShellInjected-\(UUID().uuidString)"
    return (viewModel, root, routineStore, workspaceStore, taskHistoryStore, userDefaults, suiteName)
}

@MainActor
private func waitForViewModelToBecomeIdle(
    _ viewModel: AgentViewModel,
    timeout: TimeInterval = 2
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not become idle before timeout.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private struct ProductShellFixedKeyManager: LocalStorageKeyManaging {
    let bytes: Data

    func keyData() throws -> Data {
        bytes
    }
}

private struct ProductShellEmptyShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

/// Always returns `nil`, so tests never depend on real installed apps or live `NSWorkspace`/
/// LaunchServices calls — deterministic across every machine and CI runner.
@MainActor
private struct NeverResolvingWorkspaceAppIconResolver: WorkspaceAppIconResolving {
    func icon(forAppName appName: String) -> NSImage? {
        nil
    }
}

@MainActor
private final class ProductShellPasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}
