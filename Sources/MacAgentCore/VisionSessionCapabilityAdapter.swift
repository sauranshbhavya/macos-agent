import CoreGraphics
import Foundation

public enum VisionSessionError: Error, Equatable, LocalizedError {
    case missingGoal
    case missingTargetApp
    case targetAppNotInstalled(String)
    case targetNotControllable(ScreenControlRefusal)
    case visionUnavailable
    case targetAppNotRunning(String)
    /// Screen control's billing gate refused before the session started (SONNY-213).
    ///
    /// **A throw rather than a `VisionSessionOutcome`, because this is the door and not the loop.**
    /// The two refusals already at this door — `targetNotControllable` and `missingTargetApp` —
    /// throw, and the runner does not exist yet, so there is no session to end, no record to close
    /// and no `end(with:)` to route through. Once a session is running the same gate's refusal
    /// arrives as `VisionContainmentRefusal.screenControlUnavailable` instead, which is the graceful
    /// halt; both carry the same `ScreenControlGateRefusal` and therefore the same sentence.
    case screenControlUnavailable(ScreenControlGateRefusal)

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
        case .screenControlUnavailable(let refusal):
            return refusal.userFacingReason
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
        plannerTools: [
            AgentTool(
                operation: .visionSession,
                name: "Control an app by looking at it",
                // **This description is the decomposition, and it is the whole product change
                // SONNY-93 makes.** Before it, a command that was half-expressible in Sonny's own
                // adapters and half not got rejected wholesale: the planner had no word for the
                // remainder, so it either dropped the request or spent it on whichever operation the
                // sentence vaguely fit. Now it emits the supported steps *plus* one vision remainder,
                // and the user sees one plan.
                //
                // Every sentence here reaches the model verbatim
                // (`ToolRegistry.plannerDescription` -> `OpenAIPlanner.systemPrompt`), so the two
                // rules that matter most are stated as rules rather than implied. **Last resort**,
                // because a precise adapter is previewable and gated and this is neither. **Always
                // names its app**, because the spike's own canonical failure was a vision fallback
                // that defaulted to whatever was frontmost and typed shell commands into a live
                // terminal — the product has no frontmost fallback at all, so a plan that names no
                // app fails to a clarification rather than to whatever happens to be in front.
                description: """
                Last resort, for the part of a request Sonny's other tools cannot express. Sonny \
                looks at the named app's window and decides each click and keystroke from what it \
                sees. Prefer any other tool that does the job precisely. Decompose: emit the steps \
                the precise tools can do, then at most ONE vision_session step for the remainder. \
                Always set appName to the app to control — never leave it out and never expect \
                Sonny to use whatever app happens to be in front; if you cannot name one, ask a \
                clarify question instead. Never target a terminal app; Sonny refuses those. Set \
                visionGoal to what should be accomplished in that app, in one sentence.
                """,
                requiredFields: ["appName", "visionGoal"],
                sideEffects: [
                    "Clicks and types inside the named app, as the user would",
                    "Sends redacted screenshots of that app's window to Sonny's vision model"
                ],
                dryRunBehavior: "Describe the app and the goal; take no screenshot and touch nothing.",
                examples: [
                    "send a message to Priya in Discord",
                    "set the theme to dark in Figma"
                ]
            )
        ],
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
            // **Never frontmost.** The name comes from the step, or from an app the plan's own
            // earlier steps put on screen, or from nowhere — and "nowhere" is a clarification, not a
            // fallback. This is the iTerm2 lesson as structure: the spike's vision fallback defaulted
            // to whatever was frontmost and typed shell commands into a live terminal, and the reason
            // that cannot happen here is not a better default, it is that there is no default to
            // misfire. Nothing in this file reads frontmost state; the only frontmost read in the
            // whole vision path is `VisionSessionContainment`'s per-iteration *boundary*, which
            // refuses when the pinned app is not in front rather than adopting whatever is.
            guard let rawName = Self.targetName(for: step, precededBy: Array(resolved.steps[..<index])) else {
                return Self.clarifyPlan(
                    question: "Which app should Sonny control to do that? Name the app and I will work inside it."
                )
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
                //
                // **Row J's per-app question is not here, and that is a decision** (founder,
                // 2026-08-21). It was, briefly: this assessment grew a second escalation saying the
                // app had not been allowed yet, so that the plan-level prompt could carry it. §4.3
                // puts that question *after* the session's first capture instead, because only a
                // capture can reveal a shell in a window whose app no name list refuses — so the
                // sentence moved with the question, into
                // `VisionSessionContainment.appControlRequirement(context:)`. Nothing here reads the
                // standing, and this assessment is byte-identical whatever it is.
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
        guard let bundleIdentifier = step.resolvedBundleIdentifier else {
            throw VisionSessionError.missingTargetApp
        }
        let verdict = ScreenControlPolicy.verdict(
            bundleIdentifier: bundleIdentifier,
            displayName: step.resolvedAppName ?? bundleIdentifier
        )
        // **The third door, and it comes before the availability check on purpose.** Ordered the
        // other way round for one commit, which made the ban conditional on screen control being
        // configured at all — a build with no vision credential refused a terminal for the wrong
        // reason, and would have started refusing for the right one only once someone set the key.
        // A structural deny should not depend on whether the feature it guards is switched on.
        //
        // **That build can no longer exist** (SONNY-131) — the credential is the gateway's, so
        // `context.visionSession` is only ever `nil` for a caller that asked for no vision. The
        // ordering stays, because what it protects is the principle rather than that one build.

        if let refusal = verdict.refusal {
            throw VisionSessionError.targetNotControllable(refusal)
        }
        guard let environment = context.visionSession else {
            throw VisionSessionError.visionUnavailable
        }

        // **The gate, at the session entry, and this is one of its two consult sites** (SONNY-213).
        // The other is the same gate at a step boundary inside `VisionSessionRunner`; there is no
        // third, and no other capability in this product consults it at all.
        //
        // **Here rather than in `resolveDefaultOutputs` or `assessRisk`**, for two reasons that both
        // point the same way. Those two are synchronous and this decision reads the network, so it
        // could not be taken there at all; and this is the last moment before anything happens and
        // the first moment where anything would, so a plan the user never confirms costs no
        // allowance read. It sits below the terminal ban deliberately: a structural deny should not
        // depend on a billing answer, and the third door's own comment a few lines up says why that
        // ordering is a principle rather than a convenience.
        if case .refused(let refusal) = await environment.screenControlGate.decide(at: .sessionStart) {
            throw VisionSessionError.screenControlUnavailable(refusal)
        }

        let session = VisionSessionRunner(
            goal: try goal(in: step),
            target: verdict,
            environment: environment,
            containment: VisionSessionContainment(
                target: verdict,
                limits: environment.limits,
                attentionMonitor: environment.attentionMonitor,
                permissionChecker: environment.permissionChecker
            ),
            log: log
        )
        let outcome = try await session.run()

        return AgentRunResult(
            plan: plan,
            previews: try preview(plan: plan, context: context),
            summary: outcome.summary,
            // **The one model-authored run summary in the product** (SONNY-147). This text is
            // whatever the model wrote after looking at the user's screen, and the session prompt
            // actively asks it to describe what it saw — so an injection attempt's designed
            // response is to be transcribed into exactly this string. Declared here, at the only
            // place that knows, and carried from here to storage.
            summaryProvenance: .modelAuthored
        )
    }

