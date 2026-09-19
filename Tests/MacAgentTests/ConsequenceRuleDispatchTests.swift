import Combine
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgent
@testable import MacAgentCore

/// The consequence rule driven through the REAL dispatch path, end to end — typed command in,
/// planner (a stub handed to the real planner-factory seam), `performStart`, the real
/// assessment, the real gate, the real execution, file on disk out.
///
/// This suite exists because of the 2026-08-13 manual-pass finding: row C's relaxation shipped
/// with 950 green tests pinning the mapping *function* while nothing pinned the product's dispatch
/// path into it, and the live app never fired the grant. A mapping-level suite can be green while
/// the product is wrong; these tests are the ones that would have caught it, rebuilt for the rule
/// that replaced the grants. The `AgentViewModel` whitelist and Safe-mode seams these tests use
/// were added for exactly this purpose.
@Suite(.serialized)
@MainActor
struct ConsequenceRuleDispatchTests {
    /// A tier-2 draft inside its own workspace, typed as a command: runs with no prompt, writes
    /// the file, and leaves the ran-without-asking trace.
    @Test
    func anInWorkspaceTierTwoDraftTypedAsACommandAutoRuns() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [fixture.projectFolder.path]
            )
        )
        fixture.viewModel.refreshSavedItems()

        fixture.viewModel.command = "Draft notes in Client Alpha"
        fixture.viewModel.start(workspaceBinding: "Client Alpha")
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.lastAssessedScope != .unscoped)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
    }

    /// The identical draft with no workspace bound runs identically — the boundary is data, not a
    /// gate, so its absence must not re-introduce a prompt.
    @Test
    func aPlainUnscopedTierTwoDraftTypedAsACommandAutoRuns() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(fixture.viewModel.lastAssessedScope == .unscoped)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
    }

    /// The overwrite still prompts — the destructive class keeps today's asking exactly — and
    /// approving it is what performs the write. No trace: the prompt was the disclosure.
    @Test
    func anOverwriteStillPromptsThroughTheRealDispatchPathAndApprovingRunsIt() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try "existing draft".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.assessment.effectiveTier == .tier3)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        #expect(request.requirement == .explicitApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) == "existing draft")

        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) != "existing draft")
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }

    /// Safe mode makes all three ask — the in-workspace draft, the unscoped draft, and the
    /// overwrite — through the same real path, reading the same stored property SONNY-90 will back
    /// with Settings.
    @Test
    func safeModeMakesAllThreeAskThroughTheRealDispatchPath() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        try fixture.workspaceStore.save(
            StoredWorkspace(
                name: "Client Alpha",
                apps: ["Safari"],
                urls: [],
                fileLocations: [fixture.projectFolder.path]
            )
        )
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.interactionMode = .safe

        // 1. In-workspace draft.
        fixture.viewModel.command = "Draft notes in Client Alpha"
        fixture.viewModel.start(workspaceBinding: "Client Alpha")
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(!FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        fixture.viewModel.cancelCurrentRun()

        // 2. Unscoped draft.
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(!FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        fixture.viewModel.cancelCurrentRun()

        // 3. The overwrite (asks either way; Safe mode must not make it ask less).
        try "existing draft".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.approvalRequest?.requirement == .explicitApproval)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) == "existing draft")
        fixture.viewModel.cancelCurrentRun()
    }

    /// **Power through the real dispatch path, and why this test arrived with a chassis ticket.**
    ///
    /// Until SONNY-142 the engine's posture input was a boolean, so Normal and Power were literally
    /// the same value by the time a requirement was computed — nothing could distinguish them and
    /// nothing needed to. They are distinct enum cases now, reaching the one requirement function as
    /// distinct cells of one switch, and this is the file that would notice if widening the chassis
    /// had quietly changed what Power does.
    ///
    /// **The name is scoped, and the scope is the point** (PR #88 cycle 2, F2). This used to be
    /// called `powerModeBehavesExactlyLikeNormalThroughTheRealDispatchPath`, which stopped being
    /// true on 2026-08-21: Power is now the one mode that skips the per-app control gate. The
    /// assertions were right all along — neither plan here controls an app, so for a *non-vision*
    /// dispatch the two modes really do still answer identically — but the name claimed the general
    /// case. What the per-app difference looks like through a real path is
    /// `powerSkipsThePerAppGateAndStillAsksAboutADestructiveAction` in `VisionSessionRunTests`.
    ///
    /// Both halves are asserted together on purpose. The auto-run half is what "the two agree on a
    /// non-vision plan" means; the overwrite half is the standing rule that survives every mode, and
    /// asserting only the first would let "Power skips a gate" be misread as "Power asks nothing".
    @Test
    func powerAndNormalAgreeOnANonVisionDispatchAndBothStillAskAboutAnOverwrite() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        fixture.viewModel.interactionMode = .power

        // 1. The ordinary tier-2 draft: no prompt, file written, trace left — Normal's answer.
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        #expect(fixture.viewModel.approvalRequest == nil)
        #expect(!fixture.viewModel.isAwaitingApproval)
        #expect(fixture.viewModel.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.draftOutput.path))
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")

        // 2. The overwrite still asks, in Power. The consequence rule is not a mode setting.
        fixture.viewModel.clearStaleTaskOutcome()
        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start()
        try await waitForIdle(fixture.viewModel)

        let request = try #require(fixture.viewModel.approvalRequest)
        #expect(request.requirement == .explicitApproval)
        #expect(request.assessment.escalations.map(\.consequence) == [.destructive])
        fixture.viewModel.cancelCurrentRun()
    }

    // MARK: - The trace's lifetime

    /// PR #48, F1 — the trace must not outlive the run it describes into the one deliberately
    /// destructive thing in the app.
    ///
    /// `deleteLocalData` writes its own `finalSummary`, and `WidgetResultPanel` renders
    /// `ranWithoutAskingTrace` under whatever summary is showing. A trace that survived
    /// `clearInMemoryLocalDataState` therefore put "nothing here is destructive, and it affects no
    /// one else" directly beneath "Deleted N local data files." — asserting the opposite of what the
    /// user had just done, on the one surface the trace exists to be read on.
    @Test
    func deletingAllLocalDataClearsTheRanWithoutAskingTraceItWouldOtherwiseRenderUnder() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start(origin: .widget)
        try await waitForIdle(fixture.viewModel)

        // Premises, guarded rather than assumed: the trace is really set, on a panel that is really
        // on screen. Without both, the assertion after the deletion passes for the wrong reason.
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")
        #expect(fixture.viewModel.hasVisibleWidgetPanel)

        fixture.viewModel.deleteLocalData()
        // The press is asynchronous since SONNY-404's fix round: it drains the deletion queue and
        // deletes the account's server-side content before it touches a local file.
        await fixture.viewModel.localDataWipeForTests?.value

        // Still a real render — the deletion result is showing, so an uncleared trace would be
        // visible underneath it rather than merely resident.
        // The second sentence is SONNY-404's fix round: this fixture's backend client is hermetic
        // and configured with no environment, so the wipe cannot reach a gateway and says so rather
        // than reporting a silent success. What this test is about is the trace underneath, which is
        // unaffected either way.
        // The fixture is signed out and its client is hermetic, so the press reaches nothing and
        // records nothing — the third state SONNY-404's second fix round added, which tells the user
        // to sign in rather than promising a retry that could never name their account.
        #expect(fixture.viewModel.finalSummary == LocalDataDeletionCopy.outcome(
            deletedFileCount: 0,
            serverCopy: .strandedWithNoSession
        ))
        #expect(fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }

    /// The sibling clear. The trace has no lifetime of its own: `WidgetResultPanel` is its only
    /// reader and that panel exists only while `finalSummary` is non-empty, so the widget's
    /// auto-clear timer has to take both. Left behind, the value can never again be shown with the
    /// run it describes — it can only reappear attached to someone else's summary, which is the
    /// shape F1 arrived in.
    @Test
    func clearingAStaleTaskOutcomeTakesTheRanWithoutAskingTraceWithIt() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }

        fixture.viewModel.command = "Draft notes"
        fixture.viewModel.start(origin: .widget)
        try await waitForIdle(fixture.viewModel)
        #expect(fixture.viewModel.ranWithoutAskingTrace
            == "Ran without asking — nothing here is destructive, and it affects no one else.")

        fixture.viewModel.clearStaleTaskOutcome()

        #expect(fixture.viewModel.finalSummary.isEmpty)
        #expect(!fixture.viewModel.hasVisibleWidgetPanel)
        #expect(fixture.viewModel.ranWithoutAskingTrace == nil)
    }
}

