import Foundation
import MacAgentCore

/// The product half of a vision session: how one starts, and the two questions it can ask.
///
/// Split into its own file because `AgentViewModel` is already 2,600 lines and this is a coherent
/// unit — not because it is separate: it is an extension on the same class, reading and writing the
/// same published state, exactly as `.claude/rules/macagent-ui-conventions.md` requires ("New
/// published state gets added to that one instance. Never build a second, independently-coded state
/// path").
extension AgentViewModel: VisionSessionInteracting {
    // MARK: - Starting a session

    /// Build and dispatch a vision session for `goal` in `appName`.
    ///
    /// **Nothing about this is a shortcut past anything.** It builds a plan and hands it to
    /// `start(prebuiltPlan:)`, which is SONNY-64's seam — so the run rejoins the ordinary path at
    /// `prepare`, and the assessment, the gate, the approval prompt, the events and the history row
    /// are the ones an equivalent typed command would have produced. The only thing supplying a plan
    /// changes is who wrote it, which is why the origin is its own `PreparedPlanSource` case rather
    /// than a borrowed one.
    func startVisionSession(goal: String, appName: String, origin: TaskOrigin = .widget) {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty, !trimmedApp.isEmpty else {
            setError("Sonny needs both a goal and an app to control.")
            return
        }

        let plan = AgentPlan(
            summary: "Control \(trimmedApp): \(trimmedGoal)",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "vision-1",
                    operation: .visionSession,
                    description: "Control \(trimmedApp) to \(trimmedGoal)",
                    appName: trimmedApp,
                    // The pin fields are deliberately absent. `VisionSessionCapabilityAdapter`
                    // writes them in the resolve phase, from Launch Services, exactly once — a
                    // caller pre-filling them here would be a second source of the identity the
                    // terminal ban judges.
                    visionGoal: trimmedGoal
                )
            ]
        )
        command = "Control \(trimmedApp): \(trimmedGoal)"
        start(origin: origin, prebuiltPlan: plan, prebuiltPlanSource: .visionSession)
    }

    // MARK: - VisionSessionInteracting

    func visionApprovalContext() -> ApprovalContext {
        approvalContext()
    }

    func visionSessionDidProgress(_ progress: VisionSessionProgress) {
        visionSessionProgress = progress
    }

    /// A mid-loop approval, on the same surface every other approval uses.
    ///
    /// Writes the real `approvalRequest`, so the floating widget's permission card and Command
    /// Center's attention panel both render it with no special case — which is the point. A vision
    /// approval that looked different from every other approval would be a second approval surface,
    /// and the user learns one.
    ///
    /// The cancellation handler mirrors `requestClarification`'s exactly. It is load-bearing rather
    /// than defensive: the guard is what makes a cancellation racing a real answer a no-op instead of
    /// a double resume.
    func requestVisionActionApproval(_ request: RiskApprovalRequest) async throws -> RiskApprovalDecision? {
        approvalRequest = request
        finalSummary = "Sonny needs your approval before this step."
        logStore.append(
            .confirm,
            "vision: \(request.assessment.effectiveTier.displayName) approval needed — \(request.approvalCopy.actionDescription)"
        )

        let decision = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                visionApprovalContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                guard let continuation = self.visionApprovalContinuation else { return }
                self.visionApprovalContinuation = nil
                self.approvalRequest = nil
                continuation.resume(returning: nil)
            }
        }

        // **After the await, not before.** A cancellation resumes the continuation with `nil`, and
        // `nil` already means "the user declined this action" on the line below. Without this check
        // a stopped run would be indistinguishable from a declined action, and the loop would end
        // with the wrong sentence — "You declined: click Send" for a user who pressed stop. This
        // converts it into the same `CancellationError` a cancelled clarification throws, so both
        // produce the same honest "Stopped." (Inherited from the experiment's Option A fix, where
        // the same two meanings on one control was the whole defect.)
        try Task.checkCancellation()
        return decision
    }

    /// Safe mode's pre-send capture preview.
    ///
    /// Founder decision 2 (2026-08-14): Safe mode *shows each capture before it is sent*. Two
    /// questions per iteration in Safe mode, and they are genuinely two moments — this one happens
    /// before the model has seen anything, so it cannot name the action it will produce.
    func confirmVisionCaptureBeforeSending(_ preview: VisionCapturePreview) async throws -> Bool {
        visionCapturePreview = preview
        finalSummary = "Sonny wants to send this screenshot of \(preview.appDisplayName)."

        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                visionCaptureContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                guard let continuation = self.visionCaptureContinuation else { return }
                self.visionCaptureContinuation = nil
                self.visionCapturePreview = nil
                continuation.resume(returning: false)
            }
        }

        try Task.checkCancellation()
        return allowed
    }

    /// The session paused because the user stopped being at the Mac.
    ///
    /// **Nothing resolves this but the user.** No timer, no notification of the screen unlocking, no
    /// "they moved the mouse so they must be back" — E7's requirement is a *present* human, and
    /// presence is something a person asserts rather than something an idle timer infers. A session
    /// that resumed itself the moment a Mac woke would be a program moving the cursor of someone who
    /// has not yet looked at the screen.
    func awaitVisionResume(_ pause: VisionSessionPause) async throws -> Bool {
        visionSessionPause = pause
        finalSummary = "Sonny paused — \(pause.reason.userFacingReason)."

        let resumed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                visionResumeContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                guard let continuation = self.visionResumeContinuation else { return }
                self.visionResumeContinuation = nil
                self.visionSessionPause = nil
                continuation.resume(returning: false)
            }
        }

        try Task.checkCancellation()
        return resumed
    }

    /// The user answered the pause. `true` resumes; `false` ends the session.
    func resolveVisionPause(resuming: Bool) {
        guard let continuation = visionResumeContinuation else { return }
        visionResumeContinuation = nil
        visionSessionPause = nil
        continuation.resume(returning: resuming)
    }

    // MARK: - Delegation

    /// Safe mode's ask before a delegation fires.
    ///
    /// Founder decision 4 (2026-08-14): Safe mode always asks about the delegation itself; Normal
    /// and Power never do. Rendered on the clarification surface rather than the approval one, and
    /// deliberately: this is not a risk question — the risk question is asked, in every mode, about
    /// whatever the delegated plan turns out to *do*. This one asks whether Sonny should use its own
    /// tools at all instead of clicking, and a Safe-mode user answering it is choosing a method.
    func confirmVisionDelegation(_ request: VisionDelegationRequest) async throws -> Bool {
        visionDelegationRequest = request
        finalSummary = "Sonny wants to use its own tools for one step."

        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                visionDelegationContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                guard let continuation = self.visionDelegationContinuation else { return }
                self.visionDelegationContinuation = nil
                self.visionDelegationRequest = nil
                continuation.resume(returning: false)
            }
        }

        // Same placement and same reason as the other two parked questions: a cancellation resumes
        // with `false`, which is also what declining looks like, and only this turns a stopped run
        // into a stopped run rather than a declined delegation the loop would carry on from.
        try Task.checkCancellation()
        return allowed
    }

    /// The user answered the Safe-mode delegation question.
    func resolveVisionDelegation(allowing allowed: Bool) {
        guard let continuation = visionDelegationContinuation else { return }
        visionDelegationContinuation = nil
        visionDelegationRequest = nil
        continuation.resume(returning: allowed)
    }

    /// Run a delegated instruction through the ordinary engine path.
    ///
    /// **This is the whole of "engine-routed, never around it" for delegation.** The instruction is
    /// planned by the real planner, prepared by the real runner, assessed by the real executor and
    /// gated by `RiskApprovalPolicy.requirement(for:context:)` — so a delegated "delete my drafts"
    /// meets exactly the approval a typed "delete my drafts" would. The founder's decision removed a
    /// prompt about *delegating*, never the gate on what the delegation does.
    ///
    /// **No recursion, checked rather than assumed.** A delegated plan carrying a vision step is
    /// refused before it is prepared. Without that, a model could delegate its way into a second
    /// session inside the first, each with its own iteration cap, and the cap would stop bounding
    /// anything.
    func runVisionDelegation(_ request: VisionDelegationRequest) async throws -> VisionDelegationResult {
        do {
            // The same executor factory and the same planner registry the ordinary path uses
            // (SONNY-85) — a delegated instruction is planned by whatever would have planned the
            // user's own sentence, and runs through the executor a typed command would.
            let runner = try makeDelegationRunner()

            // **The instant resolver first, exactly as a typed command gets it.** `performStart`
            // tries it before reaching for a planner, and `AgentRunner.prepare(command:)` does not —
            // so without this line a delegated "2 + 2" would take a model round trip that the same
            // words typed by the user would not. "Planned by whatever would have planned the user's
            // own sentence" has to include the case where nothing plans it at all.
            let prepared: PreparedAgentRun
            if let resolution = makeInstantCommandResolver().resolve(command: request.instruction) {
                switch resolution {
                case .plan(let localPlan), .clarify(let localPlan):
                    prepared = try runner.prepare(plan: localPlan, source: .instantResolver)
                }
            } else {
                prepared = try await runner.prepare(command: request.instruction)
            }

            if prepared.plan.steps.contains(where: { $0.operation == AgentOperation.visionSession }) {
                return .failed(
                    reason: "Sonny does not start a second screen-control session from inside one."
                )
            }
            if let question = prepared.clarificationQuestion {
                // A clarification the vision model cannot answer. Handing the question back as a
                // result rather than putting it to the user keeps one question on screen at a time,
                // and the model is the one that chose this instruction — it can pick a better one or
                // go back to the screen.
                return .failed(reason: "Sonny's tools need more detail: \(question)")
            }

            let scope = activeTaskScope
            let context = approvalContext()
            let request0 = try runner.approvalRequest(
                for: prepared,
                logAssessment: true,
                scope: scope,
                context: context
            )

            var decision: RiskApprovalDecision = .notRequested
            switch request0.requirement {
            case .autoRun:
                break
            case .lightweightConfirmation, .explicitApproval:
                guard let approved = try await requestVisionActionApproval(request0) else {
                    return .failed(reason: "You declined that.")
                }
                decision = approved
            case .previewOnly:
                return .failed(reason: "That is limited to preview under the current approval policy.")
            case .refuse:
                return .failed(reason: "Sonny refused that under the current approval policy.")
            }

            // The stale-approval re-arm, on this path too: `execute` re-assesses fresh and throws
            // when the world drifted, and the user answers the *new* request rather than the old one
            // being silently spent on it.
            while true {
                do {
                    let result = try await runner.execute(
                        prepared,
                        approvalDecision: decision,
                        confirmationMessage: "Approved a step Sonny's tools ran during screen control",
                        logRiskAssessment: true,
                        scope: scope,
                        context: context
                    )
                    refreshSavedItems()
                    if let artifactFailure = runner.lastRecentArtifactFailure {
                        recordLocalStorageWriteFailure(artifactFailure)
                    }
                    return .completed(summary: result.summary)
                } catch RiskApprovalError.approvalRequired(let refreshed) {
                    guard let approved = try await requestVisionActionApproval(refreshed) else {
                        return .failed(reason: "You declined that after its risk changed.")
                    }
                    decision = approved
                }
            }
        } catch let error where isCancellationError(error) {
            // The one outcome that is not information for the model: the user stopped the run.
            throw error
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    // MARK: - The user's answers

    /// The user allowed the pending vision action. Called by the same control that approves any
    /// other run.
    func resolveVisionApproval(approving request: RiskApprovalRequest) {
        guard let continuation = visionApprovalContinuation else { return }
        visionApprovalContinuation = nil
        approvalRequest = nil
        markFirstApprovalCompleted()
        // `answering:` rather than a bare tier, for the same reason `performApproval` uses it: the
        // recorded consent carries the escalation reasons this exact prompt showed, so a later
        // action in the same session with a *different* tier-3 reason re-prompts instead of riding
        // this one (SONNY-62's comparison, applied mid-loop).
        continuation.resume(returning: .approved(answering: request))
    }

    /// The user answered the Safe-mode capture preview.
    func resolveVisionCapturePreview(allowing allowed: Bool) {
        guard let continuation = visionCaptureContinuation else { return }
        visionCaptureContinuation = nil
        visionCapturePreview = nil
        continuation.resume(returning: allowed)
    }

    /// The vision environment this view model hands the executor.
    ///
    /// **The live recognizer, by construction and on purpose.** `LocalRedactionService()`'s
    /// `textRecognizer` parameter defaults to `VisionImageTextRecognizer`, and this call site takes
    /// that default deliberately rather than passing anything. A recognizer that *succeeds* while
    /// finding nothing produces an empty report over the original pixels with nothing thrown — a
    /// silent unredacted send — and that is exactly what a stub looks like. Recorded on SONNY-91 by
    /// PR #49's review so row I would be told rather than discover it; this comment is where the
    /// telling lands.
    static func makeVisionEnvironment(
        interaction: any VisionSessionInteracting,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VisionSessionEnvironment? {
        guard let modelClient = try? OpenCodeVisionModelClient(environment: environment) else {
            return nil
        }
        return VisionSessionEnvironment(
            captureService: ScreenCaptureService(),
            redactionService: LocalRedactionService(),
            synthesizer: SystemScreenActionSynthesizer(),
            modelClient: modelClient,
            // The real monitor, not the always-attended default. SONNY-94's whole point is that a
            // session stops when the user does, and `AlwaysAttendedMonitor` is correct only for a
            // build with no way to ask the OS — which this is not.
            attentionMonitor: SystemSessionAttentionMonitor(),
            interaction: interaction
        )
    }
}
