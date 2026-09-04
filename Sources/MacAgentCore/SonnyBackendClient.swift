import Foundation

/// The client timeouts of `docs/sonny-backend-api-contract.md` §12.
///
/// The governing rule there is one line — "the client's timeout is always longer than the server's
/// total deadline" — so that a slow route surfaces as the server's own typed `504 provider.timeout`,
/// which the app can explain, rather than as this client's opaque transport timeout, which it
/// cannot tell apart from a dead network. The table:
///
/// | Route | Server total deadline | Client timeout |
/// |---|---|---|
/// | screen/analyze, research/synthesize | 105 s | 120 s |
/// | plan, transcriptions | 75 s | 90 s |
/// | search | 25 s | 30 s |
/// | auth, account, meta, health, delete | 15 s | 20 s |
///
/// SONNY-128 declared only the last row, because a constant for a route nobody sends is a number
/// that goes stale before anything reads it. SONNY-130 added the four it built beside it, and
/// SONNY-131 the vision row — so the table is complete and every row is a route something sends.
///
/// Each of these sits above the server's own total deadline for the same route
/// (`server/src/model/limits.ts`), which is the whole of §12's governing rule. **The margin is not
/// a constant, and this comment said it was fifteen seconds until PR #139's F2** — it is fifteen on
/// the four long routes and **five** on `search` and on the auth row, straight from §12's table.
/// `ModelRouteNumbersTests` holds both halves of that table as literals, so neither side can move
/// without the other failing.
public enum SonnyBackendTimeouts {
    public static let auth: TimeInterval = 20
    public static let plan: TimeInterval = 90
    public static let researchSynthesis: TimeInterval = 120
    public static let transcription: TimeInterval = 90
    public static let search: TimeInterval = 30
    /// §12's longest client budget, shared with `researchSynthesis` (SONNY-131).
    ///
    /// **What the margin buys is a retry, and nothing else the user can see** — which is worth
    /// stating exactly, because the sentence that stood here claimed more and had it backwards
    /// (PR #144, F7). A slow iteration that ends as the server's typed `504 provider.timeout` is
    /// retried once by `SonnyBackendClient` (`SonnyBackendErrorCode.providerTimeout.maximumAttempts`
    /// is 2); one that ends as this client's own transport timeout is not retried at all
    /// (`attemptCeiling` returns `nil` for `.timedOut`). 120 s against the server's 105 s total is
    /// the fifteen seconds §12 gives the long routes, and that fifteen seconds is what makes the
    /// first outcome reachable instead of the second.
    ///
    /// **The user sees the same sentence either way, and that is a real gap rather than a nuance.**
    /// Traced end to end at this head: server upstream (90 s) and server total (105 s) both arrive as
    /// `504 provider.timeout` → `SignInFailure.backendUnreachable`; the client's own 120 s arrives as
    /// `SonnyBackendError.timedOut` → the same case; and `SonnyBackendCopy.sentence` answers all
    /// three with **"Sonny couldn't finish this one. Try again."**, which
    /// `VisionSessionInterrupted` then suffixes with the step count. So the old claim — that the
    /// client "cannot tell apart" a transport timeout from a dead network — is inverted twice over:
    /// a dead network is `SonnyBackendError.offline`, which is the one case that *does* get its own
    /// sentence ("You're offline. Everything Sonny does on this Mac still works."), and the two that
    /// share one are the two the comment said were distinguishable.
    ///
    /// **One sentence for three deadline outcomes is defensible here and is not this file's to
    /// change.** All three mean the same thing to a person — Sonny waited and gave up — and none
    /// suggests a different action, so three sentences would be three ways to say "try again" and
    /// would breach the standing rule that the product does not explain itself. What is *not*
    /// defensible is a comment implying the app already distinguishes them. Making the unreachable
    /// states distinguishable where it genuinely matters is SONNY-136's, and a dated comment on that
    /// ticket says this route currently collapses three into one.
    public static let screenAnalyze: TimeInterval = 120
    /// The budget for buying more screen-control runs — **forty seconds** (SONNY-215).
    ///
    /// **Longer than `auth` because the gateway makes two sequential provider calls behind it**, not
    /// because a database read got slower. An off-session charge is a draft order and then a
    /// finalize, each with a twelve-second budget of the gateway's own
    /// (`server/src/billing/polar.ts`'s `TOPUP_CHARGE_TIMEOUT_MS`), so twenty-four seconds of
    /// provider time can elapse inside one request that `auth`'s twenty would cut off first — and
    /// cutting it off first is the failure that matters: the Mac would report a generic unreachable
    /// backend about a gateway that was in the middle of charging the user's card.
    ///
    /// **The relation is pinned by a test on each side** rather than by this comment, following
    /// `PORTAL_SESSION_TIMEOUT_MS`'s precedent: a cross-half number living in prose on one side is a
    /// number the next session moves without noticing the other.
    ///
    /// **What the margin does not buy is a retry**, and this is the one route where that is a
    /// property rather than an oversight: `purchaseTopUp` passes `isRetrySafe: false`, so a slow
    /// charge is never sent twice by this client. A retry here is a second pack.
    public static let topUp: TimeInterval = 40
}

/// One request, described in the terms the contract's rules are written in.
///
/// **`isRetrySafe` is the request's own property and not a consequence of its verb.** §9.3 makes
/// `POST /v1/auth/email/verify` unsafe to retry — a code is single-use, so a second attempt spends
/// something the user cannot get back — while `POST /v1/auth/email/start`, `/v1/auth/refresh` and
/// `/v1/auth/signout` beside it are all safe. Nothing about "POST" says which, so the caller says.
public struct SonnyBackendRequest: Sendable, Equatable {
    public enum Authentication: Sendable, Equatable {
        case none
        case bearer
    }

    public let method: String
    public let path: String
    public let body: Data?
    /// The body's media type, or `nil` for §2.1's default of `application/json`.
    ///
    /// Defaulted rather than required because the contract itself is: "UTF-8 JSON,
    /// `Content-Type: application/json`, except `POST /v1/transcriptions`". One route names its
    /// own, every other route says nothing, and this mirrors that exactly (SONNY-130).
    public let contentType: String?
    public let authentication: Authentication
    /// §9.1: one key per logical operation, not one per attempt. A retry reuses the operation's
    /// key — that is the entire mechanism — so it is minted where the operation begins.
    public let idempotencyKey: UUID?
    public let timeout: TimeInterval
    public let isRetrySafe: Bool

