import AppKit
import SwiftUI

/// Where the run pill's window goes on a screen (SONNY-450). A pure function so a test holds it.
enum RunPillPlacement {
    /// Flush with the visible frame's top-right corner. The pill view keeps the widget's own 16pt
    /// padding around its glass, so the visible pill lands 16pt in from the corner — the same rule
    /// the widget's bottom edge follows (`FloatingWidgetWindowController.bottomMargin` is zero for
    /// the same reason), and `visibleFrame` already excludes the menu bar, so the pill never sits
    /// under it.
    static func frame(contentSize: CGSize, in visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - contentSize.width,
            y: visibleFrame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }
}

/// A panel that never takes key or main: the pill has no field to type into, and a click on it
/// hands focus to the widget it expands, not to itself.
final class RunPillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the run pill's window lifecycle and positioning, beside `FloatingWidgetWindowController`
/// and shaped like it (SONNY-450): a non-activating floating panel on every Space, sized by
/// SwiftUI and read back through `fittingSize`, pinned to the screen the cursor is on and following
/// it the way the widget does — the same activation notification plus the same cursor poll, for
/// the reason that controller's doc comment gives (an app that is already frontmost fires no
/// activation notification when the user turns back to it).
///
/// `AppDelegate` shows this exactly while `AgentViewModel.isWidgetMinimised` holds and hides it
/// otherwise; the pill never decides on its own to appear.
@MainActor
final class RunPillWindowController: NSObject {
    private static let screenFollowInterval: TimeInterval = 0.75

    private let viewModel: AgentViewModel
    private var panel: RunPillPanel?
    private var hostingController: NSHostingController<RunPillView>?
    private var screenFollowTimer: Timer?

    init(viewModel: AgentViewModel) {
        self.viewModel = viewModel
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        screenFollowTimer = Timer.scheduledTimer(withTimeInterval: Self.screenFollowInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.repositionIfVisible()
            }
        }
    }

    @objc private func activeApplicationDidChange() {
        repositionIfVisible()
    }

    private func repositionIfVisible() {
        guard let panel, panel.isVisible else {
            return
        }
        reposition(panel)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Fronts the pill without taking key: `orderFrontRegardless` and nothing else, because the
    /// pill takes no input and must not pull focus from the app the user is working in.
    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> RunPillPanel {
        let hostingController = NSHostingController(rootView: RunPillView(viewModel: viewModel))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingController = hostingController

        let panel = RunPillPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // System B is dark by design; the pill keeps the widget's appearance whatever the
        // application's is.
        panel.appearance = NSAppearance(named: .darkAqua)
        // The glass draws its own shadow; a window shadow would outline the transparent padding.
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
        guard let panel else {
            return
        }
        reposition(panel)
    }

    /// The screen containing the cursor, as the widget reads it; `NSScreen.main` when the cursor
    /// resolves to none (a display being reconfigured).
    private var screenUnderCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    private func reposition(_ panel: RunPillPanel) {
        guard let hostingController else {
            return
        }
        let contentSize = hostingController.view.fittingSize
        guard contentSize.width > 0, contentSize.height > 0 else {
            return
        }
        guard let screen = screenUnderCursor else {
            return
        }
        let newFrame = RunPillPlacement.frame(contentSize: contentSize, in: screen.visibleFrame)
        guard newFrame != panel.frame else {
            return
        }
        panel.setFrame(newFrame, display: true)
    }
}
