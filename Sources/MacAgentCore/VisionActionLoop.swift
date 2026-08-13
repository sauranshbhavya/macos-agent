import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// SONNY-69 experiment (throwaway spike — never merges). Screenshot the target app's front
// window, ask a vision model which control to click, synthesize a real click,
// re-screenshot, loop. Deliberately OUTSIDE the risk/approval engine — the model can click
// anything, including destructive controls. Supervised runs on the founder's machine only; every
// click is logged to the console (coordinates + rationale) before it is issued.
//
// SONNY-80 amendment: the computer-use substrate (window capture + click/typing synthesis) now
// lives behind the ComputerUseDriver seam. The CUA-backed driver is the default;
// SONNY_VISION_SUBSTRATE=handwritten selects the spike's original substrate. Loop semantics,
// prompts, and history/transcript wording are unchanged above the seam so an A/B run differs
// only in substrate.

public struct VisionActionRequest: Equatable, Sendable {
    public let appName: String
    public let goal: String
    // Seeds the model's action history with what the coordinator's tools already did, so the
    // vision phase continues the goal instead of redoing the parts a plan step completed.
    public let contextNote: String?

    public init(appName: String, goal: String, contextNote: String? = nil) {
        self.appName = appName
        self.goal = goal
        self.contextNote = contextNote
    }
}

public enum VisionActionExperiment {
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SONNY_VISION_DEBUG"] == "1"
    }

    public enum ParseOutcome: Equatable, Sendable {
        case request(VisionActionRequest)
        case malformed(hint: String)
    }

    /// nil means "not a vision command at all" — the normal pipeline proceeds untouched.
    public static func parseCommand(_ command: String) -> ParseOutcome? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vision:") else { return nil }
        let rest = trimmed.dropFirst("vision:".count)
        let parts = rest.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let appName = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let goal = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard parts.count == 2, !appName.isEmpty, !goal.isEmpty else {
            return .malformed(hint: "Vision experiment format: vision: <App Name> | <goal>")
        }
        return .request(VisionActionRequest(appName: appName, goal: goal))
    }
}

// SONNY-69 scope amendment (founder, 2026-08-08): where the vision fallback should act when a
// plan's unsupported remainder is handed to it — the app a supported step opened, the default
// browser when the plan opened a URL, or whatever is frontmost as the last resort.
public enum VisionFallbackAppHint: Equatable, Sendable {
    case browser
    case app(String)
    case frontmost
}

public enum VisionActionLoopError: Error, LocalizedError {
    case missingAPIKey(String)
    case screenRecordingNotGranted
    case accessibilityNotGranted
    case targetAppNotRunning(String, available: [String])
    case captureFailed(String)
    case badResponse(Int, String)
    case unparseableModelReply(String)
    case driverFailure(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let variable):
            return "\(variable) is not set. Add it to the environment before launching the app."
        case .screenRecordingNotGranted:
            return "Screen Recording is not granted. Enable Sonny under System Settings > Privacy & Security > Screen Recording, then relaunch and retry."
        case .accessibilityNotGranted:
            return "Accessibility is not granted. Enable Sonny under System Settings > Privacy & Security > Accessibility, then retry."
        case .targetAppNotRunning(let name, let available):
            return "\(name) is not running with a visible window. Running apps: \(available.joined(separator: ", "))"
        case .captureFailed(let reason):
            return "Window capture failed: \(reason)"
        case .badResponse(let status, let body):
            return "Vision model request failed with HTTP \(status): \(body)"
        case .unparseableModelReply(let reply):
            return "Vision model reply was not usable JSON: \(reply)"
        case .driverFailure(let reason):
            return "Computer-use driver failure: \(reason)"
        }
    }
}

/// The vision-model seam: what the loop needs from whoever decides the next action. Lets the
/// seam tests script decisions without touching the network; VisionModelClient is the real one.
protocol VisionDeciding: Sendable {
    /// e.g. "opencode/gpt-5.6-luna" — recorded in the transcript and the run summary.
    var transcriptDescription: String { get }
    func decide(prompt: String, pngData: Data) async throws -> (reply: String, latencySeconds: Double)
}

public struct VisionClarificationRequest: Equatable, Sendable {
    public let question: String
    public let rationale: String

    public init(question: String, rationale: String) {
        self.question = question
        self.rationale = rationale
    }
}

