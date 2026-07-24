import AppKit
import SwiftUI

/// Borderless, non-activating panel — the whole point of `.nonactivatingPanel` is that its text
/// field can become key (so typing works) without stealing focus from whatever app the user was
/// in, matching a Spotlight-style overlay rather than a normal app window grabbing activation.
final class FloatingWidgetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the floating widget's window lifecycle and positioning. Deliberately one positioning mode,
/// not two — the widget never tucks itself inside Command Center's own window (or any other app's),
/// regardless of whether Command Center is key, frontmost, or full-screen. It behaves like Wispr
/// Flow's capsule: always its own independent, screen-anchored overlay. Content is sized by SwiftUI
/// itself (`FloatingWidgetView.fixedSize()`) and read back via `NSHostingController.view.fittingSize`
/// on every frame change, so the panel grows upward from a fixed bottom edge as panels appear — the
/// wireframes' own stated behavior (§3.3.2: "panel expands upward, bottom-edge-pinned"), not just an
/// implementation convenience.
///
/// Decided 2026-07-21, superseding the earlier composited-inside-Command-Center mode: that mode's
/// entire rationale was avoiding a second, duplicate composer once Command Center's page already had
/// its own — now that Command Center has no composer of its own anywhere (the widget is the only
/// place to type or speak a command), there's nothing left for compositing to avoid duplicating, and
/// tucking the widget inside the host app's own window was never actually wanted as a UI pattern in
/// its own right. Reserved for a real follow-up, not built here: genuine screen-awareness that
/// detects the frontmost *other* app's window bounds and ducks around its content (Wispr Flow's own
/// behavior, per the founder's own reference screenshots) — today's positioning is Dock-aware
/// (via `NSScreen.visibleFrame`) but not otherwise content-aware.
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
    private static let bottomMargin: CGFloat = 0

    /// How often to re-check which screen the cursor is actually on. Cheap: `reposition` no-ops
    /// (skips the `setFrame` call entirely) unless the target frame genuinely changed, so polling
    /// this often costs a screen-bounds comparison, not a constant stream of window moves.
    private static let screenFollowInterval: TimeInterval = 0.75

    private let viewModel: AgentViewModel
    private var panel: FloatingWidgetPanel?
    private var hostingController: NSHostingController<FloatingWidgetView>?
    private var screenFollowTimer: Timer?

    init(viewModel: AgentViewModel) {
        self.viewModel = viewModel
        super.init()
        // Multi-monitor: follow the screen the user is actually working on (Wispr Flow's own
        // behavior), not just the screen it happened to open on or last position on.
        //
        // Two mechanisms, deliberately layered, after the first attempt (an app-activation
        // notification alone) proved insufficient: switching to an app that's *already* frontmost
        // — e.g. just moving your cursor/attention back to a Claude Code window that was already
        // the active app — fires no new `didActivateApplicationNotification` at all, so a
        // notification-only approach silently misses exactly that case. A lightweight poll of the
        // cursor's actual screen is the robust fallback that covers every case (cursor movement,
        // Space switches, anything) without depending on a specific event firing; the notification
        // observer stays too since it reacts instantly for the common explicit-app-switch case
        // rather than waiting up to `screenFollowInterval`.
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
        guard let panel else {
            return
        }
        reposition(panel)
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
        let hostingController = NSHostingController(rootView: FloatingWidgetView(viewModel: viewModel))
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

    /// The screen actually containing the mouse cursor — "the screen I am working on," as directly
    /// as this can be determined, matching how the user themselves described the desired behavior.
    /// Falls back to `NSScreen.main` (the active app's screen) for the rare case the cursor's
    /// location doesn't resolve to any screen (e.g. transiently during a display reconfiguration).
    private var screenUnderCursor: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    private func reposition(_ panel: FloatingWidgetPanel) {
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

        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - contentSize.width / 2,
            y: screenFrame.minY + Self.bottomMargin
        )

        let newFrame = NSRect(origin: origin, size: contentSize)
        guard newFrame != panel.frame else {
            return
        }
        panel.setFrame(newFrame, display: true)
    }
}