// MARK: - Fixture

@MainActor
private struct DispatchFixture {
    let viewModel: AgentViewModel
    let root: URL
    let projectFolder: URL
    let draftOutput: URL
    let workspaceStore: WorkspaceStore

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// The real view model with three substitutions, each named: a fake planner provider registered
/// through the real planner seam (so the typed-command branch of `performStart` runs without a network
/// key), the fixture root as the whitelist (so the draft is writable hermetically), and the
/// hermetic side-effect seams every view-model suite injects.
///
/// `planner` is the one knob, and it defaults to the draft planner every test above uses. The run
/// attribution suite below hands in a planner whose output depends on the command, so two runs park
/// two different approvals over two different files (SONNY-456).
@MainActor
private func makeDispatchFixture(
    planner: @escaping @MainActor @Sendable (_ projectFolder: URL) -> any Planning = {
        DraftPlanner(output: $0.appendingPathComponent("notes.md"))
    }
) throws -> DispatchFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConsequenceRuleDispatchTests-\(UUID().uuidString)", isDirectory: true)
    let projectFolder = root.appendingPathComponent("ClientAlpha", isDirectory: true)
    try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
    let draftOutput = projectFolder.appendingPathComponent("notes.md")

    let suiteName = "ConsequenceRuleDispatchTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)

