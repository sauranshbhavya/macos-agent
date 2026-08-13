import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// SONNY-80 experiment. The spike's original computer-use substrate (SONNY-69), moved verbatim
// behind the ComputerUseDriver seam: ScreenCaptureKit front-window capture at nominal (1x)
// resolution, CGWindowList z-order/geometry, and CGEvent click/typing synthesis. It stays
// selectable (SONNY_VISION_SUBSTRATE=handwritten) for A/B comparison against the CUA substrate
// until the founder explicitly says delete it.

public struct HandwrittenComputerUseDriver: ComputerUseDriver {
    public let substrateDescription = "handwritten"

    public init() {}

    // MARK: - Capture

    public func captureFrontWindow(ofProcess pid: pid_t, appName: String) async throws -> DriverWindowCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let candidates = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width >= 80
                && window.frame.height >= 80
        }
        // SCShareableContent's window order is undocumented, but CGWindowListCopyWindowInfo with
        // onScreenOnly is front-to-back — so the app's actually-frontmost window (a dialog over
        // its main window, say) is the one the model should see. Largest-area is the fallback.
        let frontmostID = Self.frontmostWindowID(ofProcess: pid)
        let window = candidates.first { frontmostID != nil && $0.windowID == frontmostID }
            ?? candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        guard let window else {
            throw VisionActionLoopError.captureFailed("no on-screen window found for \(appName) (pid \(pid))")
        }

        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.showsCursor = false
        configuration.captureResolution = .nominal

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return DriverWindowCapture(
            image: image,
            windowID: window.windowID,
            ownerPID: pid,
            windowFrame: window.frame,
            windowTitle: window.title ?? "untitled"
        )
    }

    // Front-to-back z-order scan; the first layer-0 window of the pid is its frontmost.
    private static func frontmostWindowID(ofProcess pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 80, bounds.height >= 80,
                  let number = info[kCGWindowNumber as String] as? Int else {
                continue
            }
            return CGWindowID(number)
        }
        return nil
    }

    private static func currentWindowFrame(windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
            return nil
        }
        return bounds
    }

    // MARK: - Clicks

    public func clickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        switch try resolveGlobalPoint(capture, imagePoint: point, avoiding: forbiddenGlobalRects) {
        case .resolved(let globalPoint):
            // Log BEFORE the click is issued (the spike's safety mandate, kept substrate-side so
            // the resolved coordinates are on the console before any event exists).
            print("[HandwrittenDriver] posting click at global(\(Int(globalPoint.x)),\(Int(globalPoint.y)))")
            try await Self.synthesizeClick(at: globalPoint)
            return .posted(globalPoint: globalPoint)
        case .blocked(let outcome):
            return outcome
        }
    }

    public func doubleClickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        switch try resolveGlobalPoint(capture, imagePoint: point, avoiding: forbiddenGlobalRects) {
        case .resolved(let globalPoint):
            print("[HandwrittenDriver] posting double-click at global(\(Int(globalPoint.x)),\(Int(globalPoint.y)))")
            try await Self.synthesizeDoubleClick(at: globalPoint)
            return .posted(globalPoint: globalPoint)
        case .blocked(let outcome):
            return outcome
        }
    }

    private enum PointResolution {
        case resolved(CGPoint)
        case blocked(DriverClickOutcome)
    }

    // The spike's exact policy: the capture-time frame gives the image→point scale; the click
    // itself is translated through the window's FRESH origin (a pure move keeps the model's
    // window-relative point valid), while a resize — or a vanished window — means the content
    // shifted under the model and the click would be a lie, so it is refused for a recapture.
    // SCWindow.frame, kCGWindowBounds, and CGEvent all use top-left-origin global display
    // coordinates, so the mapping is pure translation — no y-flip.
    private func resolveGlobalPoint(_ capture: DriverWindowCapture, imagePoint: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) throws -> PointResolution {
        let frame = capture.windowFrame
        let scaleX = frame.width / CGFloat(capture.image.width)
        let scaleY = frame.height / CGFloat(capture.image.height)
        let windowPoint = CGPoint(x: imagePoint.x * scaleX, y: imagePoint.y * scaleY)

        guard let freshFrame = Self.currentWindowFrame(windowID: capture.windowID) else {
            return .blocked(.windowDisappeared)
        }
        if abs(freshFrame.width - frame.width) > 2 || abs(freshFrame.height - frame.height) > 2 {
            return .blocked(.windowResized(from: frame.size, to: freshFrame.size))
        }
        let globalPoint = CGPoint(x: freshFrame.origin.x + windowPoint.x, y: freshFrame.origin.y + windowPoint.y)
        if let blocked = forbiddenGlobalRects.first(where: { $0.contains(globalPoint) }) {
            return .blocked(.suppressed(globalPoint: globalPoint, blockedBy: blocked))
        }
        return .resolved(globalPoint)
    }

    private static func synthesizeClick(at point: CGPoint) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VisionActionLoopError.captureFailed("could not create CGEventSource")
        }
        func post(_ type: CGEventType) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        post(.mouseMoved)
        try await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseDown)
        do {
            try await Task.sleep(nanoseconds: 80_000_000)
        } catch {
            // A cancel landing in this 80ms window must never leave the synthetic left button
            // held down at the HID level — post the up event, then propagate the cancellation.
            post(.leftMouseUp)
            throw error
        }
        post(.leftMouseUp)
    }

    private static func synthesizeDoubleClick(at point: CGPoint) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VisionActionLoopError.captureFailed("could not create CGEventSource")
        }
        func post(_ type: CGEventType, clickState: Int64) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            event?.post(tap: .cghidEventTap)
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseDown, clickState: 1)
        post(.leftMouseUp, clickState: 1)
        do {
            try await Task.sleep(nanoseconds: 80_000_000)
        } catch {
            post(.leftMouseUp, clickState: 2)
            throw error
        }
        post(.leftMouseDown, clickState: 2)
        post(.leftMouseUp, clickState: 2)
    }

    // MARK: - Keyboard

    // One character per event pair — multi-character keyboardSetUnicodeString chunks are legal
    // but some targets (Chromium's omnibox among them) only honor the first character. Newlines
    // are the other observed live failure: a unicode "\n" is not a Return keypress and neither
    // a shell nor an address bar executes on it, so they are synthesized as real Return-keycode
    // (36) events instead.
    public func typeText(_ text: String) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VisionActionLoopError.captureFailed("could not create CGEventSource")
        }
        for character in text {
            if character == "\n" || character == "\r" {
                for keyDown in [true, false] {
                    CGEvent(keyboardEventSource: source, virtualKey: ComputerUseKey.returnKey.macKeyCode, keyDown: keyDown)?
                        .post(tap: .cghidEventTap)
                }
            } else {
                let units = Array(String(character).utf16)
                for keyDown in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                    units.withUnsafeBufferPointer { buffer in
                        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
                    }
                    event.post(tap: .cghidEventTap)
                }
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    public func pressKey(_ key: ComputerUseKey) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VisionActionLoopError.captureFailed("could not create CGEventSource")
        }
        for keyDown in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: key.macKeyCode, keyDown: keyDown)?
                .post(tap: .cghidEventTap)
        }
    }

    // MARK: - Scroll

    // Not yet exposed to the vision model (the loop's action set is unchanged from the spike);
    // implemented so the seam's surface is complete for the production build's A/B evaluation.
    public func scrollInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint?, direction: ComputerUseScrollDirection, amount: Int) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw VisionActionLoopError.captureFailed("could not create CGEventSource")
        }
        if let point {
            // Wheel events land on the window under the pointer, so aim the pointer first. A
            // stale origin only mis-aims the scroll, never clicks — translation through the
            // fresh origin still applies when the window is alive.
            let frame = Self.currentWindowFrame(windowID: capture.windowID) ?? capture.windowFrame
            let scaleX = capture.windowFrame.width / CGFloat(capture.image.width)
            let scaleY = capture.windowFrame.height / CGFloat(capture.image.height)
            let globalPoint = CGPoint(x: frame.origin.x + point.x * scaleX, y: frame.origin.y + point.y * scaleY)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: globalPoint, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        let (vertical, horizontal): (Int32, Int32)
        switch direction {
        case .up: (vertical, horizontal) = (Int32(amount), 0)
        case .down: (vertical, horizontal) = (Int32(-amount), 0)
        case .left: (vertical, horizontal) = (0, Int32(amount))
        case .right: (vertical, horizontal) = (0, Int32(-amount))
        }
        CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }
}
