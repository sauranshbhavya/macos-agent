import CoreGraphics
import Foundation

// MARK: - Attention

/// Whether a human is present at the machine.
///
/// The seam SONNY-94 fills in. Screen control needs a present human — not as an accuracy hedge, but
/// as an authority requirement: the user's continued presence is what makes the run attended, and
/// "attended" is the whole basis on which a program is allowed to move their cursor. The default
/// conformer below answers "present" unconditionally, which is correct *only* because the paths that
/// could be unattended are barred three other ways (scheduled-path refusal, the `.approved(.tier2)`
/// ceiling, and `StoredRoutine.forbiddenStepOperations`).
public enum SessionAttentionState: String, Equatable, Sendable {
    case attended
    case screenLocked = "screen_locked"
    case displayAsleep = "display_asleep"
    case userIdle = "user_idle"

    public var isAttended: Bool { self == .attended }

    public var userFacingReason: String {
        switch self {
        case .attended:
            return "You are at the Mac."
        case .screenLocked:
            return "your Mac was locked"
        case .displayAsleep:
            return "your display went to sleep"
        case .userIdle:
            return "you have been away for a while"
        }
    }
}

public protocol SessionAttentionMonitoring: Sendable {
    func attentionState() async -> SessionAttentionState
}

/// The default: always attended.
///
/// Named for what it asserts rather than for being a stub, because it is production-reachable and a
/// reader should be able to see that it makes a claim rather than that it does nothing.
public struct AlwaysAttendedMonitor: SessionAttentionMonitoring {
    public init() {}
    public func attentionState() async -> SessionAttentionState { .attended }
}

// MARK: - Refusals

/// Why the containment layer stopped a session, or declined one action within it.
///
/// **A containment refusal never re-prompts.** Each of these is a fact about the world that a human
/// answering a question cannot change — the cap is reached, the app is not in front, the user
/// stopped the run, the target is a terminal. Offering an "allow anyway" here would convert a
/// structural boundary into a dialog, which is the shape every one of these checks exists to avoid.
public enum VisionContainmentRefusal: Equatable, Sendable {
    case iterationCapReached(cap: Int)
    case cancelled
    case targetIneligible(ScreenControlRefusal)
    case targetNotFrontmost(expected: String, actual: String?)
    case attentionLost(SessionAttentionState)
    case actionTypeNotAllowed(String)
    case approvalDeclined(action: String)
    case approvalRefusedByPolicy(action: String)
    case captureSendDeclined

    /// The sentence the run summary and the transcript carry. Honest about which boundary fired —
    /// "Sonny stopped because you locked your Mac" and "Sonny stopped because it ran out of steps"
    /// are different facts and the user is owed the right one.
    public var userFacingReason: String {
        switch self {
        case .iterationCapReached(let cap):
            return "Sonny stopped after \(cap) steps without finishing. Nothing further was done."
        case .cancelled:
            return "Stopped."
        case .targetIneligible(let refusal):
            return refusal.userFacingReason
        case .targetNotFrontmost(let expected, let actual):
            let actualName = actual.map { "\($0) is" } ?? "something else is"
            return "Sonny stopped because \(expected) is no longer the app in front — \(actualName). "
                + "It will not click into a window it did not look at."
        case .attentionLost(let state):
            return "Sonny paused because \(state.userFacingReason). Screen control only runs while you are here."
        case .actionTypeNotAllowed(let action):
            return "Sonny stopped because the model asked for an action it is not allowed to take: \(action)."
        case .approvalDeclined(let action):
            return "You declined: \(action)."
        case .approvalRefusedByPolicy(let action):
            return "Sonny refused this action under the current approval policy: \(action)."
        case .captureSendDeclined:
            return "You chose not to send this screenshot, so the session stopped."
        }
    }

    /// The reason code the transcript records. Stable strings — a user reading a record months later
    /// and a future session grepping for a class both want the same vocabulary.
    public var reasonCode: String {
        switch self {
        case .iterationCapReached: return "iteration_cap_reached"
        case .cancelled: return "user_stopped"
        case .targetIneligible: return "target_ineligible"
        case .targetNotFrontmost: return "target_not_frontmost"
        case .attentionLost: return "attention_lost"
        case .actionTypeNotAllowed: return "action_not_allowed"
        case .approvalDeclined: return "approval_declined"
        case .approvalRefusedByPolicy: return "approval_refused"
        case .captureSendDeclined: return "capture_send_declined"
        }
    }
}

// MARK: - Configuration

