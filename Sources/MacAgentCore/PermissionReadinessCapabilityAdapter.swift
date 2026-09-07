import Foundation

public struct PermissionReadinessCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.permissions.readiness",
        displayName: "Permission readiness",
        description: "Show current readiness status without prompting for permissions.",
        operations: [.showPermissionReadiness],
        plannerTools: [
            AgentTool(
                operation: .showPermissionReadiness,
                name: "Show permission readiness",
                // **Names no provider** (SONNY-136, founder decision 2026-08-19). This read "OpenAI
                // key" and the row it referred to is gone; the planner is given the tool's real
                // subject instead, which is the Sonny account.
                description: "Show readiness for the Sonny account, microphone, hotkey, Finder/Word automation, Desktop/Documents access, Accessibility, and Screen Recording.",
                requiredFields: [],
                sideEffects: [],
                dryRunBehavior: "Show permission readiness without requesting new permissions.",
                examples: ["Check Sonny permissions", "Show readiness panel"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let items = permissionItems(context: context)
        return [
            ActionPreview(
                title: "Permission readiness",
                details: items.map { "\($0.title): \($0.state.displayName) - \($0.detail)" }
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let items = permissionItems(context: context)
        let needsAction = items.filter { $0.state == .needsAction }
        log(.observe, "Checked \(items.count) readiness item(s)")
        let summary: String
        if needsAction.isEmpty {
            log(.summarize, "Permission readiness checked")
            summary = "Permission readiness checked. No blocking required-action items were found."
        } else {
            let names = needsAction.map(\.title).joined(separator: ", ")
            log(.summarize, "Needs action: \(names)")
            summary = "Permission readiness checked. Needs action: \(names)."
        }

        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    /// **This read `ProcessInfo.processInfo.environment["OPENAI_API_KEY"]` until SONNY-136**, which
    /// made a capability that prompts for nothing and touches nothing report on a variable no client
    /// reads — and made it the only environment read left in `MacAgentCore` outside the DOCX mock and
    /// the debug-only staging pointer. Both inputs now come from the context, so this adapter reads
    /// no process state of its own.
    private func permissionItems(context: CapabilityExecutionContext) -> [PermissionReadinessItem] {
        context.permissionReadinessService.currentStatus(
            modelAccess: context.modelAccessReadiness(),
            planAccess: context.planReadiness(),
            hotKeyReady: context.hotKeyReady()
        )
    }
}
