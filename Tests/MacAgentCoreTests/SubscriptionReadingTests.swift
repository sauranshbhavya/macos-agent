import Foundation
import Testing
@testable import MacAgentCore

/// What the Account section is allowed to say about a subscription (SONNY-216).
///
/// **The claim carries no status field and one was deliberately not added**, so every value here is
/// derived from `plan` and `capabilities` and from the claim's own window. The founders' ruling of
/// 2026-08-31 was "say what the claim can prove", and what these tests hold is the *boundary* of
/// that — four situations where the honest answer is nothing at all, and they are the half most
/// likely to be lost to a later simplification.
@Suite struct SubscriptionReadingTests {
    static let session = SonnyAccountIdentity(userID: "user-1", emailAddress: "a@example.test")
    static let issuedAt = SonnyISO8601.parse("2026-08-28T09:00:00Z")!
    static let now = issuedAt.addingTimeInterval(60 * 60)

    static func claim(
        subject: String = "user-1",
        plan: String = "paid",
        capabilities: [String] = ["screen_control"],
        issuedAt: Date = SubscriptionReadingTests.issuedAt,
        lifetime: TimeInterval = 24 * 60 * 60
    ) -> EntitlementClaim {
        EntitlementClaim(
            version: 1,
            subject: subject,
            plan: plan,
            capabilities: capabilities,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            graceSeconds: 72 * 60 * 60,
            skewToleranceSeconds: 300
        )
    }

    @Test func aClaimGrantingSomethingReadsAsActive() {
        let snapshot = SubscriptionReading.read(claim: Self.claim(), session: Self.session, now: Self.now)

        #expect(snapshot == SubscriptionSnapshot(plan: "paid", status: .active))
    }

    @Test func aClaimGrantingNothingReadsAsEnded() {
        // The shape a revoked subscription takes: `server/src/entitlement/store.ts` keeps the plan
        // key and empties the capability list, so that a refreshing client stops allowing gated
        // features immediately rather than waiting out the claim it holds. The plan surviving is
        // what makes this distinguishable from an account that never subscribed.
        let snapshot = SubscriptionReading.read(
            claim: Self.claim(capabilities: []),
            session: Self.session,
            now: Self.now
        )

        #expect(snapshot == SubscriptionSnapshot(plan: "paid", status: .ended))
    }

    @Test func theAbsenceOfAPlanIsNotASubscription() {
        // **The one test that decides whether a never-subscribed user is offered a broken control.**
        // `server/src/entitlement/store.ts:133` mints `plan: "none"` in `unprovisioned`, and its own
        // comment says that value "is not a tier name. It is the absence of a plan record." Without
        // this arm that account reads as `.ended`, the Account section offers Manage subscription,
        // and the press reaches a portal the provider has no customer for — which the gateway
        // refuses with `409 entitlement.no_subscription`, but a control that only fails when pressed
        // is a broken control (founder direction, 2026-08-31).
        //
        // **This is also the one place this repository depends on a literal whose meaning is set on
        // the other side of the wire.** If SONNY-212 renames it, this is what fails.
        #expect(SubscriptionReading.absentPlan == "none")
        let snapshot = SubscriptionReading.read(
            claim: Self.claim(plan: "none", capabilities: []),
            session: Self.session,
            now: Self.now
        )

        #expect(snapshot == nil)
    }

