import CoreGraphics
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-92: the containment layer, one check at a time.
///
/// Each per-iteration boundary gets its own test that fails for its own reason. A single
/// "everything is fine" assertion would pass just as happily with three of the four checks deleted,
/// which is exactly the shape a mutation battery is supposed to catch and a reader is supposed to be
/// able to read.
@Suite
struct VisionSessionContainmentTests {
    // MARK: - Fixtures

    private static let safari = InstalledApp(
        displayName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )

    private static func containment(
        limits: VisionSessionLimits = .default,
        attention: SessionAttentionState = .attended
    ) -> VisionSessionContainment {
        VisionSessionContainment(
            target: ScreenControlPolicy.verdict(for: safari),
            limits: limits,
            attentionMonitor: FixedAttentionMonitor(attention)
        )
    }

    private struct FixedAttentionMonitor: SessionAttentionMonitoring {
        let state: SessionAttentionState
        init(_ state: SessionAttentionState) { self.state = state }
        func attentionState() async -> SessionAttentionState { state }
    }

    private static func frontmost(_ identifier: String?) -> @Sendable () async -> String? {
        { identifier }
    }

    // MARK: - Per-iteration boundaries, individually

    @Test
    func anIterationInsideEveryBoundaryIsAllowed() async {
        let refusal = await Self.containment().checkIterationStart(
            iteration: 1,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
        )
        #expect(refusal == nil)
    }

    @Test
    func cancellationRefusesBeforeAnythingElseIsEvenAsked() async {
        // Deliberately set up so that *every other* boundary would also refuse: the iteration is
        // over the cap, the user is away, and the wrong app is in front. Cancellation still has to
        // be the answer, because a user who pressed stop is owed "Stopped." and not a lecture about
        // their screen lock.
        let refusal = await Self.containment(
            limits: VisionSessionLimits(maximumIterations: 1, settleNanoseconds: 0),
            attention: .screenLocked
        ).checkIterationStart(
            iteration: 99,
            isCancelled: true,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Notes")
        )
        #expect(refusal == .cancelled)
    }

    @Test
    func theIterationCapRefusesTheIterationAfterTheLastAllowedOne() async {
        let containment = Self.containment(limits: VisionSessionLimits(maximumIterations: 3, settleNanoseconds: 0))

        for iteration in 1...3 {
            let refusal = await containment.checkIterationStart(
                iteration: iteration,
                isCancelled: false,
                frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
            )
            #expect(refusal == nil, "iteration \(iteration) is within the cap")
        }
        let overCap = await containment.checkIterationStart(
            iteration: 4,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
        )
        #expect(overCap == .iterationCapReached(cap: 3))
    }

    /// Every non-attended state pauses, and the copy names which one — a user whose Mac locked and a
    /// user who walked away are owed different sentences.
    @Test
    func everyNonAttendedStateRefusesAndSaysWhich() async {
        for state in [SessionAttentionState.screenLocked, .displayAsleep, .userIdle] {
            let refusal = await Self.containment(attention: state).checkIterationStart(
                iteration: 1,
                isCancelled: false,
                frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
            )
            #expect(refusal == .attentionLost(state), "\(state)")
            #expect(refusal?.reasonCode == "attention_lost", "\(state)")
            #expect(refusal?.userFacingReason.contains(state.userFacingReason) == true, "\(state)")
        }
    }

    /// The pinned-app frontmost boundary. Sonny will not click into a window it did not look at.
    @Test
    func anotherAppBeingFrontmostRefuses() async {
        let refusal = await Self.containment().checkIterationStart(
            iteration: 2,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Notes")
        )
        #expect(refusal == .targetNotFrontmost(expected: "Safari", actual: "com.apple.Notes"))
    }

    /// Nothing frontmost at all is still not the target.
    @Test
    func nothingBeingFrontmostRefuses() async {
        let refusal = await Self.containment().checkIterationStart(
            iteration: 2,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost(nil)
        )
        #expect(refusal == .targetNotFrontmost(expected: "Safari", actual: nil))
    }

