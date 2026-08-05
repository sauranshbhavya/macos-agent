import Foundation

public struct OpenAppSearchURLCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let descriptor = AppWebsiteActionDescriptors.openAppSearchURL

    public static let metadata = CapabilityMetadata(
        id: descriptor.capabilityID,
        displayName: descriptor.displayName,
        description: descriptor.description,
        operations: descriptor.supportedActions,
        plannerTools: [
            AgentTool(
                operation: .openAppSearchURL,
                name: "Open allowlisted search URL",
                description: "Open a fixed allowlisted app or website search URL template. Supported search targets: \(AppSearchURLCatalog.default.displayList).",
                requiredFields: ["appName", "searchQuery"],
                sideEffects: ["open browser"],
                dryRunBehavior: "Show the fixed search URL template result without opening it.",
                examples: ["Search GitHub for Swift concurrency", "Search YouTube for Sonny demos"]
            )
        ],
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        return [
            ActionPreview(
                title: "Open \(spec.targetName) search",
                details: [
                    "Search query: \(spec.query)",
                    "Open \(spec.url.absoluteString)",
                    "Allowed search targets: \(context.appSearchURLCatalog.displayList)"
                ],
                opens: [spec.url.absoluteString]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try spec(in: plan, context: context)
        log(.act, "Opening \(spec.targetName) search for \(spec.query)")
        try await context.browserOpener.open(spec.url, using: context.preferredBrowser)
        log(.summarize, "Opened search URL")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Opened \(spec.targetName) search for \(spec.query)."
        )
    }

    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AppSearchURL {
        guard let step = plan.steps.first(where: { $0.operation == .openAppSearchURL }) else {
            throw AgentExecutionError.invalidPlan("open_app_search_url step is missing.")
        }
        return try context.appSearchURLCatalog.resolve(target: step.appName, query: step.searchQuery)
    }
}
