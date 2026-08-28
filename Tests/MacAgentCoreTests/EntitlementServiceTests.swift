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

    /// What instant the stub's `Date` header reports, in a form a `@Sendable` handler may read.
    final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(instant: Date) { value = instant }

        var instant: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ instant: Date) {
            lock.lock()
            value = instant
            lock.unlock()
        }
    }

    /// Whether the stub answers at all, in a form a `@Sendable` handler may read.
    final class Reachability: @unchecked Sendable {
        private let lock = NSLock()
        private var reachable = true

        var isReachable: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reachable
        }

        func goOffline() {
            lock.lock()
            reachable = false
            lock.unlock()
        }
    }

    /// A wall clock and a monotonic clock a test can move **separately**, which is the whole of what
    /// makes SONNY-135's clock defence testable (PR #152's review, F1).
    ///
    /// A user setting their Mac's clock back moves the first and not the second. A test that moved
    /// one closure could not express that, and the two tests that used to hold this property did not
    /// try — they seeded a `(claim, highWater)` pair directly, which is a state the production
    /// writer cannot produce, and passed against a tree where the mark could refuse nothing.
    final class MovableClocks: @unchecked Sendable {
        private let lock = NSLock()
        private var wall: Date
        private var monotonicOffset: Duration = .zero
        private let monotonicBase = ContinuousClock.now

        init(wall: Date) { self.wall = wall }

        var now: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return wall
            }
        }

        var monotonic: @Sendable () -> ContinuousClock.Instant {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return monotonicBase.advanced(by: monotonicOffset)
            }
        }

        /// Real time passing: both clocks move, which is what an honest hour looks like.
        func advance(by seconds: TimeInterval) {
            lock.lock()
            wall = wall.addingTimeInterval(seconds)
            monotonicOffset += .seconds(seconds)
            lock.unlock()
        }

        /// The attack: the wall clock is set, and monotonic time is untouched because nothing a user
        /// can do moves it.
        func setWallClock(to instant: Date) {
            lock.lock()
            wall = instant
            lock.unlock()
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

    // MARK: - Recovering, rather than refusing forever

    @Test
    @MainActor
    func aMacWithNothingCachedConnectsRatherThanTellingTheUserToConnect() async throws {
        // **F2's first state.** A Mac that has just signed in has no claim, so the answer is
        // `.noClaim` — *"Connect once so Sonny can check your plan."* Before this fix nothing ever
        // connected, because `decision(for:)` returned above the refresh: the sentence described an
        // action the code did not take.
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
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": compact])
            )
        }
        let store = MemoryStore()
        let service = EntitlementService(client: fixture.client, store: store, keys: signer.keys)

        #expect(await service.decision(for: Self.capability) == .refused(.noClaim))
        await service.awaitPendingRefresh()

        #expect(seen.all.map(\.path) == ["/v1/account/entitlements"])
        // And the next answer is the right one, which is the whole point of connecting.
        #expect(await service.decision(for: Self.capability) == .entitled)
    }

    @Test
    @MainActor
    func aClaimThisBuildCannotReadIsRefusedAndReplaced() async throws {
        // F2's second state. Unreadable bytes are useless, so the recovery is to fetch a claim that
        // is not — which needs a request, which is what was missing.
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let good = signer.claim(subject: "test-user")
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": good])
            )
        }
        let store = MemoryStore(StoredEntitlement(
            compactClaim: Signer(keyID: "someone-elses").claim(subject: "test-user"),
            observedServerTime: Self.issuedAt
        ))
        let service = EntitlementService(client: fixture.client, store: store, keys: signer.keys)

        #expect(await service.decision(for: Self.capability) == .refused(.unreadableClaim))
        await service.awaitPendingRefresh()
        #expect(seen.all.count == 1)
        #expect(await service.decision(for: Self.capability) == .entitled)
    }

    @Test
    @MainActor
    func aSecondUserOnTheSameMacGetsTheirOwnClaimRatherThanBeingToldToSignInAgain() async throws {
        // **F2's third state, and the one whose copy was actively wrong.** The second person to sign
        // in on a Mac met the first one's claim, was refused every gated capability, and was told
        // "Sign in again" — which is what they had just done. The stale claim is cleared, a refresh
        // is started, and the sentence says what is actually happening.
        let signer = Signer()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt.addingTimeInterval(60) })
        defer { fixture.unregister() }
        let mine = signer.claim(subject: "test-user")
        let seen = RecordedBackendRequests()
        fixture.register { request in
            seen.append(request)
            return .reply(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": mine])
            )
        }
        let store = MemoryStore(StoredEntitlement(
            compactClaim: signer.claim(subject: "the-previous-user"),
            observedServerTime: Self.issuedAt
        ))
        let service = EntitlementService(client: fixture.client, store: store, keys: signer.keys)

        #expect(await service.decision(for: Self.capability) == .refused(.claimIsForAnotherSession))
        // The stale bytes are gone rather than merely unusable — `discardLocally`'s caller.
        #expect(store.current == nil || store.current?.compactClaim == mine)
        await service.awaitPendingRefresh()
        #expect(seen.all.count == 1)
        #expect(await service.decision(for: Self.capability) == .entitled)
        // And the sentence is not the one they had just acted on.
        #expect(EntitlementCopy.message(for: .claimIsForAnotherSession)
            != EntitlementCopy.message(for: .notSignedIn))
        #expect(!EntitlementCopy.message(for: .claimIsForAnotherSession).contains("Sign in"))
    }

    @Test
    @MainActor
    func aMacWithNoSessionStartsNoRefresh() async throws {
        // The boundary of the three above: with no session there is no token to fetch with, so a
        // refresh would be a request guaranteed to fail. Nothing is started.
        let seen = RecordedBackendRequests()
        let fixture = SignedInBackendFixture(now: { Self.issuedAt })
        defer { fixture.unregister() }
        fixture.register { request in
            seen.append(request)
            return .failure(URLError(.notConnectedToInternet))
        }
        let service = EntitlementService(
            client: makeHermeticBackendClient(),
            store: MemoryStore(),
            keys: Signer().keys
        )
        #expect(await service.decision(for: Self.capability) == .refused(.notSignedIn))
        await service.awaitPendingRefresh()
        #expect(seen.all.isEmpty)
    }

    // MARK: - The clock the user controls

    @Test
    @MainActor
    func aClockRolledBackOfflineCannotReEnterALapsedWindow() async throws {
        // **The F1 repro, driven entirely through the production write path.** No `(claim, mark)`
        // pair is seeded: the claim and the mark both arrive by `refreshNow()` fetching a real
        // response, exactly as they do in the app. On the tree this was found at, the last assertion
        // answered `.entitled`.
        let signer = Signer()
        let clocks = MovableClocks(wall: Self.issuedAt)
        let fixture = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        defer { fixture.unregister() }
        let compact = signer.claim(subject: "test-user", issuedAt: Self.issuedAt)
        let network = Reachability()
        fixture.register { _ in
            guard network.isReachable else { return .failure(URLError(.notConnectedToInternet)) }
            return .reply(
                statusCode: 200,
                // The `Date` header is what the whole defence is built on, so the stub sends one.
                headers: [
                    "Content-Type": "application/json",
                    "Date": SonnyHTTPDate.formatter.string(from: Self.issuedAt)
                ],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": compact])
            )
        }
        let store = MemoryStore()
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )

        _ = try await service.refreshNow()
        #expect(await service.decision(for: Self.capability) == .entitled)

        // A hundred hours of real time pass with the Mac offline — past the claim's 24-hour life and
        // past its 72-hour grace.
        network.goOffline()
        clocks.advance(by: 100 * 60 * 60)
        #expect(await service.decision(for: Self.capability) == .refused(.lapsed))

        // The owner sets the Mac's clock back to an hour after the claim was issued. Monotonic time
        // does not move, because nothing a user can do moves it.
        clocks.setWallClock(to: Self.issuedAt.addingTimeInterval(3600))
        #expect(await service.decision(for: Self.capability) == .refused(.lapsed))
    }

    @Test
    @MainActor
    func aClaimStoredWithNoMarkIsStillJudgedAgainstAnObservedServerTime() async throws {
        // **The case the observation answers and the persisted mark cannot** (found by mutant S6
        // surviving twice at `0fefe0d` and `ede5009`: with a mark present the mark's own monotonic
        // anchor carries everything the observation would, so deleting the observation changed
        // nothing — and the first test written for it did not isolate the path either, because a
        // fresh response also corrects §3.5's offset and `serverNow()` then carries the same truth).
        //
        // **`observedServerTime: nil` is a legacy state, not an impossible one**, which is what makes
        // seeding it legitimate where the pair PR #152's F1 criticised was not: `StoredEntitlement`
        // has always allowed it, an entitlement written by a build before this fix has it, and that
        // is exactly the Mac an upgrade lands on. With no mark to anchor, the observation is the only
        // thing standing between a rolled-back clock and a lapsed claim.
        let signer = Signer()
        let clocks = MovableClocks(wall: Self.issuedAt)
        let fixture = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        defer { fixture.unregister() }
        let serverSays = Reported(instant: Self.issuedAt)
        fixture.register { _ in
            .reply(
                statusCode: 500,
                headers: ["Date": SonnyHTTPDate.formatter.string(from: serverSays.instant)],
                body: Data()
            )
        }
        let store = MemoryStore(StoredEntitlement(
            compactClaim: signer.claim(subject: "test-user", issuedAt: Self.issuedAt),
            observedServerTime: nil
        ))
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )

        // A hundred honest hours, then a response that confirms them. `refreshNow` fails, so no
        // claim is adopted and no mark is written — a `Date` header is read before a status is.
        clocks.advance(by: 100 * 60 * 60)
        serverSays.set(Self.issuedAt.addingTimeInterval(100 * 60 * 60))
        _ = try? await service.refreshNow()

        // Now the owner sets the Mac back. §3.5's offset moves with them; the observation does not.
        clocks.setWallClock(to: Self.issuedAt.addingTimeInterval(3600))
        #expect(await service.decision(for: Self.capability) == .refused(.lapsed))
    }

    @Test
    @MainActor
    func aServerSayingMoreTimeHasPassedIsBelievedOverThisMacsOwnClock() async throws {
        // **The observation path, held independently of the persisted mark** (found by mutant S6
        // surviving at `0fefe0d`: deleting the observation from `effectiveNow` left the suite green,
        // because every other clock test reaches the answer through the mark's own anchor).
        //
        // The case only the observation answers: this Mac's clock has barely moved — a minute — and
        // the *server* says a hundred hours have passed. That is a Mac whose clock is simply wrong,
        // not one whose owner rolled it back, and the claim really has lapsed. The failing response
        // is deliberate: a `Date` header is recorded before the status is looked at, so an
        // observation arrives without a claim being adopted, which is the only way to move the clock
        // without also handing the Mac a fresh entitlement.
        let signer = Signer()
        let clocks = MovableClocks(wall: Self.issuedAt)
        let fixture = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        defer { fixture.unregister() }
        let compact = signer.claim(subject: "test-user", issuedAt: Self.issuedAt)
        let serverSays = Reported(instant: Self.issuedAt)
        let succeed = Reachability()
        fixture.register { _ in
            let headers = [
                "Content-Type": "application/json",
                "Date": SonnyHTTPDate.formatter.string(from: serverSays.instant)
            ]
            guard succeed.isReachable else { return .reply(statusCode: 500, headers: headers, body: Data()) }
            return .reply(
                statusCode: 200,
                headers: headers,
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": compact])
            )
        }
        let store = MemoryStore()
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )
        _ = try await service.refreshNow()
        #expect(await service.decision(for: Self.capability) == .entitled)

        // A minute of local time, and a server that reports a hundred hours.
        clocks.advance(by: 60)
        succeed.goOffline()
        serverSays.set(Self.issuedAt.addingTimeInterval(100 * 60 * 60))
        _ = try? await service.refreshNow()

        #expect(await service.decision(for: Self.capability) == .refused(.lapsed))
    }

    @Test
    @MainActor
    func theMarkSurvivesARelaunchSoTheRollbackIsStillRefused() async throws {
        // The half the in-process test cannot show: a new `EntitlementService`, with no anchor and a
        // client that has seen no response this run, judging from the persisted mark alone. This is
        // what makes the bound "the last time the app ran with a correct clock" rather than "the
        // last time this process ran".
        let signer = Signer()
        let clocks = MovableClocks(wall: Self.issuedAt)
        let first = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        let compact = signer.claim(subject: "test-user", issuedAt: Self.issuedAt)
        first.register { _ in
            .reply(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Date": SonnyHTTPDate.formatter.string(from: Self.issuedAt)
                ],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": compact])
            )
        }
        let store = MemoryStore()
        let live = EntitlementService(
            client: first.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )
        _ = try await live.refreshNow()
        clocks.advance(by: 100 * 60 * 60)
        #expect(await live.decision(for: Self.capability) == .refused(.lapsed))
        first.unregister()

        // The mark was written back during that decision, which is what the next launch inherits.
        let persisted = try #require(store.current?.observedServerTime)
        #expect(persisted.timeIntervalSince(Self.issuedAt) > 99 * 60 * 60)

        // Relaunch: a fresh service, a fresh client that has never seen a response, and an owner who
        // has already set the clock back.
        clocks.setWallClock(to: Self.issuedAt.addingTimeInterval(3600))
        let second = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        defer { second.unregister() }
        second.register { _ in .failure(URLError(.notConnectedToInternet)) }
        let relaunched = EntitlementService(
            client: second.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )

        #expect(await relaunched.decision(for: Self.capability) == .refused(.lapsed))
    }

    @Test
    @MainActor
    func anHonestlyForwardClockIsNotWrittenIntoTheMark() async throws {
        // The other direction, and it is why `serverNow()` is deliberately excluded from what gets
        // persisted: a clock pushed a year forward refuses (fail-closed, correct) but must not be
        // *written down*, or fixing the clock would leave a Mac locked out for a year.
        let signer = Signer()
        let clocks = MovableClocks(wall: Self.issuedAt)
        let fixture = SignedInBackendFixture(now: clocks.now, monotonicNow: clocks.monotonic)
        defer { fixture.unregister() }
        let compact = signer.claim(subject: "test-user", issuedAt: Self.issuedAt)
        fixture.register { _ in
            .reply(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Date": SonnyHTTPDate.formatter.string(from: Self.issuedAt)
                ],
                body: try! JSONSerialization.data(withJSONObject: ["entitlement": compact])
            )
        }
        let store = MemoryStore()
        let service = EntitlementService(
            client: fixture.client,
            store: store,
            keys: signer.keys,
            monotonicNow: clocks.monotonic
        )
        _ = try await service.refreshNow()

        // A year forward on the wall clock alone. It refuses — and the mark stays where real time
        // put it.
        clocks.setWallClock(to: Self.issuedAt.addingTimeInterval(365 * 24 * 60 * 60))
        #expect(await service.decision(for: Self.capability) == .refused(.lapsed))
        let mark = try #require(store.current?.observedServerTime)
        #expect(mark.timeIntervalSince(Self.issuedAt) < 60)

        // And putting the clock right brings the claim back, which a persisted year would not have.
        clocks.setWallClock(to: Self.issuedAt.addingTimeInterval(60))
        #expect(await service.decision(for: Self.capability) == .entitled)
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
