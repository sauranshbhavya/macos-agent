import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-94: unattended vision, never — three independent layers, pinned separately.
///
/// **Separately is the requirement, not a style choice.** Each of the three would stop an unattended
/// vision session on its own, and each is pinned by a test that fails when *it* is removed even
/// though the other two still hold. That is what "no single regression unbars unattended screen
/// control" means operationally: a test that only asserted the outcome would keep passing with two
/// of the three deleted.
///
/// A present human is an authority requirement, not an accuracy hedge (E7 as ratified under C8).
@MainActor
@Suite
struct UnattendedVisionNeverTests {
    private static let safari = InstalledApp(
        displayName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )

    private static func visionPlan() -> AgentPlan {
        AgentPlan(
            summary: "Control Safari",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "1",
                    operation: .visionSession,
                    description: "Control Safari",
                    appName: "Safari",
                    visionGoal: "do a thing"
                )
            ]
        )
    }

    // MARK: - Layer 2: the ceiling

    /// **The suspenders.** The scheduled path executes with a fixed `.approved(.tier2)` grant, and a
    /// vision session assesses tier 3 — so the grant simply cannot satisfy it. Structural, not a
    /// policy check written somewhere that could drift out of sync with the real gate.
    ///
    /// Pinned against the *real* assessment rather than a hand-built tier, because what makes this
    /// layer work is that the vision assessment really is tier 3, and a change that lowered it would
    /// silently unbar the whole thing.
    @Test
    func theScheduledPathsTierTwoCeilingCannotCoverAVisionSession() throws {
        let executor = AgentActionExecutor(
            installedAppResolver: InstalledAppResolver(source: FixedAppSource([Self.safari]))
        )
        let assessment = try executor.assessRisk(plan: Self.visionPlan(), scope: .unscoped)
        #expect(assessment.effectiveTier == .tier3)

        let request = RiskApprovalRequest(assessment: assessment, requirement: .explicitApproval)
        // The exact grant `performScheduledRun` passes, and the exact grant a trusted routine gets.
        #expect(RiskApprovalDecision.approved(.tier2).authorizes(request) == false)

        // And the ceiling is not merely "the current tier happens to be higher": every tier a
        // standing tier-2 grant *can* cover is at or below 2, so no vision assessment ever qualifies
        // while its tier is honest.
        for tier in CapabilityRiskTier.allCases {
            let probe = RiskApprovalRequest(
                assessment: CapabilityRiskAssessment(defaultTier: .tier0, effectiveTier: tier),
                requirement: .explicitApproval
            )
            #expect(
                RiskApprovalDecision.approved(.tier2).authorizes(probe) == (tier.rawValue <= CapabilityRiskTier.tier2.rawValue),
                "\(tier)"
            )
        }
    }

    // MARK: - Layer 3: the routine store

    /// **The structure**, pinned from the scheduled angle specifically: the scheduled path runs
    /// *stored routines*, so a routine that structurally cannot hold a vision step is a door the
    /// scheduler can never see one through — independent of the other two layers entirely.
    @Test
    func aStoredRoutineCannotCarryAVisionStepAtAnyDepth() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnattendedVisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))

        #expect(throws: AutomationStoreError.unsafeRoutineStep("vision_session")) {
            try store.save(StoredRoutine(name: "sneaky", steps: Self.visionPlan().steps))
        }

        // Nesting does not help: `save_routine` cannot carry nested steps at all, so there is no
        // depth at which a vision step becomes storable.
        #expect(throws: (any Error).self) {
            try store.save(
                StoredRoutine(
                    name: "nested",
                    steps: [
                        AgentStep(
                            id: "1",
                            operation: .openApp,
                            description: "Open Safari",
                            appName: "Safari",
                            routineSteps: Self.visionPlan().steps
                        )
                    ]
                )
            )
        }

        #expect(StoredRoutine.forbiddenStepOperations.contains(.visionSession))
    }

    // MARK: - Session-bound: the three attention conditions

    private struct FixedMonitor: SessionAttentionMonitoring {
        let state: SessionAttentionState
        let presentable: Bool
        init(_ state: SessionAttentionState, presentable: Bool = true) {
            self.state = state
            self.presentable = presentable
        }
        func attentionState() async -> SessionAttentionState { state }
        func canPresentApproval() async -> Bool { presentable }
    }

    /// Each of the three conditions pauses, and names itself.
    @Test
    func lockSleepAndIdleEachPauseTheSessionWithTheirOwnReason() async {
        for state in [SessionAttentionState.screenLocked, .displayAsleep, .userIdle] {
            let containment = VisionSessionContainment(
                target: ScreenControlPolicy.verdict(for: Self.safari),
                attentionMonitor: FixedMonitor(state)
            )
            let refusal = await containment.checkIterationStart(
                iteration: 1,
                isCancelled: false,
                frontmostBundleIdentifier: { "com.apple.Safari" }
            )
            #expect(refusal == .attentionLost(state), "\(state)")
        }
    }

    /// **§13.1's tier-3 condition: the Mac must be unlocked to show an approval.**
    ///
    /// Narrower than the attention check on purpose, and the two are pinned apart here: an idle user
    /// can still be shown an approval and answer it — being asked is how they find out Sonny is
    /// waiting — while a locked screen cannot show one to anybody, so a session that reaches a
    /// tier-3 action there stops rather than acting without an answer.
    @Test
    func anApprovalIsNotPresentableWhileTheMacIsLocked() async {
        let locked = VisionSessionContainment(
            target: ScreenControlPolicy.verdict(for: Self.safari),
            attentionMonitor: FixedMonitor(.screenLocked, presentable: false)
        )
        #expect(await locked.checkApprovalPresentable() == .approvalNotPresentable)

        let unlocked = VisionSessionContainment(
            target: ScreenControlPolicy.verdict(for: Self.safari),
            attentionMonitor: FixedMonitor(.attended, presentable: true)
        )
        #expect(await unlocked.checkApprovalPresentable() == nil)

        // Idle but unlocked: paused by the attention check, and yet an approval *would* still be
        // presentable — the two answers are genuinely independent, which is why they are two checks.
        let idle = FixedMonitor(.userIdle, presentable: true)
        #expect(await idle.attentionState() == .userIdle)
        #expect(await idle.canPresentApproval())
    }

    /// The protocol's default is the conservative one, so a conformer with no separate opinion
    /// refuses to present whenever attention is lost.
    @Test
    func theDefaultPresentabilityAnswerFollowsAttention() async {
        struct AttentionOnlyMonitor: SessionAttentionMonitoring {
            let state: SessionAttentionState
            func attentionState() async -> SessionAttentionState { state }
        }
        #expect(await AttentionOnlyMonitor(state: .attended).canPresentApproval())
        #expect(await AttentionOnlyMonitor(state: .screenLocked).canPresentApproval() == false)
        #expect(await AttentionOnlyMonitor(state: .userIdle).canPresentApproval() == false)
    }
}