public struct VisionSessionLimits: Equatable, Sendable {
    /// How many capture-decide-act cycles one session may run.
    ///
    /// **A containment invariant, not a product surface** (C10). It is not configurable, there is no
    /// "keep going" affordance, and reaching it is a plain stop with an honest sentence. Twelve
    /// rather than the experiment's ten only because the production loop spends iterations on
    /// approvals that the experiment's did not.
    public var maximumIterations: Int
    /// How long to let the screen settle after activating the app or acting, before capturing.
    public var settleNanoseconds: UInt64

    public static let `default` = VisionSessionLimits(
        maximumIterations: 12,
        settleNanoseconds: 800_000_000
    )

    public init(maximumIterations: Int, settleNanoseconds: UInt64) {
        self.maximumIterations = maximumIterations
        self.settleNanoseconds = settleNanoseconds
    }
}

// MARK: - The containment layer

/// Every check that stands between a model's suggestion and a real input event.
///
/// **Engine code, deliberately.** This is `MacAgentCore`, it holds no UI state, and the approval
/// question it asks goes through `RiskApprovalPolicy.requirement(for:context:)` — the one public
/// path to a requirement that every other capability uses. E13's instruction was "through the
/// engine, never around it", and this type is what that means concretely: the loop above it never
/// decides whether an action may run, it only asks this, and this only asks the engine.
///
/// Each check is separable and individually testable on purpose. A single `guard everythingIsFine`
/// would pass the same tests and tell a future reader nothing about which boundary they were about
/// to weaken.
public struct VisionSessionContainment: Sendable {
    public let limits: VisionSessionLimits
    public let target: ScreenControlVerdict
    private let policy: RiskApprovalPolicy
    private let attentionMonitor: any SessionAttentionMonitoring

    public init(
        target: ScreenControlVerdict,
        limits: VisionSessionLimits = .default,
        policy: RiskApprovalPolicy = .default,
        attentionMonitor: any SessionAttentionMonitoring = AlwaysAttendedMonitor()
    ) {
        self.target = target
        self.limits = limits
        self.policy = policy
        self.attentionMonitor = attentionMonitor
    }

    // MARK: Per-iteration boundaries

    /// The checks that run before an iteration does anything at all — before a capture, before a
    /// byte leaves, before a pixel moves.
    ///
    /// Ordered cheapest-and-most-certain first. Cancellation before attention before eligibility
    /// before frontmost: a user who pressed stop should not have to wait on a frontmost query to
    /// find out that they stopped it.
    public func checkIterationStart(
        iteration: Int,
        isCancelled: Bool,
        frontmostBundleIdentifier: @Sendable () async -> String?
    ) async -> VisionContainmentRefusal? {
        if isCancelled {
            return .cancelled
        }
        guard iteration <= limits.maximumIterations else {
            return .iterationCapReached(cap: limits.maximumIterations)
        }
        let attention = await attentionMonitor.attentionState()
        guard attention.isAttended else {
            return .attentionLost(attention)
        }
        // Re-asked every iteration rather than trusted from resolve. The rule is static, but which
        // app this session is pointed at is a fact carried through a long-running loop, and a check
        // that only ran once is a check that cannot notice a pin being wrong.
        if let refusal = target.refusal {
            return .targetIneligible(refusal)
        }
        let frontmost = await frontmostBundleIdentifier()
        // **Normalized on both sides.** `ScreenControlVerdict.bundleIdentifier` is the normalized
        // (lowercased, trimmed) spelling, because that is what the deny-list comparison used, while
        // the OS hands back the bundle's own casing — `com.apple.Safari`. Comparing the two raw was
        // a real defect for one commit: the check could never pass on a real machine, so no vision
        // session would ever have got past its first iteration. Caught by
        // `VisionSessionContainmentTests.anIterationInsideEveryBoundaryIsAllowed`, which is the
        // happy-path test, which is why it was worth writing one.
        guard let frontmost,
              ScreenControlPolicy.normalize(frontmost) == target.bundleIdentifier else {
            return .targetNotFrontmost(expected: target.displayName, actual: frontmost)
        }
        return nil
    }

    /// The action-type allowlist.
    ///
    /// Redundant with `VisionActionKind` being a closed enum, and kept anyway: the enum stops a model
    /// naming an unknown verb, while this stops a *known* verb being used by a session that should
    /// not have it. They fail differently and the second one is the one that survives someone adding
    /// a case to the enum.
    public func checkActionAllowed(_ decision: VisionDecision) -> VisionContainmentRefusal? {
        guard VisionActionKind.allCases.contains(decision.kind) else {
            return .actionTypeNotAllowed(decision.kind.rawValue)
        }
        return nil
    }

