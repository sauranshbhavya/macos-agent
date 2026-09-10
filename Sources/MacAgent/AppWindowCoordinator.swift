import AppKit
import SwiftUI

@MainActor
protocol ApplicationActivationApplying: AnyObject {
    func activateAsRegularApplication()
    func returnToAccessoryApplication()
}

@MainActor
final class SystemApplicationActivationAdapter: ApplicationActivationApplying {
    func activateAsRegularApplication() {
        let application = NSApplication.shared
        _ = application.setActivationPolicy(.regular)
        application.activate(ignoringOtherApps: true)
    }

    func returnToAccessoryApplication() {
        _ = NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@MainActor
final class PrimaryWindowActivationManager {
    private let application: any ApplicationActivationApplying
    private var openWindowIDs: Set<ObjectIdentifier> = []

    init(application: any ApplicationActivationApplying = SystemApplicationActivationAdapter()) {
        self.application = application
    }

    func presentWindow(id: ObjectIdentifier) {
        openWindowIDs.insert(id)
        application.activateAsRegularApplication()
    }

    func closeWindow(id: ObjectIdentifier) {
        openWindowIDs.remove(id)
        if openWindowIDs.isEmpty {
            application.returnToAccessoryApplication()
        }
    }
}

@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    let viewModel: AgentViewModel
    let accountModel: SonnyAccountModel
    let screenAccessModel: ScreenAccessOnboardingModel
    let firstRunCoordinator: FirstRunCoordinator
    let appearanceModel: SonnyAppearanceModel
    // Created here rather than injected: it carries no state a fixture would need to control, only
    // a counter the main menu's "Settings…" item bumps, so there is nothing for a caller to supply.
    let commandCenterCommands = CommandCenterCommands()
    let notificationPreferences: SonnyNotificationPreferences
    let densityModel: SonnyDensityModel
    // Created here for the same reason `commandCenterCommands` is: it carries no state a fixture
    // would need to control, only a transient on-screen flag fed by the local event monitor below,
    // and nothing about it is written to disk (phase 14, the founders' hold-⌘ hints ask).
    let commandKeyHintModel = CommandKeyHintModel()

    private let activationManager: PrimaryWindowActivationManager
    private var commandCenterWindowController: NSWindowController?
    /// Installed each time Command Center is shown (`showCommandCenter`) and removed when it closes
    /// (`windowWillClose`); the monitor outlives neither. `Any?` is `addLocalMonitorForEvents`'s own
    /// return type. On every show rather than once when the window is made, because the window
    /// controller is kept and reused after a close: an install tied to its making ran once per
    /// process while the removal ran on every close, and the hints were gone for good after the
    /// first close (phase 14's review, F2).
    private var commandKeyEventMonitor: Any?

    /// Whether the hold-⌘ monitor is in place right now; what the window test reads across a
    /// show, a close and a second show.
    var isCommandKeyHintMonitorInstalled: Bool {
        commandKeyEventMonitor != nil
    }

    var commandCenterWindow: NSWindow? {
        commandCenterWindowController?.window
    }

    /// **`accountModel` has no default**, for the reason `AppDelegate.init(viewModel:)` has none:
    /// a default resolving to the real Keychain is invisible at every call site that predates the
    /// parameter, which is SONNY-240's argument applied to the one store every packaged build on
    /// this Mac shares. `screenAccessModel` and `firstRunCoordinator` carry the same rule through to
    /// Command Center (SONNY-137), which is where first run is presented and where Settings ›
    /// Security & Access reads the same screen-access model.
    init(
        viewModel: AgentViewModel,
        accountModel: SonnyAccountModel,
        screenAccessModel: ScreenAccessOnboardingModel,
        firstRunCoordinator: FirstRunCoordinator,
        // Defaulted, unlike the stores above, because it is a cosmetic preference read from plain
        // `UserDefaults` and written only when the user changes it: a fixture that omits it reads
        // a value and writes nothing, which is the opposite of the real-store hazard the rule above
        // guards against.
        appearanceModel: SonnyAppearanceModel = SonnyAppearanceModel(),
        // Defaulted for the same reason `appearanceModel` is: a cosmetic preference read from plain
        // `UserDefaults` and written only when the user changes it, so a fixture that omits it reads
        // a value and writes nothing rather than reaching a real store.
        notificationPreferences: SonnyNotificationPreferences = SonnyNotificationPreferences(),
        // Defaulted for the same reason `appearanceModel` and `notificationPreferences` are: a
        // cosmetic preference read from plain `UserDefaults` and written only when the user drags
        // the slider, so a fixture that omits it reads a value and writes nothing rather than
        // reaching a real store.
        densityModel: SonnyDensityModel = SonnyDensityModel(),
        activationManager: PrimaryWindowActivationManager = PrimaryWindowActivationManager()
    ) {
        self.viewModel = viewModel
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        self.appearanceModel = appearanceModel
        self.notificationPreferences = notificationPreferences
        self.densityModel = densityModel
        self.activationManager = activationManager
        super.init()
    }

    func showCommandCenter() {
        let controller = commandCenterWindowController ?? makeCommandCenterWindowController()
        commandCenterWindowController = controller
        installCommandKeyHintMonitor()
        present(controller)
    }

    /// The app menu's "Settings…" item. Brings Command Center forward first — Settings is a sheet
    /// presented over it, and the item is enabled whether or not that window already exists — then
    /// bumps the counter `CommandCenterView` is watching, which is the same effect its own
    /// account-menu "Settings" row has.
    func showSettings() {
        showCommandCenter()
        commandCenterCommands.settingsRequests += 1
    }

    /// The app menu's "About Sonny", through the same door as Settings: front the window, then
    /// ask the view to present the sheet its account menu already presents.
    func showAbout() {
        showCommandCenter()
        commandCenterCommands.aboutRequests += 1
    }

    /// The Help menu's "Keyboard shortcuts", through the same door again.
    func showKeyboardShortcuts() {
        showCommandCenter()
        commandCenterCommands.shortcutsRequests += 1
    }

    /// Whether Command Center is on screen right now: a window that was never made, or was closed,
    /// or is miniaturized, is not.
    var isCommandCenterVisible: Bool {
        commandCenterWindow?.isVisible ?? false
    }

    /// What the app does when it is asked to open while already running: a Dock click, a second
    /// launch from Spotlight or Launchpad, a Finder double-click. With Command Center on screen
    /// AppKit's own activation is the whole answer; without it, the window is what the person
    /// asked for, since the app has no other window of its own to show (the widget is a panel and
    /// runs as an accessory once Command Center closes).
    func handleReopen() {
        if !isCommandCenterVisible {
            showCommandCenter()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }
        activationManager.closeWindow(id: ObjectIdentifier(window))
        removeCommandKeyHintMonitor()
    }

    /// A local monitor sees nothing once another window is key — the widget's panel, another app —
    /// so a glimpse that was on screen when focus left would otherwise stay there until this window's
    /// next event (phase 14's review, F3 of the rules lane). Losing key status hides the hints and
    /// drops any hold still counting.
    func windowDidResignKey(_ notification: Notification) {
        commandKeyHintModel.focusLost()
    }

    // Renamed from "SonnyCommandCenterWindow" (2026-09-10, this phase): `makeWindow` below restores
    // whatever a Mac last resized *this* autosave key to, and a Mac that already had a smaller frame
    // saved under the old name would otherwise keep restoring it forever, never seeing the new
    // default even once. A fresh key means every Mac gets the new default on its next launch and
    // keeps whatever it resizes to after that — the same one-time-reset shape a stored preference's
    // key gets when its default changes. Named once here since two call sites now need it: the
    // window's own restore-or-center logic, and the window controller's autosave binding below.
    private static let commandCenterAutosaveName = "SonnyCommandCenterWindow.v2"

    private func makeCommandCenterWindowController() -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: CommandCenterView(
                viewModel: viewModel,
                accountModel: accountModel,
                screenAccessModel: screenAccessModel,
                firstRunCoordinator: firstRunCoordinator
            )
            // The Settings sheet reads the theme picker's model from here; a sheet inherits its
            // presenter's environment.
            .environmentObject(appearanceModel)
            // Read by `CommandCenterView`'s `onChange` so the app menu's "Settings…" item can open
            // the sheet without a direct reference to this view's `@State`.
            .environmentObject(commandCenterCommands)
            .environmentObject(notificationPreferences)
            .environmentObject(densityModel)
            .environmentObject(commandKeyHintModel)
        )
        // Without this, `NSHostingController` keeps the window sized to its SwiftUI content's own
        // preferred size for the life of the window, not only at creation — `CommandCenterView`'s
        // root carries a `minWidth`/`minHeight` and no `idealWidth`/`idealHeight`, so its preferred
        // size is that minimum, and a later layout pass (state changing after `.onAppear`, for one)
        // would silently shrink the window back to 900×620 even after `makeWindow` below sets the
        // size explicitly. An empty set turns that automatic resizing off entirely, leaving the
        // window's size exactly what `NSWindow(contentRect:)`/`setContentSize` and the user's own
        // resizing make it.
        hostingController.sizingOptions = []
        let window = makeWindow(
            title: "Sonny",
            // Raised from 1180×780 to 1280×840 (2026-09-10 founder ask: "make the default size of
            // the command center, when it opens, slightly bigger"). The minimum stays 900×620 —
            // that is the floor the layout still works at, not the size a fresh install opens to.
            contentSize: NSSize(width: 1_280, height: 840),
            minimumSize: NSSize(width: 900, height: 620),
            autosaveName: Self.commandCenterAutosaveName,
            contentViewController: hostingController
        )
        window.delegate = self
        let controller = NSWindowController(window: window)
        // **On the controller, not only the window — this is the fix, not decoration.** `NSWindow`
        // has its own `setFrameAutosaveName(_:)`, which is what this used to call directly here, and
        // it silently loses to `NSWindowController.showWindow(_:)`: that method resyncs the window's
        // autosave name from the *controller's* `windowFrameAutosaveName` (empty by default for a
        // bare `NSWindowController(window:)`), which clears whatever the window had just been given.
        // Measured directly (a throwaway script reproduced it byte for byte outside this app): a
        // window's `setFrameAutosaveName` call reads back correctly right up until `showWindow(nil)`
        // runs, after which `frameAutosaveName` is empty again — so every frame this window was ever
        // resized to was silently never saved, and every launch centred it at the default size
        // instead of restoring anything. Setting the name here, on the controller, is what
        // `showWindow(nil)` in `present(_:)` does not clear; `makeWindow` still calls
        // `setFrameUsingName` itself first, only to decide whether to centre a window with no saved
        // frame yet, and this reapplies the same lookup (Apple's own documented side effect of this
        // assignment) with no visible effect when it agrees, which is every time until it disagrees.
        controller.windowFrameAutosaveName = Self.commandCenterAutosaveName
        return controller
    }

    /// Phase 14's hold-⌘ hints. `.flagsChanged` tells `commandKeyHintModel` whether ⌘ is down alone;
    /// `.keyDown` tells it a key fired, which ends a hold or a showing hint immediately (a
    /// ⌘-shortcut firing must never leave its badges lingering over the page it just opened). The
    /// event is returned untouched either way, so nothing else observing these events changes.
    /// Idempotent — a show while the monitor is already in place is a no-op — which is what lets
    /// `showCommandCenter` call it every time rather than only when the window is made.
    private func installCommandKeyHintMonitor() {
        guard commandKeyEventMonitor == nil else { return }
        commandKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                self.commandKeyHintModel.flagsChanged(commandHeldAlone: CommandKeyChord.isCommandHeldAlone(event.modifierFlags))
            case .keyDown:
                self.commandKeyHintModel.otherKeyPressed()
            default:
                break
            }
            return event
        }
    }

    private func removeCommandKeyHintMonitor() {
        if let commandKeyEventMonitor {
            NSEvent.removeMonitor(commandKeyEventMonitor)
        }
        commandKeyEventMonitor = nil
    }

    private func makeWindow(
        title: String,
        contentSize: NSSize,
        minimumSize: NSSize,
        autosaveName: String,
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        // The sidebar's wordmark already says "Sonny" under the traffic lights; a second one
        // centred in the transparent title bar is the one thing this window would show twice.
        // The title itself stays set for the Window menu, Mission Control and accessibility.
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = minimumSize
        window.contentViewController = contentViewController
        // Assigning `contentViewController` hands the window over to `NSHostingController`'s own
        // preferred-content-size logic, which for a SwiftUI view whose root carries only a
        // `minWidth`/`minHeight` (no `idealWidth`/`idealHeight` — `CommandCenterView`'s own root
        // frame is exactly that) resolves to that minimum rather than the size the window was just
        // created with: measured directly, the window this produced was 900×620 regardless of the
        // 1_280×840 passed to `NSWindow(contentRect:)` above. Setting it again here, after the
        // content view controller is in place, is what makes the requested size stick.
        window.setContentSize(contentSize)
        window.isReleasedWhenClosed = false
        let restoredSavedFrame = window.setFrameUsingName(autosaveName)
        if !restoredSavedFrame {
            window.center()
        }
        return window
    }

    private func present(_ controller: NSWindowController) {
        guard let window = controller.window else {
            return
        }
        activationManager.presentWindow(id: ObjectIdentifier(window))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
