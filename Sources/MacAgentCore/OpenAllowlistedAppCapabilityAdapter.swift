import Foundation

public struct OpenAllowlistedAppCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: descriptor.capabilityID,
        displayName: descriptor.displayName,
        description: descriptor.description,
        operations: descriptor.supportedActions,
        plannerTools: [
            AgentTool(
                operation: .openApp,
                name: "Open allowlisted Mac app",
                description: "Open an app from the local allowlist by human app name. Supported apps: \(MacAppCatalog.default.displayList).",
                requiredFields: ["appName"],
                sideEffects: ["open app"],
                dryRunBehavior: "Show the allowlisted app that would open.",
                examples: ["Open Safari", "Open Spotify", "Launch Apple Music"]
            )
        ],
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public static let descriptor = AppWebsiteActionDescriptors.openApp

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try spec(in: plan, context: context)
        return [
            ActionPreview(
                title: "Open the \(spec.app.displayName) app",
                details: [
                    "Bundle: \(spec.app.bundleIdentifier)",
                    "Allowed apps: \(context.appCatalog.displayList)"
                ],
                opens: [spec.app.displayName]
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
        log(.act, "Opening \(spec.app.displayName)")
        try await context.appOpener.open(bundleIdentifier: spec.app.bundleIdentifier)
        log(.summarize, "Opened \(spec.app.displayName)")
        // Says "app" explicitly: a saved workspace can share a name with an allowlisted app
        // (a workspace called "Slack"), and a bare "Opened Slack." left the user unable to tell
        // which one actually ran. The workspace summary already names itself a workspace.
        return AgentRunResult(plan: plan, previews: previews, summary: "Opened the \(spec.app.displayName) app.")
    }

    private struct AppSpec {
        var app: MacApp
    }

    private func spec(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AppSpec {
        guard let step = plan.steps.first(where: { $0.operation == .openApp }) else {
            throw AgentExecutionError.invalidPlan("open_app step is missing.")
        }
        return AppSpec(app: try context.appCatalog.resolve(step.appName))
    }
}
