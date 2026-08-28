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

    private var refreshTask: Task<Void, Never>?

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
        keys: EntitlementKeySet
    ) {
        self.client = client
        self.store = store
        self.keys = keys
    }

    /// May this Mac do the thing this capability names, right now, with no network?
    ///
    /// **Every failure here is a refusal**, including the ones that are this build's own fault — an
    /// unreadable store, a claim signed by a key this build does not hold. A check that could not be
    /// completed is not a check that passed.
    public func decision(for capability: EntitlementCapability) async -> EntitlementDecision {
        guard let session = try? await client.restoredIdentity() else {
            return .refused(.notSignedIn)
        }
        let stored: StoredEntitlement?
        do {
            stored = try store.load()
        } catch {
            return .refused(.unreadableClaim)
        }
        guard let stored else { return .refused(.noClaim) }
        guard case .success(let claim) = EntitlementVerifier.verify(stored.compactClaim, against: keys) else {
            return .refused(.unreadableClaim)
        }

        let instant = EntitlementJudgement.effectiveNow(
            serverNow: await client.serverNow(),
            highWaterMark: stored.observedServerTime
        )
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
        try adopt(claim, compact: envelope.entitlement, observedAt: await client.serverNow())
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
    func adopt(_ claim: EntitlementClaim, compact: String, observedAt: Date) throws {
        let existing = try? store.load()
        if let existing,
           case .success(let current) = EntitlementVerifier.verify(existing.compactClaim, against: keys),
           current.issuedAt > claim.issuedAt {
            return
        }
        let highWater = [existing?.observedServerTime, observedAt].compactMap { $0 }.max()
        try store.save(StoredEntitlement(compactClaim: compact, observedServerTime: highWater))
    }

    /// Forget the cached claim on this Mac.
    ///
    /// **Not called by sign-out today, and the session check in `decision(for:)` is what covers that
    /// instead.** A claim is bound to the session that fetched it (`sub`), and a signed-out Mac has
    /// no session at all — so a stale claim after a sign-out is refused twice over: once for having
    /// no session, and again for naming one that is not the one held. This exists for a caller that
    /// wants the bytes gone rather than merely unusable.
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
