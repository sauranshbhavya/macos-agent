import CoreGraphics
import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Where a synthesized click actually went, or why it did not go anywhere.
///
/// **Refusals are outcomes, not errors.** A window that moved, vanished, or sits under Sonny's own
/// panel is an ordinary thing to happen between a screenshot and a click a second later, and the
/// correct response is to skip the action and take a fresh screenshot — not to fail the run. Only a
/// genuinely broken substrate throws.
public enum SynthesizedActionOutcome: Equatable, Sendable {
    case posted(globalPoint: CGPoint)
    case windowDisappeared
    case windowResized(from: CGSize, to: CGSize)
    /// The resolved point falls inside one of Sonny's own windows. Clicking there would be Sonny
    /// operating its own UI — including, in the worst case, its own approval buttons.
    case suppressedOwnWindow(globalPoint: CGPoint)
}

/// The OS-facing half of acting: activating an app, reading a window's live frame, and posting real
/// input events.
///
/// Split from the containment layer for the same reason `ScreenCaptureBackend` is split from
/// `ScreenCaptureService` — the part with a correctness discipline attached (which action is allowed,
/// when, and after whose approval) is pure logic under test, and the part that touches the machine
/// is a protocol a test replaces wholesale. No test in this repo may post a real mouse event.
public protocol ScreenActionSynthesizing: Sendable {
    /// Bring the target app forward. Returns false when no such app is running.
    func activateApp(bundleIdentifier: String) async -> Bool
    /// The bundle identifier of whatever is frontmost right now.
    func frontmostBundleIdentifier() async -> String?
    /// The window's frame as it is *now*, in global top-left-origin points, or nil if it is gone.
    func currentWindowFrame(windowID: UInt32) async -> CGRect?
    /// Sonny's own visible windows, in the same coordinate space, so a click into them can be
    /// suppressed.
    func ownWindowFrames() async -> [CGRect]

    func click(atGlobalPoint point: CGPoint) async throws
    func type(_ text: String) async throws
    func press(_ key: VisionActionKey) async throws
    func scroll(atGlobalPoint point: CGPoint?, direction: VisionScrollDirection, amount: Int) async throws
}

// MARK: - The live substrate

#if canImport(AppKit)
/// CoreGraphics event synthesis against the real machine.
public struct SystemScreenActionSynthesizer: ScreenActionSynthesizing {
    public init() {}

    public func activateApp(bundleIdentifier: String) async -> Bool {
        await MainActor.run {
            guard let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first else {
                return false
            }
            return app.activate(options: [])
        }
    }

    public func frontmostBundleIdentifier() async -> String? {
        await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    }

