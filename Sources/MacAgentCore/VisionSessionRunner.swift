import CoreGraphics
import Foundation

/// How a session ended.
public struct VisionSessionOutcome: Equatable, Sendable {
    public enum Ending: Equatable, Sendable {
        case finished(String)
        case gaveUp(String)
        case refused(VisionContainmentRefusal)
    }

    public let ending: Ending
    public let iterationsRun: Int
    public let actionsTaken: Int

    public var summary: String {
        switch ending {
        case .finished(let rationale):
            return rationale.isEmpty ? "Done." : rationale
        case .gaveUp(let rationale):
            return rationale.isEmpty
                ? "Sonny could not finish this from the screen."
                : "Sonny stopped: \(rationale)"
        case .refused(let refusal):
            return refusal.userFacingReason
        }
    }
}

/// The capture-decide-act loop.
///
/// **What this type is not allowed to do.** It never decides whether an action may run — it asks
/// ``VisionSessionContainment``, which asks the risk engine. It never sends anything — it hands a
/// ``RedactedPayload`` to the model client, and a payload is a thing only `LocalRedactionService`
/// can mint. It never treats screen content as instruction — everything it observed goes into the
/// prompt inside the untrusted wrapper, and the user's goal is the only text inside the trusted one.
/// Those three sentences are the whole security posture of screen control, and each is structural
/// here rather than remembered.
@MainActor
final class VisionSessionRunner {
    private let goal: String
    private let target: ScreenControlVerdict
    private let environment: VisionSessionEnvironment
    private let containment: VisionSessionContainment
    private let log: (AgentPhase, String) -> Void

    /// The consent carried across iterations — the SONNY-62 re-arm mechanism, mid-loop.
    ///
    /// One approval covers later actions whose fresh assessment it still authorizes; a second,
    /// *different* tier-3 reason re-prompts, because `RiskApprovalConsent.authorizes` compares reason
    /// sets and not bare tiers. This is exactly the bug SONNY-62 fixed at the plan level, and it is
    /// sharper here: within one session a user might approve "click Send" and then be shown "click
    /// Delete" — same tier, same requirement, entirely different question.
    private var carriedConsent: RiskApprovalDecision = .notRequested

    /// What has happened so far, in the model's own terms. Observed content, and wrapped as such.
    private var history: [String] = []
    private var actionsTaken = 0

    init(
        goal: String,
        target: ScreenControlVerdict,
        environment: VisionSessionEnvironment,
        containment: VisionSessionContainment,
        log: @escaping (AgentPhase, String) -> Void
    ) {
        self.goal = goal
        self.target = target
        self.environment = environment
        self.containment = containment
        self.log = log
    }