    public init(
        method: String,
        path: String,
        body: Data?,
        contentType: String? = nil,
        authentication: Authentication,
        idempotencyKey: UUID?,
        timeout: TimeInterval,
        isRetrySafe: Bool
    ) {
        self.method = method
        self.path = path
        self.body = body
        self.contentType = contentType
        self.authentication = authentication
        self.idempotencyKey = idempotencyKey
        self.timeout = timeout
        self.isRetrySafe = isRetrySafe
    }
}

public struct SonnyBackendResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data
    public let requestID: String?
}

/// How long to wait between attempts. Delays only — how *many* attempts an operation gets comes
/// from what failed (`SonnyBackendErrorCode.maximumAttempts`), and a `Retry-After` the server sent
/// replaces the computed delay outright, because a server that named a number knows something this
/// client does not.
public struct SonnyBackendRetryDelays: Sendable, Equatable {
    public let initial: TimeInterval
    public let multiplier: Double
    public let maximum: TimeInterval

    public static let contractDefault = SonnyBackendRetryDelays(initial: 0.5, multiplier: 2, maximum: 8)

    public init(initial: TimeInterval, multiplier: Double, maximum: TimeInterval) {
        self.initial = initial
        self.multiplier = multiplier
        self.maximum = maximum
    }

    /// `attempt` is 1-based and names the attempt that just failed.
    public func delay(afterAttempt attempt: Int, jitterFraction: Double) -> TimeInterval {
        let exponent = max(attempt - 1, 0)
        let base = min(initial * pow(multiplier, Double(exponent)), maximum)
        return base * (1 + max(jitterFraction, 0))
    }
}

