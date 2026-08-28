import Foundation

/// A `code` from the backend's error envelope (`docs/sonny-backend-api-contract.md` §7).
///
/// **The client decides on `code`, never on status.** §9.3 states that as a rule and gives the
/// reason: several statuses carry more than one code with opposite semantics, and a client that
/// retried on status would retry `provider.rejected` — a 502 whose retry is guaranteed to fail
/// identically.
///
/// An unrecognised code is kept verbatim rather than collapsed into a catch-all, so a server that
/// starts sending something new is diagnosable from a log line instead of invisible. §8 makes new
/// codes an additive, non-breaking change, so this will happen.
public enum SonnyBackendErrorCode: Equatable, Hashable, Sendable {
    case authUnauthenticated
    case authTokenExpired
    case authTokenRevoked
    case authCodeInvalid
    case authCodeExpired
    case authCodeUsed
    case entitlementRequired
    case entitlementExpired
    case limitRate
    case limitSpend
    case requestInvalid
    case requestTooLarge
    case providerUnavailable
    case providerTimeout
    case providerRejected
    case serverError
    case serverUnavailable
    case resourceNotFound
    case idempotencyConflict
    case versionUnsupported
    case unknown(String)

    public init(wire: String) {
        switch wire {
        case "auth.unauthenticated": self = .authUnauthenticated
        case "auth.token_expired": self = .authTokenExpired
        case "auth.token_revoked": self = .authTokenRevoked
        case "auth.code_invalid": self = .authCodeInvalid
        case "auth.code_expired": self = .authCodeExpired
        case "auth.code_used": self = .authCodeUsed
        case "entitlement.required": self = .entitlementRequired
        case "entitlement.expired": self = .entitlementExpired
        case "limit.rate": self = .limitRate
        case "limit.spend": self = .limitSpend
        case "request.invalid": self = .requestInvalid
        case "request.too_large": self = .requestTooLarge
        case "provider.unavailable": self = .providerUnavailable
        case "provider.timeout": self = .providerTimeout
        case "provider.rejected": self = .providerRejected
        case "server.error": self = .serverError
        case "server.unavailable": self = .serverUnavailable
        case "resource.not_found": self = .resourceNotFound
        case "idempotency.conflict": self = .idempotencyConflict
        case "version.unsupported": self = .versionUnsupported
        default: self = .unknown(wire)
        }
    }

    public var wire: String {
        switch self {
        case .authUnauthenticated: return "auth.unauthenticated"
        case .authTokenExpired: return "auth.token_expired"
        case .authTokenRevoked: return "auth.token_revoked"
        case .authCodeInvalid: return "auth.code_invalid"
        case .authCodeExpired: return "auth.code_expired"
        case .authCodeUsed: return "auth.code_used"
        case .entitlementRequired: return "entitlement.required"
        case .entitlementExpired: return "entitlement.expired"
        case .limitRate: return "limit.rate"
        case .limitSpend: return "limit.spend"
        case .requestInvalid: return "request.invalid"
        case .requestTooLarge: return "request.too_large"
        case .providerUnavailable: return "provider.unavailable"
        case .providerTimeout: return "provider.timeout"
        case .providerRejected: return "provider.rejected"
        case .serverError: return "server.error"
        case .serverUnavailable: return "server.unavailable"
        case .resourceNotFound: return "resource.not_found"
        case .idempotencyConflict: return "idempotency.conflict"
        case .versionUnsupported: return "version.unsupported"
        case .unknown(let raw): return raw
        }
    }

    /// How many times an operation may be sent **in total** when this is what came back.
    ///
    /// Per-code rather than one global ceiling, because §7.2 does not ask for one ceiling: it says
    /// `limit.rate` and `provider.timeout` are retried *once* while `provider.unavailable`,
    /// `server.error` and `server.unavailable` are "retried with backoff, then given up on". The
    /// difference is not cosmetic on a rate limit — the extra attempt spends the user's own budget
    /// against a wall that has already answered.
    public var maximumAttempts: Int {
        switch self {
        case .limitRate, .providerTimeout, .idempotencyConflict:
            return 2
        case .providerUnavailable, .serverError, .serverUnavailable:
            return 3
        default:
            return 1
        }
    }

