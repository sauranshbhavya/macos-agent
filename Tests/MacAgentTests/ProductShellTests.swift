import AppKit
import Foundation
import SwiftUI
import Testing
import MacAgentTestSupport
@testable import MacAgent
// `@testable` rather than a plain import, because this file reaches members that are internal to
// `MacAgentCore`. **What it names has changed, and the reason it changed is worth the two lines**
// (PR #177's R2). This used to cite `RoutineStore.saveBypassingStepValidation`, the module-internal
// test-only write path SONNY-52 added — and SONNY-186 removed this file's only call to it, because
// `.openWorkspace` left `StoredRoutine.forbiddenStepOperations` and the routine below is one the
// product can now author through the real `save`. So the justification outlived the call by exactly
// one commit: the branch's own rule that a comment naming a reachability guarantee goes stale in
// the commit that removes the guarantee, arriving inside the fix for the previous instance of it.
// (`grep -c "\.saveBypassingStepValidation(" Tests/MacAgentTests/ProductShellTests.swift` → 0,
// exit 1, with the same command over `ScheduledRoutineRunTests.swift` → 1 as the control that makes
// that zero a measurement.)
//
// **The attribute is still required, and that is the compiler's answer rather than a scan's.**
// Dropping it fails the build of this target at `SonnyAccountTokens(accessToken:refreshToken:…)`:
// the type is `public` but its stored `accessToken`/`refreshToken` and its memberwise `init` are
// internal (`SonnyAccountTokenStore.swift:16-26`). A grep-style scan for internal *types* answers
// zero here and would have said the attribute could go — an internal member on a public type is
// invisible to it — so the probe was to remove `@testable`, build, and read what the compiler
// named. Three errors, all at that initializer.
@testable import MacAgentCore