    let workspaceStore = WorkspaceStore(fileURL: root.appendingPathComponent("workspaces.json"))
    let viewModel = AgentViewModel(
        routineStore: RoutineStore(fileURL: root.appendingPathComponent("routines.json")),
        workspaceStore: workspaceStore,
        snippetStore: SnippetStore(fileURL: root.appendingPathComponent("snippets.json")),
        recentArtifactStore: RecentArtifactStore(fileURL: root.appendingPathComponent("recent-artifacts.json")),
        shortcutCatalog: EmptyDispatchShortcutCatalog(),
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
            fileURL: root.appendingPathComponent("shortcuts-run-history.json")
        ),
        taskHistoryStore: TaskHistoryStore(fileURL: root.appendingPathComponent("task-history.json")),
        taskPlanDetailStore: TaskPlanDetailStore(fileURL: root.appendingPathComponent("task-plan-details.json")),
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json")
        ),
        clipboardHistorySettingsStore: ClipboardHistorySettingsStore(
            fileURL: root.appendingPathComponent("clipboard-history-settings.json")
        ),
        approvedAppStore: ApprovedAppStore(fileURL: root.appendingPathComponent("approved-apps.json")),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            // The same roots this fixture hands the view model, so the store answers
            // "is this an output location" against the folders the run really used.
            whitelist: PathWhitelist(roots: [root])
        ),
        resumableTaskStore: ResumableTaskStore(fileURL: root.appendingPathComponent("resumable-tasks.json")),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        skillSelectionStore: SkillSelectionStore(
            fileURL: root.appendingPathComponent("added-skills.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: HermeticPasteboardReader(),
            store: ClipboardHistoryStore(fileURL: root.appendingPathComponent("clipboard-history.json")),
            settingsStore: ClipboardHistorySettingsStore(
                fileURL: root.appendingPathComponent("clipboard-history-settings.json")
            )
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        makePlanner: { _, _ in planner(projectFolder) },
        userDefaults: userDefaults,
        whitelist: PathWhitelist(roots: [root])
    )
    return DispatchFixture(
        viewModel: viewModel,
        root: root,
        projectFolder: projectFolder,
        draftOutput: draftOutput,
        workspaceStore: workspaceStore
    )
}