    /// Whether a retry of the same operation could succeed, per §9.3's two lists.
    ///
    /// **An unrecognised code is not retryable.** Retrying a failure whose meaning this build does
    /// not know burns a round trip in the best case, and in the worst repeats a side effect the
    /// server described in words this client cannot read.
    ///
    /// **`idempotency.conflict` is the one code whose two sub-cases share it**, so it is the one
    /// place the envelope's own `retryable` flag decides: §9.2 makes a key seen while its original
    /// request is still in flight retryable with a `Retry-After`, while the same key with a
    /// different body is a client bug that a retry cannot fix. Nothing else consults that flag —
    /// a server bug flipping it on `provider.rejected` must not turn into a retry loop here.
    ///
    /// **This member and `maximumAttempts` have to agree**, and their agreement is the invariant
    /// `SignInCopyTests.aCodesAttemptCeilingAgreesWithWhetherItMayBeRetriedAtAll` holds: a code that
    /// may not be retried gets exactly one attempt, one that may gets more than one. Without that,
    /// a code could read as retryable while its ceiling silently refused to retry it — which is the
    /// state this branch's own M10 mutant created, and which nothing noticed, because retryability
    /// was only ever observed through an attempt count that masked it (PR #133, F8: this comment was
    /// merged into `maximumAttempts`' and left the member the mutant was about undocumented).
    public func isRetryable(envelopeSaysRetryable: Bool) -> Bool {
        switch self {
        case .limitRate, .providerUnavailable, .providerTimeout, .serverError, .serverUnavailable:
            return true
        case .idempotencyConflict:
            return envelopeSaysRetryable
        case .authUnauthenticated, .authTokenExpired, .authTokenRevoked, .authCodeInvalid,
             .authCodeExpired, .authCodeUsed, .entitlementRequired, .entitlementExpired,
             .limitSpend, .requestInvalid, .requestTooLarge, .providerRejected, .resourceNotFound,
             .versionUnsupported, .unknown:
            return false
        }
    }
}

/// One failure the backend described in its own envelope (§7.1).
///
/// `message` is carried for logs and the support lookup and is **never displayed**: §7.1 makes that
/// a rule, because a sentence authored on the server and rendered in the app is a hole through
/// Sonny's standing "the product does not explain itself" rule, editable by whoever edits the
/// server with no review by anyone who knows it. `SignInCopy` maps `code` to client-owned words.
public struct SonnyBackendAPIError: Error, Equatable, Sendable {
    public let code: SonnyBackendErrorCode
    public let statusCode: Int
    public let message: String
    public let requestID: String?
    public let retryAfter: TimeInterval?
    public let envelopeSaysRetryable: Bool

    public init(
        code: SonnyBackendErrorCode,
        statusCode: Int,
        message: String,
        requestID: String?,
        retryAfter: TimeInterval?,
        envelopeSaysRetryable: Bool
    ) {
        self.code = code
        self.statusCode = statusCode
        self.message = message
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.envelopeSaysRetryable = envelopeSaysRetryable
    }

    public var isRetryable: Bool {
        code.isRetryable(envelopeSaysRetryable: envelopeSaysRetryable)
    }
}

/// Everything the shared backend client can fail with, as one typed value.
///
/// **`offline` and `timedOut` are deliberately separate, and so is `unreachable`.** §7.2's case 7
/// is the only entry with no HTTP status, and the contract says why the distinction is load
/// bearing: "the first means everything local still works, the second means Sonny is up but this
/// particular thing failed, and telling a user the wrong one of those is a real failure of the
/// error-handling-is-UX rule."
public enum SonnyBackendError: Error, Equatable, Sendable {
    /// No network on this Mac — §7.2 case 7, and the only one of these that means every local
    /// capability still works.
    case offline
    /// The request left and nothing usable came back: DNS, TLS, connection refused, a host that is
    /// not there. Distinct from `offline` because the two need different words — "you are offline"
    /// is wrong and unhelpful when the network is fine and the backend is not.
    case unreachable(String)
    /// No session is held on this Mac, so a request needing one was never sent. §7.2 case 1.
    case notSignedIn
    /// This client's own timeout elapsed. Distinct from `provider.timeout`, which the server names.
    case timedOut(after: TimeInterval)
    /// The user or an emergency stop cut the request. Never retried, never surfaced as a failure.
    case cancelled
    /// The backend answered and named the failure.
    case api(SonnyBackendAPIError)
    /// The backend answered with something this client could not read as the contract's shapes.
    case undecodableResponse(String)
    /// No base URL is configured for this build. `SonnyBackendHost.productionBaseURL` is still nil.
    case backendNotConfigured
}