/// The one HTTP client the Mac app talks to its own backend through.
///
/// **An actor, because the single-flight refresh guard is shared mutable state and nothing else in
/// this codebase owns it.** Ten requests can be in flight from as many tasks; §3.3 requires that
/// ten concurrent `401 auth.token_expired`s cause one refresh and not ten, and the server's
/// rotation rule only works if the client honours it — a second refresh presenting a token the
/// first already rotated away, past the platform's ten-second overlap, is read as theft and revokes
/// the whole family.
///
/// **The guard is a generation counter, not just "is a refresh running".** A flag alone loses the
/// straggler: request A refreshes, the flag clears, request B's 401 — raised against the *old*
/// token before A finished — then starts a second refresh. So every caller records the generation
/// of the token it used, and asks for "a token newer than this one". If the cache has already moved
/// past it, the caller retries with what is there and no request is made at all.
///
/// **Every token write reaches the Keychain before it reaches this actor's cache.** That ordering is
/// the whole of this ticket's headline requirement: macOS forces an app relaunch after a Screen
/// Recording grant (`ScreenAccessOnboardingModel.relaunchNow()`), so a session that exists only in
/// memory is lost at exactly the moment a first-run user meets it. Writing the Keychain first also
/// means a failed write cannot leave the process believing it is signed in with something no disk
/// holds — the failure surfaces to whoever asked, and the user is not told they are signed in.
public actor SonnyBackendClient {
    private let environment: SonnyBackendEnvironment?
    private let tokenStore: any SonnyAccountTokenStoring
    private let session: URLSession
    private let clientVersion: String
    private let platform: String
    private let retryDelays: SonnyBackendRetryDelays
    private let now: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant
    private let jitterFraction: @Sendable () -> Double
    private let sleepForRetry: @Sendable (TimeInterval) async throws -> Void

    /// Refresh this far ahead of expiry rather than waiting for a 401 (§3.3, "the client refreshes
    /// when `expires_in` is most of the way spent").
    ///
    /// **180 seconds, derived rather than picked**: it exceeds the longest client timeout in §12's
    /// table (120 s, the vision and synthesis routes), so a request that is allowed to start can
    /// never be holding a token that expires while it is still in flight. A margin shorter than the
    /// longest request is a margin that lets exactly that happen.
    static let proactiveRefreshMargin: TimeInterval = 180

    /// How far ahead of what real time can account for one `Date` header may move this client's
    /// recorded server observation: **300 seconds** (SONNY-344).
    ///
    /// **Derived, and it has to clear two separate things.** The first is how stale the *previous*
    /// observation can be: a `Date` is stamped before the response is transmitted, so an observation
    /// carried forward under-reads by whatever that response's latency was, and §12's longest client
    /// budget — `SonnyBackendTimeouts.researchSynthesis`, 120 s — is the ceiling on that, because a
    /// slower response is cancelled and never observed at all. The second is the gateway's own
    /// legitimate clock correction, which is not bounded by anything this side can name. 300 s clears
    /// the first with headroom for the second, and it is the number the gateway already carries for
    /// the same purpose in the other direction: `ENTITLEMENT_SKEW_TOLERANCE_SECONDS` is 300
    /// (`grep -n 'ENTITLEMENT_SKEW_TOLERANCE_SECONDS = ' server/src/entitlement/claim.ts` → `107:`
    /// at `65a7fc9`), which is what arrives in every claim as `skew_tolerance_seconds`. Both sides
    /// absorbing the same disagreement is the property worth having; a tighter number here would make
    /// this client refuse a skew its own claims are built to tolerate.
    static let maximumUncorroboratedForwardJump: TimeInterval = 300

    private var cachedTokens: SonnyAccountTokens?
    private var tokenGeneration: UInt64 = 0
    private var hasReadStore = false
    private var refreshTask: Task<Void, Error>?
    /// Server time minus this Mac's time, from the `Date` header every response carries (§3.5).
    /// All expiry arithmetic runs in server time, because the user can change their own clock.
    ///
    /// **This offset alone is not a defence against a clock the user changes, and the distinction
    /// cost a real hole** (SONNY-135, PR #152's review, F1). It is a *correction*, applied to the
    /// local clock — so `serverNow()` moves with the local clock, exactly, and a user who sets their
    /// Mac back a week gets a `serverNow()` a week earlier. What cannot be moved that way is
    /// `lastServerObservation` below, which pairs an instant a server actually reported with a
    /// **monotonic** reading, so the pair can be advanced by elapsed time rather than by a
    /// settable clock.
    private var serverClockOffset: TimeInterval = 0

    /// What this deployment has said about this build's version, and the `/v1/meta` document behind
    /// it (contract §8, SONNY-402).
    ///
    /// **Held on the client because the client is the only thing every request passes through.**
    /// §8.4's two headers arrive on *every* response — a plan, a transcription, a `401` from the auth
    /// gate — and §8.3's `410` can arrive on any route as well, so a surface that wanted to learn
    /// this would otherwise have to ask after each of five routes' calls, which is a call site per
    /// route and one more for every route added later. `clientVersionUpdates()` is how it leaves.
    private var versionState: ClientVersionState = .current
    private var meta: SonnyMetaDocument?
    /// One `/v1/meta` fetch across every concurrent caller, the same single-flight shape
    /// `refreshTask` above uses and for the same reason: a walled-off client's requests all fail with
    /// `410` at once, and one refresh per failure would be a burst of meta calls answering one
    /// question.
    private var metaFetch: Task<Void, Never>?
    private var versionObservers: [UUID: AsyncStream<ClientVersionState>.Continuation] = [:]

    /// The most recent instant a server reported, and the monotonic reading it arrived at.
    ///
    /// Written only from a `Date` header this client actually received, so it is the one time source
    /// here that a user cannot author. `nil` until a response has been seen at all — a first launch,
    /// or a relaunch with no network — which is why `EntitlementService` persists what it derives
    /// from this rather than relying on it surviving a process.
    private var lastServerObservation: ObservedServerTime?

    /// `tokenStore` has no default, deliberately.
    ///
    /// SONNY-240 removed every defaulted local store from `AgentViewModel.init` because a default
    /// nobody writes is a default nobody can see, and a fixture that inherited one wrote to the
    /// developer's own `~/Library`. The Keychain is the same hazard one step worse: every packaged
    /// build on a Mac shares one Keychain, so a test or a fixture that let this default would read
    /// and *delete* the founder's real session. `session` keeps the `= .shared` default the six
    /// provider clients already use, because a URLSession touches nothing shared on disk.
    public init(
        environment: SonnyBackendEnvironment?,
        tokenStore: any SonnyAccountTokenStoring,
        session: URLSession = .shared,
        clientVersion: String = SonnyClientIdentity.version,
        platform: String = SonnyClientIdentity.platform,
        retryDelays: SonnyBackendRetryDelays = .contractDefault,
        now: @escaping @Sendable () -> Date = Date.init,
        /// A clock a wall-clock change cannot move, for the one thing that must not be movable:
        /// how much real time has passed since a server last told this client what time it was.
        /// `ContinuousClock` keeps counting across sleep, which `ProcessInfo.systemUptime` does not.
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        jitterFraction: @escaping @Sendable () -> Double = { Double.random(in: 0...0.25) },
        sleepForRetry: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
        }
    ) {
        self.environment = environment
        self.tokenStore = tokenStore
        self.session = session
        self.clientVersion = clientVersion
        self.platform = platform
        self.retryDelays = retryDelays
        self.now = now
        self.monotonicNow = monotonicNow
        self.jitterFraction = jitterFraction
        self.sleepForRetry = sleepForRetry
    }

    public var isConfigured: Bool { environment != nil }

    public var backendEnvironment: SonnyBackendEnvironment? { environment }

    // MARK: - Session

    /// Who is signed in on this Mac, reading the Keychain the first time it is asked.
    ///
    /// This is the whole of "the app comes back signed in": it needs no network, so a relaunch — or
    /// a launch with no connection — restores the session from the one place it was written.
    public func restoredIdentity() throws -> SonnyAccountIdentity? {
        try loadedSnapshot()?.tokens.identity
    }

    /// Take a freshly issued session: **Keychain first, cache second**.
    ///
    /// Unconditional, because a sign-in is the user asking for exactly this and must always win.
    /// The refresh path uses `adopt(_:onlyIfGenerationIsStill:)` below instead.
    public func adopt(_ tokens: SonnyAccountTokens) throws {
        try adopt(tokens, onlyIfGenerationIsStill: tokenGeneration)
    }

    /// Take a session **only if nothing has replaced or discarded the one it was issued against.**
    ///
    /// This is the guard for PR #133's F1, and the defect it closes was reproduced rather than
    /// argued: a refresh already in flight when the user pressed Sign out reached `adopt` *after*
    /// `discardSessionLocally` had cleared the Keychain, wrote the rotated session back, and
    /// `restore()` signed the user in again at the next launch — `keychain_holds_session_after_
    /// signout=true`. The UI said signed out and a live credential sat on disk.
    ///
    /// **Why a generation rather than a flag, and why the check cannot race.** `performRefresh`
    /// reads the generation before its network call and hands it back here; sign-out and every
    /// adoption bump it. The comparison and the write both happen in this method with no `await`
    /// between them, so on this actor they are one indivisible step — there is no window for a
    /// sign-out to land between "still current" and "saved".
    ///
    /// **That holds because `SonnyAccountTokenStoring` is synchronous**, and it is worth saying out
    /// loud rather than leaving as a property of today's code. An actor's step is indivisible only
    /// up to its next suspension point, so the guarantee above is not a fact about the guard — it is
    /// a fact about `saveTokens` being a `throws` call rather than an `async throws` one. Make that
    /// protocol asynchronous and this method acquires a suspension point between the check and the
    /// write, and the window this exists to close is open again. Written down so that change is
    /// *seen* to reopen it: whoever makes `saveTokens` async has to come back here, rather than
    /// finding a comment that still reads true and a guard that quietly is not.
    ///
    /// Refusing throws `notSignedIn` rather than returning quietly, so the caller learns that the
    /// session it was refreshing no longer exists instead of reading an empty cache as a bug. The
    /// rotated token the server issued is discarded on purpose: the user signed out, and the whole
    /// family is revoked or about to be.
    func adopt(_ tokens: SonnyAccountTokens, onlyIfGenerationIsStill expected: UInt64) throws {
        guard tokenGeneration == expected else { throw SonnyBackendError.notSignedIn }
        try tokenStore.saveTokens(tokens)
        cachedTokens = tokens
        hasReadStore = true
        tokenGeneration &+= 1
    }

    /// Forget the session on this Mac. Deletes exactly this Keychain account and nothing else —
    /// `LocalStorageEncryptionKeyManager`'s key lives under a different service and is untouched,
    /// which is the difference between signing out and resetting the encryption identity.
    /// **The in-flight refresh is dropped as well, and it is dropped rather than cancelled.**
    /// Clearing the handle is what stops a *later* caller awaiting a refresh that belongs to a
    /// session nobody holds any more; the bumped generation is what stops that refresh writing its
    /// result (`adopt(_:onlyIfGenerationIsStill:)`). Cancelling it would add nothing the guard does
    /// not already do — a cancel cannot reach a task already past its network call — and it would
    /// hand the requests riding on that refresh `cancelled`, which the copy layer renders as an
    /// unexplained failure. Letting it run to its own refusal gives them `notSignedIn`, which is
    /// both true and the sentence the user needs.
    public func discardSessionLocally() throws {
        try tokenStore.clearTokens()
        cachedTokens = nil
        hasReadStore = true
        tokenGeneration &+= 1
        refreshTask = nil
    }

    // MARK: - Sending

    public func send(_ request: SonnyBackendRequest) async throws -> SonnyBackendResponse {
        try await send(request, allowingRefresh: true)
    }

    /// `allowingMetaRefresh` is what stops §8.3's "on any `410`" from recursing.
    ///
    /// **A `410` on the meta request itself is the reachable case, not a theoretical one** — §8.3
    /// requires the gate to refuse `/v1/meta` too, "including `/v1/meta` itself answering honestly",
    /// so a build below the minimum gets one there every single time. Without this flag the first
    /// `410` anywhere would start a meta fetch whose own `410` would start another, for as long as
    /// the process lived.
    private func send(
        _ request: SonnyBackendRequest,
        allowingRefresh: Bool,
        allowingMetaRefresh: Bool = true
    ) async throws -> SonnyBackendResponse {
        guard let environment else { throw SonnyBackendError.backendNotConfigured }
        var attempt = 1
        var hasRefreshed = false

        while true {
            var snapshot: TokenSnapshot?
            if request.authentication == .bearer {
                snapshot = allowingRefresh
                    ? try await authorizedSnapshot()
                    : try requireSnapshot()
            }

            do {
                return try await perform(
                    request,
                    accessToken: snapshot?.tokens.accessToken,
                    baseURL: environment.baseURL
                )
            } catch let error as SonnyBackendError {
                // §3.3: refresh once, retry the original request exactly once. This retry is not an
                // attempt against the failure's own budget — nothing failed that a wait would fix.
                if allowingRefresh,
                   request.authentication == .bearer,
                   !hasRefreshed,
                   case .api(let api) = error,
                   api.code == .authTokenExpired {
                    hasRefreshed = true
                    _ = try await refreshedSnapshot(newerThan: snapshot?.generation ?? 0)
                    continue
                }

                // §8.3: "The client calls `GET /v1/meta` on launch and on any `410`." Here rather
                // than at the five call sites above this client, because this is the one place every
                // route's `410` passes through. Awaited rather than detached: the refusal is not
                // retryable, so nothing is waiting on this request any more, and the meta call is the
                // cheapest request the gateway serves a walled-off client — it is refused at the
                // version gate, before authentication and before any provider. Awaiting also makes
                // the sequence observable, which a detached task would not be.
                if allowingMetaRefresh,
                   case .api(let api) = error,
                   api.code == .versionUnsupported {
                    await refreshMetaDocument()
                    throw error
                }

                // §7.2 case 1b: a revoked or reused token means the family is gone. The client's
                // stated response is to clear the Keychain entry and send the user to sign-in, so
                // the dead session does not sit on disk pretending to be one.
                if case .api(let api) = error,
                   api.code == .authTokenRevoked
                       || (request.authentication == .bearer && api.code == .authUnauthenticated) {
                    try? discardSessionLocally()
                    throw error
                }

                guard request.isRetrySafe,
                      let ceiling = attemptCeiling(for: error),
                      attempt < ceiling,
                      let delay = retryDelay(for: error, afterAttempt: attempt, request: request) else {
                    throw error
                }
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    /// The attempt ceiling this failure allows, or `nil` when it must not be retried at all.
    private func attemptCeiling(for error: SonnyBackendError) -> Int? {
        switch error {
        case .offline, .unreachable:
            // §9.3 lists `client.offline` as retryable. One retry, because a second wait does not
            // make a missing network more present and the user is waiting on a sign-in screen.
            return 2
        case .api(let api):
            return api.isRetryable ? api.code.maximumAttempts : nil
        case .timedOut, .cancelled, .backendNotConfigured, .notSignedIn, .undecodableResponse:
            // A transport timeout has already spent the route's whole budget; retrying it doubles
            // a wait the user is watching. A 2xx body this client cannot read will not parse on a
            // second reading either. Cancellation beats every timeout and is never retried (§12).
            return nil
        }
    }

    /// How long to wait before the next attempt, or `nil` for "do not attempt again".
    ///
    /// A server-named `Retry-After` replaces the computed backoff, because a server that named a
    /// number knows something this client does not — **but only up to this request's own timeout,
    /// and past that the answer is to stop rather than to sleep.** `Retry-After` is data from the
    /// network with nothing bounding it, and an unbounded sleep sits inside an operation a user is
    /// watching: a server bug or a hostile one answering `Retry-After: 86400` would park a sign-in
    /// for a day, which is indistinguishable from a hung app and is the client doing it to itself.
    ///
    /// The bound is the route's own timeout rather than a number picked for the purpose. §12 already
    /// says how long this operation may take; waiting that again between two attempts keeps one
    /// operation inside twice its own budget, and a server asking for longer than the operation is
    /// worth is answered by failing with the delay preserved on the typed error, so a surface that
    /// wants to say "try again in an hour" still can.
    private func retryDelay(
        for error: SonnyBackendError,
        afterAttempt attempt: Int,
        request: SonnyBackendRequest
    ) -> TimeInterval? {
        guard case .api(let api) = error, let retryAfter = api.retryAfter else {
            return retryDelays.delay(afterAttempt: attempt, jitterFraction: jitterFraction())
        }
        guard retryAfter <= request.timeout else { return nil }
        return retryAfter
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        do {
            try await sleepForRetry(seconds)
        } catch {
            throw SonnyBackendError.cancelled
        }
    }

    // MARK: - Tokens

    private struct TokenSnapshot {
        let tokens: SonnyAccountTokens
        let generation: UInt64
    }

    private func loadedSnapshot() throws -> TokenSnapshot? {
        if !hasReadStore {
            if let stored = try tokenStore.loadTokens() {
                cachedTokens = stored
                tokenGeneration &+= 1
            }
            hasReadStore = true
        }
        guard let cachedTokens else { return nil }
        return TokenSnapshot(tokens: cachedTokens, generation: tokenGeneration)
    }

    private func requireSnapshot() throws -> TokenSnapshot {
        guard let snapshot = try loadedSnapshot() else { throw SonnyBackendError.notSignedIn }
        return snapshot
    }

    private func authorizedSnapshot() async throws -> TokenSnapshot {
        let snapshot = try requireSnapshot()
        let remaining = snapshot.tokens.accessTokenExpiresAt.timeIntervalSince(serverNow())
        guard remaining <= Self.proactiveRefreshMargin else { return snapshot }
        return try await refreshedSnapshot(newerThan: snapshot.generation)
    }

    /// A token newer than `staleGeneration`, refreshing at most once across every concurrent caller.
    private func refreshedSnapshot(newerThan staleGeneration: UInt64) async throws -> TokenSnapshot {
        // Somebody already refreshed past the token this caller used. No request is made: the
        // caller simply retries with what is now on hand. This is the branch that turns a burst of
        // stragglers into zero extra refreshes rather than one each.
        if tokenGeneration > staleGeneration, let tokens = cachedTokens {
            return TokenSnapshot(tokens: tokens, generation: tokenGeneration)
        }

        // Everything from here to the assignment below runs without an `await`, so on this actor it
        // is one indivisible step: two callers cannot both find `refreshTask` empty.
        if let existing = refreshTask {
            try await existing.value
        } else {
            let task = Task<Void, Error> { [self] in try await performRefresh() }
            refreshTask = task
            do {
                try await task.value
                refreshTask = nil
            } catch {
                refreshTask = nil
                throw error
            }
        }

        guard let tokens = cachedTokens else { throw SonnyBackendError.notSignedIn }
        return TokenSnapshot(tokens: tokens, generation: tokenGeneration)
    }

    private func performRefresh() async throws {
        guard let tokens = cachedTokens else { throw SonnyBackendError.notSignedIn }
        // Read before the network call, checked after it. Everything between is a suspension point
        // a sign-out can land in.
        let generationAtEntry = tokenGeneration
        let body = try JSONSerialization.data(withJSONObject: ["refresh_token": tokens.refreshToken])
        let request = SonnyBackendRequest(
            method: "POST",
            path: "/v1/auth/refresh",
            body: body,
            // §2.2: refresh deliberately sends no Authorization header, so that an expired or
            // missing access token can never be the reason a refresh fails.
            authentication: .none,
            idempotencyKey: UUID(),
            timeout: SonnyBackendTimeouts.auth,
            // **Not retry-safe, against §9.3's own table — PR #133's F2, and the exception is
            // argued rather than assumed.** §9.3 calls refresh safe to retry *with the same key*,
            // and the key is the whole mechanism: the server returns the stored response instead of
            // rotating again. That mechanism does not exist — the gateway reads no
            // `Idempotency-Key` on any route (SONNY-300, 0 hits under `server/`) — so a retry here
            // is a second POST of the identical refresh token, and §3.3 makes presenting an
            // already-rotated token past the platform's ten-second overlap the definition of theft,
            // answered by revoking the whole family. Measured before the fix: a `503` carrying
            // `Retry-After: 30` produced two identical refresh POSTs 30 s apart.
            //
            // **Capping the delay below the overlap was the other option and is not enough**, which
            // is why this is the fix. The overlap runs from when the server rotated, and the first
            // attempt's own duration counts against it — this route may sit for its full 20-second
            // timeout before failing, so the window can already be gone before any delay is
            // chosen. The elapsed-time bound that would be correct is more machinery than the
            // alternative deserves, because a failed refresh costs nothing: the next request that
            // needs a token tries again, and until then the access token in hand keeps working.
            isRetrySafe: false
        )
        do {
            let response = try await send(request, allowingRefresh: false)
            let decoded = try SonnyTokenResponse.decode(response.data)
            try adopt(
                decoded.tokens(emailAddress: tokens.emailAddress, receivedAt: serverNow()),
                onlyIfGenerationIsStill: generationAtEntry
            )
        } catch let error as SonnyBackendError {
            if case .api(let api) = error,
               api.code == .authTokenRevoked || api.code == .authUnauthenticated {
                try? discardSessionLocally()
            }
            throw error
        }
    }

    // MARK: - Transport

    private func perform(
        _ request: SonnyBackendRequest,
        accessToken: String?,
        baseURL: URL
    ) async throws -> SonnyBackendResponse {
        var urlRequest = URLRequest(url: Self.url(base: baseURL, path: request.path))
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue(
                request.contentType ?? "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let accessToken {
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        urlRequest.setValue(clientVersion, forHTTPHeaderField: "Sonny-Client-Version")
        urlRequest.setValue(platform, forHTTPHeaderField: "Sonny-Platform")
        // `Accept-Encoding` is deliberately NOT set here, though §2.2 says every request should
        // include gzip. URLSession sets it itself and transparently decompresses the reply; setting
        // it by hand switches that off and hands back compressed bytes for this code to decode.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw Self.transportError(error, timeout: request.timeout)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SonnyBackendError.undecodableResponse("response was not HTTP")
        }
        recordServerClock(from: http)

        let deprecation = Self.deprecationHeaders(from: http)

        let requestID = http.value(forHTTPHeaderField: "Sonny-Request-Id")
        guard (200..<300).contains(http.statusCode) else {
            let api = Self.errorEnvelope(
                data,
                statusCode: http.statusCode,
                headerRequestID: requestID,
                retryAfterHeader: http.value(forHTTPHeaderField: "Retry-After")
            )
            noteVersionSignals(statusCode: http.statusCode, deprecation: deprecation, api: api)
            throw SonnyBackendError.api(api)
        }
        noteVersionSignals(statusCode: http.statusCode, deprecation: deprecation, api: nil)
        return SonnyBackendResponse(statusCode: http.statusCode, data: data, requestID: requestID)
    }

    static func transportError(_ error: Error, timeout: TimeInterval) -> SonnyBackendError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else {
            return .unreachable(String(describing: type(of: error)))
        }
        switch urlError.code {
        case .timedOut:
            return .timedOut(after: timeout)
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            // The only branch that means "everything local still works" — §7.2 case 7's whole point.
            return .offline
        default:
            return .unreachable("URLError \(urlError.code.rawValue)")
        }
    }

    /// §9.3's one exception to deciding on `code`: a response with no parseable body at all is
    /// treated as `server.error`, which is retryable. Everything else keeps the server's own code.
    static func errorEnvelope(
        _ data: Data,
        statusCode: Int,
        headerRequestID: String?,
        retryAfterHeader: String?
    ) -> SonnyBackendAPIError {
        let headerRetryAfter = retryAfterHeader.flatMap(TimeInterval.init)
        guard let envelope = try? JSONDecoder().decode(WireErrorEnvelope.self, from: data) else {
            return SonnyBackendAPIError(
                code: .serverError,
                statusCode: statusCode,
                message: "Response body could not be read as the contract's error envelope.",
                requestID: headerRequestID,
                retryAfter: headerRetryAfter,
                envelopeSaysRetryable: true
            )
        }
        return SonnyBackendAPIError(
            code: SonnyBackendErrorCode(wire: envelope.error.code),
            statusCode: statusCode,
            message: envelope.error.message,
            requestID: envelope.error.request_id ?? headerRequestID,
            retryAfter: envelope.error.retry_after_seconds ?? headerRetryAfter,
            envelopeSaysRetryable: envelope.error.retryable ?? false,
            upgradeURL: envelope.error.upgrade_url
        )
    }

    /// `base` and `path` joined without either end having to agree about slashes.
    static func url(base: URL, path: String) -> URL {
        let trimmedBase = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: "\(trimmedBase)/\(trimmedPath)") ?? base
    }

    // MARK: - Version (contract §8)

    /// §8.4's two headers, as this client reads them.
    ///
    /// `Sonny-Deprecation` is compared case-insensitively against `true` and nothing else is
    /// believed — a header this client cannot read is a header that says nothing, which is the same
    /// direction the gateway takes with an unreadable `Sonny-Client-Version` (§8.3, "a request
    /// carrying no version, an unreadable one, or the header twice is served").
    struct DeprecationHeaders: Equatable, Sendable {
        let isDeprecated: Bool
        /// `Sonny-Deprecation-Info`, already through ``ClientUpgradeLink``. `nil` for absent, and
        /// equally for a link this app will not open.
        let infoLink: URL?

        static let none = DeprecationHeaders(isDeprecated: false, infoLink: nil)
    }

    static func deprecationHeaders(from response: HTTPURLResponse) -> DeprecationHeaders {
        let flag = response.value(forHTTPHeaderField: "Sonny-Deprecation")?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard flag == "true" else { return .none }
        return DeprecationHeaders(
            isDeprecated: true,
            infoLink: ClientUpgradeLink.openable(response.value(forHTTPHeaderField: "Sonny-Deprecation-Info"))
        )
    }

    /// What one response says about this build's version.
    ///
    /// **Three rules, in this order, and the order is the whole of it.**
    ///
    /// 1. **`410 version.unsupported` is the wall**, whatever else the response carried. Its
    ///    `upgrade_url` is the link, because §8.3 puts one there precisely so a client too old to
    ///    parse `/v1/meta` still has somewhere to send the user; the kept document answers only when
    ///    the refusal carried nothing usable.
    /// 2. **`Sonny-Deprecation: true` is the warning**, and it cannot lower the wall. The gate
    ///    returns before setting those headers for an unsupported client, so a deprecated header can
    ///    never accompany a `410` — but a *proxy* in front of the gateway can produce very nearly
    ///    anything, and a warning that could overwrite a wall would turn "nothing works" into
    ///    "everything works, update when you can".
    /// 3. **A `2xx` with no deprecation header clears everything**, and it is the only thing that
    ///    clears the wall. A served response is proof from the deciding party that this build is at
    ///    or above the minimum and at or above the recommended version, which is exactly the two
    ///    facts this state is about — so an operator who lowers either bound is believed on the next
    ///    successful request rather than at the next launch.
    ///
    /// **A non-`2xx` carrying no deprecation header changes nothing**, deliberately: a `500`, a `503`
    /// from a load balancer, or a transport failure says nothing at all about which builds this
    /// deployment serves, and reading silence there as "current" would clear a wall on a bad gateway
    /// day.
    private func noteVersionSignals(
        statusCode: Int,
        deprecation: DeprecationHeaders,
        api: SonnyBackendAPIError?
    ) {
        if let api, api.code == .versionUnsupported {
            setVersionState(.tooOld(link: ClientUpgradeLink.openable(api.upgradeURL)
                ?? ClientUpgradeLink.openable(meta?.upgradeURL)))
            return
        }
        if deprecation.isDeprecated {
            if case .tooOld = versionState { return }
            setVersionState(.updateAvailable(
                link: deprecation.infoLink ?? ClientUpgradeLink.openable(meta?.upgradeURL)
            ))
            return
        }
        if (200..<300).contains(statusCode) {
            setVersionState(.current)
        }
    }

    private func setVersionState(_ state: ClientVersionState) {
        guard state != versionState else { return }
        versionState = state
        for continuation in versionObservers.values {
            continuation.yield(state)
        }
    }

    /// What this deployment last said about this build's version.
    public func clientVersionState() -> ClientVersionState { versionState }

    /// The `/v1/meta` document this client is keeping, or `nil` before one has been read.
    public func metaDocument() -> SonnyMetaDocument? { meta }

    /// Every change to ``clientVersionState()``, beginning with what it says right now.
    ///
    /// **The current value first, so an observer that starts late is not wrong until something
    /// moves.** The launch fetch and the first surface appearing are separately scheduled, and a
    /// stream that only carried changes would leave a widget rendering `.current` over a build the
    /// client had already been told is too old.
    ///
    /// **A stream rather than a callback, and that is a language constraint rather than a
    /// preference.** This is an actor and every surface that wants this is `@MainActor`; a stored
    /// `@Sendable` closure capturing one of those does not compile under this package's language
    /// mode. `ClientVersionState` is `Sendable`, so a stream crosses the boundary with nothing to
    /// argue about.
    public func clientVersionUpdates() -> AsyncStream<ClientVersionState> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.yield(versionState)
            versionObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeVersionObserver(id) }
            }
        }
    }

    private func removeVersionObserver(_ id: UUID) {
        versionObservers.removeValue(forKey: id)
    }

    /// §8.3's `GET /v1/meta`, at most one at a time.
    ///
    /// **Called on launch and on any `410`, and from nowhere else** — §8.3 says so in as many words,
    /// and says why: "It does not call it per request." A client that asked before each request
    /// would double every route's traffic to re-read a document that changes when a founder edits a
    /// deployment variable.
    ///
    /// **A failure keeps the document already held.** The refusal that most often ends this call is
    /// the `410` this fetch was started by, and that path has already recorded the wall and its link
    /// through `noteVersionSignals`; there is nothing for a cleared document to add and a real one
    /// to lose.
    @discardableResult
    public func refreshMetaDocument() async -> SonnyMetaDocument? {
        if let existing = metaFetch {
            await existing.value
        } else {
            let task = Task<Void, Never> { [self] in await performMetaFetch() }
            metaFetch = task
            await task.value
            metaFetch = nil
        }
        return meta
    }

    private func performMetaFetch() async {
        let request = SonnyBackendRequest(
            method: "GET",
            path: "/v1/meta",
            body: nil,
            // §2.2's public route list and `auth/gate.ts`'s `PUBLIC_ROUTES` both carry this one: a
            // client that had to sign in before it could be told its build is too old to sign in
            // with is a client in a loop.
            authentication: .none,
            // §9.1 puts a key on every `POST`. This is a `GET` and there is no operation to make
            // at-most-once.
            idempotencyKey: nil,
            // §12's "auth, account, meta, health, delete" row.
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        )
        guard let response = try? await send(
            request,
            allowingRefresh: false,
            allowingMetaRefresh: false
        ) else {
            return
        }
        guard let document = SonnyMetaDocument.decode(response.data) else { return }
        meta = document
    }

    // MARK: - Clock

    func serverNow() -> Date { now().addingTimeInterval(serverClockOffset) }

    /// The last instant a server reported, paired with the monotonic reading it arrived at.
    ///
    /// **The pair is the point.** An instant alone would have to be compared against a clock the user
    /// controls; with the monotonic reading beside it a caller can say "that instant, plus however
    /// much real time has passed since", and no wall-clock change can shorten that. `nil` when no
    /// response has ever been seen, which a caller must treat as "no trustworthy time" rather than
    /// as "now".
    func lastObservedServerTime() -> ObservedServerTime? { lastServerObservation }

    private func recordServerClock(from response: HTTPURLResponse) {
        guard let header = response.value(forHTTPHeaderField: "Date"),
              let serverDate = SonnyHTTPDate.parse(header) else { return }
        let monotonic = monotonicNow()
        let corroborated = corroboratedInstant(reported: serverDate, at: monotonic)
        // **The offset follows the header whole, and only the observation is bounded** (SONNY-344).
        // This was written both ways and the measurement decided it. Capping the offset as well
        // removes a transient: `EntitlementService` judges at the later of `serverNow()` and the
        // mark, so one header a year out refuses every gated capability until the next response
        // arrives. But that refusal is bounded and cures itself — the refusal is what starts the
        // refresh, and `recordServerClock` runs on every response including a failing one — whereas
        // capping the offset makes `serverNow()` stop meaning "the server's clock as last reported",
        // which is what token expiry is reasoned in and what
        // `aServerSayingMoreTimeHasPassedIsBelievedOverThisMacsOwnClock` holds.
        //
        // **The offset does reach the Keychain, and the sentence here used to deny it** (PR #173's
        // review, finding 3). `refreshedSnapshot` writes `receivedAt: serverNow()`, and
        // `WireTokenResponse.tokens(emailAddress:receivedAt:)` turns that into
        // `accessTokenExpiresAt`, which the token store persists — so a header a year out is written
        // down as a session that expires a year late. **What makes that non-permanent is not that it
        // was never stored**, it is that the gateway is the other half of the check: a token this
        // client believes is live is still refused as `401 auth.token_expired`, and §3.3's reactive
        // refresh rewrites the record with an expiry derived from a fresh, correct `Date`. The
        // entitlement mark has no such second party — nothing on the network disagrees with it —
        // which is exactly why it needed the bound and the repair and this does not.
        serverClockOffset = serverDate.timeIntervalSince(now())
        // **Only ever forward.** A response that reports an earlier instant than one already seen —
        // a proxy with a slow clock, a replayed response — must not lower what this client will
        // vouch for, or the defence could be walked back by the same party it defends against.
        if let existing = lastServerObservation, existing.serverInstant >= serverDate { return }
        lastServerObservation = ObservedServerTime(serverInstant: corroborated, monotonicAt: monotonic)
    }

    /// A reported instant, held to the pace real time can account for (SONNY-344).
    ///
    /// **The mirror of the backward guard directly above, and it was missing.** That guard says a
    /// server instant may not go down; nothing said how fast it may go up, so one `Date` header from
    /// a gateway whose clock was a year out wrote a year into `lastServerObservation` — and from
    /// there into `EntitlementService`'s persisted high-water mark, which is the value the user must
    /// not be able to lower and which therefore had no way back. Server time advances at exactly the
    /// rate of real time, and `ContinuousClock` measures real time in a way nothing on this Mac can
    /// set, so the previous observation carried forward is the ceiling a legitimate advance sits
    /// under.
    ///
    /// **Capped rather than refused, which is the half that makes it self-correcting.** A gateway
    /// that steps its own clock forward — an NTP correction after a long drift — is not wrong
    /// afterwards, only ahead; refusing every observation from it would freeze this client's
    /// observation permanently behind, because each later response is ahead of the same frozen
    /// projection. Capping absorbs `maximumUncorroboratedForwardJump` per response, so a real
    /// correction of a few minutes is caught up in two or three responses.
    ///
    /// **What the cap is spent in is responses, not seconds, and it compounds — so "a year can
    /// never get in" is false and the true bound is worth writing down** (PR #173's review, finding
    /// 2). Each response moves this observation up by at most 300 s beyond real time, so a year of
    /// error is absorbed in 31_536_000 / 300 = **105,120 responses**, and the amount that actually
    /// matters — enough to reach the end of a claim's own window, 24 h of life plus 72 h of grace
    /// plus 300 s of tolerance — in 345_900 / 300 = **1,153**. Those are the numbers that make this
    /// safe rather than an absolute refusal, and a client that made 1,153 requests against a gateway
    /// stuck a year ahead would get there. What stops that from being permanent is not this bound
    /// but `EntitlementService.markKeptOrReset`, which is the other half of the fix.
    ///
    /// **What it cannot do:** an anchor is needed to bound against, so the first observation of a
    /// process is accepted as reported. That residual is closed on the other side, where a claim the
    /// gateway has just signed is fresh evidence about the gateway's own clock — see
    /// `EntitlementService.adopt`.
    private func corroboratedInstant(reported: Date, at monotonic: ContinuousClock.Instant) -> Date {
        guard let existing = lastServerObservation else { return reported }
        let ceiling = existing
            .projected(to: monotonic)
            .addingTimeInterval(Self.maximumUncorroboratedForwardJump)
        return min(reported, ceiling)
    }

    /// Forget the instant a server last reported (SONNY-344).
    ///
    /// **`EntitlementService` calls this, and only when it has just reset the persisted mark this
    /// observation produced.** The two are one belief about server time held in two places — the
    /// observation is where it enters, the mark is where it is written down — so retiring the belief
    /// has to retire both or the observation immediately re-establishes the mark it was reset from,
    /// and the repair would only land after the app was quit and reopened. It costs the caller
    /// nothing it still has a use for: the mark is reset only when it has been shown to be ahead of a
    /// claim the gateway has just signed, which is the same thing being said about this observation.
    func discardServerObservation() {
        lastServerObservation = nil
    }
}

