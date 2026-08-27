import CoreGraphics
import Foundation

/// How a session ended.
public struct VisionSessionOutcome: Equatable, Sendable {
    /// How a session ended, with the model-authored endings carrying `RedactedPayload` rather than
    /// `String`.
    ///
    /// **The type is the guarantee** (PR #50 cycle-2, F13a). A `.finished`/`.gaveUp` rationale is the
    /// vision model's own free text, written after reading the user's screen — and it does not stop
    /// at the summary line. It flows `AgentRunResult.summary` → `recordPriorTaskContext` →
    /// `PriorTaskContext.plannerContextText` → the **planner** provider, as a `user` message on the
    /// next command within ten minutes. F5 closed the screen-text route to the *vision* provider and
    /// this route to a *different* provider was still open.
    ///
    /// `RedactedPayload`'s initializer is `fileprivate` to `LocalRedactionService.swift`, so an
    /// unredacted rationale cannot be put in this enum at all — the same structural non-bypass the
    /// window title got, rather than a call site somebody has to remember. `.refused` keeps its
    /// `String` deliberately: that sentence is code-authored by `VisionContainmentRefusal`, never
    /// model-authored, and giving it the redacted type would imply a provenance it does not have.
    public enum Ending: Equatable, Sendable {
        case finished(RedactedPayload)
        case gaveUp(RedactedPayload)
        case refused(VisionContainmentRefusal)
    }

    public let ending: Ending
    public let iterationsRun: Int
    public let actionsTaken: Int