    // MARK: - Helpers

    /// Which app this vision step means: its own `appName`, or the app the plan's own earlier steps
    /// put on screen. `nil` when neither answers, which is a clarification.
    ///
    /// **Only the plan's own steps, and only ones that actually surface an app.** A mixed plan like
    /// "open Notes, then write my standup there" is the case this exists for: the planner names the
    /// app once, in the step that opens it, and repeating it on the remainder would be a second place
    /// for the two to disagree. Reading anything *outside* the plan — the frontmost app, the last
    /// task's app, a running-app list — would be a fallback, and this capability has none.
    static func targetName(for step: AgentStep, precededBy earlier: [AgentStep]) -> String? {
        if let named = step.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            return named
        }
        // Last one wins: with "open Notes, open Safari, then do X", X happens in Safari.
        for earlierStep in earlier.reversed() {
            switch earlierStep.operation {
            case .openApp, .switchRunningApp:
                if let name = earlierStep.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    return name
                }
            default:
                // Exhaustive by omission is fine here and an exhaustive switch would be worse: the
                // question is not "what does every operation do" but "which operations put a *named*
                // app on screen", and only these two do. `open_workspace` opens several at once and
                // names none of them in the step, so it cannot answer this question — a plan that
                // opens a workspace and then wants a vision remainder has to name the app.
                continue
            }
        }
        return nil
    }

    static func clarifyPlan(question: String) -> AgentPlan {
        AgentPlan(
            summary: "Clarification needed.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "clarify-vision-target",
                    operation: .clarify,
                    description: "Ask which app to control.",
                    question: question
                )
            ]
        )
    }

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
