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
    /// The user pressed Pause on the HUD.
    ///
    /// **A `SessionAttentionState` rather than a separate mechanism**, because it wants exactly the
    /// same behaviour: freeze the loop, capture nothing, synthesize nothing, and wait for an explicit
    /// resume. Sharing the machinery is SONNY-95's own instruction ("shares the session-attention
    /// pause machinery") and it means there is one paused state to reason about rather than two that
    /// have to agree.
    case userPaused = "user_paused"

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
        case .userPaused:
            return "you paused it"
        }
    }
}

public protocol SessionAttentionMonitoring: Sendable {
    func attentionState() async -> SessionAttentionState

    /// Whether a mid-loop approval may be put in front of the user at all (spec §13.1's tier-3
    /// condition: the Mac must be unlocked).
    ///
    /// Narrower than ``attentionState()`` on purpose — an *idle* user can still be shown an approval
    /// and answer it, while a locked screen cannot show one to anybody. Defaulted to the attention
    /// answer so a conformer that has no separate opinion is not forced to invent one, and the
    /// default is the conservative direction.
    func canPresentApproval() async -> Bool
}

public extension SessionAttentionMonitoring {
    func canPresentApproval() async -> Bool {
        await attentionState().isAttended
    }
}

/// The default: always attended.
///
/// Named for what it asserts rather than for being a stub, because it is production-reachable and a
/// reader should be able to see that it makes a claim rather than that it does nothing.
public struct AlwaysAttendedMonitor: SessionAttentionMonitoring {
    public init() {}
    public func attentionState() async -> SessionAttentionState { .attended }
}

/// The user's own Pause, layered over whatever else is watching.
///
/// A wrapper rather than a fourth condition inside `SystemSessionAttentionMonitor`, because the two
/// answer to different things: that one reads the OS, this one reads a button. Composing them keeps
/// each honest about what it knows, and means the HUD's Pause reaches the loop through exactly the
/// path a locked screen does — one paused state, not two that have to agree.
public final class UserPausableAttentionMonitor: SessionAttentionMonitoring, @unchecked Sendable {
    private let base: any SessionAttentionMonitoring
    private let lock = NSLock()
    private var paused = false

    public init(base: any SessionAttentionMonitoring) {
        self.base = base
    }

    public func pause() {
        lock.withLock { paused = true }
    }

    /// Cleared by the resume path, so a resumed session does not immediately re-pause on a stale
    /// flag. The loop re-checks the *base* monitor after a resume regardless, which is what keeps
    /// "resumed while still locked" pausing again.
    public func clearPause() {
        lock.withLock { paused = false }
    }

    public func attentionState() async -> SessionAttentionState {
        if lock.withLock({ paused }) {
            return .userPaused
        }
        return await base.attentionState()
    }

