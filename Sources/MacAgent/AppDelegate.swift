import AppKit
import Combine
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let viewModel: AgentViewModel
    private let accountModel: SonnyAccountModel
    private let screenAccessModel: ScreenAccessOnboardingModel
    private let firstRunCoordinator: FirstRunCoordinator
    /// The interface-theme preference, applied to `NSApp` at launch and on every change; Settings
    /// binds its picker to this one instance through the Command Center's environment.
    private let appearanceModel = SonnyAppearanceModel()
    /// Per-kind on/off for native notifications, read by `notificationService`'s gate below and
    /// bound to by Settings › Notifications through the Command Center's environment — the same
    /// path `appearanceModel` takes.
    private let notificationPreferences = SonnyNotificationPreferences()
    /// The information-density preference (founder ask, 2026-09-09), bound to by Settings ›
    /// Preferences through the Command Center's environment — the same path `appearanceModel` takes.
    private let densityModel = SonnyDensityModel()
    private lazy var windowCoordinator = AppWindowCoordinator(
        viewModel: viewModel,
        accountModel: accountModel,
        screenAccessModel: screenAccessModel,
        firstRunCoordinator: firstRunCoordinator,
        appearanceModel: appearanceModel,
        notificationPreferences: notificationPreferences,
        densityModel: densityModel
    )
    private lazy var widgetController = FloatingWidgetWindowController(viewModel: viewModel)
    /// The run pill the widget minimises into while a run is in flight (SONNY-450).
    private lazy var runPillController = RunPillWindowController(viewModel: viewModel)
    /// The minimised state last applied to the two windows, so `applyWidgetMinimisation` moves a
    /// window only on a change.
    private var appliedWidgetMinimised = false
    private lazy var notificationService = SonnyNotificationService(
        onAllow: { [weak self] in self?.viewModel.start() },
        onRetry: { [weak self] in self?.viewModel.retryLastCommand() },
        // Routed through the presentation counter rather than calling `show()` directly, so every
        // hand-driven summon converges on the one mechanism SONNY-8 built. That also buys the
        // expansion this ticket needs for free: `FloatingWidgetView` already observes
        // `widgetPresentationRequest` and calls `expandFromCompact()` when it is compact, so
        // clicking a notification now lands on the outcome rather than on an empty capsule.
        // `show()` alone could never have done that — it has no reference to the view's `isCompact`
        // state at all. (SONNY-121; the open question SONNY-25 recorded and left for whoever
        // revisited outcome retention.)
        onOpen: { [weak self] in self?.requestWidgetPresentation() },
        // A finished run's notification opens that task's detail dialog in Command Center, not the
        // widget — the founder's decision of 2026-08-17 (PR #67 review, F4). The widget renders
        // nothing for a Command-Center-origin result, so the old shared handler expanded it onto an
        // empty composer.
        onOpenTask: { [weak self] taskID in
            guard let self else { return }
            windowCoordinator.showCommandCenter()
            // No id, or a task that is no longer in history: Command Center still comes forward,
            // which is the honest fallback — there is no dialog to open.
            guard let taskID else { return }
            _ = viewModel.requestTaskDetail(taskID: taskID)
        },
        // A scheduled routine's notice opens Command Center (SONNY-113). That is where its controls
        // are: the notice strip carrying the reason renders on four pages there, and a schedule
        // Sonny paused is switched back on from the Routines page. The widget shows the same notice
        // as a strip, but it has no control for the thing the worst case needs doing.
        onOpenScheduledRun: { [weak self] in
            self?.windowCoordinator.showCommandCenter()
        },
        // A storage notice opens Command Center too (SONNY-187). Same destination as the scheduled
        // notice and for a similar reason: the notice renders there as a row on four pages, and
        // Settings' local-data controls are the nearest thing to somewhere to act on it. Its own
        // closure rather than sharing that one, because they are two decisions about two notices
        // that happen to agree today.
        onOpenStorageNotice: { [weak self] in
            self?.windowCoordinator.showCommandCenter()
        },
        // A watcher notice's click, and it is deliberately a fifth closure rather than a reuse of the
        // fourth (SONNY-236). Command Center is where a watcher is listed and where its Stop control
        // will be, so the two agree today — and they are still separate decisions about separate
        // notices, which is the reason `onOpenStorageNotice` gives for not sharing the third.
        onOpenWatcherNotice: { [weak self] in
            self?.windowCoordinator.showCommandCenter()
        },
        isEnabled: { [notificationPreferences] kind in notificationPreferences.isEnabled(kind) }
    )
    private var pushToTalkHotKey: PushToTalkHotKey?
    private var cancellables: Set<AnyCancellable> = []

    /// Nothing about the delegate is touched at construction time: every AppKit-owning collaborator
    /// below is `lazy`, so an unlaunched delegate registers no status item, no hotkey, and no
    /// Combine subscriptions.
    ///
    /// **`viewModel` has no default, and this parameter is why the rule needed stating twice**
    /// (SONNY-240, PR #109 review F4). It was `= .atItsRealStoreLocations()` for one round: a
    /// defaulted parameter resolving to the real `~/Library` stores, invisible at every call site —
    /// precisely the shape SONNY-240 removed from `AgentViewModel.init`, recreated one level up. A
    /// test writing `AppDelegate()` got the developer's own data and passed every check, because the
    /// scan looks for the factory's *name* and a bare `AppDelegate()` never spells it.
    ///
    /// So the name is spelled where it is meant: `main.swift` writes
    /// `AppDelegate(viewModel: .atItsRealStoreLocations())` and is the only file in `Sources/` other
    /// than the one declaring it that mentions it at all —
    /// `LocalStoreInjectionScanTests.onlyMainAsksForTheRealStoreLocations` holds that as a
    /// population, so the door cannot be reopened here or anywhere else under another name.
    /// `accountModel` follows the same rule for the same reason, one store further out: its default
    /// would be the Keychain every packaged build on this Mac shares, and a test writing
    /// `AppDelegate(viewModel:)` would have read and deleted the founder's own session (SONNY-128).
    /// `screenAccessModel` and `firstRunCoordinator` follow it (SONNY-137): the first reads this
    /// machine's real TCC grants, the second writes two flags into the `UserDefaults` domain every
    /// packaged build here shares — including "first run is over", which a fixture flipping it would
    /// take away from the founder silently.
    init(
        viewModel: AgentViewModel,
        accountModel: SonnyAccountModel,
        screenAccessModel: ScreenAccessOnboardingModel,
        firstRunCoordinator: FirstRunCoordinator
    ) {
        self.viewModel = viewModel
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any window exists, so the first frame is drawn in the chosen appearance.
        appearanceModel.apply()
        registerBundledFonts()

        // The app shipped with no main menu at all until 2026-07-30 — `main.swift` is a bare
        // AppKit lifecycle with no SwiftUI Scene to synthesize one — which silently broke every
        // menu-routed key equivalent (⌘A/⌘C/⌘V/⌘X/⌘Z in any text field, and app-wide ⌘Q): macOS
        // dispatches those by matching against main-menu items, so with no menu they never reach
        // the first responder at all. Typing worked because that is direct key input. Installed
        // even though an accessory-policy app displays no menu bar — visibility and key-equivalent
        // routing are separate — and the bar *is* visible whenever Command Center has the app in
        // `.regular` policy.
        let mainMenu = makeMainMenu()
        NSApp.mainMenu = mainMenu
        // Installed here rather than inside the builder: `NSApp` is nil in a test process, and the
        // builder is what `ProductShellTests` calls to assert the wiring.
        NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
        // The Help menu gets the system's own search field once it is `NSApp.helpMenu`, which
        // searches every menu item's title, so the shortcuts sheet is one way to find a command
        // and the Help menu is the other.
        NSApp.helpMenu = mainMenu.item(withTitle: "Help")?.submenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars.inverse", accessibilityDescription: "Sonny")
        item.button?.imagePosition = .imageOnly
        // A persistent `menu` (rather than a custom click handler) shows on any click, left or
        // right — modern macOS renders it with the same translucent, rounded-corner chrome as
        // native menu-bar dropdowns for free. The prior custom handler only showed this menu on
        // right-click, which is exactly why "Open Command Center" (titled "Open Sonny" until
        // SONNY-338) and "Quit Sonny" read as missing entirely.
        item.menu = makeStatusMenu()
        statusItem = item
        observeStatusItemState()

        do {
            pushToTalkHotKey = try PushToTalkHotKey(
                onPress: { [weak self] in
                    self?.handlePushToTalkPress()
                },
                onRelease: { [weak self] in
                    self?.handlePushToTalkRelease()
                }
            )
        } catch {
            viewModel.markVoiceHotKeyUnavailable(error.localizedDescription)
            print("Sonny could not register push-to-talk hotkey: \(error.localizedDescription)")
        }

        // The Keychain read and the first-run decision, in that order and in one place — see
        // `decideFirstRunAfterRestoringTheSession()` for why they are one method.
        Task { await decideFirstRunAfterRestoringTheSession() }

        // Contract §8.3's launch half: "The client calls `GET /v1/meta` on launch and on any `410`.
        // It does not call it per request." (SONNY-402.)
        //
        // **Its own task rather than a line inside the one above, because the two must not wait on
        // each other.** That one reads the Keychain and decides first run, and this one makes a
        // network call; sequencing them would put a launch decision the user sees immediately behind
        // a request that can take this route's whole twenty-second budget on a bad connection. They
        // share nothing — the meta route is unauthenticated, so it needs no session — and neither
        // reads what the other writes.
        //
        // The "on any `410`" half needs no call site at all: it lives inside
        // `SonnyBackendClient.send`, the one place every route's refusal passes through.
        Task { await viewModel.beginWatchingClientVersion() }

        observeNotificationTriggers()
        observeWidgetPresentationRequests()
        observeWidgetMinimisation()
        // Starts the schedule tick and the wake observer. Deliberately after the notification and
        // presentation subscriptions above: the first check runs synchronously inside this call, so
        // anything it reports must already have somewhere to go.
        viewModel.startRoutineScheduling()

        // Row 13's unfinished runs (SONNY-210), read once at launch.
        //
        // **Here and not on a view's `onAppear`, because the surface that needs it is the widget.**
        // Every other Memory list is loaded by `refreshMemoryEntries()` when the Memory page
        // appears, which is enough for a page. This list also decides whether the widget offers to
        // carry on with a task the user was partway through when the app last stopped — and the
        // whole point of that offer is that it reaches someone who never opens Command Center. The
        // widget shows the panel off published state, so the state has to exist before it renders.
        viewModel.refreshResumableTasks()

        // The deliveries a previous run could not make (SONNY-333), retried once at launch — the
        // "retry it on next launch" half of the founders' decision of 2026-08-30.
        //
        // **Here rather than beside the session restore above, and it needs nothing from it.**
        // `SonnyBackendClient` reads the Keychain the first time it is asked for a token, so this
        // pass authenticates itself; sequencing it after `decideFirstRunAfterRestoringTheSession()`
        // would buy nothing and would tie a background sweep to the first-run decision. It reaches
        // no surface either way: a pass that finds nothing owed makes no request, and one that
        // cannot reach the gateway leaves the queue exactly as it found it.
        viewModel.sweepPendingServerDeletions()

        // Both surfaces open on launch, matching Wispr Flow's reference behavior — a real,
        // confirmed tradeoff: this also makes the Dock icon a permanent fixture, since
        // PrimaryWindowActivationManager only switches out of accessory mode when Command Center
        // is shown, and it's now shown unconditionally on every launch, not on demand.
        windowCoordinator.showCommandCenter()
        widgetController.show()
    }

    /// Reads the Keychain, then decides first run on what it found. **One method because the two
    /// halves are one decision, and separating them is the failure this sequence exists to prevent.**
    ///
    /// `restore()` reads the Keychain and touches no network, so the app comes back signed in on a
    /// relaunch with no connection — including the relaunch macOS forces after a Screen Recording
    /// grant, which is the case SONNY-128 exists for.
    ///
    /// **What goes wrong if the order or the freshness slips** (SONNY-137). `restore()` is
    /// asynchronous, and everything after the `Task` in `applicationDidFinishLaunching` runs before
    /// it finishes. So a decision taken beside that task rather than inside it — or taken inside it
    /// on a value read *before* the `await`, or on a literal — is taken against `isSignedIn ==
    /// false` for every launch, including the one right after the Screen Recording grant, where it
    /// hands a sign-in step to a user who signed in a minute ago. All three shapes produce the same
    /// user-visible bug and only one of them changes the statement order, which is why this is
    /// driven by a test rather than pinned by a scan of two lines
    /// (`ProductShellTests.theLaunchDecidesFirstRunOnTheSessionTheKeychainActuallyHeld`; PR #159's
    /// review, F3, where two mutants that kept the order and broke the value both survived).
    ///
    /// Internal rather than `private` so that test can drive it: `applicationDidFinishLaunching`
    /// cannot be called in a test process, and this is the part of it that has to be right.
    /// `FirstRunCoordinator.begin` decides once; every later change of state goes through `refresh`,
    /// which does nothing until it has.
    func decideFirstRunAfterRestoringTheSession() async {
        await accountModel.restore()
        firstRunCoordinator.begin(
            isSignedIn: accountModel.isSignedIn,
            screenRecordingGranted: screenAccessModel.screenRecordingGranted,
            accessibilityTrusted: screenAccessModel.accessibilityTrusted
        )
    }

    /// Only post a system notification when neither surface already showing the same state inline
    /// (the floating widget's permission row / failure row) is in front of the user — otherwise
    /// it's a redundant second prompt for something already on screen.
    /// The one definition of "do not interrupt", read by every notification subscription below.
    ///
    /// **Replaces the old `isAnySonnySurfaceVisible`, which had been permanently `true` since the
    /// widget became a permanent overlay — so every notification path was dead.** That test asked
    /// whether a Sonny surface was *on screen*; the widget always is, by the founder's decision of
    /// 2026-07-20, whose own record predicted this ("notifications ship as real, working code that's
    /// simply unused for now"). The founder's rule of 2026-08-17 replaces it: notify when Sonny is
    /// not the app the user is working in.
    ///
    /// Both halves are load-bearing. Activation alone would interrupt someone in the middle of
    /// typing into the widget, because `.nonactivatingPanel` means that typing deliberately does not
    /// activate the app. See `SonnyAttention`, where the rule lives and is tested.
    private var isUserWorkingInSonny: Bool {
        SonnyAttention.isUserWorkingInSonny(
            isApplicationActive: NSApp.isActive || windowCoordinator.commandCenterWindow?.isKeyWindow == true,
            isWidgetPanelKey: widgetController.isPanelKey
        )
    }

    /// Command Center has no composer of its own anymore — quick actions like "New routine"/
    /// "Create workspace" pre-fill `viewModel.command` and need the widget to come forward so the
    /// user can finish typing there. The status menu's "New Task" item and the push-to-talk hotkey
    /// ride the same subscription (see `requestWidgetPresentation()`). Independent of
    /// `notificationService`'s bundle-identity guard: showing the widget works identically under
    /// `swift run`, unlike system notifications.
    private func observeWidgetPresentationRequests() {
        viewModel.$widgetPresentationRequest
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // **The pill goes before the widget comes, in one synchronous step** (PR #237's
                // first review, F1). A summon is an expansion by the view model's rule, but that
                // rule lands a main-queue hop later through `observeWidgetMinimisation()`; this
                // sink fires first, so without these two lines the widget was fronted while the
                // pill was still ordered front, and the deferred correction then fronted the widget
                // a second time. Hiding the pill here and recording the applied state makes the
                // transition atomic and the later apply a no-op. Nothing derived is read here —
                // `@Published` publishes before the mutation lands, so the flag still reads its
                // old value inside this sink; only the two window calls happen.
                self.runPillController.hide()
                self.appliedWidgetMinimised = false
                self.widgetController.show()
            }
            .store(in: &cancellables)
    }

    /// The widget minimises into the run pill while `AgentViewModel.isWidgetMinimised` holds and
    /// comes back when it stops (SONNY-450). The state is derived on the view model from several
    /// published properties, so this listens to `objectWillChange`, reads the value one main-queue
    /// hop later (the publisher fires before the mutation lands), and moves a window only when
    /// the answer changed. Idempotent by construction: `show()` and `hide()` on a window already in
    /// that state do nothing visible.
    private func observeWidgetMinimisation() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyWidgetMinimisation()
            }
            .store(in: &cancellables)
    }

    private func applyWidgetMinimisation() {
        let minimised = viewModel.isWidgetMinimised
        guard minimised != appliedWidgetMinimised else {
            return
        }
        appliedWidgetMinimised = minimised
        if minimised {
            widgetController.hide()
            runPillController.show()
        } else {
            runPillController.hide()
            // Key focus only when the user asked for the widget (the pill's click, or any other
            // summon, which sets the flag); a widget returning on its own because its pill has
            // nothing left to show takes no focus.
            widgetController.show(takingKey: viewModel.widgetWasExpandedForThisRun)
        }
    }

    private func observeNotificationTriggers() {
        guard let notificationService else {
            print(
                "Sonny is running without a real app-bundle identity (e.g. via `swift run`), so " +
                "system notifications are unavailable — this is expected outside a packaged .app; " +
                "the floating widget's inline UI covers approvals/errors either way."
            )
            return
        }

        viewModel.$approvalRequest
            .compactMap { $0 }
            .sink { [weak self] request in
                guard let self, !isUserWorkingInSonny else {
                    return
                }
                notificationService.postPermissionNotification(resource: request.approvalCopy.involvedResource)
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isUserWorkingInSonny else {
                    return
                }
                notificationService.postErrorNotification(message: message)
                // The user was pulled away, so this outcome must still be here when they come back
                // (SONNY-121). The gate above is the only thing that knows they were elsewhere, so
                // recording it here is not a convenience — the view model cannot work it out.
                viewModel.markOutcomeAsNotified()
            }
            .store(in: &cancellables)

        // Local-storage problems moved off `errorMessage` so a corrupt store can't make a
        // successful task read as failed. They still deserve the same fallback notification when
        // no Sonny surface is in front of the user, so subscribe to the new channel too.
        //
        // **Its own category, not `postErrorNotification` (SONNY-187).** Moving the notice off
        // `errorMessage` and then posting it in the failure notification category undid the move at
        // the last hop: the banner arrived with a Retry button wired to `retryLastCommand()`, so
        // "your snippets file could not be decrypted" offered to re-dispatch whatever the user last
        // typed. See `SonnyNotificationCategory.storage`. The same shape SONNY-113 gave the
        // scheduled channel, one channel later.
        viewModel.$localStorageNotice
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isUserWorkingInSonny else {
                    return
                }
                notificationService.postStorageNoticeNotification(message: message)
            }
            .store(in: &cancellables)

        // A finished run's own outcome — the gap SONNY-44 found and the founder resolved on
        // 2026-08-06. A run started from a Command Center row action reports its result on no
        // surface at all: the widget's result panel is origin-gated to `.widget`, and Command Center
        // renders progress and failures but has no result panel for the widget's to duplicate.
        //
        // Only successes arrive here — `completedRunNotice` is written on the success path alone,
        // because a failure already reaches the user through `errorMessage` above and would
        // otherwise notify twice for one run.
        viewModel.$completedRunNotice
            .compactMap { $0 }
            .sink { [weak self] notice in
                guard let self, !isUserWorkingInSonny else {
                    return
                }
                notificationService.postOutcomeNotification(summary: notice.summary, taskID: notice.taskID)
            }
            .store(in: &cancellables)

        // Scheduled runs are the one case this fallback was actually designed for: the run happens
        // with nobody watching, which is precisely when no Sonny surface is in front of the user.
        //
        // **This used to end "unlike the two above, this path is genuinely reachable rather than
        // accepted-as-unused", and that contrast is now false in both directions (SONNY-113).** When
        // it was written every path was dead, this one included — `isAnySonnySurfaceVisible` was
        // permanently true. Since SONNY-56 replaced that gate, every path here is reachable, so
        // there is nothing to be unlike. A sentence that stayed on the page through the change that
        // falsified it is exactly what makes a comment worse than none: a session reading it would
        // conclude the other subscriptions are still decorative.
        //
        // Its own category, not `postErrorNotification` (SONNY-113). See
        // `SonnyNotificationCategory.scheduled` for why the Retry button that carried was wrong
        // twice over — a success wearing a failure's chrome, and an action that re-runs the user's
        // own last command rather than the routine.
        viewModel.$scheduledRunNotice
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isUserWorkingInSonny else {
                    return
                }
                notificationService.postScheduledRunNotification(message: message)
            }
            .store(in: &cancellables)

        // A standing watcher (SONNY-236). Like the scheduled channel above, this fires with nobody
        // watching — but here that is the feature rather than a case the fallback covers: a watcher
        // exists precisely because the user is not going to be present when the thing happens, and a
        // notification is the whole of what it may do.
        //
        // **This is the one channel with no `isUserWorkingInSonny` gate, and the asymmetry is the
        // whole point rather than an oversight** (PR #184 review, F1). For the four channels above,
        // the gate is free: whatever it suppresses is already on a Sonny surface the user is looking
        // at — an approval in the widget's panel, a storage notice as a Memory row, a scheduled
        // notice on the Routines page. **`watcherNotice` is rendered by no view at all**, so the
        // gate was not deduplication, it was deletion: `finishStandingWatcher` publishes the
        // sentence, the sink dropped it, and the next statement deletes the watcher's record. The
        // single output of the entire feature was gone, unrecoverably, in what is arguably its most
        // common case — a user who happens to have Sonny frontmost when a page they asked about
        // changes.
        //
        // **A banner arriving while the user is in Sonny is the cheap failure; silence is not.** The
        // alternative fix is to render `watcherNotice` on a surface, which is SONNY-382's work
        // pulled forward — and even with that surface built, this channel would still want no gate,
        // because a watcher's notice is news about the outside world rather than a restatement of
        // something already on screen.
        //
        // The comment that stood here argued the gate was acceptable because a suppressed notice was
        // "visible only as `watcherNotice` in Command Center". That was false about this tree, and a
        // claim that a surface exists when it does not is what kept this invisible to three sessions.
        viewModel.$watcherNotice
            .compactMap { $0 }
            .sink { message in
                notificationService.postWatcherNotification(message: message)
            }
            .store(in: &cancellables)
    }

    /// Deliberately not `Bundle.module` (SwiftPM's auto-generated resource accessor). That
    /// generated code resolves the resource bundle via `Bundle.main.bundleURL.appendingPathComponent(
    /// "MacAgent_MacAgent.bundle")` — correct for a bare `swift run` executable, where
    /// `Bundle.main.bundleURL` is `.build/.../debug/` and the bundle sits right next to it, but
    /// wrong for a real packaged `.app`: there, `Bundle.main.bundleURL` is the outer `.app`
    /// directory, and Apple's code-signing format refuses to seal anything at that top level
    /// outside `Contents/` (confirmed directly: `codesign` fails with "unsealed contents present
    /// in the bundle root" when the resource bundle sits there) — so a real signed `.app` can
    /// never satisfy that lookup, and `Bundle.module`'s generated accessor calls `fatalError` the
    /// instant anything touches it if the bundle isn't found. This resolves the same bundle by
    /// trying both real locations (packaged `.app`'s codesign-safe `Contents/Resources/`, ordered
    /// first since it's the common real-usage case going forward, and the bare-executable
    /// top-level layout `swift run` already produces) and degrades to system fonts instead of
    /// crashing the app over a missing decorative asset if neither is found.
    private static func resolvedResourceBundle() -> Bundle? {
        let candidateURLs = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MacAgent_MacAgent.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("MacAgent_MacAgent.bundle")
        ]
        for url in candidateURLs {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    private func registerBundledFonts() {
        guard let resourceBundle = Self.resolvedResourceBundle() else {
            print("Sonny could not locate its bundled fonts resource bundle — using system fonts instead.")
            return
        }

        for fontName in [
            "InstrumentSerif-Regular",
            "GolosText-Regular",
            "Inter-VariableFont_opsz,wght"
        ] {
            guard let url = resourceBundle.url(forResource: fontName, withExtension: "ttf")
                ?? resourceBundle.url(forResource: fontName, withExtension: "ttf", subdirectory: "Fonts")
            else {
                print("Sonny could not find bundled font: \(fontName)")
                continue
            }

            var error: Unmanaged<CFError>?
            guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
                  let registrationError = error?.takeRetainedValue()
            else {
                continue
            }

            print("Sonny could not register font \(fontName): \(registrationError.localizedDescription)")
        }
    }

    /// **Placed after the notification subscriptions on purpose.** `StandingWatcherRunTests` finds the
    /// notification channels by the *first* `viewModel.$errorMessage` in this file and reads the
    /// region up to its `.store`, expecting the `!isUserWorkingInSonny` gate; this observer reads the
    /// same publisher with no gate (it is not a notification), so it has to come later in the file.
    /// The menu-bar glyph follows Sonny's state, so a user in another app can see whether Sonny is
    /// working, waiting for them, or stopped on a failure without opening anything. The mapping
    /// lives in `StatusItemPresentation`; this only applies it. Template images take
    /// `contentTintColor` on a status-bar button, so the idle state hands the tint back to the bar.
    private func observeStatusItemState() {
        Publishers.CombineLatest3(
            viewModel.$isRunning,
            viewModel.$approvalRequest.map { $0 != nil },
            viewModel.$errorMessage.map { $0 != nil }
        )
        .map { isRunning, isAwaitingApproval, hasFailure in
            StatusItemPresentation.forState(
                isRunning: isRunning,
                isAwaitingApproval: isAwaitingApproval,
                hasFailure: hasFailure
            )
        }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] presentation in
            self?.applyStatusItemPresentation(presentation)
        }
        .store(in: &cancellables)
    }

    private func applyStatusItemPresentation(_ presentation: StatusItemPresentation) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: presentation.systemImageName,
            accessibilityDescription: presentation.accessibilityLabel
        )
        switch presentation.tint {
        case .plain:
            button.contentTintColor = nil
        case .accent:
            button.contentTintColor = NSColor(SonnyTheme.accent)
        case .attention:
            button.contentTintColor = NSColor(SonnyTheme.warning)
        case .failure:
            button.contentTintColor = NSColor(SonnyTheme.danger)
        }
        button.toolTip = presentation.accessibilityLabel
    }


    /// The real `NSApp.mainMenu`, distinct from `makeStatusMenu()`'s status-item dropdown. Two
    /// menus, deliberately: an Edit menu because that is what routes the standard editing
    /// key equivalents to the first responder (nil targets → responder chain), and an app menu
    /// carrying About, Settings, the standard Hide items and Quit — the first top-level item renders as the bold app menu whenever
    /// the bar is visible (`.regular` policy), so leaving Edit first would put "Edit" in the
    /// app-name slot, and ⌘Q was equally menu-routed and equally broken (the status menu's own
    /// "q" equivalent only dispatches while that dropdown is open). No File or View menu: nothing
    /// in the app needs them; a Help menu (phase 10) carries the Keyboard shortcuts sheet and the
    /// system's search field. "Settings…" is here too (phase 3) because a Mac app's own
    /// app menu is where a user expects to find it, ⌘, included, beside the account menu's own row;
    /// "About Sonny" and the Hide items (phase 9) for the same reason, the latter with nil targets
    /// so AppKit's own `hide:`, `hideOtherApplications:` and `unhideAllApplications:` answer them.
    /// Internal, like `makeStatusMenu()`, so `ProductShellTests` can assert the wiring by selector.
    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Sonny",
            action: #selector(openAbout),
            keyEquivalent: ""
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sonny", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Sonny",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        // `Selector(("undo:"))` / `Selector(("redo:"))`: not declared on NSResponder, but text
        // views resolve them through the responder chain's undo manager — the standard AppKit
        // wiring for hand-built Edit menus.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        // The capital "Z" key equivalent implies ⇧⌘Z — AppKit reads an uppercase letter as
        // requiring Shift.
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // A Window menu, so ⌘W and ⌘M route the way they do in every Mac app: to the key window
        // through the responder chain, with nil targets. The Keyboard shortcuts sheet lists both.
        // Titled "Window" because `applicationDidFinishLaunching` finds it by that title to make
        // it `NSApp.windowsMenu`.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.title = "Window"
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Titled "Help" for the same lookup, which makes it `NSApp.helpMenu`. Its one item targets
        // the delegate like About and Settings do, so ⌘/ opens the sheet from anywhere in the app,
        // the widget included; the window's own hidden ⌘/ button still answers first while it is key.
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(
            withTitle: "Keyboard shortcuts",
            action: #selector(openKeyboardShortcuts),
            keyEquivalent: "/"
        ).target = self
        helpMenuItem.title = "Help"
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }

    /// The unambiguous actions and nothing else — no "Recent"/usage section, since Sonny has no
    /// real equivalent to a chat-app's usage percentage and its actual analog (recent tasks) is a
    /// deliberate follow-up, not silently fabricated here. The first item is named as the sidebar
    /// names the same action ("Ask Sonny", the founder's ⌘N wording), because one action with two
    /// names on two surfaces is the inconsistency the modernization removes; Settings… sits here
    /// as it does in every menu-bar app's dropdown.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Ask Sonny",
            action: #selector(requestWidgetPresentation),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Open Command Center",
            action: #selector(openCommandCenter),
            keyEquivalent: ""
        ).target = self
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sonny",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self
        return menu
    }

    /// The one way anything in the app asks for the floating widget by hand. It bumps the shared
    /// counter rather than calling `widgetController.show()` directly, because `show()` only fronts
    /// the panel — it cannot move keyboard focus, which lives in `FloatingWidgetView`'s own
    /// `@FocusState`. The bump drives both halves at once: `observeWidgetPresentationRequests()`
    /// turns it into the `show()` call, and `FloatingWidgetView`'s `onChange` puts the cursor in
    /// the composer (expanding the compact capsule first, if it had collapsed). Calling `show()`
    /// straight from the menu item is exactly why the status menu's first item read as doing nothing when the widget
    /// was already on screen: the panel was re-fronted, and nothing else happened.
    ///
    /// `@objc` because the status menu item targets it by selector; Command Center's own row
    /// actions bump `widgetPresentationRequest` directly for the same reason, so every hand-driven
    /// entry point converges on one mechanism instead of each growing its own.
    @objc func requestWidgetPresentation() {
        viewModel.widgetPresentationRequest += 1
    }

    /// Split out of the `PushToTalkHotKey` closure so the hotkey shares the menu item's presentation
    /// path verbatim, and so it is reachable from tests — a test process cannot register a real
    /// Carbon hotkey to fire the closure for it. The presentation request is deliberately
    /// unconditional and comes first: `beginPushToTalkVoice()` may refuse to record (no API key, a
    /// run already in flight) and surface an error instead, and that error is only worth surfacing
    /// if the widget is coming forward to show it.
    func handlePushToTalkPress() {
        requestWidgetPresentation()
        viewModel.beginPushToTalkVoice()
    }

    func handlePushToTalkRelease() {
        viewModel.endPushToTalkVoice()
    }

    /// Internal rather than `private`, like `requestWidgetPresentation()` above, so the status
    /// menu's wiring is assertable by selector from `ProductShellTests` — a title-only assertion
    /// leaves a rewired item green, which is exactly what a reviewer's decoy-selector mutation
    /// caught on this branch.
    @objc func openCommandCenter() {
        windowCoordinator.showCommandCenter()
    }

    /// The app menu's "Settings…" item. `internal` rather than `private`, matching
    /// `openCommandCenter()`'s own reason: it targets `self` by selector, and a rewired selector is
    /// exactly the class of bug a title-only assertion cannot catch.
    @objc func openSettings() {
        windowCoordinator.showSettings()
    }

    /// The app menu's "About Sonny" item, internal for the same reason as `openSettings()`.
    @objc func openAbout() {
        windowCoordinator.showAbout()
    }

    /// The Help menu's "Keyboard shortcuts" item, likewise.
    @objc func openKeyboardShortcuts() {
        windowCoordinator.showKeyboardShortcuts()
    }

    /// A Dock click, a second launch from Spotlight or Launchpad, a Finder double-click while the
    /// app already runs. `hasVisibleWindows` counts the widget's panel, so the coordinator decides
    /// on Command Center's own visibility instead; `true` keeps AppKit's default reopen behaviour
    /// (activation, and deminiaturizing) on top.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowCoordinator.handleReopen()
        return true
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
