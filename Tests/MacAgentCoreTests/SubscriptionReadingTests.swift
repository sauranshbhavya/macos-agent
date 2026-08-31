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
        // to review: the line is the plan and one word. A mutant that appended a sentence about what
        // "Ended" means fails on the exact-equality here.
        #expect(SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "paid", status: .active)) == "Paid · Active")
        #expect(SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "paid", status: .ended)) == "Paid · Ended")
        #expect(SubscriptionCopy.manageLabel == "Manage subscription")
    }

    @Test func thePlanKeyIsShownAsTheGatewaySentItApartFromItsCase() {
        // SONNY-212 owns what the plans are and `EntitlementClaim` says this repository never
        // enumerates plan keys, so there is no translation table here and this is what pins that:
        // an unfamiliar key renders rather than falling back to a word this ticket invented.
        #expect(
            SubscriptionCopy.line(for: SubscriptionSnapshot(plan: "team-annual", status: .active))
                == "Team-Annual · Active"
        )
    }
}