    func run() async throws -> VisionSessionOutcome {
        guard let interaction = environment.interaction else {
            throw VisionSessionError.visionUnavailable
        }

        try environment.captureService.preflightScreenRecording()
        try environment.captureService.preflightAccessibilityControl()

        var iteration = 0
        while true {
            iteration += 1

            if let refusal = await containment.checkIterationStart(
                iteration: iteration,
                isCancelled: Task.isCancelled,
                // The synthesizer alone, not the whole environment: the environment holds a
                // main-actor-bound interaction seam and so is not `Sendable`, while the substrate is.
                frontmostBundleIdentifier: { [synthesizer = environment.synthesizer] in
                    await synthesizer.frontmostBundleIdentifier()
                }
            ) {
                // The frontmost check fails on the very first iteration whenever the app simply is
                // not in front yet, which is the ordinary case — so activation happens once, here,
                // rather than unconditionally at the top of every iteration where it would be a
                // focus steal on every loop.
                if case .targetNotFrontmost = refusal, iteration == 1 {
                    guard await environment.synthesizer.activateApp(bundleIdentifier: target.bundleIdentifier) else {
                        throw VisionSessionError.targetAppNotRunning(target.displayName)
                    }
                    try await settle()
                    if let stillRefused = await containment.checkIterationStart(
                        iteration: iteration,
                        isCancelled: Task.isCancelled,
                        frontmostBundleIdentifier: { [synthesizer = environment.synthesizer] in
                            await synthesizer.frontmostBundleIdentifier()
                        }
                    ) {
                        return end(with: stillRefused, iteration: iteration)
                    }
                } else {
                    return end(with: refusal, iteration: iteration)
                }
            }

            let capture = try await environment.captureService.captureFrontmostWindow(
                ofBundleIdentifier: target.bundleIdentifier
            )
            // **Redaction is not optional and not skippable.** `redactCapture` is the only producer
            // of the type the model client will accept, so there is no branch of this loop that can
            // send `capture.pngData` — it does not type-check.
            let payload = try await environment.redactionService.redactCapture(capture)

            interaction.visionSessionDidProgress(
                VisionSessionProgress(
                    appDisplayName: target.displayName,
                    iteration: iteration,
                    maximumIterations: containment.limits.maximumIterations,
                    currentAction: "Looking at \(target.displayName)"
                )
            )

            let context = interaction.visionApprovalContext()
            if context.safeMode {
                let allowed = try await interaction.confirmVisionCaptureBeforeSending(
                    VisionCapturePreview(
                        appDisplayName: target.displayName,
                        windowTitle: capture.windowTitle,
                        redactedPNGData: payload.redactedImagePNGData,
                        pixelWidth: payload.imagePixelWidth ?? capture.pixelWidth,
                        pixelHeight: payload.imagePixelHeight ?? capture.pixelHeight,
                        redactionReport: payload.report,
                        iteration: iteration
                    )
                )
                guard allowed else {
                    return end(with: .captureSendDeclined, iteration: iteration)
                }
            }

            let prompt = VisionSessionPromptBuilder.decisionPrompt(
                goal: goal,
                appDisplayName: target.displayName,
                windowTitle: capture.windowTitle,
                imageWidth: payload.imagePixelWidth ?? capture.pixelWidth,
                imageHeight: payload.imagePixelHeight ?? capture.pixelHeight,
                history: history
            )
            log(.observe, "vision: iteration \(iteration) — sending a redacted capture of \(target.displayName)")
            let reply = try await environment.modelClient.decide(prompt: prompt, payload: payload)
            let decision = try VisionDecisionParser.decision(from: reply)
            log(.act, "vision: iteration \(iteration) — \(decision.actionDescription)")

            switch decision.kind {
            case .done:
                return VisionSessionOutcome(
                    ending: .finished(decision.rationale),
                    iterationsRun: iteration,
                    actionsTaken: actionsTaken
                )
            case .stuck:
                return VisionSessionOutcome(
                    ending: .gaveUp(decision.rationale),
                    iterationsRun: iteration,
                    actionsTaken: actionsTaken
                )
            case .wait:
                history.append("iteration \(iteration): waited for the screen to settle — \(decision.rationale)")
                try await settle(multiplier: 2)
                continue
            case .click, .type, .scroll, .key:
                break
            }

            if let refusal = containment.checkActionAllowed(decision) {
                return end(with: refusal, iteration: iteration)
            }

            switch try await authorize(decision, interaction: interaction) {
            case .refused(let refusal):
                return end(with: refusal, iteration: iteration)
            case .allowed:
                break
            }

            interaction.visionSessionDidProgress(
                VisionSessionProgress(
                    appDisplayName: target.displayName,
                    iteration: iteration,
                    maximumIterations: containment.limits.maximumIterations,
                    currentAction: decision.actionDescription
                )
            )

            try await perform(decision, capture: capture, iteration: iteration)
            try await settle()
        }
    }

    // MARK: - The engine gate, per action

    private enum Authorization {
        case allowed
        case refused(VisionContainmentRefusal)
    }

    /// One action, through the one public path to a requirement.
    private func authorize(
        _ decision: VisionDecision,
        interaction: any VisionSessionInteracting
    ) async throws -> Authorization {
        let context = interaction.visionApprovalContext()
        let (assessment, requirement) = containment.requirement(for: decision, context: context)
        let request = RiskApprovalRequest(assessment: assessment, requirement: requirement)

        switch requirement {
        case .autoRun:
            // The ran-without-asking trace: an action that did not ask still says what it did and
            // why it did not have to. This is the whole of E9's transparency posture for Normal mode.
            log(.risk, "risk.ranWithoutAsking: \(decision.actionDescription) — \(containment.escalationReason(for: decision, consequence: VisionConsequenceClassifier.consequence(for: decision)))")
            return .allowed
        case .previewOnly:
            return .refused(.approvalRefusedByPolicy(action: decision.actionDescription))
        case .refuse:
            return .refused(.approvalRefusedByPolicy(action: decision.actionDescription))
        case .lightweightConfirmation, .explicitApproval:
            // The re-arm, mid-loop. A consent already given covers this action only if it still
            // authorizes the *fresh* request — same rule, same function, as the plan-level gate in
            // `AgentRunner.execute`.
            if carriedConsent.authorizes(request) {
                log(.risk, "vision: covered by the approval you already gave — \(decision.actionDescription)")
                return .allowed
            }
            if case .approved(let consent) = carriedConsent {
                let unacknowledged = consent.unacknowledgedReasons(in: request)
                if !unacknowledged.isEmpty {
                    log(.risk, "risk.rearmed: reasons not covered by the approval: \(unacknowledged.joined(separator: " "))")
                }
            }
            guard let decisionGiven = try await interaction.requestVisionActionApproval(request) else {
                return .refused(.approvalDeclined(action: decision.actionDescription))
            }
            carriedConsent = decisionGiven
            return .allowed
        }
    }

