import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MacAgent
// `@testable` rather than a plain import so this target can reach
// `RoutineStore.saveBypassingStepValidation`, the module-internal test-only write path SONNY-52
// added. Keeping that method internal is the point — nothing outside `MacAgentCore` may write a
// routine the store would refuse, and a test target reaching in through `@testable` is not the
// same thing as the app being able to.
@testable import MacAgentCore

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
    func newTaskMenuItemRoutesThroughTheSharedWidgetPresentationRequest() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let delegate = AppDelegate(viewModel: viewModel)

        let menu = delegate.makeStatusMenu()
        #expect(menu.items.map(\.title) == ["New Task", "", "Open Sonny", "", "Quit Sonny"])

        // Titles alone pin nothing about wiring: an item rewired to a different selector keeps its
        // title and a title-only assertion stays green. Every item gets its target, selector, and
        // key equivalent asserted — ⌘Q in particular, since app-wide Quit was menu-routed and
        // silently broken once already (see `makeMainMenu()`'s comment).
        let expectedItems: [(title: String, action: Selector, keyEquivalent: String)] = [
            ("New Task", #selector(AppDelegate.requestWidgetPresentation), ""),
            ("Open Sonny", #selector(AppDelegate.openCommandCenter), ""),
            ("Quit Sonny", #selector(AppDelegate.quit), "q")
        ]
        for expected in expectedItems {
            let item = try #require(menu.items.first { $0.title == expected.title })
            #expect(item.target === delegate)
            #expect(item.action == expected.action)
            #expect(item.keyEquivalent == expected.keyEquivalent)
        }

        let newTask = try #require(menu.items.first { $0.title == "New Task" })
        let action = try #require(newTask.action)
        #expect(viewModel.widgetPresentationRequest == 0)

        // Dispatched through the menu item's own target/selector exactly as AppKit would, rather
        // than calling the method directly: the bug this pins was a wiring bug (the item reached
        // `widgetController.show()`, which fronts the panel and cannot touch keyboard focus), so
        // the wiring is half of what needs asserting.
        _ = (newTask.target as? NSObject)?.perform(action)
        #expect(viewModel.widgetPresentationRequest == 1)

        _ = (newTask.target as? NSObject)?.perform(action)
        #expect(viewModel.widgetPresentationRequest == 2)
    }

    @Test
    func pushToTalkPressSharesTheMenuItemsWidgetPresentationPath() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let delegate = AppDelegate(viewModel: viewModel)

        // A run already in flight makes `canUseVoice` false whether or not the test host happens to
        // have OPENAI_API_KEY exported, so `beginPushToTalkVoice()` returns before it can reach the
        // microphone — deterministic, and it pins the more interesting half: the widget is asked to
        // come forward even when voice itself refuses to start, since that request is what puts the
        // resulting error on screen.
        viewModel.isRunning = true

        delegate.handlePushToTalkPress()
        #expect(viewModel.widgetPresentationRequest == 1)
        #expect(viewModel.isRecordingVoice == false)
        #expect(viewModel.isPreparingVoiceRecording == false)

        delegate.handlePushToTalkPress()
        #expect(viewModel.widgetPresentationRequest == 2)

        // Releasing is presentation-neutral — only the press half brings the widget forward.
        delegate.handlePushToTalkRelease()
        #expect(viewModel.widgetPresentationRequest == 2)
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

    // MARK: - Per-task workspace binding (SONNY-38)
    //
    // The binding is what makes the rejected persistent "active workspace" survivable, and the
    // entire difference between the two designs is lifecycle — so the lifecycle is what these
    // assert, not just the happy path.

    /// AC1 — a command naming a saved workspace binds to it; one naming none does not.
    @Test
    func aCommandNamingASavedWorkspaceBindsToItAndOneNamingNoneDoesNot() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let record = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(record)
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Research"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // `lastAssessedScope` rather than `activeTaskScope`: the live binding is correctly
        // `.unscoped` again by now, so the value the assessment actually used is what to check.
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: record)))

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
    }

    /// AC3 — **the test that protects the rejected persistent-active-workspace decision.** It is not
    /// incidental coverage: a second command issued immediately after a bound task must run
    /// unscoped, because inheriting the previous task's workspace is precisely the leak that design
    /// was turned down for. If this ever passes only because the second command happens to name
    /// nothing, it has stopped testing what it exists for.
    @Test
    func aSecondCommandAfterABoundTaskRunsUnscopedAndNeverInheritsTheBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Research"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.activeTaskScope == .unscoped)  // AC2: cleared on completion.

        viewModel.command = "= 2 + 2"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// AC2's failure path, asserted on its own. An earlier version used a command the instant
    /// resolver could not handle, so it threw in the planner at `try OpenAIPlanner(...)` — *before*
    /// scope resolution — and `activeTaskScope` was `.unscoped` throughout whether or not anything
    /// cleared it. The task has to bind first and fail after.
    ///
    /// The failure lands in `performApproval`'s generic catch, which is the post-binding failure
    /// actually reachable from a test: inside `performStart` the plan, the binding and the first
    /// assessment all happen in one synchronous stretch, so there is no window to make an
    /// already-bound task fail there. This pins `performApproval`'s clear — deleting it reddens
    /// exactly this test. `performStart`'s own terminal clear is pinned separately by
    /// `aSecondCommandAfterABoundTaskRunsUnscopedAndNeverInheritsTheBinding`, whose completion path
    /// runs through the same guarded defer.
    @Test
    func theBindingClearsWhenABoundTaskFails() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .openURL, description: "In scope.", targetURL: "https://github.com/sonny")
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // Bound, and paused on `run_routine`'s tier-2 confirmation — the premise, guarded.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.activeTaskScope != .unscoped)

        // Now make the run fail after the binding exists: the routine it names is gone, so the
        // re-assessment inside `execute` throws rather than escalating.
        try fixture.routineStore.delete(routineNamed: "Morning")

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.errorMessage != nil)
        #expect(!viewModel.isAwaitingApproval)
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// AC2's cancellation path — the third of the three separate assertions the criterion requires.
    /// The clear it pins is the one whose own code comment calls it "the exact leak the rejected
    /// persistent-active-workspace design was rejected for", and nothing pinned it before.
    @Test
    func theBindingClearsWhenABoundTaskIsCancelled() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.workspaceStore.save(StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: []))
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Drafting"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.activeTaskScope != .unscoped)

        viewModel.cancelCurrentRun()

        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// F6 — the other half of the unresolvable-name branch. A name that resolves to no stored record
    /// must bind `.unscoped`, **not** a scoped-but-empty `WorkspaceScope`: an empty scope reports
    /// `.unconstrained` for every kind and would read as "a workspace that restricts nothing" rather
    /// than "no workspace at all". Only reachable through `start(workspaceBinding:)`, so it goes live
    /// with B4's card dispatch.
    @Test
    func aBindingNamingAWorkspaceThatNoLongerExistsResolvesToUnscopedNotAnEmptyScope() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.refreshSavedItems()

        viewModel.command = "= 1 + 1"
        viewModel.start(workspaceBinding: "DeletedSinceDispatch")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.lastAssessedScope != .scoped(
            WorkspaceScope(workspace: StoredWorkspace(name: "DeletedSinceDispatch", apps: [], urls: []))
        ))
    }

    /// AC6 — a pending approval must not leave a binding behind when in-memory state is cleared.
    ///
    /// The fixture has to *actually pause*. An earlier version of this test ran "open workspace
    /// Research" while bound to Research — in scope, so it produced no escalation, auto-ran to
    /// completion, and had already cleared the binding before `deleteLocalData()` was ever called.
    /// It could not fail. This binds to Research and opens Drafting, whose stored apps fall outside
    /// Research, so the run escalates to tier 3 and genuinely sits awaiting approval. The state is
    /// reachable in the app: `deleteLocalData` guards on `!isRunning`, not `!isAwaitingApproval`.
    @Test
    func clearingInMemoryStateWithAnApprovalPendingLeavesNoStaleBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.workspaceStore.save(StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: []))
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Drafting"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // The premise, guarded rather than assumed — without this the assertion below is vacuous.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.activeTaskScope != .unscoped)

        viewModel.deleteLocalData()

        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// F1's regression test — a **re-armed** approval is a second pause, not a terminal exit, so the
    /// binding must survive it.
    ///
    /// `AgentRunner.execute` re-assesses on every call and throws `.approvalRequired` when the
    /// re-assessed tier exceeds the approved one — ordinary state drift landing between the approval
    /// and the execution. Simulated here the way it really happens: the routine is rewritten in the
    /// store while its approval sits pending, so the re-assessment sees an out-of-scope step the
    /// first one did not.
    ///
    /// Under an unconditional clear the binding is gone by the time the second approval executes,
    /// and nothing about the outcome changes — the run still proceeds, because an unscoped
    /// re-assessment can only ever be lower than the scoped one it is compared against. Only the
    /// binding itself shows it.
    @Test
    func aReArmedApprovalKeepsItsBindingBecauseARePauseIsNotATerminalExit() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        // In scope to begin with, so the first assessment is `run_routine`'s own tier 2.
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .openURL, description: "In scope.", targetURL: "https://github.com/sonny")
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest?.assessment.effectiveTier == .tier2)
        #expect(viewModel.activeTaskScope == .scoped(WorkspaceScope(workspace: research)))

        // The drift: the routine now leaves the workspace, so re-assessment lands at tier 3 — above
        // the tier 2 the user is about to approve.
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .openURL, description: "Out of scope.", targetURL: "https://example.com/page")
                ]
            )
        )

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // Re-armed rather than executed...
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest?.assessment.effectiveTier == .tier3)
        // ...and the binding is still here, which is the whole finding.
        #expect(viewModel.activeTaskScope == .scoped(WorkspaceScope(workspace: research)))
        // Nothing was opened while it sat re-armed — and this reads a fake, which is also the
        // standing proof that this fixture never reaches the real browser.
        #expect(fixture.browserOpener.openedURLs.isEmpty)

        // Approving the second time really executes, through the injected seam.
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(!viewModel.isAwaitingApproval)
        #expect(fixture.browserOpener.openedURLs.map(\.absoluteString) == ["https://example.com/page"])
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// AC4 — the scope used at `approvalRequest` is the scope used inside `execute`.
    ///
    /// This one needs the log to prove anything, and that is the point of the criterion. `execute`
    /// re-assesses fresh; if it re-assessed `.unscoped` against a scoped approval, the run would
    /// still succeed — the stale-approval guard compares an approved tier 3 against a now-lower
    /// effective tier and passes — so **no outcome differs**. The only observable trace is that the
    /// re-assessment logs its own `risk.escalated` line, and an unscoped one has no scope reason to
    /// log.
    ///
    /// The fixture is the one shape that produces an out-of-scope escalation through the instant
    /// path: bound to Research by an explicit dispatch, opening Drafting, whose own stored apps are
    /// compared against Research and fall outside it.
    @Test
    func theScopeUsedAtApprovalIsTheSameScopeUsedInsideExecute() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.workspaceStore.save(StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: []))
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Drafting"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // The scope really did fire: an out-of-scope escalation raised this to an approval.
        #expect(viewModel.isAwaitingApproval)
        let reason = "Notes is not part of the Research workspace."
        #expect(viewModel.approvalRequest?.assessment.escalations.map(\.reason).contains(reason) == true)

        let beforeApproval = viewModel.logStore.events.filter { $0.message.contains(reason) }.count
        #expect(beforeApproval == 1)

        // Approving re-enters `execute`, which assesses again and logs again.
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let afterApproval = viewModel.logStore.events.filter { $0.message.contains(reason) }.count
        #expect(afterApproval == 2)
    }

    // MARK: - "New task in this workspace" card dispatch (SONNY-39)

    /// AC1 — the card action sets the binding and raises the widget. Asserted on the view model,
    /// per this repo's rule that presentation logic needing a test leaves the view.
    ///
    /// AC2 is checkable in the same assertion: the summon is a `widgetPresentationRequest` bump,
    /// not a `FloatingWidgetWindowController.show()` call. There is no direct controller call to
    /// assert the absence of — the diff carries that — but the counter moving is the positive half.
    @Test
    func theCardDispatchBindsTheNextCommandAndRaisesTheWidget() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()
        let requestsBefore = viewModel.widgetPresentationRequest

        viewModel.beginTaskInWorkspace(research)

        #expect(viewModel.pendingWorkspaceBinding == "Research")
        #expect(viewModel.boundWorkspaceName == "Research")
        #expect(viewModel.widgetPresentationRequest == requestsBefore + 1)
        // An *empty* composer — the whole point is that the user types the task themselves, rather
        // than the synthesized "Open my X workspace" string the Open button uses.
        #expect(viewModel.command.isEmpty)
        // And nothing started.
        #expect(!viewModel.isRunning)
        #expect(viewModel.plan == nil)
    }

    /// The dispatch flows through SONNY-38's existing explicit-binding slot rather than a second
    /// path, so a command naming a *different* workspace still loses to the card — the precedence
    /// rule is inherited, not re-implemented.
    @Test
    func aCardDispatchStillBeatsAConflictingWorkspaceNamedInTheCommand() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.workspaceStore.save(drafting)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(drafting)
        viewModel.command = "open workspace Research"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: drafting)))
    }

    /// AC3 — clearing the binding leaves typed text alone. The two live on the same row, and a
    /// clear that also wiped the composer would lose work the user had already done.
    @Test
    func clearingTheBindingLeavesTheComposerTextIntact() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        viewModel.command = "half-written command"
        viewModel.clearPendingWorkspaceBinding()

        #expect(viewModel.pendingWorkspaceBinding == nil)
        #expect(viewModel.boundWorkspaceName == nil)
        #expect(viewModel.command == "half-written command")
    }

    /// AC4 — a bound composer with nothing typed submits nothing, and keeps its binding so the user
    /// can carry on typing rather than having to click the card again.
    @Test
    func submittingAnEmptyCommandFromABoundComposerDoesNothingAndKeepsTheBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.plan == nil)
        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.pendingWorkspaceBinding == "Research")
    }

    /// AC1's other half and manual item 3: the indicator is per task. It survives the hand-off from
    /// the pending slot to the in-flight binding, and disappears when the task ends — it must never
    /// become the rejected persistent "active workspace" mode.
    @Test
    func theBindingIndicatorSurvivesSubmitAndDisappearsWhenTheTaskEnds() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        try fixture.workspaceStore.save(StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: []))
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.boundWorkspaceName == "Research")

        // A command that pauses on an approval, so there is a stable in-flight window to observe.
        // Bound to Research, opening Drafting — whose stored app falls outside Research.
        viewModel.command = "open workspace Drafting"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // Mid-task: the pending slot has been consumed, so the indicator can only still be showing
        // because it falls back to the *in-flight* binding. Without that fallback the chip vanishes
        // the instant the user hits return, which is exactly when they most need to see it.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.pendingWorkspaceBinding == nil)
        #expect(viewModel.boundWorkspaceName == "Research")
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: research)))

        viewModel.cancelCurrentRun()

        // ...and it is gone now that the task is over — per task, never a mode.
        #expect(viewModel.boundWorkspaceName == nil)
        #expect(viewModel.pendingWorkspaceBinding == nil)
    }

    /// AC6 — the existing Open action is unchanged, pinned rather than inspected. It still
    /// synthesizes its own command and runs it in one click, and it leaves no pending binding
    /// behind, because it is not the card dispatch.
    @Test
    func theExistingOpenActionIsUnchangedByTheNewCardDispatch() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.openWorkspaceWidget(research)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.plan?.steps.first?.operation == .openWorkspace)
        #expect(fixture.appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(fixture.browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        #expect(viewModel.pendingWorkspaceBinding == nil)
    }

    /// AC7 — precedence. Both signals present at once, naming **different** workspaces: the card
    /// binding wins. No other criterion exercises this, so the rule could be implemented backwards
    /// and every other test here would still pass.
    @Test
    func anExplicitCardBindingWinsOverAConflictingWorkspaceNamedInTheCommand() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let card = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        try fixture.workspaceStore.save(card)
        viewModel.refreshSavedItems()

        // The command text names Research; the dispatch names Drafting.
        viewModel.command = "open workspace Research"
        viewModel.start(workspaceBinding: "Drafting")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: card)))
        #expect(viewModel.lastAssessedScope != .scoped(WorkspaceScope(workspace:
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"]))))
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
        // `.openWorkspace` is on `StoredRoutine.forbiddenStepOperations`, so `save` refuses this
        // routine (SONNY-52). The behavior under test is what the *task record* says when a run
        // descends into a routine that already contains one, which needs that state to exist on
        // disk; the sanctioned bypass is how a test says so out loud.
        try fixture.routineStore.saveBypassingStepValidation(routine)
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

    // MARK: - Cross-surface shared-state coverage (docs/sonny-manual-test-checklist.md §5) — these
    // scenarios were previously only manually verified; each targets a specific, real behavior found
    // by reading the actual implementation, not a guessed-at contract.

    @Test
    func retryLastCommandTagsOriginAsWidgetRegardlessOfOriginalOrigin() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let workspace = StoredWorkspace(name: "Research", apps: [], urls: [])
        try fixture.workspaceStore.save(workspace)
        viewModel.refreshSavedItems()

        // Command-Center-originated (the default) task that completes cleanly.
        viewModel.openWorkspaceWidget(workspace)
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.activeTaskOrigin == .commandCenter)
        #expect(viewModel.hasRetryableCommand)

        viewModel.retryLastCommand()

        // `isRunning` flips synchronously inside `start()`, before `performStart` (which sets
        // `activeTaskOrigin`) actually runs on a later turn — `CommandCenterRunningIndicator` only
        // ever gates on `isRunning || isAwaitingApproval` (see macagent-ui-conventions.md), never on
        // origin, so it should read this retried task as running immediately, regardless of what
        // origin ends up tagged.
        #expect(viewModel.isRunning)

        try await waitForViewModelToBecomeIdle(viewModel)
        // `retryLastCommand()` *defaults* to `.widget` even though the original task was
        // Command-Center-originated (see its own doc comment) — documented, deliberate behavior:
        // the retry is a fresh interaction on whichever surface it was pressed, not an inheritance
        // of the failed task's origin. Branch 10 checkpoint 1 turned the old hardcoded `.widget`
        // into a defaulted parameter when Command Center gained its own failure row; this argument-
        // less call is still the widget's own path, so the expectation is unchanged. See
        // `CommandCenterAttentionSurfaceTests` for the `.commandCenter` half.
        #expect(viewModel.activeTaskOrigin == .widget)
        #expect(viewModel.runningCommandDisplayText == "Open my Research workspace")
    }

    @Test
    func secondRowActionSubmissionIsBlockedWhileATaskIsAlreadyRunning() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let first = StoredWorkspace(name: "Research", apps: [], urls: [])
        let second = StoredWorkspace(name: "Personal", apps: [], urls: [])
        try fixture.workspaceStore.save(first)
        try fixture.workspaceStore.save(second)
        viewModel.refreshSavedItems()

        viewModel.openWorkspaceWidget(first)
        #expect(viewModel.isRunning)
        #expect(viewModel.runningCommandDisplayText == "Open my Research workspace")

        // Simulates a second row-action click (from either surface) while the first is still
        // running. Command Center's own Run/Open buttons are separately disabled on
        // `viewModel.isRunning || viewModel.isAwaitingApproval` at the UI layer
        // (CommandCenterView.swift) — this exercises the ViewModel-level guard underneath that
        // defense (`start()`'s `guard canSubmit else { return }`), not just the UI affordance.
        viewModel.openWorkspaceWidget(second)
        // Still reflects the first, unchanged — the second call never got far enough to touch
        // any shared state.
        #expect(viewModel.runningCommandDisplayText == "Open my Research workspace")

        try await waitForViewModelToBecomeIdle(viewModel)

        let records = try fixture.taskHistoryStore.loadAll()
        // Exactly one record — if the guard had failed, the second call would have raced in a
        // second, silently overlapping task.
        #expect(records.count == 1)
        #expect(records.first?.command == "Open my Research workspace")
    }

    @Test
    func cancelCurrentRunResetsWidgetRelevantStateRegardlessOfOrigin() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "snippet save ;cross-surface-test = Hello"

        // Default origin is `.commandCenter` — simulates a task a Command-Center-only entry point
        // (a row action) started, reaching the exact state only the widget renders controls for:
        // "Command Center itself has no approval/permission UI of its own" (macagent-ui-conventions.md).
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.activeTaskOrigin == .commandCenter)
        #expect(viewModel.approvalRequest != nil)
        #expect(viewModel.isAwaitingApproval)

        // `cancelCurrentRun()` is the one shared method both surfaces' Cancel controls call —
        // this proves it correctly resets every piece of state the widget's own panel-gating logic
        // reads, even though the task itself was never `.widget`-origin.
        viewModel.cancelCurrentRun()

        #expect(viewModel.approvalRequest == nil)
        #expect(!viewModel.isAwaitingApproval)
        #expect(!viewModel.isRunning)
        #expect(viewModel.finalSummary == "Approval canceled. No action was taken.")
    }

    @Test
    func activityPresentationHidesInternalOperationAndPhaseNames() {
        let step = AgentStep(
            id: "calculate",
            operation: .calculateUtility,
            description: ""
        )
        #expect(AgentActivityPresentation.planStepTitle(step) == "Calculate")
        #expect(AgentActivityPresentation.planStepTitle(step) != AgentOperation.calculateUtility.rawValue)
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

        // An unscheduled routine keeps the step summary on its second line — the cadence label
        // that replaced it for scheduled routines has nothing to show here.
        let routinePresentation = RoutineRowPresentation(routine: routine, now: Date())
        #expect(routinePresentation.name == "Morning planning")
        #expect(routinePresentation.detailText == "Open Safari · Create draft · +1 more")
        #expect(routinePresentation.isScheduleable == false)
        #expect(routinePresentation.nextRunText == nil)
        #expect(routinePresentation.streak == nil)

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

    @Test
    func deletingARoutineRemovesItFromTheSharedViewModelAndTheStore() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [productShellInertStep]))
        try fixture.routineStore.save(StoredRoutine(name: "Evening", steps: [productShellInertStep]))
        fixture.viewModel.refreshSavedItems()

        fixture.viewModel.deleteRoutine(try fixture.routineStore.routine(named: "Morning"))

        #expect(fixture.viewModel.savedRoutines.map(\.name) == ["Evening"])
        #expect(try fixture.routineStore.loadAll().keys.sorted() == ["evening"])
        #expect(fixture.viewModel.errorMessage == nil)
    }

    /// The in-flight guard covers both halves of "a task is in flight" — a run in progress and a
    /// run parked at an approval — because an approved run re-reads the store when it resumes.
    /// `deleteLocalData` guards only `isRunning`; these pin that the delete methods deliberately
    /// use the broader condition every other in-flight gate already uses.
    @Test
    func deletingARoutineWhileATaskIsRunningIsRefused() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [productShellInertStep]))
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.isRunning = true

        fixture.viewModel.deleteRoutine(try fixture.routineStore.routine(named: "Morning"))

        #expect(fixture.viewModel.errorMessage?.contains("Finish or stop the current task") == true)
        #expect(try fixture.routineStore.loadAll().count == 1)
    }

    @Test
    func deletingARoutineWhileAwaitingApprovalIsRefused() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.routineStore.save(StoredRoutine(name: "Morning", steps: [productShellInertStep]))
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.approvalRequest = RiskApprovalRequest(
            assessment: CapabilityRiskAssessment(defaultTier: .tier2),
            requirement: .explicitApproval
        )

        fixture.viewModel.deleteRoutine(try fixture.routineStore.routine(named: "Morning"))

        #expect(fixture.viewModel.errorMessage?.contains("Finish or stop the current task") == true)
        #expect(try fixture.routineStore.loadAll().count == 1)
    }

    @Test
    func deletingAWorkspaceRemovesItFromTheSharedViewModelAndTheStore() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        try fixture.workspaceStore.save(StoredWorkspace(name: "Client Work", apps: ["Mail"], urls: []))
        fixture.viewModel.refreshSavedItems()

        fixture.viewModel.deleteWorkspace(try fixture.workspaceStore.workspace(named: "Research"))

        #expect(fixture.viewModel.savedWorkspaces.map(\.name) == ["Client Work"])
        #expect(try fixture.workspaceStore.loadAll().keys.sorted() == ["client work"])
        #expect(fixture.viewModel.errorMessage == nil)
    }

    @Test
    func deletingAWorkspaceWhileATaskIsRunningIsRefused() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.isRunning = true

        fixture.viewModel.deleteWorkspace(try fixture.workspaceStore.workspace(named: "Research"))

        #expect(fixture.viewModel.errorMessage?.contains("Finish or stop the current task") == true)
        #expect(try fixture.workspaceStore.loadAll().count == 1)
    }

    @Test
    func deletingAWorkspaceWhileAwaitingApprovalIsRefused() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.workspaceStore.save(StoredWorkspace(name: "Research", apps: ["Safari"], urls: []))
        fixture.viewModel.refreshSavedItems()
        fixture.viewModel.approvalRequest = RiskApprovalRequest(
            assessment: CapabilityRiskAssessment(defaultTier: .tier2),
            requirement: .explicitApproval
        )

        fixture.viewModel.deleteWorkspace(try fixture.workspaceStore.workspace(named: "Research"))

        #expect(fixture.viewModel.errorMessage?.contains("Finish or stop the current task") == true)
        #expect(try fixture.workspaceStore.loadAll().count == 1)
    }

}

