import CoreGraphics
import Foundation
import ImageIO
import os

// SONNY-80 experiment. The CUA-backed substrate: window-scoped capture and input synthesis
// delegated to an embedded cua-driver daemon (see CUADriverProcess for the process topology).
// Coordinate contract, per cua-driver 0.19.3's own schemas: window-scoped x/y are SCREENSHOT
// PIXELS of the get_window_state PNG ("read straight off the image you were handed — no scaling
// math needed"); window bounds come back in logical points; the driver reverses Retina backing
// scale internally and refuses to act when the pixel frame can't be proven coherent. That is the
// same policy the handwritten substrate implements by hand, which is what makes the A/B fair.

public final class CUAComputerUseDriver: ComputerUseDriver, Sendable {
    private let process: CUADriverProcess
    /// SONNY_CUA_DELIVERY=background|foreground forwards cua-driver's delivery_mode for A/B
    /// probing; unset leaves the driver's own default ("background" — no focus steal) in place.
    private let deliveryMode: String?
    private let versionLabel = OSAllocatedUnfairLock<String>(initialState: "cua-driver")

    public var substrateDescription: String {
        versionLabel.withLock { $0 }
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.process = CUADriverProcess(environment: environment)
        let delivery = environment["SONNY_CUA_DELIVERY"]?.lowercased()
        self.deliveryMode = (delivery == "background" || delivery == "foreground") ? delivery : nil
    }

    public func prepare() async throws {
        try await process.start()
        let version = await process.serverVersion
        versionLabel.withLock { $0 = "cua-driver \(version)" }
    }

    public func shutdown() async {
        await process.stop()
    }

    // MARK: - Capture

    public func captureFrontWindow(ofProcess pid: pid_t, appName: String) async throws -> DriverWindowCapture {
        try await process.start()
        guard let window = try await frontWindowRecord(ofProcess: pid) else {
            throw VisionActionLoopError.captureFailed("no on-screen window found for \(appName) (pid \(pid))")
        }
        let arguments = CUAJSONValue.object([
            "pid": .number(Double(pid)),
            "window_id": .number(Double(window.windowID)),
            "include_screenshot": .bool(true),
            // The AX tree is not this experiment's modality — bound the walk to almost nothing.
            "max_elements": .number(1),
            "max_depth": .number(1)
        ])
        let (structured, imagePNG): (CUAJSONValue, Data?)
        do {
            (structured, imagePNG) = try await process.callTool("get_window_state", arguments: arguments)
        } catch let error as CUAToolError {
            throw VisionActionLoopError.captureFailed(error.message)
        }
        if structured["screenshot_frame_valid"]?.boolValue == false {
            // The driver could not prove the screenshot is a coherent 1x/2x view of the window
            // bounds — its fail-closed path. Treat exactly like a failed capture.
            throw VisionActionLoopError.captureFailed("cua-driver could not validate the window's pixel frame (\(structured["screenshot_error"].map(String.init(describing:)) ?? "no detail"))")
        }
        guard let imagePNG, let image = Self.decodePNG(imagePNG) else {
            throw VisionActionLoopError.captureFailed("cua-driver returned no usable screenshot for window \(window.windowID)")
        }
        let frame = Self.rect(from: structured["window_bounds"]) ?? window.bounds
        return DriverWindowCapture(
            image: image,
            windowID: window.windowID,
            ownerPID: pid,
            windowFrame: frame,
            windowTitle: window.title
        )
    }

    private struct WindowRecord {
        let windowID: CGWindowID
        let bounds: CGRect
        let title: String
        let zIndex: Int?
    }

    /// Mirrors the handwritten substrate's selection policy: on-screen, sensible size, frontmost
    /// by z-order, largest-area fallback (list_windows documents that a null z_index must never
    /// be ranked by array order).
    private func frontWindowRecord(ofProcess pid: pid_t) async throws -> WindowRecord? {
        let (structured, _) = try await process.callTool("list_windows", arguments: .object([
            "pid": .number(Double(pid))
        ]))
        let records = (structured["windows"]?.arrayValue ?? []).compactMap { entry -> WindowRecord? in
            guard let id = entry["window_id"]?.intValue,
                  let bounds = Self.rect(from: entry["bounds"]),
                  entry["is_on_screen"]?.boolValue == true,
                  bounds.width >= 80, bounds.height >= 80 else {
                return nil
            }
            return WindowRecord(
                windowID: CGWindowID(id),
                bounds: bounds,
                title: entry["title"]?.stringValue ?? "untitled",
                zIndex: entry["z_index"]?.intValue
            )
        }
        if let frontmost = records.filter({ $0.zIndex != nil }).max(by: { ($0.zIndex ?? .min) < ($1.zIndex ?? .min) }) {
            return frontmost
        }
        return records.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
    }

    // MARK: - Clicks

