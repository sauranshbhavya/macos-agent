import Foundation

public struct ClipboardHistoryCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.clipboard-history",
        displayName: "Clipboard history",
        description: "Look up recent local clipboard text captured by Sonny's privacy-filtered clipboard monitor.",
        operations: [.lookupClipboardHistory],
        requiredPermissions: [],
        defaultRiskTier: .tier0
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan)
        let items = try context.clipboardHistoryStore.recent(
            matching: spec.query,
            limit: spec.limit,
            now: context.now()
        )
        return [
            ActionPreview(
                title: "Clipboard history",
                details: details(for: items, query: spec.query)
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
        let items = try context.clipboardHistoryStore.recent(
            matching: spec.query,
            limit: spec.limit,
            now: context.now()
        )
        log(.act, "Looking up clipboard history")
        log(.summarize, "Clipboard history lookup complete")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Found \(items.count) clipboard item\(items.count == 1 ? "" : "s")."
        )
    }

    private struct ClipboardSpec {
        var query: String?
        var limit: Int
    }

    private func spec(in plan: AgentPlan) throws -> ClipboardSpec {
        guard let step = plan.steps.first(where: { $0.operation == .lookupClipboardHistory }) else {
            throw AgentExecutionError.invalidPlan("lookup_clipboard_history step is missing.")
        }
        let limit = step.count.map { max(1, min(20, $0)) } ?? 10
        return ClipboardSpec(query: step.searchQuery, limit: limit)
    }

    private func details(for items: [ClipboardHistoryItem], query: String?) -> [String] {
        var details: [String] = []
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            details.append("Search: \(query)")
        }
        if items.isEmpty {
            details.append("No clipboard history found.")
            return details
        }
        details.append(contentsOf: items.map { item in
            let preview = item.text.replacingOccurrences(of: "\n", with: " ")
            return preview.count > 120 ? "\(preview.prefix(120))..." : preview
        })
        return details
    }
}
