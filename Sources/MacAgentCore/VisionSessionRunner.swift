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

    /// The session's own record, built as the session runs.
    ///
    /// **Written here, by engine code, as each action executes** — §13.6's requirement, and the
    /// difference between an audit surface and a summary. A UI-side reconstruction could only say
    /// what the code believes it did; this is written from the same values the decision used, at the
    /// moment it was made.
    private var record: VisionSessionRecord
    /// The redaction summary of the capture the current decision came from, carried onto the entry
    /// so a reader can see what was protected on the picture that produced the action.
    private var currentRedactionSummary: [RedactionReportEntry] = []
    /// How the pending action was authorized, decided by `authorize` and read by `perform`.
    private var pendingApprovalState: VisionActionJournalEntry.ApprovalState = .ranWithoutAsking

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
        self.record = VisionSessionRecord(
            goal: goal,
            appDisplayName: target.displayName,
            startedAt: environment.now()
        )
    }

    func run() async throws -> VisionSessionOutcome {
        do {
            return try await runLoop()
        } catch {
            // **A thrown exit still leaves a record, and this is the case that matters most.** A
            // cancelled session — the user pressing stop, or the emergency hotkey — propagates a
            // `CancellationError` straight past every `end(with:)`, so without this the runs someone
            // would most want to read afterwards would be exactly the ones that recorded nothing.
            // Same for a capture failure, a model error, or anything else the loop throws.
            //
            // The record is closed with the honest reason rather than a generic one: a cancellation
            // is `user_stopped`, everything else is `failed` with the error's own text.
            if error is CancellationError {
                finishRecord(reasonCode: VisionContainmentRefusal.cancelled.reasonCode, summary: "Stopped.")
            } else {
                finishRecord(reasonCode: "failed", summary: error.localizedDescription)
            }
            throw error
        }
    }

    private func runLoop() async throws -> VisionSessionOutcome {
        guard let interaction = environment.interaction else {
            throw VisionSessionError.visionUnavailable
        }

        interaction.visionSessionDidStart(id: record.id)
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
                } else if case .attentionLost(let state) = refusal {
                    // **Pause, not stop** (SONNY-94). Attention is the one refusal a human can
                    // actually answer — they came back — so the session suspends and waits for them
                    // to say so, rather than ending work they may still want. Every other refusal in
                    // `checkIterationStart` is a fact no answer changes, and those still end.
                    let resumed = try await interaction.awaitVisionResume(
                        VisionSessionPause(
                            appDisplayName: target.displayName,
                            reason: state,
                            iteration: iteration
                        )
                    )
                    guard resumed else {
                        return end(with: refusal, iteration: iteration)
                    }
                    // Re-check rather than trust the resume: the user pressing Resume is a claim that
                    // they are back, and the OS is the thing that confirms it. A screen still locked
                    // pauses again, which is a loop the user ends by unlocking or by stopping.
                    iteration -= 1
                    continue
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

            // **The observed text is redacted too, not just the pixels** (PR #50 review, F5). The
            // window title is screen-derived — an app names its own window, and a title carries
            // document names, mail subjects, customer names, and sometimes an ID or an email — and it
            // used to leave the machine in the clear beside a carefully redacted image. The history
            // is screen-derived for the same reason: its entries quote control labels the model read
            // off the window.
            let redactedObserved = environment.redactionService.redactText(
                VisionSessionPromptBuilder.observedBlock(windowTitle: capture.windowTitle, history: history)
            )
            // Both halves of the send are recorded, so a journal entry says what was covered on the
            // picture *and* in the text that went with it.
            currentRedactionSummary = payload.report + redactedObserved.report

            let prompt = VisionSessionPromptBuilder.decisionPrompt(
                goal: goal,
                appDisplayName: target.displayName,
                redactedObserved: redactedObserved,
                imageWidth: payload.imagePixelWidth ?? capture.pixelWidth,
                imageHeight: payload.imagePixelHeight ?? capture.pixelHeight
            )
            log(.observe, "vision: iteration \(iteration) — sending a redacted capture of \(target.displayName)")
            let reply = try await environment.modelClient.decide(prompt: prompt, payload: payload)
            let decision = try VisionDecisionParser.decision(from: reply)
            log(.act, "vision: iteration \(iteration) — \(decision.actionDescription)")

            switch decision.kind {
            case .done:
                finishRecord(reasonCode: "completed", summary: decision.rationale)
                return VisionSessionOutcome(
                    ending: .finished(decision.rationale),
                    iterationsRun: iteration,
                    actionsTaken: actionsTaken
                )
            case .stuck:
                finishRecord(reasonCode: "gave_up", summary: decision.rationale)
                return VisionSessionOutcome(
                    ending: .gaveUp(decision.rationale),
                    iterationsRun: iteration,
                    actionsTaken: actionsTaken
                )
            case .wait:
                history.append("iteration \(iteration): waited for the screen to settle — \(decision.rationale)")
                try await settle(multiplier: 2)
                continue
            case .delegate:
                // **One iteration, no recursion, engine-routed.** The delegation costs an iteration
                // like any other decision, so a model that only delegates still hits the cap; the
                // result rejoins as observed history and the next iteration starts from a fresh
                // screenshot, which is why both no-change trackers are irrelevant here — nothing was
                // clicked.
                guard let instruction = decision.instruction else {
                    continue
                }
                let request = VisionDelegationRequest(
                    instruction: instruction,
                    rationale: decision.rationale,
                    appDisplayName: target.displayName
                )
                // Safe mode asks about the delegation itself; Normal and Power never do (founder,
                // 2026-08-14). What the delegated plan *does* is gated in every mode by the ordinary
                // plan-level gate inside `runVisionDelegation`.
                if interaction.visionApprovalContext().safeMode {
                    let allowed = try await interaction.confirmVisionDelegation(request)
                    guard allowed else {
                        history.append("iteration \(iteration): you declined to let Sonny's own tools do \u{201C}\(instruction)\u{201D}. Continue from the screen instead, or report stuck.")
                        continue
                    }
                }
                interaction.visionSessionDidProgress(
                    VisionSessionProgress(
                        appDisplayName: target.displayName,
                        iteration: iteration,
                        maximumIterations: containment.limits.maximumIterations,
                        currentAction: decision.actionDescription
                    )
                )
                switch try await interaction.runVisionDelegation(request) {
                case .completed(let summary):
                    history.append("external result for iteration \(iteration): Sonny's own tools completed \u{201C}\(instruction)\u{201D} — \(summary)")
                case .failed(let reason):
                    history.append("external result for iteration \(iteration): Sonny's own tools could not do \u{201C}\(instruction)\u{201D} — \(reason). Try the on-screen route instead, or report stuck.")
                }
                try await settle()
                continue
            case .click, .type, .scroll, .key:
                break
            }

            if let refusal = containment.checkActionAllowed(decision) {
                return end(with: refusal, iteration: iteration)
            }

            // §13.1's tier-3 condition, checked here rather than at iteration start because a screen
            // can lock in the seconds a model spent deciding — and this is the moment an approval
            // would actually be shown.
            if VisionConsequenceClassifier.consequence(for: decision).asksFirst,
               let refusal = await containment.checkApprovalPresentable() {
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
            pendingApprovalState = .ranWithoutAsking
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
                pendingApprovalState = .coveredByEarlierApproval
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
            pendingApprovalState = .approved
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
                    journal(decision, imagePoint: nil, observationAfter: "Scrolled at the pointer.")
                }
                return
            }
            let imagePoint = CGPoint(x: CGFloat(x), y: CGFloat(y))
            guard VisionPointResolver.isInsideImage(imagePoint, capture: capture) else {
                history.append("iteration \(iteration): \(decision.kind.rawValue) on \u{201C}\(decision.target)\u{201D} was skipped — the point (\(x), \(y)) is outside the \(capture.pixelWidth)x\(capture.pixelHeight) screenshot. Choose a point visibly inside the new screenshot.")
                // Journalled even though nothing was synthesized. A skipped action is a thing Sonny
                // decided and did not do, and a record showing only successes would read as a
                // cleaner run than the one that happened.
                journal(decision, imagePoint: imagePoint, observationAfter: "Skipped: the point was outside the captured window.")
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
                journal(decision, imagePoint: imagePoint, observationAfter: "Skipped: the window disappeared before the action was sent.")
                history.append("iteration \(iteration): the action was skipped — \(target.displayName)'s window disappeared. Reassess from the new screenshot.")
            case .windowResized(let from, let to):
                journal(decision, imagePoint: imagePoint, observationAfter: "Skipped: the window resized, so the point no longer named the control.")
                history.append("iteration \(iteration): the action was skipped — the window resized from \(Int(from.width))x\(Int(from.height)) to \(Int(to.width))x\(Int(to.height)) and the layout moved. Reassess from the new screenshot.")
            case .suppressedOwnWindow:
                journal(decision, imagePoint: imagePoint, observationAfter: "Blocked: the point fell inside Sonny's own window.")
                history.append("iteration \(iteration): the action was blocked — that part of the screen is covered by Sonny's own window. Pick a different control or report stuck.")
                try await settle(multiplier: 0.5)
            case .posted(let globalPoint):
                if decision.kind == .click {
                    try await environment.synthesizer.click(atGlobalPoint: globalPoint)
                    history.append("iteration \(iteration): clicked \u{201C}\(decision.target)\u{201D}")
                    journal(
                        decision,
                        imagePoint: imagePoint,
                        observationAfter: "Clicked at screen point (\(Int(globalPoint.x)), \(Int(globalPoint.y)))."
                    )
                } else {
                    try await environment.synthesizer.scroll(
                        atGlobalPoint: globalPoint,
                        direction: decision.scrollDirection ?? .down,
                        amount: 3
                    )
                    history.append("iteration \(iteration): scrolled \(decision.scrollDirection?.rawValue ?? "down")")
                    journal(decision, imagePoint: imagePoint, observationAfter: "Scrolled in the window.")
                }
                actionsTaken += 1
            }

        case .type:
            let text = decision.text ?? ""
            try await environment.synthesizer.type(text)
            actionsTaken += 1
            journal(
                decision,
                imagePoint: nil,
                observationAfter: text.hasSuffix("\n")
                    ? "Typed the text and pressed Return, which submits in most apps."
                    : "Typed the text into whatever had keyboard focus."
            )
            history.append("iteration \(iteration): typed \u{201C}\(VisionDecision.previewText(text))\u{201D}")

        case .key:
            guard let key = decision.key else {
                return
            }
            try await environment.synthesizer.press(key)
            actionsTaken += 1
            journal(decision, imagePoint: nil, observationAfter: "Pressed \(key.rawValue).")
            history.append("iteration \(iteration): pressed \(key.rawValue)")

        case .delegate, .wait, .done, .stuck:
            break
        }
    }

    private func end(with refusal: VisionContainmentRefusal, iteration: Int) -> VisionSessionOutcome {
        log(.summarize, "vision: \(refusal.reasonCode) — \(refusal.userFacingReason)")
        finishRecord(reasonCode: refusal.reasonCode, summary: refusal.userFacingReason)
        return VisionSessionOutcome(
            ending: .refused(refusal),
            iterationsRun: iteration,
            actionsTaken: actionsTaken
        )
    }

    /// Close and persist the session's record.
    ///
    /// **A write failure is reported, never swallowed, and never fails the run.** The session already
    /// happened; refusing to report it because its record could not be saved would tell the user the
    /// opposite of the truth. The wording is a write failure's own, not the load-failure banner's —
    /// those are different things with different correct messages, and conflating them is a bug this
    /// repo has already had once.
    private func finishRecord(reasonCode: String, summary: String) {
        guard let store = environment.journalStore else {
            return
        }
        record.endedAt = environment.now()
        record.endReasonCode = reasonCode
        record.endSummary = summary
        do {
            try store.save(record)
        } catch {
            log(.summarize, "Sonny could not save this session's record: \(error.localizedDescription)")
        }
    }

    /// One entry per synthesized action, written at the moment it executed.
    private func journal(
        _ decision: VisionDecision,
        imagePoint: CGPoint?,
        observationAfter: String
    ) {
        let consequence = VisionConsequenceClassifier.consequence(for: decision)
        record.entries.append(
            VisionActionJournalEntry(
                timestamp: environment.now(),
                appDisplayName: target.displayName,
                appBundleIdentifier: target.bundleIdentifier,
                actionType: decision.kind.rawValue,
                targetDescription: decision.target,
                imageX: imagePoint.map { Int($0.x) },
                imageY: imagePoint.map { Int($0.y) },
                riskTier: containment.assessment(for: decision).effectiveTier,
                consequence: consequence,
                approvalState: pendingApprovalState,
                observationAfter: observationAfter,
                redactionSummary: currentRedactionSummary
            )
        )
    }

    private func settle(multiplier: Double = 1) async throws {
        try await Task.sleep(
            nanoseconds: UInt64(Double(containment.limits.settleNanoseconds) * multiplier)
        )
    }
}