/// An instant a server reported, and the monotonic reading it was received at (SONNY-135).
///
/// **Two values because either alone is defeated by the thing the other answers.** A server instant
/// on its own goes stale the moment it is stored and has to be compared against *some* clock; the
/// local one is the user's to set. A monotonic reading on its own says how much time has passed and
/// never says from when. Together they say "this instant, plus the real time since", which is a
/// statement a wall-clock change cannot alter.
public struct ObservedServerTime: Equatable, Sendable {
    public let serverInstant: Date
    public let monotonicAt: ContinuousClock.Instant

    public init(serverInstant: Date, monotonicAt: ContinuousClock.Instant) {
        self.serverInstant = serverInstant
        self.monotonicAt = monotonicAt
    }

    /// This observation carried forward to `monotonicNow` — the instant it implies the server's
    /// clock now reads.
    ///
    /// Elapsed time is clamped at zero: a monotonic clock never goes backwards, so a negative
    /// reading is a caller comparing two different clocks, and answering the observation unchanged
    /// is the conservative reading of that mistake.
    public func projected(to monotonicNow: ContinuousClock.Instant) -> Date {
        let elapsed = monotonicAt.duration(to: monotonicNow)
        return serverInstant.addingTimeInterval(max(0, TimeInterval(elapsed)))
    }
}

