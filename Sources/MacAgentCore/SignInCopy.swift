import Foundation

/// What went wrong signing in, in the app's own vocabulary rather than the wire's.
///
/// **This exists because §7.1 forbids displaying the server's `message`.** The server's sentence is
/// for logs and the support lookup; a sentence authored on the server and rendered in the app is a
/// hole straight through Sonny's standing rule that the product does not explain itself, editable by
/// whoever edits the server with no review from anyone who knows that rule. So `code` maps to a case
/// here, and a case maps to words this repository owns.
public enum SignInFailure: Equatable, Sendable, CaseIterable {
    /// What was typed is not an address the backend will accept.
    case emailInvalid
    /// The code was wrong. §7.2's `auth.code_invalid`.
    case codeIncorrect
    /// The code was right once and is past its life. `auth.code_expired`.
    case codeExpired
    /// The code was already spent. `auth.code_used`.
    case codeAlreadyUsed
    /// A rate limit. `limit.rate`, which is a state that clears by waiting.
    case tooManyAttempts
    /// A spend cap. `limit.spend`, which is **not** time-bounded — §7.2 case 3a gives it no
    /// `Retry-After` precisely because waiting seconds does not fix it. Unreachable on the three
    /// unauthenticated auth routes today; it is here because `SignInFailure` is the only typed-
    /// error-to-copy mapping in the tree, so SONNY-130 and SONNY-136 will reuse it, and "try again
    /// in a few minutes" becomes a wrong sentence the moment they do (PR #133, F9).
    case outOfAllowance
    /// No network on this Mac. Everything Sonny does locally still works.
    case offline
    /// The network is fine and the backend is not: DNS, TLS, a refused connection, a 5xx, a
    /// timeout. One case, because there is exactly one thing a user can do about all of them.
    case backendUnreachable
    /// This build has no backend host. Reachable only until SONNY-192 chooses one.
    case notConfigured
    /// The stored session is gone — revoked, reused, or attributable to no live account.
    case signedOut
    /// Anything this build does not recognise, including a `code` added after it shipped.
    case unexpected

    public init(_ error: SonnyBackendError) {
        switch error {
        case .offline:
            self = .offline
        case .unreachable, .timedOut, .undecodableResponse:
            self = .backendUnreachable
        case .cancelled:
            self = .unexpected
        case .backendNotConfigured:
            self = .notConfigured
        case .notSignedIn:
            self = .signedOut
        case .api(let api):
            self.init(code: api.code)
        }
    }

    private init(code: SonnyBackendErrorCode) {
        switch code {
        case .authCodeInvalid:
            self = .codeIncorrect
        case .authCodeExpired:
            self = .codeExpired
        case .authCodeUsed:
            self = .codeAlreadyUsed
        case .limitRate:
            self = .tooManyAttempts
        case .limitSpend:
            self = .outOfAllowance
        case .requestInvalid:
            self = .emailInvalid
        case .authUnauthenticated, .authTokenExpired, .authTokenRevoked:
            self = .signedOut
        case .providerUnavailable, .providerTimeout, .providerRejected, .serverError,
             .serverUnavailable:
            self = .backendUnreachable
        case .entitlementRequired, .entitlementExpired, .requestTooLarge, .resourceNotFound,
             .idempotencyConflict, .versionUnsupported, .unknown:
            // None of these is reachable on the three unauthenticated auth routes, and a code this
            // build has never heard of is not something to guess at in front of a user.
            self = .unexpected
        }
    }
}

/// Every user-facing sentence the sign-in flow can show.
///
/// **Functional labels, not explanation** (founder, 2026-08-14, restated on this ticket): no
/// how-it-works sentences, no privacy explainer, no disclosure prose — that lives on the website.
/// Each line below says what happened and what the user can do next, and nothing else. In
/// particular none of them says "check your spam", which the ticket names as the non-design this
/// requirement exists to prevent.
public enum SignInCopy {
    public static func message(for failure: SignInFailure) -> String {
        switch failure {
        case .emailInvalid:
            return "That doesn't look like an email address."
        case .codeIncorrect:
            return "That code isn't right. Check it and try again."
        case .codeExpired:
            return "That code has expired. Send a new one."
        case .codeAlreadyUsed:
            return "That code has already been used. Send a new one."
        case .tooManyAttempts:
            return "Too many attempts. Try again in a few minutes."
        case .outOfAllowance:
            return "You've used up this period's allowance."
        case .offline:
            return "You're offline. Reconnect and try again."
        case .backendUnreachable:
            return "Sonny can't be reached right now. Try again in a moment."
        case .notConfigured:
            return "Sign-in isn't available in this build."
        case .signedOut:
            return "You're signed out. Sign in again."
        case .unexpected:
            return "Sonny couldn't finish signing you in. Try again."
        }
    }

    /// The fifth of the ticket's five cases, and the only one that is a state rather than a
    /// failure: no code arrived, so nothing failed and nothing will report anything. It is shown on
    /// the code step from the moment that step appears, beside the control that acts on it.
    public static let codeNotArriving = "No code yet? Send a new one, or use a different address."

    public static let emailFieldLabel = "Email"
    public static let emailFieldPrompt = "you@example.com"
    public static let codeFieldLabel = "Code"
    public static let codeFieldPrompt = "6-digit code"
    public static let sendCodeLabel = "Send code"
    public static let resendCodeLabel = "Send a new code"
    public static let verifyLabel = "Sign in"
    public static let useAnotherAddressLabel = "Use another address"
    public static let signOutLabel = "Sign out"
    public static let signInLabel = "Sign in"
    public static let codeSentConfirmation = "Code sent."

    /// Sign-out cleared this Mac but the server did not confirm the session ended.
    ///
    /// **The local clear happens either way, and this is what the user is told when it does.**
    /// Leaving a refresh token on disk so that a revoke can be retried later is the worse of the two
    /// failures: the credential stays where an attacker with the machine can reach it, in order to
    /// preserve a call that may never succeed.
    public static let signedOutLocallyOnly = "Signed out on this Mac. Sonny couldn't finish signing you out everywhere."
}
