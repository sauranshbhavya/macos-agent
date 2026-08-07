import Foundation
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The workspace detail sheet — B6, the surface that makes a boundary something the user can look
/// at.
///
/// Everything assertable here is a **pure function of stored state**, following the
/// `WorkspaceCardPresentation` / `AgentActivityPresentation` precedent, because this repo has no
/// SwiftUI view-inspection harness: anything composed inside a `body` cannot be asserted without
/// re-implementing the view in the test, which is the tautology this project's established standard
/// refuses. What is genuinely view-level — that the sheet *renders* these values, and that its fills
/// and type are System A — is a recorded limitation with a manual item on the ticket, not a fake
/// test.
@Suite
@MainActor
struct WorkspaceDetailSheetTests {
    /// Every field carries a **distinct** fixture value, so no assertion can pass by reading the
    /// wrong one. Three lists whose entries could be confused for each other is exactly how a
    /// section renders the wrong dimension and a test still goes green.
    private func populatedWorkspace() -> StoredWorkspace {
        StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari", "Microsoft Word"],
            urls: ["https://github.com/acme", "https://docs.example.org/handbook"],
            teamType: .team,
            fileLocations: ["~/Documents/ClientAlpha", "~/Desktop/Alpha Drafts"]
        )
    }

    private func taskRecords() -> [CompletedTaskRecord] {
        [
            CompletedTaskRecord(command: "a", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Client Alpha"),
            CompletedTaskRecord(command: "b", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Client Alpha"),
            // Excluded: failed here, and completed somewhere else.
            CompletedTaskRecord(command: "c", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .failed, workspaceName: "Client Alpha"),
            CompletedTaskRecord(command: "d", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Research")
        ]
    }

    // MARK: - Rendering the whole boundary

    /// The acceptance criterion: every stored entry of all three dimensions is present, in stored
    /// order, and each dimension's entries land in *its own* section.
    @Test
    func theSheetRendersEveryStoredEntryOfAllThreeDimensions() {
        let presentation = WorkspaceDetailPresentation(
            workspace: populatedWorkspace(),
            taskHistoryRecords: taskRecords()
        )

        #expect(presentation.name == "Client Alpha")
        #expect(presentation.avatarInitial == "C")
        #expect(presentation.effectiveTeamType == .team)
        #expect(presentation.isDefaultTeamType == false)
        #expect(presentation.teamTypeText == "Team workspace")
        #expect(presentation.taskCount == 2)
        #expect(presentation.taskCountText == "2 tasks")

        #expect(presentation.apps.title == "Apps")
        #expect(presentation.apps.entries.map(\.value) == ["Safari", "Microsoft Word"])
        #expect(presentation.urls.title == "URLs")
        // Stored verbatim, not shortened to a host the way the card shortens it: this is the one
        // place the whole boundary is meant to be checkable against what a consent prompt named.
        #expect(presentation.urls.entries.map(\.value) == ["https://github.com/acme", "https://docs.example.org/handbook"])
        #expect(presentation.fileLocations.title == "File locations")
        #expect(presentation.fileLocations.entries.map(\.value) == ["~/Documents/ClientAlpha", "~/Desktop/Alpha Drafts"])

        // Fixed order, matching the order `edit_workspace`'s consent prompts report a mixed edit in.
        #expect(presentation.sections.map(\.title) == ["Apps", "URLs", "File locations"])
        #expect(presentation.sections.allSatisfy { $0.isRestricted })
        #expect(presentation.sections.allSatisfy { $0.notRestrictedText == nil })
        // Nothing to explain when every dimension is configured.
        #expect(presentation.unrestrictedFootnote == nil)
    }

    /// A file-locations list that was never written reads exactly like one that was emptied —
    /// `effectiveFileLocations`, not the raw Optional. The nil/`[]` distinction is meaningful only
    /// to `WorkspaceStore.save`.
    @Test
    func aWorkspaceWithNoFileLocationsKeyReadsTheSameAsOneExplicitlyEmptied() {
        let never = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        let emptied = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [])

        let neverPresentation = WorkspaceDetailPresentation(workspace: never, taskHistoryRecords: [])
        let emptiedPresentation = WorkspaceDetailPresentation(workspace: emptied, taskHistoryRecords: [])

        #expect(never.fileLocations == nil)
        #expect(emptied.fileLocations == [])
        #expect(neverPresentation == emptiedPresentation)
    }

    // MARK: - The empty case, which is the one that matters

    /// **An empty list must read as "not restricted", never as an empty box.** `WorkspaceScope`
    /// treats an empty list as `.unconstrained` — neither permission nor prohibition — and a user
    /// who reads an empty Apps list as "no apps are allowed here" has learned the opposite of the
    /// truth. Asserted on the literal strings.
    @Test
    func everyEmptyDimensionRendersNotRestrictedWordingRatherThanAnEmptyBox() {
        let bare = StoredWorkspace(name: "Client Alpha", apps: [], urls: [], fileLocations: [])

        let presentation = WorkspaceDetailPresentation(workspace: bare, taskHistoryRecords: [])

        #expect(presentation.apps.notRestrictedText
            == "Not restricted — this workspace does not limit which apps a task can use.")
        #expect(presentation.urls.notRestrictedText
            == "Not restricted — this workspace does not limit which sites a task can open.")
        #expect(presentation.fileLocations.notRestrictedText
            == "Not restricted — this workspace does not limit which folders a task can touch.")

        // Each one says it, and each one says it about its own dimension — three copies of one
        // sentence would pass a `contains` check while telling the user nothing kind-specific.
        #expect(presentation.sections.allSatisfy { $0.notRestrictedText?.hasPrefix("Not restricted — ") == true })
        #expect(Set(presentation.sections.compactMap(\.notRestrictedText)).count == 3)
        #expect(presentation.sections.allSatisfy { $0.entries.isEmpty })
        #expect(presentation.sections.allSatisfy { !$0.isRestricted })
    }

    /// The footnote appears exactly when there is an unrestricted dimension to explain, and says
    /// what `.unconstrained` actually means — neither limited nor specially allowed.
    @Test
    func theUnrestrictedFootnoteAppearsOnlyWhenADimensionIsUnrestricted() {
        let partial = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [])
        let full = populatedWorkspace()

        let partialPresentation = WorkspaceDetailPresentation(workspace: partial, taskHistoryRecords: [])
        let fullPresentation = WorkspaceDetailPresentation(workspace: full, taskHistoryRecords: [])

        #expect(partialPresentation.unrestrictedFootnote
            == "An unrestricted list means this workspace says nothing about that kind of thing — Sonny neither "
                + "limits it here nor treats it as specially allowed.")
        #expect(fullPresentation.unrestrictedFootnote == nil)
        // The restricted dimension keeps its entries; only the two empty ones get the wording.
        #expect(partialPresentation.apps.notRestrictedText == nil)
        #expect(partialPresentation.urls.notRestrictedText != nil)
        #expect(partialPresentation.fileLocations.notRestrictedText != nil)
    }

    // MARK: - What the edit affordances actually send

    /// Every affordance hands the composer a command, and the command is built in the presentation
    /// so it is assertable at all. Each dimension names its own noun, so the planner is never asked
    /// to guess which list a bare value belongs to.
    @Test
    func editAffordancesProduceKindSpecificEditWorkspaceCommands() {
        let presentation = WorkspaceDetailPresentation(
            workspace: populatedWorkspace(),
            taskHistoryRecords: []
        )

        #expect(presentation.apps.addCommand == "In my Client Alpha workspace, add the app ")
        #expect(presentation.urls.addCommand == "In my Client Alpha workspace, add the URL ")
        #expect(presentation.fileLocations.addCommand == "In my Client Alpha workspace, add the folder ")
        // Completable prefixes: the entry does not exist yet for the sheet to name, so the caret
        // lands after a trailing space and the user types only the value.
        #expect(presentation.sections.allSatisfy { $0.addCommand.hasSuffix(" ") })

        #expect(presentation.apps.entries[1].removeCommand
            == "In my Client Alpha workspace, remove the app Microsoft Word")
        #expect(presentation.urls.entries[0].removeCommand
            == "In my Client Alpha workspace, remove the URL https://github.com/acme")
        #expect(presentation.fileLocations.entries[0].removeCommand
            == "In my Client Alpha workspace, remove the folder ~/Documents/ClientAlpha")
        // A removal names a real stored entry, so unlike an addition it is complete as sent.
        #expect(presentation.apps.entries.allSatisfy { !$0.removeCommand.hasSuffix(" ") })

        #expect(presentation.apps.entries[0].removeAccessibilityLabel == "Remove Safari from Client Alpha")
        #expect(presentation.fileLocations.addAccessibilityLabel == "Add the folder to Client Alpha")
    }

    /// **The sheet never writes a scope change itself.** Composing hands the widget a command and
    /// summons it; the capability then raises its own tier-2 add / tier-3 remove consent. A store
    /// call here would be a second write path that skips the approval the same edit raises from the
    /// command line — the one thing this branch's escalation-only rule forbids.
    @Test
    func composingAScopeEditFillsTheComposerAndWritesNothing() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let stored = populatedWorkspace()
        try store.save(stored)
        viewModel.refreshSavedItems()
        let before = try store.workspace(named: "Client Alpha")
        let requestsBefore = viewModel.widgetPresentationRequest

        let presentation = WorkspaceDetailPresentation(workspace: stored, taskHistoryRecords: [])
        viewModel.composeWorkspaceScopeEdit(presentation.fileLocations.entries[0].removeCommand)

        #expect(viewModel.command == "In my Client Alpha workspace, remove the folder ~/Documents/ClientAlpha")
        // Summoned, not dispatched: the user reads the composed command before it reaches the
        // planner, and nothing has run.
        #expect(viewModel.widgetPresentationRequest == requestsBefore + 1)
        #expect(viewModel.isRunning == false)
        #expect(viewModel.isAwaitingApproval == false)
        // The boundary is untouched until the capability actually runs and is approved.
        #expect(try store.workspace(named: "Client Alpha") == before)
    }

    // MARK: - Write failures

    /// The sheet's one direct write is *mark as team* — a display badge, not a boundary, and the
    /// store call it already had.
    ///
    /// A **write** failure and a **load** failure are different things with different correct
    /// wording: `recordLocalStorageLoadFailure`'s banner is hardcoded to "could not be decrypted or
    /// decoded", which is simply false of a save that failed. Asserted on the literal message and
    /// asserted different from the load banner's wording.
    @Test
    func aWorkspaceWriteFailureReportsASaveSpecificMessageRatherThanTheLoadBanner() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let workspace = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try store.save(workspace)
        viewModel.refreshSavedItems()
        #expect(viewModel.errorMessage == nil)

        // Make the store file unwritable by replacing it with a directory: the save path can
        // neither read it back nor overwrite it, so `save` throws for a reason that is genuinely a
        // storage failure rather than a stubbed error.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)

        viewModel.markWorkspaceAsTeam(workspace)

        let message = try #require(viewModel.errorMessage)
        #expect(message.hasPrefix("Could not update workspace: "))
        #expect(!message.contains("could not be decrypted or decoded"))
        #expect(!message.contains("Sonny could not load encrypted local data"))
        // A save failure is a task-level error, not a corrupt-store notice — routing it to the
        // load banner would render a *successful* task as a failure in the widget.
        #expect(viewModel.localStorageNotice == nil)
    }
}

@MainActor
private func makeSheetTestViewModel(root: URL, workspaceStore: WorkspaceStore) throws -> AgentViewModel {
    let suiteName = "WorkspaceDetailSheetTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: workspaceStore,
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: SheetTestShortcutCatalog(),
        // Hermetic seams, for the reason the sibling fixture states: these tests run no plan today,
        // but that is a property of the commands rather than of the fixture.
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
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: SheetTestPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults
    )
}

private func makeSheetTestDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkspaceDetailSheetTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private struct SheetTestShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

@MainActor
private final class SheetTestPasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}