    // MARK: The engine gate, mid-loop

    /// The assessment for one pending action.
    ///
    /// Built here rather than by the loop so the escalation's consequence class comes from
    /// ``VisionConsequenceClassifier`` every time — the loop cannot choose to skip it, and a future
    /// caller cannot construct an assessment that quietly classifies everything advisory.
    ///
    /// `defaultTier` is `.tier1`: a click or a keystroke inside an app the user asked Sonny to
    /// operate is low-impact by itself. What makes an action serious is what the *control* does, and
    /// that arrives as an escalation to tier 3 — the honest shape, and the one that keeps
    /// `effectiveTier` a true severity signal for the gates that read it.
    public func assessment(for decision: VisionDecision) -> CapabilityRiskAssessment {
        let consequence = VisionConsequenceClassifier.consequence(for: decision)
        guard consequence.asksFirst else {
            return CapabilityRiskAssessment(
                defaultTier: .tier1,
                approvalCopy: approvalCopy(for: decision, consequence: consequence)
            )
        }
        return CapabilityRiskAssessment(
            defaultTier: .tier1,
            approvalCopy: approvalCopy(for: decision, consequence: consequence),
            escalations: [
                CapabilityRiskEscalation(
                    fromTier: .tier1,
                    toTier: .tier3,
                    reason: escalationReason(for: decision, consequence: consequence),
                    consequence: consequence
                )
            ]
        )
    }

    /// The requirement for a pending action, under this run's authority context.
    ///
    /// One line, and it is the whole point of the file. Safe mode's floor makes this
    /// `.explicitApproval` for every action that can run — which is founder decision 2's "Safe asks
    /// before every vision action", falling out of the shipped engine rather than needing a rule of
    /// its own. Normal and Power reach the consequence rule, so an ordinary action is `.autoRun` and
    /// a destructive or affects-others one is `.explicitApproval` — in every mode, mid-loop
    /// included, which is the standing rule the founder kept when they made screen control silent.
    public func requirement(
        for decision: VisionDecision,
        context: ApprovalContext
    ) -> (assessment: CapabilityRiskAssessment, requirement: RiskApprovalRequirement) {
        let assessment = assessment(for: decision)
        return (assessment, policy.requirement(for: assessment, context: context))
    }

    private func approvalCopy(
        for decision: VisionDecision,
        consequence: CapabilityRiskEscalation.Consequence
    ) -> RiskApprovalCopy {
        RiskApprovalCopy(
            actionDescription: "\(decision.actionDescription) in \(target.displayName)",
            riskReason: escalationReason(for: decision, consequence: consequence),
            involvedResource: target.displayName,
            // A synthesized click sends nothing anywhere by itself. The screenshot that *led* to it
            // did, and that is disclosed on the session envelope — not re-asserted per action, where
            // it would describe the wrong event.
            dataLeavesDevice: false,
            undoDescription: undoDescription(for: decision)
        )
    }

    /// Why this action is being asked about, in the user's terms — and, when the local evidence is
    /// what fired, saying so.
    ///
    /// Naming the source matters: "the control is labelled Delete" is something the user can verify
    /// by looking at their own screen, while "the model believes this is destructive" is not. A user
    /// who can tell the two apart can tell a cautious model from a dangerous button.
    func escalationReason(
        for decision: VisionDecision,
        consequence: CapabilityRiskEscalation.Consequence
    ) -> String {
        switch consequence {
        case .advisory:
            return "Sonny is controlling \(target.displayName) directly, by clicking and typing in its window."
        case .destructive, .affectsOthers:
            let noun = consequence == .destructive
                ? "destroy or replace something you already have"
                : "reach someone other than you"
            let fromLabel = VisionConsequenceClassifier.labelConsequence(decision) == consequence
            let evidence = fromLabel
                ? "the control it is aiming at is labelled \u{201C}\(decision.target)\u{201D}"
                : "the model reports that this action would \(noun)"
            return "This action could \(noun) — \(evidence)."
        }
    }

    private func undoDescription(for decision: VisionDecision) -> String {
        switch decision.kind {
        case .type:
            return "Sonny cannot undo typing. \(target.displayName)'s own undo may be able to."
        case .click, .key, .scroll:
            return "Sonny cannot undo this. Whatever \(target.displayName) does in response is up to \(target.displayName)."
        case .wait, .done, .stuck:
            return "Nothing to undo."
        }
    }
}