    public func currentWindowFrame(windowID: UInt32) async -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
            let entry = list.first,
            let bounds = entry[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
            return nil
        }
        return frame
    }

    public func ownWindowFrames() async -> [CGRect] {
        await MainActor.run { () -> [CGRect] in
            // Cocoa window frames are bottom-left-origin against the primary screen; every other
            // coordinate in this file is CoreGraphics top-left-origin. Converting here rather than
            // at the comparison keeps exactly one flip in the codebase.
            guard let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height,
                let application = NSApp else {
                return []
            }
            return application.windows.filter(\.isVisible).map { window in
                let frame = window.frame
                return CGRect(
                    x: frame.origin.x,
                    y: primaryHeight - frame.origin.y - frame.height,
                    width: frame.width,
                    height: frame.height
                )
            }
        }
    }

    public func click(atGlobalPoint point: CGPoint) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenActionSynthesisError.eventSourceUnavailable
        }
        try await ClickEventSequence.run(
            post: { type in
                CGEvent(
                    mouseEventSource: source,
                    mouseType: type,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
            },
            sleep: { try await Task.sleep(nanoseconds: $0) }
        )
    }

    public func type(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenActionSynthesisError.eventSourceUnavailable
        }
        for character in text {
            try Task.checkCancellation()
            if character == "\n" {
                // A real Return keypress, never an inserted newline character: a newline typed into
                // a chat composer inserts a line break, while Return sends the message. The two are
                // different actions and the model asked for the second.
                try postKeyCode(36, source: source)
                continue
            }
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw ScreenActionSynthesisError.eventSourceUnavailable
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 8_000_000)
        }
    }

    public func press(_ key: VisionActionKey) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenActionSynthesisError.eventSourceUnavailable
        }
        try postKeyCode(Self.virtualKeyCode(for: key), source: source)
    }

    public func scroll(
        atGlobalPoint point: CGPoint?,
        direction: VisionScrollDirection,
        amount: Int
    ) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenActionSynthesisError.eventSourceUnavailable
        }
        if let point {
            CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        let lines = Int32(direction == .up ? amount : -amount)
        CGEvent(
            scrollWheelEvent2Source: source,
            units: .line,
            wheelCount: 1,
            wheel1: lines,
            wheel2: 0,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func postKeyCode(_ code: CGKeyCode, source: CGEventSource) throws {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            throw ScreenActionSynthesisError.eventSourceUnavailable
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func virtualKeyCode(for key: VisionActionKey) -> CGKeyCode {
        switch key {
        case .enterKey: return 36
        case .tab: return 48
        case .escape: return 53
        case .delete: return 51
        case .arrowLeft: return 123
        case .arrowRight: return 124
        case .arrowDown: return 125
        case .arrowUp: return 126
        }
    }
}
#endif

/// The order of events one synthetic click posts, and what happens when a cancellation lands in the
/// middle of it.
///
/// **Extracted from the poster so the mouse-up guarantee is testable at the synthesis seam**, which
/// SONNY-92 requires as a contract rather than a habit. No test in this repo may post a real HID
/// event, so the only way to assert "the button always comes back up" is for the sequence to be a
/// pure function over an injected poster and an injected sleep. The production caller supplies the
/// real two; a test supplies a recorder and a sleep that throws.
enum ClickEventSequence {
    /// How long the button is held down. Long enough for the target app to register a real click,
    /// short enough not to read as a press-and-hold.
    static let holdNanoseconds: UInt64 = 80_000_000
    /// A settle after the move, so the app under the pointer has processed the hover before the
    /// button goes down.
    static let moveSettleNanoseconds: UInt64 = 60_000_000

    static func run(
        post: (CGEventType) -> Void,
        sleep: (UInt64) async throws -> Void
    ) async throws {
        post(.mouseMoved)
        try await sleep(moveSettleNanoseconds)
        post(.leftMouseDown)
        do {
            try await sleep(holdNanoseconds)
        } catch {
            // **The mouse-up guarantee.** A cancellation landing inside the hold must never leave
            // the synthetic left button held down at the HID level — the user would be left with a
            // machine that drags everything it touches, from a run they just stopped. Post the up
            // event, then propagate. Inherited from the experiment branch, where it was learned the
            // hard way.
            post(.leftMouseUp)
            throw error
        }
        post(.leftMouseUp)
    }
}

public enum ScreenActionSynthesisError: Error, Equatable, LocalizedError {
    case eventSourceUnavailable

    public var errorDescription: String? {
        switch self {
        case .eventSourceUnavailable:
            return "Sonny could not create the input event source macOS needs to control an app."
        }
    }
}

// MARK: - Coordinate resolution

/// Translates a point the model picked *in the screenshot* into a point on the screen.
///
/// Kept as a free function over plain values — no OS calls, no state — because this is the one piece
/// of the acting path where an arithmetic slip puts a click somewhere nobody chose, and it should be
/// exhaustively testable without a machine.
public enum VisionPointResolver {
    /// The fresh-frame policy, which is the whole reason this takes `freshFrame` separately from the
    /// capture.
    ///
    /// The capture-time frame gives the image-to-point *scale*. The click is then translated through
    /// the window's **current** origin, because a window that merely moved between the screenshot
    /// and now leaves the model's window-relative point perfectly valid. A window that *resized*,
    /// though, has reflowed its content under the model, so the point it chose no longer names the
    /// control it was aiming at — that click would be a lie, and it is refused for a recapture
    /// instead. A window that vanished is the same answer for the same reason.
    ///
    /// Tolerance of 2 points on each axis absorbs sub-point rounding without absorbing a real
    /// resize.
    public static let resizeTolerance: CGFloat = 2

    public static func resolve(
        imagePoint: CGPoint,
        capture: CapturedWindowImage,
        freshFrame: CGRect?,
        ownWindowFrames: [CGRect]
    ) -> SynthesizedActionOutcome {
        guard let freshFrame else {
            return .windowDisappeared
        }
        guard abs(freshFrame.width - capture.windowFrame.width) <= resizeTolerance,
              abs(freshFrame.height - capture.windowFrame.height) <= resizeTolerance else {
            return .windowResized(from: capture.windowFrame.size, to: freshFrame.size)
        }
        guard capture.pixelWidth > 0, capture.pixelHeight > 0 else {
            return .windowDisappeared
        }

        let scaleX = capture.windowFrame.width / CGFloat(capture.pixelWidth)
        let scaleY = capture.windowFrame.height / CGFloat(capture.pixelHeight)
        let globalPoint = CGPoint(
            x: freshFrame.origin.x + imagePoint.x * scaleX,
            y: freshFrame.origin.y + imagePoint.y * scaleY
        )

        if ownWindowFrames.contains(where: { $0.contains(globalPoint) }) {
            return .suppressedOwnWindow(globalPoint: globalPoint)
        }
        return .posted(globalPoint: globalPoint)
    }

    /// Whether an image point lies inside the captured image at all.
    ///
    /// Separate from `resolve` because an out-of-bounds coordinate is a *model* error worth telling
    /// the model about ("you named a point outside the screenshot"), while the outcomes above are
    /// *world* changes worth telling it something different ("the window moved").
    public static func isInsideImage(_ point: CGPoint, capture: CapturedWindowImage) -> Bool {
        point.x >= 0 && point.y >= 0
            && point.x < CGFloat(capture.pixelWidth)
            && point.y < CGFloat(capture.pixelHeight)
    }
}