/// The 30 seconds is a deadlock backstop, not a timing assertion (SONNY-159/160/161): this target is
/// `@MainActor` and Swift Testing interleaves its suites on one actor, so the previous 2 s fired when a
/// neighbouring test was busy rather than when anything was wrong. Full reasoning and the measurements
/// are on `VisionSessionRunTests.hangBackstop`.
@MainActor
private func waitForIdle(_ viewModel: AgentViewModel, timeout: TimeInterval = 30) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not become idle before timeout. Waited 30s, which at this length means genuinely stuck rather than merely busy — treat it as a real failure.")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Returns the same tier-2 draft plan for every command — the planner half of the manual-pass
/// scenario, minus the network.
private struct DraftPlanner: Planning {
    let output: URL

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        AgentPlan(
            summary: "Draft notes.",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft notes.",
                    outputPath: output.path,
                    draftTitle: "Notes",
                    draftContent: "Outline for today."
                )
            ]
        )
    }
}

private struct EmptyDispatchShortcutCatalog: ShortcutCatalogProviding {
    func shortcutNames() throws -> [String] {
        []
    }
}

// MARK: - SONNY-456: an answer reaches the run it names, and no other

/// An approval is answered against a named run and the token that approval was parked with, through
/// the real dispatch path, the real gate and the real execution — the property SONNY-456's first
/// layer exists for.
///
/// **Two real runs in two slots, and the widget left on the first.** `addRunSlotForTests()` is the
/// only way a second slot can exist on this branch; the second run is started inside that slot's
/// `RunScope`, exactly as the rest of SONNY-456 will start one. With the focus left on the first
/// run, every way an answer could fall back to "whatever is on screen" lands on the wrong run, so
/// the file each approval guards says which run was answered.
@Suite(.serialized)
@MainActor
struct RunAttributedApprovalTests {
    @Test
    func anApprovalNamedForOneRunRunsThatRunAndLeavesTheOtherParked() async throws {
        let fixture = try makeDispatchFixture(planner: { PerCommandDraftPlanner(folder: $0) })
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        let alpha = fixture.projectFolder.appendingPathComponent("alpha.md")
        let beta = fixture.projectFolder.appendingPathComponent("beta.md")
        // Both files exist, so each draft is an overwrite and each run parks at tier 3.
        try "existing alpha".write(to: alpha, atomically: true, encoding: .utf8)
        try "existing beta".write(to: beta, atomically: true, encoding: .utf8)

        // Every announcement the notification would be posted from, in order (F2 of PR #279's
        // review): with two runs and the widget on the first, "announced with its run" and
        // "announced with the run on screen" finally give different answers.
        var announced: [ApprovalTarget] = []
        let subscription = viewModel.approvalParked.sink { target, _ in announced.append(target) }
        defer { subscription.cancel() }

        let first = viewModel.focusedRunID
        viewModel.command = "Draft alpha"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the first run to park its approval") {
            slot(first, in: viewModel).map { $0.approvalRequest != nil && !$0.isRunning } == true
        }
        let firstToken = try #require(slot(first, in: viewModel)?.approvalToken)

        let second = viewModel.addRunSlotForTests()
        RunScope.$current.withValue(second) {
            viewModel.command = "Draft beta"
            viewModel.start()
        }
        // Ends on the first run's token moving too, so a second run that wrote into the first
        // run's slot fails at an assertion below rather than as a wait that gave up.
        try await HangBackstop.waitOrAbandon(for: "the second run to park, or the first run's slot to move") {
            let parked = slot(second, in: viewModel).map { $0.approvalRequest != nil && !$0.isRunning } == true
            return parked || slot(first, in: viewModel)?.approvalToken != firstToken
        }

