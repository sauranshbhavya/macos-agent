import Foundation

public enum PreparedPlanSource: String, Equatable, Sendable {
    case planner
    case instantResolver = "instant_resolver"

    var planLogMessage: String {
        switch self {
        case .planner:
            return "Sending command to planner"
        case .instantResolver:
            return "Resolved command locally"
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
        return try prepareResolvedPlan(plan)
    }

    public func prepare(
        plan: AgentPlan,
        source: PreparedPlanSource = .instantResolver
    ) throws -> PreparedAgentRun {
        logStore.reset()
        logStore.append(.plan, source.planLogMessage)
        return try prepareResolvedPlan(plan)
    }

    private func prepareResolvedPlan(_ plan: AgentPlan) throws -> PreparedAgentRun {
        logStore.append(.observe, "Received plan: \(plan.summary)")
        logStore.append(.validate, "Validating whitelist and supported operations")
        let preparedRun = try executor.prepare(plan: plan)
        logStore.append(.preview, "Prepared \(preparedRun.previews.count) preview item(s)")
        return preparedRun
    }

    public func approvalRequest(
        for preparedRun: PreparedAgentRun,
        logAssessment: Bool = false
    ) throws -> RiskApprovalRequest {
        let assessment = try executor.assessRisk(plan: preparedRun.plan)
        let request = RiskApprovalRequest(
            assessment: assessment,
            requirement: assessment.approvalRequirement(policy: approvalPolicy)
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
        logRiskAssessment: Bool = true
    ) async throws -> AgentRunResult {
        let request = try approvalRequest(for: preparedRun, logAssessment: logRiskAssessment)
        switch request.requirement {
        case .autoRun:
            break
        case .lightweightConfirmation, .explicitApproval:
            guard case .approved(let approvedTier) = approvalDecision,
                  approvedTier.rawValue >= request.assessment.effectiveTier.rawValue else {
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
