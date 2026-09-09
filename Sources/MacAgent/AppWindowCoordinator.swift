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

    private let activationManager: PrimaryWindowActivationManager
    private var commandCenterWindowController: NSWindowController?

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
        activationManager: PrimaryWindowActivationManager = PrimaryWindowActivationManager()
    ) {
        self.viewModel = viewModel
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        self.appearanceModel = appearanceModel
        self.notificationPreferences = notificationPreferences
        self.activationManager = activationManager
        super.init()
    }

    func showCommandCenter() {
        let controller = commandCenterWindowController ?? makeCommandCenterWindowController()
        commandCenterWindowController = controller
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
    }

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
        )
        let window = makeWindow(
            title: "Sonny",
            contentSize: NSSize(width: 1_180, height: 780),
            minimumSize: NSSize(width: 900, height: 620),
            autosaveName: "SonnyCommandCenterWindow",
            contentViewController: hostingController
        )
        window.delegate = self
        return NSWindowController(window: window)
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
        window.isReleasedWhenClosed = false
        let restoredSavedFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
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
