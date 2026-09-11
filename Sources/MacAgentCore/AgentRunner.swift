import Foundation

/// How a prepared run's plan came to exist — and, because of that, how much of it any part of the
/// app is entitled to trust.
///
/// **This is the origin signal SONNY-13's row C asked for, and its trustworthiness is structural
/// rather than promised.** There is no decoding path that reaches it: `AgentPlan` and `AgentStep`
/// are the only things a planner response is decoded into, neither carries a source field, and the
/// value is stamped by `AgentRunner.prepare` *after* decoding has already finished — so no planner
/// output, however adversarial, can name its own origin. `prepare(command:)` hardcodes `.planner`
/// for exactly that reason: the one entry point a model's text can reach cannot pass a source at
/// all. Everything else is set by a Swift call site inside this app, which is the same shape
/// `AgentViewModel.start(fromComposer:)` already uses for the pending-arm rule.
///
/// **Nothing reads this to weaken a consent, and nothing may.** Row C's origin grant briefly did —
/// superseded by the founder's consequence rule (2026-08-13), which gates on what an action *does*
/// (destructive / affects-others / advisory), never on how its plan came to exist. What survives
/// reading this value: dispatch (which planner path to take), the plan log line, the pending-arm
/// rule, and the view model's confirmation copy. (SONNY-281 briefly added a fifth reader — which
/// door a clarification answer goes through — and PR #118's review removed it: the Continue door
/// replays a paused plan as `.resumedTask`, so that decision reads the question instead.)
public enum PreparedPlanSource: String, Equatable, Sendable {
    case planner
    case instantResolver = "instant_resolver"
    /// The user's own interaction constructed this exact plan, field by field, and no natural
    /// language was interpreted by anything on the way. The workspace detail sheet's Add and Remove
    /// affordances are the first callers; the vision-envelope consent §B1 sketches is the next
    /// planned one.
    ///
    /// Named for the mechanism rather than for one surface deliberately. The integration plan makes
    /// this dispatch path *shared* plumbing, so a case called `workspaceSheet` would need renaming
    /// the moment the second caller lands — and a rename of a trust signal is exactly the change
    /// nobody wants to be reviewing under time pressure. A surface that later needs to be told apart
    /// from this one adds its own case; it does not overload this one.
    case directUserAction = "direct_user_action"
    /// A vision session: the user asked Sonny to act inside an app it has no adapter for, and
    /// `AgentViewModel` built the one-step plan that starts it (row I, SONNY-92).
    ///
    /// **Its own case rather than `.directUserAction`, exactly as that case's own comment
    /// instructs.** The two are genuinely different claims. `.directUserAction` says a plan was
    /// constructed field by field with no natural language interpreted on the way; a vision session
    /// carries the user's goal as free text and hands it to a model that decides what to do with it.
    /// SONNY-81's amendment forbade overloading on a second ground that has since dissolved, and
    /// the record is worth keeping straight: at the time, `.directUserAction` was on row C's
    /// relaxation allowlist, so borrowing it would have handed a vision session an origin that could
    /// weaken a consent. The founder's consequence rule (2026-08-13) deleted relaxation entirely —
    /// nothing in `Sources/` reads an origin to weaken anything anymore, so "never
    /// relaxation-eligible" is true of a vision session vacuously rather than by a rule. The case
    /// still exists on its own merits, above, and the amendment's instinct was right for the
    /// mechanism that was there.
    case visionSession = "vision_session"
    /// What is left of a plan an earlier run began and did not finish, dispatched because the user
    /// pressed Continue on the widget's offer (row 13, SONNY-210).
    ///
    /// **Its own case rather than `.directUserAction`, exactly as that case instructs.** The claim
    /// `.directUserAction` makes is that a plan was constructed field by field with no natural
    /// language interpreted on the way; these steps came from wherever the original run's did, which
    /// for most tasks is a planner reading a sentence. Borrowing it would be a false statement about
    /// how the plan came to exist, which is the one thing this enum is for.
    ///
    /// **And it is not the original source replayed**, which was the other option. The stored record
    /// could have carried the source it was prepared with, but then a *decode* would produce a value
    /// of this type — and the reason this enum is trustworthy is that no decoding path reaches it.
    /// Nothing weakens a consent from an origin today, so replaying one would not be a live hole;
    /// keeping the structural property intact costs one case, and a hole that has to stay closed by
    /// convention is the kind this repository has already paid for.
    case resumedTask = "resumed_task"

    var planLogMessage: String {
        switch self {
        case .planner:
            return "Sending command to planner"
        case .instantResolver:
            return "Resolved command locally"
        case .directUserAction:
            return "Using the plan this screen built"
        case .visionSession:
            return "Starting a screen-control session"
        case .resumedTask:
            return "Continuing what was left of an earlier task"
        }
    }
}

