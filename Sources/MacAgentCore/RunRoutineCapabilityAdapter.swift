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
        let nested = try namingRoutine(routine) { try context.previewNestedPlan(routine.plan) }
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
            // yields **`.inScope`** on a plan whose routine writes outside the boundary. Nothing
            // gates on the verdict since the consequence rule (2026-08-13) — it is data for the
            // surfaces that render it and for the future vision cage — but data that lies about a
            // routine's reach is still a lie a surface would repeat. Both shapes are pinned; the
            // mixed one is the reason this line exists.
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
        let result: AgentRunResult
        do {
            result = try await context.executeNestedPlan(routine.plan, browser(for: routine, context: context), log)
        } catch let error as AutomationStoreError {
            throw Self.namingRoutine(routine, in: error)
        }
        // Return the nested execution's real previews — re-deriving them here would re-resolve
        // default output paths (fresh timestamps) and report files that were never written.
        return AgentRunResult(
            plan: plan,
            previews: [headerPreview(for: routine)] + result.previews,
            summary: "Ran routine \(routine.name). \(result.summary)",
            // Forwarded, not authored (SONNY-147). This sentence is a template, but a nested run's
            // whole summary is interpolated into it, so declaring `.codeAuthored` because the
            // wrapper is code-authored would launder whatever the nested run produced.
            //
            // **Defence in depth, not a live path.** No routine can carry a screen-control step
            // today — `StoredRoutine.forbiddenStepOperations` refuses `.visionSession` at the write
            // door, deliberately, as the third layer of "unattended vision: never" — so the only
            // model-authored producer cannot reach this closure and `result.summaryProvenance` is
            // `.codeAuthored` on every path the product can currently take. Written this way anyway
            // because the alternative is a hardcoded `.codeAuthored` that becomes wrong silently the
            // day a second model-authored capability exists, and the enclosing sentence gives no
            // reader a reason to look here. The reachable join is
            // `AgentActionExecutor.executeChain`, which is pinned end to end by
            // `aChainWhoseScreenControlSegmentWrotePartOfTheSummaryStoresItAsModelAuthored`.
            summaryProvenance: result.summaryProvenance,
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
    /// `NSWorkspace.shared.open` directly, so a media step carrying an explicit
    /// `open.spotify.com`-style URL still lands in the system default browser.
    /// "Every URL the routine opens" was the original claim here and it was too broad.
    ///
    /// **That is a decision as of 2026-08-20, not an outstanding gap** (SONNY-51). Binding it would
    /// mean giving `MediaOpening` a browser preference, and forcing an https provider link through a
    /// named browser could override the handler that would otherwise open the Spotify or Music app —
    /// turning an app-open into a web-player open, which is worse than the inconsistency it fixes and
    /// cannot be measured from this repository because it depends on what each user has installed.
    /// The full reasoning, the measured reach (the media opener's fallback ends in an app-scheme URI
    /// in every case but an explicit https provider link), and the cost are recorded in
    /// `docs/sonny-founder-design-decisions.md`.
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
    /// Unresolvable app names are skipped rather than thrown on: a routine step naming an app that
    /// is not installed fails when *that step* executes, with its own error. Resolving the browser
    /// must not pre-empt that with a different failure before any step has run.
    ///
    /// Resolved through `installedAppResolver` since SONNY-82, which is what finally makes
    /// `WorkspaceBrowserCatalog`'s Arc, Firefox and Edge entries reachable — they were bundle
    /// identifiers no resolution path could ever produce while only the twelve-app catalog answered.
    ///
    /// **A nested workspace open contributes its own apps, as of SONNY-186.** This considered
    /// `.openApp` steps and nothing else for as long as `StoredRoutine.forbiddenStepOperations`
    /// refused `.openWorkspace` inside a routine — the shape was reachable only through
    /// `saveBypassingStepValidation` or a hand-edited store file, so it was treated as unhandled
    /// rather than impossible (PR #28's F5, PR #81's review). It is a product shape now, and left
    /// alone it would have contradicted the one thing the paragraph above is for: a routine that
    /// opens a Safari workspace and then opens a URL would have put the workspace's own URLs in
    /// Safari — `OpenWorkspaceCapabilityAdapter` resolves a browser from the same catalog for its
    /// own URLs — and the routine's URL step in whatever the system default is. Two browsers, one
    /// routine, for a reason no user could see.
    ///
    /// So both step kinds feed one ordered list and the existing rule is unchanged over it: first
    /// browser-capable app wins, in step order, and a workspace's apps enter in the workspace's own
    /// stored order at the position of the step that opens it. A routine with no `open_workspace`
    /// step therefore binds byte-identically to before.
    ///
    /// **This half is only half, and the other half is at `OpenWorkspaceCapabilityAdapter.execute`
    /// — it did not exist for one round, and the record claimed it did** (PR #177's F1). Reading the
    /// workspace's apps into the list makes a workspace *donate* a browser to the routine; it does
    /// nothing about the workspace *receiving* one, because that adapter opened its own URLs with
    /// its own resolution and read `preferredBrowser` nowhere. So the two shapes that need both
    /// halves stayed broken while the paragraph above read as if they were fixed:
    /// `[open_app Chrome, open_workspace(→ Safari, with URLs), open_url]`, where the routine binds
    /// Chrome and the workspace's URLs still went to Safari; and a routine opening two workspaces
    /// with different browsers, which needs no `open_app` at all and is the exact sentence the
    /// paragraph above gives as the reason this fix exists. That adapter now takes
    /// `preferredBrowser` first, so the ordering computed here is what every URL the routine opens
    /// actually uses.
    ///
    /// A workspace that cannot be loaded contributes nothing, for the same reason an unresolvable
    /// app name does: the missing workspace is `open_workspace`'s own failure to report, at the step
    /// that names it, and resolving a browser must not pre-empt that with a different failure before
    /// any step has run.
    private func browser(for routine: StoredRoutine, context: CapabilityExecutionContext) -> MacApp? {
        let apps = routine.steps.flatMap { step -> [MacApp] in
            switch step.operation {
            case .openApp:
                return [context.installedAppResolver.resolve(step.appName)?.macApp].compactMap { $0 }
            case .openWorkspace:
                guard let workspace = try? context.workspaceStore.workspace(named: step.workspaceName ?? "") else {
                    return []
                }
                return workspace.apps.compactMap { context.installedAppResolver.resolve($0)?.macApp }
            default:
                return []
            }
        }
        return WorkspaceBrowserCatalog.firstBrowser(in: apps)
    }

    /// Runs `body`, re-labelling a nested `open_workspace`'s "no such workspace" with the routine
    /// that asked for it.
    ///
    /// **Why the re-label exists at all** (SONNY-186). A routine may open a workspace as of that
    /// ticket, and the workspace it names can be deleted or renamed afterwards — the step holds a
    /// name and nothing keeps the two in step. Without this the user types "run my morning routine"
    /// and hears "I don't have a workspace called \"Research\" saved", a sentence about a thing they
    /// did not mention, two levels below the thing they did. `AutomationStoreError` carries the pair
    /// instead, and `AgentActionExecutor` turns it into the same clarification, listing the saved
    /// workspace names — which is the diagnostic a rename actually needs.
    ///
    /// Wrapped at `preview` and `execute` and not at `assessRisk`, because those are the two doors
    /// that can reach it: `OpenWorkspaceCapabilityAdapter` loads the store in `preview` and in
    /// `execute`, and overrides `assessRisk` not at all. Only `.missingWorkspace` is re-labelled —
    /// a missing *routine* is already the user's own word, and every other automation-store failure
    /// keeps its own error for the same reason `missingAutomationTargetQuestion` leaves them alone.
    private func namingRoutine<T>(_ routine: StoredRoutine, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AutomationStoreError {
            throw Self.namingRoutine(routine, in: error)
        }
    }

    private static func namingRoutine(_ routine: StoredRoutine, in error: AutomationStoreError) -> AutomationStoreError {
        guard case .missingWorkspace(let workspaceName) = error else {
            return error
        }
        return .missingWorkspaceInRoutine(routine: routine.name, workspace: workspaceName)
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
