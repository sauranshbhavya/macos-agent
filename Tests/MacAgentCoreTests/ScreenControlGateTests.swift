import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// **Direction one of SONNY-213's acceptance criterion**: screen control with no allowance, or with
/// no confirmable entitlement, is refused.
///
/// Direction two — every other capability running with no network and no entitlement — is
/// `ScreenControlGateFreeCapabilityTests` below and `ScreenControlGateReachTests` in the app target.
/// The ticket asks for both to be pinned and names the second as the one that breaks offline Sonny
/// if it is got backwards, so neither is left to follow from the other.
@Suite
struct ScreenControlGateTests {
    private func gate(
        entitlement: EntitlementDecision,
        allowance: StubAllowanceReading.Answer
    ) -> (SonnyScreenControlGate, StubAllowanceReading) {
        let reader = StubAllowanceReading(allowance)
        return (
            SonnyScreenControlGate(
                entitlements: StubEntitlementConfirmation(entitlement),
                allowance: reader
            ),
            reader
        )
    }

    // MARK: - The entitlement half

    /// Every refusal the entitlement check can produce reaches the gate as its own case, at both
    /// moments, carrying `EntitlementCopy`'s sentence.
    ///
    /// **Parameterized over the whole population rather than over a representative**, because the
    /// case that matters is the one nobody thought to write: `.notEntitled` is unreachable today
    /// (no capability key exists, so `claimConfirmation` never asks the question that produces it)
    /// and is here anyway, so the day row 18 mints a key it is already held.
    @Test(arguments: [
        EntitlementRefusal.notSignedIn,
        .noClaim,
        .unreadableClaim,
        .claimIsForAnotherSession,
        .clockUnusable,
        .lapsed,
        .notEntitled
    ])
    func anUnconfirmableClaimRefusesAtEveryMomentAndSaysWhichNo(refusal: EntitlementRefusal) async {
        let (subject, reader) = gate(entitlement: .refused(refusal), allowance: .runsLeft(99))

        for moment in [ScreenControlGateMoment.sessionStart, .stepBoundary] {
            #expect(
                await subject.decide(at: moment) == .refused(.entitlementUnconfirmed(refusal)),
                "\(moment) with \(refusal)"
            )
        }
        // **The allowance was never asked**, which is the property an outcome assertion cannot see.
        // The entitlement half is local and instant; opening a network request the answer would be
        // thrown away by is the shape §16.3 exists to prevent, and a gate that did it would block on
        // a request before telling a signed-out user to sign in.
        #expect(reader.fetchCount == 0)

