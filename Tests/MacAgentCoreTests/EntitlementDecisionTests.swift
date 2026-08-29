import Foundation
import Testing
@testable import MacAgentCore

/// The decision itself: the two clock-skew edges, the grace boundary, and every refusal that is not
/// about time (SONNY-135).
///
/// **These are the edges the ticket asks to be pinned at both ends**, and they are asserted at the
/// second because that is where a boundary either holds or does not: a test that checked "an hour
/// past grace is refused" would pass against an off-by-a-day implementation.
@Suite
struct EntitlementDecisionTests {
    static let issuedAt = SonnyISO8601.parse("2026-08-28T09:00:00Z")!
    static let session = SonnyAccountIdentity(userID: "user-1", emailAddress: "someone@example.com")
    static let capability = EntitlementCapability("test.capability")

    /// A day's life, three days' grace, five minutes' tolerance — the gateway's own values.
    static func claim(
        subject: String = "user-1",
        capabilities: [String] = ["test.capability"],
        lifetime: TimeInterval = 24 * 60 * 60,
        grace: TimeInterval = 72 * 60 * 60,
        tolerance: TimeInterval = 300
    ) -> EntitlementClaim {
        EntitlementClaim(
            version: 1,
            subject: subject,
            plan: "test-plan",
            capabilities: capabilities,
            issuedAt: issuedAt,
            expiresAt: issuedAt.addingTimeInterval(lifetime),
            graceSeconds: grace,
            skewToleranceSeconds: tolerance
        )
    }

    static func decide(at now: Date, claim: EntitlementClaim = claim()) -> EntitlementDecision {
        EntitlementJudgement.judge(claim: claim, capability: capability, session: session, now: now)
    }

    // MARK: - The ordinary answers

    @Test
    func aCurrentClaimNamingTheCapabilityIsEntitled() {
        #expect(Self.decide(at: Self.issuedAt.addingTimeInterval(60)) == .entitled)
    }

    @Test
    func aCurrentClaimNotNamingTheCapabilityIsRefused() {
        // The other direction of fail-closed at its narrowest: a perfectly valid, current, verified
        // claim that simply does not grant this. §7.2 case 2.
        let decision = Self.decide(
            at: Self.issuedAt.addingTimeInterval(60),
            claim: Self.claim(capabilities: ["something.else"])
        )
        #expect(decision == .refused(.notEntitled))
    }

    @Test
    func aClaimAboutAnotherSessionIsRefusedBeforeAnythingAboutTimeIsChecked() {
        // A claim cached before a sign-out must not grant anything to whoever signs in next. It is
        // refused for *whose* it is rather than for being stale, because reporting it as expired
        // would send the user to a refresh that changes nothing about what they hold — and it is
        // refused even at an instant where every time check would have passed.
        let decision = Self.decide(
            at: Self.issuedAt.addingTimeInterval(60),
            claim: Self.claim(subject: "somebody-else")
        )
        #expect(decision == .refused(.claimIsForAnotherSession))
    }

    // MARK: - The expiry edge, at the second

    @Test
    func anExpiredClaimInsideTheGraceWindowStillWorks() {
        // The requirement in one line: a user on a plane is not locked out the moment a token
        // expires. One second past expiry, and one second short of the whole window.
        let expiry = Self.issuedAt.addingTimeInterval(24 * 60 * 60)
        #expect(Self.decide(at: expiry.addingTimeInterval(1)) == .entitled)
        #expect(Self.decide(at: expiry.addingTimeInterval(72 * 60 * 60 - 1)) == .entitled)
    }

    @Test
    func pastTheGraceWindowAndItsToleranceTheClaimIsRefused() {
        // The other half, at the second. The tolerance extends this edge by five minutes and is
        // asserted here rather than described: at the boundary it is honoured, one second past it is
        // not.
        let expiry = Self.issuedAt.addingTimeInterval(24 * 60 * 60)
        let lastHonoured = expiry.addingTimeInterval(72 * 60 * 60 + 300)
        #expect(Self.decide(at: lastHonoured) == .entitled)
        #expect(Self.decide(at: lastHonoured.addingTimeInterval(1)) == .refused(.lapsed))
        // And far past it, so nothing about the boundary rests on an arithmetic coincidence.
        #expect(Self.decide(at: expiry.addingTimeInterval(365 * 24 * 60 * 60)) == .refused(.lapsed))
    }

