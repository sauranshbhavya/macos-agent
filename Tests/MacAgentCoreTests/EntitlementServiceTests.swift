import CryptoKit
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The check the rest of the app asks, driven end to end — and above all **driven with no network at
/// all** (SONNY-135).
///
/// **The headline assertion is `aGatedCapabilityIsAnsweredOfflineFromTheCachedClaim`.** It hands the
/// service a client whose transport fails every request the way a dead network does, and asks for a
/// decision. The answer comes back, correct, from a signed claim on disk. That is contract §5.3's
/// "a signed claim the client can verify with no network call", asserted rather than described.
///
/// **Its pair is `aFreeLocalCapabilityNeverConsultsAnyOfThis`, in
/// `EntitlementFreePathTests`.** Together they are the two directions of fail-closed, which the
/// ticket names as the requirement most likely to be inverted by accident.
@Suite
struct EntitlementServiceTests {
    static let capability = EntitlementCapability("test.capability")
    static let issuedAt = SonnyISO8601.parse("2026-08-28T09:00:00Z")!

    /// A signing key generated per test, and the key set that verifies it.
    ///
    /// **Generated rather than committed**, the same call `server/test/support/entitlement.ts` makes
    /// and for the same reason: this is the private half of the thing that grants capabilities, and a
    /// literal one in the repository is a working minting key. The one claim written down anywhere is
    /// `EntitlementClaimTests`' golden vector, which is public, signed and expired.
    struct Signer {
        let keyID: String
        private let privateKey: Curve25519.Signing.PrivateKey

        init(keyID: String = "test-key-1") {
            self.keyID = keyID
            privateKey = Curve25519.Signing.PrivateKey()
        }

        var keys: EntitlementKeySet {
            EntitlementKeySet.parsing([
                "\(keyID):\(Base64URL.encode(privateKey.publicKey.rawRepresentation))"
            ])
        }

        func claim(
            subject: String = "test-user",
            capabilities: [String] = ["test.capability"],
            issuedAt: Date = EntitlementServiceTests.issuedAt,
            lifetime: TimeInterval = 24 * 60 * 60,
            algorithm: String = "EdDSA"
        ) -> String {
            let header: [String: Any] = ["alg": algorithm, "typ": "JWT", "kid": keyID]
            let payload: [String: Any] = [
                "v": 1,
                "sub": subject,
                "plan": "test-plan",
                "capabilities": capabilities,
                "issued_at": SonnyISO8601Formatter.text(issuedAt),
                "expires_at": SonnyISO8601Formatter.text(issuedAt.addingTimeInterval(lifetime)),
                "grace_seconds": 72 * 60 * 60,
                "skew_tolerance_seconds": 300
            ]
            let encodedHeader = Base64URL.encode(try! JSONSerialization.data(withJSONObject: header))
            let encodedPayload = Base64URL.encode(try! JSONSerialization.data(withJSONObject: payload))
            let signature = try! privateKey.signature(
                for: Data("\(encodedHeader).\(encodedPayload)".utf8)
            )
            return "\(encodedHeader).\(encodedPayload).\(Base64URL.encode(signature))"
        }
    }

    /// A `EntitlementStoring` in memory, with the two failures a real one has.
    final class MemoryStore: EntitlementStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: StoredEntitlement?
        private var loadFailure: Error?

        init(_ initial: StoredEntitlement? = nil) { stored = initial }

        func load() throws -> StoredEntitlement? {
            lock.lock()
            defer { lock.unlock() }
            if let loadFailure { throw loadFailure }
            return stored
        }

        func save(_ entitlement: StoredEntitlement) throws {
            lock.lock()
            stored = entitlement
            lock.unlock()
        }

        func clear() throws {
            lock.lock()
            stored = nil
            lock.unlock()
        }

