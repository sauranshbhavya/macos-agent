import Foundation

/// Why a billing *setting* would not change, and what the user is told (SONNY-215).
///
/// **A third failure vocabulary beside `SignInFailure` and `BillingPortalFailure`, for the reason
/// the second one exists.** `BillingPortalCopy`'s own doc records what reusing `SignInFailure`
/// outside sign-in produced: sentences that were wrong rather than merely generic — a not-retryable
/// refusal answered with "Try again in a moment", and a signed-in user pressing Manage subscription
/// told Sonny could not finish signing them in. The same reuse here would produce the same class of
/// sentence about a switch.
///
/// **Three cases and not five, because a setting has fewer things it can mean than a portal does.**
/// There is nothing here to be "not found", and no provider is called: the gateway writes a row. So
/// what is left is whether waiting helps, whether signing in does, or neither.
public enum BillingSettingFailure: Equatable, Sendable, CaseIterable {
    /// Something transient — no network, a timeout, a rate limit, a server error. Waiting helps.
    case temporarilyUnavailable
    /// The session is gone. Distinct because it is the one case whose action is signing in again.
    case signedOut
    /// Anything else. **A retry is not suggested**, because nothing here suggests one would work.
    case cannotBeChanged

    public init(_ error: SonnyBackendError) {
        switch error {
        case .offline, .unreachable, .timedOut:
            self = .temporarilyUnavailable
        case .undecodableResponse, .cancelled, .backendNotConfigured:
            self = .cannotBeChanged
        case .notSignedIn:
            self = .signedOut
        case .api(let api):
            self.init(code: api.code)
        }
    }

    private init(code: SonnyBackendErrorCode) {
        switch code {
        case .authUnauthenticated, .authTokenExpired, .authTokenRevoked:
            self = .signedOut
        // **`limitRate` sits with the transient ones and not with the refusals**, which is the rule
        // `server/src/auth/supabase.ts:521-525` states and `BillingPortalFailure` already follows: a
        // rate limit is a statement about capacity, never about whether the request was right.
        case .limitRate, .providerUnavailable, .providerTimeout, .serverError, .serverUnavailable,
             .requestTimeout:
            // `requestTimeout` joins them on exactly the rule the comment above states: a body that
            // did not arrive in time is a statement about the connection, never about whether the
            // request was right.
            self = .temporarilyUnavailable
        case .providerRejected, .limitSpend, .requestInvalid, .requestTooLarge, .resourceNotFound,
             .idempotencyConflict, .versionUnsupported, .authCodeInvalid, .authCodeExpired,
             .authCodeUsed, .entitlementRequired, .entitlementExpired, .entitlementNoSubscription,
             .unknown:
            // A code this build has never heard of is not something to guess at in front of a user,
            // and the honest general answer is the one that promises nothing.
            self = .cannotBeChanged
        }
    }
}

/// What the user reads when a billing setting does not change.
///
/// **Functional, not explanatory**, on the same standing rule as `SignInCopy`, `SubscriptionCopy`
/// and `BillingPortalCopy`: what happened and what to do next. None of these says what auto top-up
/// is, what it costs, or when it fires — that is the website's, and the control's own name is what
/// carries its meaning in the product.
public enum BillingSettingCopy {
    public static func message(for failure: BillingSettingFailure) -> String {
        switch failure {
        case .temporarilyUnavailable:
            return "Sonny couldn't change that setting. Try again in a moment."
        case .signedOut:
            return "Sign in to Sonny to change that setting."
        case .cannotBeChanged:
            // **No "try again", deliberately** — the same call `BillingPortalCopy.cannotBeOpened`
            // makes. This is the case where nothing says a retry would land differently.
            return "Sonny couldn't change that setting."
        }
    }
}
