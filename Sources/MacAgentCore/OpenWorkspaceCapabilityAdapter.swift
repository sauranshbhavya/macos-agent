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
                // launch; a scope-only entry is now skipped, so "every" overclaims. The hedge chosen
                // then was "the supported apps", which C12 falsified in turn — support is no longer
                // the question, installation is — so the qualifier is simply dropped (PR #44
                // cycle-1 review, MEDIUM-2). Unlike the descriptor strings fixed alongside it, this
                // one reaches the model verbatim (`ToolRegistry.plannerDescription` ->
                // `OpenAIPlanner.systemPrompt`). The skip itself is still deliberately not spelled
                // out: this description governs only *when* to emit `open_workspace`, which takes a
                // workspace name and no app list, so the detail would cost prompt tokens and decide
                // nothing.
                description: "Open the apps and URLs saved in a named workspace. Use only when the user names a workspace they have actually saved; do not infer a workspace name from vague activity phrasing such as \"focus on writing\" or \"get into research mode\" — ask a clarifying question instead.",
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
        // One restore around the whole workspace, not one per app (SONNY-451): the user's app comes
        // back once everything is open, so the opens do not fight it for the front in between.
        var apps: [MacApp] = []
        let launchable = spec.entries.compactMap { entry -> String? in
            if case .launchable(_, let app) = entry {
                return app.bundleIdentifier
            }
            return nil
        }
        try await context.restoringFocus(afterOpening: launchable, log: log) {
            for entry in spec.entries {
                switch entry {
                case .launchable(_, let app):
                    log(.act, "Opening \(app.displayName)")
                    try await context.appOpener.open(bundleIdentifier: app.bundleIdentifier)
                    apps.append(app)
                case .scopeOnly(let storedName):
                    // Never an error. Scope listing is decoupled from launchability (2026-08-05), so
                    // a workspace legitimately holds names it cannot open, and the SONNY-9 precedent for
                    // an app that cannot be launched is to proceed and log — opening the rest of an
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
            //
            // **An enclosing routine's binding wins over the workspace's own, and that is a decision
            // this branch had to make rather than a mechanism it inherited** (SONNY-186, PR #177's F1).
            // A routine could not carry `open_workspace` until this branch, so `preferredBrowser` was
            // never non-nil here and the two rules could not meet. Now they can, and the founders'
            // 2026-08-04 routine rule is the one that governs when they do: *the first browser-capable
            // app anywhere in the routine binds all of the routine's URL steps*, with the first in step
            // order winning when there are two. A routine that opens a Chrome workspace and a Safari
            // workspace **is** "two browsers in one routine", so the tie-break already exists and this
            // applies it one level down rather than inventing a second rule — which is the whole point
            // of that decision's own sentence, that a routine and a workspace are one mental model.
            //
            // **What this costs, stated because it is the half a founder might overturn:** a routine
            // opening a Chrome workspace and a Safari workspace puts both workspaces' URLs in whichever
            // comes first in step order, so a user who deliberately gave two workspaces two browsers
            // loses that distinction inside a routine. The alternative — each workspace keeps its own,
            // which is what shipped in this branch's first round — is defensible and leaves a routine
            // opening two browsers with nothing in the product explaining why. `RunRoutineCapabilityAdapter.browser(for:)`
            // is the other half of this decision and reads the same way.
            //
            // **Nothing outside a routine changes**, and the reason is a one-site enumeration rather
            // than a survey: exactly one site in `Sources` puts a non-nil value into
            // `preferredBrowser` — `AgentActionExecutor.swift:1885`, inside the `executeNestedPlan`
            // closure, whose own sole caller is `RunRoutineCapabilityAdapter.swift:93`. Every other
            // site either threads the parameter it was given or declares one. So a standalone workspace
            // open still resolves its own browser and a Safari workspace opened on its own still opens
            // in Safari, byte for byte.
            //
            // The pipeline below is what measures it: **1**, naming that line, at `a82ae04` and on any
            // later tree — the second stage drops comment lines, so this citation cannot inflate its
            // own count. The control is deliberately not stamped, because it is a property of the
            // command rather than of a commit: drop that second stage on whatever tree you are reading
            // and the answer becomes **2**, the extra hit being this very block. That is what proves
            // the stage is doing the excluding rather than the pattern failing to match.
            //
            //     git grep -n 'preferredBrowser: ' -- Sources \
            //       | grep -vE ':[0-9]+: *[/][/]' \
            //       | grep -v 'preferredBrowser: preferredBrowser' \
            //       | grep -v 'preferredBrowser: MacApp?'
            //
            // **Two things about that command are the point, and both are corrections** (PR #177's R1).
            // It is written to be un-matchable by its own text — the second stage drops comment lines,
            // and the slashes are bracketed so this block is not a line comment opening a span the
            // source-scanning tests would read to the end of the file (`CLAUDE.md`'s slash-star gotcha,
            // same family). And it measures the claim: **`preferredBrowser` argument sites**, which is
            // what "no other door sets it" is about. The citation this replaces counted call sites of
            // `executeNestedPlan(` instead, which establishes only that *that* door has one caller —
            // one half of the claim, with nothing telling a reader which half. It also answered **2**
            // rather than the 1 it reported, because the second hit was its own line.
            //
            // The narrower fact the old command did measure is kept above as a sentence rather than a
            // count, since it is still true and still load-bearing: the setting site is reached only
            // through the routine adapter.
            //
            // A browser named on the *step* is deliberately still not read here. `context.browser(for:in:)`
            // would honour one, and the precedence it documents would put it above the routine's binding;
            // no path emits an `open_workspace` step carrying `browserName`, so wiring it would be a
            // behaviour change on a shape nothing produces and a separate decision from this one.
            let browser = context.preferredBrowser ?? WorkspaceBrowserCatalog.firstBrowser(in: apps)
            for rawURL in workspace.urls {
                let url = try SafeURL.validateWebURL(rawURL)
                log(.act, "Opening \(url.absoluteString)")
                try await context.browserOpener.open(url, using: browser)
            }
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
        /// A stored name that resolves to an app installed on this Mac. Launched when the
        /// workspace opens.
        case launchable(storedName: String, app: MacApp)
        /// A stored name nothing installed answers to. Present for scope membership only, so it is
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
        //
        // This was the *second* catalog-consulting launch path, and the quiet one: because it soft-
        // skips with `try?` rather than throwing, a workspace listing Figma opened everything except
        // Figma and said so in a note, where `open_app` refused outright. Both now ask the same
        // question — is it installed — through the same seam, so the two doors agree.
        let entries = workspace.apps.map { storedName in
            guard let app = context.installedAppResolver.resolve(storedName) else {
                return WorkspaceAppEntry.scopeOnly(storedName: storedName)
            }
            return WorkspaceAppEntry.launchable(storedName: storedName, app: app.macApp)
        }
        for url in workspace.urls {
            _ = try SafeURL.validateWebURL(url)
        }
        return WorkspaceRunSpec(workspace: workspace, entries: entries)
    }
}