        var current: StoredEntitlement? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func failLoads() {
            lock.lock()
            loadFailure = EntitlementStoreError.undecodable("planted")
            lock.unlock()
        }
    }

    // MARK: - The offline direction

    @Test
    @MainActor
    func aGatedCapabilityIsAnsweredOfflineFromTheCachedClaim() async throws {
        // **The requirement, asserted.** Every request this client makes fails the way a dead network
        // does; the decision comes back from the claim on disk.
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return .failure(URLError(.notConnectedToInternet))
        }
        let store = MemoryStore(StoredEntitlement(
            compactClaim: signer.claim(subject: "test-user"),
            observedServerTime: Self.issuedAt
        ))
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys
        )

        let decision = await service.decision(for: Self.capability)

        #expect(decision == .entitled)
        // And the answer did not depend on a request having been made: nothing was sent.
        #expect(seen.all.isEmpty)
    }

    @Test
    @MainActor
    func aGatedCapabilityIsRefusedOfflineWithNothingCached() async throws {
        // The same shape, the other answer, and the one that matters more: with no claim and no
        // network there is no way to establish entitlement, so the answer is no.
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let service = EntitlementService(
            client: fixture.client,
            store: MemoryStore(),
            keys: Signer().keys
        )

        #expect(await service.decision(for: Self.capability) == .refused(.noClaim))
    }

    // MARK: - Every failure is a refusal

    @Test
    @MainActor
    func aMacWithNoSessionIsRefusedBeforeAnythingElseIsAsked() async throws {
        let store = MemoryStore(StoredEntitlement(
            compactClaim: Signer().claim(),
            observedServerTime: Self.issuedAt
        ))
        let service = EntitlementService(
            client: makeHermeticBackendClient(),
            store: store,
            keys: Signer().keys
        )
        #expect(await service.decision(for: Self.capability) == .refused(.notSignedIn))
    }

    @Test
    @MainActor
    func aClaimSignedByAKeyThisBuildDoesNotHoldIsRefused() async throws {
        // A cryptographically perfect claim from somewhere else. The forged-token direction, through
        // the service rather than through the verifier.
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let service = EntitlementService(
            client: fixture.client,
            store: MemoryStore(StoredEntitlement(
                compactClaim: Signer(keyID: "someone-elses").claim(subject: "test-user"),
                observedServerTime: Self.issuedAt
            )),
            keys: Signer().keys
        )
        #expect(await service.decision(for: Self.capability) == .refused(.unreadableClaim))
    }

    @Test
    @MainActor
    func aStoreThatCannotBeReadIsARefusalAndNotAPass() async throws {
        // A check that could not be completed is not a check that passed.
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let store = MemoryStore()
        store.failLoads()
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: Signer().keys
        )
        #expect(await service.decision(for: Self.capability) == .refused(.unreadableClaim))
    }

    @Test
    @MainActor
    func aClaimForAnotherSessionIsRefusedAfterAUserChange() async throws {
        // Signed out, signed in as somebody else, and the old claim is still on disk. Without the
        // binding it would grant the new user the old one's capabilities until it lapsed.
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let service = EntitlementService(
            client: fixture.client,
            store: MemoryStore(StoredEntitlement(
                compactClaim: signer.claim(subject: "somebody-else"),
                observedServerTime: Self.issuedAt
            )),
            keys: signer.keys
        )
        #expect(await service.decision(for: Self.capability) == .refused(.claimIsForAnotherSession))
    }

    // MARK: - Fetching and caching

    @Test
    @MainActor
    func refreshFetchesVerifiesAndCachesAClaim() async throws {
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let compact = signer.claim(subject: "test-user")
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "entitlement": compact,
                    "expires_at": "2026-08-29T09:00:00Z",
                    "refresh_after": "2026-08-28T17:00:00Z"
                ])
            )
        }
        let store = MemoryStore()
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys
        )

        let claim = try await service.refreshNow()

        #expect(seen.all.map(\.path) == ["/v1/account/entitlements"])
        // A `GET`, carrying the session's bearer token and no idempotency key — there is nothing for
        // one to be about on a request that changes nothing.
        #expect(try seen.only.method == "GET")
        #expect(try seen.only.idempotencyKey == nil)
        #expect(try seen.only.authorization?.hasPrefix("Bearer ") == true)
        #expect(claim.subject == "test-user")
        #expect(claim.capabilities == ["test.capability"])
        #expect(store.current?.compactClaim == compact)
        // And the answer is now available offline.
        #expect(await service.decision(for: Self.capability) == .entitled)
    }

    @Test
    @MainActor
    func aResponseThisBuildCannotVerifyNeverReplacesTheClaimOnDisk() async throws {
        // The claim already cached may still be inside its grace window. A response that does not
        // verify must not take its place — losing a working claim to a bad answer would be a refusal
        // caused by the refresh that was meant to prevent one.
        let signer = Signer()
        let cached = signer.claim(subject: "test-user")
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: [
                    "entitlement": Signer(keyID: "someone-elses").claim(subject: "test-user")
                ])
            )
        }
        let store = MemoryStore(StoredEntitlement(compactClaim: cached, observedServerTime: Self.issuedAt))
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys
        )

        await #expect(throws: SonnyBackendError.self) { try await service.refreshNow() }
        #expect(store.current?.compactClaim == cached)
    }

    @Test
    @MainActor
    func anOlderClaimReplayedAtThisMacDoesNotReplaceTheCurrentOne() async throws {
        // **The replay this side can close.** An old, correctly signed response is a real claim from a
        // moment when the account may have had more than it has now, so accepting it would undo a
        // revocation. A claim is only taken when it is no older than the one already held.
        let signer = Signer()
        let current = signer.claim(
            subject: "test-user",
            capabilities: [],
            issuedAt: Self.issuedAt
        )
        let older = signer.claim(
            subject: "test-user",
            capabilities: ["test.capability"],
            issuedAt: Self.issuedAt.addingTimeInterval(-3600)
        )
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        fixture.register { _ in
            .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": older])
            )
        }
        let store = MemoryStore(StoredEntitlement(compactClaim: current, observedServerTime: Self.issuedAt))
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys
        )

        _ = try await service.refreshNow()

        #expect(store.current?.compactClaim == current)
        // Which is the point: the revoked state survives the replay.
        #expect(await service.decision(for: Self.capability) == .refused(.notEntitled))
    }

    @Test
    @MainActor
    func theHighWaterMarkOnlyEverMovesForward() async throws {
        // A response received while the Mac's clock is set back must not lower the mark, or the
        // defence it provides could be turned off by the same clock it defends against.
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let ahead = Self.issuedAt.addingTimeInterval(3600)
        let store = MemoryStore(StoredEntitlement(
            compactClaim: signer.claim(subject: "test-user"),
            observedServerTime: ahead
        ))
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys
        )

        let claim = signer.claim(subject: "test-user", issuedAt: Self.issuedAt)
        guard case .success(let decoded) = EntitlementVerifier.verify(claim, against: signer.keys) else {
            Issue.record("the fixture's own claim did not verify")
            return
        }
        try await service.adopt(decoded, compact: claim, observedAt: Self.issuedAt)

        #expect(store.current?.observedServerTime == ahead)
    }

    @Test
    @MainActor
    func aStaleClaimStartsARefreshWithoutTheAnswerWaitingForIt() async throws {
        // "Refreshed whenever the app is online", without the decision ever blocking on a network
        // call: the answer below is the cached claim's, and the refresh changes the *next* one.
        let signer = Signer()
        // The client's clock is past a third of the cached claim's life, which is when §5.3 says a
        // client should fetch a new one. **The client's** rather than the service's: the service has
        // no clock of its own, because §3.5 makes server time the one source and `serverNow()` is it.
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(9 * 60 * 60) })
        defer { fixture.unregister() }
        let fresher = signer.claim(
            subject: "test-user",
            capabilities: ["test.capability", "another.capability"],
            issuedAt: Self.issuedAt.addingTimeInterval(9 * 60 * 60)
        )
        fixture.register { _ in
            .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": fresher])
            )
        }
        let store = MemoryStore(StoredEntitlement(
            compactClaim: signer.claim(subject: "test-user"),
            observedServerTime: Self.issuedAt
        ))
        let service = EntitlementService(client: fixture.client, store: store, keys: signer.keys)

        #expect(await service.decision(for: Self.capability) == .entitled)
        await service.awaitPendingRefresh()
        #expect(store.current?.compactClaim == fresher)
    }

    @Test
    @MainActor
    func aFreshClaimStartsNoRefreshAtAll() async throws {
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return .failure(URLError(.notConnectedToInternet))
        }
        let service = EntitlementService(
            client: fixture.client,
            store: MemoryStore(StoredEntitlement(
                compactClaim: signer.claim(subject: "test-user"),
                observedServerTime: Self.issuedAt
            )),
            keys: signer.keys
        )

        #expect(await service.decision(for: Self.capability) == .entitled)
        await service.awaitPendingRefresh()
        #expect(seen.all.isEmpty)
    }
}

/// The ISO-8601 text the gateway writes, so a fixture's claim is byte-shaped like a real one.
enum SonnyISO8601Formatter {
    static func text(_ instant: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: instant)
    }
}
