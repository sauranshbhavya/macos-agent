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
        // The routine's draft output already exists, so the run pauses on the destructive
        // collision — the pause the consequence rule still has. (This fixture used the tier-2
        // routine confirmation before the rule; the lifecycle claim is unchanged.)
        let occupied = fixture.root.appendingPathComponent("draft.md")
        try "existing draft".write(to: occupied, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "a",
                        operation: .createLocalDraft,
                        description: "Draft notes.",
                        outputPath: occupied.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    )
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // Bound, and paused on the destructive collision — the premise, guarded.
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
        // Paused on a destructive collision (the pause the consequence rule still has), bound to
        // Research by the explicit dispatch.
        let occupied = fixture.root.appendingPathComponent("draft.md")
        try "existing draft".write(to: occupied, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "a",
                        operation: .createLocalDraft,
                        description: "Draft notes.",
                        outputPath: occupied.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    )
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
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
    /// The fixture has to *actually pause*. An earlier version of this test ran an in-scope
    /// command — no pause, so it could not fail. Under the consequence rule the pause that still
    /// exists is the destructive one, so the bound run collides on an existing draft output and
    /// genuinely sits awaiting approval. The state is reachable in the app: `deleteLocalData`
    /// guards on `!isRunning`, not `!isAwaitingApproval`.
    @Test
    func clearingInMemoryStateWithAnApprovalPendingLeavesNoStaleBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        let occupied = fixture.root.appendingPathComponent("draft.md")
        try "existing draft".write(to: occupied, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "a",
                        operation: .createLocalDraft,
                        description: "Draft notes.",
                        outputPath: occupied.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    )
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // The premise, guarded rather than assumed — without this the assertion below is vacuous.
        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.activeTaskScope != .unscoped)

        viewModel.deleteLocalData()

        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// **The forcing function for `clearInMemoryLocalDataState`'s hand-written enumeration.**
    ///
    /// That enumeration has now been missed three times, always the same way: a new stored property
    /// lands on `AgentViewModel`, nothing connects it to the local-data wipe, and the wipe keeps
    /// showing the deleted data's leftovers. `explicitWorkspaceBinding` (SONNY-38's review),
    /// `pendingWorkspaceBinding` (a new binding field one ticket later), and `ranWithoutAskingTrace`
    /// (SONNY-99, filed by PR #48's review as F1 — the trace rendered "nothing here is destructive"
    /// under the deletion summary). Three of one class is a missing test, not three unlucky editors:
    /// the compiler cannot see the omission, and a reviewer only sees it by reading the wipe against
    /// the whole class, which is exactly the reading nobody does by default.
    ///
    /// This test is that reading, made automatic. It reflects over the *real* instance, so a new
    /// stored property appears in the population the moment it is declared, and it requires every
    /// one to sit in exactly one of three named sets. A fourth omission is a red test naming the
    /// field, not a fourth review finding.
    ///
    /// **What it claims, precisely.** It pins *classification*, not behaviour. `clearedByTheWipe` is
    /// cross-checked against the function's real source in both directions — a clear that is not
    /// listed fails, and a listing that is not cleared fails — so that set cannot drift from the
    /// code. The other two sets are decisions recorded with their reasons; whether a given decision
    /// is the *right* one is what the behavioural tests around the wipe are for
    /// (`deletingAllLocalDataClearsTheRanWithoutAskingTrace…`,
    /// `clearingInMemoryStateWithAnApprovalPendingLeavesNoStaleBinding`). What this removes is the
    /// silent fourth option: landing a field and never deciding at all.
    @Test
    func everyAgentViewModelStoredPropertyIsClassifiedAgainstTheLocalDataWipe() throws {
        // Assigned by `clearInMemoryLocalDataState` itself. Cross-checked against the real source
        // below, so this list cannot say something the function does not do.
        let clearedByTheWipe: Set<String> = [
            "plan",
            "suggestions",
            "approvalRequest",
            "stepStatuses",
            "priorTaskContext",
            "taskUsageSummary",
            "taskHistoryRecords",
            "taskHistoryQuery",
            "completedRunNotice",
            "taskDetailRequest",
            "outcomeWasNotified",
            "clarificationQuestion",
            "clarificationAnswer",
            "clarificationAutoExecute",
            "clarificationWorkspaceBinding",
            "activeTaskScope",
            "ranWithoutAskingTrace",
            "explicitWorkspaceBinding",
            "pendingWorkspaceBinding",
            "preparedRun",
            "runner",
            "pendingCommandForPriorTaskContext",
            "pendingTaskHistoryStartedAt",
            "preserveUsageForNextStart"
        ]

        // Not assigned by the wipe, but rewritten by the three `refresh…` calls it ends with — from
        // stores whose files the deletion has just emptied, so they come back as the empty truth
        // rather than as stale values. Covered, by a different mechanism.
        let reloadedByTheWipe: Set<String> = [
            "savedRoutines",              // refreshSavedItems()
            "savedWorkspaces",            // refreshSavedItems()
            "clipboardHistoryEnabled",    // refreshClipboardHistoryNotice()
            "clipboardHistoryTimer",      // ditto, via start/stopClipboardHistoryMonitoring()
            "localStorageLoadFailures",   // record/clearLocalStorageLoadFailure, inside all three
            "localStorageNotice"          // ditto, via refreshLocalStorageNotice()
        ]

        // Deliberately untouched, in four groups.
        let outsideTheWipe: Set<String> = [
            // 1. Injected collaborators, timers and observers — not state about a task. (The wipe
            // does reset the *contents* of `logStore`, `priorTaskContextStore` and
            // `taskUsageRecorder` through their own APIs; the properties themselves are the
            // collaborators, not the state.) A new dependency belongs here.
            "logStore", "currentTask", "audioRecorder", "permissionReadinessService",
            "routineStore", "workspaceStore", "snippetStore", "recentArtifactStore",
            "shortcutCatalog", "browserOpener", "appOpener", "fileOpener", "mediaOpener",
            "runningAppSwitcher", "shortcutInvoker", "finderContextReader", "documentConverter",
            "zipArchiver", "shortcutRunHistoryStore", "taskHistoryStore",
            "clipboardHistorySettingsStore", "clipboardHistoryMonitor", "localDataDeletionService",
            "priorTaskContextStore", "taskUsageRecorder", "plannerProviderRegistry",
            "plannerSelection", "userDefaults", "whitelist", "routineScheduleTimer", "wakeObserver",

            // 2. Written by `deleteLocalData` itself, immediately after the wipe returns. Clearing
            // them inside the wipe would be undone one line later.
            "finalSummary", "errorMessage", "localDataDeletionStatusMessage",

            // 3. Settings, preferences and readiness — none of it is local *data*, and a wipe that
            // silently reset the user's preferences would be a different feature.
            "errorIsPersistent", "usePointerCursors", "displayFullNames", "interactionMode",
            "voiceHotKeyStatus", "voiceHotKeyReady", "permissionItems", "clipboardHistoryPollFailure",
            "hasCompletedFirstApproval", "widgetPresentationRequest", "scheduledRunNotice",
            "plannerFallbackNotice",

            // 4. Live-interaction state that cannot be stale when the wipe runs, plus the two slots
            // whose whole purpose is outliving a task. `deleteLocalData` guards on `!isRunning`, so
            // the in-flight voice/run flags are already at rest. `lastCommand` and `command` are the
            // user's own text, not a task artifact. `lastAssessedScope` is documented at its
            // declaration as deliberately never cleared — `retryLastCommand` reads it after the live
            // binding is gone, and a workspace name the store no longer has resolves to `.unscoped`
            // anyway.
            // `taskRecordingPolicy` sits here with `command` for the same reason: it is the
            // user's own pending instruction for the next task, not a task artifact. The wipe
            // guards on `!isRunning`, so no suppressed run is in flight, and silently switching
            // "Don't save this task" back off because someone erased their history would discard a
            // choice they deliberately made. It is reset by `finishRecordingPolicyIfSettled()` on
            // every terminal state instead.
            "command", "lastCommand", "isRunning", "activeTaskOrigin", "lastAssessedScope",
            "taskRecordingPolicy",
            "isPreparingVoiceRecording", "isRecordingVoice", "isTranscribingVoice",
            "isPushToTalkHotKeyDown", "voiceRecordingOrigin", "clarificationOrigin",
            "scheduledRunDisplayCommand",

            // 5. Row I's vision-session state, all four slots of it. Same reasoning as the
            // in-flight voice flags above, and it holds harder here: `deleteLocalData` guards on
            // `!isRunning`, and every one of these can only be non-nil while a session is live —
            // the two continuations are literally a suspended loop, and the preview and progress
            // are cleared in `performStart`'s own `defer` on every exit. `visionSessionEnvironment`
            // is not task state at all: it is the injected substrate seam, infrastructure like
            // `whitelist` in group 1, and wiping it would leave the app unable to run a session
            // until relaunch.
            "visionCapturePreview", "visionSessionProgress", "visionApprovalContinuation",
            "visionCaptureContinuation", "visionSessionEnvironment",
            "visionDelegationRequest", "visionDelegationContinuation",
            "visionSessionPause", "visionResumeContinuation",
            "visionUserPauseMonitor", "visionEmergencyStopHotKey", "visionEmergencyStopHotKeyFactory",
            "visionSessionJournalStore", "activeVisionSessionID",

            // 6. A test seam, not state — `nil` in the shipping app, and nothing in `Sources/`
            // assigns it. Same category as `visionSessionEnvironment` in group 5: it lets a test
            // describe the world rather than inherit it, and it holds no user data for a wipe to
            // find. (SONNY-173.)
            "voiceConfigurationBlockerOverride"
        ]

        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The population: every stored property of the real instance, published or not. Property
        // wrappers store under a leading underscore, so `_plan` is `plan`.
        let stored = Set(
            Mirror(reflecting: fixture.viewModel).children
                .compactMap(\.label)
                .map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
        )
        #expect(
            stored.count > 60,
            "Reflection saw \(stored.count) stored properties — too few to be the real view model."
        )

        // `clearedByTheWipe` against the function's real body, both directions.
        let assigned = try Self.assignmentsInClearInMemoryLocalDataState()
        #expect(
            assigned == clearedByTheWipe,
            """
            `clearInMemoryLocalDataState` and this test's `clearedByTheWipe` list disagree.
            Cleared in the function but not listed here: \(assigned.subtracting(clearedByTheWipe).sorted()).
            Listed here but not cleared in the function: \(clearedByTheWipe.subtracting(assigned).sorted()).
            """
        )

        // The three sets partition the population: no field in two of them, none in none of them.
        #expect(clearedByTheWipe.isDisjoint(with: reloadedByTheWipe))
        #expect(clearedByTheWipe.isDisjoint(with: outsideTheWipe))
        #expect(reloadedByTheWipe.isDisjoint(with: outsideTheWipe))

        let classified = clearedByTheWipe.union(reloadedByTheWipe).union(outsideTheWipe)
        #expect(
            stored.subtracting(classified).isEmpty,
            """
            `AgentViewModel` has stored properties this test was never told about: \
            \(stored.subtracting(classified).sorted()).
            Put each one in exactly one of `clearedByTheWipe`, `reloadedByTheWipe` or \
            `outsideTheWipe`, with its reason — and if it is per-task state a surface renders, add \
            the clear to `clearInMemoryLocalDataState` too. This check exists because that \
            enumeration has already been missed three times.
            """
        )
        #expect(
            classified.subtracting(stored).isEmpty,
            """
            This test names properties `AgentViewModel` no longer has: \
            \(classified.subtracting(stored).sorted()). Remove them from their set.
            """
        )
    }

    /// SONNY-99's differential-signal rule at the real dispatch surface: a tier-1 run always ran
    /// silently, so a ran-without-asking trace on it would mark a silence that was always ordinary
    /// and teach the user to ignore the one that matters. The silence has to stay ordinary silence.
    @Test
    func aTierOneRunInsideItsOwnWorkspaceLeavesNoRanWithoutAskingTrace() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.command = "open workspace Research"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // Premises, guarded rather than assumed: the run was bound to its own workspace, completed
        // without any prompt, and really opened things through the hermetic seams.
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: research)))
        #expect(!viewModel.isAwaitingApproval)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.finalSummary.isEmpty)

        #expect(viewModel.ranWithoutAskingTrace == nil)
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
        // Paused on one destructive collision to begin with. (Before the consequence rule this
        // fixture paused on the tier-2 routine confirmation and drifted upward to tier 3; a pause
        // now already means tier 3, so the drift below is a second reason at equal tier — the
        // shape SONNY-62's reason axis exists for.)
        let draftA = fixture.root.appendingPathComponent("a.md")
        let draftB = fixture.root.appendingPathComponent("b.md")
        try "existing a".write(to: draftA, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .createLocalDraft, description: "Draft A.", outputPath: draftA.path, draftTitle: "A", draftContent: "Body A.")
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest?.assessment.effectiveTier == .tier3)
        #expect(viewModel.activeTaskScope == .scoped(WorkspaceScope(workspace: research)))

        // The drift: a second colliding draft the user was never shown, landing while the prompt
        // sits open.
        try "existing b".write(to: draftB, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .createLocalDraft, description: "Draft A.", outputPath: draftA.path, draftTitle: "A", draftContent: "Body A."),
                    AgentStep(id: "b", operation: .createLocalDraft, description: "Draft B.", outputPath: draftB.path, draftTitle: "B", draftContent: "Body B.")
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
        // Nothing was written while it sat re-armed.
        #expect(try String(contentsOf: draftA, encoding: .utf8) == "existing a")

        // Approving the second time really executes.
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(!viewModel.isAwaitingApproval)
        #expect(try String(contentsOf: draftA, encoding: .utf8) != "existing a")
        #expect(try String(contentsOf: draftB, encoding: .utf8) != "existing b")
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// SONNY-62, at the surface it was observed on: the approval the user answered names one
    /// tier-3 reason, and by the time they tap Allow the run's *actual* reason is a different one
    /// — equal tier, disjoint reason — so it must stop again instead of riding the first approval.
    ///
    /// Before the consequence rule this fixture drifted between two *out-of-scope* reasons; those
    /// are advisory now and never prompt, so the drift that still reaches a human is between two
    /// destructive reasons — which is also exactly the shape of the original SONNY-62 field
    /// observation ("the draft output already exists" appearing behind an answered prompt).
    ///
    /// It also pins the write-back, which is half the fix and lives in this file: if
    /// `performApproval` recorded a bare tier instead of the request the user answered, the engine
    /// would have nothing to compare and this would execute.
    @Test
    func approvingOneDestructiveReasonDoesNotAuthorizeADifferentOneThatReplacesIt() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: [], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        let draftA = fixture.root.appendingPathComponent("a.md")
        let draftB = fixture.root.appendingPathComponent("b.md")
        try "existing a".write(to: draftA, atomically: true, encoding: .utf8)
        try "existing b".write(to: draftB, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .createLocalDraft, description: "Draft A.", outputPath: draftA.path, draftTitle: "A", draftContent: "Body A.")
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest?.assessment.effectiveTier == .tier3)
        #expect(viewModel.approvalRequest?.assessment.escalations.map(\.reason) == [
            "Draft output already exists at \(draftA.path)."
        ])

        // The drift: the routine now collides on a *different* file. Tier 3 either way — the
        // approval on screen is worth exactly as much as before, and covers none of what is now
        // about to happen.
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "b", operation: .createLocalDraft, description: "Draft B.", outputPath: draftB.path, draftTitle: "B", draftContent: "Body B.")
                ]
            )
        )

        // The Allow tap.
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest?.assessment.effectiveTier == .tier3)
        #expect(viewModel.approvalRequest?.assessment.escalations.map(\.reason) == [
            "Draft output already exists at \(draftB.path)."
        ])
        // Nothing was written while it sat re-armed.
        #expect(try String(contentsOf: draftB, encoding: .utf8) == "existing b")
        // A second pause, so the binding is still the one the run was assessed under (the invariant
        // the test above owns, re-checked here because this re-arm arrives by a different route).
        #expect(viewModel.activeTaskScope == .scoped(WorkspaceScope(workspace: research)))

        // Answering the re-armed prompt runs it: one extra question, not a loop.
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(!viewModel.isAwaitingApproval)
        #expect(try String(contentsOf: draftB, encoding: .utf8) != "existing b")
        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// AC4 — the scope used at `approvalRequest` is the scope used inside `execute`.
    ///
    /// This one needs the log to prove anything, and that is the point of the criterion. `execute`
    /// re-assesses fresh; if it re-assessed `.unscoped` against a scoped approval, the run would
    /// still proceed — the destructive reason alone still covers it — so **no outcome differs**.
    /// The only observable trace is that the re-assessment logs its own `risk.escalated` line for
    /// the scope reason, and an unscoped one has no scope reason to log.
    ///
    /// The fixture pairs the out-of-scope fact (advisory — it cannot pause anything on its own
    /// under the consequence rule) with a destructive draft collision, so the run genuinely pauses
    /// and the prompt's assessment carries the scope reason beside the destructive one. Approving
    /// re-enters `execute`, which must assess under the same scope and log the scope reason a
    /// second time.
    @Test
    func theScopeUsedAtApprovalIsTheSameScopeUsedInsideExecute() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.workspaceStore.save(
            StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        )
        let occupied = fixture.root.appendingPathComponent("draft.md")
        try "existing draft".write(to: occupied, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(id: "a", operation: .openURL, description: "Out of scope.", targetURL: "https://example.com/page"),
                    AgentStep(
                        id: "b",
                        operation: .createLocalDraft,
                        description: "Draft notes.",
                        outputPath: occupied.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    )
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.command = "run routine Morning"
        viewModel.start(workspaceBinding: "Research")
        try await waitForViewModelToBecomeIdle(viewModel)

        // Paused on the destructive collision, with the scope's advisory reason on the same
        // assessment — the scope really was applied.
        #expect(viewModel.isAwaitingApproval)
        let reason = "example.com is not part of the Research workspace."
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
        viewModel.start(origin: .widget, fromComposer: true)
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
        viewModel.start(origin: .widget, fromComposer: true)
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
        // A destructive collision, so there is a stable in-flight pause to observe — the pause the
        // consequence rule still has.
        let occupied = fixture.root.appendingPathComponent("draft.md")
        try "existing draft".write(to: occupied, atomically: true, encoding: .utf8)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [
                    AgentStep(
                        id: "a",
                        operation: .createLocalDraft,
                        description: "Draft notes.",
                        outputPath: occupied.path,
                        draftTitle: "Notes",
                        draftContent: "Body."
                    )
                ]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.boundWorkspaceName == "Research")

        viewModel.command = "run routine Morning"
        viewModel.start(origin: .widget, fromComposer: true)
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

        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(drafting)
        viewModel.refreshSavedItems()

        // The interaction the name claims, and the one that was actually broken: arm a card
        // dispatch on a *different* workspace first. Before the fix, Open inherited it and opened
        // Research under Drafting's boundary — a scope approval naming a workspace the user never
        // mentioned, on the one-click action the contract says must be unchanged.
        viewModel.beginTaskInWorkspace(drafting)
        viewModel.openWorkspaceWidget(research)
        try await waitForViewModelToBecomeIdle(viewModel)

        // Open ran under its own plan-derived binding, never the pending one...
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: research)))
        // ...so no scope prompt at all, and certainly none naming Drafting.
        #expect(!viewModel.isAwaitingApproval)
        #expect(viewModel.approvalRequest == nil)
        // One click, exactly as before.
        #expect(viewModel.plan?.steps.first?.operation == .openWorkspace)
        #expect(fixture.appOpener.openedBundleIDs == ["com.apple.Safari"])
        #expect(fixture.browserOpener.openedURLs.map(\.absoluteString) == ["https://github.com"])
        // And the abandoned arm is dead rather than waiting for the next victim.
        #expect(viewModel.pendingWorkspaceBinding == nil)
    }

    /// F2's other inheriting entry point. `runRoutineWidget` is a Command Center row action, not a
    /// composer dispatch, so an armed chip must neither scope it nor survive it.
    @Test
    func aRoutineRowActionNeitherInheritsNorSurvivesAnArmedCardBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(drafting)
        try fixture.routineStore.save(
            StoredRoutine(
                name: "Morning",
                steps: [AgentStep(id: "a", operation: .openURL, description: "Go.", targetURL: "https://github.com/sonny")]
            )
        )
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(drafting)
        viewModel.runRoutineWidget(try fixture.routineStore.routine(named: "Morning"))
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.pendingWorkspaceBinding == nil)
    }

    /// F4 — "delete all local data" must take the pending slot with everything else. The workspace
    /// itself is gone by then; a chip still naming it, and a next command still binding to it, is
    /// the same defect SONNY-38's review filed against this function one ticket earlier.
    @Test
    func clearingInMemoryStateAlsoDropsAnArmedCardBinding() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        viewModel.deleteLocalData()

        #expect(viewModel.pendingWorkspaceBinding == nil)
        #expect(viewModel.boundWorkspaceName == nil)
    }

    /// A retry is a re-dispatch of the last command, not a composer submission, so it must not pick
    /// up an arm either — and the arm must not outlive it.
    @Test
    func aRetryNeitherInheritsNorSurvivesAnArmedCardBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(drafting)
        viewModel.refreshSavedItems()

        viewModel.command = "= 1 + 1"
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)

        viewModel.beginTaskInWorkspace(drafting)
        viewModel.retryLastCommand()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.pendingWorkspaceBinding == nil)
    }

    /// Last-wins: arming a second card before submitting replaces the first rather than stacking.
    @Test
    func aSecondCardArmBeforeSubmitReplacesTheFirst() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(research)
        try fixture.workspaceStore.save(drafting)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        viewModel.beginTaskInWorkspace(drafting)
        #expect(viewModel.boundWorkspaceName == "Drafting")

        viewModel.command = "= 1 + 1"
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: drafting)))
    }

    /// H1(a) — the reviewer's PROBED-2/3 sequence, now unreproducible. A clarification pause holds
    /// `activeTaskScope`, so the chip names the *paused* task's workspace while a card arm sits
    /// invisible behind it. Voice was the one dispatch route with no clarification term, so it
    /// consumed that arm and ran scoped to a workspace the chip never named.
    ///
    /// Driven at the level the tests actually reach — the same `start(autoExecute:origin:
    /// fromComposer:)` the transcription completion issues. Stated per the D4 standard: the
    /// `canUseVoice` half of the gate is **not** exercised here, because the fixture has no API key
    /// so `canUseVoice` is already false for an unrelated reason; that half is readable, not
    /// testable, and its proof is the declaration.
    @Test
    func voiceCannotConsumeAnArmWhileAClarificationIsPending() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let alpha = StoredWorkspace(name: "Alpha", apps: ["Safari"], urls: [])
        let research = StoredWorkspace(name: "Research", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(alpha)
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        // A task bound to Alpha, paused on a real clarification.
        viewModel.command = "="
        viewModel.start(origin: .widget, workspaceBinding: "Alpha", fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.clarificationQuestion != nil)
        #expect(viewModel.boundWorkspaceName == "Alpha")

        // A second workspace armed from its card — the button is live in this state, and the chip
        // still says Alpha because `activeTaskScope` wins.
        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.boundWorkspaceName == "Alpha")
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        // The dispatch the transcription completion issues. It must not run.
        viewModel.dispatchTranscribedCommand("= 2 + 2")
        try await waitForViewModelToBecomeIdle(viewModel)

        // Nothing ran scoped to Research — the arm the chip never showed.
        #expect(viewModel.lastAssessedScope != .scoped(WorkspaceScope(workspace: research)))
    }

    /// H1(b) — the paused task's unanswered clarification survives the attempted voice dispatch.
    /// `performStart`'s per-task reset clears `clarificationQuestion` unconditionally, so a dispatch
    /// that got through would have discarded the question with no notice at all.
    @Test
    func aPendingClarificationSurvivesAnAttemptedVoiceDispatch() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        let question = try #require(viewModel.clarificationQuestion)

        viewModel.dispatchTranscribedCommand("= 2 + 2")
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.clarificationQuestion == question)
    }

    /// R1 — deleting a workspace kills an arm naming it, so the chip can never promise a boundary
    /// the run will not apply: `resolveTaskScope` returns `.unscoped` for a name the store no longer
    /// has, so a surviving arm would render "In X" over an unscoped task.
    @Test
    func deletingAWorkspaceKillsAPendingArmThatNamesIt() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        let drafting = StoredWorkspace(name: "Drafting", apps: ["Notes"], urls: [])
        try fixture.workspaceStore.save(research)
        try fixture.workspaceStore.save(drafting)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        viewModel.deleteWorkspace(research)

        #expect(viewModel.pendingWorkspaceBinding == nil)
        // The symmetric edge: no chip rendering a name the store no longer has.
        #expect(viewModel.boundWorkspaceName == nil)

        // And an arm naming a *different*, still-saved workspace is untouched.
        viewModel.beginTaskInWorkspace(drafting)
        viewModel.deleteWorkspace(research)
        #expect(viewModel.pendingWorkspaceBinding == "Drafting")
    }

    /// R3 — a retry of a bound task keeps its workspace. Without this a command that raised a scope
    /// prompt the first time runs silently the second, which is a relaxation. Inherited from
    /// SONNY-38 rather than introduced by the card dispatch.
    @Test
    func aRetryOfABoundTaskKeepsTheOriginalWorkspaceScope() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: ["https://github.com"])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.command = "= 1 + 1"
        viewModel.start(origin: .widget, workspaceBinding: "Research", fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: research)))

        viewModel.retryLastCommand()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .scoped(WorkspaceScope(workspace: research)))
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

    // MARK: - Notified outcomes persist until acknowledged (SONNY-121)

    @Test
    func anErrorAloneDoesNotMarkAnOutcomeNotified() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.setError("Could not reach the planner.")

        // Setting an error is not the same as notifying about one. The gate that decides lives in
        // AppDelegate, and a user watching the widget is never notified at all.
        #expect(!viewModel.outcomeWasNotified)
    }

    /// **The acceptance criterion at the boundary the suite can reach.** A notified outcome and an
    /// identical unnotified one differ in exactly one readable fact, and that fact is what
    /// `FloatingWidgetView`'s collapse and clear decisions read.
    @Test
    func aNotifiedOutcomeAndAnIdenticalUnnotifiedOneDifferOnlyInTheMarker() throws {
        let notifiedFixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: notifiedFixture.root) }
        let unnotifiedFixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: unnotifiedFixture.root) }

        notifiedFixture.viewModel.setError("Could not reach the planner.")
        notifiedFixture.viewModel.markOutcomeAsNotified()
        unnotifiedFixture.viewModel.setError("Could not reach the planner.")

        #expect(notifiedFixture.viewModel.outcomeWasNotified)
        #expect(!unnotifiedFixture.viewModel.outcomeWasNotified)
        // Same message and same persistence flag — the marker is the only difference, so it is the
        // only thing the widget's two decisions can be turning on.
        #expect(notifiedFixture.viewModel.errorMessage == unnotifiedFixture.viewModel.errorMessage)
        #expect(notifiedFixture.viewModel.errorIsPersistent == unnotifiedFixture.viewModel.errorIsPersistent)
    }

    /// The marker describes the outcome, so it cannot outlive it — a stale `true` would make the
    /// *next* outcome un-collapsible for a notification nobody ever sent about it.
    @Test
    func clearingAStaleOutcomeClearsItsNotifiedMarkerToo() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.setError("Could not reach the planner.")
        viewModel.markOutcomeAsNotified()

        viewModel.clearStaleTaskOutcome()

        #expect(!viewModel.outcomeWasNotified)
        #expect(viewModel.errorMessage == nil)
    }

    @Test
    func submittingAnotherCommandAcknowledgesANotifiedOutcome() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.setError("Could not reach the planner.")
        viewModel.markOutcomeAsNotified()
        #expect(viewModel.outcomeWasNotified)

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(!viewModel.outcomeWasNotified)
    }

    /// Retry is the other acknowledgement and reaches the same clearing point through `dispatch`.
    /// Asserted separately, because "retry clears it" and "a new command clears it" are two
    /// criteria and one line satisfying both is worth pinning as such.
    @Test
    func retryingAcknowledgesANotifiedOutcome() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // A real failed run first, so `lastCommand` is populated and retry actually dispatches.
        viewModel.command = "calc apples"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.hasRetryableCommand)

        viewModel.markOutcomeAsNotified()
        #expect(viewModel.outcomeWasNotified)

        viewModel.retryLastCommand()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(!viewModel.outcomeWasNotified)
    }

    /// **The distinction the whole ticket rests on: visible is not read.** Bringing the widget
    /// forward is exactly what clicking a notification now does, and it must not count as
    /// acknowledgement — otherwise the outcome would be wiped by the act of going to look at it.
    @Test
    func bringingTheWidgetForwardDoesNotAcknowledgeAnything() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.setError("Could not reach the planner.")
        viewModel.markOutcomeAsNotified()
        let before = viewModel.widgetPresentationRequest

        // Exactly what the notification's default action does now.
        viewModel.widgetPresentationRequest += 1

        #expect(viewModel.widgetPresentationRequest == before + 1)
        #expect(viewModel.outcomeWasNotified)
        #expect(viewModel.errorMessage == "Could not reach the planner.")
    }

    // MARK: - A finished run's outcome (SONNY-56)

    /// The gap SONNY-44 found: a run started from a Command Center row action reports its result on
    /// no surface at all. It now publishes a summary the notification fallback carries.
    @Test
    func aSuccessfulCommandCenterRunPublishesItsSummaryForTheNotificationFallback() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        #expect(viewModel.completedRunNotice == nil)

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let notice = try #require(viewModel.completedRunNotice)
        #expect(!notice.summary.isEmpty)
        // It carries the run's own summary, not a generic "done".
        #expect(notice.summary == viewModel.finalSummary)
        // And the task it is about, so a click can open that task's detail (PR #67 review, F4).
        // Resolved against the row actually on disk, not merely non-nil.
        let taskID = try #require(notice.taskID)
        #expect(try fixture.taskHistoryStore.loadAll().contains { $0.id == taskID })
        #expect(viewModel.taskHistoryRecords.first?.id == taskID)
    }

    /// A run whose summary is blank posts nothing. An empty notification body is a notification that
    /// says nothing, and it would still make a sound and take a slot in Notification Center.
    @Test
    func aBlankSummaryPublishesNoOutcomeNotice() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.publishCompletedRunNoticeIfUnreported("", taskID: nil)
        #expect(viewModel.completedRunNotice == nil)
        viewModel.publishCompletedRunNoticeIfUnreported("   \n\t ", taskID: nil)
        #expect(viewModel.completedRunNotice == nil)

        viewModel.publishCompletedRunNoticeIfUnreported("  Opened Research.  ", taskID: nil)
        // Trimmed, so the notification body has no stray leading whitespace.
        #expect(viewModel.completedRunNotice?.summary == "Opened Research.")
    }

    /// **F4.** Clicking a finished-run notification opens that task's detail rather than expanding
    /// the widget onto an empty composer. The view-model half of that — resolving the id the
    /// notification carries to a real row and raising the request — is what the suite can reach.
    @Test
    func aFinishedRunNotificationOpensThatTasksDetailAndNotAnyOther() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        viewModel.command = "= 2 + 2"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 2)
        let firstTask = try #require(rows.first { $0.command == "= 1 + 1" }?.id)

        // The older task, not the most recent one — "the newest row" would open the wrong task when
        // another run finishes between the notification arriving and the click.
        #expect(viewModel.requestTaskDetail(taskID: firstTask))
        #expect(viewModel.taskDetailRequest?.taskID == firstTask)

        // Two requests for the same task are two distinct requests, so a second notification
        // reopens the sheet rather than being dropped as an unchanged value.
        let first = try #require(viewModel.taskDetailRequest)
        #expect(viewModel.requestTaskDetail(taskID: firstTask))
        #expect(viewModel.taskDetailRequest != first)
    }

    /// The notice names the row *this* run wrote, not whichever row the sort happens to leave at
    /// the head (PR #67 cycle-3, defect B).
    ///
    /// **The tie is built by construction, not by timing.** The first version of this test sampled
    /// `Date()` once at the top and seeded every row from it, then let the run stamp its own row
    /// with a second `Date()` about twenty milliseconds later — so the two agreed only when no
    /// second boundary fell between them, and roughly one run in fifty failed on the tie assertion
    /// rather than on the thing under test. Seeding a *band* of consecutive seconds removes the
    /// clock from the outcome: wherever within the band the run's own row lands, four seeded rows
    /// already share its persisted second.
    ///
    /// Two separate properties are set up here, and the test asserts both rather than assuming
    /// either:
    ///
    /// 1. **The tie really happened** — at least four other rows share this run's persisted
    ///    `completedAt`. That is the real-world condition, since `completedAt` persists at
    ///    whole-second resolution and any two tasks finishing within one second of each other
    ///    compare exactly equal.
    /// 2. **A strictly newer row exists**, from the far band. This is what makes the mutation's
    ///    failure deterministic instead of probabilistic: with a genuinely newer row present,
    ///    "the newest row" is provably not this run's, so the old `taskHistoryRecords.first?.id`
    ///    derivation picks the wrong id every time rather than most of the time. Without it the
    ///    test would rest on an unstable sort happening to mis-order a tie group, which is likely
    ///    but not certain — and a test that passes by luck under the mutation is not a test.
    @Test
    @MainActor
    func aFinishedRunsNoticeNamesItsOwnRowEvenWhenEveryTimestampTies() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // Whole seconds, because that is the resolution the store persists and therefore the
        // resolution at which rows can tie at all.
        let base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down))
        func seed(_ label: String, at offset: TimeInterval) throws {
            for index in 0..<4 {
                try fixture.taskHistoryStore.record(
                    CompletedTaskRecord(
                        command: "seeded \(label) \(index)",
                        startedAt: base,
                        completedAt: base.addingTimeInterval(offset),
                        outcomeStatus: .completed
                    )
                )
            }
        }
        // The band the run's own completion must land in — four consecutive seconds, against a run
        // that takes milliseconds. Whichever it lands on, it ties with four seeded rows.
        for offset in 0..<4 { try seed("band", at: TimeInterval(offset)) }
        // Far enough ahead that no plausible fixture run reaches it, so these are newer than this
        // run's row with certainty rather than with probability.
        try seed("newer", at: 30)

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let rows = try fixture.taskHistoryStore.loadAll()
        let ownRow = try #require(rows.first { $0.command == "= 1 + 1" })
        let tiedWithOwnRow = rows.filter { $0.completedAt == ownRow.completedAt && $0.id != ownRow.id }
        // (1) and (2). Both are setup conditions rather than the behaviour under test, and both are
        // asserted: if a change ever stops them holding, this test fails loudly here instead of
        // continuing to pass while proving nothing.
        #expect(tiedWithOwnRow.count >= 4)
        #expect(rows.contains { $0.completedAt > ownRow.completedAt })

        let notice = try #require(viewModel.completedRunNotice)
        #expect(notice.taskID == ownRow.id)
    }

    /// A task deleted between the notification arriving and the click resolves to nothing, and the
    /// opener says so rather than inventing a fallback.
    @Test
    func aNotificationForADeletedTaskOpensNothing() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        let record = try #require(viewModel.taskHistoryRecords.first)
        let taskID = try #require(record.id)

        viewModel.deleteTask(record)

        #expect(!viewModel.requestTaskDetail(taskID: taskID))
        #expect(viewModel.taskDetailRequest == nil)
    }

    /// **The narrowness is the design, so it is asserted rather than assumed.** A widget-origin run
    /// already shows its result in the widget's own panel — a permanent overlay, on screen even
    /// while the user works elsewhere — so notifying would be the duplicate the origin gate exists
    /// to prevent.
    @Test
    func aWidgetOriginRunPublishesNoOutcomeNoticeBecauseTheWidgetAlreadyShowsIt() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "= 1 + 1"
        viewModel.start(origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.finalSummary.isEmpty == false)
        #expect(viewModel.completedRunNotice == nil)
    }

    /// A failure already reaches the user through `errorMessage`, which has its own notification
    /// subscription. Publishing here too would notify twice for one run.
    @Test
    func aFailedRunPublishesNoOutcomeNoticeSoOneRunNeverNotifiesTwice() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "calc apples"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.completedRunNotice == nil)
    }

    // MARK: - "Don't save this task" (SONNY-120)

    /// **The test that defines done, and the reason it is written this way.**
    ///
    /// It enumerates the `.trace` stores from `LocalStore` — SONNY-115's classification — rather
    /// than from a list written here. That is the whole point: the writing sites live in five
    /// separate layers, and a boolean remembered at each of them is exactly how this feature would
    /// quietly stop being true. Enumerating from the classification means a trace store added later
    /// is covered the day it is classified, whether or not anyone remembered its call site.
    ///
    /// Byte-identical, not "no new records" — a rewrite that happened to produce the same records
    /// would still be a write, and AES-GCM seals with a fresh nonce, so identical bytes prove no
    /// write occurred at all rather than that the content matched.
    @Test
    func aSuppressedRunLeavesEveryTraceStoreByteIdentical() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // A normal run first, so every trace store this task touches actually exists on disk. A
        // file that was never created is trivially "unchanged", which would make the assertion below
        // pass for the wrong reason.
        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(try fixture.taskHistoryStore.loadAll().count == 1)

        let traceStores = LocalStore.allCases.filter { $0.kind == .trace }
        #expect(!traceStores.isEmpty, "The classification produced no trace stores to check.")
        // Mapped into the fixture root by filename — the fixture wires every store to
        // `root/<the store's own file name>`, so the classification's URLs and the test's agree
        // without a second hand-written mapping.
        let before = snapshot(of: traceStores, in: fixture.root)
        #expect(!before.isEmpty, "No trace-store file existed to compare.")

        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "= 2 + 2"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let after = snapshot(of: traceStores, in: fixture.root)
        for (name, bytes) in before {
            #expect(after[name] == bytes, "\(name) changed during a suppressed run")
        }
        // Files that did not exist before must not have been created by the suppressed run either.
        #expect(Set(after.keys) == Set(before.keys))
        // And the row really is absent, read back from the file rather than from published state.
        #expect(try fixture.taskHistoryStore.loadAll().map(\.command) == ["= 1 + 1"])
    }

    /// The negative half, and it matters as much as the positive one: a suppressed run still does
    /// what the user asked. Someone who says "save this as a routine" with the switch on still wants
    /// the routine — a saved routine is an *effect*, and this switch never claimed to hide effects.
    @Test
    func aSuppressedRunStillWritesTheArtifactTheUserAskedFor() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "snippet save ;quiet = Nothing to see"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // The artifact survives — a snippet is a `.artifact` store, never suppressed...
        #expect(try fixture.snippetStore.loadAll().contains { $0.value.trigger == ";quiet" })
        // ...and the trace of having made it does not.
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
    }

    @Test
    func theSwitchGoesBackOffOnEveryTerminalOutcome() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // Success.
        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "= 1 + 1"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.taskRecordingPolicy == .record)

        // Failure — the outcome most likely to skip a cleanup path.
        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "calc apples"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.taskRecordingPolicy == .record)
        // Neither run left a row behind.
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
    }

    /// A run that never started leaves the switch alone. Its counterpart — the switch surviving an
    /// approval *pause* — is what `finishRecordingPolicyIfSettled()`'s guard exists for.
    @Test
    func theSwitchSurvivesUntilATaskActuallyEnds() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.taskRecordingPolicy = .suppressTraces
        // No command, so `start()` refuses and nothing runs.
        viewModel.command = "   "
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.taskRecordingPolicy == .suppressTraces)
    }

    /// **F1's seam test.** The vision journal is the fifth `.trace` store and was the one nothing
    /// pinned: its withholding decision lived inline in `makeLiveVisionEnvironment()`, which no test
    /// here can execute — `makeVisionEnvironment` returns `nil` without an API key, and the vision
    /// tests inject `visionSessionEnvironment` directly and bypass it. So a mutation handing the
    /// store over regardless of policy survived the whole suite.
    ///
    /// Asserting the decision is asserting the suppression: row I built `journalStore == nil` as
    /// "run the session, record nothing", so withholding the store *is* the mechanism. This test's
    /// whole purpose is to fail when suppression breaks.
    @Test
    func aSuppressedRunIsHandedNoVisionSessionJournal() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        #expect(viewModel.visionSessionJournalStoreForThisRun != nil)
        viewModel.taskRecordingPolicy = .suppressTraces
        #expect(viewModel.visionSessionJournalStoreForThisRun == nil)
        viewModel.taskRecordingPolicy = .record
        #expect(viewModel.visionSessionJournalStoreForThisRun != nil)
        // The store handed back when recording is the real one, not some other instance — a
        // withholding that returned a fresh empty store would satisfy nil-vs-non-nil and record
        // nowhere the app can read.
        #expect(viewModel.visionSessionJournalStoreForThisRun?.fileURL == viewModel.visionSessionJournalStore.fileURL)
    }

    /// **F2.** A scheduled routine is never suppressed, including in the one window where a
    /// foreground run has left the policy set: paused at a clarification, `isRunning` is false and
    /// `checkScheduledRoutines` does not guard on it, so a routine can fire while
    /// `taskRecordingPolicy` is still `.suppressTraces`.
    @Test
    func aScheduledRunIsNeverSuppressedEvenWhileAForegroundRunIsPausedAtAClarification() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // The window: policy set, run not "running", not awaiting approval.
        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.clarificationQuestion = "Which workspace did you mean?"
        #expect(!viewModel.isRunning)
        #expect(!viewModel.isAwaitingApproval)

        // The foreground executor still suppresses — that run really is still going.
        #expect(viewModel.makeExecutor().suppressesTracesForTests)
        // The scheduled executor does not, whatever the policy says.
        #expect(!viewModel.makeExecutor(recordingPolicy: .record).suppressesTracesForTests)
    }

    /// The recent-artifacts half, asserted at the decision rather than end-to-end.
    ///
    /// The fixture's deterministic planner has no command that generates an artifact, so a
    /// suppressed run leaves that store untouched whether or not the withholding works — the
    /// acceptance test above passes for the wrong reason on this one store, which a mutation
    /// battery found by surviving. This is what actually pins it: `AgentRunner` already treats a
    /// `nil` store as "record nothing", so withholding the store *is* the suppression.
    @Test
    func aSuppressedRunIsHandedNoRecentArtifactStore() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        #expect(viewModel.recentArtifactStoreForThisRun != nil)
        viewModel.taskRecordingPolicy = .suppressTraces
        #expect(viewModel.recentArtifactStoreForThisRun == nil)
        viewModel.taskRecordingPolicy = .record
        #expect(viewModel.recentArtifactStoreForThisRun != nil)
    }

    private func snapshot(of stores: [LocalStore], in root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        for store in stores {
            let name = store.fileURL().lastPathComponent
            if let data = try? Data(contentsOf: root.appendingPathComponent(name)) {
                result[name] = data
            }
        }
        return result
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
        // The trigger already exists with different text, so the save is a destructive replace —
        // the pause the consequence rule still has (a first-time save auto-runs).
        try fixture.snippetStore.save(StoredSnippet(trigger: ";history-test", expansion: "Old text"))
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

        let records = try fixture.taskHistoryStore.loadAll()
        let record = try #require(records.last)
        // The tier-2 routine auto-runs under the consequence rule, so the record is a completed
        // one now rather than the canceled-at-approval record this test used before the rule.
        #expect(record.outcomeStatus == .completed)
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

        // The routine auto-runs to completion under the consequence rule — completing, rather
        // than a planner-missing-key failure, proves the command resolved instantly and locally,
        // with no network call attempted.
        #expect(viewModel.finalSummary.contains("Ran routine Morning Setup"))
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
        // A destructive replace, so the run genuinely pauses (a first-time save auto-runs under
        // the consequence rule).
        try fixture.snippetStore.save(StoredSnippet(trigger: ";cross-surface-test", expansion: "Old text"))
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

    // MARK: - Source reading, for the local-data-wipe classification test

    /// The identifiers `clearInMemoryLocalDataState` assigns, read out of the real source file.
    ///
    /// Read from source rather than observed by behaviour on purpose: the point is to catch a clear
    /// that exists but was never classified (and a classification with no clear behind it), and both
    /// of those are invisible to any assertion over values. The body is delimited by the function's
    /// own closing brace at four-space indentation — the whole body is one flat sequence of
    /// statements at eight, which the parse below asserts rather than assumes.
    private static func assignmentsInClearInMemoryLocalDataState() throws -> Set<String> {
        // <package root>/Tests/MacAgentTests/<this file>
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/MacAgent/AgentViewModel.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: "\n")
        let start = try #require(
            lines.firstIndex { $0.hasSuffix("private func clearInMemoryLocalDataState() {") },
            "`clearInMemoryLocalDataState` was renamed or removed; this test reads it by name."
        )
        let body = lines[(start + 1)...].prefix { $0 != "    }" }
        #expect(
            body.count > 15,
            "Read \(body.count) lines of the function body — too few to be the real one."
        )

        var assigned: Set<String> = []
        for line in body {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), let separator = trimmed.range(of: " = ") else {
                continue
            }
            let name = String(trimmed[trimmed.startIndex ..< separator.lowerBound])
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                continue
            }
            assigned.insert(name)
        }
        return assigned
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
    snippetStore: SnippetStore,
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
    snippetStore: SnippetStore,
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
    let snippetStore = SnippetStore(
        fileURL: root.appendingPathComponent("snippets.json"),
        encryption: encryption
    )
    let viewModel = AgentViewModel(
        routineStore: routineStore,
        workspaceStore: workspaceStore,
        snippetStore: snippetStore,
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
        // Injected under the fixture root rather than defaulted, or it resolves to the real
        // ~/Library/Application Support/Sonny/vision-sessions.json. No test read it before
        // SONNY-120, so nothing was wrong yet — which is exactly the hermeticity-by-accident the
        // seam comment above describes.
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        ),
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
        userDefaults: userDefaults,
        // The fixture root, so the REAL dispatch path can assess and execute file-writing plans
        // (drafts above all) hermetically — the seam whose absence let a green mapping suite
        // coexist with a live app that behaved differently (2026-08-13 manual-pass finding).
        whitelist: PathWhitelist(roots: [root])
    )
    let suiteName = userDefaultsSuiteName ?? "ProductShellInjected-\(UUID().uuidString)"
    return (viewModel, root, routineStore, workspaceStore, snippetStore, taskHistoryStore, userDefaults, suiteName, browserOpener, appOpener)
}

/// The 30 seconds is a deadlock backstop, not a timing assertion (SONNY-159/160/161): this target is
/// `@MainActor` and Swift Testing interleaves its suites on one actor, so the previous 2 s fired when a
/// neighbouring test was busy rather than when anything was wrong. Full reasoning and the measurements
/// are on `VisionSessionRunTests.hangBackstop`.
@MainActor
private func waitForViewModelToBecomeIdle(
    _ viewModel: AgentViewModel,
    timeout: TimeInterval = 30
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while viewModel.isRunning {
        if Date() > deadline {
            Issue.record("View model did not become idle before timeout. Waited 30s, which at this length means genuinely stuck rather than merely busy — treat it as a real failure.")
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
