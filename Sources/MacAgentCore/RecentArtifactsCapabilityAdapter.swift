import Foundation

public struct RecentArtifactsCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.recent-artifacts",
        displayName: "Recent artifacts",
        description: "Look up recently generated Sonny files without opening them.",
        operations: [.lookupRecentArtifacts],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan)
        let artifacts = try context.recentArtifactStore.recent(
            matching: spec.query,
            limit: spec.limit,
            now: context.now()
        )
        return [
            ActionPreview(
                title: "Recent artifacts",
                details: details(for: artifacts, query: spec.query)
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try spec(in: plan)
        let artifacts = try context.recentArtifactStore.recent(
            matching: spec.query,
            limit: spec.limit,
            now: context.now()
        )
        log(.act, "Looking up recent artifacts")
        log(.summarize, "Recent artifact lookup complete")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Found \(artifacts.count) recent artifact\(artifacts.count == 1 ? "" : "s")."
        )
    }

    private struct RecentArtifactSpec {
        var query: String?
        var limit: Int
    }

    private func spec(in plan: AgentPlan) throws -> RecentArtifactSpec {
        guard let step = plan.steps.first(where: { $0.operation == .lookupRecentArtifacts }) else {
            throw AgentExecutionError.invalidPlan("lookup_recent_artifacts step is missing.")
        }
        let limit = step.count.map { max(1, min(20, $0)) } ?? 10
        return RecentArtifactSpec(query: step.searchQuery, limit: limit)
    }

    private func details(for artifacts: [RecentArtifact], query: String?) -> [String] {
        var details: [String] = []
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            details.append("Search: \(query)")
        }
        if artifacts.isEmpty {
            details.append("No recent artifacts found.")
            return details
        }
        details.append(contentsOf: artifacts.map { artifact in
            "\(artifact.title) - \(artifact.path)"
        })
        return details
    }
}
