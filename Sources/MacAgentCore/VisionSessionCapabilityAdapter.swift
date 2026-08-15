import CoreGraphics
import Foundation

public enum VisionSessionError: Error, Equatable, LocalizedError {
    case missingGoal
    case missingTargetApp
    case targetAppNotInstalled(String)
    case targetNotControllable(ScreenControlRefusal)
    case visionUnavailable
    case targetAppNotRunning(String)

    public var errorDescription: String? {
        switch self {
        case .missingGoal:
            return "Sonny needs to know what to do in the app before it can control it."
        case .missingTargetApp:
            return "Sonny needs to know which app to control."
        case .targetAppNotInstalled(let name):
            return "Sonny could not find an app called \(name) on this Mac."
        case .targetNotControllable(let refusal):
            return refusal.userFacingReason
        case .visionUnavailable:
            return "Screen control is not available in this build."
        case .targetAppNotRunning(let name):
            return "Sonny could not bring \(name) to the front. Is it running?"
        }
    }
}

/// Sonny acting inside an app it has no adapter for.
///
/// **The shape, in one paragraph.** The user's command becomes a one-step plan carrying a goal and
/// an app name. `resolveDefaultOutputs` pins the app to a bundle identifier once, through Launch
/// Services, and refuses outright if that app is a terminal. `assessRisk` reports the session
/// honestly as tier 3 — high enough that the unattended path's tier-2 ceiling can never cover it —
/// with an *advisory* escalation, so the consequence rule lets it start without a prompt in Normal
/// and Power while Safe mode's floor still asks. Then `execute` runs the loop, and every single
/// thing that loop does passes through `VisionSessionContainment`, which asks
/// `RiskApprovalPolicy.requirement(for:context:)` — the same one function every other capability in
/// this app asks. There is no second trust path and no gate inside the loop that the engine does not
/// own.
public struct VisionSessionCapabilityAdapter: CapabilityAdapter {
    public init() {}

    public var metadata: CapabilityMetadata { Self.metadata }

    public static let metadata = CapabilityMetadata(
        id: "local.screen.vision-session",
        displayName: "Control an app",
        description: "Act inside any app by looking at its window and clicking and typing in it.",
        operations: [.visionSession],
        // Empty deliberately, and only until SONNY-93. The operation is excluded from
        // `plannerVisibleCases` in SONNY-92, and `PlannerBoundaryTests` pins the agreement between
        // those two facts — so a tool here without the schema entry would break that pin, in the
        // direction of telling the model about a word the schema will not let it say.
        plannerTools: [],
        // Both, and this is the only capability that needs both: Screen Recording to see the
        // window, Accessibility to send real input into it. `.descriptiveOnly` is the enforcement
        // vocabulary this metadata has — the real enforcement is the pair of preflights at the top
        // of the loop, which throw before a byte is captured or an event is posted.
        requiredPermissions: [
            CapabilityPermissionMetadata(requirement: .screenRecording),
            CapabilityPermissionMetadata(requirement: .accessibilityControl)
        ],
        // Tier 2, not tier 3, and the difference is load-bearing in two directions. Upward: the
        // session's real severity arrives as an escalation in `assessRisk`, which is what keeps
        // `effectiveTier` an honest computed signal rather than a constant. Downward: every
        // `defaultRiskTier` literal in this codebase is tier 2 or below, and
        // `RiskApprovalConsent.Coverage` reasons from exactly that fact to prove a tier-3 assessment
        // always carries at least one reason. A tier-3 literal here would falsify it.
        defaultRiskTier: .tier2
    )

    // MARK: - Resolve: pin the target once, refuse a terminal here

