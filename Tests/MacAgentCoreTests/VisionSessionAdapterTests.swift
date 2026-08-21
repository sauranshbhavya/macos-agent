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
    private static let notes = InstalledApp(
        displayName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        applicationURL: URL(fileURLWithPath: "/Applications/Notes.app")
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
        running: [InstalledApp] = [],
        vision: VisionSessionEnvironment? = nil
    ) -> AgentActionExecutor {
        AgentActionExecutor(
            installedAppResolver: InstalledAppResolver(source: FixedAppSource(installed)),
            runningAppSwitcher: FixedRunningApps(running),
            visionSession: vision
        )
    }

    /// A running-app universe a test states rather than inherits — `switch_running_app`'s own
    /// resolver refuses an app that is not running, and which apps happen to be open on the machine
    /// running the suite is not something a test may depend on.
    private final class FixedRunningApps: RunningAppSwitching {
        private let apps: [InstalledApp]
        init(_ apps: [InstalledApp]) { self.apps = apps }
        func runningApps() -> [RunningApp] {
            apps.map { RunningApp(displayName: $0.displayName, bundleIdentifier: $0.bundleIdentifier, processIdentifier: 0) }
        }
        func activate(bundleIdentifier: String) async throws {}
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

    // MARK: - Never frontmost (SONNY-93)

    /// **A plan with no resolvable target fails to a clarification, never to whatever is in front.**
    ///
    /// This is the iTerm2 lesson as structure. The spike's vision fallback defaulted to the frontmost
    /// app and typed shell commands into a live terminal; what stops that here is not a better
    /// default but the absence of one.
    @Test
    func aVisionStepWithNoResolvableTargetFailsToAClarification() throws {
        var plan = Self.plan(app: "Safari")
        plan.steps[0].appName = "   "

        let prepared = try Self.executor(installed: [Self.safari]).prepare(plan: plan)

        #expect(prepared.clarificationQuestion != nil)
        #expect(prepared.plan.steps.map(\.operation) == [.clarify])
        #expect(prepared.clarificationQuestion?.contains("Which app") == true)
    }

    /// **Inheritance, through the real executor** — the mixed plan a user actually gets.
    ///
    /// This test replaced one that called `VisionSessionCapabilityAdapter.targetName(for:precededBy:)`
    /// directly (PR #50 review, F1). That version passed while the feature was broken through every
    /// user-reachable path: the resolve dispatch lived in `resolveUnitDefaultOutputs`, which runs
    /// **per segment**, and `open_app` and `vision_session` are different workflows — so the adapter
    /// only ever saw a plan containing the vision step alone, `precededBy` was always empty, and the
    /// whole mixed plan collapsed to "Which app should Sonny control?" after the user had already
    /// said Notes.
    ///
    /// It is the third defect on this branch hidden by a test written against a component rather
    /// than a path, and it is the reason this one asserts on the *prepared plan*: both steps survive,
    /// and the vision step carries the pin.
    @Test
    func aMixedPlanInheritsItsVisionTargetFromAnEarlierStepThroughTheRealExecutor() throws {
        let plan = AgentPlan(
            summary: "Open Notes and write today's standup there.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openApp, description: "Open Notes", appName: "Notes"),
                // Deliberately no `appName`: the whole point is that the earlier step supplies it.
                AgentStep(
                    id: "2",
                    operation: .visionSession,
                    description: "Write the standup",
                    visionGoal: "write today's standup as a new note"
                )
            ]
        )

        let prepared = try Self.executor(installed: [Self.safari, Self.notes]).prepare(plan: plan)

        // The supported step is still there — the old behaviour discarded it along with everything
        // else when the clarification replaced the plan.
        #expect(prepared.plan.steps.map(\.operation) == [.openApp, .visionSession])
        #expect(prepared.clarificationQuestion == nil)

        let visionStep = try #require(prepared.plan.steps.last)
        #expect(visionStep.resolvedAppName == "Notes")
        #expect(visionStep.resolvedBundleIdentifier == "com.apple.Notes")
    }

    /// A `switch_running_app` step supplies the target too, and the *last* one wins: after
    /// "open Notes, focus Safari, then do X", X happens in Safari.
    @Test
    func theLastAppNamingStepBeforeTheVisionStepWins() throws {
        let plan = AgentPlan(
            summary: "Open Notes, focus Safari, then act.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openApp, description: "Open Notes", appName: "Notes"),
                AgentStep(id: "2", operation: .switchRunningApp, description: "Focus Safari", appName: "Safari"),
                AgentStep(id: "3", operation: .visionSession, description: "Act", visionGoal: "do a thing")
            ]
        )

        let prepared = try Self.executor(
            installed: [Self.safari, Self.notes],
            running: [Self.safari]
        ).prepare(plan: plan)
        let visionStep = try #require(prepared.plan.steps.last)
        #expect(visionStep.resolvedBundleIdentifier == "com.apple.Safari")
    }

    /// The step's own name always wins over anything inherited.
    @Test
    func aVisionStepsOwnAppNameOutranksAnEarlierStepsThroughTheRealExecutor() throws {
        let plan = AgentPlan(
            summary: "Open Notes, then act in Safari.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openApp, description: "Open Notes", appName: "Notes"),
                AgentStep(
                    id: "2",
                    operation: .visionSession,
                    description: "Act",
                    appName: "Safari",
                    visionGoal: "do a thing"
                )
            ]
        )

        let prepared = try Self.executor(installed: [Self.safari, Self.notes]).prepare(plan: plan)
        let visionStep = try #require(prepared.plan.steps.last)
        #expect(visionStep.resolvedBundleIdentifier == "com.apple.Safari")
    }

    /// **The reviewer's own safety probe, kept as a test.** A mixed plan whose earlier step opens a
    /// terminal must not inherit it into a controllable session. Now that inheritance actually works,
    /// this is the case that could have turned a broken feature into a hole — it does not: the
    /// inherited target is judged by the same ban as a named one.
    @Test
    func aMixedPlanCannotInheritATerminalAsItsVisionTarget() {
        let plan = AgentPlan(
            summary: "Open Terminal and do a thing.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openApp, description: "Open Terminal", appName: "Terminal"),
                AgentStep(id: "2", operation: .visionSession, description: "Act", visionGoal: "run a command")
            ]
        )

        #expect(throws: VisionSessionError.targetNotControllable(.terminal)) {
            _ = try Self.executor(installed: [Self.safari, Self.terminal]).prepare(plan: plan)
        }
    }

    /// Only steps that put a *named* app on screen can answer, through the real path: a plan whose
    /// earlier steps name no app still fails to a clarification rather than to whatever is frontmost.
    @Test
    func aMixedPlanWhoseEarlierStepsNameNoAppStillClarifies() throws {
        let plan = AgentPlan(
            summary: "Open a workspace and do a thing.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openWorkspace, description: "Open Research", workspaceName: "Research"),
                AgentStep(id: "2", operation: .visionSession, description: "Act", visionGoal: "do a thing")
            ]
        )

        let prepared = try Self.executor(installed: [Self.safari, Self.notes]).prepare(plan: plan)
        #expect(prepared.plan.steps.map(\.operation) == [.clarify])
        #expect(prepared.clarificationQuestion?.contains("Which app") == true)
    }

    /// Only steps that put a *named* app on screen can answer. A workspace opens several and names
    /// none of them in the step, so it cannot — and the honest outcome is a clarification.
    @Test
    func onlyStepsThatNameAnAppCanSupplyTheTarget() {
        var vision = AgentStep(id: "2", operation: .visionSession, description: "d", visionGoal: "g")
        vision.appName = nil

        let nonAnswers: [AgentStep] = [
            AgentStep(id: "1", operation: .openWorkspace, description: "d", workspaceName: "Research"),
            AgentStep(id: "1", operation: .openURL, description: "d", targetURL: "https://example.com"),
            AgentStep(id: "1", operation: .createLocalDraft, description: "d", draftTitle: "t", draftContent: "c"),
            // An open_app step with no name of its own answers nothing either.
            AgentStep(id: "1", operation: .openApp, description: "d", appName: "  ")
        ]
        for step in nonAnswers {
            #expect(
                VisionSessionCapabilityAdapter.targetName(for: vision, precededBy: [step]) == nil,
                "\(step.operation.rawValue)"
            )
        }
    }

    /// **Nothing in the resolution path reads frontmost state**, and the pin is a sweep rather than a
    /// reading of the file — the point of a negative claim is that its evidence lives everywhere you
    /// did not look. The one legitimate frontmost read in the whole vision path is the containment
    /// layer's per-iteration *boundary*, which refuses when the pinned app is not in front rather
    /// than adopting whatever is.
    @Test
    func noFrontmostStateIsReadAnywhereInTheResolutionPath() throws {
        let sources = [
            "Sources/MacAgentCore/VisionSessionCapabilityAdapter.swift",
            "Sources/MacAgentCore/VisionSessionRunner.swift",
            "Sources/MacAgentCore/VisionSessionPromptBuilder.swift"
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for relative in sources {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("frontmostApplication"), "\(relative)")
            #expect(!code.contains("VisionFallbackAppHint"), "\(relative)")
        }

        // And the containment layer's own frontmost read is a refusal, never an adoption: the check
        // compares against the *pinned* target and returns a refusal, so there is no assignment of a
        // discovered app to anything.
        let containment = try String(
            contentsOf: root.appendingPathComponent("Sources/MacAgentCore/VisionSessionContainment.swift"),
            encoding: .utf8
        )
        #expect(containment.contains("targetNotFrontmost"))
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
                context: ApprovalContext(mode: mode, appControl: .notApplicable)
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

    /// **The goal is the planner's to write; the pins are the resolver's alone.** SONNY-93 made the
    /// operation planner-visible and moved `visionGoal` into the decodable set with it — and the two
    /// pin fields deliberately did not move, which is the asymmetry this test exists to hold.
    @Test
    func theGoalDecodesWhileThePinsStayResolverOnly() throws {
        #expect(AgentOperation.plannerVisibleCases.contains(.visionSession))

        let plan = try AgentPlanDecoder.decodeStrict(from: """
        {"summary":"x","requiresConfirmation":false,"steps":[
          {"id":"1","operation":"vision_session","description":"d","appName":"Safari","visionGoal":"do a thing"}
        ]}
        """)
        let step = try #require(plan.steps.first)
        #expect(step.visionGoal == "do a thing")
        #expect(step.appName == "Safari")
        #expect(step.resolvedBundleIdentifier == nil)
        #expect(step.resolvedAppName == nil)
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

/// SONNY-93: one plan, one assessment, both halves disclosed.
///
/// A mixed plan runs some steps through precise, previewable, individually-gated adapters and one
/// step by a model looking at a window. Those are very different things to agree to, and the plan
/// summary — written by the planner, describing the goal — says nothing about the difference.
@MainActor
@Suite
struct MixedVisionPlanTests {
    private static let safari = InstalledApp(
        displayName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app")
    )
    private static let notes = InstalledApp(
        displayName: "Notes",
        bundleIdentifier: "com.apple.Notes",
        applicationURL: URL(fileURLWithPath: "/Applications/Notes.app")
    )

    private static func executor() -> AgentActionExecutor {
        AgentActionExecutor(
            installedAppResolver: InstalledAppResolver(source: FixedAppSource([safari, notes]))
        )
    }

    private static func mixedPlan() -> AgentPlan {
        AgentPlan(
            summary: "Open Notes and write today's standup there.",
            requiresConfirmation: false,
            steps: [
                AgentStep(id: "1", operation: .openApp, description: "Open Notes", appName: "Notes"),
                AgentStep(
                    id: "2",
                    operation: .visionSession,
                    description: "Write the standup",
                    appName: "Notes",
                    visionGoal: "write today's standup as a new note"
                )
            ]
        )
    }

    /// **One assessment for the whole plan**, unioning the supported steps' tiers with the vision
    /// step's — not two assessments, and not a second gate.
    @Test
    func aMixedPlanIsAssessedAsOneUnit() throws {
        let assessment = try Self.executor().assessRisk(plan: Self.mixedPlan(), scope: .unscoped)

        // Tier 3 comes from the vision half; `open_app` alone is tier 1. The union takes the higher.
        #expect(assessment.effectiveTier == .tier3)
        #expect(assessment.escalations.contains { $0.consequence == .advisory })
        // And the whole plan reads as leaving the device, because half of it does.
        #expect(assessment.approvalCopy?.dataLeavesDevice == true)
    }

    /// The disclosure names both halves, the app, and the goal.
    @Test
    func theDisclosureNamesBothHalvesTheAppAndTheGoal() throws {
        let assessment = try Self.executor().assessRisk(plan: Self.mixedPlan(), scope: .unscoped)
        let description = try #require(assessment.approvalCopy?.actionDescription)

        // The planner's own summary survives — the split is appended, never a replacement.
        #expect(description.contains("Open Notes and write today's standup there."))
        #expect(description.contains("1 step with its own tools"))
        #expect(description.contains("write today's standup as a new note"))
        #expect(description.contains("controlling Notes directly"))
    }

    /// A plan that is *only* a vision step says so plainly rather than counting zero other steps.
    @Test
    func aVisionOnlyPlanGetsItsOwnSentenceRatherThanACountOfZero() throws {
        let plan = AgentPlan(
            summary: "Set the theme to dark in Safari.",
            requiresConfirmation: false,
            steps: [
                AgentStep(
                    id: "1",
                    operation: .visionSession,
                    description: "d",
                    appName: "Safari",
                    visionGoal: "set the theme to dark"
                )
            ]
        )
        let disclosure = try #require(AgentActionExecutor.visionSplitDisclosure(for: plan))
        #expect(disclosure.contains("by controlling Safari directly"))
        #expect(!disclosure.contains("steps with its own tools"))
    }

    /// **Every plan without a vision step is untouched**, which is every plan the product had before
    /// row I. Asserted as a negative over a spread of ordinary shapes, because a disclosure that
    /// leaked into unrelated approvals would be a change to copy nobody reviewed.
    @Test
    func noOrdinaryPlanGainsAVisionDisclosure() {
        let ordinary: [AgentPlan] = [
            AgentPlan(summary: "Open Safari.", requiresConfirmation: false, steps: [
                AgentStep(id: "1", operation: .openApp, description: "d", appName: "Safari")
            ]),
            AgentPlan(summary: "Save a draft.", requiresConfirmation: false, steps: [
                AgentStep(id: "1", operation: .createLocalDraft, description: "d", draftTitle: "t", draftContent: "c")
            ]),
            AgentPlan(summary: "Ask.", requiresConfirmation: false, steps: [
                AgentStep(id: "1", operation: .clarify, description: "d", question: "Which folder?")
            ])
        ]
        for plan in ordinary {
            #expect(AgentActionExecutor.visionSplitDisclosure(for: plan) == nil, "\(plan.summary)")
        }
    }

    /// The pinned name outranks the raw one, so a disclosure names the app that will actually be
    /// controlled rather than the word the planner happened to write (SONNY-58 again).
    @Test
    func theDisclosureNamesThePinnedAppNotTheRawQuery() throws {
        var plan = Self.mixedPlan()
        plan.steps[1].appName = "notes"
        let prepared = try Self.executor().prepare(plan: plan)

        let disclosure = try #require(AgentActionExecutor.visionSplitDisclosure(for: prepared.plan))
        #expect(disclosure.contains("controlling Notes directly"))
        #expect(!disclosure.contains("controlling notes directly"))
    }
}