@MainActor
public final class AgentRunner {
    private let plannerProvider: () throws -> any Planning
    private let executor: AgentActionExecutor
    private let logStore: AgentLogStore
    private let approvalPolicy: RiskApprovalPolicy
    private let recentArtifactStore: RecentArtifactStore?
    /// Where this run may record the folders it wrote into, or `nil` when it may not (SONNY-209).
    ///
    /// **Its own parameter rather than a flag, and its own parameter rather than riding on
    /// `recentArtifactStore`.** The withhold-the-store seam is what makes a memory switch impossible
    /// to forget at the writing site — `AgentRunner` treats `nil` as "record nothing", exactly as it
    /// already does for artifacts and as `AgentViewModel` does for the vision journal. Separate from
    /// the artifact store because the two are separate Memory rows with separate switches: folding
    /// them into one optional would make turning off "Recent artifacts" silently stop Sonny learning
    /// where work goes, which is a switch doing something its label does not say.
    private let outputLocationStore: OutputLocationStore?

    public init(
        planner: any Planning,
        executor: AgentActionExecutor,
        logStore: AgentLogStore = AgentLogStore(),
        approvalPolicy: RiskApprovalPolicy = .default,
        recentArtifactStore: RecentArtifactStore? = nil,
        outputLocationStore: OutputLocationStore? = nil
    ) {
        self.plannerProvider = { planner }
        self.executor = executor
        self.logStore = logStore
        self.approvalPolicy = approvalPolicy
        self.recentArtifactStore = recentArtifactStore
        self.outputLocationStore = outputLocationStore
    }

    /// The second door, and it takes the same stores for the same reason: a store threaded through
    /// one initializer and defaulted away in the other is a seam that is honoured on whichever path
    /// somebody happened to look at (SONNY-209).
    public init(
        plannerProvider: @escaping () throws -> any Planning,
        executor: AgentActionExecutor,
        logStore: AgentLogStore = AgentLogStore(),
        approvalPolicy: RiskApprovalPolicy = .default,
        recentArtifactStore: RecentArtifactStore? = nil,
        outputLocationStore: OutputLocationStore? = nil
    ) {
        self.plannerProvider = plannerProvider
        self.executor = executor
        self.logStore = logStore
        self.approvalPolicy = approvalPolicy
        self.recentArtifactStore = recentArtifactStore
        self.outputLocationStore = outputLocationStore
    }

    public func prepare(
        command: String,
        priorTaskContext: PriorTaskContext? = nil
    ) async throws -> PreparedAgentRun {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentExecutionError.emptyCommand
        }