    public func clickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        try await performClick(toolName: "click", capture: capture, point: point, avoiding: forbiddenGlobalRects)
    }

    public func doubleClickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        try await performClick(toolName: "double_click", capture: capture, point: point, avoiding: forbiddenGlobalRects)
    }

    private func performClick(toolName: String, capture: DriverWindowCapture, point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        // Same fresh-frame policy as the handwritten substrate, sourced from the driver's own
        // window table: a vanished window refuses, a resize refuses, a pure move translates.
        guard let fresh = try await currentWindowRecord(capture: capture) else {
            return .windowDisappeared
        }
        if abs(fresh.bounds.width - capture.windowFrame.width) > 2 || abs(fresh.bounds.height - capture.windowFrame.height) > 2 {
            return .windowResized(from: capture.windowFrame.size, to: fresh.bounds.size)
        }
        let scaleX = capture.windowFrame.width / CGFloat(capture.image.width)
        let scaleY = capture.windowFrame.height / CGFloat(capture.image.height)
        let globalPoint = CGPoint(
            x: fresh.bounds.origin.x + point.x * scaleX,
            y: fresh.bounds.origin.y + point.y * scaleY
        )
        if let blocked = forbiddenGlobalRects.first(where: { $0.contains(globalPoint) }) {
            return .suppressed(globalPoint: globalPoint, blockedBy: blocked)
        }

        var arguments: [String: CUAJSONValue] = [
            "pid": .number(Double(capture.ownerPID)),
            "window_id": .number(Double(capture.windowID)),
            "x": .number(Double(point.x)),
            "y": .number(Double(point.y))
        ]
        if let deliveryMode {
            arguments["delivery_mode"] = .string(deliveryMode)
        }
        print("[CUADriver] posting \(toolName) at image(\(Int(point.x)),\(Int(point.y))) ≈ global(\(Int(globalPoint.x)),\(Int(globalPoint.y)))")
        do {
            let (structured, _) = try await process.callTool(toolName, arguments: .object(arguments))
            // The closed ActionResult contract: effect ∈ confirmed | partial | unverifiable |
            // suspected_noop | refused. Log it for the A/B record; the loop still verifies
            // visually either way, exactly as it does for the handwritten substrate.
            if let effect = structured["effect"]?.stringValue {
                let route = structured["route"]?.stringValue ?? "unknown"
                print("[CUADriver] \(toolName) effect=\(effect) route=\(route)")
                if effect == "refused" {
                    return .refusedByDriver(reason: CUAJSONRPCCodec.errorText(from: .object(["structuredContent": structured])))
                }
            }
            return .posted(globalPoint: globalPoint)
        } catch let error as CUAToolError {
            return .refusedByDriver(reason: error.message)
        }
    }

    private func currentWindowRecord(capture: DriverWindowCapture) async throws -> WindowRecord? {
        let (structured, _) = try await process.callTool("list_windows", arguments: .object([
            "pid": .number(Double(capture.ownerPID))
        ]))
        for entry in structured["windows"]?.arrayValue ?? [] {
            guard let id = entry["window_id"]?.intValue, CGWindowID(id) == capture.windowID,
                  let bounds = Self.rect(from: entry["bounds"]) else {
                continue
            }
            return WindowRecord(
                windowID: capture.windowID,
                bounds: bounds,
                title: entry["title"]?.stringValue ?? "untitled",
                zIndex: entry["z_index"]?.intValue
            )
        }
        return nil
    }

    // MARK: - Keyboard

    enum TypingStep: Equatable {
        case type(String)
        case pressReturn
    }

    /// The seam's typing contract: newlines are Return KEY presses, never inserted "\n" text —
    /// the spike's live-observed failure mode (a shell or address bar does not execute on an
    /// inserted newline character). Pure so the segmentation is unit-testable.
    static func typingPlan(for text: String) -> [TypingStep] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let segments = normalized.components(separatedBy: "\n")
        var plan: [TypingStep] = []
        for (index, segment) in segments.enumerated() {
            if !segment.isEmpty {
                plan.append(.type(segment))
            }
            if index < segments.count - 1 {
                plan.append(.pressReturn)
            }
        }
        return plan
    }

    public func typeText(_ text: String) async throws {
        try await process.start()
        for step in Self.typingPlan(for: text) {
            switch step {
            case .type(let segment):
                var arguments: [String: CUAJSONValue] = [
                    "text": .string(segment),
                    // No pid/window target: type into whatever has focus in the frontmost app,
                    // matching the handwritten substrate's focus-follows-clicks semantics.
                    "scope": .string("desktop")
                ]
                if let deliveryMode {
                    arguments["delivery_mode"] = .string(deliveryMode)
                }
                _ = try await mapToolError { try await self.process.callTool("type_text", arguments: .object(arguments)) }
            case .pressReturn:
                try await pressKey(.returnKey)
            }
        }
    }

    public func pressKey(_ key: ComputerUseKey) async throws {
        try await process.start()
        var arguments: [String: CUAJSONValue] = [
            "key": .string(key.rawValue),
            "scope": .string("desktop")
        ]
        if let deliveryMode {
            arguments["delivery_mode"] = .string(deliveryMode)
        }
        _ = try await mapToolError { try await self.process.callTool("press_key", arguments: .object(arguments)) }
    }

    // MARK: - Scroll

    public func scrollInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint?, direction: ComputerUseScrollDirection, amount: Int) async throws {
        var arguments: [String: CUAJSONValue] = [
            "direction": .string(direction.rawValue),
            "amount": .number(Double(amount)),
            "pid": .number(Double(capture.ownerPID)),
            "window_id": .number(Double(capture.windowID))
        ]
        if let point {
            arguments["x"] = .number(Double(point.x))
            arguments["y"] = .number(Double(point.y))
        }
        if let deliveryMode {
            arguments["delivery_mode"] = .string(deliveryMode)
        }
        _ = try await mapToolError { try await self.process.callTool("scroll", arguments: .object(arguments)) }
    }

    // MARK: - Helpers

    /// Non-click actions have no skip-and-recapture path — a tool refusal there is a run error.
    private func mapToolError<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CUAToolError {
            throw VisionActionLoopError.driverFailure(error.message)
        }
    }

    private static func decodePNG(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func rect(from value: CUAJSONValue?) -> CGRect? {
        guard let value,
              let x = value["x"]?.doubleValue,
              let y = value["y"]?.doubleValue,
              let width = value["width"]?.doubleValue,
              let height = value["height"]?.doubleValue else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
