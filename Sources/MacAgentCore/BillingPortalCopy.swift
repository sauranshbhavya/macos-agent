import Foundation

/// Why the hosted billing portal did not open, and what the user is told (SONNY-216, PR #183's F4).
///
/// **This exists because the portal press was reusing `SignInFailure`, and that produced sentences
/// that were wrong rather than merely generic.** `SignInCopy`'s own doc comment calls itself "every
/// user-facing sentence the **sign-in flow** can show", and `SignInFailure` already carries a
/// recorded warning from PR #133's F9 that reusing it outside sign-in makes a wrong sentence the
/// moment another route does. It did, on the two errors most likely to arrive:
///
/// - `provider.rejected` — whose whole meaning is that an identical retry fails identically, and
///   which the route marks `retryable: false` — mapped to `.backendUnreachable`, whose sentence
///   ends "**Try again in a moment.**" That is the rotation outage `server/README.md` describes,
///   answered with advice that cannot work.
/// - `entitlement.no_subscription` had no name in `SonnyBackendErrorCode` at all, so it became
///   `.unknown` and then `.unexpected` — "**Sonny couldn't finish signing you in.**" — shown to
///   somebody who is signed in and pressed Manage subscription.
///
/// **The server half's retryable/not-retryable taxonomy is preserved to the last step**, which was
/// the point of building it: a case that a retry can fix says so, and a case a retry cannot fix
/// does not.
public enum BillingPortalFailure: Equatable, Sendable, CaseIterable {
    /// There is no subscription on this account. §7.2's `entitlement.no_subscription`.
    ///
    /// **Reachable, even though the row is not offered without a subscription.** The claim can be a
    /// few hours stale, so a subscription that ended since the last refresh still renders a row.
    case nothingToManage
    /// The provider could not be reached, timed out, or throttled us. Waiting is the whole remedy.
    case temporarilyUnavailable
    /// The provider answered and refused, or this build could not read what it sent. **A retry
    /// fails identically**, so the sentence does not suggest one.
    case cannotBeOpened
    /// No network on this Mac.
    case offline
    /// The session is gone. Distinct because it is the one case whose action is signing in again.
    case signedOut

    public init(_ error: SonnyBackendError) {
        switch error {
        case .offline:
            self = .offline
        case .unreachable, .timedOut:
            self = .temporarilyUnavailable
        case .undecodableResponse, .cancelled, .backendNotConfigured:
            self = .cannotBeOpened
        case .notSignedIn:
            self = .signedOut
        case .api(let api):
            self.init(code: api.code)
        }
    }

    private init(code: SonnyBackendErrorCode) {
        switch code {
        case .entitlementNoSubscription:
            self = .nothingToManage
        case .authUnauthenticated, .authTokenExpired, .authTokenRevoked:
            self = .signedOut
        // **`limitRate` is here and not with the refusals**, because it is the same rule
        // `server/src/auth/supabase.ts:521-525` states for the gateway's own upstreams: a rate limit
        // is a statement about capacity, never about whether the request was right.
        case .limitRate, .providerUnavailable, .providerTimeout, .serverError, .serverUnavailable:
            self = .temporarilyUnavailable
        case .providerRejected, .limitSpend, .requestInvalid, .requestTooLarge, .resourceNotFound,
             .idempotencyConflict, .versionUnsupported, .authCodeInvalid, .authCodeExpired,
             .authCodeUsed, .entitlementRequired, .entitlementExpired, .unknown:
            // A code this build has never heard of is not something to guess at in front of a user,
            // and the honest general answer here is the one that promises nothing.
            self = .cannotBeOpened
        }
    }
}

/// What the user reads when the portal does not open.
///
/// **Functional, not explanatory**, on the same standing rule as `SignInCopy` and
/// `SubscriptionCopy`: what happened and what to do next. None of these says what the portal is,
/// why a subscription might have ended, or how any of it works.
public enum BillingPortalCopy {
    public static func message(for failure: BillingPortalFailure) -> String {
        switch failure {
        case .nothingToManage:
            return "There's no subscription on this account."
        case .temporarilyUnavailable:
            return "Sonny couldn't open your billing page. Try again in a moment."
        case .cannotBeOpened:
            // **No "try again", deliberately.** This is the case where a retry fails identically —
            // a revoked provider credential is the live example, and `server/README.md`'s rotation
            // section describes exactly that outage.
            return "Sonny couldn't open your billing page."
        case .offline:
            return "Connect to the internet to manage your subscription."
        case .signedOut:
            return "Sign in to Sonny to manage your subscription."
        }
    }
}