        logStore.reset()
        logStore.append(.plan, PreparedPlanSource.planner.planLogMessage)
        if priorTaskContext != nil {
            logStore.append(.observe, "Short-lived prior task context available to planner")
        }
        let planner = try plannerProvider()
        let plan = try await planner.plan(command: trimmed, priorTaskContext: priorTaskContext)
        // `.planner`, hardcoded, with no parameter for a caller to override. This is the one entry
        // point whose plan is authored by a model, so it is the one entry point that must never be
        // able to claim a stronger origin than that.
        return try prepareResolvedPlan(plan, source: .planner)
    }

    public func prepare(
        plan: AgentPlan,
        source: PreparedPlanSource = .instantResolver
    ) throws -> PreparedAgentRun {
        logStore.reset()
        logStore.append(.plan, source.planLogMessage)
        return try prepareResolvedPlan(plan, source: source)
    }

    /// The single funnel both entry points share, which is what makes "the pre-built path and the
    /// typed path are the same path" a structural fact rather than two implementations kept in
    /// step: everything after this line — `executor.prepare`, `approvalRequest`'s `assessRisk`, the
    /// gate in `execute`, execution itself — never learns how the plan was authored.
    private func prepareResolvedPlan(_ plan: AgentPlan, source: PreparedPlanSource) throws -> PreparedAgentRun {
        logStore.append(.observe, "Received plan: \(plan.summary)")
        logStore.append(.validate, "Validating whitelist and supported operations")
        var preparedRun: PreparedAgentRun
        do {
            preparedRun = try executor.prepare(plan: plan)
        } catch AgentExecutionError.unsupported(let reason) {
            // **The planner's reason stays in the act log, as SONNY-447 requires** (PR #232's fresh
            // review, F1): the user reads `AgentExecutionError.unsupported`'s own sentence on every
            // surface, and this line is what lets a trace say why. Here rather than in the executor
            // because this is the one funnel both `prepare` doors share, so a refusal typed or
            // pre-built lands in the same log once. The unified-log line beside the throw is the
            // support session's copy, redacted as private; this one is the run's own record.
            logStore.append(.observe, "The planner refused this request: \(reason)")
            throw AgentExecutionError.unsupported(reason)
        }
        preparedRun.source = source
        logStore.append(.preview, "Prepared \(preparedRun.previews.count) preview item(s)")
        return preparedRun
    }

    /// `scope` is non-defaulted here for the same reason it is on
    /// `AgentActionExecutor.assessRisk(plan:scope:)`, and the reason is sharper at this layer than
    /// at that one.
    ///
    /// **There are two entry points that independently assess, and the one that logs in production
    /// is the easier one to miss.** `execute` calls `approvalRequest` again internally, so threading
    /// a real scope at the `approvalRequest` call site while leaving `execute` defaulted would
    /// produce a run that prompts the user with a tier-3 scope escalation, takes their approval, and
    /// then re-assesses `.unscoped` — the gate still passes, because the approved tier exceeds the
    /// now-lower effective tier, while the `risk.assessed`/`risk.escalated` trace records an
    /// assessment with no scope escalation in it at all. Spec §11.1A's "escalation is its own logged
    /// trace event" would hold in the tests and fail in the app: green tests, lying log.
    ///
    /// A default is what makes that failure silent, so there isn't one. SONNY-38 has to write a
    /// scope at every site or the compiler stops it. Nothing about the gating below changes — scope
    /// changes the assessment, never the gate.
    ///
    /// `context` is non-defaulted for the identical reason (SONNY-97): `execute` calls this again
    /// internally, so a context threaded here and defaulted there would prompt under one
    /// requirement and execute under another.
    ///
    /// And note where it lands — the *requirement*, never the assessment. **`assessRisk` takes no
    /// `ApprovalContext` and must never grow one:** `effectiveTier` remains a pure function of the
    /// plan and the scope, and the requirement is that tier plus the escalations' consequence
    /// classes plus whatever the context says (the mode, and row J's per-app standing).
    ///
    /// **This sentence was briefly untrue and is worth the paragraph** (PR #88's fix round). Row J's
    /// first implementation forwarded `context.appControl` into `assessRisk` so the vision adapter
    /// could word an escalation reason with it — the *sentence* saying that allowing an app is
    /// remembered. The founder then decided (2026-08-21) that the per-app question is asked after
    /// the session's first capture rather than here, because only a capture can reveal a shell in a
    /// window whose app no name list refuses. With the question gone from this gate, the sentence
    /// belongs with it: `VisionSessionContainment.appControlRequirement(context:)` builds that
    /// request inside the loop, and the standing reaches an assessment nowhere. The forwarding is
    /// removed rather than left dormant — a field nothing reads is how the next reader concludes it
    /// is load-bearing.
    public func approvalRequest(
        for preparedRun: PreparedAgentRun,
        logAssessment: Bool = false,
        scope: TaskWorkspaceScope,
        context: ApprovalContext
    ) throws -> RiskApprovalRequest {
        let assessment = try executor.assessRisk(plan: preparedRun.plan, scope: scope)
        let request = RiskApprovalRequest(
            assessment: assessment,
            requirement: approvalPolicy.requirement(for: assessment, context: context)
        )
        if logAssessment {
            logRiskAssessment(request)
        }
        return request
    }

    /// `onUnitCompleted` and `onItemFailed` are forwarded to `AgentActionExecutor.execute` unchanged
    /// and mean exactly what they mean there (SONNY-210, SONNY-235). It defaults to "nobody is recording progress", which is
    /// every caller but the foreground run's resumable checkpoint — the scheduled path passes none,
    /// deliberately, because a scheduled routine writes no resumable record at all
    /// (`AgentViewModel.beginResumableTask`).
    public func execute(
        _ preparedRun: PreparedAgentRun,
        approvalDecision: RiskApprovalDecision = .notRequested,
        confirmationMessage: String = "Execution approved",
        logRiskAssessment: Bool = true,
        scope: TaskWorkspaceScope,
        context: ApprovalContext,
        onUnitCompleted: ((CompletedRunUnit) -> Void)? = nil,
        onItemFailed: ((ItemJobFailure) -> Void)? = nil
    ) async throws -> AgentRunResult {
        let request = try approvalRequest(
            for: preparedRun,
            logAssessment: logRiskAssessment,
            scope: scope,
            context: context
        )
        switch request.requirement {
        case .autoRun:
            break
        case .lightweightConfirmation, .explicitApproval:
            // The stale-approval gate. `request` above is a *fresh* assessment, not the one the user
            // answered, so this is the only place that can notice the world drifting between the
            // prompt and the run. It used to compare bare tiers, which made two different tier-3
            // causes indistinguishable — see `RiskApprovalConsent.authorizes(_:)` for the rule that
            // replaced it and for why each half of it reads the way it does (SONNY-62).
            guard approvalDecision.authorizes(request) else {
                // Only for the reason-drift and requirement-drift halves, and only when a consent
                // existed to be exceeded: `.notRequested` reaching here is the ordinary "this needs
                // approval" path, not a re-arm, and labelling it one would put a false event in the
                // trace (the mutation that emitted it there survived a whole battery — SONNY-62,
                // M9). The tier half is already legible from the `risk.assessed` line's own tier.
                if case .approved(let consent) = approvalDecision {
                    let unacknowledged = consent.unacknowledgedReasons(in: request)
                    if !unacknowledged.isEmpty {
                        logStore.append(
                            .risk,
                            "risk.rearmed: reasons not covered by the approval: \(unacknowledged.joined(separator: " "))"
                        )
                    }
                    if let answered = consent.answeredRequirement,
                       request.requirement.permissivenessRank < answered.permissivenessRank {
                        logStore.append(
                            .risk,
                            "risk.rearmed: a stricter approval is now required: \(request.requirement.displayName) (answered: \(answered.displayName))"
                        )
                    }
                }
                logStore.append(.confirm, "Approval required for \(request.assessment.effectiveTier.displayName)")
                throw RiskApprovalError.approvalRequired(request)
            }
        case .previewOnly:
            logStore.append(.confirm, "Execution paused by preview-only approval policy")
            throw RiskApprovalError.previewOnly(request)
        case .refuse:
            logStore.append(.confirm, "Execution refused by approval policy")
            throw RiskApprovalError.refused(request)
        }

        logStore.append(.confirm, confirmationMessage)
        let result = try await executor.execute(
            plan: preparedRun.plan,
            onUnitCompleted: onUnitCompleted,
            onItemFailed: onItemFailed
        ) { phase, message in
            self.logStore.append(phase, message)
        }
        recordRecentArtifacts(from: result)
        recordOutputLocations(from: result)
        return result
    }

    /// Set when artifact bookkeeping failed during the last `execute`. `AgentLogStore` alone is
    /// not a user-visible surface — no view renders its events — so the caller reads this to
    /// report the failure somewhere the user will actually see it.
    public private(set) var lastRecentArtifactFailure: String?

    private func recordRecentArtifacts(from result: AgentRunResult) {
        guard let recentArtifactStore else {
            return
        }
        do {
            let count = try recentArtifactStore.recordGeneratedArtifacts(from: result)
            if count > 0 {
                logStore.append(.observe, "Recorded \(count) recent artifact\(count == 1 ? "" : "s")")
            }
            lastRecentArtifactFailure = nil
        } catch {
            let description = "Sonny could not update its recent-artifacts list: \(error.localizedDescription)"
            logStore.append(.observe, description)
            lastRecentArtifactFailure = description
        }
    }

    /// Set when output-location bookkeeping failed during the last `execute`, for the same reason
    /// `lastRecentArtifactFailure` exists: `AgentLogStore` is not a user-visible surface, so a caller
    /// reads this to put the failure somewhere a person will see it.
    ///
    /// A separate property rather than a shared one, so a reader of either can tell which store
    /// could not be written — CLAUDE.md's rule that a write failure names what could not be saved
    /// does not survive two stores sharing one sentence.
    public private(set) var lastOutputLocationFailure: String?

    /// Remembers the folders this run wrote into.
    ///
    /// **Beside `recordRecentArtifacts` rather than inside it**, and reading the same `result` — the
    /// two answer different questions about the same run (which files, which folders) and are
    /// switched on and off separately, so they are two calls with two `nil` guards rather than one
    /// call doing both. `outputLocationStore` is `nil` whenever the user has this kind of memory
    /// off, which is the whole of the check: there is no second flag at this site to get wrong.
    private func recordOutputLocations(from result: AgentRunResult) {
        guard let outputLocationStore else {
            return
        }
        do {
            let recorded = try outputLocationStore.recordOutputs(from: result)
            if !recorded.isEmpty {
                let noun = recorded.count == 1 ? "output location" : "output locations"
                logStore.append(.observe, "Recorded \(recorded.count) \(noun)")
            }
            lastOutputLocationFailure = nil
        } catch {
            let description = "Sonny could not update its list of output locations: \(error.localizedDescription)"
            logStore.append(.observe, description)
            lastOutputLocationFailure = description
        }
    }

    private func logRiskAssessment(_ request: RiskApprovalRequest) {
        let assessment = request.assessment
        logStore.append(
            .risk,
            "risk.assessed: \(assessment.effectiveTier.displayName) (\(assessment.effectiveTier.semanticName)); approval: \(request.requirement.displayName)"
        )

        for escalation in assessment.escalations {
            logStore.append(
                .risk,
                "risk.escalated: \(escalation.fromTier.displayName) -> \(escalation.toTier.displayName): \(escalation.reason)"
            )
        }
    }
}