public struct VisionCoordinatorRequest: Equatable, Sendable {
    public let instruction: String
    public let rationale: String

    public init(instruction: String, rationale: String) {
        self.instruction = instruction
        self.rationale = rationale
    }
}

public enum VisionCoordinatorResult: Equatable, Sendable {
    case completed(summary: String)
    case failed(reason: String)
}

@MainActor
public protocol VisionActionLoopInteracting: Sendable {
    func requestClarification(_ request: VisionClarificationRequest) async throws -> String
    func delegateToCoordinator(_ request: VisionCoordinatorRequest) async throws -> VisionCoordinatorResult
}

public enum VisionActionLoop {
    public static let maxIterations = 10

    public struct ActionRecord: Sendable {
        public enum Kind: String, Sendable {
            case click
            case type
        }

        public let kind: Kind
        public let iteration: Int
        public let imagePoint: CGPoint?
        public let globalPoint: CGPoint?
        public let text: String?
        public let target: String
        public let rationale: String
        public let visionLatencySeconds: Double
    }

    public struct RunSummary: Sendable {
        public enum Outcome: Sendable {
            case done(String)
            case stuck(String)
            case iterationCapReached
        }

        public let outcome: Outcome
        public let actions: [ActionRecord]
        public let iterations: Int
        public let transcript: [String]
        public let modelDescription: String

        public var userSummary: String {
            let clickCount = actions.filter { $0.kind == .click }.count
            let typeCount = actions.filter { $0.kind == .type }.count
            let actionPhrase = "\(clickCount) click\(clickCount == 1 ? "" : "s") and \(typeCount) typed input\(typeCount == 1 ? "" : "s") in \(iterations) iteration\(iterations == 1 ? "" : "s") via \(modelDescription)"
            switch outcome {
            case .done(let rationale):
                return "Vision experiment finished: goal reported done after \(actionPhrase). \(rationale)"
            case .stuck(let rationale):
                return "Vision experiment stopped: model reported stuck after \(actionPhrase). \(rationale)"
            case .iterationCapReached:
                return "Vision experiment stopped: iteration cap (\(maxIterations)) reached after \(actionPhrase)."
            }
        }
    }

    public static func run(
        _ request: VisionActionRequest,
        interaction: any VisionActionLoopInteracting
    ) async throws -> RunSummary {
        let driver = ComputerUseDriverFactory.make()
        do {
            try driver.preflightPermissions()
            try await driver.prepare()
            let client = try VisionModelClient()
            let summary = try await run(request, driver: driver, decider: client, interaction: interaction)
            await driver.shutdown()
            return summary
        } catch {
            await driver.shutdown()
            throw error
        }
    }

