import Foundation

public struct OpenWorkspaceCapabilityAdapter: CapabilityAdapter {
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
                operation: .openWorkspace,
                name: "Open saved workspace",
                description: "Open every app and URL saved in a named workspace. Use only when the user names a workspace they have actually saved; do not infer a workspace name from vague activity phrasing such as \"focus on writing\" or \"get into research mode\" — ask a clarifying question instead.",
                requiredFields: ["workspaceName"],
                sideEffects: ["open apps", "open browser"],
                dryRunBehavior: "Show apps and URLs that would open.",
                examples: ["Open my research workspace", "Start research mode"]
            )
        ],
        requiredPermissions: descriptor.requiredPermissions,
        defaultRiskTier: descriptor.defaultRiskTier
    )

    public static let descriptor = AppWebsiteActionDescriptors.openWorkspace

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let workspace = try workspaceRunSpec(plan, context: context)
        return [
            ActionPreview(
                title: "Open workspace \(workspace.name)",
                details: [
                    "Apps: \(workspace.apps.isEmpty ? "none" : workspace.apps.joined(separator: ", "))",
                    "URLs: \(workspace.urls.isEmpty ? "none" : workspace.urls.joined(separator: ", "))"
                ],
                opens: workspace.apps + workspace.urls
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let workspace = try workspaceRunSpec(plan, context: context)
        for appName in workspace.apps {
            let app = try context.appCatalog.resolve(appName)
            log(.act, "Opening \(app.displayName)")
            try await context.appOpener.open(bundleIdentifier: app.bundleIdentifier)
        }
        for rawURL in workspace.urls {
            let url = try SafeURL.validateWebURL(rawURL)
            log(.act, "Opening \(url.absoluteString)")
            try await context.browserOpener.open(url)
        }
        log(.summarize, "Opened workspace")
        let summary = "Opened workspace \(workspace.name) with \(workspace.apps.count) app(s) and \(workspace.urls.count) URL(s)."
        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    private func workspaceRunSpec(_ plan: AgentPlan, context: CapabilityExecutionContext) throws -> StoredWorkspace {
        guard let step = plan.steps.first(where: { $0.operation == .openWorkspace }) else {
            throw AgentExecutionError.invalidPlan("open_workspace step is missing.")
        }
        let workspace = try context.workspaceStore.workspace(named: step.workspaceName ?? "")
        for app in workspace.apps {
            _ = try context.appCatalog.resolve(app)
        }
        for url in workspace.urls {
            _ = try SafeURL.validateWebURL(url)
        }
        return workspace
    }
}
