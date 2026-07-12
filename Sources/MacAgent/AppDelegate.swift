import AppKit
import CoreText
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let viewModel = AgentViewModel()
    private lazy var windowCoordinator = AppWindowCoordinator(viewModel: viewModel)
    private var pushToTalkHotKey: PushToTalkHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "wand.and.stars.inverse", accessibilityDescription: "Sonny")
        item.button?.imagePosition = .imageLeading
        item.button?.title = " Sonny"
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 600, height: 740)
        let hostingController = NSHostingController(
            rootView: ContentView(
                viewModel: viewModel,
                openCommandCenter: { [weak self] in
                    self?.windowCoordinator.showCommandCenter()
                }
            )
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        popover.contentViewController = hostingController

        do {
            pushToTalkHotKey = try PushToTalkHotKey(
                onPress: { [weak self] in
                    self?.showPopover()
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

        print("Sonny is running. Click the Sonny item in the macOS menu bar to open it.")
    }

    private func registerBundledFonts() {
        for fontName in [
            "InstrumentSerif-Regular",
            "GolosText-Regular",
            "Inter-VariableFont_opsz,wght"
        ] {
            guard let url = Bundle.module.url(forResource: fontName, withExtension: "ttf")
                ?? Bundle.module.url(forResource: fontName, withExtension: "ttf", subdirectory: "Fonts")
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

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard statusItem?.button != nil else {
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let window = popover.contentViewController?.view.window {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
