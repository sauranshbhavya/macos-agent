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
/// rule, and the view model's confirmation copy.
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

    public init(
        planner: any Planning,
        executor: AgentActionExecutor = AgentActionExecutor(),
        logStore: AgentLogStore = AgentLogStore(),
        approvalPolicy: RiskApprovalPolicy = .default,
        recentArtifactStore: RecentArtifactStore? = nil
    ) {
        self.plannerProvider = { planner }
        self.executor = executor
        self.logStore = logStore
        self.approvalPolicy = approvalPolicy
        self.recentArtifactStore = recentArtifactStore
    }

    public init(
        plannerProvider: @escaping () throws -> any Planning,
        executor: AgentActionExecutor = AgentActionExecutor(),
        logStore: AgentLogStore = AgentLogStore(),
        approvalPolicy: RiskApprovalPolicy = .default,
        recentArtifactStore: RecentArtifactStore? = nil
    ) {
        self.plannerProvider = plannerProvider
        self.executor = executor
        self.logStore = logStore
        self.approvalPolicy = approvalPolicy
        self.recentArtifactStore = recentArtifactStore
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
        var preparedRun = try executor.prepare(plan: plan)
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
    /// requirement and execute under another. And note where it lands — the *requirement*, never
    /// the assessment. `assessRisk` takes no context and must never grow one: `effectiveTier`
    /// remains a pure function of the plan, and the requirement is that tier plus the escalations'
    /// consequence classes plus whatever the context says (Safe mode today).
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

    public func execute(
        _ preparedRun: PreparedAgentRun,
        approvalDecision: RiskApprovalDecision = .notRequested,
        confirmationMessage: String = "Execution approved",
        logRiskAssessment: Bool = true,
        scope: TaskWorkspaceScope,
        context: ApprovalContext
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
        let result = try await executor.execute(plan: preparedRun.plan) { phase, message in
            self.logStore.append(phase, message)
        }
        recordRecentArtifacts(from: result)
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