    @Test func anEmptyPlanIsAlsoNotASubscription() {
        // Not a shape the gateway sends, and refused anyway: `"".capitalized` is `""`, so the line
        // would render as a bare separator with a Manage control beside it.
        #expect(
            SubscriptionReading.read(claim: Self.claim(plan: ""), session: Self.session, now: Self.now) == nil
        )
    }

    @Test func aClaimAboutAnotherSessionSaysNothing() {
        // Checked before anything about time, for `EntitlementJudgement.judge`'s reason: a claim
        // about somebody else is not stale, it is irrelevant — and rendering its plan would show the
        // previous user's subscription to whoever signed in next on this Mac.
        let snapshot = SubscriptionReading.read(
            claim: Self.claim(subject: "somebody-else"),
            session: Self.session,
            now: Self.now
        )

        #expect(snapshot == nil)
    }

    @Test func aClaimPastItsWholeWindowSaysNothing() {
        // Expiry plus grace plus tolerance. Past that the claim establishes nothing, and the Account
        // section shows no line rather than a stale one — a subscription may be perfectly healthy
        // while this Mac has simply been offline for five days, so "Ended" would be a lie about the
        // subscription rather than a statement about the claim.
        let claim = Self.claim()
        #expect(
            SubscriptionReading.read(
                claim: claim,
                session: Self.session,
                now: claim.honouredUntil.addingTimeInterval(1)
            ) == nil
        )
        // And the boundary itself still reads, which is the direction a `<` would silently break.
        #expect(
            SubscriptionReading.read(claim: claim, session: Self.session, now: claim.honouredUntil) != nil
        )
    }

    @Test func aClaimFromTheFutureSaysNothing() {
        // This Mac's clock is behind by more than the claim's own tolerance. Same reasoning as
        // `judge`'s `clockUnusable`: what is wrong is the clock, and nothing about the subscription
        // is known.
        let claim = Self.claim()
        #expect(
            SubscriptionReading.read(
                claim: claim,
                session: Self.session,
                now: claim.honouredFrom.addingTimeInterval(-1)
            ) == nil
        )
        #expect(
            SubscriptionReading.read(claim: claim, session: Self.session, now: claim.honouredFrom) != nil
        )
    }

    @Test func theLineNamesThePlanAndTheStateAndExplainsNeither() {
        // The standing rule that the product does not explain itself, asserted rather than trusted
        // to review: the line is the plan and one word — two, for the state that needs two. A mutant
        // that appended a sentence about what "Ended" means, or about how long a grace window runs,
        // fails on the exact-equality here.
        #expect(
            SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "paid", status: .active), payment: .current)
                == "Paid · Active"
        )
        #expect(
            SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "paid", status: .ended), payment: .current)
                == "Paid · Ended"
        )
        #expect(
            SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "paid", status: .active), payment: .pastDue)
                == "Paid · Past due"
        )
        #expect(SubscriptionCopy.manageLabel == "Manage subscription")
        #expect(SubscriptionCopy.updatePaymentLabel == "Update payment")
        #expect(SubscriptionCopy.pastDueWord == "Past due")
    }

    @Test func thePlanKeyIsShownAsTheGatewaySentItApartFromItsCase() {
        // SONNY-212 owns what the plans are and `EntitlementClaim` says this repository never
        // enumerates plan keys, so there is no translation table here and this is what pins that:
        // an unfamiliar key renders rather than falling back to a word this ticket invented.
        #expect(
            SubscriptionCopy.line(
                for: SubscriptionSnapshot(plan: "team-annual", status: .active),
                payment: .current
            ) == "Team-Annual · Active"
        )
    }

    // MARK: - What a past-due reading does to the line (SONNY-380)

    @Test func aPastDueReadingCannotRenderAsActive() {
        // **The ticket's central property, asserted over the whole population rather than on a
        // case.** §16.4 keeps the capabilities through the grace window on purpose, so the claim a
        // past-due customer holds is byte-identical to a healthy one's and `status` is `.active` for
        // both — this is the only thing that can tell them apart. Every claim state, against the
        // past-due reading: none of them may produce the word the defect was.
        for status in [SubscriptionStatus.active, .ended] {
            let line = SubscriptionCopy.line(
                for: SubscriptionSnapshot(plan: "paid", status: status),
                payment: .pastDue
            )

            #expect(line == "Paid · Past due", "status \(status)")
            // Asserted as an absence too, because the equality above would still hold if a later
            // change made the word a substring of a longer one.
            #expect(!line.contains("Active"), "status \(status)")
        }
    }

    @Test func aPastDueReadingNamesTheControlThatResolvesIt() {
        // The founders' decision of 2026-09-05 asks for "the control that resolves it", and what
        // resolves a declined card is not managing a subscription. One button, two labels, the same
        // hosted portal behind both.
        #expect(SubscriptionCopy.controlLabel(for: .pastDue) == "Update payment")
        #expect(SubscriptionCopy.controlLabel(for: .current) == "Manage subscription")
        #expect(SubscriptionCopy.controlLabel(for: nil) == "Manage subscription")
        #expect(SubscriptionCopy.controlLabel(for: .unrecognised) == "Manage subscription")
    }

    @Test func aMacThatKnowsNothingAboutPaymentSaysNothingAboutIt() {
        // The offline answer, which the founders chose on 2026-09-05: the grace window keeps
        // capabilities working without a network, so a Mac that cannot reach the gateway shows the
        // line the claim alone supports rather than guessing in either direction.
        let active = SubscriptionSnapshot(plan: "paid", status: .active)
        let ended = SubscriptionSnapshot(plan: "paid", status: .ended)

        #expect(SubscriptionCopy.line(for: active, payment: nil) == "Paid · Active")
        #expect(SubscriptionCopy.line(for: ended, payment: nil) == "Paid · Ended")
        // And `current` is not a third rendering: it says the same thing as knowing nothing, because
        // what it means is the absence of a failure rather than a fact about a payment.
        #expect(SubscriptionCopy.line(for: active, payment: .current) == "Paid · Active")
    }

    @Test func aValueThisBuildDoesNotKnowIsToleratedAndSaysNothing() {
        // §8.2 item 7: the server may add a value to a wire enum only because every client carries
        // an unknown fallback, and this is that fallback doing the honest thing — an unrecognised
        // state is not asserted as anything, so the line falls back to what the claim proves.
        #expect(BillingPaymentState(wire: "settled_yesterday") == .unrecognised)
        #expect(BillingPaymentState(wire: "") == .unrecognised)
        #expect(
            SubscriptionCopy.line(
                for: SubscriptionSnapshot(plan: "paid", status: .active),
                payment: .unrecognised
            ) == "Paid · Active"
        )
    }

    @Test func theWireValuesAreTheOnesTheContractNames() {
        // The two literals whose meaning is set on the other side of the wire, in the one place they
        // are written down on this side. §4.1's row for `GET /v1/billing/payment-state` is what
        // these have to agree with, and `billing/store.ts`'s `BillingPaymentState` is what serves
        // them; a rename on either side fails here rather than silently reading as unrecognised —
        // which would present as the line quietly saying `Active` again.
        #expect(BillingPaymentState(wire: "current") == .current)
        #expect(BillingPaymentState(wire: "past_due") == .pastDue)
        // Case and shape are exact, not tolerated: a server sending `PAST_DUE` has changed the
        // contract, and reading it anyway would hide that.
        #expect(BillingPaymentState(wire: "PAST_DUE") == .unrecognised)
        #expect(BillingPaymentState(wire: "pastDue") == .unrecognised)
    }
}