    public func canPresentApproval() async -> Bool {
        // A user who paused is present by definition — pausing is something only someone at the Mac
        // does — so presentability follows the base monitor alone.
        await base.canPresentApproval()
    }
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
    /// The captured window is showing a shell (SONNY-139).
    ///
    /// **A second refusal on the same rule, never a replacement for the first.**
    /// ``ScreenControlPolicy/terminalBundleIdentifiers`` refuses the terminal apps it names and
    /// refuses them first — at three doors and again at the top of every iteration, above this one.
    /// A static bundle comparison cannot be talked out of its answer by anything rendered, while
    /// this reads exactly the surface an attacker controls, so this is layered after the list and
    /// is never a reason to shorten it. What it buys is the ground a name list cannot reach: a
    /// terminal nobody listed, and a shell running *inside* an app that is not a terminal.
    ///
    /// **Ends the session rather than declining the one action**, matching every other case here.
    /// The next capture is one scroll away from the same shell, and the doc comment above already
    /// says why none of these re-prompts. Founder decision 2026-08-16, made conditional on the
    /// capture being scoped to the target app's own window — `SCContentFilter(desktopIndependentWindow:)`,
    /// the only content filter in the repository — so a terminal sitting behind Chrome cannot end a
    /// Chrome session. **Any change that widens the capture invalidates that and must revisit this
    /// case rather than route around it.**
    case screenShowsShell(ShellSurfaceVerdict)
    case targetNotFrontmost(expected: String, actual: String?)
    case attentionLost(SessionAttentionState)
    case actionTypeNotAllowed(String)
    case approvalDeclined(action: String)
    case approvalRefusedByPolicy(action: String)
    case captureSendDeclined
    /// A tier-3 approval came due while the Mac was locked. §13.1's condition, as a refusal: an
    /// approval nobody can see is not an approval, and running without one is not an option.
    case approvalNotPresentable
    /// Control was lost: the Accessibility grant Sonny needs to synthesize input went away
    /// mid-session — System Settings, an MDM push, or an OS re-prompt.
    ///
    /// **The same stop path as a manual emergency stop, deliberately.** §13.5's invariant is "control
    /// was lost, for any reason" — one implementation, distinct reason codes. A revocation that had
    /// its own bespoke teardown would be a second stop path, and the second stop path is always the
    /// one that turns out not to release the mouse button.
    case permissionRevoked

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
        case .screenShowsShell:
            // The same authority reason `ScreenControlRefusal.terminal` gives, said about a window
            // rather than an app — it is the same rule, and a user who met both sentences should
            // recognize them as one. It names the fact that fired and stops; how Sonny knows is not
            // in the product (founder, 2026-08-14: no how-it-works copy in the app). One string for
            // the panel and for the recorded reason, deliberately: a refusal the log describes
            // differently from the panel is a refusal nobody can audit.
            return "Sonny stopped because that window is showing a shell — anything typed into one "
                + "runs with your full account authority, outside every permission Sonny has. This "
                + "is not something you can allow."
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
        case .approvalNotPresentable:
            return "Sonny needed to ask you about a step, and your Mac was locked. It stopped rather than acting without an answer."
        case .permissionRevoked:
            return "Sonny stopped because its permission to control your Mac was turned off. "
                + "Turn Accessibility back on in the Permission Center to use screen control again."
        }
    }

    /// The reason code the transcript records. Stable strings — a user reading a record months later
    /// and a future session grepping for a class both want the same vocabulary.
    public var reasonCode: String {
        switch self {
        case .iterationCapReached: return "iteration_cap_reached"
        case .cancelled: return "user_stopped"
        case .targetIneligible: return "target_ineligible"
        case .screenShowsShell: return "screen_shows_shell"
        case .targetNotFrontmost: return "target_not_frontmost"
        case .attentionLost: return "attention_lost"
        case .actionTypeNotAllowed: return "action_not_allowed"
        case .approvalDeclined: return "approval_declined"
        case .approvalRefusedByPolicy: return "approval_refused"
        case .captureSendDeclined: return "capture_send_declined"
        case .approvalNotPresentable: return "approval_not_presentable"
        case .permissionRevoked: return "permission_revoked"
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
    private let permissionChecker: any ScreenCapturePermissionChecking

    public init(
        target: ScreenControlVerdict,
        limits: VisionSessionLimits = .default,
        policy: RiskApprovalPolicy = .default,
        attentionMonitor: any SessionAttentionMonitoring = AlwaysAttendedMonitor(),
        permissionChecker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker()
    ) {
        self.target = target
        self.limits = limits
        self.policy = policy
        self.attentionMonitor = attentionMonitor
        self.permissionChecker = permissionChecker
    }

    // MARK: Per-iteration boundaries

    /// The checks that run before an iteration does anything at all — before a capture, before a
    /// byte leaves, before a pixel moves.
    ///
    /// Ordered cheapest-and-most-certain first: cancellation, then the iteration cap, then the
    /// Accessibility grant, then attention, then target eligibility, then frontmost. A user who
    /// pressed stop should not have to wait on a frontmost query to find out that they stopped it.
    ///
    /// The two middle checks earn their places for their own reasons, each recorded where it sits
    /// rather than restated here. This sentence used to list four of the six and read as the whole
    /// order (SONNY-123 finding 4); it is a summary of every guard below, and stays one.
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
        // **Polled, because macOS pushes no reliable revocation callback.** Defense in depth rather
        // than the primary mechanism: revoking Accessibility usually kills event synthesis anyway,
        // and the point of noticing is to stop with an honest sentence and a route to fix it rather
        // than to grind out iterations whose clicks silently go nowhere.
        //
        // Ahead of the attention check on purpose: a user who revoked the grant while also being
        // away is owed the actionable reason, not the one that resolves itself when they sit down.
        guard permissionChecker.isAccessibilityTrusted() else {
            return .permissionRevoked
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
        // **Normalized on both sides, at the comparison.** Launch Services treats bundle
        // identifiers case-insensitively, so `com.apple.Safari` and `com.apple.safari` name one app
        // and a raw `==` here would refuse a session for a spelling difference. Normalizing at the
        // comparison rather than storing a normalized identifier on the verdict is deliberate and
        // was learned the hard way: the verdict's identifier is what the loop hands to
        // `SCShareableContent` and `NSRunningApplication`, both of which want the bundle's own
        // casing, so a normalized one found no window and activated nothing.
        guard let frontmost,
              ScreenControlPolicy.normalize(frontmost) == ScreenControlPolicy.normalize(target.bundleIdentifier) else {
            return .targetNotFrontmost(expected: target.displayName, actual: frontmost)
        }
        return nil
    }

    /// The last check before input synthesis: **this kind must be one that drives the machine.**
    ///
    /// **This check was a tautology and is now real** (PR #50 review, F2). It read
    /// `VisionActionKind.allCases.contains(decision.kind)`, which is true for every value of a closed
    /// enum by construction — the whole body could return `nil` with the suite green, and its own doc
    /// comment claimed it "survives someone adding a case to the enum" when `allCases` grows with the
    /// enum and a new case would be auto-allowed. Dead safety code that reads like a guarantee is
    /// worse than no code, and this branch has now met that shape three times.
    ///
    /// **What it guards instead, which is a real invariant with a real failure mode.** The loop
    /// reaches this line only after a `switch` that is supposed to have narrowed to the four
    /// input-synthesizing kinds; `wait`, `done`, `stuck` and `delegate` are handled and `continue`
    /// before it. If that switch is ever edited so a non-synthesizing kind falls through — a `wait`
    /// arm that stops `continue`-ing, a new kind added to the wrong group — the run would try to
    /// synthesize an action for a decision that names none, with coordinates and a target that mean
    /// nothing. This refuses that, and unlike the old body it can actually return non-`nil`.
    ///
    /// It is deliberately *not* a configurable allowlist. SONNY-92 contracted an "allowed action-type
    /// set {click, type, scroll, key, wait}", and the honest reading is that the set is enforced —
    /// by the closed enum, by `VisionDecisionParser` throwing on an unrecognized action, and by the
    /// loop's exhaustive switch — rather than by a knob no caller varies. Adding one would be
    /// speculative generality dressed as a boundary, which is the same mistake in a new coat.
    public func checkActionAllowed(_ decision: VisionDecision) -> VisionContainmentRefusal? {
        guard decision.kind.synthesizesInput else {
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

    /// Whether an approval may be presented right now — §13.1's tier-3 condition.
    ///
    /// Separate from the iteration-start check because it answers a later question: by the time an
    /// action needs approving, the loop has already passed the attention gate, and a screen can lock
    /// in the seconds a model spent deciding.
    public func checkApprovalPresentable() async -> VisionContainmentRefusal? {
        await attentionMonitor.canPresentApproval() ? nil : .approvalNotPresentable
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
        case .delegate:
            return "Whatever Sonny's own tools do is undone the way that action is normally undone."
        case .wait, .done, .stuck:
            return "Nothing to undo."
        }
    }
}