private let productShellInertStep = AgentStep(
    id: "calc",
    operation: .calculateUtility,
    description: "Calculate 1 + 1.",
    searchQuery: "1 + 1"
)

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
    userDefaultsSuiteName: String,
    browserOpener: HermeticBrowserOpener,
    appOpener: HermeticAppOpener
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
    userDefaultsSuiteName: String,
    browserOpener: HermeticBrowserOpener,
    appOpener: HermeticAppOpener
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
    let browserOpener = HermeticBrowserOpener()
    let appOpener = HermeticAppOpener()
    let fileOpener = HermeticFileOpener()
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
        // Hermetic seams — see the fakes at the bottom of this file. Without these the suite
        // launches real apps and opens real URLs in the user's browser.
        browserOpener: browserOpener,
        appOpener: appOpener,
        fileOpener: fileOpener,
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
    return (viewModel, root, routineStore, workspaceStore, taskHistoryStore, userDefaults, suiteName, browserOpener, appOpener)
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

// MARK: - Hermetic side-effect seams
//
// `AgentViewModel.makeExecutor()` used to construct `AgentActionExecutor` without any of its
// side-effect services, so every one fell to its production default and any view-model test that
// *executed* a plan drove the real machine — the suite genuinely launched Safari and opened
// https://github.com and https://example.com/page in the user's browser. `AgentActionExecutor`
// already accepted all nine as parameters; only the view-model construction path skipped them.
//
// These record rather than merely swallow, so a test that wants to assert what a run actually
// opened can, and so a fixture that silently stopped being injected would show up as an empty
// recording rather than as a browser window.