        let firstSlot = try #require(slot(first, in: viewModel))
        let secondSlot = try #require(slot(second, in: viewModel))
        #expect(firstSlot.approvalToken == firstToken, "starting the second run moved the first run's question")
        #expect(firstSlot.lastCommand == "Draft alpha")
        #expect(secondSlot.lastCommand == "Draft beta")
        #expect(secondSlot.approvalRequest?.assessment.effectiveTier == .tier3)
        let secondToken = try #require(secondSlot.approvalToken, "the second run parked no approval of its own")
        #expect(firstToken != secondToken)
        #expect(viewModel.focusedRunID == first, "precondition: the widget is on the first run")
        #expect(
            announced == [
                ApprovalTarget(runID: first, token: firstToken),
                ApprovalTarget(runID: second, token: secondToken)
            ],
            "each park must be announced with its own run while the widget shows the other"
        )

        // One run's token answers nothing on the other, in either direction.
        #expect(!viewModel.approveParkedRun(first, token: secondToken))
        #expect(!viewModel.approveParkedRun(second, token: firstToken))
        #expect(slot(first, in: viewModel)?.approvalToken == firstToken)
        #expect(slot(second, in: viewModel)?.approvalToken == secondToken)
        #expect(try String(contentsOf: alpha, encoding: .utf8) == "existing alpha")
        #expect(try String(contentsOf: beta, encoding: .utf8) == "existing beta")

        // The second run's own announcement, carried the way the banner carries it — written into a
        // notification's userInfo and read back — answers the second run, and only it (F3).
        let secondAnnouncement = try #require(announced.last)
        let carried = try #require(ApprovalTarget(notificationUserInfo: secondAnnouncement.notificationUserInfo))
        #expect(carried == ApprovalTarget(runID: second, token: secondToken))
        #expect(viewModel.approveParkedRun(carried.runID, token: carried.token))
        try await HangBackstop.waitOrAbandon(for: "the approved run to finish") {
            viewModel.runSlots.allSatisfy { !$0.isRunning }
        }
        #expect(try String(contentsOf: beta, encoding: .utf8) != "existing beta", "the named run did not run")
        #expect(try String(contentsOf: alpha, encoding: .utf8) == "existing alpha", "the run on screen ran instead")
        #expect(slot(second, in: viewModel)?.approvalRequest == nil)
        #expect(slot(second, in: viewModel)?.approvalToken == nil)
        #expect(slot(first, in: viewModel)?.approvalToken == firstToken, "the first run's question must still be waiting")
    }

    /// A question asked again is a new question: the token an earlier answer carries — a
    /// notification posted for the first asking — answers nothing, and the new one does. This asks
    /// again by setting the same request straight over itself; `performApproval`'s stale-approval
    /// re-arm clears to `nil` first and then parks, and either step alone retires the old token.
    @Test
    func aTokenFromBeforeTheQuestionWasAskedAgainAnswersNothing() async throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        try "existing draft".write(to: fixture.draftOutput, atomically: true, encoding: .utf8)

        let run = viewModel.focusedRunID
        viewModel.command = "Draft notes"
        viewModel.start()
        try await HangBackstop.waitOrAbandon(for: "the run to park its approval") {
            slot(run, in: viewModel).map { $0.approvalRequest != nil && !$0.isRunning } == true
        }
        let stale = try #require(slot(run, in: viewModel)?.approvalToken)
        let request = try #require(viewModel.approvalRequest)

        viewModel.approvalRequest = request
        let fresh = try #require(slot(run, in: viewModel)?.approvalToken)
        #expect(fresh != stale, "asking again must mint a new token")

        #expect(!viewModel.approveParkedRun(run, token: stale))
        #expect(!viewModel.approveParkedRun(RunID(), token: fresh), "a run that does not exist was answered")
        #expect(viewModel.approvalRequest != nil)
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) == "existing draft")

        #expect(viewModel.approveParkedRun(run, token: fresh))
        try await HangBackstop.waitOrAbandon(for: "the approved run to finish") {
            viewModel.runSlots.allSatisfy { !$0.isRunning }
        }
        #expect(try String(contentsOf: fixture.draftOutput, encoding: .utf8) != "existing draft")
    }

    /// A failure is announced with the run it belongs to, and the notification's hold lands on that
    /// run (F2 of PR #279's review). Before SONNY-456 this was `@Published`'s own behaviour; it is
    /// one explicit line in `errorMessage`'s setter now, so it needs a test that would notice the
    /// line gone or naming the run on screen — which a single run cannot tell apart.
    @Test
    func aFailureIsAnnouncedWithTheRunItBelongsToAndItsHoldLandsThere() throws {
        let fixture = try makeDispatchFixture()
        defer { fixture.tearDown() }
        let viewModel = fixture.viewModel
        var raised: [(RunID, String)] = []
        let subscription = viewModel.errorMessageRaised.sink { raised.append(($0, $1)) }
        defer { subscription.cancel() }

        let first = viewModel.focusedRunID
        let second = viewModel.addRunSlotForTests()
        // `start()` with nothing typed fails synchronously with its own sentence, inside whichever
        // run is in scope — here the second, with the widget left on the first.
        RunScope.$current.withValue(second) {
            viewModel.command = ""
            viewModel.start()
        }

        #expect(raised.count == 1)
        #expect(raised.first?.0 == second, "the failure was announced as the run on screen's")
        #expect(raised.first?.1 == "Enter a natural-language command first.")
        #expect(slot(second, in: viewModel)?.errorMessage == "Enter a natural-language command first.")
        #expect(slot(first, in: viewModel)?.errorMessage == nil, "the failure landed on the run on screen")

        viewModel.markOutcomeAsNotified(for: second)
        #expect(slot(second, in: viewModel)?.outcomeWasNotified == true)
        #expect(slot(first, in: viewModel)?.outcomeWasNotified == false, "the hold landed on the run on screen")
    }

    /// The banner's Allow answers the run and the approval it was posted for — read off the wiring,
    /// because `SonnyNotificationService.init?` returns nil without bundle identity and neither the
    /// subscription nor the response handler exists in a test process. The encoding and decoding
    /// themselves are `ApprovalTarget`'s, held by `ApprovalNotificationRoundTripTests`; this pins
    /// that the notification uses exactly those two members on each side. Before SONNY-456 the
    /// Allow closure was `viewModel.start()`, which approves whatever the focused run has parked
    /// when the banner is pressed; that is why the absence of `start()` is asserted beside the new
    /// door.
    @Test
    func theBannersAllowAnswersTheRunAndApprovalItWasPostedFor() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")
        let allow = try MacAgentSource.region(of: delegate, from: "onAllow:", to: "onRetry:")
        #expect(MacAgentSource.count(of: "viewModel.approveParkedRun(target.runID, token: target.token)", inText: allow) == 1)
        #expect(MacAgentSource.count(of: "start()", inText: allow) == 0)
        #expect(MacAgentSource.count(of: "guard let target else { return }", inText: allow) == 1)

        let posting = try MacAgentSource.region(of: delegate, from: "viewModel.approvalParked", to: ".store(in: &cancellables)")
        #expect(MacAgentSource.count(of: "target: target", inText: posting) == 1)

        let service = try MacAgentSource.read("SonnyNotificationService.swift")
        let post = try MacAgentSource.braceBlock(
            of: service,
            openedBy: "func postPermissionNotification(resource: String, target: ApprovalTarget) {"
        )
        #expect(MacAgentSource.count(of: "target.notificationUserInfo", inText: post) == 1)
        let received = try MacAgentSource.region(of: service, from: "didReceive response", to: "case SonnyNotificationAction.retry:")
        #expect(
            MacAgentSource.count(
                of: "ApprovalTarget(notificationUserInfo: response.notification.request.content.userInfo)",
                inText: received
            ) == 1
        )
        #expect(MacAgentSource.count(of: "self?.onAllow(approvalTarget)", inText: received) == 1)
    }
}

