import CoreGraphics
import Foundation
import os
import Testing
@testable import MacAgentCore

// SONNY-80: the ComputerUseDriver seam. The loop's behavior against a scripted mock driver and
// a scripted decider — no network, no real input synthesis, no processes. Test images stay under
// 320px wide so the loop's zoom-refinement pass (which needs a 320px crop) never fires and the
// decider scripts stay one-reply-per-iteration.

// MARK: - Test doubles

private actor MockComputerUseDriver: ComputerUseDriver {
    nonisolated let substrateDescription = "mock"

    private let images: [CGImage]
    private var clickOutcomes: [DriverClickOutcome]
    private(set) var captureCount = 0
    private(set) var clickCalls: [CGPoint] = []
    private(set) var forbiddenRectsSeen: [[CGRect]] = []
    private(set) var typedTexts: [String] = []
    private(set) var pressedKeys: [ComputerUseKey] = []
    private(set) var shutdownCount = 0

    init(images: [CGImage], clickOutcomes: [DriverClickOutcome] = []) {
        self.images = images
        self.clickOutcomes = clickOutcomes
    }

    nonisolated func preflightPermissions() throws {}

    func prepare() async throws {}

    func activateApp(named appName: String) async -> pid_t? { 4242 }

    func visibleAppNames() async -> [String] { ["Mock App"] }

    func captureFrontWindow(ofProcess pid: pid_t, appName: String) async throws -> DriverWindowCapture {
        let image = images[min(captureCount, images.count - 1)]
        captureCount += 1
        return DriverWindowCapture(
            image: image,
            windowID: 42,
            ownerPID: pid,
            windowFrame: CGRect(x: 100, y: 100, width: CGFloat(image.width), height: CGFloat(image.height)),
            windowTitle: "Mock Window"
        )
    }

    func clickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        clickCalls.append(point)
        forbiddenRectsSeen.append(forbiddenGlobalRects)
        if clickOutcomes.isEmpty {
            return .posted(globalPoint: CGPoint(x: capture.windowFrame.origin.x + point.x, y: capture.windowFrame.origin.y + point.y))
        }
        return clickOutcomes.removeFirst()
    }

    func doubleClickInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint, avoiding forbiddenGlobalRects: [CGRect]) async throws -> DriverClickOutcome {
        try await clickInWindow(capture, atImagePoint: point, avoiding: forbiddenGlobalRects)
    }

    func typeText(_ text: String) async throws {
        typedTexts.append(text)
    }

    func pressKey(_ key: ComputerUseKey) async throws {
        pressedKeys.append(key)
    }

    func scrollInWindow(_ capture: DriverWindowCapture, atImagePoint point: CGPoint?, direction: ComputerUseScrollDirection, amount: Int) async throws {}

    func shutdown() async {
        shutdownCount += 1
    }
}

private final class ScriptedDecider: VisionDeciding, Sendable {
    private struct State: Sendable {
        var replies: [String]
        var prompts: [String] = []
    }

    let transcriptDescription = "scripted"
    private let state: OSAllocatedUnfairLock<State>

    init(replies: [String]) {
        self.state = OSAllocatedUnfairLock(initialState: State(replies: replies))
    }

    var recordedPrompts: [String] {
        state.withLock { $0.prompts }
    }