    // `settleScale` exists for the seam tests only: it scales the loop's human-paced settle
    // sleeps (0 in tests) without changing their relative structure.
    static func run(
        _ request: VisionActionRequest,
        driver: any ComputerUseDriver,
        decider: any VisionDeciding,
        interaction: any VisionActionLoopInteracting = UnavailableVisionActionLoopInteraction(),
        settleScale: Double = 1.0
    ) async throws -> RunSummary {
        var transcript: [String] = []
        func emit(_ line: String) {
            print("[VisionLoop] \(line)")
            transcript.append(line)
        }
        func settle(_ nanoseconds: UInt64) async throws {
            let scaled = UInt64(Double(nanoseconds) * settleScale)
            if scaled > 0 {
                try await Task.sleep(nanoseconds: scaled)
            }
        }

        emit("start substrate=\(driver.substrateDescription) vision=\(decider.transcriptDescription) app=\"\(request.appName)\" goal=\"\(request.goal)\"")

        var history: [String] = []
        if let contextNote = request.contextNote {
            history.append(contextNote)
        }
        var actions: [ActionRecord] = []
        var iterationsRun = 0
        // Feedback state, live 2026-08-08: the original model's raw pointing ran ~1 list-row low and, with
        // byte-identical re-captures, the history kept implying the click worked — so the model
        // repeated the same miss six times. The marker + pixel-identical callout give it ground
        // truth to correct against.
        var lastClickImagePoint: CGPoint?
        var lastUnmarkedPNG: Data?

        for iteration in 1...maxIterations {
            iterationsRun = iteration

            guard let pid = await driver.activateApp(named: request.appName) else {
                throw VisionActionLoopError.targetAppNotRunning(request.appName, available: await driver.visibleAppNames())
            }
            try await settle(800_000_000)

            // Per-action substrate timing is the A/B's latency metric — measured loop-side with
            // the same clock for both substrates, printed into the transcript lines below.
            let captureStarted = Date()
            let capture = try await driver.captureFrontWindow(ofProcess: pid, appName: request.appName)
            let captureMillis = Int(Date().timeIntervalSince(captureStarted) * 1000)
            let unmarkedPNG = try pngData(from: capture.image)

            // Compare UNMARKED bytes across iterations: the deterministic PNG encode makes
            // byte-equality a reliable "the click changed nothing" signal.
            if let previous = lastUnmarkedPNG, previous == unmarkedPNG, let missed = lastClickImagePoint {
                history.append("IMPORTANT: your last click at image (\(Int(missed.x)), \(Int(missed.y))) produced NO visible change — the new screenshot is pixel-identical. The red circle-and-crosshair marker shows exactly where that click landed; it missed the control or that spot is not clickable. Compare the marker with the control you intended and correct your aim in the opposite direction of the miss, or choose a different approach.")
            }
            lastUnmarkedPNG = unmarkedPNG

            var png = unmarkedPNG
            if let lastClickImagePoint {
                let marked = imageByMarkingPoint(capture.image, at: lastClickImagePoint)
                png = (try? pngData(from: marked)) ?? unmarkedPNG
            }
            guard png.count <= 9_000_000 else {
                throw VisionActionLoopError.captureFailed("screenshot PNG is \(png.count) bytes, over the vision API payload limit")
            }
            emit("iteration \(iteration): captured \(capture.image.width)x\(capture.image.height)px of window \"\(capture.windowTitle)\" (\(png.count) bytes, window frame \(Int(capture.windowFrame.origin.x)),\(Int(capture.windowFrame.origin.y)) \(Int(capture.windowFrame.width))x\(Int(capture.windowFrame.height))pt, capture \(captureMillis)ms)")

            let prompt = decisionPrompt(
                request: request,
                windowTitle: capture.windowTitle,
                imageWidth: capture.image.width,
                imageHeight: capture.image.height,
                history: history
            )
            let (reply, latency) = try await decider.decide(prompt: prompt, pngData: png)
            let decision = try VisionDecision.parse(reply)
            emit("iteration \(iteration): model replied in \(String(format: "%.2f", latency))s action=\(decision.kind.rawValue) target=\"\(decision.target)\"")

            switch decision.kind {
            case .done:
                return RunSummary(outcome: .done(decision.rationale), actions: actions, iterations: iteration, transcript: transcript, modelDescription: decider.transcriptDescription)
            case .stuck:
                return RunSummary(outcome: .stuck(decision.rationale), actions: actions, iterations: iteration, transcript: transcript, modelDescription: decider.transcriptDescription)
            case .clarify:
                guard let question = decision.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else {
                    throw VisionActionLoopError.unparseableModelReply(reply)
                }
                emit("iteration \(iteration): CLARIFY — \(question)")
                history.append("iteration \(iteration): asked the user: \"\(question)\" — \(decision.rationale)")
                let answer = try await interaction.requestClarification(VisionClarificationRequest(
                    question: question,
                    rationale: decision.rationale
                ))
                emit("iteration \(iteration): user answered clarification")
                history.append("external result for iteration \(iteration): user answered: \"\(answer)\"")
                lastClickImagePoint = nil
                lastUnmarkedPNG = nil
            case .delegate:
                guard let instruction = decision.instruction?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else {
                    throw VisionActionLoopError.unparseableModelReply(reply)
                }
                emit("iteration \(iteration): DELEGATE — \(instruction)")
                history.append("iteration \(iteration): delegated to Sonny's coordinator: \"\(instruction)\" — \(decision.rationale)")
                let result = try await interaction.delegateToCoordinator(VisionCoordinatorRequest(
                    instruction: instruction,
                    rationale: decision.rationale
                ))
                switch result {
                case .completed(let summary):
                    emit("iteration \(iteration): coordinator completed — \(summary)")
                    history.append("external result for iteration \(iteration): coordinator completed: \(summary)")
                case .failed(let reason):
                    emit("iteration \(iteration): coordinator failed — \(reason)")
                    history.append("external result for iteration \(iteration): coordinator failed: \(reason)")
                }
                lastClickImagePoint = nil
                lastUnmarkedPNG = nil
            case .wait:
                emit("iteration \(iteration): WAIT — \(decision.rationale)")
                history.append("iteration \(iteration): waited for the screen to settle — \(decision.rationale)")
                try await settle(2_000_000_000)
            case .type:
                guard let text = decision.text, !text.isEmpty else {
                    throw VisionActionLoopError.unparseableModelReply(reply)
                }
                // Same mandate as clicks: log BEFORE the keystrokes are issued.
                emit("iteration \(iteration): TYPE \"\(text.replacingOccurrences(of: "\n", with: "\\n"))\" target=\"\(decision.target)\" rationale=\"\(decision.rationale)\"")
                let typeStarted = Date()
                try await driver.typeText(text)
                emit("iteration \(iteration): typing completed in \(Int(Date().timeIntervalSince(typeStarted) * 1000))ms")
                actions.append(ActionRecord(
                    kind: .type,
                    iteration: iteration,
                    imagePoint: nil,
                    globalPoint: nil,
                    text: text,
                    target: decision.target,
                    rationale: decision.rationale,
                    visionLatencySeconds: latency
                ))
                history.append("iteration \(iteration): typed \"\(text.replacingOccurrences(of: "\n", with: "\\n"))\" into \"\(decision.target)\" — \(decision.rationale)")
                try await settle(1_500_000_000)
            case .click:
                guard let initialX = decision.x, let initialY = decision.y else {
                    throw VisionActionLoopError.unparseableModelReply(reply)
                }
                // Two-stage pointing: the model's first estimate on a full-window screenshot runs
                // ~1 list-row off; a 2x zoom pass over a 320px crop around that estimate pins the
                // control's center far more precisely. Refine failure just keeps the first estimate.
                var x = initialX
                var y = initialY
                var refineLatency = 0.0
                if let refined = await refineClick(decider: decider, image: capture.image, target: decision.target, initialX: initialX, initialY: initialY) {
                    if refined.x != initialX || refined.y != initialY {
                        emit("iteration \(iteration): zoom pass refined \"\(decision.target)\" from image(\(initialX),\(initialY)) to image(\(refined.x),\(refined.y)) in \(String(format: "%.2f", refined.latency))s")
                    }
                    x = refined.x
                    y = refined.y
                    refineLatency = refined.latency
                }

                guard (0..<capture.image.width).contains(x),
                      (0..<capture.image.height).contains(y) else {
                    emit("iteration \(iteration): click image(\(x),\(y)) is outside the captured \(capture.image.width)x\(capture.image.height)px image — click skipped, recapturing")
                    history.append("iteration \(iteration): click on \"\(decision.target)\" skipped — coordinates (\(x), \(y)) are outside the screenshot bounds 0...\(capture.image.width - 1) x 0...\(capture.image.height - 1); choose a point visibly inside the new screenshot")
                    continue
                }

                // Sonny's own floating widget is a .floating-level window anchored bottom-center;
                // a click landing inside any of our own windows would be swallowed by the widget
                // while the transcript records a normal-looking click on the target app. The
                // substrate checks these rects against the freshly resolved global point.
                let ownFrames = await ownWindowFramesInCGSpace()

                // Mandated by the ticket's safety note: the intent (coordinates + rationale) is
                // logged BEFORE any event is dispatched; the substrate additionally logs the
                // resolved global point before posting.
                emit("iteration \(iteration): CLICK image(\(x),\(y)) target=\"\(decision.target)\" rationale=\"\(decision.rationale)\"")
                let clickStarted = Date()
                let outcome = try await driver.clickInWindow(capture, atImagePoint: CGPoint(x: CGFloat(x), y: CGFloat(y)), avoiding: ownFrames)
                let clickMillis = Int(Date().timeIntervalSince(clickStarted) * 1000)

                switch outcome {
                case .windowDisappeared:
                    // The frame was captured before the vision call, whose latency is uncapped —
                    // the window can vanish meanwhile; the click would be a lie. Skip, recapture.
                    emit("iteration \(iteration): window disappeared during model inference — click skipped, recapturing")
                    history.append("iteration \(iteration): click on \"\(decision.target)\" skipped — the window disappeared; reassess from the new screenshot")
                    continue
                case .windowResized(let from, let to):
                    emit("iteration \(iteration): window resized during model inference (\(Int(from.width))x\(Int(from.height)) -> \(Int(to.width))x\(Int(to.height))) — click skipped, recapturing")
                    history.append("iteration \(iteration): click on \"\(decision.target)\" skipped — the window resized; reassess from the new screenshot")
                    continue
                case .suppressed(let globalPoint, let blocked):
                    emit("iteration \(iteration): click at global(\(Int(globalPoint.x)),\(Int(globalPoint.y))) suppressed — it falls inside Sonny's own window at \(Int(blocked.origin.x)),\(Int(blocked.origin.y)) \(Int(blocked.width))x\(Int(blocked.height))")
                    history.append("iteration \(iteration): click on \"\(decision.target)\" was blocked — that screen area is covered by the operator's control panel; pick a different control or report stuck")
                    try await settle(400_000_000)
                    continue
                case .refusedByDriver(let reason):
                    emit("iteration \(iteration): click refused by the driver — \(reason) — click skipped, recapturing")
                    history.append("iteration \(iteration): click on \"\(decision.target)\" skipped — the substrate refused it (\(reason)); reassess from the new screenshot")
                    continue
                case .posted(let globalPoint):
                    emit("iteration \(iteration): click posted at global(\(Int(globalPoint.x)),\(Int(globalPoint.y))) in \(clickMillis)ms")
                    lastClickImagePoint = CGPoint(x: x, y: y)
                    actions.append(ActionRecord(
                        kind: .click,
                        iteration: iteration,
                        imagePoint: CGPoint(x: x, y: y),
                        globalPoint: globalPoint,
                        text: nil,
                        target: decision.target,
                        rationale: decision.rationale,
                        visionLatencySeconds: latency + refineLatency
                    ))
                    history.append("iteration \(iteration): clicked \"\(decision.target)\" at image (\(x), \(y)) — \(decision.rationale)")
                    let clickActions = actions.filter { $0.kind == .click }
                    if let previous = clickActions.dropLast().last, let previousPoint = previous.imagePoint,
                       abs(previousPoint.x - CGFloat(x)) <= 5, abs(previousPoint.y - CGFloat(y)) <= 5 {
                        history.append("warning: you clicked this same spot twice with no visible effect — choose a different control or report stuck")
                    }
                    try await settle(1_200_000_000)
                }
            }
        }

        return RunSummary(outcome: .iterationCapReached, actions: actions, iterations: iterationsRun, transcript: transcript, modelDescription: decider.transcriptDescription)
    }

