import AppKit
import SwiftUI

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Keeps the widget at the bottom centre of the screen under the pointer, sized to its content.
/// The panel never activates Sonny, so the app the person is using stays in front.
@MainActor
final class WidgetWindowController: NSObject {
    /// How often the widget follows the pointer to another screen.
    private static let screenFollowInterval: TimeInterval = 0.75

    private let model: SonnyAppModel
    private var panel: WidgetPanel?
    private var hostingController: NSHostingController<WidgetView>?
    private var screenFollowTimer: Timer?

    init(model: SonnyAppModel) {
        self.model = model
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        screenFollowTimer = Timer.scheduledTimer(withTimeInterval: Self.screenFollowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.repositionIfVisible() }
        }
    }

    var isPanelKey: Bool {
        panel?.isKeyWindow ?? false
    }

    func show(takingKey: Bool = true) {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
        if takingKey { panel.makeKey() }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    @objc private func activeApplicationDidChange() {
        repositionIfVisible()
    }

    private func repositionIfVisible() {
        guard let panel else { return }
        reposition(panel)
    }

    private func makePanel() -> WidgetPanel {
        let hostingController = NSHostingController(rootView: WidgetView(model: model))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingController = hostingController

        let panel = WidgetPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController

        hostingController.view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentFrameDidChange),
            name: NSView.frameDidChangeNotification,
            object: hostingController.view
        )
        return panel
    }

    @objc private func contentFrameDidChange() {
        repositionIfVisible()
    }

    private var screenUnderPointer: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    /// One frame set per change, and none when nothing moved: animating the frame here fed the
    /// content's own resize and hung the app (Bhavya's 336959ca).
    private func reposition(_ panel: WidgetPanel) {
        guard let hostingController, let screen = screenUnderPointer else { return }
        let size = hostingController.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(origin: NSPoint(x: visible.midX - size.width / 2, y: visible.minY), size: size)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }
}