    // MARK: - Acting

    private func perform(_ decision: VisionDecision, capture: CapturedWindowImage, iteration: Int) async throws {
        switch decision.kind {
        case .click, .scroll:
            guard let x = decision.x, let y = decision.y else {
                // A scroll with no point scrolls wherever the pointer is, which is the sensible
                // default; a click without coordinates cannot parse, so this arm is scroll-only.
                if decision.kind == .scroll {
                    try await environment.synthesizer.scroll(
                        atGlobalPoint: nil,
                        direction: decision.scrollDirection ?? .down,
                        amount: 3
                    )
                    actionsTaken += 1
                    history.append("iteration \(iteration): scrolled \(decision.scrollDirection?.rawValue ?? "down")")
                }
                return
            }
            let imagePoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
            guard VisionPointResolver.isInsideImage(imagePoint, capture: capture) else {
                history.append("iteration \(iteration): \(decision.kind.rawValue) on \u{201C}\(decision.target)\u{201D} was skipped — the point (\(x), \(y)) is outside the \(capture.pixelWidth)x\(capture.pixelHeight) screenshot. Choose a point visibly inside the new screenshot.")
                return
            }

            let outcome = VisionPointResolver.resolve(
                imagePoint: imagePoint,
                capture: capture,
                freshFrame: await environment.synthesizer.currentWindowFrame(windowID: capture.windowID),
                ownWindowFrames: await environment.synthesizer.ownWindowFrames()
            )
            switch outcome {
            case .windowDisappeared:
                history.append("iteration \(iteration): the action was skipped — \(target.displayName)'s window disappeared. Reassess from the new screenshot.")
            case .windowResized(let from, let to):
                history.append("iteration \(iteration): the action was skipped — the window resized from \(Int(from.width))x\(Int(from.height)) to \(Int(to.width))x\(Int(to.height)) and the layout moved. Reassess from the new screenshot.")
            case .suppressedOwnWindow:
                history.append("iteration \(iteration): the action was blocked — that part of the screen is covered by Sonny's own window. Pick a different control or report stuck.")
                try await settle(multiplier: 0.5)
            case .posted(let globalPoint):
                if decision.kind == .click {
                    try await environment.synthesizer.click(atGlobalPoint: globalPoint)
                    history.append("iteration \(iteration): clicked \u{201C}\(decision.target)\u{201D}")
                } else {
                    try await environment.synthesizer.scroll(
                        atGlobalPoint: globalPoint,
                        direction: decision.scrollDirection ?? .down,
                        amount: 3
                    )
                    history.append("iteration \(iteration): scrolled \(decision.scrollDirection?.rawValue ?? "down")")
                }
                actionsTaken += 1
            }

        case .type:
            let text = decision.text ?? ""
            try await environment.synthesizer.type(text)
            actionsTaken += 1
            history.append("iteration \(iteration): typed \u{201C}\(VisionDecision.previewText(text))\u{201D}")

        case .key:
            guard let key = decision.key else {
                return
            }
            try await environment.synthesizer.press(key)
            actionsTaken += 1
            history.append("iteration \(iteration): pressed \(key.rawValue)")

        case .wait, .done, .stuck:
            break
        }
    }

    private func end(with refusal: VisionContainmentRefusal, iteration: Int) -> VisionSessionOutcome {
        log(.summarize, "vision: \(refusal.reasonCode) — \(refusal.userFacingReason)")
        return VisionSessionOutcome(
            ending: .refused(refusal),
            iterationsRun: iteration,
            actionsTaken: actionsTaken
        )
    }

    private func settle(multiplier: Double = 1) async throws {
        try await Task.sleep(
            nanoseconds: UInt64(Double(containment.limits.settleNanoseconds) * multiplier)
        )
    }
}