        // §7.1's rule, already applied one layer down: the sentence is this repository's, not the
        // server's, and it is the same one every other entitlement refusal in the product shows.
        #expect(
            ScreenControlGateRefusal.entitlementUnconfirmed(refusal).userFacingReason
                == EntitlementCopy.message(for: refusal)
        )
    }

    // MARK: - The allowance half

    /// No runs left refuses at both moments — the ticket's first direction, at its boundary value.
    @Test
    func noRunsLeftRefusesAtBothMoments() async {
        let (subject, _) = gate(entitlement: .entitled, allowance: .runsLeft(0))

        #expect(await subject.decide(at: .sessionStart) == .refused(.allowanceExhausted))
        #expect(await subject.decide(at: .stepBoundary) == .refused(.allowanceExhausted))
    }

    /// **One run left runs**, and this is the off-by-one that a `>= 0` or a `> 1` would ship.
    ///
    /// Asserted as a value at the boundary rather than as "some positive number is allowed": the
    /// interesting number is exactly 1, because that is the last session a user gets and refusing it
    /// would take a run they had paid for.
    @Test
    func oneRunLeftIsAllowedAtBothMoments() async {
        let (subject, _) = gate(entitlement: .entitled, allowance: .runsLeft(1))

        #expect(await subject.decide(at: .sessionStart) == .allowed)
        #expect(await subject.decide(at: .stepBoundary) == .allowed)
    }

    /// **A session admitted on the account's last run is not halted for spending that run**
    /// (PR #190's F1 — the defect this test exists for, and the money path).
    ///
    /// This is the state no `runsLeft` value can express, which is exactly why one figure read at
    /// both moments looked correct: the door reads 1 and admits, iteration 1 is metered, and because
    /// `runsLeft` is `floor(remaining / runCredits)` over a remainder the session's *own* draw has
    /// already been subtracted from, the very next boundary reads 0 with most of the run still
    /// unspent. Under the old single predicate the tenth run of a ten-run plan was one step long.
    ///
    /// The two assertions are opposite answers to the *same reading*, which is the whole point: the
    /// door refuses (no whole further run is affordable) and the boundary allows (this run is not
    /// finished). A test that only asserted one of them would pass on the defect.
    @Test
    func aSessionAdmittedOnItsLastRunIsNotHaltedForSpendingIt() async {
        let (subject, _) = gate(
            entitlement: .entitled,
            allowance: .runsAndCredits(runsLeft: 0, creditsRemaining: 0.9)
        )

        #expect(await subject.decide(at: .sessionStart) == .refused(.allowanceExhausted))
        #expect(await subject.decide(at: .stepBoundary) == .allowed)
    }

    /// **And the halt still fires when the account has actually run out**, or F1's fix would have
    /// deleted the ticket's acceptance criterion instead of correcting it.
    ///
    /// Asserted at the boundary value on the figure that now decides it. `0.0` halts and any
    /// positive remainder does not, so "ran out" means the remainder reached zero rather than the
    /// run count flooring to zero — the distinction the two tests either side of this one turn on.
    @Test
    func theBoundaryHaltsWhenTheRemainderIsActuallyGone() async {
        let (exhausted, _) = gate(
            entitlement: .entitled,
            allowance: .runsAndCredits(runsLeft: 0, creditsRemaining: 0)
        )
        #expect(await exhausted.decide(at: .stepBoundary) == .refused(.allowanceExhausted))

        let (barely, _) = gate(
            entitlement: .entitled,
            allowance: .runsAndCredits(runsLeft: 0, creditsRemaining: 0.000001)
        )
        #expect(await barely.decide(at: .stepBoundary) == .allowed)
    }

    /// **The one asymmetry in the gate, both directions in one test.**
    ///
    /// An allowance the gateway would not answer fails *closed* at the door — nothing has happened,
    /// so a refusal costs a sentence and no work — and is *not* a halt at a step boundary, where the
    /// alternative is destroying a running session on a transient failure. That is deliberate and it
    /// is the single most attackable line in this type, so it is asserted rather than described.
    @Test
    func anUnreadableAllowanceRefusesAtTheDoorAndDoesNotHaltARunningSession() async {
        let (subject, reader) = gate(entitlement: .entitled, allowance: .failure)

        #expect(await subject.decide(at: .sessionStart) == .refused(.allowanceUnknown))
        #expect(await subject.decide(at: .stepBoundary) == .allowed)
        // Both moments really did open a request — a gate that answered from a cache would pass the
        // two assertions above while asserting nothing about a failed read.
        #expect(reader.fetchCount == 2)
    }

    /// A confirmable claim and runs in hand is the only combination that runs.
    @Test
    func theOnlyAllowedCombinationIsAConfirmedClaimWithRunsLeft() async {
        for entitlement in [EntitlementDecision.entitled, .refused(.lapsed)] {
            for allowance in [StubAllowanceReading.Answer.runsLeft(3), .runsLeft(0), .failure] {
                let (subject, _) = gate(entitlement: entitlement, allowance: allowance)
                let expected: Bool
                if case .runsLeft(let runs) = allowance {
                    expected = entitlement == .entitled && runs > 0
                } else {
                    expected = false
                }
                #expect(
                    await subject.decide(at: .sessionStart).isAllowed == expected,
                    "\(entitlement) with \(allowance)"
                )
            }
        }
    }

    // MARK: - The unwired gate

    /// A build that never installs a gate refuses screen control rather than running it.
    ///
    /// **The fail-closed direction of a wiring mistake**, which is the direction an `Optional` gate
    /// with a `?? .allowed` fallback would have got backwards.
    @Test
    func theUnwiredGateRefusesEveryMoment() async {
        let closed = ClosedScreenControlGate()

        #expect(await closed.decide(at: .sessionStart) == .refused(.allowanceUnknown))
        #expect(await closed.decide(at: .stepBoundary) == .refused(.allowanceUnknown))
    }

    // MARK: - Copy and reason codes

    /// The three sentences, by value, and the three reason codes, distinct.
    ///
    /// **Values rather than a completeness check**, for `theWipesOwnSentenceNamesEveryStoreItDeletes`'
    /// recorded reason: a switch compared against the same switch that built it sees a missing case
    /// and never a wrong word, and the allowance sentence is the one the ticket specified literally.
    @Test
    func eachRefusalCarriesItsOwnSentenceAndItsOwnCode() {
        #expect(
            ScreenControlGateRefusal.allowanceExhausted.userFacingReason
                == "You've used your screen-control allowance — top up or wait."
        )
        #expect(
            ScreenControlGateRefusal.allowanceUnknown.userFacingReason
                == "Sonny couldn't check your screen-control allowance. Try again in a moment."
        )
        #expect(
            ScreenControlGateRefusal.entitlementUnconfirmed(.notSignedIn).userFacingReason
                == "Sign in to Sonny to use this."
        )

        let codes = [
            ScreenControlGateRefusal.entitlementUnconfirmed(.lapsed).reasonCode,
            ScreenControlGateRefusal.allowanceExhausted.reasonCode,
            ScreenControlGateRefusal.allowanceUnknown.reasonCode
        ]
        #expect(Set(codes).count == codes.count, "reason codes must be distinct: \(codes)")
        #expect(codes.allSatisfy { !$0.isEmpty })
        // An exhausted allowance and one that could not be read are the two a reader is most likely
        // to conflate months later, and they are entirely different facts — one is billing, one is
        // an outage.
        #expect(
            ScreenControlGateRefusal.allowanceExhausted.reasonCode
                != ScreenControlGateRefusal.allowanceUnknown.reasonCode
        )
    }
}

