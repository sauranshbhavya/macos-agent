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
            interaction: interaction
        )
    }
}
