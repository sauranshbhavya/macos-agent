import AppKit
import Combine
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let viewModel = AgentViewModel()
    private lazy var windowCoordinator = AppWindowCoordinator(viewModel: viewModel)
    private lazy var widgetController = FloatingWidgetWindowController(viewModel: viewModel)
    private lazy var notificationService = SonnyNotificationService(
        onAllow: { [weak self] in self?.viewModel.start() },
        onRetry: { [weak self] in self?.viewModel.retryLastCommand() },
        onOpen: { [weak self] in self?.widgetController.show() }
    )
    private var pushToTalkHotKey: PushToTalkHotKey?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()

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
                    self?.widgetController.show()
                    self?.viewModel.beginPushToTalkVoice()
                },
                onRelease: { [weak self] in
                    self?.viewModel.endPushToTalkVoice()
                }
            )
        } catch {
            viewModel.markVoiceHotKeyUnavailable(error.localizedDescription)
            print("Sonny could not register push-to-talk hotkey: \(error.localizedDescription)")
        }

        observeNotificationTriggers()
        observeWidgetPresentationRequests()

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
    /// user can finish typing there. Independent of `notificationService`'s bundle-identity guard:
    /// showing the widget works identically under `swift run`, unlike system notifications.
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

    /// Just the two unambiguous actions for now — no "Recent"/usage section, since Sonny has no
    /// real equivalent to a chat-app's usage percentage and its actual analog (recent tasks) is a
    /// deliberate follow-up, not silently fabricated here.
    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "New Task",
            action: #selector(showWidget),
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

    @objc private func showWidget() {
        widgetController.show()
    }

    @objc private func openCommandCenter() {
        windowCoordinator.showCommandCenter()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