@MainActor
final class HermeticBrowserOpener: BrowserOpening {
    private(set) var openedURLs: [URL] = []
    private(set) var openedBrowsers: [MacApp?] = []
    func open(_ url: URL, using browser: MacApp?) async throws {
        openedURLs.append(url)
        openedBrowsers.append(browser)
    }
}

@MainActor
final class HermeticAppOpener: AppOpening {
    private(set) var openedBundleIDs: [String] = []
    func open(bundleIdentifier: String) async throws {
        openedBundleIDs.append(bundleIdentifier)
    }
}

@MainActor
final class HermeticFileOpener: FileOpening {
    private(set) var openedFiles: [URL] = []
    func openFile(_ url: URL) async throws {
        openedFiles.append(url.standardizedFileURL)
    }
}

@MainActor
final class HermeticMediaOpener: MediaOpening {
    private(set) var requests: [MediaPlaybackRequest] = []
    func open(_ request: MediaPlaybackRequest) async throws -> String {
        requests.append(request)
        return "Played (fake)."
    }
}

@MainActor
final class HermeticRunningAppSwitcher: RunningAppSwitching {
    private(set) var activated: [String] = []
    func runningApps() -> [RunningApp] { [] }
    func activate(bundleIdentifier: String) async throws { activated.append(bundleIdentifier) }
}

final class HermeticShortcutInvoker: ShortcutInvoking, @unchecked Sendable {
    func invokeShortcut(name: String, input: String?) async throws -> ProcessResult {
        ProcessResult(terminationStatus: 0, output: "")
    }
}

final class HermeticFinderContextReader: FinderContextReading, @unchecked Sendable {
    func selectedItems() throws -> [URL] { [] }
}

final class HermeticDocumentConverter: DocumentConverting, @unchecked Sendable {
    var isAvailable: Bool { false }
    var modeName: String { "fake" }
    var usesMockNaming: Bool { true }
    func convert(_ records: [DocxRecord], log: @escaping (String) -> Void) async throws -> [DocxRecord] { records }
}

final class HermeticZipArchiver: ZipArchiving, @unchecked Sendable {
    func createArchive(sourceFolder: URL, files: [URL], outputURL: URL) async throws {}
}
