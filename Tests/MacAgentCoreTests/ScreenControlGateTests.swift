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
    /// Three free capabilities execute with `visionSession: nil` — no gate, no entitlement service,
    /// no allowance reader and nothing to reach one with.
    ///
    /// **`nil` is the honest shape of "no billing wiring at all"**, and it is stronger than handing
    /// these adapters a refusing gate would be: a refusing gate proves they ignore one particular
    /// object, while this proves the object need not exist. That is §5.3.1's own code shape — "a
    /// check that is never made cannot fail closed" — read in the direction this ticket is about.
    ///
    /// **Each result is asserted by value, not by not-throwing.** An adapter that had acquired a
    /// billing dependency and failed soft would return an empty summary and pass a no-throw test.
    @Test
    func freeCapabilitiesExecuteWithNoBillingWiringInReach() async throws {
        let context = VisionTestContext.make(installed: [], vision: nil)

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
            DefaultCapabilityAdapters.all().first { $0.metadata.operations.contains(step.operation) },
            "no adapter is registered for \(step.operation)"
        )
        // Nothing in this file constructs an `EntitlementService`, a `ScreenControlGate` or a
        // `SonnyBackendClient`, and nothing these three adapters call can reach one.
        return try await adapter.execute(plan: plan, context: context) { _, _ in }.summary
    }
}
