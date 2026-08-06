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
                // "Open every app" was true until SONNY-44 let a workspace list apps Sonny cannot
                // launch; a scope-only entry is now skipped, so "every" overclaims. Unlike the
                // descriptor strings fixed alongside it, this one reaches the model verbatim
                // (`ToolRegistry.plannerDescription` -> `OpenAIPlanner.systemPrompt`). The skip
                // itself is deliberately not spelled out: this description governs only *when* to
                // emit `open_workspace`, which takes a workspace name and no app list, so the
                // detail would cost prompt tokens and decide nothing.
                description: "Open the supported apps and URLs saved in a named workspace. Use only when the user names a workspace they have actually saved; do not infer a workspace name from vague activity phrasing such as \"focus on writing\" or \"get into research mode\" — ask a clarifying question instead.",
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
        let spec = try workspaceRunSpec(plan, context: context)
        let workspace = spec.workspace
        var details = [
            // Every listed app, launchable or not — this line describes what the workspace *is*,
            // and a scope-only entry is a real part of it.
            "Apps: \(workspace.apps.isEmpty ? "none" : workspace.apps.joined(separator: ", "))",
            "URLs: \(workspace.urls.isEmpty ? "none" : workspace.urls.joined(separator: ", "))"
        ]
        if let note = WorkspaceScopeOnlyApps.scopeOnlyNote(for: spec.scopeOnlyApps) {
            details.append(note)
        }
        return [
            ActionPreview(
                title: "Open workspace \(workspace.name)",
                details: details,
                // `opens` is a side-effect declaration, not a content listing — it feeds
                // `PreparedAgentRun.sideEffects` as "Open: X". A scope-only entry is never opened,
                // so listing it here would claim a side effect that cannot happen. Stored names
                // rather than resolved display names, so every workspace that exists today
                // previews byte-identically to before.
                opens: spec.launchableStoredNames + workspace.urls
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let spec = try workspaceRunSpec(plan, context: context)
        let workspace = spec.workspace
        // Walked in the workspace's own stored order so a skip is logged where the user expects it,
        // between the entries around it.
        var apps: [MacApp] = []
        for entry in spec.entries {
            switch entry {
            case .launchable(_, let app):
                log(.act, "Opening \(app.displayName)")
                try await context.appOpener.open(bundleIdentifier: app.bundleIdentifier)
                apps.append(app)
            case .scopeOnly(let storedName):
                // Never an error. Scope listing is decoupled from the launch catalog (2026-08-05),
                // so a workspace legitimately holds names it cannot open, and the SONNY-9 precedent
                // for an app that cannot be launched is to proceed and log — opening the rest of an
                // otherwise-good workspace beats failing the whole open.
                log(.observe, WorkspaceScopeOnlyApps.openSkipNote(for: storedName))
            }
        }
        // A workspace that names a browser gets its URLs in that browser rather than the system
        // default — the whole point of listing Safari in a Safari workspace. Resolved after the
        // apps loop so the browser is already launching by the time its first URL arrives; `nil`
        // (no browser in the list) keeps the pre-existing default-browser behavior exactly.
        // Only launchable apps are candidates, and their relative order is preserved, so
        // "first browser in the list" is unchanged for every workspace that exists today — a
        // scope-only entry can never be a browser Sonny could open URLs in anyway.
        let browser = WorkspaceBrowserCatalog.firstBrowser(in: apps)
        for rawURL in workspace.urls {
            let url = try SafeURL.validateWebURL(rawURL)
            log(.act, "Opening \(url.absoluteString)")
            try await context.browserOpener.open(url, using: browser)
        }
        log(.summarize, "Opened workspace")
        // Counts what was actually opened, not what the workspace lists. Identical to the old
        // `workspace.apps.count` for every workspace that can exist before this change, and the
        // honest number afterwards — "Opened … with 2 app(s)" when one of them was skipped for
        // being scope-only is a summary that contradicts what happened.
        //
        // An honest count alone still leaves the user guessing *which* app did not start, so the
        // names ride along. This is the only channel that reaches them: `ActionPreview` and the act
        // log above are both rendered by nothing (see `AgentRunner`'s note on `AgentLogStore`),
        // which is exactly why the count and the note live together here. The one surface that does
        // render it is the floating widget's result panel — and only for a widget-originated run,
        // since `hasVisibleWidgetPanel` gates `.result` on origin while Command Center renders no
        // summary of its own. So an open driven from Command Center's Workspaces row shows this
        // nowhere. Pre-existing and not specific to this note (it applies to every run summary
        // equally), filed separately rather than worked around here.
        //
        // A workspace whose every entry is scope-only reads "with 0 app(s) and 0 URL(s)" plus the
        // note. Deliberately not special-cased into a separate "nothing to open" string: the note
        // already explains the zero, and a second summary format is a second thing to keep true.
        var summary = "Opened workspace \(workspace.name) with \(apps.count) app(s) and \(workspace.urls.count) URL(s)."
        if let note = WorkspaceScopeOnlyApps.notOpenedNote(for: spec.scopeOnlyApps) {
            summary += " " + note
        }
        return AgentRunResult(plan: plan, previews: previews, summary: summary)
    }

    /// One stored app entry, classified once so `preview` and `execute` cannot disagree about which
    /// entries open.
    private enum WorkspaceAppEntry {
        /// A stored name `MacAppCatalog` resolves. Launched when the workspace opens, exactly as
        /// before.
        case launchable(storedName: String, app: MacApp)
        /// A stored name the catalog does not carry. Present for scope membership only, so it is
        /// skipped at open time and never fails the open.
        case scopeOnly(storedName: String)
    }

    private struct WorkspaceRunSpec {
        let workspace: StoredWorkspace
        /// In the workspace's stored order.
        let entries: [WorkspaceAppEntry]

        var launchableStoredNames: [String] {
            entries.compactMap { entry in
                guard case .launchable(let storedName, _) = entry else {
                    return nil
                }
                return storedName
            }
        }

        var scopeOnlyApps: [String] {
            entries.compactMap { entry in
                guard case .scopeOnly(let storedName) = entry else {
                    return nil
                }
                return storedName
            }
        }
    }

    private func workspaceRunSpec(
        _ plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> WorkspaceRunSpec {
        guard let step = plan.steps.first(where: { $0.operation == .openWorkspace }) else {
            throw AgentExecutionError.invalidPlan("open_workspace step is missing.")
        }
        let workspace = try context.workspaceStore.workspace(named: step.workspaceName ?? "")
        // Resolution no longer throws on an unresolvable name — that rejection is what made a
        // workspace unable to hold Microsoft Word, and it is the thing SONNY-44 removes. URL
        // validation is untouched and still throws: `SafeURL` is a capability bound, not a
        // user-declared boundary, and nothing decoupled it from anything.
        let entries = workspace.apps.map { storedName in
            guard let app = try? context.appCatalog.resolve(storedName) else {
                return WorkspaceAppEntry.scopeOnly(storedName: storedName)
            }
            return WorkspaceAppEntry.launchable(storedName: storedName, app: app)
        }
        for url in workspace.urls {
            _ = try SafeURL.validateWebURL(url)
        }
        return WorkspaceRunSpec(workspace: workspace, entries: entries)
    }
}