/// **Direction two, behaviourally**: with no network, no session and no entitlement of any kind,
/// the free capabilities still run (SONNY-213).
///
/// The ticket names this as the direction that breaks offline Sonny if it is got backwards and asks
/// for it explicitly rather than as a consequence of direction one, so it is a test of its own
/// rather than an inference from the refusals above. `EntitlementFreePathTests` holds the same
/// property one layer earlier, at the *resolver*; this holds it at execution, which is where a gate
/// would have had to be consulted to block anything. `ScreenControlGateReachTests` in the app target
/// holds the structural half — that no adapter but the vision one can name the gate at all.
@Suite
@MainActor
struct ScreenControlGateFreeCapabilityTests {
    /// Three free capabilities execute in **both** shapes a context comes in: with no billing wiring
    /// at all, and with the live wiring the shipping app actually hands them.
    ///
    /// **The second case is the one that holds the property, and its absence was a real hole**
    /// (PR #190's F5). This test used to run `visionSession: nil` only, arguing that `nil` was
    /// "stronger than handing these adapters a refusing gate would be" because it proves the object
    /// need not exist. Measured, it is weaker, and in the one direction that matters: `nil` is the
    /// single configuration in which an adapter that *did* consult the gate still passes, because
    /// `context.visionSession?.screenControlGate` short-circuits to `nil` and execution carries on.
    /// A mutant giving `CalculatorCapabilityAdapter` exactly that consult **survived** this suite
    /// while dying against 50 tests elsewhere — so the property was held by tests written for other
    /// things, and the test named for it was the one test that did not hold it.
    ///
    /// **`visionSession` is not a vision-only channel**, which is why the second case is the shipping
    /// shape rather than a hypothetical: `AgentActionExecutor` builds one `CapabilityExecutionContext`
    /// carrying it and hands that same context to whichever adapter runs, so in the real app every
    /// free adapter's `execute` receives the live gate. Nothing structural stops one reading it; what
    /// stops it is that none does, which is a fact about the population and is held as one by
    /// `ScreenControlGateReachTests`' exact-set scan.
    ///
    /// **Each result is asserted by value, not by not-throwing.** An adapter that had acquired a
    /// billing dependency and failed soft would return an empty summary and pass a no-throw test.
    @Test(arguments: [false, true])
    func freeCapabilitiesExecuteWhateverBillingWiringIsInReach(withARefusingGate: Bool) async throws {
        // `nil` is "no billing wiring exists"; the environment is the shipping shape, carrying a gate
        // that refuses every moment. Neither may change what these three answer.
        let context = VisionTestContext.make(
            installed: [],
            vision: withARefusingGate ? Self.environmentCarrying(ClosedScreenControlGate()) : nil
        )

        let calculation = try await execute(
            AgentStep(
                id: "calc",
                operation: .calculateUtility,
                description: "What is 2 plus 2?",
                searchQuery: "2 + 2"
            ),
            in: context
        )
        #expect(calculation.contains("4"), "the calculation summarised as \(calculation.debugDescription)")

        let saved = try await execute(
            AgentStep(
                id: "save",
                operation: .saveSnippet,
                description: "Save snippet sig.",
                searchQuery: "sig",
                draftContent: "Sent from Sonny"
            ),
            in: context
        )
        #expect(saved.contains("sig"), "the save summarised as \(saved.debugDescription)")

        // The same context, so this really reads back what the step above wrote — a second context
        // would have a scratch store of its own and this would be a test of an empty one.
        let expanded = try await execute(
            AgentStep(
                id: "expand",
                operation: .expandSnippet,
                description: "Expand snippet sig.",
                searchQuery: "sig"
            ),
            in: context
        )
        #expect(
            expanded.contains("Sent from Sonny"),
            "the expansion summarised as \(expanded.debugDescription)"
        )
    }

    /// Runs one step through the real adapter `DefaultCapabilityAdapters` registers for it, the way
    /// the executor would pick it, and answers the summary.
    private func execute(_ step: AgentStep, in context: CapabilityExecutionContext) async throws -> String {
        let plan = AgentPlan(summary: "Do it.", requiresConfirmation: false, steps: [step])
        let adapter = try #require(
            DefaultCapabilityAdapters.all(finderRevealer: { _ in })
                .first { $0.metadata.operations.contains(step.operation) },
            "no adapter is registered for \(step.operation)"
        )
        // Nothing in this file constructs an `EntitlementService` or a `SonnyBackendClient`, so the
        // only gate any of these adapters could reach is the refusing one the context may carry.
        return try await adapter.execute(plan: plan, context: context) { _, _ in }.summary
    }

    /// A `VisionSessionEnvironment` whose only live part is the gate.
    ///
    /// Everything else is inert on purpose: this environment exists to be *carried* by a context, not
    /// driven, and the three adapters under test never touch a capture service, a synthesizer or a
    /// model client. Giving them real ones would put a screen capture and a network client inside a
    /// test about capabilities that need neither.
    private static func environmentCarrying(
        _ gate: any ScreenControlGating
    ) -> VisionSessionEnvironment {
        let permissions = DeterministicScreenPermissions()
        return VisionSessionEnvironment(
            captureService: ScreenCaptureService(permissionChecker: permissions),
            redactionService: LocalRedactionService(textRecognizer: InertTextRecognizer()),
            synthesizer: InertSynthesizer(),
            modelClient: InertVisionModel(),
            permissionChecker: permissions,
            screenControlGate: gate,
            interaction: nil
        )
    }

    /// Recognises nothing. Never called — the adapters under test capture no screen.
    private struct InertTextRecognizer: ImageTextRecognizing {
        func recognizeText(
            inPNGData pngData: Data,
            pixelWidth: Int,
            pixelHeight: Int
        ) async throws -> [RecognizedTextObservation] { [] }
    }

    /// Does nothing to the machine, and would be a defect if it were reached: these three
    /// capabilities move no windows and press no keys.
    private struct InertSynthesizer: ScreenActionSynthesizing {
        func activateApp(bundleIdentifier: String) async -> Bool { false }
        func frontmostBundleIdentifier() async -> String? { nil }
        func currentWindowFrame(windowID: UInt32) async -> CGRect? { nil }
        func ownWindowFrames() async -> [CGRect] { [] }
        func click(atGlobalPoint point: CGPoint) async throws {}
        func type(_ text: String) async throws {}
        func press(_ key: VisionActionKey) async throws {}
        func scroll(
            atGlobalPoint point: CGPoint?,
            direction: VisionScrollDirection,
            amount: Int
        ) async throws {}
    }

    /// Reaches no network. A call here would mean a free capability had started a vision session.
    private struct InertVisionModel: VisionModelDeciding {
        var transcriptDescription: String { "inert" }

        func decide(
            prompt: String,
            payload: RedactedPayload,
            session: VisionSessionRequestContext
        ) async throws -> String {
            throw InertModelReached()
        }
    }

    private struct InertModelReached: Error {}
}