    func decide(prompt: String, pngData: Data) async throws -> (reply: String, latencySeconds: Double) {
        #expect(!pngData.isEmpty)
        let reply: String? = state.withLock { state in
            state.prompts.append(prompt)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else {
            throw VisionActionLoopError.unparseableModelReply("scripted decider ran out of replies")
        }
        return (reply, 0.01)
    }
}

private func makeImage(width: Int = 200, height: Int = 150, white: CGFloat) throws -> CGImage {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(srgbRed: white, green: white, blue: white, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private let sampleRequest = VisionActionRequest(appName: "Mock App", goal: "press the button")

// MARK: - Loop-against-seam behavior

@Suite
struct ComputerUseDriverSeamTests {
    @Test
    func clickIsSentToTheDriverInImagePixelsAndRecordedWithTheDriversGlobalPoint() async throws {
        let driver = MockComputerUseDriver(images: [
            try makeImage(white: 0.2), try makeImage(white: 0.8)
        ])
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"it is the goal"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"button pressed"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(await driver.clickCalls == [CGPoint(x: 10, y: 12)])
        #expect(summary.actions.count == 1)
        #expect(summary.actions.first?.kind == .click)
        #expect(summary.actions.first?.imagePoint == CGPoint(x: 10, y: 12))
        #expect(summary.actions.first?.globalPoint == CGPoint(x: 110, y: 112))
        #expect(summary.transcript.contains { $0.contains("CLICK image(10,12)") })
        #expect(summary.transcript.contains { $0.contains("click posted at global(110,112)") })
        if case .done = summary.outcome {} else {
            Issue.record("expected .done, got \(summary.outcome)")
        }
    }

    @Test
    func typedTextReachesTheDriverVerbatimIncludingTheTrailingNewline() async throws {
        let driver = MockComputerUseDriver(images: [
            try makeImage(white: 0.2), try makeImage(white: 0.8)
        ])
        let decider = ScriptedDecider(replies: [
            #"{"action":"type","text":"hello\n","target":"message field","rationale":"send it"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"sent"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(await driver.typedTexts == ["hello\n"])
        #expect(summary.actions.count == 1)
        #expect(summary.actions.first?.kind == .type)
    }

    @Test
    func windowDisappearedClickIsSkippedRecapturedAndExplainedToTheModel() async throws {
        let driver = MockComputerUseDriver(
            images: [try makeImage(white: 0.2), try makeImage(white: 0.8)],
            clickOutcomes: [.windowDisappeared]
        )
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"try"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"fine"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(await driver.captureCount == 2)
        #expect(summary.actions.isEmpty)
        #expect(summary.transcript.contains { $0.contains("window disappeared during model inference — click skipped, recapturing") })
        let secondPrompt = try #require(decider.recordedPrompts.last)
        #expect(secondPrompt.contains("click on \"Button\" skipped — the window disappeared; reassess from the new screenshot"))
    }

    @Test
    func windowResizeRefusalCarriesBothSizesIntoTheTranscript() async throws {
        let driver = MockComputerUseDriver(
            images: [try makeImage(white: 0.2), try makeImage(white: 0.8)],
            clickOutcomes: [.windowResized(from: CGSize(width: 300, height: 200), to: CGSize(width: 400, height: 300))]
        )
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"try"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"fine"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(summary.actions.isEmpty)
        #expect(summary.transcript.contains { $0.contains("window resized during model inference (300x200 -> 400x300) — click skipped, recapturing") })
    }

    @Test
    func suppressedClickIsBlockedAndTheModelIsToldWhy() async throws {
        let blocked = CGRect(x: 0, y: 0, width: 50, height: 50)
        let driver = MockComputerUseDriver(
            images: [try makeImage(white: 0.2), try makeImage(white: 0.8)],
            clickOutcomes: [.suppressed(globalPoint: CGPoint(x: 5, y: 5), blockedBy: blocked)]
        )
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"try"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"fine"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(summary.actions.isEmpty)
        #expect(summary.transcript.contains { $0.contains("suppressed — it falls inside Sonny's own window") })
        let secondPrompt = try #require(decider.recordedPrompts.last)
        #expect(secondPrompt.contains("was blocked — that screen area is covered by the operator's control panel"))
    }

    @Test
    func substrateRefusalIsSkippedAndSurfacedToTheModel() async throws {
        let driver = MockComputerUseDriver(
            images: [try makeImage(white: 0.2), try makeImage(white: 0.8)],
            clickOutcomes: [.refusedByDriver(reason: "click: window_id_not_found")]
        )
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"try"}"#,
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"fine"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        #expect(summary.actions.isEmpty)
        #expect(summary.transcript.contains { $0.contains("click refused by the driver — click: window_id_not_found") })
        let secondPrompt = try #require(decider.recordedPrompts.last)
        #expect(secondPrompt.contains("the substrate refused it (click: window_id_not_found)"))
    }

    @Test
    func pixelIdenticalRecaptureAfterAClickTellsTheModelItsClickChangedNothing() async throws {
        // Same brightness twice → byte-identical PNG encodes → the loop's no-visible-change signal.
        let driver = MockComputerUseDriver(images: [
            try makeImage(white: 0.5), try makeImage(white: 0.5)
        ])
        let decider = ScriptedDecider(replies: [
            #"{"action":"click","x":10,"y":12,"target":"Button","rationale":"try"}"#,
            #"{"action":"stuck","x":null,"y":null,"target":"","rationale":"nothing works"}"#
        ])

        _ = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        let secondPrompt = try #require(decider.recordedPrompts.last)
        #expect(secondPrompt.contains("produced NO visible change"))
        #expect(secondPrompt.contains("(10, 12)"))
    }

    @Test
    func transcriptOpensWithSubstrateAndVisionModelIdentity() async throws {
        let driver = MockComputerUseDriver(images: [try makeImage(white: 0.3)])
        let decider = ScriptedDecider(replies: [
            #"{"action":"done","x":null,"y":null,"target":"","rationale":"already done"}"#
        ])

        let summary = try await VisionActionLoop.run(sampleRequest, driver: driver, decider: decider, settleScale: 0)

        let startLine = try #require(summary.transcript.first)
        #expect(startLine.contains("substrate=mock"))
        #expect(startLine.contains("vision=scripted"))
        #expect(summary.modelDescription == "scripted")
    }
}

// MARK: - Substrate selection

@Suite
struct ComputerUseDriverFactoryTests {
    @Test
    func substrateSelectionDefaultsToCUAAndHonorsTheHandwrittenOverride() {
        #expect(ComputerUseDriverFactory.substrate(fromEnvironment: [:]) == .cua)
        #expect(ComputerUseDriverFactory.substrate(fromEnvironment: ["SONNY_VISION_SUBSTRATE": "handwritten"]) == .handwritten)
        #expect(ComputerUseDriverFactory.substrate(fromEnvironment: ["SONNY_VISION_SUBSTRATE": "HandWritten"]) == .handwritten)
        // Lenient like the spike's SONNY_VISION_HOST: unknown values fall back to the default.
        #expect(ComputerUseDriverFactory.substrate(fromEnvironment: ["SONNY_VISION_SUBSTRATE": "python"]) == .cua)
    }
}

// MARK: - CUA typing contract

@Suite
struct CUATypingPlanTests {
    @Test
    func newlinesBecomeReturnKeyPressesNeverInsertedCharacters() {
        #expect(CUAComputerUseDriver.typingPlan(for: "hi\n") == [.type("hi"), .pressReturn])
        #expect(CUAComputerUseDriver.typingPlan(for: "a\n\nb") == [.type("a"), .pressReturn, .pressReturn, .type("b")])
        #expect(CUAComputerUseDriver.typingPlan(for: "x\r\ny") == [.type("x"), .pressReturn, .type("y")])
        #expect(CUAComputerUseDriver.typingPlan(for: "\r") == [.pressReturn])
        #expect(CUAComputerUseDriver.typingPlan(for: "plain") == [.type("plain")])
        #expect(CUAComputerUseDriver.typingPlan(for: "") == [])
    }
}

// MARK: - JSON-RPC codec

@Suite
struct CUAJSONRPCCodecTests {
    @Test
    func requestEncodingProducesLineFramedJSONRPCWithParams() throws {
        let frame = try CUAJSONRPCCodec.encode(id: 7, method: "tools/call", params: .object([
            "name": .string("click"),
            "arguments": .object(["pid": .number(123), "x": .number(10.0)])
        ]))
        #expect(frame.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["id"] as? Int == 7)
        #expect(object["method"] as? String == "tools/call")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["name"] as? String == "click")
        let arguments = try #require(params["arguments"] as? [String: Any])
        // Integral numbers must round-trip as integers — cua-driver's schemas declare pid/x as
        // integer/number and a "123.0" pid is the kind of drift that fails schema validation.
        #expect(arguments["pid"] as? Int == 123)
    }

    @Test
    func notificationEncodingOmitsTheID() throws {
        let frame = try CUAJSONRPCCodec.encode(id: nil, method: "notifications/initialized", params: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: frame.dropLast()) as? [String: Any])
        #expect(object["id"] == nil)
        #expect(object["method"] as? String == "notifications/initialized")
    }

    @Test
    func responseAndNotificationFramesDecodeWithCorrectIdentity() throws {
        let response = try CUAJSONRPCCodec.decode(Data(#"{"jsonrpc":"2.0","id":3,"result":{"ok":true}}"#.utf8))
        #expect(response.id == 3)
        #expect(response.result?["ok"]?.boolValue == true)
        #expect(response.method == nil)

        let notification = try CUAJSONRPCCodec.decode(Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#.utf8))
        #expect(notification.id == nil)
        #expect(notification.method == "notifications/progress")
    }

    @Test
    func toolResultUnwrappingExtractsStructuredContentAndImageBytes() throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])
        let result = CUAJSONValue.fromFoundation([
            "content": [
                ["type": "text", "text": "ok"],
                ["type": "image", "data": pngBytes.base64EncodedString(), "mimeType": "image/png"]
            ],
            "structuredContent": ["screenshot_scale": 2.0, "window_bounds": ["x": 1, "y": 2, "width": 3, "height": 4]]
        ] as [String: Any])

        let unwrapped = try CUAJSONRPCCodec.unwrapToolResult(result, toolName: "get_window_state")
        #expect(unwrapped.imagePNG == pngBytes)
        #expect(unwrapped.structured["screenshot_scale"]?.doubleValue == 2.0)
        #expect(unwrapped.structured["window_bounds"]?["width"]?.doubleValue == 3)
    }

    @Test
    func toolLevelErrorsThrowCUAToolErrorCarryingTheToolsOwnMessage() {
        let result = CUAJSONValue.fromFoundation([
            "isError": true,
            "content": [["type": "text", "text": "window_id_not_found: window 42 no longer exists"]]
        ] as [String: Any])

        do {
            _ = try CUAJSONRPCCodec.unwrapToolResult(result, toolName: "click")
            Issue.record("expected CUAToolError")
        } catch let error as CUAToolError {
            #expect(error.message == "click: window_id_not_found: window 42 no longer exists")
        } catch {
            Issue.record("expected CUAToolError, got \(error)")
        }
    }

    @Test
    func refusalMessagesAreReadFromStructuredContentWhenNoTextPartExists() {
        let result = CUAJSONValue.fromFoundation([
            "structuredContent": ["refusal": ["code": "px_frame_mismatch", "message": "capture scale unprovable"]]
        ] as [String: Any])
        #expect(CUAJSONRPCCodec.errorText(from: result) == "capture scale unprovable")
    }
}