@Suite(.serialized)
@MainActor
struct ProductShellTests {
    @Test
    func appSurfacesRetainTheSameInjectedViewModelReference() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let coordinator = AppWindowCoordinator(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )
        let widget = FloatingWidgetView(viewModel: viewModel)
        let commandCenter = CommandCenterView(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

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
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let delegate = AppDelegate(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

        // The first item is "Ask Sonny" since the ui-ux-claude modernization: the sidebar's ⌘N
        // button and this item are one action, named once. The function keeps its historical name
        // because the changelog and `WidgetControlNamingTests` cite it.
        let menu = delegate.makeStatusMenu()
        #expect(menu.items.map(\.title) == ["Ask Sonny", "", "Open Command Center", "Settings…", "", "Quit Sonny"])

        // Titles alone pin nothing about wiring: an item rewired to a different selector keeps its
        // title and a title-only assertion stays green. Every item gets its target, selector, and
        // key equivalent asserted — ⌘Q in particular, since app-wide Quit was menu-routed and
        // silently broken once already (see `makeMainMenu()`'s comment).
        let expectedItems: [(title: String, action: Selector, keyEquivalent: String)] = [
            ("Ask Sonny", #selector(AppDelegate.requestWidgetPresentation), ""),
            ("Open Command Center", #selector(AppDelegate.openCommandCenter), ""),
            ("Settings…", #selector(AppDelegate.openSettings), ""),
            ("Quit Sonny", #selector(AppDelegate.quit), "q")
        ]
        for expected in expectedItems {
            let item = try #require(menu.items.first { $0.title == expected.title })
            #expect(item.target === delegate)
            #expect(item.action == expected.action)
            #expect(item.keyEquivalent == expected.keyEquivalent)
        }

        let newTask = try #require(menu.items.first { $0.title == "Ask Sonny" })
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

    /// The real app menu, pinned the way the status menu is: titles alone leave a rewired item
    /// green. About and Settings target the delegate, whose doors bump `CommandCenterCommands`; the
    /// three Hide items carry nil targets so AppKit's own responder-chain selectors answer them,
    /// and ⌘H / ⌥⌘H are the equivalents every Mac app gives them.
    @Test
    func theAppMenuCarriesAboutSettingsTheHideItemsAndQuit() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let delegate = AppDelegate(
            viewModel: fixture.viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

        let mainMenu = delegate.makeMainMenu()
        #expect(mainMenu.items.map { $0.submenu?.title ?? "" } == ["", "Edit", "Window", "Help"])
        // `applicationDidFinishLaunching` installs the Window submenu as `NSApp.windowsMenu` by
        // looking the item up by this title, so the title is wiring rather than decoration.
        #expect(mainMenu.item(withTitle: "Window")?.submenu === mainMenu.items[2].submenu)
        let appMenu = try #require(mainMenu.items.first?.submenu)
        #expect(appMenu.items.map(\.title) == [
            "About Sonny", "", "Settings…", "", "Hide Sonny", "Hide Others", "Show All", "", "Quit Sonny"
        ])

        let delegateItems: [(title: String, action: Selector, keyEquivalent: String)] = [
            ("About Sonny", #selector(AppDelegate.openAbout), ""),
            ("Settings…", #selector(AppDelegate.openSettings), ","),
            ("Quit Sonny", #selector(AppDelegate.quit), "q")
        ]
        for expected in delegateItems {
            let item = try #require(appMenu.items.first { $0.title == expected.title })
            #expect(item.target === delegate)
            #expect(item.action == expected.action)
            #expect(item.keyEquivalent == expected.keyEquivalent)
        }

        let hide = try #require(appMenu.items.first { $0.title == "Hide Sonny" })
        #expect(hide.target == nil)
        #expect(hide.action == #selector(NSApplication.hide(_:)))
        #expect(hide.keyEquivalent == "h")
        #expect(hide.keyEquivalentModifierMask == [.command])
        let hideOthers = try #require(appMenu.items.first { $0.title == "Hide Others" })
        #expect(hideOthers.target == nil)
        #expect(hideOthers.action == #selector(NSApplication.hideOtherApplications(_:)))
        #expect(hideOthers.keyEquivalent == "h")
        #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])
        let showAll = try #require(appMenu.items.first { $0.title == "Show All" })
        #expect(showAll.target == nil)
        #expect(showAll.action == #selector(NSApplication.unhideAllApplications(_:)))

        // The Help menu: found by title to become `NSApp.helpMenu`, one item, ⌘/, the delegate.
        let helpMenu = try #require(mainMenu.item(withTitle: "Help")?.submenu)
        #expect(helpMenu === mainMenu.items[3].submenu)
        #expect(helpMenu.items.map(\.title) == ["Keyboard shortcuts"])
        let shortcuts = try #require(helpMenu.items.first)
        #expect(shortcuts.target === delegate)
        #expect(shortcuts.action == #selector(AppDelegate.openKeyboardShortcuts))
        #expect(shortcuts.keyEquivalent == "/")
        #expect(shortcuts.keyEquivalentModifierMask == [.command])
    }

    /// Opening the app while it already runs (a Dock click, Spotlight, Launchpad, a Finder
    /// double-click) shows Command Center when it is not on screen and leaves it alone when it is.
    /// The same activation-policy dance as `coordinatorCreatesReusableCommandCenterWindowAndChangesActivationPolicy`,
    /// because showing the window switches the app to `.regular`.
    @Test
    func reopeningTheAppShowsCommandCenterOnlyWhenItIsNotOnScreen() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let application = NSApplication.shared
        let originalActivationPolicy = application.activationPolicy()
        defer { _ = application.setActivationPolicy(originalActivationPolicy) }
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let coordinator = AppWindowCoordinator(
            viewModel: fixture.viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

        #expect(coordinator.commandCenterWindow == nil)
        #expect(!coordinator.isCommandCenterVisible)

        coordinator.handleReopen()
        let window = try #require(coordinator.commandCenterWindow)
        #expect(window.isVisible)
        #expect(coordinator.isCommandCenterVisible)

        // On screen already: the same window, nothing new made.
        coordinator.handleReopen()
        #expect(coordinator.commandCenterWindow === window)

        // Closed and reopened: the same window comes back rather than a second one.
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(!coordinator.isCommandCenterVisible)
        coordinator.handleReopen()
        #expect(coordinator.commandCenterWindow === window)
        #expect(window.isVisible)
        window.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    @Test
    func pushToTalkPressSharesTheMenuItemsWidgetPresentationPath() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let delegate = AppDelegate(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

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

    /// **SONNY-25's two audited `FloatingWidgetWindowController.show()` callers, pinned so neither
    /// is changed blind.**
    ///
    /// SONNY-8 routed every *hand-driven* summon through `widgetPresentationRequest` and left these
    /// two direct, each for a stated reason. One has since moved and the other deliberately has not,
    /// and both dispositions are decisions rather than leftovers — which is the whole thing this
    /// ticket was filed to preserve, since its own analysis asks a future session not to redo it.
    ///
    /// - **The notification's default action is no longer direct.** SONNY-121 rerouted it through
    ///   the counter, because `show()` fronts the panel and cannot do either of the other two things
    ///   a click needs: it has no reference to the view's `isCompact` state, and it cannot move
    ///   keyboard focus, which lives in `FloatingWidgetView`'s own `@FocusState`. Before that, a
    ///   click landed on a compact capsule with an unfocused composer.
    /// - **Launch is still direct, and must stay so.** `show()` creates the panel and
    ///   `FloatingWidgetView.onAppear` focuses the composer on first render, so the counter buys
    ///   nothing there; routing launch through it would make the launch path depend on
    ///   `observeWidgetPresentationRequests()` having been installed first — an ordering dependency
    ///   for no user-visible gain.
    ///
    /// **The focus half is now conditional, and that is the same decision rather than a weakening of
    /// it** (SONNY-247). Both call sites moved from a bare `pillFocused = true` to a helper that
    /// gives the caret to the composer only when the composer can use it. While a question is parked
    /// the composer is `.disabled`, so the old unconditional write aimed the caret at a field that
    /// refuses every keystroke and every paste — the founder's report, twice in one day — while the
    /// live field sat in the panel above. SONNY-283 then made the helper `focusTheFieldThatTakesInput()`,
    /// which knows about *both* fields, because a summon during a question had nothing to focus and
    /// the hotkey did nothing. What this test holds is unchanged: a click still reaches a view that
    /// does *both* halves. Whether the rule itself is right is held by `WidgetComposerStateTests`.
    ///
    /// **Read rather than run, and this is the case that best shows why the tool exists.** Neither
    /// line can execute in a test process: `SonnyNotificationService.init?` returns nil without
    /// bundle identity, and `applicationDidFinishLaunching` registers a real `NSStatusItem`, a
    /// Carbon hotkey and the schedule timer. That is also the accepted coverage gap SONNY-25
    /// recorded — `observeWidgetPresentationRequests()`'s sink body has never been exercised by any
    /// test — which stands, and is narrower now: the *decision* at each call site is held even
    /// though the AppKit call is not.
    @Test
    func theNotificationClickAndLaunchKeepTheirAuditedPresentationPaths() throws {
        let delegate = try MacAgentSource.read("AppDelegate.swift")

        let onOpen = try MacAgentSource.region(of: delegate, from: "onOpen: {", to: "onOpenTask:")
        #expect(onOpen.contains("requestWidgetPresentation()"))
        #expect(!onOpen.contains("widgetController.show()"))

        let launch = try MacAgentSource.region(
            of: delegate,
            from: "func applicationDidFinishLaunching(",
            to: "private var isUserWorkingInSonny: Bool {"
        )
        #expect(launch.contains("widgetController.show()"))
        #expect(!launch.contains("requestWidgetPresentation()"))

        // The counter is only worth routing a click through because the view does *both* halves with
        // it. A reroute that reached a view doing only one of them would be the old bug wearing the
        // new mechanism.
        let onChange = try MacAgentSource.region(
            of: try MacAgentSource.read("FloatingWidgetView.swift"),
            from: ".onChange(of: viewModel.widgetPresentationRequest) { _, _ in",
            to: ".onChange(of: isMicHintSlotFree)"
        )
        #expect(onChange.contains("expandFromCompact()"))
        #expect(onChange.contains("focusTheFieldThatTakesInput()"))
    }

    /// **The post-relaunch launch, end to end, on the value the Keychain actually held** (SONNY-137;
    /// PR #159's review, F3).
    ///
    /// The worst bug this row can ship is a user who signs in, grants Screen Recording, watches the
    /// app relaunch, and is handed a sign-in screen for the account they just signed into. Three
    /// separate edits produce it and only one of them changes the statement order: moving `begin`
    /// out of the task that awaits `restore()`, reading `isSignedIn` into a local *before* the
    /// `await`, and passing a literal `false`. A source scan of the shape catches the first and
    /// neither of the others — both survived a battery while that scan was the only pin.
    ///
    /// So this drives the real method. The Keychain is seeded before anything reads it, exactly as a
    /// relaunch leaves it; the account model has not read it yet, which is what `isSignedIn == false`
    /// before the call asserts; and afterwards the sequence must be at the step that is *left*.
    /// Landing on `.signIn` is the bug, and every one of the three edits lands there.
    ///
    /// It lives in this file rather than beside the rest of SONNY-137's tests because it needs a
    /// real `AgentViewModel`, and `makeProductShellFixture` is file-private here.
    @Test
    func theLaunchDecidesFirstRunOnTheSessionTheKeychainActuallyHeld() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.userDefaultsSuiteName) }

        // What the process that comes back after the Screen Recording grant finds on disk.
        let keychain = InMemoryKeychainSecretStore()
        try KeychainAccountTokenStore(secretStore: keychain).saveTokens(SonnyAccountTokens(
            accessToken: "restored-access",
            refreshToken: "restored-refresh",
            accessTokenExpiresAt: Date().addingTimeInterval(3_600),
            refreshTokenExpiresAt: nil,
            userID: "acct_7f3c",
            emailAddress: "founder@example.com"
        ))
        let accountModel = makeHermeticAccountModel(keychain: keychain)
        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let firstRunCoordinator = suite.makeCoordinator()
        let delegate = AppDelegate(
            viewModel: fixture.viewModel,
            accountModel: accountModel,
            // Screen Recording granted, Accessibility not: the state the relaunch leaves behind.
            screenAccessModel: makeHermeticScreenAccessModel(
                screenRecordingGranted: true,
                accessibilityTrusted: false
            ),
            firstRunCoordinator: firstRunCoordinator
        )

        // Nothing has read the Keychain yet, so a decision taken now — or on a value captured now —
        // would be taken against a signed-out account.
        #expect(accountModel.isSignedIn == false)
        #expect(firstRunCoordinator.presentedStep == nil)
        #expect(firstRunCoordinator.hasBegun == false)

        await delegate.decideFirstRunAfterRestoringTheSession()

        #expect(accountModel.isSignedIn)
        #expect(accountModel.signedInAddress == "founder@example.com")
        #expect(firstRunCoordinator.hasBegun)
        #expect(
            firstRunCoordinator.presentedStep == .screenAccess,
            "the relaunch must come back at the step that is left, not at sign-in"
        )
        #expect(firstRunCoordinator.presentedStep != .signIn)
    }

    /// The mirror, and the reason the test above is not merely asserting that `restore()` works: on
    /// a Mac with nothing stored, the same call must land on sign-in. Without this, a mutant that
    /// hard-coded `.screenAccess` would pass the test above.
    @Test
    func theSameLaunchOnAMacWithNoStoredSessionStartsAtSignIn() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.userDefaults.removePersistentDomain(forName: fixture.userDefaultsSuiteName) }

        let suite = FirstRunDefaultsSuite()
        defer { suite.removeAtEndOfTest() }
        let firstRunCoordinator = suite.makeCoordinator()
        let delegate = AppDelegate(
            viewModel: fixture.viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(
                screenRecordingGranted: true,
                accessibilityTrusted: false
            ),
            firstRunCoordinator: firstRunCoordinator
        )

        await delegate.decideFirstRunAfterRestoringTheSession()

        #expect(firstRunCoordinator.presentedStep == .signIn)
    }

    @Test
    func commandCenterDestinationsKeepTheLockedSidebarOrder() {
        // Settings is no longer a sidebar destination (2026-07-18) — it moved to its own dialog,
        // opened from the bottom account row. See `SettingsDialogView`.
        // Memory joined the list last (SONNY-208), below Workspaces: the four above it are the
        // places work happens, and Memory is what those four leave behind.
        #expect(
            CommandCenterDestination.allCases == [
                .tasks,
                .insights,
                .routines,
                .workspaces,
                .memory
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
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let commandCenter = CommandCenterView(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

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
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let commandCenter = CommandCenterView(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

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
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        // `NSWindow`'s frame autosave writes to the real, un-sandboxed `UserDefaults.standard` under
        // "NSWindow Frame <name>" — there is no hermetic seam for it, unlike every other preference
        // this suite touches. A window this smoke test (or a manual `SONNY_UI_SMOKE=1` run) already
        // showed once would have saved a real frame under this exact key, and the content-size
        // assertion below is specifically about the *no-saved-frame* default — so it is cleared
        // first, deliberately, rather than assumed absent.
        let autosaveDefaultsKey = "NSWindow Frame SonnyCommandCenterWindow.v2"
        UserDefaults.standard.removeObject(forKey: autosaveDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: autosaveDefaultsKey) }
        let coordinator = AppWindowCoordinator(
            viewModel: viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

        coordinator.showCommandCenter()
        let commandCenterWindow = try #require(coordinator.commandCenterWindow)
        #expect(commandCenterWindow.title == "Sonny")
        #expect(commandCenterWindow.minSize == NSSize(width: 900, height: 620))
        #expect(commandCenterWindow.styleMask.contains(.resizable))
        #expect(commandCenterWindow.isVisible)
        #expect(application.activationPolicy() == .regular)
        // Phase 14 (founder ask): the default content size, raised from 1180×780, and the renamed
        // autosave key — `commandCenterWindow.contentView` is the hosting controller's view, which
        // fills the content rect exactly, so this reads the size `NSWindow(contentRect:)` was given
        // rather than the outer frame, which also carries the (zero-height, transparent) title bar.
        #expect(commandCenterWindow.contentView?.frame.size == NSSize(width: 1_280, height: 840))
        // Read on the window itself, and correct only because `makeCommandCenterWindowController`
        // also sets `windowFrameAutosaveName` on the *controller* — `NSWindowController.showWindow`
        // resyncs the window's own autosave name from that controller property (empty by default),
        // clearing anything set directly on the window beforehand; see that method's own comment on
        // the fix, found and corrected in this same phase.
        #expect(commandCenterWindow.frameAutosaveName == "SonnyCommandCenterWindow.v2")

        coordinator.showCommandCenter()
        #expect(coordinator.commandCenterWindow === commandCenterWindow)

        if let snapshotPath = ProcessInfo.processInfo.environment["SONNY_COMMAND_CENTER_SNAPSHOT"] {
            try render(window: commandCenterWindow, to: URL(fileURLWithPath: snapshotPath))
        }

        // Phase 14: the hold-⌘ hint monitor lives exactly as long as the window is on screen.
        #expect(coordinator.isCommandKeyHintMonitorInstalled, "installed with the window")

        commandCenterWindow.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(application.activationPolicy() == .accessory)
        #expect(coordinator.isCommandKeyHintMonitorInstalled == false, "removed when the window closes")

        // Phase 14's review, F2: the window controller is kept and reused after a close, so an
        // install tied to its making ran once per process while the removal ran on every close,
        // and the hints were gone for good after the first close. Showing again reinstalls it — on
        // the same window, so nothing here comes from making a new one.
        coordinator.showCommandCenter()
        #expect(coordinator.commandCenterWindow === commandCenterWindow)
        #expect(commandCenterWindow.isVisible)
        #expect(coordinator.isCommandKeyHintMonitorInstalled, "shown again, the monitor is back")

        commandCenterWindow.close()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        #expect(coordinator.isCommandKeyHintMonitorInstalled == false)
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
        // The press is asynchronous since SONNY-404's fix round: it drains the deletion queue and
        // deletes the account's server-side content before it touches a local file.
        await viewModel.localDataWipeForTests?.value

        #expect(viewModel.activeTaskScope == .unscoped)
    }

    /// **A job over many items publishes its progress from a real run** (row 13, SONNY-235).
    ///
    /// The founder's decision of 2026-08-31 approves a whole job in one press on the condition that
    /// the user can see it moving and stop it. This is the seeing, driven through the view model's
    /// own dispatch rather than by calling the reporter: the executor's unit boundaries are what
    /// feed it, and a test that pushed values into `itemJobProgress` directly would pin nothing
    /// about whether a real run ever reaches them.
    ///
    /// Two of three, not three of three, and that is `CompletedRunUnit`'s semantics rather than a
    /// miscount: a chain never reports its last unit, because a boundary with nothing behind it
    /// changes no resume. The run's own summary is what settles the third.
    @Test
    func aJobOverManyItemsPublishesHowFarItHasGot() async throws {
        let fixture = try makeProductShellFixture()
        let viewModel = fixture.viewModel
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let folder = fixture.root.appendingPathComponent("job-items")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent("\(name).pdf"), options: .atomic)
        }

        viewModel.command = "Reveal each of these"
        viewModel.start(
            prebuiltPlan: AgentPlan(
                summary: "Reveal each of these.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(id: "reveal", operation: .revealInFinder, description: "Reveal it.")
                ],
                itemJob: PlanItemJob(
                    source: .folder,
                    folderPath: folder.path,
                    itemKind: .files,
                    fileExtensions: ["pdf"],
                    itemField: .inputPath
                )
            )
        )
        try await waitForViewModelToBecomeIdle(viewModel)

        let progress = try #require(viewModel.itemJobProgress)
        #expect(progress.itemCount == 3)
        #expect(progress.completedItemIndexes == [0, 1])
        #expect(progress.failedCount == 0)
        #expect(ItemJobProgressPresentation.progressLine(for: progress) == "2 of 3 files done")
        // The control for every assertion above: the run really did happen and really was a job.
        #expect(viewModel.finalSummary == "Worked through all 3 files.")
    }

    /// **A reveal inside a plan ends at this view model's own `finderRevealer`, not at the
    /// machine** (SONNY-395).
    ///
    /// The two tests directly above are where the founder's Finder windows came from. Both pass
    /// `hermeticFinderRevealer` into the view model, both were correct to, and both still opened
    /// real windows — four per suite run, measured with a probe at `15c7bd9` — because
    /// `AgentActionExecutor` took `CapabilityRegistry.default`, whose reveal adapter called
    /// `NSWorkspace.shared.activateFileViewerSelecting` inline. The seam was one level above the
    /// code that ignored it.
    ///
    /// So this asserts the join rather than the adapter: `RevealInFinderSeamTests` already proves
    /// the adapter reveals through whatever seam its registry was built with, and what that cannot
    /// see is `makeExecutor` handing it a *different* one. Run through `start(prebuiltPlan:)`, the
    /// same door as the two tests above, so the thing asserted is the thing that was broken.
    ///
    /// **It fails if the real call comes back** — by replacing the seam or by joining it, since
    /// either leaves this recorder holding something other than exactly one reveal of exactly this
    /// file, and it fails if `makeExecutor` stops threading `finderRevealer` at all.
    @Test
    func aRevealInsideAPlanEndsAtThisViewModelsOwnRevealer() async throws {
        let revealed = ProductShellFinderRevealer()
        let fixture = try makeProductShellFixture(finderRevealer: { revealed.record($0) })
        let viewModel = fixture.viewModel
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let file = fixture.root.appendingPathComponent("shown.pdf")
        try Data("x".utf8).write(to: file, options: .atomic)

        viewModel.command = "Reveal it"
        viewModel.start(
            prebuiltPlan: AgentPlan(
                summary: "Reveal it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "reveal",
                        operation: .revealInFinder,
                        description: "Reveal it.",
                        inputPath: file.path
                    )
                ]
            )
        )
        try await waitForViewModelToBecomeIdle(viewModel)

        // The control: the run reached the reveal capability rather than failing somewhere earlier.
        #expect(viewModel.finalSummary == "Revealed \(file.path) in Finder.")
        #expect(revealed.calls.count == 1, "the view model's seam was called \(revealed.calls.count) times")
        #expect(revealed.calls.first == [file])
    }

    /// The control beside the test above, and the one that makes a non-nil progress mean something:
    /// an ordinary run publishes none at all, so a surface that renders it renders nothing.
    @Test
    func anOrdinaryRunPublishesNoJobProgress() async throws {
        let fixture = try makeProductShellFixture()
        let viewModel = fixture.viewModel
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let file = fixture.root.appendingPathComponent("one.pdf")
        try Data("x".utf8).write(to: file, options: .atomic)

        viewModel.command = "Reveal it"
        viewModel.start(
            prebuiltPlan: AgentPlan(
                summary: "Reveal it.",
                requiresConfirmation: false,
                steps: [
                    AgentStep(
                        id: "reveal",
                        operation: .revealInFinder,
                        description: "Reveal it.",
                        inputPath: file.path
                    )
                ]
            )
        )
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.itemJobProgress == nil)
        #expect(!viewModel.finalSummary.isEmpty)
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
            // **`watcherNotice` moved here from `outsideTheWipe` in PR #184's fix round, and the
            // earlier reasoning is superseded rather than merely wrong.** It said clearing the
            // sentence would erase the record of a thing the user was told — true while the wipe left
            // a watcher check running, because the notice was then the only surviving trace. F2 made
            // the wipe abandon that check, so what is left is residue naming a watcher the same press
            // just deleted, which is exactly `completedRunNotice`'s case one line above. The user is
            // present at a wipe by construction, so F1's concern — a notice destroyed while nobody
            // could see it — does not arise here.
            "watcherNotice",
            // `notifiedWatcherIDs` goes with the records it is about (PR #184 cycle 3, N1). It is
            // the set of watchers already notified, so a delete that keeps failing says its sentence
            // once rather than once per pulse — and the wipe has just deleted every record those ids
            // name, so keeping them would silence the first notice of a watcher created afterwards
            // that happened to reuse one.
            "notifiedWatcherIDs",
            "taskDetailRequest",
            // Row J's grants, cached for one vision iteration. The grants file is one of the
            // stores the wipe erases, so its in-memory copy is erased with it (SONNY-202).
            "approvedAppsForThisVisionIteration",
            "outcomeWasNotified",
            "clarificationQuestion",
            "clarificationAnswer",
            "clarificationAutoExecute",
            "clarificationWorkspaceBinding",
            // The request a clarification pause is holding on behalf of the task that asked
            // (SONNY-248). Cleared with the question it belongs to and for the same reason: the
            // pause is over, and the user's own text from a task that no longer has a record is the
            // kind of leftover this wipe exists to remove. `clarificationOrigin` is in group 4 below
            // rather than here, which is where it already was.
            "clarificationSubmittedCommand",
            "activeTaskScope",
            "ranWithoutAskingTrace",
            "explicitWorkspaceBinding",
            "pendingWorkspaceBinding",
            "preparedRun",
            "runner",
            "pendingCommandForPriorTaskContext",
            "pendingTaskHistoryStartedAt",
            "preserveUsageForNextStart",
            "memoryDeletionStatusMessage",
            // Row 13's three in-memory slots (SONNY-210). The wipe erases the file all three
            // describe: a surviving checkpoint would write its task straight back on the next unit
            // boundary, a surviving arm would let a dispatch continue a record that no longer
            // exists, and a surviving decline set would suppress an offer for an id that can only
            // now belong to a different task. (The set is the in-session half of a decline since
            // SONNY-282; the persisted half is on the record, in the file the wipe erases.)
            "activeResumableTask",
            "pendingResumableContinuation",
            "declinedResumeOfferIDs",
            // SONNY-239's Reveal in Finder control renders off this record — the list of kept files
            // it holds, and the row and count its sentence is derived from (PR #117 review, F1). The
            // wipe's own sweep has just deleted the files it names, so a surviving record would offer
            // to show the user files that are gone.
            "lastPerRowDelete",
            // SONNY-235's four: the progress a job over many items publishes, and the three inputs it
            // is computed from. Cleared for `plan`'s and `stepStatuses`' reason rather than row 13's
            // — it is what a surface renders about the run in flight — so a wipe does not leave a
            // "17 of 40" line counting records it has just deleted.
            "itemJobProgress",
            "activeItemJobPlan",
            "activeItemJobCompletedStepIDs",
            "activeItemJobFailures"
        ]