/// An error that is really a backend failure wearing a caller's own type.
///
/// **One question needs answering through these wrappers and only one: is this a cancellation?**
/// Every client that talks to `SonnyBackendClient` catches `SonnyBackendError` and rethrows it inside
/// a case of its own — `VisionModelClientError.backend`, `PlannerError.backend` — because the caller
/// above it wants one error type. That is right, and it hides `SonnyBackendError.cancelled`, which is
/// the one case that must never be reported as a failure: it means the user pressed stop.
///
/// Conforming is one line and it is what `SonnyBackendError.isCancellation` reads.
public protocol CarriesBackendError {
    var backendError: SonnyBackendError? { get }
}

public extension SonnyBackendError {
    /// Is this error the user stopping something, rather than something failing?
    ///
    /// **Three shapes, and they arrive from three different layers** (SONNY-131). `CancellationError`
    /// is what `Task.cancel()` produces; `URLError(.cancelled)` is what `URLSession` raises when its
    /// task is cancelled underneath, which is the emergency stop reaching a request already in
    /// flight; and ``SonnyBackendError/cancelled`` is the shared client's own typed name for the same
    /// event, raised so a Foundation error never escapes it. The fourth is the third wearing a
    /// caller's type, which is what ``CarriesBackendError`` is for.
    ///
    /// **This exists as one function because it was two, and the second one was incomplete.**
    /// `AgentViewModel.isCancellationError` knew the first two shapes, which was the whole population
    /// while every client held its own provider key; the moment the vision route moved behind the
    /// gateway, a stop mid-send arrived as the third and was recorded in the session journal as
    /// `failed` and shown to the user as "Sonny couldn't finish this one. Try again." — the exact
    /// wrong sentence for someone who had just pressed stop. `aCancellationDuringASendIsNotReported
    /// AsASendFailure` is the test that found it.
    ///
    /// **What it does not yet reach**, stated rather than left to be discovered: the text clients'
    /// own wrappers do not conform to ``CarriesBackendError``, so a cancellation on those routes
    /// still reads as a failure. Those files are SONNY-130's and are outside this ticket's region;
    /// **SONNY-320** carries them.
    ///
    /// **Three conformances, not four, and the population is the error type rather than the route**
    /// (PR #144, F6). The population is four declarations —
    /// `git grep -nE '^ *case backend\(SonnyBackendError\)' -- Sources` → 4, anchored to the start
    /// of a line so this sentence does not count itself, which the unanchored form does — and one of
    /// them is ``VisionModelClientError``'s, which already conforms. The other three are
    /// `PlannerError`, `TranscriptionError` and `TavilySearchError`. **`WebResearchSynthesizer.swift`
    /// needs no edit**: it declares `WebResearchNoteDecodingError`, whose three cases are
    /// `invalidJSON`, `unexpectedTopLevelKey` and `malformedNote` — no `.backend` at all — and it
    /// throws `PlannerError.backend` (`:407`), so conforming `PlannerError` once covers both
    /// `/v1/plan` and `/v1/research/synthesize`. This said "the four" and SONNY-320's description
    /// named that file, which would have sent its session looking for a fourth error type and
    /// finding an unrelated decoding enum.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if let backend = error as? SonnyBackendError { return backend == .cancelled }
        if let wrapped = (error as? any CarriesBackendError)?.backendError { return wrapped == .cancelled }
        return false
    }
}

extension SonnyBackendError: LocalizedError {
    /// **For logs and tests, never for the user.** Every user-facing sentence in the sign-in flow
    /// comes from `SignInCopy`, which maps a `code` to client-owned words.
    public var errorDescription: String? {
        switch self {
        case .offline:
            return "No network connection was available."
        case .unreachable(let detail):
            return "The backend could not be reached: \(detail)"
        case .notSignedIn:
            return "No sign-in is stored on this Mac."
        case .timedOut(let seconds):
            return "The request did not complete within \(Int(seconds)) seconds."
        case .cancelled:
            return "The request was cancelled."
        case .api(let error):
            return "Backend returned \(error.statusCode) \(error.code.wire): \(error.message)"
        case .undecodableResponse(let detail):
            return "Backend response could not be decoded: \(detail)"
        case .backendNotConfigured:
            return "No backend base URL is configured for this build."
        }
    }
}