extension TimeInterval {
    /// A `Duration` as seconds. `components` is `(seconds, attoseconds)`; both are needed, because
    /// dropping the fraction would make a sub-second duration read as no time at all.
    init(_ duration: Duration) {
        let parts = duration.components
        self = Double(parts.seconds) + Double(parts.attoseconds) * 1e-18
    }
}

/// The `URLSession` the app's own backend calls run on.
///
/// **`URLSession.shared` is a stock default nobody chose, and it is backed by a disk cache** — 20 MB
/// of it on this machine, with `requestCachePolicy` at `useProtocolCachePolicy` (PR #133's F11,
/// measured). That is the same shape §12 calls out for timeouts and that this client already fixed
/// there. Exposure today is small: the only routes are auth POSTs, which Foundation does not
/// normally store. It stops being small the moment SONNY-130 and SONNY-134 point authenticated
/// `GET`s at this same client — `/v1/account/entitlements` and `/v1/tasks/{task_id}` — because a
/// shared on-disk cache is exactly what stores a `GET` response, and those responses are the user's.
///
/// So the configuration is chosen here rather than inherited: ephemeral, whose cookie and credential
/// stores are its own and in memory rather than the process-wide ones the shared session persists
/// to; `urlCache` cleared outright, so not even an in-memory response cache survives; and a request
/// policy that says so at the request level too, because a proxy or a server sending cache headers
/// should not be able to reintroduce what this removed.
///
/// The client's `session` parameter keeps its `= .shared` default, which is the pattern the six
/// provider clients already use and the one SONNY-128's contract named. This is what the shipping
/// app passes instead, and `SignInSurfaceTests.theProductionClientDoesNotRunOnTheSharedSession`
/// holds that it is the only session named at that site.
public enum SonnyBackendSession {
    public static func forBackendCalls() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

/// Version and platform for §2.2's two identifying headers.
public enum SonnyClientIdentity {
    /// Marketing version plus build, e.g. `1.0+1`. A bare `swift run` has no bundle and reports
    /// `0.0+0` rather than inventing a version — the packaged app is the only build with an honest
    /// answer, and it is the only one a user runs.
    public static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)+\(build)"
    }

    public static var platform: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macos/\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

