import AppKit
import Combine
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let viewModel: AgentViewModel
    private lazy var windowCoordinator = AppWindowCoordinator(viewModel: viewModel)
    private lazy var widgetController = FloatingWidgetWindowController(viewModel: viewModel)
    private lazy var notificationService = SonnyNotificationService(
        onAllow: { [weak self] in self?.viewModel.start() },
        onRetry: { [weak self] in self?.viewModel.retryLastCommand() },
        onOpen: { [weak self] in self?.widgetController.show() }
    )
    private var pushToTalkHotKey: PushToTalkHotKey?
    private var cancellables: Set<AnyCancellable> = []

    /// Injectable purely so tests can drive the menu and hotkey entry points against a fixture
    /// view model — `main.swift` still constructs the delegate with no arguments and gets the same
    /// real, fully-defaulted `AgentViewModel` it always did. Nothing else about the delegate is
    /// touched at construction time: every AppKit-owning collaborator below is `lazy`, so an
    /// unlaunched delegate registers no status item, no hotkey, and no Combine subscriptions.
    init(viewModel: AgentViewModel = AgentViewModel()) {
        self.viewModel = viewModel
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()

        // The app shipped with no main menu at all until 2026-07-30 — `main.swift` is a bare
        // AppKit lifecycle with no SwiftUI Scene to synthesize one — which silently broke every
        // menu-routed key equivalent (⌘A/⌘C/⌘V/⌘X/⌘Z in any text field, and app-wide ⌘Q): macOS
        // dispatches those by matching against main-menu items, so with no menu they never reach
        // the first responder at all. Typing worked because that is direct key input. Installed
        // even though an accessory-policy app displays no menu bar — visibility and key-equivalent
        // routing are separate — and the bar *is* visible whenever Command Center has the app in
        // `.regular` policy.
        NSApp.mainMenu = makeMainMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars.inverse", accessibilityDescription: "Sonny")
        item.button?.imagePosition = .imageOnly
        // A persistent `menu` (rather than a custom click handler) shows on any click, left or
        // right — modern macOS renders it with the same translucent, rounded-corner chrome as
        // native menu-bar dropdowns for free. The prior custom handler only showed this menu on
        // right-click, which is exactly why "Open Sonny"/"Quit Sonny" read as missing entirely.
        item.menu = makeStatusMenu()
        statusItem = item

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

        observeNotificationTriggers()
        observeWidgetPresentationRequests()
        // Starts the schedule tick and the wake observer. Deliberately after the notification and
        // presentation subscriptions above: the first check runs synchronously inside this call, so
        // anything it reports must already have somewhere to go.
        viewModel.startRoutineScheduling()

        // Both surfaces open on launch, matching Wispr Flow's reference behavior — a real,
        // confirmed tradeoff: this also makes the Dock icon a permanent fixture, since
        // PrimaryWindowActivationManager only switches out of accessory mode when Command Center
        // is shown, and it's now shown unconditionally on every launch, not on demand.
        windowCoordinator.showCommandCenter()
        widgetController.show()

        print("Sonny is running. Click the Sonny item in the macOS menu bar to open it.")
    }

    /// Only post a system notification when neither surface already showing the same state inline
    /// (the floating widget's permission row / failure row) is in front of the user — otherwise
    /// it's a redundant second prompt for something already on screen.
    private var isAnySonnySurfaceVisible: Bool {
        widgetController.isVisible || windowCoordinator.commandCenterWindow?.isKeyWindow == true
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
                self?.widgetController.show()
            }
            .store(in: &cancellables)
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
                guard let self, !isAnySonnySurfaceVisible else {
                    return
                }
                notificationService.postPermissionNotification(resource: request.approvalCopy.involvedResource)
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isAnySonnySurfaceVisible else {
                    return
                }
                notificationService.postErrorNotification(message: message)
            }
            .store(in: &cancellables)

        // Local-storage problems moved off `errorMessage` so a corrupt store can't make a
        // successful task read as failed. They still deserve the same fallback notification when
        // no Sonny surface is in front of the user, so subscribe to the new channel too.
        viewModel.$localStorageNotice
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isAnySonnySurfaceVisible else {
                    return
                }
                notificationService.postErrorNotification(message: message)
            }
            .store(in: &cancellables)

        // Scheduled runs are the one case this fallback was actually designed for: the run happens
        // with nobody watching, which is precisely when no Sonny surface is in front of the user.
        // Unlike the two above, this path is genuinely reachable rather than accepted-as-unused.
        viewModel.$scheduledRunNotice
            .compactMap { $0 }
            .sink { [weak self] message in
                guard let self, !isAnySonnySurfaceVisible else {
                    return
                }
                notificationService.postErrorNotification(message: message)
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

    /// The real `NSApp.mainMenu`, distinct from `makeStatusMenu()`'s status-item dropdown. Two
    /// menus only, deliberately: an Edit menu because that is what routes the standard editing
    /// key equivalents to the first responder (nil targets → responder chain), and an app menu
    /// carrying just Quit — the first top-level item renders as the bold app menu whenever the
    /// bar is visible (`.regular` policy), so leaving Edit first would put "Edit" in the
    /// app-name slot, and ⌘Q was equally menu-routed and equally broken (the status menu's own
    /// "q" equivalent only dispatches while that dropdown is open). No File/View/Window/Help:
    /// nothing in the app needs them.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
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

        return mainMenu
    }

    /// Just the two unambiguous actions for now — no "Recent"/usage section, since Sonny has no
    /// real equivalent to a chat-app's usage percentage and its actual analog (recent tasks) is a
    /// deliberate follow-up, not silently fabricated here.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "New Task",
            action: #selector(requestWidgetPresentation),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Open Sonny",
            action: #selector(openCommandCenter),
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
    /// straight from the menu item is exactly why "New Task" read as doing nothing when the widget
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

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }
}
