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
    /// The account holds no subscription to manage. §7.2's `entitlement.no_subscription`, on
    /// `POST /v1/billing/portal` alone (SONNY-216).
    ///
    /// **Named here because an unnamed code is not merely unhandled, it is mis-worded** (PR #183,
    /// F4). Without this case it decoded to `.unknown(…)`, which `SignInFailure` maps to
    /// `.unexpected`, whose sentence is "Sonny couldn't finish signing you in." — shown to a user
    /// who is signed in and pressed Manage subscription.
    case entitlementNoSubscription
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
        case "entitlement.no_subscription": self = .entitlementNoSubscription
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
        case .entitlementNoSubscription: return "entitlement.no_subscription"
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
             .entitlementNoSubscription, .limitSpend, .requestInvalid, .requestTooLarge,
             .providerRejected, .resourceNotFound, .versionUnsupported, .unknown:
            // `entitlementNoSubscription` joins the not-retryable side: an account with no
            // subscription still has none a moment later, and the route sets `retryable: false`.
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
    /// §7.1's `upgrade_url`, present on `version.unsupported` and absent everywhere else.
    ///
    /// **The one field of the envelope that is displayed — as a destination, never as words**
    /// (SONNY-204 added it to the contract for exactly this, SONNY-402 is what reads it). §8.3 puts
    /// it in the *error* body rather than leaving it to `GET /v1/meta` because a client this old may
    /// not be able to parse that document at all, so the refusal has to carry everything the app
    /// needs to act.
    ///
    /// **Kept as the wire string rather than a `URL`**, so this type stays a faithful reading of the
    /// envelope. ``ClientUpgradeLink/openable(_:)`` is the one place it becomes something the app
    /// will open, and `ClientVersionState` is where the result is carried.
    ///
    /// **Defaulted to `nil`, which is the one default in this file and is argued rather than
    /// assumed.** SONNY-240's rule against defaults is about a value that reaches the founder's real
    /// data by silence; this is a wire field that is genuinely absent on twenty of the twenty-one
    /// codes, and the production construction site — `SonnyBackendClient.errorEnvelope` — passes it
    /// explicitly. Requiring it would edit a dozen fixtures to write `nil`.
    public let upgradeURL: String?

    public init(
        code: SonnyBackendErrorCode,
        statusCode: Int,
        message: String,
        requestID: String?,
        retryAfter: TimeInterval?,
        envelopeSaysRetryable: Bool,
        upgradeURL: String? = nil
    ) {
        self.code = code
        self.statusCode = statusCode
        self.message = message
        self.requestID = requestID
        self.retryAfter = retryAfter
        self.envelopeSaysRetryable = envelopeSaysRetryable
        self.upgradeURL = upgradeURL
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
    /// **Every wrapper in the tree conforms now** (SONNY-320). Until then only the vision route's
    /// did, so the fourth shape above was recognised on one route and hidden on the other four; a
    /// stop on any of them read as a failure. The population is
    /// the error *type* rather than the route — four declarations,
    /// `git grep -cE '^ *case backend\(SonnyBackendError\)' -- Sources` → 4 files at `563c38f`
    /// — and they answer for five routes, because **`WebResearchSynthesizer.swift`
    /// declares no error of its own**: `WebResearchNoteDecodingError` there has three cases,
    /// `invalidJSON`, `unexpectedTopLevelKey` and `malformedNote`, and no `.backend` at all, so
    /// `/v1/research/synthesize` throws `PlannerError.backend` and one conformance covers it and
    /// `/v1/plan` both. That is PR #144's F6: SONNY-320's description said "four files" and named
    /// that one, which would have sent its session looking for a fifth error type and finding an
    /// unrelated decoding enum. The conforming four are ``VisionModelClientError`` (SONNY-131),
    /// `PlannerError`, `TranscriptionError` and `TavilySearchError`
    /// (`git grep -cE '^public enum .*, CarriesBackendError \{' -- Sources` → 4 files at
    /// `4b5870a`.)
    ///
    /// **Neither of those two anchors does anything, and this paragraph said the opposite twice
    /// before a reviewer measured it** (SONNY-320, PR #146's F1). **Six readings**, at
    /// `4b5870a` — and the numeral is six rather than the four the review measured because the
    /// case-declaration grep is swept here as well: it answers **4** with `^ *` and **4** without
    /// it, and the conformance grep answers **4** as written, **4** with the `^` dropped and **4**
    /// with `public enum` dropped for `^.*,`. Only a genuinely looser pattern moves the number —
    /// `git grep -cE 'CarriesBackendError \{' -- Sources` → **5** — and the fifth line it admits is
    /// `public protocol CarriesBackendError {`, which every one of the other forms excludes because
    /// it contains neither `enum` nor the comma they require. The anchors are decorative here.
    ///
    /// **The way that error arrived is worth more than the correction.** PR #144's F6 claimed the
    /// unanchored case-declaration form "matches its own citation in `SonnyBackendError.swift` and
    /// answers five"; it answers 4, because a citation escapes its parentheses and an escaped `\(`
    /// is not the literal `(` a pattern looks for, so the line cannot match itself. That was the
    /// **fourth** defect this repository has recorded from the write-the-command-beside-the-number
    /// rule. Correcting it, this comment then asserted that its *other* anchor was load-bearing —
    /// on the strength of the brace form's 5, a looser pattern, which is precisely the mistake it
    /// had just diagnosed. That is the **fifth**, and it arrived inside the correction of the
    /// fourth. The rule makes a figure checkable; it does not check it, and a parenthesis written
    /// while correcting someone else's parenthesis gets no less attention than the number beside
    /// it. The changelog's SONNY-131 entry repeats F6's five and stays as it is — it is a dated
    /// record of what that review found — and SONNY-320's entry carries both corrections.
    ///
    /// **What it still does not reach is a caller that never asks it, not a shape it cannot see**,
    /// and the two known ones were filed rather than left here. The voice route's `catch` called
    /// `setError(error.localizedDescription)` without consulting this at all; its non-success exit
    /// is now the one seam `AgentViewModel.deliverTranscriptionError(_:)`, which does
    /// (**SONNY-327**, and `TranscriptionError.backendError` says the same at its own declaration —
    /// what remains open there is whether anything can *press* stop during a transcription,
    /// **SONNY-332**). The web-research source-fetch loop matched `CancellationError` alone while
    /// the `URLSession` beneath it raises `URLError(.cancelled)`, so a stop there was swallowed as a
    /// skipped source before any predicate was consulted; that arm asks this now (**SONNY-328**).
    /// Both were call-site defects: no conformance can fix a question nobody asks, and the shape
    /// recurs because a call site that never asks is invisible to every test of this function.
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
