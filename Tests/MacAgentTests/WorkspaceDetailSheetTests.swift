import AppKit
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

    /// Every affordance produces a dispatch, and it is built in the presentation so it is assertable
    /// at all. Each dimension carries its own `kind`, so nothing downstream has to guess which list
    /// a bare value belongs to — which is what the noun in the sentence used to be doing when a
    /// planner had to read it.
    ///
    /// Both halves are asserted together on purpose: the sentence the user is shown and the request
    /// that actually runs are two different values, and the failure that matters is them disagreeing
    /// — a row that says "remove the URL github.com" while submitting a *file location* removal
    /// would still run, still prompt, and still look right in history.
    @Test
    func editAffordancesProduceKindSpecificEditWorkspaceRequests() {
        let presentation = WorkspaceDetailPresentation(
            workspace: populatedWorkspace(),
            taskHistoryRecords: []
        )

        let word = presentation.apps.entries[1].removeDispatch
        #expect(word.displayCommand == "In my Client Alpha workspace, remove the app Microsoft Word")
        #expect(word.request == WorkspaceScopeEditRequest(
            workspaceName: "Client Alpha",
            kind: .app,
            value: "Microsoft Word",
            action: .remove
        ))

        let url = presentation.urls.entries[0].removeDispatch
        #expect(url.displayCommand
            == "In my Client Alpha workspace, remove the URL https://github.com/acme")
        #expect(url.request == WorkspaceScopeEditRequest(
            workspaceName: "Client Alpha",
            kind: .webDomain,
            value: "https://github.com/acme",
            action: .remove
        ))

        let folder = presentation.fileLocations.entries[0].removeDispatch
        #expect(folder.displayCommand
            == "In my Client Alpha workspace, remove the folder ~/Documents/ClientAlpha")
        #expect(folder.request == WorkspaceScopeEditRequest(
            workspaceName: "Client Alpha",
            kind: .fileLocation,
            value: "~/Documents/ClientAlpha",
            action: .remove
        ))

        // Each section knows which dimension its Add button opens the picker for.
        #expect(presentation.sections.map(\.kind) == [.app, .webDomain, .fileLocation])

        #expect(presentation.apps.entries[0].removeAccessibilityLabel == "Remove Safari from Client Alpha")
        #expect(presentation.fileLocations.addAccessibilityLabel == "Add the folder to Client Alpha")
    }

    /// **SONNY-41's R-1, fixed where it is now load-bearing.**
    ///
    /// Two stored folders outside the whitelist canonicalize to one path, so `edit_workspace` takes
    /// both when a removal names either. The sheet used to reconstruct removal units by probing
    /// `WorkspaceScope.verdict(for:)` symmetrically, which can never answer `.inScope` for an entry
    /// the evaluator has already dropped — so these two drew as independent rows, each with a Remove
    /// button promising to take one and taking two. The note now comes from the capability's own key
    /// function.
    ///
    /// It matters more here than it did when this was recorded: the button no longer hands a
    /// sentence to a composer for the user to read and send, it submits the removal.
    @Test
    func inertEntriesSharingARemovalUnitSayThatBeforeTheyAreRemoved() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: ["~/Downloads/Alpha", "~/Downloads/Alpha/", "~/Downloads/Beta"]
            ),
            taskHistoryRecords: []
        )

        let entries = presentation.fileLocations.entries
        #expect(entries[0].sharedRemovalNote == "Removing this also removes ~/Downloads/Alpha/.")
        #expect(entries[1].sharedRemovalNote == "Removing this also removes ~/Downloads/Alpha.")
        #expect(entries[2].sharedRemovalNote == nil)
        #expect(entries[0].removeAccessibilityLabel
            == "Remove ~/Downloads/Alpha from Client Alpha, which also removes ~/Downloads/Alpha/")
        // Still inert, and still said so — the shared-removal note is additional to that, not a
        // replacement for it. (All three sit outside Desktop/Documents, which is exactly why the
        // old probe could not see them.)
        #expect(entries.allSatisfy { $0.inertNote != nil })
    }

    /// **A Remove tap runs the plan the row named — and, under the consequence rule (2026-08-13),
    /// applies it without asking.**
    ///
    /// SONNY-64's infrastructure claim survives the pivot in its important half: the plan that ran
    /// is the one the row named, field for field — no planner read anything, and nothing widened
    /// it. What changed is the gate's answer: the removal's tier-3 escalation is advisory, so the
    /// edit applies immediately and its consent sentence — same words, verbatim — surfaces on the
    /// ran-without-asking trace instead of a prompt. This supersedes the Q4-ratified prompting the
    /// same tap used to reach; a recorded coordinator call, founder-vetoable.
    ///
    /// `activeTaskPlanSource` is asserted because the run still has to be *identifiable* as
    /// screen-built — dispatch and copy read it even though no grant does anymore.
    @Test
    func dispatchingARemovalRunsThePreBuiltPlanAndAppliesWithTheTraceNamingTheChange() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let stored = StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Notes"], urls: [])
        try store.save(stored)
        viewModel.refreshSavedItems()
        let requestsBefore = viewModel.widgetPresentationRequest

        let presentation = WorkspaceDetailPresentation(workspace: stored, taskHistoryRecords: [])
        viewModel.dispatchWorkspaceScopeEdit(presentation.apps.entries[1].removeDispatch)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        // Ran without asking — and said so, naming the exact consent sentence the prompt used to
        // carry.
        #expect(!viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest == nil)
        #expect(viewModel.ranWithoutAskingTrace == "Ran without asking — worth knowing: "
            + "Removes Notes from workspace Client Alpha's apps. "
            + "What is removed stops counting as part of this workspace.")

        // The plan that ran is the one the row named, field for field.
        let plan = try #require(viewModel.plan)
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].operation == .editWorkspace)
        #expect(plan.steps[0].workspaceName == "Client Alpha")
        #expect(plan.steps[0].workspaceAppsToRemove == ["Notes"])
        #expect(plan.steps[0].workspaceApps == nil)

        #expect(viewModel.activeTaskPlanSource == .directUserAction)
        #expect(viewModel.lastCommand == "In my Client Alpha workspace, remove the app Notes")
        // The widget is summoned: it is where the trace renders, and the one surface this modal
        // sheet cannot cover.
        #expect(viewModel.widgetPresentationRequest == requestsBefore + 1)
        // Exactly the tapped change applied, and nothing else.
        #expect(try store.workspace(named: "Client Alpha").apps == ["Safari"])
    }

    /// An addition takes the same route and auto-runs: under the consequence rule every sheet edit
    /// does — the founder's 2026-08-07 friction complaint, answered by the rule itself. The
    /// one-directional escalation rule still reaches the picker unchanged: the assessment never
    /// moved, only the gate's answer did.
    @Test
    func dispatchingAnAdditionAutoRunsAndApplies() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let stored = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try store.save(stored)
        viewModel.refreshSavedItems()

        let picker = WorkspaceScopeAddPresentation(kind: .app, workspace: stored)
        let slack = try #require(
            picker.categories.flatMap(\.entries).first { $0.name == "Slack" }
        )
        // The return value is the picker's dismissal signal — it closes only on `true`. Asserted
        // after a mutation battery: inverting this return left the whole suite green.
        let accepted = viewModel.dispatchWorkspaceScopeEdit(slack.dispatch)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        #expect(accepted)
        // No prompt: the run completed, and the tapped change — exactly that change — is applied.
        #expect(!viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest == nil)
        #expect(viewModel.plan?.steps.first?.workspaceApps == ["Slack"])
        #expect(viewModel.activeTaskPlanSource == .directUserAction)
        #expect(try store.workspace(named: "Client Alpha").apps == ["Safari", "Slack"])
    }

    /// A dispatched removal applies exactly the tapped change and nothing else.
    ///
    /// The other half of the parity claim: it is not enough that the assessment matched — the
    /// write has to be the one the row described. A dispatch path that assessed the right plan and
    /// executed a different one would pass every assertion above. Every other field of the
    /// boundary — the URLs, the team type — must come through untouched.
    @Test
    func aDispatchedRemovalAppliesExactlyTheTappedChange() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let stored = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari", "Notes"],
            urls: ["https://github.com/acme"],
            teamType: .team
        )
        try store.save(stored)
        viewModel.refreshSavedItems()

        let presentation = WorkspaceDetailPresentation(workspace: stored, taskHistoryRecords: [])
        viewModel.dispatchWorkspaceScopeEdit(presentation.apps.entries[1].removeDispatch)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        let after = try store.workspace(named: "Client Alpha")
        #expect(after.apps == ["Safari"])
        // Every other field of the boundary is left alone.
        #expect(after.urls == ["https://github.com/acme"])
        #expect(after.teamType == .team)
        #expect(viewModel.isAwaitingApproval == false)
        #expect(viewModel.errorMessage == nil)
    }

    /// The sheet addition that auto-runs leaves the ran-without-asking trace, and — with nothing
    /// advisory on a plain tier-2 add — it states the rule itself, so the user learns *why* Sonny
    /// stopped asking (SONNY-99, reshaped by the consequence rule).
    @Test
    func aSheetAdditionThatAutoRanLeavesTheRuleStatingTrace() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let stored = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try store.save(stored)
        viewModel.refreshSavedItems()
        let picker = WorkspaceScopeAddPresentation(kind: .app, workspace: stored)
        let slack = try #require(
            picker.categories.flatMap(\.entries).first { $0.name == "Slack" }
        )

        _ = viewModel.dispatchWorkspaceScopeEdit(slack.dispatch)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        // Premise, guarded rather than assumed: the run really did auto-run and apply.
        #expect(!viewModel.isAwaitingApproval)
        #expect(try store.workspace(named: "Client Alpha").apps == ["Safari", "Slack"])
        #expect(viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
    }

    /// **A dispatch from this sheet is never an approval of something else.**
    ///
    /// `start()` turns a call made while an approval is pending into "allow", which is right for the
    /// widget's Send button and wrong for a button that says Remove. The sheet's controls are
    /// disabled while a task is in flight, so this was unreachable by clicking — but not by timing.
    /// A run the user started can pause at its approval, and `performApproval`'s stale-approval
    /// re-arm is a second way one appears; either can land between a render and a tap, which is the
    /// hole H1 had to be taught about once already. (Not a scheduled routine: `performScheduledRun`
    /// runs pre-approved at tier 2 and pauses the schedule instead of ever setting
    /// `approvalRequest` — PR #40 review, F4.) The pending approval is a destructive snippet
    /// replace — the pause the consequence rule still has, since sheet edits themselves no longer
    /// pause — so an accidental allow would be visible in the snippet store.
    @Test
    func aSheetDispatchWhileAnApprovalIsPendingIsRefusedRatherThanTreatedAsAnAllow() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let alpha = StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Slack"], urls: [])
        try store.save(alpha)
        viewModel.refreshSavedItems()

        let snippetStore = try await armPendingDestructiveApproval(viewModel, root: root)
        #expect(viewModel.isAwaitingApproval)
        let pendingPlan = viewModel.plan

        let alphaSheet = WorkspaceDetailPresentation(workspace: alpha, taskHistoryRecords: [])
        viewModel.dispatchWorkspaceScopeEdit(alphaSheet.apps.entries[1].removeDispatch)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        // Still waiting on the original approval; nothing was allowed and nothing was replaced.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.plan == pendingPlan)
        #expect(try snippetStore.snippet(matchingTrigger: ";armed").expansion == "Old text")
        #expect(try store.workspace(named: "Client Alpha").apps == ["Safari", "Slack"])
    }

    /// **The voice door — the one with the most at stake, and the one the branch never named.**
    ///
    /// `canUseVoice` blocks *starting* a recording while an approval is pending, but an approval can
    /// land during the recording or the transcription. Before this guard existed, the finished
    /// transcript went into `start()`, whose first branch is `approvePendingRun()` — so a sentence
    /// the user spoke about something else entirely would have landed as a silent **allow** on
    /// whatever tier-3 action was waiting. Nothing about the spoken words would have appeared
    /// anywhere; the approval would simply have been granted.
    ///
    /// Driven through `dispatchTranscribedCommand`, which exists as a seam for exactly this — one
    /// copy of the guard, one `start(...)` call, no transcriber and no API key required. The
    /// pending approval is a destructive snippet replace, so an accidental allow is visible in the
    /// store rather than only in a flag.
    @Test
    func aVoiceDispatchWhileAnApprovalIsPendingIsRefusedRatherThanTreatedAsAnAllow() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)

        let snippetStore = try await armPendingDestructiveApproval(viewModel, root: root)
        #expect(viewModel.isAwaitingApproval)
        let pendingPlan = viewModel.plan

        viewModel.dispatchTranscribedCommand("what is the weather today", origin: .widget)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        // The replace is still waiting to be answered, and the old snippet text survives.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.plan == pendingPlan)
        #expect(try snippetStore.snippet(matchingTrigger: ";armed").expansion == "Old text")
        // The spoken words did not become the next command either — the residue guard cleared them.
        #expect(viewModel.command == "")
        // And the refusal is on the record, which is the half F5 was about: the voice path used to
        // announce "Sonny will act now" and then drop the transcript with nothing said afterwards.
        #expect(viewModel.logStore.events.contains {
            $0.message == "Not started: an approval is still waiting for your answer."
        })
    }

    /// **The routine door.** `runRoutineWidget`'s button lives in `RoutineDetailView`, a different
    /// file entirely — which is precisely the argument for a shared guard, and precisely why it
    /// needs its own test rather than inheriting the sheet's.
    @Test
    func aRoutineDispatchWhileAnApprovalIsPendingIsRefusedRatherThanTreatedAsAnAllow() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)

        let snippetStore = try await armPendingDestructiveApproval(viewModel, root: root)
        #expect(viewModel.isAwaitingApproval)
        let pendingPlan = viewModel.plan

        viewModel.runRoutineWidget(StoredRoutine(name: "Morning", steps: []))
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.plan == pendingPlan)
        #expect(try snippetStore.snippet(matchingTrigger: ";armed").expansion == "Old text")
    }

    /// **The retry door, which the guard does *not* change** — recorded so the enumeration is
    /// complete rather than selective.
    ///
    /// `retryLastCommand` carries its own `!isTaskInFlight` guard, which is a strict superset of
    /// `isAwaitingApproval`, and it fires before `dispatch` is reached. The new guard is therefore
    /// unreachable through this door. Asserted anyway: "this caller is unaffected" is a claim about
    /// a shared helper's blast radius, and the point of enumerating five doors is that each answer
    /// is checked rather than assumed.
    @Test
    func aRetryWhileAnApprovalIsPendingIsRefusedByItsOwnOlderGuard() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)

        let snippetStore = try await armPendingDestructiveApproval(viewModel, root: root)
        #expect(viewModel.isAwaitingApproval)
        let pendingPlan = viewModel.plan

        viewModel.retryLastCommand()
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.plan == pendingPlan)
        #expect(try snippetStore.snippet(matchingTrigger: ";armed").expansion == "Old text")
        // Refused by `retryLastCommand`'s own guard, so `dispatch` was never entered and its
        // refusal line was never written. That is what makes this door's answer "unaffected"
        // rather than "also covered".
        #expect(viewModel.logStore.events.contains {
            $0.message == "Not started: an approval is still waiting for your answer."
        } == false)
    }

    /// **The workspace-card door.**
    ///
    /// The refusal lives in the shared `dispatch` helper rather than on the sheet's button, so it
    /// covers `openWorkspaceWidget` and `runRoutineWidget` too — neither of which had one. That is
    /// the whole argument for putting it there, and this repo's H1 precedent is that "structurally
    /// covered" is a claim worth a test per door: a later change narrowing the guard to the
    /// pre-built path only would otherwise break these silently.
    @Test
    func aWorkspaceCardDispatchWhileAnApprovalIsPendingIsAlsoRefusedRatherThanTreatedAsAnAllow() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let research = StoredWorkspace(name: "Research", apps: ["Safari", "Notes"], urls: [])
        try store.save(research)
        viewModel.refreshSavedItems()

        let snippetStore = try await armPendingDestructiveApproval(viewModel, root: root)
        #expect(viewModel.isAwaitingApproval)
        let pendingPlan = viewModel.plan

        viewModel.openWorkspaceWidget(research)
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        // The card action did not become an "allow" on the replace waiting behind it.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.plan == pendingPlan)
        #expect(try snippetStore.snippet(matchingTrigger: ";armed").expansion == "Old text")
    }

    /// **A refused dispatch leaves an armed card binding alone, and that is the rule — not an
    /// oversight in the rule above it.**
    ///
    /// `start` kills the arm when it *accepts* a non-composer dispatch; both of its early returns sit
    /// in front of that. So a sheet edit refused because something else is in flight leaves "New task
    /// here on Research" armed. That is what the arm is for: it binds the next composer dispatch, and
    /// nothing dispatched. Killing it would discard an intent the user still holds because an
    /// unrelated button was pressed at an unlucky moment.
    ///
    /// Pinned because the branch's doc comment claimed the kill was unconditional, which was false on
    /// exactly this path; a sentence that is wrong about a lifecycle is worth replacing with a test.
    @Test
    func aRefusedSheetDispatchLeavesAnArmedCardBindingIntact() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        let alpha = StoredWorkspace(name: "Client Alpha", apps: ["Safari", "Slack"], urls: [])
        try store.save(research)
        try store.save(alpha)
        viewModel.refreshSavedItems()

        // An approval from somewhere else is pending — the state the sheet's buttons are disabled
        // for, and one a foreground run can produce between a render and a click. Bound to Client
        // Alpha explicitly, so the in-flight-versus-armed distinction below stays observable.
        _ = try await armPendingDestructiveApproval(viewModel, root: root, workspaceBinding: "Client Alpha")
        #expect(viewModel.isAwaitingApproval)

        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        let accepted = viewModel.dispatchWorkspaceScopeEdit(
            WorkspaceScopeEditCommand.dispatch(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Notes",
                action: .add
            )
        )

        #expect(accepted == false)
        #expect(viewModel.pendingWorkspaceBinding == "Research")
        // While the task that caused the refusal is still live, the widget's chip names *that*
        // task's workspace — `boundWorkspaceName` prefers the in-flight binding and falls back to
        // the arm. Asserted rather than assumed, because the tempting claim is that the surviving
        // arm is on screen throughout, and it is not.
        #expect(viewModel.boundWorkspaceName == "Client Alpha")

        // Once that task is out of the way, the arm is the binding again — so it was preserved for
        // the composer dispatch it was always for, not merely left lying in a field.
        viewModel.cancelCurrentRun()
        #expect(viewModel.boundWorkspaceName == "Research")
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

    /// A scope edit dispatched from a sheet is its own context, so it drops any armed card binding.
    ///
    /// The composer dispatch is the one dispatch permitted to consume a pending arm, so an arm left
    /// alive by "New task here" on workspace A would run this edit bound to A while it edits B —
    /// under a chip naming A. A chip naming an unrelated workspace over an edit is the confusion the
    /// arm rules exist to prevent, and it survives the move from composing to dispatching because
    /// this path is not `fromComposer`.
    @Test
    func dispatchingAScopeEditDropsAnArmedCardBindingFromAnotherWorkspace() async throws {
        let root = try makeSheetTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
        let viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        let other = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        let alpha = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try store.save(other)
        try store.save(alpha)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(other)
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        viewModel.dispatchWorkspaceScopeEdit(
            WorkspaceScopeEditCommand.dispatch(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Notes",
                action: .add
            )
        )
        try await waitForSheetViewModelToBecomeIdle(viewModel)

        #expect(viewModel.pendingWorkspaceBinding == nil)
        // Bound to the workspace the plan names, never to the abandoned arm. The addition
        // auto-runs to completion under the origin grant (SONNY-97), so `activeTaskScope` is
        // already `.unscoped` again by the time the dispatch settles — `lastAssessedScope` is the
        // durable record of what the run was actually bound to, and it exists for exactly this
        // class of post-hoc check.
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: alpha)))
        // And the edit applied to the workspace the plan named, not the armed one.
        #expect(try store.workspace(named: "Client Alpha").apps == ["Safari", "Notes"])
        #expect(try store.workspace(named: "Research").apps == ["Safari"])
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

    // MARK: - App icons on the sheet's rows (SONNY-65)

    /// **The founder's ask of 2026-08-07: icon beside the name, apps only.**
    ///
    /// Asserted on the presentation rather than the view, per this suite's own standard — the icon
    /// is resolved in `WorkspaceDetailPresentation` precisely so that it *can* be. What the view
    /// does with a resolved icon is a manual item, as it is for every other field here.
    @Test
    func onlyAppRowsCarryAnIconAndUrlsAndFoldersCarryNone() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari", "Notes"],
                urls: ["https://example.com"],
                fileLocations: ["~/Documents/Alpha"]
            ),
            taskHistoryRecords: [],
            iconResolver: StubWorkspaceAppIconResolver(resolving: ["Safari"])
        )

        // Apps: every row carries an icon presentation, and it is for that row's own app.
        #expect(presentation.apps.entries.map(\.appIcon?.appName) == ["Safari", "Notes"])
        // The other two dimensions carry none at all — the row view is shared across all three, so
        // this is what keeps a folder from being asked for an app icon.
        #expect(presentation.urls.entries.allSatisfy { $0.appIcon == nil })
        #expect(presentation.fileLocations.entries.allSatisfy { $0.appIcon == nil })
    }

    /// **The fallback constraint, which is the one place this ticket departs from the card.**
    ///
    /// An app the catalog cannot resolve renders **name-only**. The card's tile does the opposite —
    /// `app.dashed` on a bordered chip — and reusing it wholesale would have violated this ticket's
    /// own constraint, which is why the resolver is reused and the fallback is not.
    ///
    /// Two different `nil`s reach the same rendering, and both are asserted: `appIcon` itself being
    /// `nil` (not an app), and `appIcon?.icon` being `nil` (an app that resolves to nothing). The
    /// view branches on the second, so a row for an uninstalled app is name-only exactly like a URL.
    @Test
    func anUnresolvableAppFallsBackToNameOnlyRatherThanAPlaceholder() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari", "NotInstalledApp"],
                urls: [],
                fileLocations: []
            ),
            taskHistoryRecords: [],
            iconResolver: StubWorkspaceAppIconResolver(resolving: ["Safari"])
        )

        let entries = presentation.apps.entries
        #expect(entries[0].appIcon?.icon != nil)
        #expect(entries[1].appIcon?.icon == nil)
        // And the name is untouched either way — the verbatim string is the sheet's recorded
        // rationale (a user checks an entry against the one a consent prompt named), so an icon is
        // additional to it and never a replacement.
        #expect(entries.map(\.value) == ["Safari", "NotInstalledApp"])
    }

    /// **Equality stays independent of what is installed**, which is why the entry carries a
    /// `WorkspaceAppIconPresentation?` rather than a bare `NSImage?`.
    ///
    /// That type excludes icon content from its `==` on purpose. A bare image on the entry would
    /// have put it back into this type's synthesized equality, making two presentations of the same
    /// workspace compare unequal on a machine where one app happens to be installed — a difference
    /// no user could see and every diffing test would trip over.
    @Test
    func twoPresentationsOfOneWorkspaceCompareEqualWhateverResolved() {
        let workspace = StoredWorkspace(
            name: "Client Alpha",
            apps: ["Safari", "NotInstalledApp"],
            urls: [],
            fileLocations: []
        )
        let everything = WorkspaceDetailPresentation(
            workspace: workspace,
            taskHistoryRecords: [],
            iconResolver: StubWorkspaceAppIconResolver(resolving: ["Safari", "NotInstalledApp"])
        )
        let nothing = WorkspaceDetailPresentation(
            workspace: workspace,
            taskHistoryRecords: [],
            iconResolver: StubWorkspaceAppIconResolver(resolving: [])
        )

        // One resolved both icons and the other resolved neither.
        #expect(everything.apps.entries.allSatisfy { $0.appIcon?.icon != nil })
        #expect(nothing.apps.entries.allSatisfy { $0.appIcon?.icon == nil })
        // And they are still the same presentation.
        #expect(everything == nothing)
    }

    /// **The row renders the icon *beside* the name, not instead of it** — the ticket's central
    /// constraint, and the one the four tests above could not reach.
    ///
    /// Found by a mutant, not by reading: blanking the name whenever an icon resolved
    /// (`Text(entry.appIcon?.icon == nil ? entry.value : "")`) **passed the whole suite**. Every
    /// assertion above is about the presentation, and the presentation was still correct — the view
    /// was simply declining to render a field it had. That is the same shape as PR #80's F2, where a
    /// scan anchored on a call site missed what the callee did with what it was handed.
    ///
    /// So this reads the view, through `MacAgentSource`. This suite's header says view-level claims
    /// are a recorded limitation with a manual item rather than a fake test, and that still holds
    /// for anything about *appearance* — spacing, alignment, whether 16pt reads right beside 13pt
    /// text. It does not have to hold for *whether a field is rendered at all*, which is textual and
    /// therefore checkable, and which is the half a user would actually lose.
    ///
    /// **Three assertions, and each one exists because the ones before it are not enough.** This doc
    /// said "two assertions" for a round after it needed three, never mentioning the one that does
    /// the most work (PR #84 cycle 3, C3):
    ///
    /// 1. **The name is rendered** — `Text(entry.value)` appears once in the row.
    /// 2. **It is not inside the icon's conditional** — that block, delimited by its own braces.
    /// 3. **It is a direct child of the row's stack, inside no conditional at all** — every nested
    ///    brace span stripped, and the name must survive that.
    ///
    /// **Why 1 and 2 are not enough, measured rather than argued.** The second assertion originally
    /// used `region(of:from:to:)` with `Text(entry.value)` as the `to:` anchor, and that function
    /// ends its region *at* the end anchor — so "the region does not contain `entry.value`" was true
    /// wherever that line sat. It could not fail. Two of the reviewer's mutants survived all 1446
    /// tests, and **both keep `Text(entry.value)` byte-identical, changing only its depth**:
    ///
    /// - **W** wraps it inside the icon's `if let` — nothing renders on an icon-less row. Assertion 2,
    ///   once brace-delimited, kills this.
    /// - **I** renders it only when no icon resolved — icon-only rows, verbatim what the ticket
    ///   forbids. **Assertion 2 cannot see this**, because I nests the name in a *different*
    ///   conditional that the icon-branch check never looks at, and assertion 1 counts a token
    ///   without caring where it sits. Only assertion 3 kills it.
    ///
    /// The generalisable form: **"renders unconditionally" is a claim about depth.** A count sees a
    /// token and not its position; a single-branch check sees one branch and not the others.
    ///
    /// **What none of the three covers, and it is a different axis entirely:** styling. A mutant
    /// adding `.opacity(entry.appIcon?.icon == nil ? 1 : 0)` to the name passes all three — the
    /// `Text` is present, outside the icon branch, and a direct child — while rendering the name
    /// invisible whenever an icon resolved. That is the reviewer's N4 survivor, recorded rather than
    /// closed: a textual scan can say *where* a view sits, never how it looks. The covering check is
    /// the manual row that has a human open the sheet and read the names.
    @Test
    func theSheetRowRendersTheNameUnconditionallyBesideAnyIcon() throws {
        let row = try MacAgentSource.region(
            of: MacAgentSource.read("CommandCenterView.swift"),
            from: "private func entryRow(_ entry: WorkspaceScopeEntryPresentation) -> some View {",
            to: "private struct WorkspaceScopeAddTarget: Identifiable {"
        )
        #expect(MacAgentSource.count(of: "Text(entry.value)", inText: row) == 1)

        // The conditional's own body, brace-matched — not "everything up to the name", which is
        // what made this vacuous.
        let iconBranch = try MacAgentSource.braceBlock(
            of: row,
            openedBy: "if let nsImage = entry.appIcon?.icon {"
        )
        // The name is not in here: neither the value itself, nor a second `Text(` that could render
        // it under another spelling. A conditional that draws the icon draws only the icon.
        #expect(!iconBranch.contains("entry.value"))
        #expect(MacAgentSource.count(of: "Text(", inText: iconBranch) == 0)

        // **And the name is a *direct child* of the row's stack, inside no conditional at all.**
        // The two assertions above still do not say that: one counts a token across the whole row,
        // the other looks inside a single branch. A mutant that keeps `Text(entry.value)` byte for
        // byte and wraps it in `if entry.appIcon?.icon == nil { … }` passes both — a different
        // conditional, so the icon-branch check never sees it, and the count is unchanged. That is
        // the reviewer's mutant I, and this is the line that kills it.
        let stack = try MacAgentSource.braceBlock(
            of: row,
            openedBy: "HStack(alignment: .top, spacing: 8) {"
        )
        #expect(MacAgentSource.topLevel(of: stack).contains("Text(entry.value)"))
        // And the icon really is gated on a resolved image rather than on the entry being an app,
        // which is what routes an unresolvable app to the same name-only rendering a URL gets.
        #expect(row.contains("if let nsImage = entry.appIcon?.icon {"))
    }

    /// **SONNY-41's inert rendering survives the icon field** — this ticket's third constraint, as
    /// far as a presentation-level test can carry it.
    ///
    /// `inertNote` and `appIcon` are independent fields, so nothing here can displace anything; the
    /// point of asserting it is that the icon was added *to* the row rather than in place of part
    /// of it. The visual half — that a 16pt square beside the name does not out-shout a muted note
    /// on the line beneath it — is a manual item, like every other rendering claim in this suite.
    ///
    /// **Worth knowing, because it makes the constraint mostly structural:** an app entry is inert
    /// only when its name is empty (`WorkspaceScope`, "The app name is empty." — the catalog stopped
    /// making apps inert in SONNY-82). An empty name resolves no icon in production, so an inert app
    /// row is name-only anyway. The two can only coexist in a fixture, which is why this test
    /// asserts the fields' independence rather than staging a combination the app cannot reach.
    @Test
    func anInertAppRowKeepsItsInertNoteAndTheIconFieldDoesNotDisplaceIt() {
        let presentation = WorkspaceDetailPresentation(
            workspace: StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari", "   "],
                urls: [],
                fileLocations: []
            ),
            taskHistoryRecords: [],
            iconResolver: StubWorkspaceAppIconResolver(resolving: ["Safari"])
        )

        let entries = presentation.apps.entries
        #expect(entries.count == 2)
        // The live one: icon resolved, no note.
        #expect(entries[0].appIcon?.icon != nil)
        #expect(entries[0].inertNote == nil)
        // The inert one: the note is intact, and it still carries an icon *field* — so the row is
        // rendering both facts rather than the icon having taken the note's place. It resolves no
        // image, which is the production shape too.
        #expect(entries[1].inertNote == "Not in effect — The app name is empty.")
        #expect(entries[1].appIcon != nil)
        #expect(entries[1].appIcon?.icon == nil)
    }

}

