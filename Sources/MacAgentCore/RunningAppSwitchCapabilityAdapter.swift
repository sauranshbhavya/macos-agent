import Foundation

public struct RunningAppSwitchCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.instant.running-app-switch",
        displayName: "Switch running app",
        description: "Bring an already-running regular macOS app to the front without launching new apps.",
        operations: [.switchRunningApp],
        plannerTools: [],
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .appOpening)
        ],
        defaultRiskTier: .tier1
    )

    /// Resolves the query against the live running apps exactly once and pins the winner into the
    /// step (SONNY-58). Every executor gate — `prepare`, `assessRisk`, `execute` — resolves the
    /// plan before doing anything else, so the pin written at `prepare` is what the approval's
    /// assessment classifies, what the preview names, and what execution activates: the scope
    /// verdict binds to the app that will actually be switched to, never to the raw query string.
    ///
    /// **Pin once, first resolver wins.** An already-pinned step is returned untouched even if the
    /// running-apps list has changed since — re-resolving at a later gate would reopen the exact
    /// assessment-versus-execution divergence this hook exists to close. The only post-pin change
    /// that can matter is the pinned app quitting, and that fails execution with
    /// `noMatchingRunningApp` rather than silently re-matching something else.
    ///
    /// **Unresolvable throws, at the earliest gate.** Before this hook the same query failed inside
    /// `prepare` when this adapter's `preview` re-resolved it; the error and the user-visible
    /// outcome are unchanged, only earlier and singular.
    @MainActor
    public func resolveDefaultOutputs(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> AgentPlan {
        var resolved = plan
        for index in resolved.steps.indices where resolved.steps[index].operation == .switchRunningApp {
            guard resolved.steps[index].resolvedBundleIdentifier == nil else {
                continue
            }
            let app = try RunningAppMatcher.bestMatch(
                query: resolved.steps[index].appName ?? resolved.steps[index].searchQuery,
                in: context.runningAppSwitcher.runningApps()
            )
            resolved.steps[index].resolvedAppName = app.displayName
            resolved.steps[index].resolvedBundleIdentifier = app.bundleIdentifier
        }
        return resolved
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let app = try app(in: plan, context: context)
        return [
            ActionPreview(
                title: "Switch running app",
                details: [
                    "App: \(app.displayName)",
                    "Bundle: \(app.bundleIdentifier)"
                ],
                opens: [app.displayName]
            )
        ]
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let previews = try preview(plan: plan, context: context)
        let app = try app(in: plan, context: context)
        log(.act, "Switching to \(app.displayName)")
        try await context.runningAppSwitcher.activate(bundleIdentifier: app.bundleIdentifier)
        log(.summarize, "Switched running app")
        return AgentRunResult(
            plan: plan,
            previews: previews,
            summary: "Switched to \(app.displayName)."
        )
    }

    @MainActor
    private func app(in plan: AgentPlan, context: CapabilityExecutionContext) throws -> RunningApp {
        guard let step = plan.steps.first(where: { $0.operation == .switchRunningApp }) else {
            throw AgentExecutionError.invalidPlan("switch_running_app step is missing.")
        }
        // A pinned step is looked up by its exact bundle identifier — never re-fuzzy-matched. The
        // pin is the identity the assessment classified and the preview showed; if the app is gone,
        // failing with its name is the honest outcome, and switching to whatever now best-matches
        // the query would spend the pinned verdict on a different app.
        if let bundleIdentifier = step.resolvedBundleIdentifier {
            guard let app = context.runningAppSwitcher.runningApps()
                .first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                throw RunningAppSwitchError.noMatchingRunningApp(step.resolvedAppName ?? bundleIdentifier)
            }
            return app
        }
        // Unpinned: every executor gate resolves the plan before reaching this adapter, so this is
        // only reachable when the adapter is driven directly (tests, or a future caller that skips
        // the resolve phase). Behavior is the pre-SONNY-58 one, and the scope classifier's own
        // unpinned branch stays on the raw name for the same fail-closed reason.
        return try RunningAppMatcher.bestMatch(
            query: step.appName ?? step.searchQuery,
            in: context.runningAppSwitcher.runningApps()
        )
    }
}
