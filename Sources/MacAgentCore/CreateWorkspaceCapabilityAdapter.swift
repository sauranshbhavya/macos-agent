import Foundation

public struct CreateWorkspaceCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.workspaces.create",
        displayName: "Create workspace launcher",
        description: "Save a named workspace of allowlisted apps and safe URLs.",
        operations: [.createWorkspace],
        plannerTools: [
            AgentTool(
                operation: .createWorkspace,
                name: "Create workspace launcher",
                description: "Save a named workspace containing allowlisted apps and safe http/https URLs.",
                requiredFields: ["workspaceName"],
                sideEffects: ["write local workspace file"],
                dryRunBehavior: "Show the workspace apps and URLs without saving.",
                examples: ["Create a workspace called research with Safari, VS Code, and https://github.com"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let spec = try workspaceCreateSpec(plan, context: context)
        let workspace = spec.workspace
        var details = [
            "Apps: \(workspace.apps.isEmpty ? "none" : workspace.apps.joined(separator: ", "))",
            "URLs: \(workspace.urls.isEmpty ? "none" : workspace.urls.joined(separator: ", "))"
        ]
        if let note = WorkspaceScopeOnlyApps.scopeOnlyNote(for: spec.scopeOnlyApps) {
            details.append(note)
        }
        return [
            ActionPreview(
                title: "Save workspace \(workspace.name)",
                details: details,
                writes: [context.workspaceStore.fileURL.path]
            )
        ]
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let workspace = try workspaceCreateSpec(plan, context: context).workspace
        let escalations = (try? context.workspaceStore.workspace(named: workspace.name)) != nil
            ? [
                CapabilityRiskEscalation(
                    fromTier: metadata.defaultRiskTier,
                    toTier: .tier3,
                    reason: "Workspace named \(workspace.name) already exists and would be replaced."
                )
            ]
            : []
        return CapabilityRiskAssessment(defaultTier: metadata.defaultRiskTier, escalations: escalations)
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try workspaceCreateSpec(plan, context: context)
        let workspace = spec.workspace
        // `ActionPreview.details` reaches no UI surface today — nothing in `MacAgent` renders an
        // `ActionPreview` — so the preview note alone would be invisible in the real app. This is
        // the same signal on the channel the user actually sees, following the established
        // `log(.observe, "Skipped …")` shape (`WebResearchMarkdownCapabilityAdapter:155`,
        // `OpenMediaResultCapabilityAdapter:210`): notable, not a failure. Deliberately *not* a
        // `CapabilityRiskEscalation` — all six existing escalation sites raise a tier, and both
        // approval panels label that line "what raised this above its default tier", so a
        // same-tier entry would render an informational note in warning colour under a heading
        // that would then be a lie.
        if let note = WorkspaceScopeOnlyApps.scopeOnlyNote(for: spec.scopeOnlyApps) {
            log(.observe, note)
        }
        log(.act, "Saving workspace \(workspace.name)")
        try context.workspaceStore.save(workspace)
        log(.summarize, "Saved workspace")
        let summary = "Saved workspace \(workspace.name) with \(workspace.apps.count) app(s) and \(workspace.urls.count) URL(s)."
        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    /// A workspace about to be saved, together with the names that will count for scope only.
    private struct WorkspaceCreateSpec {
        let workspace: StoredWorkspace
        /// Listed names `MacAppCatalog` cannot resolve, in the order the user gave them.
        let scopeOnlyApps: [String]
    }

    private func workspaceCreateSpec(
        _ plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> WorkspaceCreateSpec {
        guard let step = plan.steps.first(where: { $0.operation == .createWorkspace }) else {
            throw AgentExecutionError.invalidPlan("create_workspace step is missing.")
        }
        guard let name = step.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw AutomationStoreError.missingName("Workspace")
        }

        let rawApps = step.workspaceApps ?? []
        let urls = step.workspaceURLs ?? []
        guard !rawApps.isEmpty || !urls.isEmpty else {
            throw AutomationStoreError.emptyWorkspace
        }

        // A name the catalog cannot resolve is no longer a hard failure (the 2026-08-05 decision) —
        // but a *blank* one still is, and that distinction is the whole typo guard on the storage
        // side. `catalog.resolve` used to throw `.missingAppName` for an empty string on the way to
        // rejecting everything else; dropping the catalog gate without keeping this would let ""
        // into an apps list, where `WorkspaceScope` classifies it as an inert entry that can never
        // match anything — a boundary that quietly does nothing.
        //
        // Names are stored **trimmed and otherwise as typed**, which is `docs/sonny-branch-b-plan.md`
        // §7's recorded storage rule ("Raw user string — `Chrome` and `Google Chrome` both persist
        // as typed") kept intact for catalog and non-catalog names alike. Folding a stored name down
        // to `MacAppCatalog.normalize`'s key form would persist "Microsoft Word" as "microsoftword"
        // in the list the user reads back in B6's detail sheet, and would make non-catalog entries
        // display differently from catalog ones for no matching benefit: `WorkspaceScope.appKey`
        // already folds *both* sides of every comparison through that same normalizer, so matching
        // is unaffected by which of the two forms is on disk. One normalizer, and it stays the
        // evaluator's — this path adds none.
        var apps: [String] = []
        for rawApp in rawApps {
            let trimmed = rawApp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MacAppCatalogError.missingAppName
            }
            apps.append(trimmed)
        }
        for url in urls {
            _ = try SafeURL.validateWebURL(url)
        }

        return WorkspaceCreateSpec(
            workspace: StoredWorkspace(name: name, apps: apps, urls: urls),
            scopeOnlyApps: WorkspaceScopeOnlyApps.names(in: apps, catalog: context.appCatalog)
        )
    }
}