enum SonnyHTTPDate {
    /// RFC 1123, the form an HTTP `Date` header takes. Fixed locale and zone, or a device set to a
    /// non-Gregorian calendar parses its own server's clock wrong.
    static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parse(_ value: String) -> Date? { formatter.date(from: value) }
}

private struct WireErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let retryable: Bool?
        let retry_after_seconds: TimeInterval?
        let request_id: String?
        /// §7.1's one conditional field, on `version.unsupported` alone (SONNY-204). Optional here
        /// rather than absent, because §8.1 makes a response field an additive change and §2.1 makes
        /// ignoring an unknown one the client's job — so a code that starts carrying it later needs
        /// no change on this side.
        let upgrade_url: String?
    }

    let error: Body
}

/// §3.2's token response, returned by `email/verify`, `oauth/{provider}` and `refresh`.
struct SonnyTokenResponse: Decodable {
    struct User: Decodable {
        let id: String
    }

    let access_token: String
    let refresh_token: String
    let expires_in: TimeInterval
    let refresh_expires_at: String?
    let user: User
    /// §3.6, advisory. Decoded so that SONNY-129 does not have to re-derive the field; a client
    /// that ignores it is correct per the contract and gets two accounts, which is why no prompt
    /// is built here.
    let link_hint: String?

    static func decode(_ data: Data) throws -> SonnyTokenResponse {
        do {
            return try JSONDecoder().decode(SonnyTokenResponse.self, from: data)
        } catch {
            throw SonnyBackendError.undecodableResponse(String(describing: error))
        }
    }

    /// **Expiry is scheduled from `expires_in`, not from `expires_at`.** §3.2 says why both are
    /// sent: `expires_in` is immune to clock skew and is what a client should schedule from, and
    /// `receivedAt` here is already server time, because the `Date` header on this very response
    /// updated the offset before the body was read.
    func tokens(emailAddress: String?, receivedAt: Date) -> SonnyAccountTokens {
        SonnyAccountTokens(
            accessToken: access_token,
            refreshToken: refresh_token,
            accessTokenExpiresAt: receivedAt.addingTimeInterval(expires_in),
            refreshTokenExpiresAt: refresh_expires_at.flatMap(SonnyISO8601.parse),
            userID: user.id,
            emailAddress: emailAddress
        )
    }
}

enum SonnyISO8601 {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
