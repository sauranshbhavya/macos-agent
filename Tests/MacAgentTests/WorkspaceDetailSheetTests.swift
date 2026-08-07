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

    /// One task is "1 task", not "1 tasks".
    ///
    /// Added after a mutation battery: replacing the pluralisation with a bare "tasks" left the
    /// whole suite green, because every existing assertion — the card's included — happened to use
    /// a plural count. Sharing the rule between the card and the sheet made the gap visible, and
    /// this closes it for both.
    @Test
    func theTaskCountReadsSingularForExactlyOneTask() {
        let oneRecord = [
            CompletedTaskRecord(command: "a", startedAt: .distantPast, completedAt: Date(), outcomeStatus: .completed, workspaceName: "Client Alpha")
        ]

        let presentation = WorkspaceDetailPresentation(
            workspace: populatedWorkspace(),
            taskHistoryRecords: oneRecord
        )

        #expect(presentation.taskCount == 1)
        #expect(presentation.taskCountText == "1 task")
        #expect(WorkspaceTaskCount.text(0) == "0 tasks")
        #expect(WorkspaceTaskCount.text(1) == "1 task")
        #expect(WorkspaceTaskCount.text(2) == "2 tasks")
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

    // MARK: - The evaluator is the only notion of "restricted"

    /// **A dimension whose every entry is inert restricts nothing, and the sheet must say so.**
    ///
    /// `WorkspaceScope` reports `.unconstrained` whenever its *canonical* list is empty, and its own
    /// doc comment states that this includes the all-inert case. The sheet shipped deriving the
    /// answer from `entries.isEmpty` instead — the same two-notions-of-empty defect SONNY-40 removed
    /// from the consent path one commit earlier, reintroduced on the surface whose whole job is
    /// telling the user whether a dimension restricts, and inverted from the failure the ticket was
    /// written against: the user reads a dimension as restricting when nothing is.
    ///
    /// The row is still shown — never silently dropped — but marked as not in effect, carrying the
    /// evaluator's own reason.
    @Test
    func aDimensionOfOnlyInertEntriesReadsAsNotRestrictedAndSaysWhy() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let outside = "/tmp/WorkspaceDetailSheetTests-Outside"
        let workspace = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari"],
            urls: [],
            fileLocations: [outside]
        )
        let scope = WorkspaceScope(workspace: workspace, whitelist: whitelist)
        // Premise, so this cannot pass vacuously: the evaluator really does treat the dimension as
        // unconstrained while an entry is stored.
        #expect(scope.fileRoots.isEmpty)
        #expect(scope.inertEntries.map(\.value) == [outside])
        #expect(scope.verdict(for: .fileLocation(root.appendingPathComponent("anything").path)) == .unconstrained)

        let presentation = WorkspaceDetailPresentation(
            workspace: workspace,
            taskHistoryRecords: [],
            whitelist: whitelist
        )

        // The sheet now gives the evaluator's answer, not the array's.
        #expect(presentation.fileLocations.isRestricted == false)
        #expect(presentation.fileLocations.notRestrictedText
            == "Not restricted — this workspace does not limit which folders a task can touch.")
        #expect(presentation.unrestrictedFootnote != nil)
        // Shown, not dropped — and marked, with the evaluator's own words for why.
        let entry = try #require(presentation.fileLocations.entries.first)
        #expect(entry.value == outside)
        let reason = try #require(scope.inertEntries.first?.reason)
        #expect(entry.inertNote == "Not in effect — \(reason)")
        #expect(entry.inertNote?.contains("outside the writable whitelist") == true)
        // The live dimension beside it is unaffected.
        #expect(presentation.apps.isRestricted)
        #expect(presentation.apps.entries[0].inertNote == nil)
    }

    /// The same divergence on the URL dimension, through a host `SafeURL` refuses.
    @Test
    func aURLTheEvaluatorRejectsReadsAsNotRestrictedRatherThanAsABoundary() throws {
        let workspace = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari"],
            urls: ["https://192.168.1.10/dashboard"]
        )
        let scope = WorkspaceScope(workspace: workspace)
        #expect(scope.webDomains.isEmpty)
        #expect(scope.verdict(for: .webDomain("example.com")) == .unconstrained)

        let presentation = WorkspaceDetailPresentation(workspace: workspace, taskHistoryRecords: [])

        #expect(presentation.urls.isRestricted == false)
        #expect(presentation.urls.notRestrictedText
            == "Not restricted — this workspace does not limit which sites a task can open.")
        #expect(presentation.urls.entries.count == 1)
        #expect(presentation.urls.entries[0].inertNote?.hasPrefix("Not in effect — ") == true)
    }

    /// One live entry beside an inert one still restricts — the dimension's status is the canonical
    /// list's, so a single working entry keeps it configured, and only the inert row is marked.
    @Test
    func aLiveEntryBesideAnInertOneKeepsTheDimensionRestricted() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let inside = root.appendingPathComponent("Live").path
        let outside = "/tmp/WorkspaceDetailSheetTests-Outside-Mixed"

        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [inside, outside]
            ),
            taskHistoryRecords: [],
            whitelist: whitelist
        )

        #expect(presentation.fileLocations.isRestricted)
        #expect(presentation.fileLocations.notRestrictedText == nil)
        #expect(presentation.fileLocations.entries.map(\.value) == [inside, outside])
        #expect(presentation.fileLocations.entries[0].inertNote == nil)
        #expect(presentation.fileLocations.entries[1].inertNote != nil)
    }

    /// **The footnote follows the evaluator too, not the array count.**
    ///
    /// Added after a mutation battery: sourcing the footnote from raw array emptiness left the suite
    /// green, because every existing fixture that had an unrestricted dimension also had an *empty*
    /// one, so the two sources never disagreed. This fixture has no empty array anywhere and one
    /// all-inert dimension, which is the only shape that tells them apart.
    @Test
    func theFootnoteFollowsTheEvaluatorEvenWhenNoListIsEmpty() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let workspace = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari"],
            urls: ["https://example.com"],
            fileLocations: ["/tmp/WorkspaceDetailSheetTests-FootnoteOnly"]
        )
        // Premise: nothing is empty, and exactly one dimension nonetheless restricts nothing.
        #expect(workspace.apps.isEmpty == false)
        #expect(workspace.urls.isEmpty == false)
        #expect(workspace.effectiveFileLocations.isEmpty == false)

        let presentation = WorkspaceDetailPresentation(
            workspace: workspace,
            taskHistoryRecords: [],
            whitelist: whitelist
        )

        #expect(presentation.fileLocations.isRestricted == false)
        #expect(presentation.apps.isRestricted)
        #expect(presentation.urls.isRestricted)
        #expect(presentation.unrestrictedFootnote != nil)
    }

    /// The general statement the three cases above are instances of: for every dimension of every
    /// fixture, the sheet's answer equals the evaluator's. A predicate that drifted from the
    /// canonical lists in *any* direction fails here.
    @Test
    func everyDimensionStatusEqualsTheEvaluatorsCanonicalEmptiness() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let fixtures = [
            populatedWorkspace(),
            StoredWorkspace(name: "Client Alpha", apps: [], urls: [], fileLocations: []),
            StoredWorkspace(name: "Client Alpha", apps: [" "], urls: ["not a url"], fileLocations: ["/tmp/nope"]),
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: ["https://192.168.1.10/x"],
                fileLocations: [root.appendingPathComponent("Live").path]
            )
        ]

        for workspace in fixtures {
            let scope = WorkspaceScope(workspace: workspace, whitelist: whitelist)
            let presentation = WorkspaceDetailPresentation(
                workspace: workspace,
                taskHistoryRecords: [],
                whitelist: whitelist
            )

            #expect(presentation.apps.isRestricted == !scope.appKeys.isEmpty)
            #expect(presentation.urls.isRestricted == !scope.webDomains.isEmpty)
            #expect(presentation.fileLocations.isRestricted == !scope.fileRoots.isEmpty)
            // And the sentence follows the status, in both directions.
            for section in presentation.sections {
                #expect((section.notRestrictedText == nil) == section.isRestricted)
            }
        }
    }

    // MARK: - The Remove affordance tells the truth about granularity

    /// **`edit_workspace` matches removals by host, so two rows on one host leave together.** The
    /// per-row Remove control promised single-entry removal; the label and a visible note now state
    /// the real unit, so the user can see what goes before they tap.
    @Test
    func removingOneURLRowStatesThatItsSiblingOnTheSameHostGoesToo() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: ["https://github.com/acme", "https://github.com/other-team", "https://example.com/docs"]
            ),
            taskHistoryRecords: []
        )

        let acme = presentation.urls.entries[0]
        #expect(acme.sharedRemovalNote == "Removing this also removes https://github.com/other-team.")
        #expect(acme.removeAccessibilityLabel
            == "Remove https://github.com/acme from Client Alpha, which also removes https://github.com/other-team")
        // Symmetric, and the unrelated host is not swept in.
        #expect(presentation.urls.entries[1].sharedRemovalNote
            == "Removing this also removes https://github.com/acme.")
        #expect(presentation.urls.entries[2].sharedRemovalNote == nil)
        #expect(presentation.urls.entries[2].removeAccessibilityLabel
            == "Remove https://example.com/docs from Client Alpha")
    }

    /// The app half: removal matches by catalog key, so two spellings of one app leave together.
    @Test
    func removingOneAppRowStatesThatTheOtherSpellingOfTheSameAppGoesToo() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(name: "Client Alpha", apps: ["Chrome", "Google Chrome", "Safari"], urls: []),
            taskHistoryRecords: []
        )

        #expect(presentation.apps.entries[0].sharedRemovalNote == "Removing this also removes Google Chrome.")
        #expect(presentation.apps.entries[1].sharedRemovalNote == "Removing this also removes Chrome.")
        #expect(presentation.apps.entries[0].removeAccessibilityLabel
            == "Remove Chrome from Client Alpha, which also removes Google Chrome")
        // A genuinely different app is left alone — the note is not simply always-on.
        #expect(presentation.apps.entries[2].sharedRemovalNote == nil)
    }

    /// **Grouping is equality, not containment** — the reason the unit is computed by asking the
    /// evaluator in *both* directions. `verdict(for:)` is folder containment and a dot-suffix host
    /// match, so a one-way probe would report `~/Documents` and `~/Documents/ClientAlpha` as one
    /// removal unit and offer to delete the parent when the user asked for the child. They are not
    /// one unit; a trailing slash is.
    @Test
    func aContainingFolderIsNotTheSameRemovalUnitAsTheFolderInsideIt() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let parent = root.path
        let child = root.appendingPathComponent("ClientAlpha").path

        let nested = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [parent, child]),
            taskHistoryRecords: [],
            whitelist: whitelist
        )
        #expect(nested.fileLocations.entries[0].sharedRemovalNote == nil)
        #expect(nested.fileLocations.entries[1].sharedRemovalNote == nil)

        // The same path written twice, once with a trailing slash, *is* one unit.
        let duplicated = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [child, child + "/"]
            ),
            taskHistoryRecords: [],
            whitelist: whitelist
        )
        #expect(duplicated.fileLocations.entries[0].sharedRemovalNote == "Removing this also removes \(child)/.")
    }

    /// An inert entry groups with nothing — it can never match anything, including another entry.
    @Test
    func anInertEntryIsItsOwnRemovalUnit() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: ["/tmp/WorkspaceDetailSheetTests-A", "/tmp/WorkspaceDetailSheetTests-B"]
            ),
            taskHistoryRecords: [],
            whitelist: PathWhitelist(roots: [root])
        )

        #expect(presentation.fileLocations.entries.allSatisfy { $0.sharedRemovalNote == nil })
        #expect(presentation.fileLocations.entries.allSatisfy { $0.inertNote != nil })
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

    /// **The sheet's one direct write touches the badge and nothing else.**
    ///
    /// Added after a mutation battery: making `markWorkspaceAsTeam` clear the apps list left the
    /// whole suite green. Nothing pinned that the one write reachable from this sheet leaves the
    /// boundary alone — and a badge toggle silently wiping a workspace's scope is precisely the
    /// class of loss this branch exists to prevent, arriving through the one mutation that is
    /// allowed to skip the capability's consent because it is not supposed to be a boundary change.
    @Test
    func markingAsTeamChangesOnlyTheBadgeAndLeavesTheBoundaryIntact() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let solo = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari", "Microsoft Word"],
            urls: ["https://github.com/acme"],
            fileLocations: ["~/Documents/ClientAlpha"]
        )
        try store.save(solo)
        viewModel.refreshSavedItems()

        viewModel.markWorkspaceAsTeam(solo)

        let stored = try store.workspace(named: "Client Alpha")
        #expect(stored.teamType == .team)
        #expect(stored.apps == ["Safari", "Microsoft Word"])
        #expect(stored.urls == ["https://github.com/acme"])
        #expect(stored.fileLocations == ["~/Documents/ClientAlpha"])
        #expect(viewModel.errorMessage == nil)
    }

    /// **The pair: what the sheet shows about an inert entry, and what removing it actually costs.**
    ///
    /// SONNY-40's L1 made the capability right — removing an entry that never restricted anything
    /// raises no tier-3, because nothing is lost. The sheet was the half that disagreed, presenting
    /// that entry as a live boundary. Both halves are asserted here in one test, because the defect
    /// was never in either half alone: it was the two surfaces answering the same question
    /// differently.
    @Test
    func anInertEntryReadsAsInertAndItsRemovalClaimsNoLoss() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let whitelist = PathWhitelist(roots: [root])
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let live = root.appendingPathComponent("Live").path
        let inert = "/tmp/WorkspaceDetailSheetTests-Pair"
        try store.save(
            StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [], fileLocations: [live, inert])
        )
        let executor = AgentActionExecutor(
            whitelist: whitelist,
            appOpener: HermeticAppOpener(),
            fileOpener: HermeticFileOpener(),
            routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
            workspaceStore: store,
            shortcutCatalog: SheetTestShortcutCatalog(),
            shortcutRunHistoryStore: ShortcutRunHistoryStore(
                fileURL: root.appendingPathComponent("shortcuts-run-history.json")
            )
        )

        // The presentation half.
        let presentation = WorkspaceDetailPresentation(
            workspace: try store.workspace(named: "Client Alpha"),
            taskHistoryRecords: [],
            whitelist: whitelist
        )
        let inertRow = try #require(presentation.fileLocations.entries.first { $0.value == inert })
        #expect(inertRow.inertNote != nil)

        // The behaviour half, through the real capability: removing it costs nothing, so no
        // loss-claiming consent is raised.
        let assessment = try executor.assessRisk(
            plan: AgentPlan(
                summary: "Edit workspace.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "edit",
                        operation: .editWorkspace,
                        description: "Edit workspace.",
                        workspaceName: "Client Alpha",
                        workspaceFileLocationsToRemove: [inert]
                    )
                ]
            ),
            scope: .unscoped
        )
        #expect(assessment.escalations.isEmpty)
        #expect(assessment.effectiveTier == .tier2)

        // And the contrast that proves the assertion above is not vacuous: removing the *live*
        // entry does cost something, and does escalate.
        let liveAssessment = try executor.assessRisk(
            plan: AgentPlan(
                summary: "Edit workspace.",
                requiresConfirmation: true,
                steps: [
                    AgentStep(
                        id: "edit",
                        operation: .editWorkspace,
                        description: "Edit workspace.",
                        workspaceName: "Client Alpha",
                        workspaceFileLocationsToRemove: [live]
                    )
                ]
            ),
            scope: .unscoped
        )
        #expect(liveAssessment.effectiveTier == .tier3)
    }

    // MARK: - Strings the view no longer builds itself

    /// Both were composed inside a view body, where nothing can assert them, while their Add and
    /// Remove siblings were pure and tested.
    @Test
    func theSheetsRemainingUserVisibleStringsArePureAndPinned() {
        let presentation = WorkspaceDetailPresentation(
            workspace: populatedWorkspace(),
            taskHistoryRecords: []
        )

        #expect(presentation.markAsTeamAccessibilityLabel == "Mark Client Alpha as a team workspace")
        #expect(WorkspaceDetailPresentation.unavailableText(name: "Client Alpha")
            == "“Client Alpha” is no longer saved.")
    }

    /// A scope edit composed from a sheet is a new composition context, so it drops any armed card
    /// binding.
    ///
    /// The composer dispatch is the one dispatch permitted to consume a pending arm, so an arm left
    /// alive by "New task here" on workspace A would run this edit bound to A while its command
    /// edits B — under a chip naming A. A chip naming an unrelated workspace over an edit command is
    /// the confusion the arm rules exist to prevent.
    @Test
    func composingAScopeEditDropsAnArmedCardBindingFromAnotherWorkspace() throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let other = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try store.save(other)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(other)
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        viewModel.composeWorkspaceScopeEdit("In my Client Alpha workspace, add the app Notes")

        #expect(viewModel.pendingWorkspaceBinding == nil)
        #expect(viewModel.command == "In my Client Alpha workspace, add the app Notes")
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
