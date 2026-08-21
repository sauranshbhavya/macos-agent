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

    private static let terminal = InstalledApp(
        displayName: "Terminal",
        bundleIdentifier: "com.apple.Terminal",
        applicationURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    )

    /// **The only place this file builds a containment** (SONNY-103), so that no test can fall back
    /// to a default seam by forgetting to pass one. Every input the containment reads — the target,
    /// the cap, attention, and the Accessibility grant — is stated here as a value, and not one of
    /// them is read from the machine running the suite.
    ///
    /// **What that seam cost when it was open, kept because it is the reason this helper exists.**
    /// `VisionSessionContainment` defaults its checker to `SystemScreenCapturePermissionChecker`,
    /// which answers `AXIsProcessTrusted()` — a fact about whichever process happens to be running
    /// the suite. macOS grants Accessibility per responsible process, so one unchanged tree passed
    /// from the founder's terminal and failed 22 issues from an agent session's, every one of them
    /// `.permissionRevoked` returned before the boundary the test was written to pin. (Measured at
    /// main `9a84e3b`: 1203 tests / 90 suites / 22 issues from a process where `AXIsProcessTrusted()`
    /// answered false, against 1203 / 90 / exit 0 from one where it answered true.) A suite whose
    /// result depends on machine state is not evidence — and this one failed in the flattering
    /// direction as well, because a defect that made the containment refuse everything would have
    /// looked exactly like a missing grant.
    ///
    /// The screen-recording grant is left at the stub's default rather than tracking
    /// `accessibilityTrusted`: `checkIterationStart` asks `isAccessibilityTrusted()` and nothing
    /// else, so a second axis here would suggest a question the containment never asks.
    private static func containment(
        target: InstalledApp = safari,
        limits: VisionSessionLimits = .default,
        attention: SessionAttentionState = .attended,
        accessibilityTrusted: Bool = true
    ) -> VisionSessionContainment {
        VisionSessionContainment(
            target: ScreenControlPolicy.verdict(for: target),
            limits: limits,
            attentionMonitor: FixedAttentionMonitor(attention),
            permissionChecker: DeterministicScreenPermissions(accessibilityTrusted: accessibilityTrusted)
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
        let containment = Self.containment(target: Self.terminal)

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

    // MARK: - The Accessibility grant, in both directions

    /// **The revoked-grant branch, stated on purpose rather than arrived at by accident**
    /// (SONNY-103).
    ///
    /// Every other test in this file states the grant as held, because each is written to reach a
    /// later boundary. Stubbing it trusted everywhere and stopping there would leave this branch
    /// unexercised — the same hole moved rather than closed — so the refusing direction gets its own
    /// test, asserted against the very call the allowing direction makes.
    @Test
    func aRevokedAccessibilityGrantRefusesTheIterationAndAHeldGrantDoesNot() async {
        let revoked = await Self.containment(accessibilityTrusted: false).checkIterationStart(
            iteration: 1,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
        )
        #expect(revoked == .permissionRevoked)

        // Identical inputs, grant held: the boundary list runs to the end and allows the iteration.
        // The two answers differing is what shows the containment reads the injected value rather
        // than this Mac's TCC state, and neither half can pass vacuously while the other holds.
        let held = await Self.containment(accessibilityTrusted: true).checkIterationStart(
            iteration: 1,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Safari")
        )
        #expect(held == nil)
    }

    /// Where the revocation check sits in the order — claimed by the production comment, pinned by
    /// nothing until now.
    ///
    /// Ahead of attention, eligibility and frontmost: a user who revoked the grant while also being
    /// away is owed the reason they can act on, not the one that resolves itself when they sit back
    /// down. Behind cancellation, which stays the answer for anyone who pressed stop.
    @Test
    func aRevokedGrantOutranksAttentionAndTheTargetChecksButNotCancellation() async {
        // Every later boundary would refuse too — away from the Mac, a banned target, and the wrong
        // app in front — so the ordering alone decides what comes back.
        let containment = Self.containment(
            target: Self.terminal,
            attention: .screenLocked,
            accessibilityTrusted: false
        )

        let running = await containment.checkIterationStart(
            iteration: 1,
            isCancelled: false,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Notes")
        )
        #expect(running == .permissionRevoked)

        let stopped = await containment.checkIterationStart(
            iteration: 1,
            isCancelled: true,
            frontmostBundleIdentifier: Self.frontmost("com.apple.Notes")
        )
        #expect(stopped == .cancelled)
    }

    // MARK: - Every refusal is legible

    /// **The §13.5 reason taxonomy, pinned as a whole** (SONNY-95).
    ///
    /// Every way a session can end has its own code and its own sentence, and the codes are
    /// distinct — a record that said `user_stopped` for a revoked permission would be a record that
    /// misleads whoever reads it months later. Listed exhaustively rather than sampled, and the
    /// count is asserted, so a new ending has to come here and choose a code rather than silently
    /// borrowing one.
    ///
    /// **That last sentence was a promise this test could not keep, and it took two rounds to make
    /// it true** (SONNY-139, PR #57 F5).
    ///
    /// Round one: the list was hand-written, so `screenShowsShell` was added to the enum and this
    /// test stayed green — "exhaustively" was true of how the list had been *typed* and not of
    /// anything enforced. ``expectedReasonCode(for:)`` was added, an exhaustive `switch`, so a new
    /// case fails to compile here. Round two, the reviewer's finding: that forces the author into
    /// this file but not into the *array*. A new case could be given a `switch` arm and never a
    /// sample, and then its distinct-code and non-empty-sentence assertions would simply never run,
    /// with a literal `== 12` still passing.
    ///
    /// Closed by ``Sample``, which is `CaseIterable` because it carries no associated values. The
    /// array is built from `Sample.allCases`, so there is no hand-written list and no literal count;
    /// ``expectedReasonCode(for:)`` maps the real enum back to a `Sample`, so a new refusal case
    /// fails to compile until it has one; and ``sample(_:)`` maps each `Sample` to a value, so a new
    /// `Sample` fails to compile until it has a refusal. Neither direction can be satisfied without
    /// the other. Same family as `identifierProducing(_:)` in `ScreenControlEligibilityTests`.
    @Test
    func everyRefusalCarriesADistinctReasonCodeAndANonEmptySentence() {
        let refusals = Sample.allCases.map(Self.sample)
        // Not a literal: the count is whatever the enum has, and the mapping below is what forces a
        // new case to appear here at all.
        #expect(refusals.count == Sample.allCases.count)
        #expect(Set(refusals.map { Self.expectedReasonCode(for: $0) }).count == Sample.allCases.count)
        for refusal in refusals {
            #expect(refusal.reasonCode == Self.expectedReasonCode(for: refusal).rawValue)
        }

        // **The two refusals that both mean "this is a shell" stay distinguishable.** The static
        // deny list and the screen check enforce one rule at two different doors, and a record that
        // could not tell them apart could not say which one held. Different codes, different
        // sentences, and both say the thing that makes the rule categorical.
        let byName = Self.sample(.targetIneligible)
        let byScreen = Self.sample(.screenShowsShell)
        #expect(byName.reasonCode != byScreen.reasonCode)
        #expect(byName.userFacingReason != byScreen.userFacingReason)
        #expect(byName.userFacingReason.contains("This is not something you can allow."))
        #expect(byScreen.userFacingReason.contains("This is not something you can allow."))

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

    /// One tag per `VisionContainmentRefusal` case, with the reason code that case must carry.
    ///
    /// `CaseIterable` is the whole point and is only possible because these carry no associated
    /// values — which is exactly why the real enum cannot be `CaseIterable` and needs this stand-in.
    /// The raw values are the second, independent copy of the reason codes: production changing one
    /// without anyone deciding to makes the two disagree.
    private enum Sample: String, CaseIterable {
        case iterationCapReached = "iteration_cap_reached"
        case cancelled = "user_stopped"
        case targetIneligible = "target_ineligible"
        case screenShowsShell = "screen_shows_shell"
        case appControlWithdrawn = "app_control_withdrawn"
        case targetNotFrontmost = "target_not_frontmost"
        case attentionLost = "attention_lost"
        case actionTypeNotAllowed = "action_not_allowed"
        case approvalDeclined = "approval_declined"
        case approvalRefusedByPolicy = "approval_refused"
        case captureSendDeclined = "capture_send_declined"
        case approvalNotPresentable = "approval_not_presentable"
        case permissionRevoked = "permission_revoked"
    }

    /// A representative value for each tag. Exhaustive over ``Sample``, so a tag with no sample does
    /// not compile.
    private static func sample(_ tag: Sample) -> VisionContainmentRefusal {
        switch tag {
        case .iterationCapReached: return .iterationCapReached(cap: 12)
        case .cancelled: return .cancelled
        case .targetIneligible: return .targetIneligible(.terminal)
        case .screenShowsShell:
            return .screenShowsShell(
                ShellSurfaceDetector.verdict(for: "user@host ~ % ls\nzsh: command not found: x")
            )
        case .appControlWithdrawn: return .appControlWithdrawn(app: "Safari")
        case .targetNotFrontmost: return .targetNotFrontmost(expected: "Safari", actual: "Notes")
        case .attentionLost: return .attentionLost(.screenLocked)
        case .actionTypeNotAllowed: return .actionTypeNotAllowed("launch_missiles")
        case .approvalDeclined: return .approvalDeclined(action: "Click Delete")
        case .approvalRefusedByPolicy: return .approvalRefusedByPolicy(action: "Click Send")
        case .captureSendDeclined: return .captureSendDeclined
        case .approvalNotPresentable: return .approvalNotPresentable
        case .permissionRevoked: return .permissionRevoked
        }
    }

    /// The tag a refusal belongs to. Exhaustive over `VisionContainmentRefusal`, so a case added to
    /// the production enum does not compile until it has a tag here — and a tag does not compile
    /// until ``sample(_:)`` gives it a value, which is what puts it in the array the assertions run
    /// over.
    private static func expectedReasonCode(for refusal: VisionContainmentRefusal) -> Sample {
        switch refusal {
        case .iterationCapReached: return .iterationCapReached
        case .cancelled: return .cancelled
        case .targetIneligible: return .targetIneligible
        case .screenShowsShell: return .screenShowsShell
        case .appControlWithdrawn: return .appControlWithdrawn
        case .targetNotFrontmost: return .targetNotFrontmost
        case .attentionLost: return .attentionLost
        case .actionTypeNotAllowed: return .actionTypeNotAllowed
        case .approvalDeclined: return .approvalDeclined
        case .approvalRefusedByPolicy: return .approvalRefusedByPolicy
        case .captureSendDeclined: return .captureSendDeclined
        case .approvalNotPresentable: return .approvalNotPresentable
        case .permissionRevoked: return .permissionRevoked
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
                context: ApprovalContext(mode: mode, appControl: .notApplicable)
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
                    context: ApprovalContext(mode: mode, appControl: .notApplicable)
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

    /// **The last check before synthesis, in both directions.**
    ///
    /// The old version of this test asserted only the allow direction, against a check that could
    /// never refuse — `allCases.contains` on a closed enum (PR #50 review, F2). It was titled
    /// "accepts exactly the closed vocabulary and nothing else", a claim it could not make. Now the
    /// check guards a real invariant — only kinds that drive the machine reach input synthesis — so
    /// the refusing direction exists and is asserted first, because that is the half that can fail.
    @Test
    func onlyInputSynthesizingKindsMayReachSynthesis() {
        let containment = Self.containment()

        for kind in VisionActionKind.allCases where !kind.synthesizesInput {
            #expect(
                containment.checkActionAllowed(Self.decision(kind)) == .actionTypeNotAllowed(kind.rawValue),
                "\(kind) does not drive the machine and must be refused here"
            )
        }

        for kind in VisionActionKind.allCases where kind.synthesizesInput {
            #expect(containment.checkActionAllowed(Self.decision(kind)) == nil, "\(kind)")
        }

        // Both directions are non-empty, so neither loop above is vacuously satisfied — the failure
        // this test exists to catch is a `synthesizesInput` that answers the same for everything.
        #expect(VisionActionKind.allCases.contains { $0.synthesizesInput })
        #expect(VisionActionKind.allCases.contains { !$0.synthesizesInput })
    }
}
