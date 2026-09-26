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

/// Sonny is a menu-bar app with a Dock icon only while one of its windows is open.
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

/// Owns the Command Center window and the requests that open its sheets.
@MainActor
final class AppWindowCoordinator: NSObject, NSWindowDelegate {
    let model: SonnyAppModel
    let accountModel: SonnyAccountModel
    let screenAccessModel: ScreenAccessOnboardingModel
    let firstRunCoordinator: FirstRunCoordinator
    let appearanceModel: SonnyAppearanceModel
    let notificationPreferences: SonnyNotificationPreferences
    let densityModel: SonnyDensityModel
    let commandCenterCommands = CommandCenterCommands()
    let commandKeyHintModel = CommandKeyHintModel()

    private let activationManager = PrimaryWindowActivationManager()
    private var windowController: NSWindowController?
    private var commandKeyEventMonitor: Any?
    /// A fresh autosave name so every Mac gets V2's default size once.
    private static let autosaveName = "SonnyCommandCenterWindow.v3"

    init(
        model: SonnyAppModel,
        accountModel: SonnyAccountModel,
        screenAccessModel: ScreenAccessOnboardingModel,
        firstRunCoordinator: FirstRunCoordinator,
        appearanceModel: SonnyAppearanceModel,
        notificationPreferences: SonnyNotificationPreferences,
        densityModel: SonnyDensityModel
    ) {
        self.model = model
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        self.appearanceModel = appearanceModel
        self.notificationPreferences = notificationPreferences
        self.densityModel = densityModel
        super.init()
    }

    var window: NSWindow? { windowController?.window }

    var isCommandCenterVisible: Bool { window?.isVisible ?? false }

    func showCommandCenter() {
        let controller = windowController ?? makeWindowController()
        windowController = controller
        installCommandKeyHintMonitor()
        guard let window = controller.window else { return }
        activationManager.presentWindow(id: ObjectIdentifier(window))
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        showCommandCenter()
        commandCenterCommands.settingsRequests += 1
    }

    func showAbout() {
        showCommandCenter()
        commandCenterCommands.aboutRequests += 1
    }

    func showKeyboardShortcuts() {
        showCommandCenter()
        commandCenterCommands.shortcutsRequests += 1
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        activationManager.closeWindow(id: ObjectIdentifier(window))
        removeCommandKeyHintMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        commandKeyHintModel.focusLost()
    }

    private func makeWindowController() -> NSWindowController {
        let hosting = NSHostingController(
            rootView: CommandCenterView(
                model: model,
                accountModel: accountModel,
                screenAccessModel: screenAccessModel,
                firstRunCoordinator: firstRunCoordinator
            )
            .environmentObject(appearanceModel)
            .environmentObject(commandCenterCommands)
            .environmentObject(notificationPreferences)
            .environmentObject(densityModel)
            .environmentObject(commandKeyHintModel)
        )
        hosting.sizingOptions = []
        let size = NSSize(width: 1_180, height: 780)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sonny"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 900, height: 620)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.delegate = self
        let controller = NSWindowController(window: window)
        controller.windowFrameAutosaveName = Self.autosaveName
        return controller
    }

    /// Holding ⌘ alone shows the shortcut badges.
    private func installCommandKeyHintMonitor() {
        guard commandKeyEventMonitor == nil else { return }
        commandKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                commandKeyHintModel.flagsChanged(commandHeldAlone: CommandKeyChord.isCommandHeldAlone(event.modifierFlags))
            case .keyDown:
                commandKeyHintModel.otherKeyPressed()
            default:
                break
            }
            return event
        }
    }

    private func removeCommandKeyHintMonitor() {
        if let commandKeyEventMonitor { NSEvent.removeMonitor(commandKeyEventMonitor) }
        commandKeyEventMonitor = nil
    }
}
