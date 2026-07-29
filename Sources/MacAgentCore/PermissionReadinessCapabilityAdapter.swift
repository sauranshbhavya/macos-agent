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
                description: "Show readiness for OpenAI key, microphone, hotkey, Finder/Word automation, Desktop/Documents access, Accessibility, and Screen Recording.",
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

    private func permissionItems(context: CapabilityExecutionContext) -> [PermissionReadinessItem] {
        let hasAPIKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return context.permissionReadinessService.currentStatus(
            hasAPIKey: hasAPIKey,
            hotKeyReady: context.hotKeyReady()
        )
    }
}