    /// The resolve phase every gate runs before reading the plan (SONNY-58).
    ///
    /// Two things happen exactly once, here, and never again: the app name becomes a bundle
    /// identifier, and a terminal target is refused. Pinning once is what stops `assessRisk` and
    /// `execute` from independently re-resolving a name and disagreeing about which app they meant —
    /// the classic time-of-check/time-of-use gap, and the reason `resolvedBundleIdentifier` is
    /// excluded from every decoder so nothing can arrive pre-pinned.
    public func resolveDefaultOutputs(
        in plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> AgentPlan {
        var resolved = plan
        for index in resolved.steps.indices where resolved.steps[index].operation == .visionSession {
            let step = resolved.steps[index]
            let rawName = (step.appName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else {
                throw VisionSessionError.missingTargetApp
            }
            guard let app = context.installedAppResolver.resolve(rawName) else {
                throw VisionSessionError.targetAppNotInstalled(rawName)
            }

            // **The terminal ban, at the first door.** A refusal rather than a tier — nothing here
            // reaches an approval surface, because there is no question to ask. The plan simply
            // never becomes executable, and the user is told why in the same sentence
            // `ScreenControlPolicy` would have used anywhere else.
            let verdict = ScreenControlPolicy.verdict(for: app)
            if let refusal = verdict.refusal {
                throw VisionSessionError.targetNotControllable(refusal)
            }

            resolved.steps[index].resolvedAppName = app.displayName
            resolved.steps[index].resolvedBundleIdentifier = app.bundleIdentifier
        }
        return resolved
    }

    // MARK: - Preview

    public func preview(plan: AgentPlan, context: CapabilityExecutionContext) throws -> [ActionPreview] {
        let step = try visionStep(in: plan)
        let appName = step.resolvedAppName ?? step.appName ?? "the app"
        return [
            ActionPreview(
                title: "Control \(appName)",
                details: [
                    "Goal: \(try goal(in: step))",
                    "Sonny will look at \(appName)'s window and click and type in it.",
                    "Screenshots of that window are redacted, then sent to Sonny's vision model.",
                    "You can stop it at any time."
                ]
            )
        ]
    }

    // MARK: - Assess: the session envelope, once, before anything moves

    public func assessRisk(
        plan: AgentPlan,
        context: CapabilityExecutionContext
    ) throws -> CapabilityRiskAssessment {
        let step = try visionStep(in: plan)

        // Defense in depth. `resolveDefaultOutputs` already refused a terminal and runs before every
        // gate, so in the shipped wiring this is unreachable — which is the point: the check is per
        // door, not one shared assumption, and a future caller that assesses a hand-built plan
        // without resolving first still cannot get a controllable verdict for a terminal.
        if let bundleIdentifier = step.resolvedBundleIdentifier {
            let verdict = ScreenControlPolicy.verdict(
                bundleIdentifier: bundleIdentifier,
                displayName: step.resolvedAppName ?? bundleIdentifier
            )
            if let refusal = verdict.refusal {
                throw VisionSessionError.targetNotControllable(refusal)
            }
        }

        let appName = step.resolvedAppName ?? step.appName ?? "an app"
        return CapabilityRiskAssessment(
            defaultTier: .tier2,
            approvalCopy: RiskApprovalCopy(
                actionDescription: "Control \(appName) directly — clicking and typing in its window",
                riskReason: "Sonny will act inside \(appName) the way you would, deciding each step from a screenshot.",
                involvedResource: appName,
                // Yes, and the one place a user is told so is Safe mode's approval line. Every
                // iteration sends a redacted screenshot of this window to the vision model.
                dataLeavesDevice: true,
                undoDescription: "Sonny cannot undo what it does inside \(appName). You can stop it at any time."
            ),
            escalations: [
                // **Advisory, and tier 3, and both halves matter.**
                //
                // Tier 3 because a session that can click anything in an app is genuinely
                // external-or-destructive class, and because the unattended scheduled path's fixed
                // `.approved(.tier2)` ceiling must never be able to cover one. That ceiling is one
                // of the three independent layers behind "unattended vision: never", and it works by
                // comparing tiers — so the tier has to be honest for the layer to exist at all.
                //
                // Advisory because the founder decided on 2026-08-14 that Normal and Power run
                // vision actions silently. An advisory escalation raises `effectiveTier` honestly
                // while leaving the consequence rule's ask-term false, so the session starts without
                // a prompt in Normal and Power, and Safe mode's floor asks anyway. The reason below
                // still reaches the user — on the ran-without-asking trace, which is precisely what
                // that trace is for. What stays *non*-advisory is every individual action the
                // session goes on to take: `VisionSessionContainment` classifies each one, and a
                // destructive or affects-others one asks in every mode.
                CapabilityRiskEscalation(
                    fromTier: .tier2,
                    toTier: .tier3,
                    reason: "Sonny will control \(appName) directly, clicking and typing in its window, and will send redacted screenshots of that window to its vision model.",
                    consequence: .advisory
                )
            ]
        )
    }

    // MARK: - Execute: the loop

    public func execute(
        plan: AgentPlan,
        context: CapabilityExecutionContext,
        log: @escaping (AgentPhase, String) -> Void
    ) async throws -> AgentRunResult {
        let step = try visionStep(in: plan)
        guard let environment = context.visionSession else {
            throw VisionSessionError.visionUnavailable
        }
        guard let bundleIdentifier = step.resolvedBundleIdentifier else {
            throw VisionSessionError.missingTargetApp
        }
        let verdict = ScreenControlPolicy.verdict(
            bundleIdentifier: bundleIdentifier,
            displayName: step.resolvedAppName ?? bundleIdentifier
        )
        // The third door. Same rule, third independent check.
        if let refusal = verdict.refusal {
            throw VisionSessionError.targetNotControllable(refusal)
        }

        let session = VisionSessionRunner(
            goal: try goal(in: step),
            target: verdict,
            environment: environment,
            containment: VisionSessionContainment(
                target: verdict,
                limits: environment.limits,
                attentionMonitor: environment.attentionMonitor
            ),
            log: log
        )
        let outcome = try await session.run()

        return AgentRunResult(
            plan: plan,
            previews: try preview(plan: plan, context: context),
            summary: outcome.summary
        )
    }

    // MARK: - Helpers

    private func visionStep(in plan: AgentPlan) throws -> AgentStep {
        guard let step = plan.steps.first(where: { $0.operation == .visionSession }) else {
            throw AgentExecutionError.invalidPlan("vision_session step is missing.")
        }
        return step
    }

    private func goal(in step: AgentStep) throws -> String {
        let goal = (step.visionGoal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            throw VisionSessionError.missingGoal
        }
        return goal
    }
}
