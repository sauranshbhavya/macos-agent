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
    /// **`effectiveNow` used to live here and is deliberately gone** (SONNY-135, PR #152's review,
    /// F1). It took a `serverNow` and a `highWaterMark` and answered the later of the two, and its
    /// doc claimed that "moving the Mac's clock back cannot undo an expiry" — a property two values
    /// cannot have on their own, because the mark it was handed was always the cached claim's own
    /// issue time and could therefore never land past `honouredUntil`. The two tests that held it
    /// passed a mark the production writer could not produce, so they were green and silent.
    ///
    /// The instant a claim is judged at is now computed in `EntitlementService.effectiveNow`, where
    /// the inputs that make it trustworthy actually live: an instant a server reported, carried
    /// forward by a monotonic clock. What stays pure and testable here is the judgement below.

    public static func judge(
        claim: EntitlementClaim,
        capability: EntitlementCapability,
        session: SonnyAccountIdentity,
        now: Date
    ) -> EntitlementDecision {
        // **Every rule except the capability one, from the single place that holds them.** Spelling
        // them out here as well as in `confirm` would be two copies of the clock defence, and the
        // copy that drifted would be the one nothing was looking at.
        let confirmation = confirm(claim: claim, session: session, now: now)
        guard case .entitled = confirmation else { return confirmation }
        guard claim.grants(capability) else { return .refused(.notEntitled) }
        return .entitled
    }

    /// Everything ``judge(claim:capability:session:now:)`` asks **except which capability the claim
    /// names** — does this Mac hold a current, verifiable claim about its own session (SONNY-213)?
    ///
    /// **It exists because row 18 has not decided what the keys are, and this ticket must not decide
    /// for it.** SONNY-213 gates screen control on the entitlement cache being able to confirm, and
    /// no capability key exists anywhere under `Sources/` —
    /// `EntitlementSourceScanTests.theGatedCapabilitySetIsRowEighteensAndThisRepositoryNamesNoKey`
    /// holds that as a population scan, and it holds it because row 18 (SONNY-23) owns which
    /// capability gates which feature. A gate that invented a key to ask about would be taking that
    /// decision in row 13.
    ///
    /// **So this is a narrowing and never a widening.** Every refusal `judge` can produce, this one
    /// produces too, on the same values and in the same order — the session check first, then the
    /// two clock edges. The only answer it cannot give is `.notEntitled`, which is precisely the
    /// question it declines to ask. `judge` is written in terms of it, so the day row 18 mints a key
    /// the gate becomes a `judge` call and every rule below it is already the one being applied.
    public static func confirm(
        claim: EntitlementClaim,
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