    /// **The terminal ban, re-asked every iteration.** The rule is static, but which app a session is
    /// pointed at is a fact carried through a long-running loop, and a check that only ran at resolve
    /// could not notice a pin being wrong.
    @Test
    func aTerminalTargetRefusesAtEveryIterationNotJustTheFirst() async {
        let terminal = InstalledApp(
            displayName: "Terminal",
            bundleIdentifier: "com.apple.Terminal",
            applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        )
        let containment = VisionSessionContainment(target: ScreenControlPolicy.verdict(for: terminal))

        for iteration in [1, 2, 7] {
            let refusal = await containment.checkIterationStart(
                iteration: iteration,
                isCancelled: false,
                // Frontmost *is* the target here, so nothing but the ban can be what refuses.
                frontmostBundleIdentifier: Self.frontmost("com.apple.Terminal")
            )
            #expect(refusal == .targetIneligible(.terminal), "iteration \(iteration)")
        }
    }

    /// Ordering, pinned as its own property rather than inferred from the tests above.
    ///
    /// Attention is checked before eligibility and eligibility before frontmost, so a locked Mac
    /// reports a locked Mac even when the target is also wrong. Without this the user gets whichever
    /// refusal the implementation happens to reach first, and that ordering would be free to change
    /// silently.
    @Test
    func attentionIsReportedAheadOfAWrongFrontmostApp() async {
        let refusal = await Self.containment(attention: .screenLocked).checkIterationStart(
            iteration: 1,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Notes")
        )
        #expect(refusal == .attentionLost(.screenLocked))
    }

    // MARK: - Every refusal is legible

