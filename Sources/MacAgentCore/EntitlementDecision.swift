import Foundation

/// Whether this Mac may do a gated thing right now, and — when it may not — which of the several
/// different "no"s this is (SONNY-135).
///
/// **The cases are separate because the user's answer is different for each**, which is this
/// repository's error-handling-is-UX rule applied to a check rather than to a failure. Being signed
/// out, being on a plan that does not include something, and holding a claim that has gone stale on
/// a laptop that has been offline for four days are three different sentences and three different
/// next actions.
public enum EntitlementDecision: Equatable, Sendable {
    case entitled
    case refused(EntitlementRefusal)

    public var isEntitled: Bool { self == .entitled }
}

public enum EntitlementRefusal: Equatable, Sendable {
    /// No session is held on this Mac. §7.2 case 1.
    case notSignedIn
    /// Signed in, but nothing has ever been cached — a first run that has not yet been online.
    case noClaim
    /// Something was cached and this build cannot verify or read it. **Refused, never assumed.**
    case unreadableClaim
    /// The cached claim is about a different session than the one this Mac holds.
    case claimIsForAnotherSession
    /// The claim is not yet valid even after its own tolerance, which can only be this Mac's clock.
    case clockUnusable
    /// Past expiry, past the grace window, past the tolerance. §7.2 case 2a.
    case lapsed
    /// A valid, current claim that does not name this capability. §7.2 case 2.
    case notEntitled
}

/// The decision itself, as a pure function of a claim, a capability and an instant.
///
/// **Pure and separate from the service on purpose.** Every edge this ticket has to pin — the two
/// clock-skew edges, the grace boundary, a claim belonging to another session — is a question about
/// these four values and nothing else, and a test that had to build an actor, a Keychain and a
/// network client to ask one of them would be testing the wiring instead of the rule.
public enum EntitlementJudgement {
    /// The instant to judge a claim at.
    ///
    /// **The later of server time and the highest server instant this Mac has ever seen.** Expiry is
    /// checked against a clock the user controls, and `SonnyBackendClient`'s offset (§3.5) only
    /// corrects drift *since the last response* — it lives in memory, so a relaunch with no network
    /// leaves it at zero and server time collapses onto the local clock. Taking the later of the two
    /// means moving the Mac's clock backwards cannot undo an expiry that has already been observed.
    ///
    /// **It deliberately does not clamp the other way.** A clock set *forward* still reads as later,
    /// and it is absorbed by the grace window and the claim's own tolerance rather than by this — and
    /// past those it refuses, which is the fail-closed direction. Clamping forward movement would
    /// need an upper bound this Mac has no way to know.
    public static func effectiveNow(
        serverNow: Date,
        highWaterMark: Date?
    ) -> Date {
        guard let highWaterMark else { return serverNow }
        return max(serverNow, highWaterMark)
    }

    public static func judge(
        claim: EntitlementClaim,
        capability: EntitlementCapability,
        session: SonnyAccountIdentity,
        now: Date
    ) -> EntitlementDecision {
        // **Checked before anything about time**, because a claim about somebody else is not stale,
        // it is irrelevant — and reporting it as expired would send the user to a refresh that
        // changes nothing about the claim they are holding.
        guard claim.subject == session.userID else {
            return .refused(.claimIsForAnotherSession)
        }
        // Not yet valid even after the tolerance. The claim's `issued_at` is signed, so this can only
        // be this Mac's clock being behind by more than the claim allows for.
        guard now >= claim.honouredFrom else { return .refused(.clockUnusable) }
        // Past expiry, past grace, past tolerance.
        guard now <= claim.honouredUntil else { return .refused(.lapsed) }
        guard claim.grants(capability) else { return .refused(.notEntitled) }
        return .entitled
    }

    /// Is this claim old enough that a client should fetch a new one?
    ///
    /// **Derived from the claim's own life rather than from a constant here**, so the server can
    /// change the cadence without an app release, exactly as it can change grace and tolerance. A
    /// third of the way through is what `ENTITLEMENT_REFRESH_AFTER_SECONDS` sets on the gateway; this
    /// computes the same point from what the claim carries, because §5.3 puts `refresh_after` in the
    /// response envelope rather than in the signed payload and the envelope is not what is cached.
    public static func shouldRefresh(claim: EntitlementClaim, now: Date) -> Bool {
        let life = claim.expiresAt.timeIntervalSince(claim.issuedAt)
        guard life > 0 else { return true }
        return now >= claim.issuedAt.addingTimeInterval(life / 3)
    }
}