    // MARK: - Fallback target resolution

    public static func resolveAppName(for hint: VisionFallbackAppHint) async -> String? {
        switch hint {
        case .app(let name):
            return name
        case .browser:
            return await MainActor.run { () -> String? in
                guard let httpsURL = URL(string: "https://example.com"),
                      let appURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL),
                      let bundle = Bundle(url: appURL) else {
                    return nil
                }
                return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent
            }
        case .frontmost:
            return await MainActor.run { () -> String? in
                // Sonny itself being frontmost is never a useful vision target.
                let ownName = NSRunningApplication.current.localizedName
                let frontName = NSWorkspace.shared.frontmostApplication?.localizedName
                return frontName == ownName ? nil : frontName
            }
        }
    }

    // MARK: - Own-window suppression rects

    // NSWindow.frame is bottom-left-origin Cocoa space; convert to the top-left-origin global
    // display space the click math lives in before comparing. Stays loop-side (it inspects
    // Sonny's own NSApp windows, which no substrate should know about).
    private static func ownWindowFramesInCGSpace() async -> [CGRect] {
        await MainActor.run { () -> [CGRect] in
            let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height
            guard let primaryHeight else { return [] }
            // NSApp is an implicitly-unwrapped global that is nil in a headless test process —
            // the seam tests are the first thing to ever drive this path without a real app.
            guard let application = NSApp else { return [] }
            return application.windows.filter { $0.isVisible }.map { window in
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

    // MARK: - Click-precision helpers

    // Red circle + crosshair at the previous click's image coordinates, so the model can see
    // exactly where its click landed and correct a miss. CGContext is bottom-left-origin, so
    // the y is flipped once here.
    private static func imageByMarkingPoint(_ image: CGImage, at point: CGPoint) -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width,
                  height: image.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let flippedY = CGFloat(image.height) - point.y
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)
        context.strokeEllipse(in: CGRect(x: point.x - 14, y: flippedY - 14, width: 28, height: 28))
        context.move(to: CGPoint(x: point.x - 22, y: flippedY))
        context.addLine(to: CGPoint(x: point.x + 22, y: flippedY))
        context.move(to: CGPoint(x: point.x, y: flippedY - 22))
        context.addLine(to: CGPoint(x: point.x, y: flippedY + 22))
        context.strokePath()
        return context.makeImage() ?? image
    }

    private static func upscaled2x(_ image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: image.width * 2,
                  height: image.height * 2,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        return context.makeImage()
    }

    private static func refineClick(
        decider: any VisionDeciding,
        image: CGImage,
        target: String,
        initialX: Int,
        initialY: Int
    ) async -> (x: Int, y: Int, latency: Double)? {
        let side = 320
        guard image.width >= side, image.height >= side else { return nil }
        let x0 = max(0, min(image.width - side, initialX - side / 2))
        let y0 = max(0, min(image.height - side, initialY - side / 2))
        guard let crop = image.cropping(to: CGRect(x: x0, y: y0, width: side, height: side)),
              let zoomed = upscaled2x(crop),
              let png = try? pngData(from: zoomed) else {
            return nil
        }
        let prompt = """
        Zoomed 2x view of a \(side)x\(side)-pixel region of the same window screenshot, origin top-left. Find this control: "\(target)". Reply ONLY {"x":<int>,"y":<int>} — the point in THIS zoomed \(side * 2)x\(side * 2) image that sits EXACTLY on the target's visible text, in the vertical middle of its glyphs (never the row, container, or whitespace around it) — or {"x":null,"y":null} if it is not visible here.
        """
        guard let response = try? await decider.decide(prompt: prompt, pngData: png),
              let refined = parseRefinement(response.reply),
              (0...side * 2).contains(refined.x), (0...side * 2).contains(refined.y) else {
            return nil
        }
        return (x0 + refined.x / 2, y0 + refined.y / 2, response.latencySeconds)
    }

    private static func parseRefinement(_ reply: String) -> (x: Int, y: Int)? {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(String(reply[start...end]).utf8)) as? [String: Any] else {
            return nil
        }
        func intValue(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String { return Int(value) }
            return nil
        }
        guard let x = intValue("x"), let y = intValue("y") else { return nil }
        return (x, y)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw VisionActionLoopError.captureFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw VisionActionLoopError.captureFailed("could not encode PNG")
        }
        return data as Data
    }

    // MARK: - Prompt

    private static func decisionPrompt(
        request: VisionActionRequest,
        windowTitle: String,
        imageWidth: Int,
        imageHeight: Int,
        history: [String]
    ) -> String {
        let historyBlock = history.isEmpty ? "none yet" : history.joined(separator: "\n")
        return """
        You are a precise macOS UI vision agent. You see one screenshot of the window \"\(windowTitle)\" of the app \"\(request.appName)\". The screenshot is \(imageWidth)x\(imageHeight) pixels; the coordinate origin (0,0) is the TOP-LEFT corner, x grows right, y grows down. Every click must satisfy 0 <= x < \(imageWidth) and 0 <= y < \(imageHeight); never estimate coordinates outside those bounds.

        GOAL: \(request.goal)

        Actions already taken:
        \(historyBlock)

        Decide the single next action toward the goal. Reply with ONLY a JSON object, no markdown fences, no extra text. One of:
        {"action":"click","x":<int>,"y":<int>,"target":"<visible label of the control>","rationale":"<one short sentence>"}
        {"action":"type","text":"<the literal text to type>","target":"<the focused text field>","rationale":"<one short sentence>"}
        {"action":"wait","x":null,"y":null,"target":"","rationale":"<why>"}
        {"action":"clarify","question":"<one specific question for the user>","rationale":"<why the answer is required>"}
        {"action":"delegate","instruction":"<one bounded task for Sonny's coordinator>","rationale":"<why this is better handled outside the visible UI>"}
        {"action":"done","x":null,"y":null,"target":"","rationale":"<why>"}
        {"action":"stuck","x":null,"y":null,"target":"","rationale":"<why>"}
        Coordinates must be pixels inside this screenshot. Aim EXACTLY at the visible text of the target itself: put the point in the vertical middle of the text glyphs (a name, a button label), never on the row, container, or whitespace around it. If the target has both an icon and a text label, click the text label.
        A red circle-and-crosshair marker, when visible, marks exactly where your PREVIOUS click landed. If the marker is not sitting on the target's text, your aim was off — shift your next coordinates by the same distance in the opposite direction of the miss.
        "type" sends real keystrokes to whatever control currently has keyboard focus — click the text field first in an earlier action if it is not already focused, and only type text the goal itself calls for. To submit what you typed (a chat message, an address bar URL), end the text with \\n — it is delivered as a real Return keypress.
        Use "wait" when the page or app is visibly still loading and the right move is to let it finish.
        Use "clarify" only when the goal is ambiguous and one specific answer from the user is required before acting.
        Use "delegate" when a bounded subtask is better handled by Sonny's coordinator tools, such as opening another app or URL, accessing local files, researching information, creating a file, or writing a summary. Do not delegate clicks or typing in the current app. The coordinator result will be returned in Actions already taken, then you will receive a fresh screenshot of this app and continue the original goal.
        Use "done" when the goal is already visibly complete in this screenshot; use "stuck" only after a click, typing, and waiting have all failed to advance the goal.
        """
    }
}