    /// **The §13.5 reason taxonomy, pinned as a whole** (SONNY-95).
    ///
    /// Every way a session can end has its own code and its own sentence, and the codes are
    /// distinct — a record that said `user_stopped` for a revoked permission would be a record that
    /// misleads whoever reads it months later. Listed exhaustively rather than sampled, and the
    /// count is asserted, so a new ending has to come here and choose a code rather than silently
    /// borrowing one.
    @Test
    func everyRefusalCarriesADistinctReasonCodeAndANonEmptySentence() {
        let refusals: [VisionContainmentRefusal] = [
            .iterationCapReached(cap: 12),
            .cancelled,
            .targetIneligible(.terminal),
            .targetNotFrontmost(expected: "Safari", actual: "Notes"),
            .attentionLost(.screenLocked),
            .actionTypeNotAllowed("launch_missiles"),
            .approvalDeclined(action: "Click Delete"),
            .approvalRefusedByPolicy(action: "Click Send"),
            .captureSendDeclined,
            .approvalNotPresentable,
            .permissionRevoked
        ]
        #expect(refusals.count == 11)

        // The two §13.5 names the spec calls out by hand, so a rename fails here rather than in a
        // record nobody reads until they need it.
        #expect(VisionContainmentRefusal.cancelled.reasonCode == "user_stopped")
        #expect(VisionContainmentRefusal.permissionRevoked.reasonCode == "permission_revoked")

        // Control lost for any reason is one invariant with distinct codes — the codes differ, the
        // handling does not.
        #expect(VisionContainmentRefusal.permissionRevoked.reasonCode != VisionContainmentRefusal.cancelled.reasonCode)
        #expect(VisionContainmentRefusal.permissionRevoked.userFacingReason.contains("Permission Center"))

        // Every attention state contributes its own sentence to the pause copy, so a paused session
        // never says the wrong reason.
        for state in [SessionAttentionState.screenLocked, .displayAsleep, .userIdle, .userPaused] {
            #expect(
                VisionContainmentRefusal.attentionLost(state).userFacingReason.contains(state.userFacingReason),
                "\(state)"
            )
        }
        let codes = refusals.map(\.reasonCode)
        #expect(Set(codes).count == codes.count, "reason codes must be distinct: \(codes)")
        for refusal in refusals {
            #expect(!refusal.userFacingReason.isEmpty, "\(refusal)")
            #expect(!refusal.reasonCode.isEmpty, "\(refusal)")
        }
    }

    // MARK: - The engine gate

    private static func decision(
        _ kind: VisionActionKind,
        target: String = "OK",
        declared: CapabilityRiskEscalation.Consequence? = .advisory,
        text: String? = nil
    ) -> VisionDecision {
        VisionDecision(kind: kind, x: 10, y: 10, text: text, target: target, declaredConsequence: declared)
    }

    /// **Founder decision 2, as behavior.** Normal and Power run an ordinary action silently; Safe
    /// asks about it. Asserted over the real `AgentInteractionMode` mapping, not over a hand-written
    /// boolean, so the two cannot drift.
    @Test
    func anOrdinaryActionAutoRunsInNormalAndPowerAndAsksInSafe() {
        let containment = Self.containment()
        let ordinary = Self.decision(.click, target: "Bookmarks")

        for mode in AgentInteractionMode.allCases {
            let (assessment, requirement) = containment.requirement(
                for: ordinary,
                context: ApprovalContext(safeMode: mode.asksBeforeEveryAction)
            )
            #expect(assessment.effectiveTier == .tier1, "\(mode)")
            #expect(assessment.escalations.isEmpty, "\(mode)")
            #expect(requirement == (mode == .safe ? .explicitApproval : .autoRun), "\(mode)")
        }
    }

    /// **The standing consequence rule, in every mode including Power.** A destructive or
    /// affects-others action asks — Safe, Normal and Power alike. This is the property the founder
    /// kept when they made screen control silent, so it is asserted across the whole mode set rather
    /// than on the interesting one.
    @Test
    func destructiveAndAffectsOthersActionsAskInAllThreeModes() {
        let containment = Self.containment()
        let cases: [(VisionDecision, CapabilityRiskEscalation.Consequence)] = [
            (Self.decision(.click, target: "Delete"), .destructive),
            (Self.decision(.click, target: "Send"), .affectsOthers),
            (Self.decision(.click, target: "OK", declared: .destructive), .destructive),
            (Self.decision(.click, target: "OK", declared: .affectsOthers), .affectsOthers)
        ]

        for (decision, expectedClass) in cases {
            for mode in AgentInteractionMode.allCases {
                let (assessment, requirement) = containment.requirement(
                    for: decision,
                    context: ApprovalContext(safeMode: mode.asksBeforeEveryAction)
                )
                #expect(assessment.effectiveTier == .tier3, "\(decision.target)/\(mode)")
                #expect(assessment.escalations.map(\.consequence) == [expectedClass], "\(decision.target)/\(mode)")
                #expect(requirement == .explicitApproval, "\(decision.target)/\(mode)")
                #expect(requirement.requiresUserApproval, "\(decision.target)/\(mode)")
            }
        }
    }

    /// The assessment never carries a tier-3 *default*, only a tier-3 *effective* tier reached by
    /// escalation.
    ///
    /// `RiskApprovalConsent.Coverage` reasons from "no `defaultTier` anywhere reaches tier 3" to
    /// prove that a tier-3 assessment always carries at least one reason. Row I is the newest place
    /// that could break it, so it is pinned here rather than left to the sweep in that comment.
    @Test
    func theDefaultTierNeverReachesTierThreeAndEveryTierThreeCarriesAReason() {
        let containment = Self.containment()
        for kind in VisionActionKind.allCases {
            for target in ["OK", "Delete", "Send"] {
                let assessment = containment.assessment(for: Self.decision(kind, target: target))
                #expect(assessment.defaultTier.rawValue < CapabilityRiskTier.tier3.rawValue, "\(kind)/\(target)")
                if assessment.effectiveTier == .tier3 {
                    #expect(!assessment.escalations.isEmpty, "\(kind)/\(target)")
                }
            }
        }
    }

    /// The escalation sentence names the *evidence*, and which evidence fired.
    ///
    /// "the control it is aiming at is labelled Delete" is something the user can check by looking at
    /// their own screen; "the model reports…" is not. A user who can tell the two apart can tell a
    /// cautious model from a dangerous button.
    @Test
    func theEscalationSentenceNamesWhichEvidenceFired() {
        let containment = Self.containment()

        let fromLabel = containment.escalationReason(
            for: Self.decision(.click, target: "Delete", declared: .advisory),
            consequence: .destructive
        )
        #expect(fromLabel.contains("labelled"))
        #expect(fromLabel.contains("Delete"))

        let fromModel = containment.escalationReason(
            for: Self.decision(.click, target: "Continue", declared: .destructive),
            consequence: .destructive
        )
        #expect(fromModel.contains("the model reports"))
        #expect(!fromModel.contains("labelled"))
    }

    /// The action-type allowlist accepts exactly the closed vocabulary and nothing else.
    @Test
    func everyDeclaredActionKindIsAllowed() {
        let containment = Self.containment()
        for kind in VisionActionKind.allCases {
            #expect(containment.checkActionAllowed(Self.decision(kind)) == nil, "\(kind)")
        }
    }
}
