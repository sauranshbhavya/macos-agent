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
        activationManager: PrimaryWindowActivationManager = PrimaryWindowActivationManager()
    ) {
        self.viewModel = viewModel
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        self.activationManager = activationManager
        super.init()
    }

    func showCommandCenter() {
        let controller = commandCenterWindowController ?? makeCommandCenterWindowController()
        commandCenterWindowController = controller
        present(controller)
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