/// The OS-reading monitor, driven through every branch without a real display or a real lock.
@Suite
struct SystemSessionAttentionMonitorTests {
    private static func monitor(
        locked: Bool = false,
        asleep: Bool = false,
        idleSeconds: TimeInterval = 0
    ) -> SystemSessionAttentionMonitor {
        SystemSessionAttentionMonitor(
            environment: .init(
                isScreenLocked: { locked },
                isDisplayAsleep: { asleep },
                secondsSinceLastInput: { idleSeconds }
            )
        )
    }

    @Test
    func aUserWhoIsThereIsAttended() async {
        #expect(await Self.monitor().attentionState() == .attended)
    }

    /// Each condition on its own.
    @Test
    func eachConditionIsDetectedIndependently() async {
        #expect(await Self.monitor(locked: true).attentionState() == .screenLocked)
        #expect(await Self.monitor(asleep: true).attentionState() == .displayAsleep)
        #expect(
            await Self.monitor(idleSeconds: SystemSessionAttentionMonitor.idleTimeout).attentionState() == .userIdle
        )
    }

    /// **Ordering, pinned rather than inferred.** A locked Mac is the strongest statement of "I am
    /// not here", so it is what the user is told even when the display is also asleep and they have
    /// also been idle — a user told the weakest true reason is worse served than one told the
    /// strongest.
    @Test
    func theStrongestTrueReasonIsTheOneReported() async {
        let all = Self.monitor(locked: true, asleep: true, idleSeconds: 9_999)
        #expect(await all.attentionState() == .screenLocked)

        let asleepAndIdle = Self.monitor(asleep: true, idleSeconds: 9_999)
        #expect(await asleepAndIdle.attentionState() == .displayAsleep)
    }

    /// The idle threshold is a boundary, so both sides of it are pinned.
    @Test
    func theIdleThresholdIsInclusiveAndBoundedOnBothSides() async {
        let timeout = SystemSessionAttentionMonitor.idleTimeout
        #expect(await Self.monitor(idleSeconds: timeout - 0.1).attentionState() == .attended)
        #expect(await Self.monitor(idleSeconds: timeout).attentionState() == .userIdle)
    }

    /// **Fail closed.** A live lock check that cannot read the session dictionary answers "locked",
    /// because unable-to-tell means unable to justify moving the cursor. Driven through the seam
    /// rather than by breaking CoreGraphics, so what is pinned is the *policy* the live closure
    /// implements.
    @Test
    func anUnreadableLockStateIsTreatedAsLocked() async {
        #expect(await Self.monitor(locked: true).attentionState() == .screenLocked)
        #expect(await Self.monitor(locked: true).canPresentApproval() == false)
    }

    /// Presentability tracks the lock alone — not sleep, and not idle.
    @Test
    func presentabilityTracksTheLockAloneAndNotTheOtherTwo() async {
        #expect(await Self.monitor().canPresentApproval())
        #expect(await Self.monitor(asleep: true).canPresentApproval())
        #expect(await Self.monitor(idleSeconds: 9_999).canPresentApproval())
        #expect(await Self.monitor(locked: true).canPresentApproval() == false)
    }
}