/// Arms a pending approval the consequence rule still produces: a typed snippet save whose
/// trigger already exists with different text — a destructive replace. Returns the store so the
/// caller can assert nothing was written while the prompt sat pending. (Sheet edits themselves
/// auto-run now, so the pending-approval tests arm their pause here instead.)
@MainActor
private func armPendingDestructiveApproval(
    _ viewModel: AgentViewModel,
    root: URL,
    workspaceBinding: String? = nil
) async throws -> SnippetStore {
    let snippetStore = SnippetStore(fileURL: root.appendingPathComponent("snippets.json"))
    try snippetStore.save(StoredSnippet(trigger: ";armed", expansion: "Old text"))
    viewModel.command = "snippet save ;armed = New text"
    viewModel.start(workspaceBinding: workspaceBinding)
    try await waitForSheetViewModelToBecomeIdle(viewModel)
    return snippetStore
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
        // Hermetic seams, for the reason the sibling fixture states. These tests *do* run plans now
        // — SONNY-64's sheet dispatches one — but only `edit_workspace`, which opens nothing; the
        // seams stay replaced so that a future test in this file is not one typo away from driving
        // the developer's machine.
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
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
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

/// Waits for a dispatched run to reach a terminal state *or a pause*.
///
/// `isRunning` is the right term rather than `isTaskInFlight`: a run that stops at an approval has
/// already flipped `isRunning` back to false and is exactly the state most of these tests are
/// asserting about. Records an issue rather than hanging, so a regression that never settles fails
/// as a test instead of as a stuck suite.
/// The 30 seconds is a deadlock backstop, not a timing assertion (SONNY-159/160/161): this target is
/// `@MainActor` and Swift Testing interleaves its suites on one actor, so the previous 2 s fired when a
/// neighbouring test was busy rather than when anything was wrong. Full reasoning and the measurements
/// are on `VisionSessionRunTests.hangBackstop`.
@MainActor
private func waitForSheetViewModelToBecomeIdle(
    _ viewModel: AgentViewModel,
    timeout: TimeInterval = 30
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not settle before timeout. Waited 30s, which at this length means genuinely stuck rather than merely busy — treat it as a real failure.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
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

/// The clarification gate, in the family H1 opened for voice.
///
/// A clarification pause looks idle from outside — `performStart`'s defer clears `isRunning` and
/// `approvalRequest` is nil — so any gate written as `isRunning || isAwaitingApproval` is live during
/// exactly the state where a second dispatch destroys the first task's continuation. H1 closed the
/// voice door; these close the sheet's and the cards'.
@Suite
@MainActor
struct ClarificationGateTests {
    /// **F3(b) — the dispatch guard, now covering the door SONNY-64 replaced it with.** Dispatching a
    /// scope edit during a pause is refused, and the pending question survives byte-identical.
    ///
    /// The rule is inherited rather than re-implemented: `dispatchWorkspaceScopeEdit` goes through
    /// the same `dispatch` → `canSubmit` choke point the composer's own Send does, so the pause term
    /// applies to it without a fourth copy of the check. Asserted through the new door anyway — the
    /// point of H1 was that "structurally covered" is a claim worth a test per door.
    @Test
    func dispatchingAScopeEditDuringAClarificationPauseIsRefused() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        harness.viewModel.command = ""

        harness.viewModel.dispatchWorkspaceScopeEdit(
            WorkspaceScopeEditCommand.dispatch(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Notes",
                action: .add
            )
        )

        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?")
        // The edit's text never stayed in `command`, which is the property `submitClarification`
        // interpolates the Q&A *around* — so the continuation cannot become a hybrid.
        #expect(harness.viewModel.command == "")
        #expect(harness.viewModel.isRunning == false)
        // Not summoned either: a refused dispatch raises no widget, because there is nothing new
        // there to answer.
        #expect(harness.viewModel.widgetPresentationRequest == 0)
        // **`dispatch`'s second trace line, and the reason it is asserted here rather than nowhere.**
        //
        // F5 added two: a cause-specific one on the approval guard, and this cause-neutral one on
        // the `canSubmit` path — cause-neutral because `canSubmit` refuses for four different
        // reasons and naming one would be wrong for the other three. The voice-door test pins the
        // first; PR #40's cycle-3 re-check deleted the second and the whole suite stayed green.
        //
        // That is M13's shape recurring one round later: a contract the fix was specifically built
        // around, held by nothing, found by a mutant rather than by reading. This door is the right
        // place for it — a clarification pause refuses *through* `canSubmit`, so the line under test
        // is the one this path actually emits.
        #expect(harness.viewModel.logStore.events.contains {
            $0.message == "Not started: Sonny was not ready to begin another task."
        })
    }

    /// The consequence the guard exists for, asserted on the continuation itself: with the edit
    /// refused, `submitClarification` builds a continuation carrying only the Q&A over an empty
    /// command.
    @Test
    func theClarificationContinuationCannotCarryADispatchedEdit() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        harness.viewModel.command = ""

        harness.viewModel.dispatchWorkspaceScopeEdit(
            WorkspaceScopeEditCommand.dispatch(
                workspaceName: "Client Alpha",
                kind: .app,
                value: "Safari",
                action: .remove
            )
        )
        harness.viewModel.clarificationAnswer = "~/Documents"
        harness.viewModel.submitClarification()

        // Read from `lastCommand`, not `command`: `start` captures the submitted text and clears
        // `command` synchronously, so the live property is empty by the time the call returns.
        #expect(!harness.viewModel.lastCommand.contains("workspace"))
        #expect(!harness.viewModel.lastCommand.contains("remove the app"))
        #expect(harness.viewModel.lastCommand.contains("Clarification question: Which folder should I scan?"))
        #expect(harness.viewModel.lastCommand.contains("Clarification answer: ~/Documents"))
        // Stronger than "does not contain the edit": the submitted text *begins* with the
        // question, so nothing at all preceded it. `start` trims what it captures, which is why the
        // literal's leading blank lines are absent here.
        #expect(harness.viewModel.lastCommand.hasPrefix("Clarification question:"))
    }

    /// **F3(a) — the entry gate.** The sheet's and card's controls are gated on one shared term that
    /// includes the pause, so a control that would refuse is not offered.
    @Test
    func theInFlightTermTreatsAClarificationPauseAsInFlight() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }

        #expect(harness.viewModel.isTaskInFlight == false)
        harness.viewModel.clarificationQuestion = "Which folder?"
        #expect(harness.viewModel.isTaskInFlight)
        // Not merely "something is set" — the two older terms are still false, which is exactly why
        // a gate missing the third term was live here.
        #expect(harness.viewModel.isRunning == false)
        #expect(harness.viewModel.isAwaitingApproval == false)
    }

    /// **F5 — the card actions' half of the same family**, closed at the dispatch choke point so one
    /// term covers Open, Run now, the composer and anything added later.
    @Test
    func cardDispatchesDuringAClarificationPauseRefuseRatherThanDiscardTheAnswer() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        let workspace = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try harness.store.save(workspace)
        harness.viewModel.refreshSavedItems()
        harness.viewModel.clarificationQuestion = "Which folder should I scan?"

        harness.viewModel.openWorkspaceWidget(workspace)

        // `openWorkspaceWidget` assigns `command` then calls `start`, which now refuses — so the
        // paused question is still there to answer.
        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?")
        #expect(harness.viewModel.isRunning == false)

        harness.viewModel.runRoutineWidget(StoredRoutine(name: "Morning", steps: []))

        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?")
        #expect(harness.viewModel.isRunning == false)
    }

    /// `canSubmit` is the seam, so the refusal holds for every dispatch rather than per surface —
    /// and it does **not** block the continuation, because `submitClarification` clears the question
    /// before re-entering `start`.
    @Test
    func theDispatchSeamRefusesWhilePausedAndStillAllowsTheContinuation() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        harness.viewModel.command = "Scan my Desktop"
        #expect(harness.viewModel.canSubmit)

        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        #expect(harness.viewModel.canSubmit == false)

        harness.viewModel.clarificationAnswer = "~/Documents"
        harness.viewModel.submitClarification()
        // The question is cleared by `submitClarification` itself, which is what keeps the seam from
        // blocking the one dispatch that must pass.
        #expect(harness.viewModel.clarificationQuestion == nil)
    }

    // MARK: - A refused dispatch leaves no residue (PR #32 cycle 3, H1)

    /// **The invariant, stated once and asserted at every door: after any refused dispatch, a
    /// subsequent `submitClarification` interpolates only the question and the answer.**
    ///
    /// `canSubmit`'s clarification term closed the *discard* everywhere, but four callers wrote
    /// `command` before the refusal could fire and the refusal path returned without touching it —
    /// so the fix traded a discarded answer for a corrupted continuation at three doors. These are
    /// the reviewer's measured probe sequences turned into pins.
    @Test(arguments: [
        ("run now", "Run my Morning routine"),
        ("retry", "Zip my Desktop"),
        ("open workspace", "Open my Client Alpha workspace")
    ])
    func aRefusedDispatchLeavesNoResidueAndTheContinuationCarriesOnlyTheQandA(
        probe: (name: String, dispatchText: String)
    ) throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        let workspace = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try harness.store.save(workspace)
        harness.viewModel.refreshSavedItems()

        // `retry` needs a prior command to retry; `start` is the only thing that sets `lastCommand`.
        if probe.name == "retry" {
            harness.viewModel.command = probe.dispatchText
            harness.viewModel.start()
            #expect(harness.viewModel.lastCommand == probe.dispatchText, "\(probe.name) premise")
            harness.viewModel.cancelCurrentRun()
            harness.viewModel.isRunning = false
        }

        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        harness.viewModel.command = ""

        switch probe.name {
        case "run now":
            harness.viewModel.runRoutineWidget(StoredRoutine(name: "Morning", steps: []))
        case "retry":
            harness.viewModel.retryLastCommand()
        default:
            harness.viewModel.openWorkspaceWidget(workspace)
        }

        // The discard is still fixed — the question survives the refusal.
        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?", "\(probe.name) question")
        // And the residue is gone: nothing the refused dispatch wrote is left behind.
        #expect(harness.viewModel.command == "", "\(probe.name) residue")

        harness.viewModel.clarificationAnswer = "~/Documents"
        harness.viewModel.submitClarification()

        // The continuation begins with the question, so nothing at all preceded it.
        #expect(harness.viewModel.lastCommand.hasPrefix("Clarification question:"), "\(probe.name) continuation")
        #expect(!harness.viewModel.lastCommand.contains(probe.dispatchText), "\(probe.name) no dispatch text")
    }

    /// The notification Retry path, asserted at the level it is honestly assertable.
    ///
    /// `AppDelegate` wires the system notification's Retry action to `retryLastCommand(origin:)` and
    /// fires it from outside SwiftUI entirely, so no view gate can cover it and no test in this
    /// target can post a real notification. What *is* assertable is the method that action calls,
    /// with the same origin it passes — which is the whole of the behaviour, since the action's only
    /// body is that call.
    @Test
    func theNotificationRetryPathRefusesDuringAPauseAndLeavesNoResidue() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        harness.viewModel.command = "Zip my Desktop"
        harness.viewModel.start()
        harness.viewModel.cancelCurrentRun()
        harness.viewModel.isRunning = false
        #expect(harness.viewModel.lastCommand == "Zip my Desktop")

        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        harness.viewModel.command = ""

        harness.viewModel.retryLastCommand(origin: .widget)

        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?")
        #expect(harness.viewModel.command == "")
    }

    /// The compose family's half of the same invariant. These never reach `start`, so the outcome
    /// check cannot cover them — they guard before assigning instead.
    @Test
    func composerPrefillsDuringAPauseLeaveNoResidueEither() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        harness.viewModel.clarificationQuestion = "Which folder should I scan?"
        harness.viewModel.command = ""

        harness.viewModel.composeCommand("Create a workspace called ")

        #expect(harness.viewModel.command == "")
        #expect(harness.viewModel.clarificationQuestion == "Which folder should I scan?")

        harness.viewModel.clarificationAnswer = "~/Documents"
        harness.viewModel.submitClarification()
        #expect(harness.viewModel.lastCommand.hasPrefix("Clarification question:"))
        #expect(!harness.viewModel.lastCommand.contains("Create a workspace called"))
    }

    /// A dispatch that is *not* refused still works — the residue clear must not eat a real one.
    @Test
    func anAcceptedDispatchStillRunsAndIsRecorded() throws {
        let harness = try ClarificationHarness()
        defer { harness.tearDown() }
        let workspace = StoredWorkspace(name: "Client Alpha", apps: ["Safari"], urls: [])
        try harness.store.save(workspace)
        harness.viewModel.refreshSavedItems()

        harness.viewModel.openWorkspaceWidget(workspace)

        #expect(harness.viewModel.lastCommand == "Open my Client Alpha workspace")
        harness.viewModel.cancelCurrentRun()
    }

    @MainActor
    private struct ClarificationHarness {
        let root: URL
        let store: WorkspaceStore
        let viewModel: AgentViewModel

        init() throws {
            root = try makeSheetTestDirectory()
            store = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
            viewModel = try makeSheetTestViewModel(root: root, workspaceStore: store)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// Resolves an icon for a named set of apps and nothing else, so a test can drive both branches of
/// the fallback without depending on what is installed on the machine running it.
///
/// A distinct, non-`nil` `NSImage` per app: the assertions below are about *whether* an icon
/// resolved, and a shared instance would let a mix-up between two rows pass.
@MainActor
private struct StubWorkspaceAppIconResolver: WorkspaceAppIconResolving {
    let resolving: Set<String>

    func icon(forAppName appName: String) -> NSImage? {
        guard resolving.contains(appName) else {
            return nil
        }
        return NSImage(size: NSSize(width: 16, height: 16))
    }
}