// MARK: - Vision model client (OpenCode Zen Responses API)

struct VisionModelClient: VisionDeciding {
    let model: String
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    var transcriptDescription: String { "opencode/\(model)" }

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        endpoint: URL = URL(string: "https://opencode.ai/zen/go/v1/responses")!,
        session: URLSession = .shared
    ) throws {
        self.model = environment["SONNY_VISION_MODEL"] ?? "gpt-5.6-luna"
        self.endpoint = endpoint
        self.session = session
        guard let key = environment["OPENCODE_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisionActionLoopError.missingAPIKey("OPENCODE_API_KEY")
        }
        self.apiKey = key
    }

    func decide(prompt: String, pngData: Data) async throws -> (reply: String, latencySeconds: Double) {
        let started = Date()
        let reply = try await decideViaOpenCode(prompt: prompt, pngData: pngData)
        return (reply, Date().timeIntervalSince(started))
    }

    private func decideViaOpenCode(prompt: String, pngData: Data) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": prompt],
                        [
                            "type": "input_image",
                            "image_url": "data:image/png;base64,\(pngData.base64EncodedString())"
                        ]
                    ]
                ]
            ]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        do {
            return try OpenAIResponseParser.outputText(from: data)
        } catch {
            throw VisionActionLoopError.unparseableModelReply(String(data: data, encoding: .utf8) ?? "<unreadable body>")
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VisionActionLoopError.badResponse(-1, "No HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VisionActionLoopError.badResponse(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "<unreadable body>")
        }
        return data
    }
}