    @Test
    func theRevocationBoundIsTheClaimsLifePlusItsGrace() {
        // The number the ticket asks to be stated and justified: four days offline, and it is a
        // property of the two values rather than a constant written anywhere.
        let claim = Self.claim()
        let offlineBound = claim.honouredUntil.timeIntervalSince(claim.issuedAt)
        let day: TimeInterval = 24 * 60 * 60
        let grace: TimeInterval = 72 * 60 * 60
        let tolerance: TimeInterval = 300
        #expect(offlineBound == day + grace + tolerance)
        // Four days and five minutes, in hours, so the figure a reader would quote is the one the
        // arithmetic produces.
        #expect(offlineBound / 3600 > 96)
        #expect(offlineBound / 3600 < 97)
    }

    // MARK: - The not-yet-valid edge, at the second

    @Test
    func aClockBehindByLessThanTheToleranceStillWorks() {
        // A Mac whose clock is a few minutes slow reads a freshly issued claim as not yet valid.
        // Refusing it would lock out a paying user for a clock error, and `issued_at` is signed, so
        // there is nothing a forgery gains from the tolerance. Asserted at the boundary and one
        // second inside it.
        #expect(Self.decide(at: Self.issuedAt.addingTimeInterval(-299)) == .entitled)
        #expect(Self.decide(at: Self.issuedAt.addingTimeInterval(-300)) == .entitled)
    }

    @Test
    func aClockBehindByMoreThanTheToleranceIsRefusedAsAClockProblem() {
        // Its own refusal rather than `.lapsed`, because the user's action is different: a clock that
        // is minutes or days out is something they can fix, and telling them their plan expired
        // would be both wrong and unactionable.
        #expect(Self.decide(at: Self.issuedAt.addingTimeInterval(-301)) == .refused(.clockUnusable))
        #expect(Self.decide(at: Self.issuedAt.addingTimeInterval(-365 * 24 * 60 * 60))
            == .refused(.clockUnusable))
    }

    // MARK: - The instant a claim is judged at

    // **The two tests that stood here are gone, and their subject moved to the service** (PR #152's
    // review, F1). They called `EntitlementJudgement.effectiveNow(serverNow:highWaterMark:)` with a
    // mark placed well past the claim's expiry and asserted that the later of the two won — which is
    // true of `max` and says nothing about the product, because the only writer of that mark could
    // never produce such a pair. The function is deleted; the property is now held by
    // `EntitlementServiceTests.aClockRolledBackOfflineCannotReEnterALapsedWindow` and its two
    // neighbours, which drive `refreshNow()` and then move a wall clock and a monotonic clock
    // independently — which is what a user setting their Mac back actually does.
    //
    // What stays here is the pure half a pure test can hold: how an instant, once arrived at, is
    // judged against a claim.

    // MARK: - When to fetch a new one

    @Test
    func aClaimIsRefreshedAThirdOfTheWayThroughItsOwnLife() {
        // Derived from what the claim carries rather than from a constant here, so the gateway can
        // change the cadence without an app release. A third, so one missed refresh does not spend
        // the grace window that exists for being genuinely offline.
        let claim = Self.claim()
        #expect(!EntitlementJudgement.shouldRefresh(claim: claim, now: Self.issuedAt))
        #expect(!EntitlementJudgement.shouldRefresh(
            claim: claim, now: Self.issuedAt.addingTimeInterval(8 * 60 * 60 - 1)
        ))
        #expect(EntitlementJudgement.shouldRefresh(
            claim: claim, now: Self.issuedAt.addingTimeInterval(8 * 60 * 60)
        ))
        // A claim whose expiry is not after its issue is nonsense; refreshing is the only safe answer
        // and it avoids a division that would be meaningless.
        #expect(EntitlementJudgement.shouldRefresh(
            claim: Self.claim(lifetime: 0), now: Self.issuedAt.addingTimeInterval(-1)
        ))
    }
}