        // Not assigned by the wipe, but rewritten by the four `refresh…` calls it ends with — from
        // stores whose files the deletion has just emptied, so they come back as the empty truth
        // rather than as stale values. Covered, by a different mechanism.
        let reloadedByTheWipe: Set<String> = [
            "savedRoutines",              // refreshSavedItems()
            "savedWorkspaces",            // refreshSavedItems()
            // SONNY-382. Loaded by the same `refreshSavedItems()` the two above are, from the file
            // the wipe has just deleted — so the Routines page's Watching card comes back empty,
            // which is the truth after a wipe: every watcher in that file is gone.
            "standingWatchers",
            "savedSnippets",              // refreshMemoryEntries()
            "recentArtifacts",            // ditto
            "clipboardHistoryItems",      // ditto
            "approvedApps",               // ditto
            // Written by the same `refreshMemoryEntries()` line, from the same load, so it can
            // never be stale while `approvedApps` is fresh (PR #175 review, F1). It is the count
            // *before* the deny-list filter, which is what Settings' Remove All is offered on.
            "storedApprovedAppCount",
            "outputLocations",            // ditto (SONNY-209)
            "resumableTasks",             // ditto, via refreshResumableTasks() (SONNY-210)
            "clipboardHistoryEnabled",    // refreshClipboardHistoryNotice()
            "clipboardHistoryTimer",      // ditto, via start/stopClipboardHistoryMonitoring()
            "localStorageLoadFailures",   // record/clearLocalStorageLoadFailure, inside all four
            "localStorageNotice",         // ditto, via refreshLocalStorageNotice()
            // Reloaded by `refreshStoreReadability()`, which `refreshMemoryRowsAfterRun()` calls —
            // and the wipe reaches it the same way the four refreshes above reach the rest
            // (SONNY-239). It matters that it does: the wipe deletes the file a row was marked
            // unreadable for, so a set that survived would leave that row saying "Can't be read"
            // about a file that no longer exists.
            "unreadableStores",
            // Re-listed by `refreshSetAsideFiles()`, which `deleteLocalData` calls after either of
            // its branches (SONNY-266). The wipe sweeps the set-aside files itself, so the Data
            // page's line has to go to nothing when it succeeds — and has to keep counting the file
            // it could not remove when it does not, which is why that reload sits outside the
            // success path rather than among the refreshes above.
            "setAsideFilesSummary"
        ]

