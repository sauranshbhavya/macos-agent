import AppKit
import Combine
import MacAgentCore
import SwiftUI

/// Starts Sonny: the menus, the menu-bar item, the hotkeys, first run, the widget and the Command
/// Center, all over one `SonnyAppModel`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: SonnyAppModel
    private let accountModel: SonnyAccountModel
    private let screenAccessModel: ScreenAccessOnboardingModel
    private let firstRunCoordinator: FirstRunCoordinator
    private let appearanceModel = SonnyAppearanceModel()
    private let notificationPreferences = SonnyNotificationPreferences()
    private let densityModel = SonnyDensityModel()
    private lazy var windowCoordinator = AppWindowCoordinator(
        model: model,
        accountModel: accountModel,
        screenAccessModel: screenAccessModel,
        firstRunCoordinator: firstRunCoordinator,
        appearanceModel: appearanceModel,
        notificationPreferences: notificationPreferences,
        densityModel: densityModel
    )
    private lazy var widget = WidgetWindowController(model: model)
    private var notifier: TaskNotifier?
    private var statusItem: NSStatusItem?
    private var pushToTalkHotKey: PushToTalkHotKey?
    private var emergencyStopHotKey: EmergencyStopHotKey?
    private var sheetTerminationObservation: NSObjectProtocol?
    private var watching: Set<AnyCancellable> = []

    init(
        model: SonnyAppModel,
        accountModel: SonnyAccountModel,
        screenAccessModel: ScreenAccessOnboardingModel,
        firstRunCoordinator: FirstRunCoordinator
    ) {
        self.model = model
        self.accountModel = accountModel
        self.screenAccessModel = screenAccessModel
        self.firstRunCoordinator = firstRunCoordinator
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceModel.apply()
        registerBundledFonts()
        if let appIcon = SonnyBrandAssets.appIcon {
            NSApp.applicationIconImage = appIcon
        }
        sheetTerminationObservation = SheetTerminationRelease.install(on: .default, windows: { NSApp.windows })

        let mainMenu = makeMainMenu()
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = mainMenu.item(withTitle: "Help")?.submenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = SonnyBrandAssets.mark
            ?? NSImage(systemSymbolName: "wand.and.stars.inverse", accessibilityDescription: "Sonny")
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.imagePosition = .imageOnly
        item.menu = makeStatusMenu()
        statusItem = item

        do {
            pushToTalkHotKey = try PushToTalkHotKey(
                onPress: { [weak self] in self?.model.beginVoice() },
                onRelease: { [weak self] in self?.model.finishVoice() }
            )
        } catch {
            model.markVoiceHotKeyUnavailable()
        }
        emergencyStopHotKey = try? EmergencyStopHotKey { [weak self] in self?.model.stopEverything() }

        notifier = TaskNotifier(model: model, preferences: notificationPreferences) { [weak self] in
            guard let self else { return false }
            return SonnyAttention.shouldNotify(
                isApplicationActive: NSApp.isActive || windowCoordinator.window?.isKeyWindow == true,
                isWidgetPanelKey: widget.isPanelKey
            )
        }
        observeTasksForTheMenuBar()
        model.$widgetRequests.dropFirst().sink { [weak self] _ in self?.widget.show() }.store(in: &watching)
        Task { await decideFirstRunAfterRestoringTheSession() }
        Task { await model.start() }

        windowCoordinator.showCommandCenter()
        widget.show()
    }

    /// First run is decided on the session the Keychain actually holds, so it is read first.
    func decideFirstRunAfterRestoringTheSession() async {
        await accountModel.restore()
        firstRunCoordinator.begin(
            isSignedIn: accountModel.isSignedIn,
            screenRecordingGranted: screenAccessModel.screenRecordingGranted,
            accessibilityTrusted: screenAccessModel.accessibilityTrusted
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !windowCoordinator.isCommandCenterVisible { windowCoordinator.showCommandCenter() }
        return true
    }

    // MARK: Menu bar

    /// The menu-bar mark takes the accent while a task runs, the warning colour while one waits on
    /// the person, and the danger colour after one fails.
    private func observeTasksForTheMenuBar() {
        model.controller.$tasks
            .map { tasks in
                StatusItemPresentation.forState(
                    isRunning: tasks.contains { !$0.phase.isTerminal },
                    isAwaitingApproval: tasks.contains { $0.needsThePerson },
                    hasFailure: tasks.last.map { if case .failed = $0.phase { true } else { false } } ?? false
                )
            }
            .removeDuplicates()
            .sink { [weak self] presentation in self?.apply(presentation) }
            .store(in: &watching)
    }

    private func apply(_ presentation: StatusItemPresentation) {
        guard let button = statusItem?.button else { return }
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.accessibilityLabel
        switch presentation.tint {
        case .plain: button.contentTintColor = nil
        case .accent: button.contentTintColor = NSColor(SonnyTheme.accent)
        case .attention: button.contentTintColor = NSColor(SonnyTheme.warning)
        case .failure: button.contentTintColor = NSColor(SonnyTheme.danger)
        }
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Ask Sonny", action: #selector(askSonny), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Stop Sonny", action: #selector(stopSonny), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Command Center", action: #selector(openCommandCenter), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sonny", action: #selector(quit), keyEquivalent: "q").target = self
        return menu
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Sonny", action: #selector(openAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sonny", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sonny", action: #selector(quit), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.title = "Window"
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Keyboard shortcuts", action: #selector(openKeyboardShortcuts), keyEquivalent: "/").target = self
        helpMenuItem.title = "Help"
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        return mainMenu
    }

    @objc private func askSonny() { model.showWidget() }
    @objc private func stopSonny() { model.stopEverything() }
    @objc private func openCommandCenter() { windowCoordinator.showCommandCenter() }
    @objc private func openSettings() { windowCoordinator.showSettings() }
    @objc private func openAbout() { windowCoordinator.showAbout() }
    @objc private func openKeyboardShortcuts() { windowCoordinator.showKeyboardShortcuts() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: Fonts

    private func registerBundledFonts() {
        guard let resourceBundle = SonnyResourceBundle.resolved() else { return }
        for fontName in ["InstrumentSerif-Regular", "GolosText-Regular", "Inter-VariableFont_opsz,wght"] {
            guard let url = resourceBundle.url(forResource: fontName, withExtension: "ttf")
                ?? resourceBundle.url(forResource: fontName, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
