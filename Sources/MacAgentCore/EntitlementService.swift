import Foundation

/// The check the rest of the app asks: **is this user allowed to do this right now** (SONNY-135).
///
/// **The answer is local and instant, and that is the requirement rather than an optimisation.**
/// `decision(for:)` reads a cached, signed claim and verifies it against a public key this build
/// holds. It makes no network call, it cannot block on one, and it works with the Wi-Fi off — which
/// is what §16.3's guarantee rests on and what the ticket asks to be asserted rather than described.
///
/// **Row 18 (SONNY-23) owns what is gated; this owns the answer.** Nothing in this file names a
/// capability key, and no capability is gated anywhere in this repository today. That is the row
/// boundary the founder set on 2026-08-16 and it is deliberate: a ticket that decided screen control
/// was the paid line would be taking row 18's decision in row 12.
///
/// ## The two directions of fail-closed, which is the pair most likely to be inverted
///
/// - **A gated capability with no valid claim is refused.** No key, no cached claim, an expired one
///   past its grace, a forged one — every path ends in `.refused`, and none of them ends in
///   `.entitled`.
/// - **A free local capability never asks this at all.** Not "asks and is allowed": does not call.
///   Contract §5.3.1 states it as a code shape for exactly this reason — "a check that is never made
///   cannot fail closed" — and `InstantCommandResolver` is the thing it most matters for: it imports
///   only `Foundation`, makes no network call of any kind, and returns a plan straight from local
///   stores. `EntitlementFreePathScanTests` holds that no free path acquires a dependency on this
///   type, and `InstantCommandResolverTests` holds that those commands still resolve with none of
///   this wired at all.
///
/// ## Refreshing
///
/// `decision(for:)` never waits for the network, so the refresh is a **detached, single-flight task**
/// this actor starts when the cached claim is stale — the same shape, and the same generation-free
/// reasoning, as `SonnyBackendClient`'s token refresh: one request whatever the number of callers,
/// and a failure that costs nothing because the cached claim keeps working until its grace runs out.
/// `refreshNow()` is the explicit form, for a caller that wants the new claim rather than the next
/// answer.
public actor EntitlementService {
    private let client: SonnyBackendClient
    private let store: any EntitlementStoring
    private let keys: EntitlementKeySet
    private let monotonicNow: @Sendable () -> ContinuousClock.Instant

    private var refreshTask: Task<Void, Never>?

    /// The highest instant this process is willing to vouch for, and the monotonic reading it was
    /// established at. Re-anchored on every read, so it advances with real time and never with the
    /// wall clock.
    private var trustedAnchor: (instant: Date, at: ContinuousClock.Instant)?

    /// How far the mark may advance before it is written back to the store: **60 seconds**.
    ///
    /// A Keychain write per check would be absurd for a value that moves continuously, and a mark
    /// persisted to the second buys nothing — what it bounds is how much a *relaunch* forgets, and a
    /// minute of forgetting is nothing against a 96-hour window. It is the same shape as any
    /// write-behind: the cost of a crash is bounded by the interval, and the interval is chosen so
    /// the cost is uninteresting.
    static let markPersistenceInterval: TimeInterval = 60

    /// No parameter has a default, deliberately — the same hazard `SonnyBackendClient` records for
    /// its own token store: every packaged build on a Mac shares one Keychain, so a fixture that
    /// inherited a default store would read and delete the founder's real entitlement.
    /// **There is no `now` here, and its absence is the point.** Every instant this service judges
    /// against comes from `SonnyBackendClient.serverNow()`, which is §3.5's mechanism: the offset
    /// between the `Date` header on the last response and this Mac's own clock. A second clock
    /// injected here would be a second time source for the same question, and a test that set it
    /// would be asserting against a clock the shipping app does not consult — which is how a
    /// green suite comes to say nothing. A test controls time by giving the *client* its clock.
    public init(
        client: SonnyBackendClient,
        store: any EntitlementStoring,
        keys: EntitlementKeySet,
        /// The same clock the client is given, and it has to be the same one: the two are compared.
        /// In every shipping path both are `ContinuousClock.now`, which is one clock.
        monotonicNow: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.client = client
        self.store = store
        self.keys = keys
        self.monotonicNow = monotonicNow
    }

    /// May this Mac do the thing this capability names, right now, with no network?
    ///
    /// **Every failure here is a refusal**, including the ones that are this build's own fault — an
    /// unreadable store, a claim signed by a key this build does not hold. A check that could not be
    /// completed is not a check that passed.
    public func decision(for capability: EntitlementCapability) async -> EntitlementDecision {
        // **A session this Mac cannot read is answered as no session, deliberately.** `try?`
        // collapses two cases — nothing stored, and stored bytes this build cannot decode — and both
        // have the same recovery and the same honest answer: there is no session in hand. Reporting
        // the second differently would need a case whose only advice is still "sign in again".
        guard let session = try? await client.restoredIdentity() else {
            return .refused(.notSignedIn)
        }
        let stored: StoredEntitlement?
        do {
            stored = try store.load()
        } catch {
            // **Every refusal below this line starts a refresh before it returns** (PR #152's
            // review, F2). Three of them are states a refresh is the whole cure for — nothing
            // cached, bytes this build cannot read, a claim belonging to somebody else — and
            // returning without asking for a new one left a freshly signed-in Mac permanently at
            // "Connect once so Sonny can check your plan" while nothing ever connected. The sentence
            // described an action the code did not take.
            startRefresh()
            return .refused(.unreadableClaim)
        }
        guard let stored else {
            startRefresh()
            return .refused(.noClaim)
        }
        guard case .success(let claim) = EntitlementVerifier.verify(stored.compactClaim, against: keys) else {
            startRefresh()
            return .refused(.unreadableClaim)
        }

        let instant = await effectiveNow(floor: stored.observedServerTime)
        // **The claim's owner is checked here rather than only inside `judge`**, so a claim left by a
        // previous user can be *replaced* rather than merely refused. Without this the second person
        // to sign in on a Mac meets the first one's claim, is refused every gated capability, and is
        // told to sign in again — which is what they just did. Clearing gives `discardLocally` its
        // caller and the refresh below gives them a claim of their own.
        if claim.subject != session.userID {
            // **`discardLocally()` rather than `store.clear()`, so the three sentences that say this
            // is its caller are true** (cycle 3's N1 note). The behaviour is identical — that method
            // is one line — and a comment claiming a call that is not made is the shape this
            // repository files findings about; the reader asking "what can clear this" is asking a
            // question the answer to which had better be a real call.
            try? discardLocally()
            startRefresh()
            return .refused(.claimIsForAnotherSession)
        }
        // Started, never awaited: the answer below is the cached claim's, and a refresh that
        // succeeds changes the *next* answer rather than this one.
        if EntitlementJudgement.shouldRefresh(claim: claim, now: instant) {
            startRefresh()
        }
        return EntitlementJudgement.judge(
            claim: claim,
            capability: capability,
            session: session,
            now: instant
        )
    }

    /// What the cached claim says about this account's subscription, or `nil` when it says nothing
    /// (SONNY-216).
    ///
    /// ## This is a second public reader on this actor, and it is deliberately not a claim accessor
    ///
    /// `decision(for:)` is a narrow surface on purpose: a caller names one capability and gets one
    /// answer, and cannot enumerate what the account has. **Handing out the `EntitlementClaim`
    /// itself would widen that**, and in the direction that matters — a caller holding the claim can
    /// read `capabilities` directly and decide entitlement for itself, without `judge`, without the
    /// session check and without `effectiveNow`'s clock defence. Every one of those is a rule this
    /// type exists to apply, and none of them is enforceable on a value that has left it.
    ///
    /// **So what this returns is a purpose-built value and not the claim**: a plan key and one of
    /// two states, both of which are already true of what the user is looking at. It answers a
    /// question about *billing*, which is what Command Center's Account section asks;
    /// `decision(for:)` still answers the only question about *permission*, and it remains the only
    /// thing that does. Adding this does not make a second way to ask whether a capability is
    /// granted, and `SubscriptionSnapshot` carries no capability list so that it cannot become one.
    ///
    /// **Local and instant, exactly as `decision(for:)` is.** It reads the cache, verifies it against
    /// a held public key and makes no network call — so the Account section renders with the Wi-Fi
    /// off, which is §16.3's guarantee applied to a screen rather than to a capability. A stale
    /// claim starts the same background refresh the decision path starts, and changes the *next*
    /// answer rather than this one.
    public func currentSubscription() async -> SubscriptionSnapshot? {
        guard let session = try? await client.restoredIdentity() else { return nil }
        guard let stored = ((try? store.load()) ?? nil) else {
            startRefresh()
            return nil
        }
        guard case .success(let claim) = EntitlementVerifier.verify(stored.compactClaim, against: keys) else {
            startRefresh()
            return nil
        }
        let instant = await effectiveNow(floor: stored.observedServerTime)
        if EntitlementJudgement.shouldRefresh(claim: claim, now: instant) {
            startRefresh()
        }
        return SubscriptionReading.read(claim: claim, session: session, now: instant)
    }

    /// The instant a claim is judged at, and **the half of the clock defence that was missing**.
    ///
    /// **What was wrong** (PR #152's review, F1). The persisted mark had exactly one writer, `adopt`,
    /// which stored the claim it had just fetched — whose `issued_at` the gateway sets from the same
    /// instant. So the mark was always ≈ the claim's own issue time, `max(serverNow, mark)` could
    /// never land past `honouredUntil`, and the mark could not refuse anything. Measured: the mark
    /// minus `issued_at` was **0.0 s**, and a Mac 100 hours past its window answered `entitled` again
    /// the moment its owner set the clock back. The 96-hour offline bound was not a bound against
    /// the only party who benefits from defeating it.
    ///
    /// **What replaces it.** Three readings, and the latest of them wins:
    ///
    /// - `client.serverNow()` — the local clock plus §3.5's offset. Moves with the local clock, so it
    ///   can only ever push the answer *later*, which is the fail-closed direction and is why it stays.
    /// - **The last instant a server actually reported, carried forward by monotonic elapsed time.**
    ///   This is the one a wall-clock change cannot move: `ObservedServerTime` pairs the `Date` header
    ///   with a `ContinuousClock` reading, so "that instant plus the real time since" holds however
    ///   the Mac's clock is set. It is what closes the rollback *within* a process run.
    /// - **The persisted mark, likewise carried forward.** It is what closes the rollback *across* a
    ///   relaunch, and it is written back below as it advances.
    ///
    /// **The residual, which is the honest bound rather than a gap.** With no observation this
    /// process and a mark from the last run, a rollback re-enters the window only as far back as the
    /// last time the app ran with a correct clock. Closing that needs a time source that survives a
    /// reboot and is not the user's, which this Mac does not have.
    private func effectiveNow(floor: Date?) async -> Date {
        let monotonic = monotonicNow()
        var candidates: [Date] = [await client.serverNow()]
        if let observed = await client.lastObservedServerTime() {
            candidates.append(observed.projected(to: monotonic))
        }
        if let floor {
            // Anchored the first time it is seen, then advanced from the anchor, so a mark read at
            // launch keeps moving with real time rather than sitting where the last run left it.
            if trustedAnchor == nil || floor > trustedAnchor!.instant {
                trustedAnchor = (floor, monotonic)
            }
        }
        if let anchor = trustedAnchor {
            candidates.append(
                ObservedServerTime(serverInstant: anchor.instant, monotonicAt: anchor.at)
                    .projected(to: monotonic)
            )
        }
        let now = candidates.max() ?? Date.distantPast

        // **Only what a wall clock cannot author is persisted.** `serverNow()` is deliberately
        // excluded from the mark: a clock pushed a year forward would otherwise be written down and
        // refuse every claim for a year afterwards, which is fail-closed and is also a permanent
        // self-inflicted lockout. What is written is the observation-derived reading, which no
        // setting of the clock can raise.
        var trustworthy: Date?
        if let observed = await client.lastObservedServerTime() {
            trustworthy = observed.projected(to: monotonic)
        }
        if let anchor = trustedAnchor {
            let projected = ObservedServerTime(serverInstant: anchor.instant, monotonicAt: anchor.at)
                .projected(to: monotonic)
            trustworthy = max(trustworthy ?? projected, projected)
        }
        if let trustworthy {
            trustedAnchor = (trustworthy, monotonic)
            persistMark(trustworthy, floor: floor)
        }
        return now
    }

    /// Write the advanced mark back, at most once per `markPersistenceInterval` of movement.
    ///
    /// A failure is swallowed on purpose: the mark is a hardening of an answer this method has
    /// already computed, and failing a decision because a Keychain write did not land would turn a
    /// defence into an outage. What is lost is how much a relaunch forgets, which is bounded by the
    /// window either way.
    private func persistMark(_ mark: Date, floor: Date?) {
        if let floor, mark.timeIntervalSince(floor) < Self.markPersistenceInterval { return }
        guard let existing = ((try? store.load()) ?? nil) else { return }
        try? store.save(
            StoredEntitlement(compactClaim: existing.compactClaim, observedServerTime: mark)
        )
    }

    /// Fetch, verify and cache a fresh claim, or throw.
    ///
    /// **Verified before it is stored**, so a response this build cannot check never becomes the
    /// cached answer — and the claim already on disk, which may still be inside its grace window,
    /// survives a bad one rather than being replaced by it.
    @discardableResult
    public func refreshNow() async throws -> EntitlementClaim {
        let response = try await client.send(SonnyBackendRequest(
            method: "GET",
            path: "/v1/account/entitlements",
            body: nil,
            authentication: .bearer,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            // A `GET` that changes nothing on the server; §9.3's own reading of what is safe to send
            // again. It carries no idempotency key for the same reason — there is nothing for one to
            // be about.
            isRetrySafe: true
        ))
        guard let envelope = try? JSONDecoder().decode(WireEntitlementResponse.self, from: response.data) else {
            throw SonnyBackendError.undecodableResponse("entitlement response")
        }
        guard case .success(let claim) = EntitlementVerifier.verify(envelope.entitlement, against: keys) else {
            throw SonnyBackendError.undecodableResponse("entitlement claim did not verify")
        }
        // **The instant a refresh vouches for is the observation's, not `serverNow()`.** The response
        // that just arrived carried a `Date` header, so `lastObservedServerTime` is fresh and is a
        // value the local clock cannot have authored — which is the whole property the mark exists
        // to carry. Falling back to `serverNow()` covers a response with no parseable `Date`, where
        // there is nothing better and the mark is no worse than it was.
        let observedAt = await client.lastObservedServerTime()?.projected(to: monotonicNow())
        let fallback = await client.serverNow()
        try await adopt(claim, compact: envelope.entitlement, observedAt: observedAt ?? fallback)
        return claim
    }

    /// Take a verified claim, **keeping the later of the two high-water marks**.
    ///
    /// **A claim is only replaced by one issued no earlier than the one on disk**, which closes the
    /// one replay this side can close: an old signed response replayed by something on the network is
    /// a real claim, correctly signed, from a moment when the account may have had *more* than it has
    /// now — so accepting it would undo a revocation. What that does not close is an attacker who can
    /// write the Keychain directly, and nothing here could: they hold the refresh token in the same
    /// keychain, which is the larger asset. The bound on that case is the claim's own life plus its
    /// grace, which is the reason the lifetime is a day rather than a week.
    func adopt(_ claim: EntitlementClaim, compact: String, observedAt: Date) async throws {
        let existing = ((try? store.load()) ?? nil)
        // **Not optional, and it never was** (PR #173's review, finding 5). `observedAt` is a
        // non-optional `Date`, so the pair this is the larger of always has a member; written as a
        // `compactMap`/`max()` over an array it *read* as optional, and the sentence below then
        // described what a `nil` mark would mean — a state that cannot occur, which is a claim a
        // later reader would have acted on. A mutant deleting the branch that handled it survived,
        // correctly, because the branch was unreachable.
        let highWater = max(existing?.observedServerTime ?? observedAt, observedAt)
        if let existing,
           case .success(let current) = EntitlementVerifier.verify(existing.compactClaim, against: keys),
           current.issuedAt > claim.issuedAt,
           // **And the stored claim is still one this Mac could honour** (SONNY-344). A claim the
           // mark has already killed grants nothing, so preferring it over a live one protects
           // nothing — and preferring it is the only thing that made a wrong mark permanent, because
           // the mark that killed it then killed every claim the gateway signed afterwards.
           highWater <= current.honouredUntil {
            // **The claim is declined and the observation is kept** (PR #152's review, F1). This
            // branch used to return outright, throwing away a genuinely newer reading of server time
            // because the claim it arrived with was older — which is the one direction the mark must
            // never move in. The older claim is still refused; only the clock advances.
            if highWater != existing.observedServerTime {
                try store.save(
                    StoredEntitlement(compactClaim: existing.compactClaim, observedServerTime: highWater)
                )
            }
            return
        }
        try store.save(StoredEntitlement(
            compactClaim: compact,
            observedServerTime: await markKeptOrReset(highWater, adopting: claim)
        ))
    }

    /// The mark to store beside a claim being adopted — **reset rather than kept when it is already
    /// past the end of that claim's own window** (SONNY-344).
    ///
    /// **What was wrong.** The mark had no ceiling. One `Date` header from a gateway whose clock was
    /// a year out wrote a year into it, and because a high-water mark only ever rises, nothing in the
    /// product could bring it back: after the gateway's clock was put right, every claim it signed
    /// was judged against an instant a year later and answered `.lapsed`, for a year, and then
    /// forever as the mark crept on with real time. No attacker is involved and the user is the
    /// victim. `SonnyBackendClient.corroboratedInstant` now stops that header from being recorded at
    /// all — but only when there is a previous observation to measure it against, so the first
    /// response of a process is still taken at its word and the mark still needs a way back.
    ///
    /// **The way back, and why it is this one.** A mark past `honouredUntil` of the claim it is being
    /// stored beside is a mark that kills that claim. That is a legitimate thing for it to have done
    /// to the claim it *was* stored beside — that is its whole job — but the claim arriving here came
    /// from the gateway just now, and a gateway does not sign a claim it already considers dead. So a
    /// mark past this claim's window is not an instant this Mac ever saw a server report; it is the
    /// wrong reading, and the claim's own `issuedAt` — signed, gateway-authored, and the newest
    /// statement about that clock in existence — is what replaces it.
    ///
    /// **What it costs, stated rather than implied.** Any response that carries a correctly signed
    /// claim old enough that the mark already sits past its window resets the mark to that claim's
    /// issue time. Two things can produce one, and both are the class `adopt` already concedes above:
    /// somebody who can serve this client responses — which needs TLS to the gateway broken from
    /// inside the Mac, the same person who can read and write the Keychain this mark and the refresh
    /// token both live in — and the stale replay that guard was written for, a response held
    /// somewhere on the network for longer than the claim's own 96-hour window. It is emphatically
    /// **not** the case the mark exists to stop, which is a person moving their Mac's clock in
    /// System Settings: that moves `serverNow()`, which is excluded from the mark, and it cannot on
    /// its own make a claim old enough for this to fire.
    ///
    /// **The observation goes with it**, or the repair does not survive the round trip: the client's
    /// in-memory observation is where the bad instant entered, so leaving it in place would let it
    /// re-establish the mark on the very next decision and defer the repair to the next launch.
    private func markKeptOrReset(_ mark: Date, adopting claim: EntitlementClaim) async -> Date {
        // **Strictly past the end of the window, and the strictness is load-bearing** (PR #173's
        // review, finding 4). `judge` answers `.entitled` at exactly `honouredUntil`, so a mark
        // sitting on that instant belongs to a claim that is still alive and resetting it would roll
        // the mark back by the claim's whole 96-hour window on a live entitlement — the one
        // direction the mark must never move in. `theBoundaryOfTheResetIsTheLastHonouredInstant`
        // pins it; a mutant loosening this to `>=` survived the first battery.
        guard mark > claim.honouredUntil else { return mark }
        await client.discardServerObservation()
        trustedAnchor = (claim.issuedAt, monotonicNow())
        return claim.issuedAt
    }

    /// Forget the cached claim on this Mac.
    ///
    /// **Called by `decision(for:)` when it meets a claim belonging to another session**, which is
    /// what turns that state from a permanent refusal into a recovery: the stale bytes go, a refresh
    /// is started, and the next answer is the current user's own. It is public as well, for a caller
    /// that wants the bytes gone at a moment of its own choosing — sign-out being the obvious one,
    /// which does not call it today because the session check already refuses a claim with no
    /// session behind it.
    public func discardLocally() throws {
        try store.clear()
    }

    /// Wait for whatever refresh this actor has in flight, if any. **Tests, and nothing else.**
    ///
    /// A detached task is invisible to a test, which is how a suite comes to assert on a cache the
    /// refresh has not written yet. Exposed rather than made deterministic, because the production
    /// behaviour — an answer that never waits — is the property worth keeping.
    func awaitPendingRefresh() async {
        await refreshTask?.value
    }

    /// One refresh at a time, whatever the number of callers.
    ///
    /// Everything from the check to the assignment runs without an `await`, so on this actor it is
    /// one indivisible step and two callers cannot both find the slot empty — the same argument
    /// `SonnyBackendClient.refreshedSnapshot` makes for its own single-flight guard.
    private func startRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // Failure is deliberately swallowed: this is the *background* refresh, its whole point is
            // that the cached claim keeps working when it cannot run, and a caller asking whether it
            // is entitled is not asking about the network. `refreshNow()` is the form that reports.
            _ = try? await self?.refreshNow()
            await self?.clearRefreshTask()
        }
    }

    private func clearRefreshTask() {
        refreshTask = nil
    }
}

/// §5.3's response envelope. `expires_at` and `refresh_after` are carried by the signed payload and
/// by this; the payload is what is judged, so only `entitlement` is read.
private struct WireEntitlementResponse: Decodable {
    let entitlement: String
}
