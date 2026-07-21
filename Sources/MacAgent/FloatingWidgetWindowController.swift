import AppKit
import SwiftUI

/// Borderless, non-activating panel — the whole point of `.nonactivatingPanel` is that its text
/// field can become key (so typing works) without stealing focus from whatever app the user was
/// in, matching a Spotlight-style overlay rather than a normal app window grabbing activation.
final class FloatingWidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets `FloatingWidgetWindowController` (AppKit) tell `FloatingWidgetView` (SwiftUI) which
/// positioning mode is currently active, so the view can hide its own compose pill/compact
/// capsule while composited into Command Center (see `FloatingWidgetView`'s use of this).
@MainActor
final class WidgetPositionState: ObservableObject {
    @Published var isComposited = false
}

/// Owns the floating widget's window lifecycle and positioning. Two positioning modes per
/// docs/sonny-design-system-reference.md §3.4: bottom-center of the active screen when standalone,
/// or inset inside the Command Center window when that window is key (the composited case shown in
/// wireframe 12). Content is sized by SwiftUI itself (`FloatingWidgetView.fixedSize()`) and read
/// back via `NSHostingController.view.fittingSize` on every frame change, so the panel grows
/// upward from a fixed bottom edge as panels appear — the wireframes' own stated behavior
/// (§3.3.2: "panel expands upward, bottom-edge-pinned"), not just an implementation convenience.
@MainActor
final class FloatingWidgetWindowController: NSObject {
    /// The window's own bottom edge, relative to `NSScreen.visibleFrame` (already Dock-aware —
    /// adapts to the user's actual Dock size/auto-hide state, unlike a flat margin against the
    /// full screen). Zero, not the wireframe's literal 93pt: `FloatingWidgetView`'s own 16pt outer
    /// padding already sits between the window's edge and the visible glass shape, so the window
    /// only needs to start flush with `visibleFrame.minY` for the *visible* shape to land ~16pt
    /// above the Dock — a second, separate 93pt margin on top of that (the original mistake) was
    /// double counting: it reused the wireframe's gap-to-*full-screen*-bottom as if it were a
    /// gap-to-*Dock*-top, when `visibleFrame` already excludes the Dock's reserved space.
    private static let standaloneBottomMargin: CGFloat = 0
    /// §3.4's own 308/104 numbers are pixel offsets from one specific reference window
    /// (1440×969) — a fixed pixel offset from a window that size doesn't scale to a Command
    /// Center window of a different size, landing the widget somewhere disconnected from the
    /// window's actual proportions (confirmed directly: this is what caused the "random position"
    /// jump when the widget opened while Command Center was a different size than the reference).
    /// Converted to the proportional ratios the design doc's own text already implied ("roughly
    /// 21%-55% of window width, near the bottom"): 308/1440 and 104/969, applied against the
    /// window's *actual* current width/height instead of a flat pixel count.
    private static let compositedInsetXRatio: CGFloat = 308.0 / 1440.0
    private static let compositedInsetYRatio: CGFloat = 104.0 / 969.0

    private let viewModel: AgentViewModel
    private let commandCenterWindowProvider: () -> NSWindow?
    private let positionState = WidgetPositionState()
    private var panel: FloatingWidgetPanel?
    private var hostingController: NSHostingController<FloatingWidgetView>?

    init(viewModel: AgentViewModel, commandCenterWindowProvider: @escaping () -> NSWindow?) {
        self.viewModel = viewModel
        self.commandCenterWindowProvider = commandCenterWindowProvider
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingWidgetPanel {
        let hostingController = NSHostingController(
            rootView: FloatingWidgetView(viewModel: viewModel, positionState: positionState)
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.hostingController = hostingController

        let panel = FloatingWidgetPanel(
            contentRect: NSRect(origin: .zero, size: hostingController.view.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // SwiftUI already draws the glass panel's own shadow (§3.2); a system window shadow on
        // top would draw a plain rectangle behind the mostly-transparent padding around it.
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

    private func reposition(_ panel: FloatingWidgetPanel) {
        guard let hostingController else {
            return
        }
        let contentSize = hostingController.view.fittingSize
        guard contentSize.width > 0, contentSize.height > 0 else {
            return
        }

        let origin: NSPoint
        if let commandCenterWindow = commandCenterWindowProvider(), commandCenterWindow.isKeyWindow {
            positionState.isComposited = true
            let mainFrame = commandCenterWindow.frame
            origin = NSPoint(
                x: mainFrame.minX + mainFrame.width * Self.compositedInsetXRatio,
                y: mainFrame.minY + mainFrame.height * Self.compositedInsetYRatio
            )
        } else if let screen = NSScreen.main {
            positionState.isComposited = false
            let screenFrame = screen.visibleFrame
            origin = NSPoint(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.minY + Self.standaloneBottomMargin
            )
        } else {
            return
        }

        let newFrame = NSRect(origin: origin, size: contentSize)
        guard newFrame != panel.frame else {
            return
        }
        panel.setFrame(newFrame, display: true)
    }
}