        // Deliberately untouched, in four groups.
        let outsideTheWipe: Set<String> = [
            // 1. Injected collaborators, timers and observers — not state about a task. (The wipe
            // does reset the *contents* of `logStore`, `priorTaskContextStore` and
            // `taskUsageRecorder` through their own APIs; the properties themselves are the
            // collaborators, not the state.) A new dependency belongs here.
            "logStore", "currentTask", "audioRecorder", "permissionReadinessService",
            // `voiceRecordingAutoStopTask` is a task handle beside `currentTask` above and for the
            // same reason (phase 11, the voice lane): it holds no local data, and the wipe guards on
            // `!isRunning` with nothing about a recording able to outlive one (SONNY-283's reasoning
            // for `voiceRecordingPurpose`, applied to this handle). `voiceRecordingListeningWindow`
            // sits with it as the same kind of thing `whitelist` below is: a configuration constant
            // a test shrinks, not data any wipe could find.
            "voiceRecordingAutoStopTask", "voiceRecordingListeningWindow",
            "routineStore", "workspaceStore", "snippetStore", "recentArtifactStore",
            "shortcutCatalog", "browserOpener", "appOpener", "fileOpener", "mediaOpener",
            "runningAppSwitcher", "shortcutInvoker", "finderContextReader", "documentConverter",
            "zipArchiver", "shortcutRunHistoryStore", "taskHistoryStore", "taskPlanDetailStore",
            "clipboardHistorySettingsStore", "approvedAppStore", "outputLocationStore",
            "resumableTaskStore",
            // The fourteenth store and the two things built from it (SONNY-333). All three are
            // collaborators, and the store belongs in this group for the reason the twelve above it
            // do — the wipe resets the *file*, through `localDataDeletionService`, not the handle.
            //
            // `pendingServerDeletionDelivery` sits with them rather than in the cleared group, and
            // that is a decision rather than a default. It is a `Task` handle for a background
            // delivery pass, so it holds no local data for a wipe to find; and cancelling or
            // dropping it inside the wipe would be worse than useless, because the wipe has just
            // deleted the queue file underneath it and the pass reads that file itself — a pass
            // that survives the wipe finds an empty queue and does nothing, which is exactly right.
            "pendingServerDeletionStore", "taskDeletionService", "pendingServerDeletionDelivery",
            // **`localDataWipe` is the wipe's own handle** (SONNY-404's fix round), and it is in
            // this group for a sharper version of the same reason: the wipe is what would be doing
            // the clearing, so clearing its own handle from inside itself is a task cancelling
            // itself half way through the promise it is keeping. It holds no local data either.
            "localDataWipe",
            // **The wipe's claim** (SONNY-404, PR #207's F3). A flag the run doors read, held from
            // the press to the last step; the wipe clears it itself when it finishes, and clearing
            // it from `clearInMemoryLocalDataState` — which the wipe calls *mid-sequence* — would
            // drop the claim while the sequence still had steps left. Not local data either.
            "isDeletingLocalData",
            // The count the claim is derived from (SONNY-404, PR #207's cycle-3). Same group and
            // the same reason: it belongs to the wipe that is running, and the wipe clearing its own
            // bookkeeping mid-sequence is what cycle 3 measured going wrong.
            "localDataWipesInFlight",
            // A monotone count of finished delivery passes, for the test that cannot wait on the
            // handle above (PR #194 cycle-3). Not local data and not task state — it counts
            // background work since launch, so a wipe has nothing to find in it and resetting it
            // would only make a test's wait ambiguous.
            "completedServerDeletionPasses",
            "clipboardHistoryMonitor", "finderRevealer",
            "localDataDeletionService", "memorySettingsStore", "memoryPolicyProvider",
            // `plannerProviderRegistry` and `plannerSelection` stood here and were deleted with the
            // client-side router (SONNY-132). `makePlanner` replaces them: a closure this view model
            // holds, no more local data than the stores above it are.
            "priorTaskContextStore", "taskUsageRecorder", "makePlanner",
            "userDefaults", "whitelist", "routineScheduleTimer", "wakeObserver",
            // The one HTTP client the process holds (SONNY-130). A collaborator like the stores
            // above, and emphatically not local data: the session it holds lives in the Keychain,
            // which `deleteLocalData` deliberately leaves alone — signing out and wiping local data
            // are different things, and branch 7's whole argument is that conflating them is a bug.
            "backendClient",
            // One authenticated GET over that client, wrapped as a service (SONNY-214). A
            // collaborator exactly as `backendClient` above is, and it holds nothing at all — the
            // figure it reads lives on `screenControlAllowance` in group 3.
            "screenControlAllowanceService",

            // 2. Written by `deleteLocalData` itself, immediately after the wipe returns. Clearing
            // them inside the wipe would be undone one line later.
            "finalSummary", "errorMessage", "localDataDeletionStatusMessage",

            // 3. Settings, preferences and readiness — none of it is local *data*, and a wipe that
            // silently reset the user's preferences would be a different feature.
            "errorIsPersistent", "usePointerCursors", "displayFullNames", "interactionMode",
            "voiceHotKeyStatus", "voiceHotKeyReady", "permissionItems", "clipboardHistoryPollFailure",
            // `modelAccessReadiness` is this group's own subject twice over (SONNY-136): it is the
            // readiness row's input, and the fact it reports — a session in the Keychain — is the
            // one thing `deleteLocalData` most deliberately does not touch, for the reason
            // `backendClient` gives above. A wipe that reset it would make the readiness page say
            // "sign in" to a user who still is.
            "modelAccessReadiness",
            // `planReadiness` sits beside it for the identical reason, one half further along
            // (SONNY-336): it is the same row's other input, and the fact it reports — whether this
            // Mac holds an entitlement claim it can verify — lives in the Keychain and on the
            // gateway, not in any local store this wipe reaches. A wipe that reset it would make the
            // readiness page stop reporting a confirmed plan for a user whose plan is fine, until
            // the next refresh put the same answer back.
            "planReadiness",
            // `screenControlAllowance` sits beside it for the same reason (SONNY-214): the fact it
            // carries — how many screen-control runs the account has left — lives on the gateway,
            // derived from the server's own metering, and no local store this wipe reaches has ever
            // held it. A wipe that cleared the figure would blank Command Center's usage line for a
            // user who is still signed in, until the next refresh put the same number back.
            "screenControlAllowance",
            // The auto-top-up control's two fields sit here with it (SONNY-215), and each for a
            // slightly different half of the same reason. `screenControlAutoTopUpFailure` is why the
            // last *write* of a gateway-held setting did not land — a fact about a network call, not
            // about anything under `~/Library/Application Support/Sonny/`, so a wipe has nothing to
            // find in it, and clearing it would take a sentence off a control the user is still
            // looking at. `isSettingScreenControlAutoTopUp` is in-flight bookkeeping for that one
            // request; it is `false` at rest and the wipe guards on `!isRunning` besides.
            "screenControlAutoTopUpFailure", "isSettingScreenControlAutoTopUp",
            // `plannerFallbackNotice` stood beside `scheduledRunNotice` and is gone with the widget
            // strip that rendered it (SONNY-132); `AgentViewModel` enumerates where its four states
            // went.
            "hasCompletedFirstApproval", "widgetPresentationRequest", "scheduledRunNotice",
            // `widgetWasExpandedForThisRun` is the same kind of thing (SONNY-450): whether the user has
            // summoned the widget since the current run started, derived into the run pill's minimised
            // state; transient UI state about the run in flight, holding no user data.
            "widgetWasExpandedForThisRun",
            // `standingWatcherObserver` is a collaborator; `standingWatcherCheck` and the three
            // beside it are one check's bookkeeping — a task handle, the watcher it is about, when it
            // started, and the generation that makes a late answer inert. None is state a surface
            // renders and none holds anything a wipe could find.
            //
            // **All four are in fact cleared by the wipe, through `abandonStandingWatcherCheck()`**
            // (PR #184 review, F2). They are not in `clearedByTheWipe` because that list is the
            // *direct* assignments in `clearInMemoryLocalDataState`, which is what
            // `assignmentsInClearInMemoryLocalDataState()` can read — the classification is about
            // what a property holds, not about which door clears it.
            "standingWatcherObserver", "standingWatcherCheck",
            "standingWatcherCheckSubject", "standingWatcherCheckStartedAt",
            "standingWatcherCheckGeneration",
            // `memorySettings` sits here for the sharpest version of the group's reason: a wipe
            // that switched memory back on would re-enable recording for the user who reached for
            // the most privacy-minded control in the app. It lives in `UserDefaults`, which the
            // wipe does not touch, so "off" survives it — and the in-memory copy must survive it
            // too or the surface would disagree with the store until the next refresh.
            "memorySettings",

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
            // `currentTaskID` sits here rather than in the cleared group, and the reason is what
            // it is for (SONNY-130). It is the key this run's requests are filed under, on the
            // backend and in `CompletedTaskRecord.id`; the wipe guards on `!isRunning`, so the run
            // it names has finished and nothing will use it again until `beginNewTaskIdentity()`
            // mints the next one. Clearing it would mean inventing an "no task" state for a
            // non-optional field that every run overwrites anyway.
            "command", "lastCommand", "isRunning", "activeTaskOrigin", "lastAssessedScope",
            "taskRecordingPolicy", "currentTaskID",
            "isPreparingVoiceRecording", "isRecordingVoice", "isTranscribingVoice",
            // `voiceRecordingPurpose` sits beside `voiceRecordingOrigin` for the same reason: both
            // describe the recording in progress, written at its start and read at its end, and
            // the wipe guards on `!isRunning` with no recording able to outlive a task (SONNY-283).
            "isPushToTalkHotKeyDown", "voiceRecordingOrigin", "voiceRecordingPurpose", "clarificationOrigin",
            "scheduledRunDisplayCommand",
            // `voiceRecordingStartedAt` travels with `isRecordingVoice` for the same reason those
            // sit in this group (phase 11, the voice lane): it is the timestamp of the same
            // in-flight recording, cleared everywhere `isRecordingVoice` becomes `false` again, so
            // nothing about it can outlive the run.
            "voiceRecordingStartedAt",

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
            // `screenControlGate` is row 13's billing gate (SONNY-213), and it sits in this group
            // for `visionSessionEnvironment`'s reason rather than for the in-flight ones': it is
            // infrastructure `main.swift` installs at launch, not task state. It holds no user data
            // — a decision function over a shared entitlement service and a network read — so a wipe
            // has nothing to find in it, and clearing it would leave the app refusing screen control
            // until relaunch for somebody who had erased their history.
            "screenControlGate",
            // `entitlementConfirmation` sits with it and for the same reason (SONNY-336): it is the
            // closure `main.swift` installs so the readiness row can ask the one shared
            // `EntitlementService` whether a claim confirms. Infrastructure installed at launch, not
            // task state and not user data — it holds a reference to an actor and no claim of its
            // own — and clearing it would leave the account row unable to report the plan until
            // relaunch for somebody who had erased their history.
            "entitlementConfirmation",

            // 6. A test seam, not state — `nil` in the shipping app, and nothing in `Sources/`
            // assigns it. Same category as `visionSessionEnvironment` in group 5: it lets a test
            // describe the world rather than inherit it, and it holds no user data for a wipe to
            // find. (SONNY-173.)
            "voiceConfigurationBlockerOverride",

            // 7. Contract §8's version state (SONNY-402). What a *deployment* has said about this
            // build, the observation reading it, whether the user has waved the warning away, and
            // the seam that opens the upgrade link. None of it is the user's data, none of it is
            // task state, and clearing any of it would be wrong in the same direction: a wipe would
            // hide the fact that this build is too old to reach Sonny at all, which is the one
            // sentence a user whose backend calls are all failing needs. It also comes back on its
            // own — the next response re-derives it — so a clear would be a flicker rather than a
            // change. The dismissal is per-launch by construction and a wipe is not the press that
            // should re-raise a warning the user answered a minute ago.
            "clientVersionState",
            "clientVersionObservation",
            "hasDismissedUpdateAvailablePrompt",
            "openUpgradeLink"
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
    func clearingInMemoryStateAlsoDropsAnArmedCardBinding() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let research = StoredWorkspace(name: "Research", apps: ["Safari"], urls: [])
        try fixture.workspaceStore.save(research)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(research)
        #expect(viewModel.pendingWorkspaceBinding == "Research")

        viewModel.deleteLocalData()
        // The press is asynchronous since SONNY-404's fix round: it drains the deletion queue and
        // deletes the account's server-side content before it touches a local file.
        await viewModel.localDataWipeForTests?.value

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
    /// so `canUseVoice` is already false for an unrelated reason.
    ///
    /// This used to end "that half is readable, not testable, and its proof is the declaration."
    /// It is testable as of SONNY-173: `AgentViewModel.voiceConfigurationBlockerOverride` lets a
    /// test state the configuration answer instead of inheriting the launching process's
    /// environment, and `WidgetVoiceEntryTests` exercises that half directly. This test is
    /// unchanged and still does not exercise it — what changed is that the gap is now a choice
    /// about this test's scope rather than a limit of the code. (PR #73 review, F4.)
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

    /// **SONNY-283 — a transcript recorded as an answer lands in the answer field, and nothing
    /// runs.** Founder decision 2026-08-25: the mic and the push-to-talk hotkey both feed the answer
    /// field while a question is pending. "Feed", not "send": the question is still waiting
    /// afterwards, the composer's own text is untouched, and no dispatch happened — the user reads
    /// what was heard and presses Return.
    ///
    /// Driven through `deliverTranscript`, the router the real transcription completion calls, with
    /// the purpose the recording would have been started with. The question is a real one, raised
    /// by a real run through the instant resolver, so the field being fed is the one the panel
    /// draws.
    @Test
    func aTranscriptRecordedAsAnAnswerLandsInTheAnswerFieldAndRunsNothing() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        let question = try #require(viewModel.clarificationQuestion)
        #expect(viewModel.clarificationAnswer.isEmpty)

        viewModel.deliverTranscript("2 + 2", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.clarificationAnswer == "2 + 2")
        #expect(viewModel.clarificationQuestion == question, "feeding the field is not sending it")
        #expect(viewModel.lastCommand == "=", "nothing was dispatched — the last command is still the one that asked")
        #expect(viewModel.command.isEmpty, "the composer is not where a spoken answer goes")
        #expect(viewModel.errorMessage == nil)

        // Appended at the caret, the way dictation lands: a half-typed answer keeps its half, and
        // exactly one space separates the two whatever whitespace either side carried.
        viewModel.clarificationAnswer = "the"
        viewModel.deliverTranscript("Downloads folder", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        #expect(viewModel.clarificationAnswer == "the Downloads folder")
        viewModel.clarificationAnswer = "the "
        viewModel.deliverTranscript("  Downloads folder \n", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        #expect(viewModel.clarificationAnswer == "the Downloads folder")
        // An empty transcript changes nothing.
        viewModel.deliverTranscript("   ", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        #expect(viewModel.clarificationAnswer == "the Downloads folder")
        #expect(viewModel.clarificationQuestion == question)
    }

    /// **The purpose is decided when the recording starts, and a mismatch at delivery is refused
    /// in both directions** (SONNY-283). An answer whose question has gone must not run as a
    /// command — voice commands auto-execute, and a folder name spoken in reply is not a task — and
    /// a command spoken before a question arrived must not land in that question's answer field.
    /// Each half ships with its control in the same fixture: the matching purpose does go through.
    @Test
    func aTranscriptDeliveredForAPurposeTheStateNoLongerMatchesIsRefusedBothWays() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        // A command recorded before the question arrived: refused, and the answer field stays empty.
        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        let question = try #require(viewModel.clarificationQuestion)

        viewModel.deliverTranscript("= 2 + 2", recordedFor: .command, origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.clarificationQuestion == question, "the paused question survives")
        #expect(viewModel.clarificationAnswer.isEmpty, "a command is not an answer to a question the user had not seen")
        #expect(viewModel.lastCommand == "=", "and it did not run")

        // An answer recorded while the question stood, arriving after it was cancelled: dropped.
        viewModel.cancelCurrentRun()
        #expect(viewModel.clarificationQuestion == nil)

        viewModel.deliverTranscript("= 2 + 2", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastCommand == "=", "an orphaned answer never runs as a command")
        #expect(viewModel.clarificationAnswer.isEmpty)
        #expect(viewModel.clarificationQuestion == nil)

        // The control: the same transcript, recorded as a command, with no question in the way,
        // runs — so the refusals above are about the mismatch and not about the fixture.
        viewModel.deliverTranscript("= 2 + 2", recordedFor: .command, origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.lastCommand == "= 2 + 2")
    }

    /// **The live completion routes through the purpose captured at recording start, and decides
    /// nothing itself** (SONNY-283). The completion cannot run in a test process — it needs a real
    /// transcriber and an API key — so the wiring from the captured value to the router is read
    /// rather than run, in the shape the rest of this file uses for AppKit-bound paths.
    @Test
    func theTranscriptionCompletionDeliversThroughThePurposeCapturedAtRecordingStart() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")

        let completion = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func stopVoiceRecordingAndTranscribe() {"
        )
        #expect(
            MacAgentSource.count(
                of: "deliverTranscript(result.text, recordedFor: voiceRecordingPurpose, origin: voiceRecordingOrigin)",
                inText: completion
            ) == 1
        )
        #expect(MacAgentSource.count(of: "dispatchTranscribedCommand(", inText: completion) == 0)
        #expect(MacAgentSource.count(of: "clarificationAnswer = ", inText: completion) == 0, "the completion routes; it does not decide")

        // Written exactly once, at the start of a recording, from the question standing at that
        // moment — its text, not merely its presence (F3). (The declaration carries a type
        // annotation, so it does not match this text.)
        let start = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func startVoiceRecording(trigger: VoiceRecordingTrigger, origin: TaskOrigin) {"
        )
        #expect(
            MacAgentSource.count(
                of: "voiceRecordingPurpose = .forRecordingStarted(clarificationQuestion: clarificationQuestion)",
                inText: start
            ) == 1
        )
        #expect(MacAgentSource.count(of: "voiceRecordingPurpose = ", inText: source) == 1)