    public var summary: String {
        switch ending {
        case .finished(let rationale):
            let text = rationale.maskedText ?? ""
            return text.isEmpty ? "Done." : text
        case .gaveUp(let rationale):
            let text = rationale.maskedText ?? ""
            return text.isEmpty
                ? "Sonny could not finish this from the screen."
                : "Sonny stopped: \(text)"
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
    /// Whether the per-app control question has been settled for this session — asked and allowed,
    /// or never needed. It flips exactly once, and it is what separates "ask" from "re-check".
    private var appControlSettled = false

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
            // Before every refusal check, so nothing below reads a stale answer, and once per
            // iteration rather than once per session — which is the difference a revoked grant
            // depends on (SONNY-202). The attention-pause branch below rewinds `iteration` and
            // `continue`s, which comes back through here and re-invalidates, so a session that
            // waited for a human re-reads rather than resuming on what it had.
            interaction.visionIterationWillBegin()


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
            // **The shell check, here, before anything downstream has looked at this capture**
            // (SONNY-139). Refusing at the redaction step means a window showing a shell never
            // reaches the vision provider and never produces an action — not the Safe-mode preview
            // below, not the prompt, not the send, not `perform`. It also runs on the *first*
            // capture, which happens before the per-app control approval a few lines down — so a
            // user is never asked to approve an app Sonny would refuse anyway.
            //
            // **That last clause was false for one branch, which is why it is now load-bearing
            // rather than descriptive.** Row J's first implementation raised the per-app question at
            // plan time, before any capture existed, and an unlisted terminal therefore arrived as
            // an ordinary "may Sonny control this app?" — the accidental-approval trap §4.3 exists
            // to close. The founder restored the ordering on 2026-08-21 and the gate below is where
            // it now lives.
            //
            // Re-asked every iteration rather than once per session, for the reason the deny-list
            // re-check above is: a screen changes under you, and a once-per-session answer is a
            // check that cannot notice a shell opening in the window it already cleared.
            //
            // The two refusals that reach a shell are ordered and both are kept.
            // `checkIterationStart` has already re-asked the static deny list at the top of this
            // iteration; this fires only for what a name list cannot reach.
            if payload.shellSurface.showsShell {
                return end(with: .screenShowsShell(payload.shellSurface), iteration: iteration)
            }
            // **The per-app control gate, here, and the position is the founder's decision**
            // (2026-08-21, §4.3). Below the deny list's per-iteration re-check and below the shell
            // check, so both refusals have already had their say; above the Safe-mode capture
            // preview and everything that sends, so nothing leaves the device for a session this
            // gate is about to end.
            //
            // The first time through it *asks*; every time after that it re-checks, which is what
            // makes a grant withdrawn mid-session take effect at the next iteration rather than at
            // the next launch. See `resolveAppControl` for why those are two behaviours and not one.
            if let refusal = try await resolveAppControl(interaction: interaction) {
                return end(with: refusal, iteration: iteration)
            }
            // **The one size, resolved once.** Everything downstream — what the user is shown, what
            // the model is told, what bounds a returned coordinate, and what that coordinate is
            // scaled by — has to agree about how big the picture is, and since SONNY-114 the answer
            // is the payload's, not the capture's: the egress ladder may have resampled to fit its
            // byte budget. The fallback is unreachable for an image payload (`redactCapture` sets
            // both dimensions whenever it sets bytes) and exists so this is not a throw; a payload
            // with no image is refused a few lines later by the model client anyway.
            let sentImage = SentImageSize(payload: payload)
                ?? SentImageSize(pixelWidth: capture.pixelWidth, pixelHeight: capture.pixelHeight)

            interaction.visionSessionDidProgress(
                VisionSessionProgress(
                    appDisplayName: target.displayName,
                    iteration: iteration,
                    maximumIterations: containment.limits.maximumIterations,
                    currentAction: "Looking at \(target.displayName)"
                )
            )

            let context = interaction.visionApprovalContext(targetBundleIdentifier: target.bundleIdentifier)
            if context.mode.asksBeforeEveryAction {
                let allowed = try await interaction.confirmVisionCaptureBeforeSending(
                    VisionCapturePreview(
                        appDisplayName: target.displayName,
                        windowTitle: capture.windowTitle,
                        redactedImageData: payload.redactedImageData,
                        pixelWidth: sentImage.pixelWidth,
                        pixelHeight: sentImage.pixelHeight,
                        redactionReport: payload.report,
                        iteration: iteration,
                        // The same value this iteration's own `visionSessionDidProgress` call
                        // carries, from the same expression, so the HUD and this panel cannot
                        // disagree about how long the session is. (Named rather than measured in
                        // lines: this said "three lines up" of a call eighteen lines up, and a
                        // distance drifts on the next edit while a symbol does not — PR #140
                        // review, F3.)
                        maximumIterations: containment.limits.maximumIterations
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
                imageWidth: sentImage.pixelWidth,
                imageHeight: sentImage.pixelHeight
            )
            log(.observe, "vision: iteration \(iteration) — sending a redacted capture of \(target.displayName)")
            let reply = try await environment.modelClient.decide(prompt: prompt, payload: payload)
            let decision = try VisionDecisionParser.decision(from: reply)
            log(.act, "vision: iteration \(iteration) — \(decision.actionDescription)")

            switch decision.kind {
            case .done:
                // **The model's closing rationale is redacted before it becomes the run summary.**
                // That summary reaches the *planner* provider on the next command within ten minutes
                // (via `recordPriorTaskContext` -> `plannerContextText`), and it is free text written
                // after reading the user's screen. F5 closed this class for the vision provider; this
                // is the same class arriving at a different one (PR #50 cycle-2, F13a).
                let finishedRationale = environment.redactionService.redactText(decision.rationale)
                record.sessionRedactionSummary += finishedRationale.report
                finishRecord(reasonCode: "completed", summary: finishedRationale.maskedText ?? "")
                return VisionSessionOutcome(
                    ending: .finished(finishedRationale),
                    iterationsRun: iteration,
                    actionsTaken: actionsTaken
                )
            case .stuck:
                let gaveUpRationale = environment.redactionService.redactText(decision.rationale)
                record.sessionRedactionSummary += gaveUpRationale.report
                finishRecord(reasonCode: "gave_up", summary: gaveUpRationale.maskedText ?? "")
                return VisionSessionOutcome(
                    ending: .gaveUp(gaveUpRationale),
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
                // **The delegated instruction is redacted before it reaches the planner.** It is
                // model-authored from a screen-derived prompt and goes straight to
                // `AgentRunner.prepare(command:)` — the same standard F5 set, at the same provider
                // the rationale reaches (PR #50 cycle-2, F13c). The rationale beside it is redacted
                // too: it comes from the same pen, and treating the two differently would leave a
                // reader working out which model-authored strings are safe.
                let redactedInstruction = environment.redactionService.redactText(instruction)
                let redactedRationale = environment.redactionService.redactText(decision.rationale)
                record.sessionRedactionSummary += redactedInstruction.report + redactedRationale.report
                let request = VisionDelegationRequest(
                    instruction: redactedInstruction,
                    rationale: redactedRationale,
                    appDisplayName: target.displayName
                )
                // Safe mode asks about the delegation itself; Normal and Power never do (founder,
                // 2026-08-14). What the delegated plan *does* is gated in every mode by the ordinary
                // plan-level gate inside `runVisionDelegation`.
                if interaction.visionApprovalContext(targetBundleIdentifier: target.bundleIdentifier).mode.asksBeforeEveryAction {
                    let allowed = try await interaction.confirmVisionDelegation(request)
                    guard allowed else {
                        history.append("iteration \(iteration): you declined to let Sonny's own tools do \u{201C}\(request.instructionText)\u{201D}. Continue from the screen instead, or report stuck.")
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
                    history.append("external result for iteration \(iteration): Sonny's own tools completed \u{201C}\(request.instructionText)\u{201D} — \(summary)")
                case .failed(let reason):
                    history.append("external result for iteration \(iteration): Sonny's own tools could not do \u{201C}\(request.instructionText)\u{201D} — \(reason). Try the on-screen route instead, or report stuck.")
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

            try await perform(decision, capture: capture, sentImage: sentImage, iteration: iteration)
            try await settle()
        }
    }

    // MARK: - The engine gate, per app

    /// The per-app control gate, run once per iteration immediately after the shell check.
    ///
    /// **Two behaviours, and the difference is which question is open.**
    ///
    /// - *Not yet settled* — the first capture has just cleared the screen check, so this is the
    ///   moment §4.3 names: ask, and mint the grant from the answer. An app that needs no question
    ///   settles silently.
    /// - *Already settled* — the user answered, or never had to. From here the standing is only
    ///   *re-checked*, and a withdrawal ends the session rather than re-prompting, because a
    ///   containment refusal never re-prompts and the user has just answered this exact question in
    ///   the other direction.
    ///
    /// Collapsing the two would break one or the other: re-asking every iteration would prompt on
    /// every screenshot, and asking only once would let a revocation sit unnoticed for the rest of
    /// the session.
    ///
    /// - Returns: the refusal that ends the session, or `nil` to carry on.
    private func resolveAppControl(
        interaction: any VisionSessionInteracting
    ) async throws -> VisionContainmentRefusal? {
        let state = interaction.visionAppControlState(targetBundleIdentifier: target.bundleIdentifier)
        guard !appControlSettled else {
            switch state {
            case .allowed:
                return nil
            case .needsApproval:
                return .appControlWithdrawn(app: target.displayName)
            case .unreadable(let description):
                log(.risk, "vision: could not read the allowed-apps list — \(description)")
                return .appControlUnreadable(app: target.displayName)
            }
        }

        switch state {
        case .allowed:
            appControlSettled = true
            return nil
        case .unreadable(let description):
            log(.risk, "vision: could not read the allowed-apps list — \(description)")
            return .appControlUnreadable(app: target.displayName)
        case .needsApproval:
            break
        }

        // **Through the one requirement function**, like every other gate in this loop. The context
        // carries the standing that produced `.needsApproval`, so the ask is the switch's answer
        // rather than a rule written here.
        let context = interaction.visionApprovalContext(targetBundleIdentifier: target.bundleIdentifier)
        let (assessment, requirement) = containment.appControlRequirement(context: context)
        guard requirement.requiresUserApproval else {
            // Unreachable by construction: `.needsApproval` floors the requirement at
            // `.explicitApproval` in every mode at every tier that can run, pinned cell by cell by
            // `everyAuthorityCellMatchesTheWrittenTable`. Fail closed rather than pass silently: a
            // session running on a grant nobody was asked for is the one outcome this gate exists to
            // prevent.
            //
            // **Its own case, because `appControlDeclined` would be a lie here** (PR #88 cycle 2,
            // F7). That sentence says "you did not allow it", and in this arm nobody was asked —
            // the requirement came back as something that raises no question, which is a defect in
            // the engine rather than an answer from the user. One true sentence per refusal is the
            // standard F3 set; borrowing a neighbour's is the failure it was set against.
            return .appControlUnresolvable(app: target.displayName)
        }
        if let refusal = await containment.checkApprovalPresentable() {
            return refusal
        }
        // The ordinary approval path, and the same method every mid-loop action approval uses — so
        // this renders on the floating widget *and* on `CommandCenterAttentionPanel`, with no
        // surface taught anything about it. That is §2.3's half of the design, kept intact inside
        // §4.3's ordering.
        //
        // **True of this gate all along, and false of every other user of that method until
        // SONNY-255** — which is worth stating here rather than quietly correcting, because the
        // difference is an accident of position and reads as nothing. This gate runs *before* the
        // iteration's first `visionSessionDidProgress`, so on the first capture there is no progress
        // for the widget's precedence to prefer and the question really did render. The per-action
        // gate below runs *after* it, and there the widget showed the HUD instead — for the whole
        // session, since the progress is cleared only when the session ends. Both render now.
        // **The `nil` arm is unreachable today, and is kept for the control that will reach it.**
        // The only Deny in the product routes through `cancelCurrentRun`, which resumes this
        // continuation with `nil` *and* cancels the task — and the cancellation check inside
        // `requestVisionActionApproval` throws before the `nil` is ever returned, so a decline
        // reaches the loop as `CancellationError` and the session ends with "Stopped." The founder's
        // standing note on SONNY-80 asks for a labelled "deny this step" control beside the stop,
        // and that lands as a second entry point resuming `nil` without cancelling — which is
        // exactly this arm. Same status as `authorize`'s `.approvalDeclined`, which has it for the
        // same reason. A mutation battery reports this as a survivor and is right to: with no such
        // control, deleting the arm changes no reachable behaviour (PR #88's fix round, M12).
        guard try await interaction.requestVisionActionApproval(
            RiskApprovalRequest(assessment: assessment, requirement: requirement)
        ) != nil else {
            return .appControlDeclined(app: target.displayName)
        }
        guard interaction.rememberAppControlGrant(
            bundleIdentifier: target.bundleIdentifier,
            displayName: target.displayName
        ) else {
            return .appControlNotRemembered(app: target.displayName)
        }
        appControlSettled = true
        return nil
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
        let context = interaction.visionApprovalContext(targetBundleIdentifier: target.bundleIdentifier)
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

    private func perform(
        _ decision: VisionDecision,
        capture: CapturedWindowImage,
        sentImage: SentImageSize,
        iteration: Int
    ) async throws {
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
            guard VisionPointResolver.isInsideImage(imagePoint, sentImageSize: sentImage) else {
                // The dimensions quoted back are the ones the model was given, not the capture's —
                // telling it that (900, 40) is outside a screenshot it was told was 1728 wide would
                // be an instruction it cannot act on.
                history.append("iteration \(iteration): \(decision.kind.rawValue) on \u{201C}\(decision.target)\u{201D} was skipped — the point (\(x), \(y)) is outside the \(sentImage.pixelWidth)x\(sentImage.pixelHeight) screenshot. Choose a point visibly inside the new screenshot.")
                // Journalled even though nothing was synthesized. A skipped action is a thing Sonny
                // decided and did not do, and a record showing only successes would read as a
                // cleaner run than the one that happened.
                journal(decision, imagePoint: imagePoint, observationAfter: "Skipped: the point was outside the captured window.")
                return
            }

            let outcome = VisionPointResolver.resolve(
                imagePoint: imagePoint,
                sentImageSize: sentImage,
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
                    do {
                        try await environment.synthesizer.click(atGlobalPoint: globalPoint)
                    } catch {
                        // **A stop landing inside the click still delivered one** (PR #50 review,
                        // F11). `ClickEventSequence` posts `leftMouseDown`, sleeps 80ms, and on
                        // cancellation posts `leftMouseUp` before rethrowing — so the target app
                        // received a complete down/up pair, which is a real click. Before this, the
                        // throw propagated past `journal(...)` and the record showed nothing: the run
                        // someone stopped mid-click was the one whose record was silently incomplete,
                        // and it is the run they would most want to read.
                        //
                        // Journalled with what actually happened, then rethrown so the stop still
                        // ends the session. `actionsTaken` is incremented for the same reason: an
                        // action that reached the machine counts, however it ended.
                        journal(
                            decision,
                            imagePoint: imagePoint,
                            observationAfter: "Clicked at screen point (\(Int(globalPoint.x)), \(Int(globalPoint.y))) — "
                                + "then the run was stopped mid-click. The mouse button was released."
                        )
                        actionsTaken += 1
                        throw error
                    }
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