// MARK: - Model decision parsing (deliberately lenient about surrounding text)

struct VisionDecision {
    enum Kind: String {
        case click
        case type
        case wait
        case clarify
        case delegate
        case done
        case stuck
    }

    let kind: Kind
    let x: Int?
    let y: Int?
    let text: String?
    let question: String?
    let instruction: String?
    let target: String
    let rationale: String

    static func parse(_ reply: String) throws -> VisionDecision {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else {
            throw VisionActionLoopError.unparseableModelReply(reply)
        }
        let jsonText = String(reply[start...end])
        guard let object = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any],
              let actionRaw = object["action"] as? String,
              let kind = Kind(rawValue: actionRaw.lowercased()) else {
            throw VisionActionLoopError.unparseableModelReply(reply)
        }
        func intValue(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? Double { return Int(value) }
            if let value = object[key] as? String { return Int(value) }
            return nil
        }
        return VisionDecision(
            kind: kind,
            x: intValue("x"),
            y: intValue("y"),
            text: object["text"] as? String,
            question: object["question"] as? String,
            instruction: object["instruction"] as? String,
            target: object["target"] as? String ?? "",
            rationale: object["rationale"] as? String ?? ""
        )
    }
}

private struct UnavailableVisionActionLoopInteraction: VisionActionLoopInteracting {
    func requestClarification(_ request: VisionClarificationRequest) async throws -> String {
        throw VisionActionLoopError.driverFailure("Vision clarification is unavailable in this host.")
    }

    func delegateToCoordinator(_ request: VisionCoordinatorRequest) async throws -> VisionCoordinatorResult {
        throw VisionActionLoopError.driverFailure("Vision coordinator delegation is unavailable in this host.")
    }
}