        // And the router is the only caller of the answer path, so nothing can feed the field with
        // a transcript whose purpose was never decided — and the question travels with it.
        #expect(MacAgentSource.count(of: "answerClarificationWithTranscript(", inText: source) == 2, "the declaration and its one caller")
        #expect(MacAgentSource.count(of: "answerClarificationWithTranscript(transcript, answering: question)", inText: source) == 1)

        // **F4: an answer's transcription resets nothing of the paused task's.** The usage reset and
        // the summary clear are the `.command` arm's alone, inside the completion.
        // **The reset is spelled `beginNewTaskIdentity()` since SONNY-130**, which also mints the
        // run's `task_id` — the two have identical lifetimes, so they are one call rather than two
        // lines that have to be remembered together. The property this asserts is unchanged: the
        // reset is the `.command` arm's alone, and an answer's transcription resets nothing of the
        // paused task's.
        let commandArm = try MacAgentSource.region(of: completion, from: "case .command:", to: "case .clarificationAnswer:")
        #expect(MacAgentSource.count(of: "beginNewTaskIdentity()", inText: commandArm) == 1)
        #expect(MacAgentSource.count(of: "\"Transcribing voice command\"", inText: commandArm) == 1)
        #expect(MacAgentSource.count(of: "beginNewTaskIdentity()", inText: completion) == 1, "no reset outside the command arm")
        #expect(MacAgentSource.count(of: "taskUsageRecorder.reset()", inText: completion) == 0, "the reset goes through the one helper")
        #expect(MacAgentSource.count(of: "taskUsageSummary = .empty", inText: completion) == 0)
        let summaryClear = try MacAgentSource.region(
            of: completion,
            from: "if case .command = voiceRecordingPurpose {",
            to: "isTranscribingVoice = false"
        )
        #expect(MacAgentSource.count(of: "finalSummary = \"\"", inText: summaryClear) == 1)
        #expect(MacAgentSource.count(of: "finalSummary = \"\"", inText: completion) == 1, "the summary is cleared for a command and nowhere else")
        #expect(MacAgentSource.count(of: "\"Transcribing voice answer\"", inText: completion) == 1)
    }

    /// **SONNY-327 — a stop during a transcription is not a failure, and this is the route where
    /// nothing was asking.** The catch this replaces called `setError(error.localizedDescription)`
    /// for anything at all, so a cancellation would have rendered as *"Sonny couldn't finish this
    /// one. Try again."* — the sentence `TranscriptionError.backend(.cancelled)` carries, because
    /// its `errorDescription` is `SonnyBackendCopy.sentence(for: .cancelled)`.
    ///
    /// Driven through `deliverTranscriptionError`, the seam the real catch calls, for the reason
    /// `deliverTranscript`'s own doc comment gives: the live path needs a real transcriber and an
    /// API key, so the completion cannot run in a test process. The scan below is what holds the
    /// real catch to this seam; without it, this test would pass over a catch that had gone back to
    /// `setError`.
    ///
    /// **All four shapes `SonnyBackendError.isCancellation` knows, not just the obvious one.** The
    /// shape this route would actually produce is the fourth — `.cancelled` wearing
    /// `TranscriptionError`, which SONNY-320's conformance made transparent — and a test that tried
    /// only `CancellationError()` would pass against a predicate that had never learned the
    /// wrapper. The control at the end is what makes the four mean something: an ordinary
    /// transcription failure still sets the banner, so a seam that simply stopped calling
    /// `setError` fails here rather than reading as a pass.
    ///
    /// **What no test can reach today, stated so the coverage is not read as more than it is:**
    /// nothing can cancel a transcription in the shipping app — it runs in an unstructured
    /// `Task { }` that nothing stores — so this pins the sentence a stop will get, not a stop a user
    /// can currently perform. Whether one should be able to is SONNY-332's.
    @Test
    func aCancelledTranscriptionIsNotReportedAsAFailure() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        let cancellations: [any Error] = [
            CancellationError(),
            URLError(.cancelled),
            SonnyBackendError.cancelled,
            TranscriptionError.backend(.cancelled)
        ]
        for cancellation in cancellations {
            viewModel.isTranscribingVoice = true
            viewModel.errorMessage = nil
            let loggedBefore = viewModel.logStore.events.count

            viewModel.deliverTranscriptionError(cancellation)

            #expect(viewModel.errorMessage == nil, "a stop is not a failure: \(type(of: cancellation))")
            #expect(viewModel.isTranscribingVoice == false, "and the route still ends: \(type(of: cancellation))")
            let appended = viewModel.logStore.events.dropFirst(loggedBefore).map(\.message)
            #expect(
                appended == ["Transcription canceled by user"],
                "one line, and it says what happened: \(type(of: cancellation))"
            )
        }

        // The control: an ordinary failure of this route still reaches the user, with the sentence
        // the error carries and the log line that names it a failure.
        viewModel.isTranscribingVoice = true
        let failure = TranscriptionError.missingText
        let loggedBefore = viewModel.logStore.events.count

        viewModel.deliverTranscriptionError(failure)

        #expect(viewModel.isTranscribingVoice == false)
        // **The sentence is provider-neutral since SONNY-136**, which is why it changed here without
        // this test's subject changing: it read "OpenAI transcription response did not include
        // text.", and the founder's decision of 2026-08-19 is that user-visible copy names no
        // provider. What is being asserted is unchanged — that the ordinary failure reaches the user
        // with the error's own sentence and a log line naming it a failure.
        #expect(viewModel.errorMessage == "Sonny couldn't read anything back from that recording.")
        #expect(viewModel.errorMessage == failure.errorDescription)
        #expect(viewModel.errorIsPersistent == false, "try again and it is just as likely to work")
        let appended = viewModel.logStore.events.dropFirst(loggedBefore).map(\.message)
        #expect(
            appended == ["Transcription failed: Sonny couldn't read anything back from that recording."]
        )
    }

    /// **The real catch routes through that one seam, and sets no error of its own** (SONNY-327).
    /// The behavioural test above drives `deliverTranscriptionError` directly; this is what stops a
    /// later edit from putting `setError(error.localizedDescription)` back into the catch and
    /// leaving that test passing about a function nothing calls.
    ///
    /// Paired counts rather than a presence check, for the reason `MacAgentSource`'s own doc gives:
    /// a trailing comment can add a token but cannot take one away, so a swap is only visible when
    /// both sides are counted. The one surviving `setError(` in this function is the *recorder's*
    /// failure — `audioRecorder.stop()` throwing before any transcription starts — which is a real
    /// failure and stays one.
    @Test
    func theTranscriptionCatchRoutesThroughTheSeamThatAsksTheCancellationPredicate() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let stopAndTranscribe = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "private func stopVoiceRecordingAndTranscribe() {"
        )

        #expect(
            MacAgentSource.count(of: "setError(", inText: stopAndTranscribe) == 1,
            "the recorder's own failure, and nothing else in this function sets an error directly"
        )
        // And that one is outside the transcription entirely — `audioRecorder.stop()` throwing
        // before any request is made, which is a real failure and stays one. Everything the
        // transcription itself can end with is inside this task.
        let transcription = try MacAgentSource.braceBlock(of: stopAndTranscribe, openedBy: "Task {")
        #expect(MacAgentSource.count(of: "deliverTranscriptionError(error)", inText: transcription) == 1)
        #expect(MacAgentSource.count(of: "setError(", inText: transcription) == 0)

        // And the seam asks. Counted at the declaration rather than trusted from the behaviour, so
        // that deleting the guard fails this as well as the test above — two independent reads of
        // the same property, which is what a one-line guard deserves.
        let seam = try MacAgentSource.braceBlock(
            of: source,
            openedBy: "func deliverTranscriptionError(_ error: Error) {"
        )
        #expect(MacAgentSource.count(of: "guard !isCancellationError(error) else {", inText: seam) == 1)
        #expect(MacAgentSource.count(of: "setError(", inText: seam) == 1, "exactly one, and it is after the guard")
        let cancelArm = try MacAgentSource.braceBlock(of: seam, openedBy: "guard !isCancellationError(error) else {")
        #expect(MacAgentSource.count(of: "setError(", inText: cancelArm) == 0)
        #expect(MacAgentSource.count(of: "\"Transcription canceled by user\"", inText: cancelArm) == 1)

        // One seam, one caller. A second exit that skipped it would be exactly the defect this
        // ticket fixed, arriving again somewhere else in the file.
        #expect(MacAgentSource.count(of: "deliverTranscriptionError(", inText: source) == 2, "the declaration and its one caller")
    }

    /// **PR #119 review, F1 — Return while a spoken answer is still in flight keeps the question,
    /// runs nothing, and the transcript then lands.** `submitClarification` used to clear the
    /// question, the answer, the origin, the binding and the request, arm the restart, and *then*
    /// call `start()`, which refused on `!isTranscribingVoice` — leaving nothing running, the
    /// composed Q&A in the composer, the "Clarification needed" line as a result, and the task just
    /// abandoned on offer. That window needed a transcription already in flight when a question
    /// arrived; voice answering a clarification made it the ordinary case.
    ///
    /// All three voice flags, each in turn, because `canSendClarificationAnswer`'s doc says why all
    /// three are in the guard and a test of one would let the other two drift out. Then the
    /// control: the transcript lands, Send comes back, and Return sends.
    @Test
    func returnWhileVoiceInputIsInFlightKeepsTheQuestionAndTheTranscriptThenLands() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        let question = try #require(viewModel.clarificationQuestion)
        let summary = viewModel.finalSummary
        let records = viewModel.resumableTasks.map(\.id)
        viewModel.clarificationAnswer = "2 +"
        #expect(viewModel.canSendClarificationAnswer, "precondition: with no voice in flight the answer is sendable")

        let flags: [(name: String, set: (AgentViewModel, Bool) -> Void)] = [
            ("transcribing", { $0.isTranscribingVoice = $1 }),
            ("recording", { $0.isRecordingVoice = $1 }),
            ("preparing", { $0.isPreparingVoiceRecording = $1 })
        ]
        for flag in flags {
            flag.set(viewModel, true)
            #expect(viewModel.isVoiceInputInFlight, "\(flag.name)")
            #expect(!viewModel.canSendClarificationAnswer, "\(flag.name): Send must be off")

            viewModel.submitClarification()
            try await waitForViewModelToBecomeIdle(viewModel)

            #expect(viewModel.clarificationQuestion == question, "\(flag.name): the pause survives Return")
            #expect(viewModel.clarificationAnswer == "2 +", "\(flag.name): the typed half is kept")
            #expect(viewModel.command.isEmpty, "\(flag.name): nothing composed into the composer")
            #expect(viewModel.lastCommand == "=", "\(flag.name): nothing ran")
            #expect(viewModel.finalSummary == summary, "\(flag.name): the pause's own line stands")
            #expect(viewModel.resumableTasks.map(\.id) == records, "\(flag.name): no record minted")
            #expect(viewModel.resumeOffer == nil, "\(flag.name): the task is not on offer while its question stands")
            #expect(viewModel.errorMessage == nil, "\(flag.name): transient, so silent")
            flag.set(viewModel, false)
        }

        // The control: the transcript lands in the field, Send comes back, and Return sends.
        viewModel.deliverTranscript("2", recordedFor: .clarificationAnswer(question: question), origin: .widget)
        #expect(viewModel.clarificationAnswer == "2 + 2")
        #expect(viewModel.canSendClarificationAnswer)
        viewModel.submitClarification()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.lastCommand != "=" && viewModel.lastCommand.contains("2 + 2"), "the answered run dispatched")
    }

    /// **PR #119 review, F3 — the answer to one question never lands in another's field.** The
    /// guard used to ask whether *a* question was open; a second question can arrive inside the
    /// transcription's round trip, so the purpose now carries the question's text and delivery
    /// compares it. The control is the answer recorded for the second question, which does land.
    @Test
    func aTranscriptRecordedForOneQuestionIsDroppedWhenADifferentQuestionIsOpen() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "="
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)
        let first = try #require(viewModel.clarificationQuestion)

        // The first question goes and a different one takes its place before the transcript lands.
        viewModel.cancelCurrentRun()
        #expect(viewModel.clarificationQuestion == nil)
        let second = "Which workspace did you mean?"
        viewModel.clarificationQuestion = second
        #expect(second != first)

        viewModel.deliverTranscript("2 + 2", recordedFor: .clarificationAnswer(question: first), origin: .widget)
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.clarificationAnswer.isEmpty, "the first question's answer must not land in the second's field")
        #expect(viewModel.clarificationQuestion == second)
        #expect(viewModel.lastCommand == "=", "and it did not run as a command either")

        // The control: an answer recorded for the question that is open lands.
        viewModel.deliverTranscript("Research", recordedFor: .clarificationAnswer(question: second), origin: .widget)
        #expect(viewModel.clarificationAnswer == "Research")
    }

    /// **F1's wiring: the guard sits before anything is torn down, and both Send controls read the
    /// predicate it refuses on.** A guard placed after the first clear would be the defect with a
    /// log line; a Send button gated on the answer alone would be a live control for a press the
    /// state refuses — which is the widget's SONNY-173 shape from the other direction.
    @Test
    func theAnswerGateSitsBeforeTheTeardownAndBothSendControlsReadIt() throws {
        let source = try MacAgentSource.read("AgentViewModel.swift")
        let submit = try MacAgentSource.braceBlock(of: source, openedBy: "func submitClarification() {")

        #expect(MacAgentSource.count(of: "guard !isVoiceInputInFlight else {", inText: submit) == 1)
        let gate = try #require(submit.range(of: "guard !isVoiceInputInFlight else {"))
        for teardown in [
            "clarificationQuestion = nil",
            "clarificationAnswer = \"\"",
            "clarificationSubmittedCommand = nil",
            "armRestartOfTaskInFlight()",
            "start(autoExecute:"
        ] {
            let site = try #require(submit.range(of: teardown), "not in submitClarification: \(teardown)")
            #expect(gate.lowerBound < site.lowerBound, "the gate must come before \(teardown)")
        }

        // The predicate names all three voice terms, once each.
        let inFlight = try MacAgentSource.braceBlock(of: source, openedBy: "var isVoiceInputInFlight: Bool {")
        for term in ["isPreparingVoiceRecording", "isRecordingVoice", "isTranscribingVoice"] {
            #expect(MacAgentSource.count(of: term, inText: inFlight) == 1, "\(term)")
        }
        let canSend = try MacAgentSource.braceBlock(of: source, openedBy: "var canSendClarificationAnswer: Bool {")
        #expect(MacAgentSource.count(of: "!isVoiceInputInFlight", inText: canSend) == 1)

        // Both Send controls, one predicate.
        let widget = try MacAgentSource.read("FloatingWidgetView.swift")
        let panel = try MacAgentSource.braceBlock(of: widget, openedBy: "private struct WidgetClarificationPanel: View {")
        #expect(MacAgentSource.count(of: ".disabled(!canSend)", inText: panel) == 1)
        #expect(MacAgentSource.count(of: ".disabled(answer.", inText: panel) == 0, "the answer-only gate is gone")
        #expect(MacAgentSource.count(of: "canSend: viewModel.canSendClarificationAnswer", inText: widget) == 1)

        let commandCenter = try MacAgentSource.read("CommandCenterView.swift")
        let content = try MacAgentSource.braceBlock(
            of: commandCenter,
            openedBy: "private func clarificationContent(_ question: String) -> some View {"
        )
        #expect(MacAgentSource.count(of: ".disabled(!viewModel.canSendClarificationAnswer)", inText: content) == 1)
        #expect(MacAgentSource.count(of: ".disabled(viewModel.clarificationAnswer", inText: content) == 0)
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
            let firstRunSuite = FirstRunDefaultsSuite()
            defer { firstRunSuite.removeAtEndOfTest() }
            let coordinator = AppWindowCoordinator(
                viewModel: viewModel,
                accountModel: makeHermeticAccountModel(),
                screenAccessModel: makeHermeticScreenAccessModel(),
                firstRunCoordinator: firstRunSuite.makeCoordinator()
            )
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
    /// here can execute — the vision tests inject `visionSessionEnvironment` directly and bypass
    /// it. So a mutation handing the store over regardless of policy survived the whole suite.
    /// (This used to give a second reason, that `makeVisionEnvironment` returns `nil` without an
    /// API key. SONNY-131 made that builder non-Optional and SONNY-136 deleted the key; the
    /// injection is the reason that remains, and it is the one that was doing the work.)
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

    // MARK: - What a finished task stores (row E, SONNY-147)

    /// **The whole storage half, on the real dispatch path, read off the files.** A completed run
    /// keeps what it produced on its row, and the plan that produced it in the sibling store keyed
    /// on that row's own id.
    @Test
    func aCompletedRunStoresWhatItProducedAndThePlanThatProducedIt() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "= 12 + 30"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        let result = try #require(record.result)
        #expect(result.text.contains("42"))
        #expect(result.text == viewModel.finalSummary, "the row keeps the text the user was shown")
        // Every summary in the product but the vision session's is a template this repository wrote.
        #expect(result.provenance == .codeAuthored)

        let taskID = try #require(record.id)
        let detail = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: taskID))
        #expect(!detail.planSummary.isEmpty)
        #expect(detail.steps.map(\.operation) == [.calculateUtility])
        #expect(detail.completedAt == record.completedAt)
        // One row, one plan — nothing writes a second entry per run.
        #expect(try fixture.taskPlanDetailStore.loadAll().count == 1)
    }

    /// A failed run keeps the failure the user was shown, not an empty field. This is the case a
    /// stored result is most useful for and the one most easily left to a clean-finish-only path.
    @Test
    func aFailedRunStoresTheFailureTextTheUserWasShown() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        viewModel.command = "calc apples"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .failed)
        let result = try #require(record.result)
        #expect(result.text.contains("Could not calculate that expression"))
        #expect(result.text == viewModel.errorMessage)
        #expect(result.provenance == .codeAuthored)
    }

    /// A cancelled run keeps the words it ended with rather than nothing — and it still stores the
    /// plan, because a plan was prepared before the approval pause it was cancelled at.
    @Test
    func aCanceledRunStoresTheTextItEndedWithAndItsPlan() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        try fixture.snippetStore.save(StoredSnippet(trigger: ";cancel-result", expansion: "Old text"))
        viewModel.command = "snippet save ;cancel-result = Hello"

        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)
        #expect(viewModel.approvalRequest != nil)
        viewModel.cancelCurrentRun()

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .canceled)
        let result = try #require(record.result)
        #expect(result.text == "Approval canceled. No action was taken.")
        #expect(result.text == viewModel.finalSummary)

        let taskID = try #require(record.id)
        let detail = try #require(try fixture.taskPlanDetailStore.detail(forTaskID: taskID))
        #expect(detail.steps.map(\.operation) == [.saveSnippet])
    }

    /// **Suppression reaches the new store too, and is asserted rather than inherited.** The
    /// byte-identical sweep above already covers this store because it enumerates the
    /// classification — but that sweep would also pass if the store were misclassified `.artifact`,
    /// since it only compares the files a trace classification names. This names the file.
    @Test
    func aSuppressedRunStoresNeitherARowNorAPlan() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.taskRecordingPolicy = .suppressTraces
        viewModel.command = "= 7 + 7"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // The run itself happened — this is suppression, not refusal.
        #expect(viewModel.finalSummary.contains("14"))
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(try fixture.taskPlanDetailStore.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.taskPlanDetailStore.fileURL.path))
    }

    /// **The eviction handoff's plan-less branch, which is the branch the split's own condition
    /// exists for** (PR #89 review, M6).
    ///
    /// "Same cap, same eviction" is what makes the plan store share the task row's life. The two
    /// stores only stay level on their own while *every* row has a plan — and a run that fails
    /// before preparing one writes a row with none, which is exactly when the handoff has to fire.
    /// `theHistoryStoreReportsWhatItEvictedAndThePlanStoreDropsThoseInTheSameWrite` writes a plan on
    /// every row, so it exercises the branch that already worked; removing the plan-less branch's
    /// `delete(ids:)` survived the whole suite.
    ///
    /// So: two rows with plans, then a **failing** run that produces a row and no plan, at a cap of
    /// two. The failing run's row displaces the oldest, and the oldest's plan must go with it.
    @Test
    func aRowWithNoPlanStillDropsThePlanOfTheRowItEvicted() async throws {
        let fixture = try makeProductShellFixture(taskHistoryMaxItems: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        for expression in ["= 1 + 1", "= 2 + 2"] {
            viewModel.command = expression
            viewModel.start()
            try await waitForViewModelToBecomeIdle(viewModel)
        }
        let seeded = try fixture.taskHistoryStore.loadAll()
        #expect(seeded.count == 2)
        let doomedID = try #require(seeded.first?.id)
        #expect(try fixture.taskPlanDetailStore.detail(forTaskID: doomedID) != nil, "the row about to be evicted has a plan")
        #expect(try fixture.taskPlanDetailStore.loadAll().count == 2)

        // A run that fails before a plan exists: the row is written through the overload that has
        // no `preparedRun`, so `recordTaskPlanDetail` takes its plan-less branch.
        viewModel.command = "calc apples"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        let rows = try fixture.taskHistoryStore.loadAll()
        #expect(rows.count == 2, "the cap held")
        #expect(rows.map(\.command) == ["= 2 + 2", "calc apples"])
        #expect(rows.last?.outcomeStatus == .failed)
        // The failing row really did store no plan — otherwise this test drives the other branch.
        let failedID = try #require(rows.last?.id)
        #expect(try fixture.taskPlanDetailStore.detail(forTaskID: failedID) == nil)
        // And the evicted row's plan went with its row, in that same write.
        #expect(try fixture.taskPlanDetailStore.detail(forTaskID: doomedID) == nil)
        #expect(try fixture.taskPlanDetailStore.loadAll().count == 1, "only the surviving row's plan is left")
        #expect(viewModel.errorMessage?.contains("Could not calculate that expression") == true)
    }

    /// **A plan write that fails must not turn a successful task into a failed one** (PR #89
    /// cycle 2, F4).
    ///
    /// The foreground path reported this through `setError`, which writes `errorMessage` — and
    /// `publishLocalStorageLoadError`'s own doc comment, some seven hundred lines up, records exactly
    /// what that costs: "routing a corrupt-store notice there made a *successful* task render as a
    /// failure in the widget, since the widget picks `.failure` ahead of `.result`". So a task that
    /// ran, produced its result and stored its row would show "Could not save this task's plan: …"
    /// in place of what it produced. Documented mode, zero tests.
    ///
    /// A plan-persistence failure is a **degraded follow-up**, not a task failure: the run happened,
    /// the row landed, and what is lost is that a later follow-up on this task will have its command
    /// and its outcome but not its plan. It gets its own accurate channel, the same
    /// `recordLocalStorageWriteFailure` its scheduled twin uses, which is also what CLAUDE.md's
    /// write-failure gotcha requires — never the load-failure banner, whose text is hardcoded to
    /// "could not be decrypted or decoded".
    @Test(.requiresUnprivilegedProcess)
    func aPlanWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed() async throws {
        let planRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForegroundPlanFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: planRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planRoot.path)
            try? FileManager.default.removeItem(at: planRoot)
        }
        let fixture = try makeProductShellFixture(planDetailRoot: planRoot)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        // Read-only: every other store sits under the fixture root and stays writable, so the row
        // write lands and only the plan write fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: planRoot.path)

        viewModel.command = "= 12 + 30"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // The task succeeded and still says so — this is the assertion the old channel broke.
        #expect(viewModel.errorMessage == nil, "a plan-persist failure is not this task failing")
        #expect(viewModel.finalSummary.contains("42"))
        // **The premise this test's own claim rests on, pinned rather than assumed** (PR #89
        // cycle 3). This line read `!hasVisibleWidgetPanel || errorMessage == nil`, which cannot
        // fail: the line above already asserts `errorMessage == nil`, so the right disjunct is true
        // whatever the panel does — and the panel predicate is false here anyway, since this run's
        // origin is `.commandCenter`. A test line that cannot fail is this branch's own recurring
        // theme, so it is replaced rather than deleted.
        //
        // What is genuinely worth holding is the ordering the whole fix depends on: "the result
        // stays on screen because `errorMessage` is nil" is only true while `FloatingWidgetView`
        // picks `.failure` ahead of `.result`. Reorder those two arms and this fix silently stops
        // mattering, with every view-model assertion above still green. Nothing else in the suite
        // pins it, and a view-model test cannot reach the view — so it is read off the source, in
        // the scan shape this target already uses.
        let widgetState = try MacAgentSource.braceBlock(
            of: try MacAgentSource.read("AgentViewModel.swift"),
            openedBy: "var widgetState: WidgetState {"
        )
        let failureArm = try #require(widgetState.range(of: "return .failure("))
        let resultArm = try #require(widgetState.range(of: "return .result("))
        #expect(
            failureArm.lowerBound < resultArm.lowerBound,
            "the widget must still pick .failure ahead of .result, or this fix no longer keeps the result on screen"
        )

        // The row landed, with its result, and the published list agrees with the file.
        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.result?.text.contains("42") == true)
        #expect(viewModel.taskHistoryRecords.map(\.id) == [record.id])

        // And the failure is a quiet, accurate notice on the storage channel.
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not save this task's plan: "))
        #expect(!notice.contains("decrypted or decoded"))
    }

    /// **A row write that fails must not turn a successful task into a failed one either**
    /// (SONNY-201).
    ///
    /// The sibling of the plan-write test above, and it was the one neighbour still on the wrong
    /// channel: after PR #89's F4 moved the plan write onto `recordLocalStorageWriteFailure`, the two
    /// adjacent failures inside one function disagreed with each other — the plan write a notice, the
    /// row write a `setError`. So a task that ran and produced its result showed "Could not save task
    /// history: …" in place of it, which is the exact mode `publishLocalStorageLoadError` was written
    /// to end.
    ///
    /// **The heavier loss of the two, and still not a task failure.** A lost plan leaves the task
    /// fully visible with its plan missing; a lost row leaves it absent from the Tasks list, from
    /// search, from Insights and from anything a follow-up could aim at. That is worth saying — just
    /// not in the slot that means the task itself did not happen. The scheduled path already
    /// answered it this way; `ScheduledRoutineRunTests.aRowWriteFailureIsAStorageNoticeRatherThanAFailedScheduledRun`
    /// is the twin, and it is new too: the behaviour was right there and untested.
    @Test(.requiresUnprivilegedProcess)
    func aRowWriteFailureLeavesTheTaskLookingSuccessfulAndSaysWhatActuallyFailed() async throws {
        let historyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForegroundRowFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyRoot.path)
            try? FileManager.default.removeItem(at: historyRoot)
        }
        let fixture = try makeProductShellFixture(taskHistoryRoot: historyRoot)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        // Read-only: every other store, the plan store included, sits under the fixture root and
        // stays writable, so the row write is the only one that fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyRoot.path)

        viewModel.command = "= 12 + 30"
        viewModel.start()
        try await waitForViewModelToBecomeIdle(viewModel)

        // The task succeeded and still says so — the assertion the old channel broke.
        #expect(viewModel.errorMessage == nil, "a lost history row is not this task failing")
        #expect(viewModel.finalSummary.contains("42"))

        // The failure is a quiet, accurate notice on the storage channel, in write wording rather
        // than the load banner's "could not be decrypted or decoded".
        let notice = try #require(viewModel.localStorageNotice)
        #expect(notice.hasPrefix("Sonny could not save this task to task history: "))
        #expect(!notice.contains("decrypted or decoded"))

        // And the row really did not land, or this test drives some other branch entirely.
        #expect(try fixture.taskHistoryStore.loadAll().isEmpty)
        #expect(viewModel.taskHistoryRecords.isEmpty)
        // The plan store was reachable throughout, so nothing was orphaned by a write that skipped
        // it: `recordTaskPlanDetail` is never called when the row write throws, which is the
        // dependents-after-the-row rule that function's own doc comment states.
        #expect(try fixture.taskPlanDetailStore.loadAll().isEmpty)
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
        // Written through the real `save`, which is what changed on SONNY-186: `.openWorkspace` left
        // `StoredRoutine.forbiddenStepOperations`, so this routine is one a user can author and the
        // sanctioned bypass is no longer what a test needs to say here. The behaviour under test is
        // unchanged — what the *task record* says when a run descends into a routine that opens a
        // workspace — and it is now exercised against a routine the product itself could have
        // written. (PR #177's F4. The lane corrected the identical comment and call in
        // `WorkspaceTaskTaggingTests` and missed this one, because its enumeration was scoped
        // `-- Sources` and this site is under `Tests/`.)
        try fixture.routineStore.save(routine)
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

    // MARK: - What a history row's workspace means (SONNY-195, SONNY-191)
    //
    // The founder's decision of 2026-08-21: a record shows the workspace the run **actually ran in**,
    // not the one the user meant. Both defects were one root cause pointed in opposite directions —
    // `recordPriorTaskContext` derived the tag a second time, after the run terminated, from
    // `WorkspaceTaskTagging.resolvedWorkspaceName`, whose signature cannot see an explicit binding
    // and never learns whether the store answered. So the row and the boundary disagreed whenever
    // the two derivations did. See `AgentViewModel.assessedWorkspaceName`.
    //
    // Every test below drives a real dispatch and reads the row back off the file, because the two
    // derivations agree on the easy cases: a unit test of the tagger alone passes identically before
    // and after this fix. The corrupt-store case is the fourth of these and lives in
    // `AgentViewModelLocalStorageTests`, which is where a mismatched-key fixture already exists.

    /// **Under-tagging** (SONNY-195): a run bound through the workspace card wrote a row saying it
    /// ran in no workspace, while the widget's own chip said "In Research" for the whole of it.
    ///
    /// Driven through the real route rather than `start(workspaceBinding:)`: `beginTaskInWorkspace`
    /// arms `pendingWorkspaceBinding` and hands the user an empty composer, and the widget's submit
    /// is what turns that into `explicitWorkspaceBinding` — which is exactly the arm the old tagger
    /// could not see. The command is deliberately arithmetic that names nothing, since a command
    /// mentioning "Research" would have been tagged by free-text matching for a different reason and
    /// the test would pass with the fix removed.
    @Test
    func aCardBoundTaskTagsTheRecordEvenThoughItsCommandNeverNamesTheWorkspace() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        let workspace = StoredWorkspace(name: "Research", apps: [], urls: [])
        try fixture.workspaceStore.save(workspace)
        viewModel.refreshSavedItems()

        viewModel.beginTaskInWorkspace(workspace)
        #expect(viewModel.pendingWorkspaceBinding == "Research")
        let command = "= 1 + 1"
        #expect(!command.localizedCaseInsensitiveContains("research"), "nothing but the binding can tag this run")
        viewModel.command = command
        viewModel.start(origin: .widget, fromComposer: true)
        try await waitForViewModelToBecomeIdle(viewModel)

        // The run really was scoped — the half that always worked, asserted so the row's tag below
        // is being compared against something rather than merely being non-nil.
        guard case .scoped(let scope) = viewModel.lastAssessedScope else {
            Issue.record("expected a scoped run, got \(viewModel.lastAssessedScope)")
            return
        }
        #expect(scope.workspaceName == "Research")

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.workspaceName == "Research")
        // And the surface that reads the field agrees: the workspace card counts this run.
        #expect(WorkspaceTaskCount.count(forWorkspaceNamed: "Research", in: viewModel.taskHistoryRecords) == 1)
    }

    /// **Over-tagging, the deleted-workspace case** (SONNY-191). `directWorkspaceName` reads
    /// `AgentStep.workspaceName` straight off the plan with no store access, so a plan naming a
    /// workspace that is gone resolved that name anyway and the row claimed a boundary the run never
    /// had. The workspace card's count then included it, which is a number no boundary backs.
    ///
    /// The step is a `calculate_utility` rather than an `open_workspace`, deliberately: the field is
    /// read off *any* operation (`steps.compactMap(\.workspaceName).first`), and using an operation
    /// that succeeds keeps the run `.completed`, which is the only status the card counts. An
    /// `open_workspace` for a missing workspace would fail and be excluded from the count for a
    /// second reason, hiding the one under test.
    @Test
    func aPlanNamingAWorkspaceThatIsGoneLeavesTheRowUntaggedAndOutOfTheWorkspaceCount() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel
        // A healthy, readable store that simply does not contain the name the plan carries.
        try fixture.workspaceStore.save(StoredWorkspace(name: "Writing", apps: [], urls: []))
        viewModel.refreshSavedItems()

        viewModel.command = "tally the sprint numbers"
        viewModel.start(prebuiltPlan: planCalculating("1 + 1", workspaceName: "Research"))
        try await waitForViewModelToBecomeIdle(viewModel)

        // Nothing bound, and it is not a storage fault — a workspace deleted between dispatch and
        // assessment is `resolveTaskScope`'s recorded, legitimate fallback.
        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.localStorageNotice == nil)

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .completed, "the run itself succeeded, so the card would have counted it")
        #expect(record.workspaceName == nil)
        #expect(WorkspaceTaskCount.count(forWorkspaceNamed: "Research", in: viewModel.taskHistoryRecords) == 0)
    }

    /// **Over-tagging, the blank-name case** (SONNY-191, folding in PR #83's F1 note). A step
    /// carrying `workspaceName: ""` is guaranteed to produce an unscoped run — `resolveTaskScope`
    /// refuses a blank name before it touches the store — while the old tagger recorded the blank
    /// string verbatim, so the row was tagged with something that can never be a workspace and the
    /// chip would have rendered an empty one.
    ///
    /// Reachable with no tampering: the planner schema requires a `workspaceName` slot on every step
    /// and `""` is a valid value for it, and `validateStepSafety` checks operations rather than
    /// fields, so a routine can be *saved* carrying a stray blank and reproduce it on every run.
    @Test
    func aPlanCarryingABlankWorkspaceNameLeavesTheRowUntaggedRatherThanTaggingTheBlank() async throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewModel = fixture.viewModel

        viewModel.command = "tally the sprint numbers"
        viewModel.start(prebuiltPlan: planCalculating("1 + 1", workspaceName: "   "))
        try await waitForViewModelToBecomeIdle(viewModel)

        #expect(viewModel.lastAssessedScope == .unscoped)
        #expect(viewModel.localStorageNotice == nil, "a blank name is not a storage fault")

        let record = try #require(try fixture.taskHistoryStore.loadAll().last)
        #expect(record.outcomeStatus == .completed)
        #expect(record.workspaceName == nil)
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
        // (a row action) started, reaching a state *both* surfaces render controls for. Until
        // SONNY-183 this comment read "the exact state only the widget renders controls for:
        // 'Command Center itself has no approval/permission UI of its own'
        // (macagent-ui-conventions.md)" — quoting that file for a sentence it does not contain and
        // that is the opposite of what it says: `CommandCenterAttentionPanel` renders this state on
        // the four pages that host `CommandCenterStorageNotice` and wires Deny/Allow to the same
        // `cancelCurrentRun()`/`start()` entry points the widget uses. What the test asserts is
        // unchanged and is still worth pinning; only the premise was wrong.
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
        // The overflow lane's more-actions label names the workspace, not a bare "More actions"
        // (founder ask 2026-09-09).
        #expect(workspacePresentation.moreActionsAccessibilityLabel == "More actions for Research")

        let teamWorkspace = StoredWorkspace(name: "Client Work", apps: [], urls: [], teamType: .team)
        let teamPresentation = WorkspaceCardPresentation(
            workspace: teamWorkspace,
            taskHistoryRecords: taskHistoryRecords,
            iconResolver: NeverResolvingWorkspaceAppIconResolver()
        )
        #expect(teamPresentation.effectiveTeamType == .team)
        #expect(teamPresentation.isDefaultTeamType == false)
        #expect(teamPresentation.moreActionsAccessibilityLabel == "More actions for Client Work")
        #expect(teamPresentation.appIcons.isEmpty)
        #expect(teamPresentation.taskCount == 0)
        #expect(teamPresentation.taskCountText == "0 tasks")
    }

    @Test
    func savedItemRefreshImmediatelyPublishesCreatesAndUpdatesToTheSharedViewModel() throws {
        let fixture = try makeProductShellFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let widget = FloatingWidgetView(viewModel: fixture.viewModel)
        let firstRunSuite = FirstRunDefaultsSuite()
        defer { firstRunSuite.removeAtEndOfTest() }
        let commandCenter = CommandCenterView(
            viewModel: fixture.viewModel,
            accountModel: makeHermeticAccountModel(),
            screenAccessModel: makeHermeticScreenAccessModel(),
            firstRunCoordinator: firstRunSuite.makeCoordinator()
        )

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

/// A one-step plan that completes hermetically, with a `workspaceName` on the step.
///
/// The workspace field is what the tagging tests need and `calculate_utility` is what makes the run
/// terminate cleanly — `WorkspaceTaskTagging.directWorkspaceName` reads the field off *any*
/// operation, which is the documented behaviour those tests are exercising rather than a shortcut
/// around it.
private func planCalculating(_ expression: String, workspaceName: String?) -> AgentPlan {
    AgentPlan(
        summary: "Calculate \(expression).",
        requiresConfirmation: false,
        steps: [
            AgentStep(
                id: "calculate",
                operation: .calculateUtility,
                description: "Calculate \(expression).",
                workspaceName: workspaceName,
                searchQuery: expression
            )
        ]
    )
}

@MainActor
private func makeProductShellFixture(
    /// Injected only so a test can drive task-history eviction without ten thousand records — the
    /// same seam and the same reason as `TaskHistoryStore.maxItems`'s own doc comment gives.
    taskHistoryMaxItems: Int = TaskHistoryStore.defaultMaxItems,
    /// For the one test that has to make the plan store unwritable while every other store stays
    /// writable. Everything else leaves it under the fixture root.
    planDetailRoot: URL? = nil,
    /// The mirror of `planDetailRoot`, for the test that has to fail the *row* write while every
    /// other store — the plan store included — stays writable (SONNY-201).
    taskHistoryRoot: URL? = nil,
    /// The one seam in this fixture whose live implementation opens a window rather than writing a
    /// file (SONNY-395). Defaulted, unlike the stores, and safely: the default is the *inert* one,
    /// so a fixture that never heard of this parameter reveals nowhere. Only the test that asserts
    /// where a reveal ends up passes anything else.
    finderRevealer: @escaping @MainActor @Sendable ([URL]) -> Void = hermeticFinderRevealer,
) throws -> (
    viewModel: AgentViewModel,
    root: URL,
    routineStore: RoutineStore,
    workspaceStore: WorkspaceStore,
    snippetStore: SnippetStore,
    taskHistoryStore: TaskHistoryStore,
    taskPlanDetailStore: TaskPlanDetailStore,
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String,
    browserOpener: HermeticBrowserOpener,
    appOpener: HermeticAppOpener
) {
    let userDefaultsSuiteName = "ProductShellTests-\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: userDefaultsSuiteName))
    return try makeProductShellFixture(
        userDefaults: userDefaults,
        userDefaultsSuiteName: userDefaultsSuiteName,
        taskHistoryMaxItems: taskHistoryMaxItems,
        planDetailRoot: planDetailRoot,
        taskHistoryRoot: taskHistoryRoot,
        finderRevealer: finderRevealer
    )
}

@MainActor
private func makeProductShellFixture(
    userDefaults: UserDefaults,
    userDefaultsSuiteName: String? = nil,
    taskHistoryMaxItems: Int = TaskHistoryStore.defaultMaxItems,
    planDetailRoot: URL? = nil,
    taskHistoryRoot: URL? = nil,
    /// The one seam in this fixture whose live implementation opens a window rather than writing a
    /// file (SONNY-395). Defaulted, unlike the stores, and safely: the default is the *inert* one,
    /// so a fixture that never heard of this parameter reveals nowhere. Only the test that asserts
    /// where a reveal ends up passes anything else.
    finderRevealer: @escaping @MainActor @Sendable ([URL]) -> Void = hermeticFinderRevealer,
) throws -> (
    viewModel: AgentViewModel,
    root: URL,
    routineStore: RoutineStore,
    workspaceStore: WorkspaceStore,
    snippetStore: SnippetStore,
    taskHistoryStore: TaskHistoryStore,
    taskPlanDetailStore: TaskPlanDetailStore,
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
        fileURL: (taskHistoryRoot ?? root).appendingPathComponent("task-history.json"),
        encryption: encryption,
        maxItems: taskHistoryMaxItems
    )
    // Row E's plan details (SONNY-147), under the fixture root for the same reason the journal is:
    // an un-injected store resolves to the user's real
    // ~/Library/Application Support/Sonny/task-plan-details.json.
    let taskPlanDetailStore = TaskPlanDetailStore(
        fileURL: (planDetailRoot ?? root).appendingPathComponent("task-plan-details.json"),
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
        finderRevealer: finderRevealer,
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
        taskPlanDetailStore: taskPlanDetailStore,
        // Injected under the fixture root rather than defaulted, or it resolves to the real
        // ~/Library/Application Support/Sonny/vision-sessions.json. No test read it before
        // SONNY-120, so nothing was wrong yet — which is exactly the hermeticity-by-accident the
        // seam comment above describes.
        visionSessionJournalStore: VisionSessionJournalStore(
            fileURL: root.appendingPathComponent("vision-sessions.json"),
            encryption: encryption
        ),
        clipboardHistorySettingsStore: clipboardSettingsStore,
        approvedAppStore: ApprovedAppStore(
            fileURL: root.appendingPathComponent("approved-apps.json"),
            encryption: encryption
        ),
        outputLocationStore: OutputLocationStore(
            fileURL: root.appendingPathComponent("output-locations.json"),
            encryption: encryption,
            // The same roots this fixture hands the view model, so the store answers
            // "is this an output location" against the folders the run really used.
            whitelist: PathWhitelist(roots: [root])
        ),
        resumableTaskStore: ResumableTaskStore(
            fileURL: root.appendingPathComponent("resumable-tasks.json"),
            encryption: encryption
        ),
        pendingServerDeletionStore: PendingServerDeletionStore(
            fileURL: root.appendingPathComponent("pending-server-deletions.json")
        ),
        standingWatcherObserver: UnreachableStandingWatcherObserver(),
        clipboardHistoryMonitor: ClipboardHistoryMonitor(
            reader: ProductShellPasteboardReader(),
            store: ClipboardHistoryStore(
                fileURL: root.appendingPathComponent("clipboard-history.json"),
                encryption: encryption
            ),
            settingsStore: clipboardSettingsStore
        ),
        localDataDeletionService: LocalDataDeletionService(fileURLs: []),
        // SONNY-130: undefaulted like the stores, and for a worse reason — this client holds the
        // Keychain session every packaged build on this Mac shares. Hermetic: no environment, so
        // every request fails before a URL is built, and an in-memory Keychain of its own.
        backendClient: makeHermeticBackendClient(),
        priorTaskContextStore: PriorTaskContextStore(),
        taskUsageRecorder: TaskUsageRecorder(),
        userDefaults: userDefaults,
        // The fixture root, so the REAL dispatch path can assess and execute file-writing plans
        // (drafts above all) hermetically — the seam whose absence let a green mapping suite
        // coexist with a live app that behaved differently (2026-08-13 manual-pass finding).
        whitelist: PathWhitelist(roots: [root])
    )
    let suiteName = userDefaultsSuiteName ?? "ProductShellInjected-\(UUID().uuidString)"
    return (viewModel, root, routineStore, workspaceStore, snippetStore, taskHistoryStore, taskPlanDetailStore, userDefaults, suiteName, browserOpener, appOpener)
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

/// A pasteboard that is always empty and never changes.
///
/// **Here because six fixtures had no pasteboard seam at all**
/// (SONNY-240). `ClipboardHistoryMonitor`'s own defaults are the real `clipboard-history.json` and
/// the real `NSPasteboard`, so a fixture that let `clipboardHistoryMonitor:` default had a monitor
/// that would have copied the developer's actual clipboard into the developer's actual store file,
/// under the deterministic test key the packaged app cannot read. That parameter is required now, so
/// this is what the six of them pass. `private` copies of this already exist in five files, each
/// serving a suite that asserts on what the reader returned; this one is for a fixture that only
/// needs the monitor to be inert.
final class HermeticPasteboardReader: PasteboardReading {
    var changeCount = 0

    func typeIdentifiers() -> [String] {
        []
    }

    func stringValue() -> String? {
        nil
    }
}

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

/// The inert stand-in for `AgentViewModel`'s `finderRevealer`, beside the other hermetic seams and
/// for the same reason: the live one calls `NSWorkspace.activateFileViewerSelecting`, so a fixture
/// that reached it would steal focus and open Finder windows in the middle of a suite run
/// (SONNY-239). The parameter is undefaulted, per SONNY-240's rule applied to something that is not
/// a store, so the compiler asks every fixture — and this is what all fourteen of them answer.
///
/// A function rather than a type, because the seam is a closure: `MemoryCommandCenterTests` needs
/// to record what was revealed and has `MemoryFixtureFinderRevealer` for that, and every other
/// fixture only needs the call to go nowhere.
@MainActor
func hermeticFinderRevealer(_ urls: [URL]) {
    _ = urls
}

/// The recording counterpart of the stand-in above, for the one test that asserts *where* a reveal
/// ends up (SONNY-395). `@unchecked Sendable` with a lock because the seam is a `@Sendable` closure.
final class ProductShellFinderRevealer: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[URL]] = []

    func record(_ urls: [URL]) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(urls)
    }

    var calls: [[URL]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
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