/// The notification's half of an approval's address, written and read back (F3 of PR #279's
/// review). A mismatch between the two turns every banner's Allow into a silent refusal — the safe
/// direction, and still a dead control — with nothing else in the suite noticing.
@Suite
struct ApprovalNotificationRoundTripTests {
    @Test
    func anAddressWrittenIntoANotificationReadsBackAsTheSameAddress() throws {
        let one = ApprovalTarget(runID: RunID(), token: UUID())
        let other = ApprovalTarget(runID: RunID(), token: UUID())
        #expect(ApprovalTarget(notificationUserInfo: one.notificationUserInfo) == one)
        #expect(ApprovalTarget(notificationUserInfo: other.notificationUserInfo) == other)
        // The run is written from its UUID, so nothing about how a `RunID` prints can move it.
        #expect(Set(one.notificationUserInfo.values) == [one.runID.value.uuidString, one.token.uuidString])
    }

    @Test
    func aNotificationThatCarriesNoReadableAddressAnswersNothing() {
        let target = ApprovalTarget(runID: RunID(), token: UUID())
        let written = target.notificationUserInfo
        #expect(ApprovalTarget(notificationUserInfo: [:]) == nil)
        for key in written.keys {
            var missingOne: [AnyHashable: Any] = written
            missingOne[key] = nil
            #expect(ApprovalTarget(notificationUserInfo: missingOne) == nil, "read with \(key) missing")

            var malformed: [AnyHashable: Any] = written
            malformed[key] = "not a uuid"
            #expect(ApprovalTarget(notificationUserInfo: malformed) == nil, "read with \(key) malformed")

            var wrongType: [AnyHashable: Any] = written
            wrongType[key] = 7
            #expect(ApprovalTarget(notificationUserInfo: wrongType) == nil, "read with \(key) not a string")
        }
    }

