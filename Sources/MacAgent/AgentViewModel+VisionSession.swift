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

    /// One read of the grants file per iteration, taken here rather than three or four times below
    /// (SONNY-202). Everything the loop asks between this call and the next one gets this answer.
    ///
    /// Reading eagerly rather than clearing and letting the first asker fill it is what keeps the
    /// cache's lifetime statable: `loadApprovedAppsForGate` never writes it, so the only two moments
    /// it changes are here and the run teardown, and neither is inside an iteration.
    func visionIterationWillBegin() {
        cacheApprovedAppsForThisVisionIteration()
    }

    func visionApprovalContext(targetBundleIdentifier: String) -> ApprovalContext {
        approvalContext(visionTarget: targetBundleIdentifier)
    }

    /// The per-app gate's answer for this session's target, re-asked after every capture.
    ///
    /// Reads through the same loader `approvalContext` uses, so the standing on the context and the
    /// state the loop acts on come from one read of one file and cannot disagree. The difference is
    /// only what each does with a load failure: a requirement fails closed to an ask, a session
    /// cannot, and the third case is what carries that distinction (PR #88, F3).
    func visionAppControlState(targetBundleIdentifier: String) -> VisionAppControlState {
        let loaded = loadApprovedAppsForGate()
        if let failure = loaded.failure {
            return .unreadable(failure)
        }
        switch AppControlResolver.standing(
            mode: interactionMode,
            targetBundleIdentifier: targetBundleIdentifier,
            starterList: AppControlStarterList.bundleIdentifiers,
            approvedApps: loaded.apps
        ) {
        case .allowed:
            return .allowed
        case .needsApproval:
            return .needsApproval
        case .notApplicable:
            // Unreachable: the resolver only answers `.notApplicable` for a missing or blank
            // identifier, and a live session's target is neither. Fails closed to the ask rather
            // than to `.allowed`, so a future caller that does pass a blank one is asked about it
            // instead of granted it silently.
            return .needsApproval
        }
    }

    /// The session's journal id, recorded as soon as it starts so the task-history row this run
    /// produces can link to it — including when the run is stopped, refused, or fails, which are
    /// exactly the runs someone most wants to be able to read afterwards.
    func visionSessionDidStart(id: String) {
        activeVisionSessionID = id
    }

    func visionSessionDidProgress(_ progress: VisionSessionProgress) {
        let wasLive = isVisionSessionLive
        visionSessionProgress = progress
        // Registered on the first progress report of a session rather than at dispatch, so the
        // window is exactly "Sonny is actually driving" — a session that failed at resolve or was
        // refused at the gate never takes the combination at all.
        if !wasLive {
            registerEmergencyStopHotKey()
        }
    }

    /// Take `Ctrl-Opt-Esc` for the duration of the session.
    ///
    /// A failure here is recorded and swallowed rather than surfaced: the hotkey is one of four
    /// ways to stop a session, and refusing to run because a convenience shortcut was already taken
    /// by another app would be a worse product than running without it.
    ///
    /// **The other three are the Stop controls, enumerated rather than described, because this count
    /// has been wrong once already** (PR #132 review, F5). It said three ways and named "the HUD's
    /// Stop and the widget's existing cancel" — a set that stopped being the set when SONNY-255 gave
    /// the widget's approval panel its own Stop and PR #132's F1 gave Command Center's one, and whose
    /// second member is now hidden during a session precisely because it ended one while reading as a
    /// per-step decline. The population is one grep, and it is the whole of it because every door is
    /// the same call: `git grep -n emergencyStopVisionSession'()' -- Sources | grep -v 'func '` → 4
    /// lines, of which one is the closure below and three are controls —
    /// `WidgetControllingPanel`'s Stop and `WidgetPermissionPanel`'s in `FloatingWidgetView`, and
    /// `CommandCenterAttentionPanel`'s in `CommandCenterView`. Hotkey plus three controls is the
    /// four. Every one ends in `cancelCurrentRun`, which is the point of the paragraph below.
    func registerEmergencyStopHotKey() {
        guard visionEmergencyStopHotKey == nil else {
            return
        }
        do {
            visionEmergencyStopHotKey = try visionEmergencyStopHotKeyFactory { [weak self] in
                self?.emergencyStopVisionSession()
            }
            logStore.append(.observe, "vision: \(EmergencyStopHotKey.displayName) stops this session")
        } catch {
            logStore.append(
                .observe,
                "vision: could not register \(EmergencyStopHotKey.displayName) - \(error.localizedDescription)"
            )
        }
    }

    /// Give the combination back. Called from the one place a session can end.
    func releaseEmergencyStopHotKey() {
        visionEmergencyStopHotKey = nil
    }

    // MARK: - The HUD's own controls

    /// The user pressed Pause on the HUD.
    ///
    /// Routed through the attention monitor rather than a separate mechanism, so a user-initiated
    /// pause reaches the loop by exactly the path a locked screen does — the loop freezes at the top
    /// of the next iteration, captures nothing, synthesizes nothing, and waits for an explicit
    /// resume. One paused state, not two that have to agree (SONNY-95: "shares the session-attention
    /// pause machinery").
    func pauseVisionSession() {
        visionUserPauseMonitor?.pause()
    }

    /// The emergency stop, from the hotkey or from any of the three Stop controls that call it.
    ///
    /// **Three, and this line named one of them until PR #132's review (F5).** They are the HUD's
    /// Stop, the widget's approval panel's Stop (SONNY-255, which is the panel that outranks the HUD
    /// while a question is parked), and Command Center's approval panel's Stop (PR #132's F1). The
    /// last two exist because on both surfaces the refusal that was there before ended the whole
    /// session while reading as a per-step decline — an icon-only cross in the widget, a button
    /// labelled "Deny" in Command Center — and the fix on each was to give the call a word that
    /// says what it does rather than to change what it does.
    ///
    /// **Deliberately the same call as every other stop.** §13.5's invariant is one implementation
    /// of "control was lost, for any reason", and a bespoke emergency path would be the second stop
    /// path — which is always the one that turns out not to release the mouse button. What
    /// `cancelCurrentRun` gives this for free: the parked-question branches resume before
    /// cancelling so there is exactly one resume, `Task.checkCancellation` turns it into the same
    /// `CancellationError` a cancelled clarification throws, and `ClickEventSequence` posts
    /// `leftMouseUp` before propagating so the button is never left down.
    func emergencyStopVisionSession() {
        guard isVisionSessionLive else {
            return
        }
        logStore.append(.summarize, "vision: user_stopped - emergency stop")
        cancelCurrentRun()
    }

    /// Whether a screen-control session is live in any of its states — running, paused, or holding
    /// one of its three questions.
    ///
    /// The hotkey's registration window and the HUD's visibility both read this, so "live" has one
    /// definition rather than two that drift.
    var isVisionSessionLive: Bool {
        visionSessionProgress != nil
            || visionSessionPause != nil
            || visionCapturePreview != nil
            || visionDelegationRequest != nil
    }

    /// A mid-loop approval, on the same surface every other approval uses.
    ///
    /// Writes the real `approvalRequest`, so the floating widget's permission card and Command
    /// Center's attention panel both render it. A vision approval that looked different from every
    /// other approval would be a second approval surface, and the user learns one.
    ///
    /// **That sentence was an intention rather than a description until SONNY-255, and the half that
    /// was false is worth keeping written down.** Command Center rendered it from the start. The
    /// widget did not, for the whole life of every session: `FloatingWidgetView.state` is an ordered
    /// chain and `.controlling` sat above `.permission`, while `visionSessionProgress` is written at
    /// the top of each iteration and cleared only at session end — so from iteration 1 the widget
    /// showed the HUD, which carries no question, and the run waited on an answer the user could
    /// give only by finding the other surface. This comment claimed the opposite and was the reason
    /// nobody re-derived it. `.permission` now outranks `.controlling`.
    ///
    /// **"With no special case" is what the fix had to give up, and only in one direction.** The
    /// request, the method and both answering entry points are still exactly the ordinary ones — no
    /// surface is taught what a vision approval is. What the widget's panel does read is
    /// `visionSessionProgress`, so that a question raised inside a session still says which app is
    /// being controlled and still offers the Stop the HUD it outranks was carrying.
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
        // Cleared on both answers. On a resume it is what lets the loop proceed; on an end it stops
        // a stale flag outliving the session that set it.
        visionUserPauseMonitor?.clearPause()
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
            if let resolution = makeInstantCommandResolver().resolve(command: request.instructionText) {
                switch resolution {
                case .plan(let localPlan), .clarify(let localPlan):
                    prepared = try runner.prepare(plan: localPlan, source: .instantResolver)
                }
            } else {
                prepared = try await runner.prepare(command: request.instructionText)
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
            // `nil`, like every other plan gate: a delegated plan is an ordinary plan gated the
            // ordinary way, and §4.3 puts the per-app question inside a session rather than in front
            // of one. A delegated plan that itself controls an app gets asked about at *its* own
            // session's first capture, which is the same rule and the same place.
            let context = approvalContext(visionTarget: nil)
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
                    if let outputLocationFailure = runner.lastOutputLocationFailure {
                        recordLocalStorageWriteFailure(outputLocationFailure)
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
    /// **It no longer returns `nil`, and the signature says so** (SONNY-131). It used to be
    /// `Optional` for exactly one reason — `OpenCodeVisionModelClient.init` threw when
    /// `OPENCODE_API_KEY` was unset, and a build with no key had no vision. There is no key to be
    /// missing now: the credential is the gateway's, and a session started with no signed-in account
    /// fails at the *request* with a sentence the user can act on rather than at construction with a
    /// capability that silently is not there. That is the same collapse SONNY-130 made for
    /// `TavilySearchProvider`, for the same reason and with the same consequence — `visionUnavailable`
    /// stops being a state this app can be in, so a user who asks Sonny to control an app always gets
    /// either a session or a sentence.
    ///
    /// **`backendClient` and `taskContext` are parameters with no defaults**, so a call site that has
    /// not decided cannot compile. A defaulted client would be a second construction of the shared
    /// one, defeating the single-flight refresh guard §3.3 needs; a defaulted `taskContext` would be
    /// a defaulted `retention`, which is a privacy answer nobody chose.
    static func makeVisionEnvironment(
        interaction: any VisionSessionInteracting,
        backendClient: SonnyBackendClient,
        taskContext: BackendTaskContext,
        usageRecorder: any TaskUsageRecording,
        userPauseMonitor: UserPausableAttentionMonitor? = nil,
        journalStore: VisionSessionJournalStore? = nil
    ) -> VisionSessionEnvironment {
        return VisionSessionEnvironment(
            captureService: ScreenCaptureService(),
            redactionService: LocalRedactionService(),
            synthesizer: SystemScreenActionSynthesizer(),
            modelClient: SonnyVisionModelClient(
                client: backendClient,
                taskContext: taskContext,
                usageRecorder: usageRecorder
            ),
            // The real monitor, not the always-attended default. SONNY-94's whole point is that a
            // session stops when the user does, and `AlwaysAttendedMonitor` is correct only for a
            // build with no way to ask the OS — which this is not.
            attentionMonitor: userPauseMonitor ?? UserPausableAttentionMonitor(base: SystemSessionAttentionMonitor()),
            journalStore: journalStore,
            interaction: interaction
        )
    }
}
