import Foundation

public struct RunRoutineCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata {
        Self.metadata
    }

    public static let metadata = CapabilityMetadata(
        id: "local.routines.run",
        displayName: "Run saved routine",
        description: "Load and run a saved routine through normal plan validation.",
        operations: [.runRoutine],
        plannerTools: [
            AgentTool(
                operation: .runRoutine,
                name: "Run saved routine",
                description: "Load a saved routine by name and execute its registered steps with the same validation and logging as normal plans. Use only when the user names a routine they have actually saved; do not infer a routine name from vague activity phrasing such as \"start my day\" — ask a clarifying question instead.",
                requiredFields: ["routineName"],
                sideEffects: ["depends on saved routine"],
                dryRunBehavior: "Preview the saved routine without executing its steps.",
                examples: ["Run my morning setup routine"]
            )
        ],
        requiredPermissions: [],
        defaultRiskTier: .tier2
    )

    /// The canonical single-step plan that runs a saved routine by name.
    ///
    /// Lives on the adapter that owns `.runRoutine` because the plan shape *is* that operation's
    /// contract. Shared by the instant resolver, the unattended-trust advisory, and the scheduler
    /// so a scheduled run goes through exactly the plan a typed "run my X routine" produces —
    /// three hand-rolled copies of this literal would be three chances to drift.
    public static func plan(forRoutineNamed name: String) -> AgentPlan {
        AgentPlan(
            summary: "Run routine \(name).",
            requiresConfirmation: true,
            steps: [
                AgentStep(
                    id: "run-routine",
                    operation: .runRoutine,
                    description: "Run saved routine \(name).",
                    routineName: name
                )
            ]
        )
    }

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let routine = try routineRunSpec(plan, context: context)
        let nested = try context.previewNestedPlan(routine.plan)
        return [headerPreview(for: routine)] + nested
    }

    public func assessRisk(plan: AgentPlan, context: CapabilityExecutionContext) throws -> CapabilityRiskAssessment {
        let routine = try routineRunSpec(plan, context: context)
        // Forwarded: a routine's steps must not escape the boundary its caller is bound by.
        let nested = try context.assessNestedPlan(routine.plan, context.taskScope)
        let defaultTier = highestTier(metadata.defaultRiskTier, nested.defaultTier)
        return CapabilityRiskAssessment(
            defaultTier: defaultTier,
            effectiveTier: highestTier(defaultTier, nested.effectiveTier),
            escalations: nested.escalations,
            // Forwarded, not dropped. The nested plan was assessed under the caller's own workspace
            // scope, so its roll-up is the only report of what the routine's steps touch — rebuilding
            // this assessment without it hands the executor `nil` and the outer fold then answers
            // from the outer plan's own findings alone.
            //
            // What that produces depends on the plan's shape, and the dangerous shape is the mixed
            // one. A plan whose *only* step is `run_routine` has no outer findings at all
            // (`PlanScopedResources` classifies the operation as `.none`), so dropping this yields
            // `.unconstrained` — wrong, but inert. Add one in-scope step beside it and dropping this
            // yields **`.inScope`** on a plan whose routine writes outside the boundary, which is
            // precisely the value row C relaxes on. Both shapes are pinned; the mixed one is the
            // reason this line exists.
            scopeVerdict: nested.scopeVerdict
        )
    }

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let routine = try routineRunSpec(plan, context: context)
        log(.act, "Running routine \(routine.name)")
        let result = try await context.executeNestedPlan(routine.plan, browser(for: routine, context: context), log)
        // Return the nested execution's real previews — re-deriving them here would re-resolve
        // default output paths (fresh timestamps) and report files that were never written.
        return AgentRunResult(
            plan: plan,
            previews: [headerPreview(for: routine)] + result.previews,
            summary: "Ran routine \(routine.name). \(result.summary)",
            suggestions: result.suggestions
        )
    }

    /// The routine's browser: the first browser-capable app among its own app-open steps, which
    /// then binds every URL the routine opens **on the injected browser-opener seam**, regardless
    /// of step order.
    ///
    /// That seam qualifier is load-bearing, not hedging (PR #28, F4). `.openURL`, `.openAppSearchURL`
    /// and the Hacker News open all go through `CapabilityExecutionContext.browserOpener` and so
    /// bind. `.playMedia` does not: it opens through `context.mediaOpener`, which reaches
    /// `NSWorkspace.shared.open` directly (`MediaPlaybackService.swift:1015`), so a media step
    /// carrying an explicit `open.spotify.com`-style URL still lands in the system default browser.
    /// "Every URL the routine opens" was the original claim here and it was too broad.
    ///
    /// Byte-for-byte the workspace rule (`WorkspaceBrowserCatalog.firstBrowser(in:)`, reused rather
    /// than reimplemented so there is one definition of "browser-capable"), deliberately so: a
    /// routine that opens Safari and a workspace that lists Safari should behave the same way, and
    /// two mental models for one behavior is the surprise SONNY-24 exists to remove.
    ///
    /// **The decided semantic, spelled out rather than cited** (founder decision, 2026-08-04): the
    /// first browser-capable app *anywhere* in the routine binds *all* of the routine's URL steps,
    /// regardless of step order — a URL step sequenced before the browser step still binds, and
    /// with two browsers the first in step order wins. The order-sensitive alternative and a
    /// per-routine browser setting were both considered and declined, so that a routine and a
    /// workspace are one mental model.
    ///
    /// `nil` when the routine names no browser, which keeps the system-default behavior exactly.
    ///
    /// Unresolvable app names are skipped rather than thrown on: a routine step naming an app the
    /// catalog no longer knows fails when *that step* executes, with its own error. Resolving the
    /// browser must not pre-empt that with a different failure before any step has run.
    ///
    /// Only `.openApp` steps are considered. A nested workspace open is *rejected by
    /// `SaveRoutineCapabilityAdapter.validateRoutineSteps`* — but that is the save capability's
    /// boundary, not the store's: `RoutineStore.save` validates `schedule` and nothing else, so a
    /// routine carrying one can still be written directly and reach here. Treated as unhandled
    /// rather than impossible for that reason (PR #28, F5).
    private func browser(for routine: StoredRoutine, context: CapabilityExecutionContext) -> MacApp? {
        let apps = routine.steps
            .filter { $0.operation == .openApp }
            .compactMap { try? context.appCatalog.resolve($0.appName) }
        return WorkspaceBrowserCatalog.firstBrowser(in: apps)
    }

    private func headerPreview(for routine: StoredRoutine) -> ActionPreview {
        ActionPreview(
            title: "Run routine \(routine.name)",
            details: ["Saved steps: \(routine.steps.count)"]
        )
    }

    private func routineRunSpec(_ plan: AgentPlan, context: CapabilityExecutionContext) throws -> StoredRoutine {
        guard let step = plan.steps.first(where: { $0.operation == .runRoutine }) else {
            throw AgentExecutionError.invalidPlan("run_routine step is missing.")
        }
        return try context.routineStore.routine(named: step.routineName ?? "")
    }

    private func highestTier(_ first: CapabilityRiskTier, _ second: CapabilityRiskTier) -> CapabilityRiskTier {
        first.rawValue >= second.rawValue ? first : second
    }
}