    /// The two halves are read from their own keys: an address with its halves swapped reads back
    /// as a different address, which `approveParkedRun` then refuses like any other stranger.
    @Test
    func theRunAndTheTokenAreReadFromTheirOwnKeys() throws {
        let target = ApprovalTarget(runID: RunID(), token: UUID())
        let written = target.notificationUserInfo
        // `#require`, not `#expect`: the subscripts below would trap on a shorter dictionary and take
        // the whole test process down with them, which costs every other test its verdict.
        try #require(written.count == 2)
        let keys = Array(written.keys)
        var swapped: [AnyHashable: Any] = [:]
        swapped[keys[0]] = written[keys[1]]
        swapped[keys[1]] = written[keys[0]]
        let readBack = try #require(ApprovalTarget(notificationUserInfo: swapped))
        #expect(readBack.runID == RunID(target.token))
        #expect(readBack.token == target.runID.value)
        #expect(readBack != target)
    }
}

@MainActor
private func slot(_ id: RunID, in viewModel: AgentViewModel) -> RunSlot? {
    viewModel.runSlots.first { $0.id == id }
}

/// A draft whose file depends on the command, so two runs park two approvals over two files and the
/// file that changed says which run an approval reached.
private struct PerCommandDraftPlanner: Planning {
    let folder: URL

    func plan(command: String, priorTaskContext: PriorTaskContext?) async throws -> AgentPlan {
        let name = command.localizedCaseInsensitiveContains("beta") ? "beta" : "alpha"
        return AgentPlan(
            summary: "Draft \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "draft",
                    operation: .createLocalDraft,
                    description: "Draft \(name).",
                    outputPath: folder.appendingPathComponent("\(name).md").path,
                    draftTitle: "Notes",
                    draftContent: "Outline for \(name)."
                )
            ]
        )
    }
}
