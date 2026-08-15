import CoreGraphics
import Foundation
import Testing
@testable import MacAgentCore

/// SONNY-92: the adapter's three gates — resolve, assess, execute — and the plan-shape guarantees
/// that make them trustworthy.
@MainActor
@Suite
struct VisionSessionAdapterTests {
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

    private static func plan(app: String, goal: String = "open example.com") -> AgentPlan {
        AgentPlan(
            summary: "Control \(app)",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "vision-1",
                    operation: .visionSession,
                    description: "Control \(app)",
                    appName: app,
                    visionGoal: goal
                )
            ]
        )
    }

    /// Driven through the real `AgentActionExecutor` rather than by hand-building a
    /// `CapabilityExecutionContext`, for the same reason every other adapter test in this file's
    /// neighbours is: the executor is what actually runs `resolveDefaultOutputs` before every gate,
    /// and a test that called the adapter directly would be testing a path production never takes.
    private static func executor(
        installed: [InstalledApp],
        vision: VisionSessionEnvironment? = nil
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed)),
            visionSession: vision
        )
    }

    // MARK: - Resolve-phase pinning (SONNY-58 discipline)

    @Test
    func resolvePinsTheBundleIdentifierExactlyOnceFromLaunchServices() throws {
        let prepared = try Self.executor(installed: [Self.safari]).prepare(plan: Self.plan(app: "Safari"))

        let step = try #require(prepared.plan.steps.first)
        #expect(step.resolvedBundleIdentifier == "com.apple.Safari")
        #expect(step.resolvedAppName == "Safari")
        // The raw name is left untouched: the pin is added beside it, not over it, so a preview can
        // still say what the user asked for.
        #expect(step.appName == "Safari")
    }

    @Test
    func resolveFailsWhenTheAppIsNotInstalled() {
        #expect(throws: VisionSessionError.targetAppNotInstalled("Figma")) {
            _ = try Self.executor(installed: [Self.safari]).prepare(plan: Self.plan(app: "Figma"))
        }
    }

    @Test
    func resolveFailsWhenNoAppIsNamed() {
        var plan = Self.plan(app: "Safari")
        plan.steps[0].appName = "   "
        #expect(throws: VisionSessionError.missingTargetApp) {
            _ = try Self.executor(installed: [Self.safari]).prepare(plan: plan)
        }
    }

    // MARK: - The terminal ban, at each of its three doors

    /// **Door 1 — resolve.** The plan never becomes executable, so nothing reaches an approval
    /// surface. A refusal, not a prompt.
    @Test
    func aTerminalTargetIsRefusedAtResolve() {
        #expect(throws: VisionSessionError.targetNotControllable(.terminal)) {
            _ = try Self.executor(installed: [Self.terminal]).prepare(plan: Self.plan(app: "Terminal"))
        }
    }

    /// **Door 2 — assess.** Unreachable in the shipped wiring, because resolve runs before every
    /// gate — which is exactly why it is worth a test. The check is per door, not one shared
    /// assumption, so a caller that assesses a hand-built pre-pinned plan without resolving still
    /// cannot get a controllable answer for a terminal.
    @Test
    func aTerminalTargetIsRefusedAtAssessEvenWhenResolveWasSkipped() {
        let adapter = VisionSessionCapabilityAdapter()
        var prePinned = Self.plan(app: "Terminal")
        prePinned.steps[0].resolvedAppName = "Terminal"
        prePinned.steps[0].resolvedBundleIdentifier = "com.apple.Terminal"

        // The adapter directly, deliberately: the point is that this gate answers on its own, with
        // resolve never having run. Through the executor the resolve door would fire first and this
        // door would stay unexercised, which is the opposite of what the test is for.
        #expect(throws: VisionSessionError.targetNotControllable(.terminal)) {
            _ = try adapter.assessRisk(plan: prePinned, context: VisionTestContext.make(installed: [Self.terminal]))
        }
    }

    /// **Door 3 — execute.** Same again, at the last possible moment before anything moves.
    @Test
    func aTerminalTargetIsRefusedAtExecuteEvenWhenBothEarlierGatesWereSkipped() async {
        let adapter = VisionSessionCapabilityAdapter()
        var prePinned = Self.plan(app: "Terminal")
        prePinned.steps[0].resolvedAppName = "Terminal"
        prePinned.steps[0].resolvedBundleIdentifier = "com.apple.Terminal"

        await #expect(throws: VisionSessionError.targetNotControllable(.terminal)) {
            _ = try await adapter.execute(
                plan: prePinned,
                context: VisionTestContext.make(installed: [Self.terminal]),
                log: { _, _ in }
            )
        }
    }

    /// Launching a terminal is untouched by all of this — ordinary tier-1 work, and deliberately so.
    /// The ban is about *controlling*, and conflating the two would break a capability C12 ratified.
    @Test
    func theBanDoesNotReachTheLaunchCapability() {
        #expect(!StoredRoutine.forbiddenStepOperations.contains(.openApp))
        #expect(OpenAppCapabilityAdapter.metadata.defaultRiskTier == .tier1)
    }

    // MARK: - The session envelope

    /// **Both founder decisions at once.** Tier 3 so the unattended path's fixed `.approved(.tier2)`
    /// ceiling can never cover a vision session; advisory so Normal and Power start one silently.
    @Test
    func theSessionEnvelopeIsTierThreeAndAdvisory() throws {
        let assessment = try Self.executor(installed: [Self.safari])
            .assessRisk(plan: Self.plan(app: "Safari"), scope: .unscoped)

        #expect(assessment.defaultTier == .tier2)
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.count == 1)
        #expect(assessment.escalations.first?.consequence == .advisory)
        #expect(assessment.approvalCopy?.dataLeavesDevice == true)
        #expect(assessment.escalations.first?.reason.contains("Safari") == true)
    }

    /// The requirement that envelope produces, per mode — the behavior the two facts above exist for.
    @Test
    func theSessionStartsSilentlyInNormalAndPowerAndAsksInSafe() throws {
        let assessment = try Self.executor(installed: [Self.safari])
            .assessRisk(plan: Self.plan(app: "Safari"), scope: .unscoped)

        for mode in AgentInteractionMode.allCases {
            let requirement = RiskApprovalPolicy.default.requirement(
                for: assessment,
                context: ApprovalContext(safeMode: mode.asksBeforeEveryAction)
            )
            #expect(requirement == (mode == .safe ? .explicitApproval : .autoRun), "\(mode)")
        }
    }

    /// **The unattended ceiling, pinned from the vision side.** A standing tier-2 grant — what the
    /// scheduled path holds — cannot authorize a vision session. This is one of the three independent
    /// layers behind "unattended vision: never", and it works by comparing tiers, so it is worth
    /// asserting against the real assessment rather than against a hand-built tier.
    @Test
    func aStandingTierTwoGrantCannotAuthorizeAVisionSession() throws {
        let assessment = try Self.executor(installed: [Self.safari])
            .assessRisk(plan: Self.plan(app: "Safari"), scope: .unscoped)
        let request = RiskApprovalRequest(assessment: assessment, requirement: .explicitApproval)

        #expect(RiskApprovalDecision.approved(.tier2).authorizes(request) == false)
        #expect(RiskApprovalDecision.notRequested.authorizes(request) == false)
    }

    // MARK: - Plan-shape guarantees

    /// **The single-sourcing pin, driven by a hostile payload.** A planner response naming either pin
    /// field is rejected outright rather than silently ignored — and the check recurses, so burying
    /// it inside a routine's nested steps does not help.
    @Test
    func aHostilePayloadCannotPrePinTheTargetAtAnyNestingDepth() {
        let topLevel = """
        {"summary":"x","requiresConfirmation":false,"steps":[
          {"id":"1","operation":"vision_session","description":"d","appName":"Terminal",
           "resolvedBundleIdentifier":"com.apple.Terminal"}
        ]}
        """
        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("resolvedBundleIdentifier")) {
            _ = try AgentPlanDecoder.decodeStrict(from: topLevel)
        }

        let nested = """
        {"summary":"x","requiresConfirmation":false,"steps":[
          {"id":"1","operation":"save_routine","description":"d","routineName":"r","routineSteps":[
            {"id":"2","operation":"vision_session","description":"d","appName":"Terminal",
             "resolvedAppName":"Terminal"}
          ]}
        ]}
        """
        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("resolvedAppName")) {
            _ = try AgentPlanDecoder.decodeStrict(from: nested)
        }
    }

    /// The goal is decode-excluded too, for SONNY-92's duration — a vision step can only be built in
    /// Swift, so nothing a model writes can name it.
    @Test
    func theVisionGoalIsDecodeExcludedWhileTheOperationIsPlannerInvisible() {
        #expect(!AgentOperation.plannerVisibleCases.contains(.visionSession))
        let payload = """
        {"summary":"x","requiresConfirmation":false,"steps":[
          {"id":"1","operation":"vision_session","description":"d","appName":"Safari","visionGoal":"do a thing"}
        ]}
        """
        #expect(throws: AgentPlanDecodingError.unexpectedStepKey("visionGoal")) {
            _ = try AgentPlanDecoder.decodeStrict(from: payload)
        }
    }

    /// A vision step cannot be stored in a routine — the third layer of "unattended vision: never",
    /// asserted through the real write door rather than by reading the list.
    @Test
    func aRoutineCannotStoreAVisionStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionRoutineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = RoutineStore(fileURL: root.appendingPathComponent("routines.json"))
        #expect(throws: AutomationStoreError.unsafeRoutineStep("vision_session")) {
            try store.save(
                StoredRoutine(name: "sneaky", steps: Self.plan(app: "Safari").steps)
            )
        }
    }

    /// Scope: opaque always, and the pinned app is still reported so a workspace that excludes it
    /// escalates through row B's machinery.
    @Test
    func aVisionStepIsOpaqueAndStillNamesItsTargetApp() throws {
        let prepared = try Self.executor(installed: [Self.safari]).prepare(plan: Self.plan(app: "Safari"))
        let classification = PlanScopedResources.classification(of: try #require(prepared.plan.steps.first))

        #expect(classification.isOpaque)
        #expect(
            classification.resources == [
                .resolvedApp(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
            ]
        )

        // Unpinned, the app is still named from the raw field — over-reporting escalates,
        // under-reporting silently blesses.
        let unpinned = PlanScopedResources.classification(of: try #require(Self.plan(app: "Safari").steps.first))
        #expect(unpinned.isOpaque)
        #expect(unpinned.resources == [.app("Safari")])
    }

    /// A vision session's own dispatch origin is its own case — never `.directUserAction`.
    @Test
    func theDispatchOriginIsItsOwnCase() {
        #expect(PreparedPlanSource.visionSession.rawValue == "vision_session")
        #expect(PreparedPlanSource.visionSession != .directUserAction)
        #expect(PreparedPlanSource.visionSession.planLogMessage != PreparedPlanSource.directUserAction.planLogMessage)
    }

    /// Screenshots leave the device, and Safe mode's one egress disclosure has to say so.
    @Test
    func aVisionSessionIsClassifiedAsLeavingTheDevice() {
        #expect(AgentActionExecutor.dataEgressOperations.contains(.visionSession))
    }
}
