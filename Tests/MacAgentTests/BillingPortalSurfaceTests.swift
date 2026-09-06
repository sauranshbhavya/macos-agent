import CryptoKit
import Foundation
import MacAgentCore
import MacAgentTestSupport
import Testing
@testable import MacAgent

/// The Account section's way to the provider's hosted portal (SONNY-216).
///
/// **What these tests are mostly about is the press that must not happen.** A user who signed in and
/// never subscribed has nothing to manage, and the gateway refuses them with
/// `409 entitlement.no_subscription` — but a control that only fails when pressed is a broken
/// control, so the requirement is that it is not offered (founder direction, 2026-08-31). That is
/// held here and in `SubscriptionReadingTests.theAbsenceOfAPlanIsNotASubscription`, which is the
/// arm that decides it.
@MainActor
@Suite struct BillingPortalSurfaceTests {
    /// A model over a stub transport, with somewhere to record what it would have opened.
    struct Surface {
        let model: SonnyAccountModel
        let fixture: SignedInBackendFixture
        let opened: Opened
    }

    /// `@MainActor` closures cannot write a local, and the model's opener is one, so the recording
    /// goes through a reference type the closure captures.
    @MainActor final class Opened {
        private(set) var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
    }

    static func surface() -> Surface {
        let fixture = SignedInBackendFixture()
        let model = SonnyAccountModel(
            client: fixture.client,
            entitlementStore: KeychainEntitlementStore(secretStore: InMemoryKeychainSecretStore()),
            entitlementKeys: SonnyEntitlementKeys.shipped
        )
        let opened = Opened()
        model.openPortalURL = { [opened] url in opened.record(url) }
        return Surface(model: model, fixture: fixture, opened: opened)
    }

    /// Mints the one thing this suite could not previously produce: a claim that actually verifies.
    ///
    /// **Its absence was PR #183's F3, and it was the hole that hid two other findings.** Every
    /// fixture passed `SonnyEntitlementKeys.shipped`, which is empty in every build, so no claim
    /// could verify and no test anywhere produced a non-`nil` subscription — a mutant replacing
    /// `currentSubscription()`'s answer with `nil` passed all 2579 tests. The ticket's own
    /// Verification line asks for "a test that the state renders from the entitlement", and this is
    /// the piece that was missing from it.
    struct Signer {
        let keyID = "portal-test-key"
        private let privateKey = Curve25519.Signing.PrivateKey()

        var keys: EntitlementKeySet {
            EntitlementKeySet.parsing(["\(keyID):\(BillingPortalSurfaceTests.base64url(privateKey.publicKey.rawRepresentation))"])
        }

        /// `subject` defaults to the user `SignedInBackendFixture` puts in the Keychain, because a
        /// claim about anyone else is refused — the property F2 is about, kept out of the way here.
        func claim(
            subject: String = "test-user",
            plan: String = "paid",
            capabilities: [String] = ["screen_control"],
            issuedAt: Date = Date(),
            lifetime: TimeInterval = 24 * 60 * 60
        ) -> String {
            let header: [String: Any] = ["alg": "EdDSA", "typ": "JWT", "kid": keyID]
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime]
            let payload: [String: Any] = [
                "v": 1,
                "sub": subject,
                "plan": plan,
                "capabilities": capabilities,
                "issued_at": format.string(from: issuedAt),
                "expires_at": format.string(from: issuedAt.addingTimeInterval(lifetime)),
                "grace_seconds": 72 * 60 * 60,
                "skew_tolerance_seconds": 300
            ]
            let head = BillingPortalSurfaceTests.base64url(try! JSONSerialization.data(withJSONObject: header))
            let body = BillingPortalSurfaceTests.base64url(try! JSONSerialization.data(withJSONObject: payload))
            let signature = try! privateKey.signature(for: Data("\(head).\(body)".utf8))
            return "\(head).\(body).\(BillingPortalSurfaceTests.base64url(signature))"
        }
    }

    /// Written out rather than reached for: `Base64URL` is internal to `MacAgentCore`, and
    /// `@testable`-importing a whole module for four lines of encoding would couple this suite to
    /// that module's internals for no gain.
    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A model whose entitlement store and key set are a matched pair, over the stub transport.
    static func subscribedSurface(
        storing compactClaim: String?,
        signer: Signer,
        serving servedClaim: String? = nil
    ) -> Surface {
        let fixture = SignedInBackendFixture()
        let keychain = InMemoryKeychainSecretStore()
        let store = KeychainEntitlementStore(secretStore: keychain)
        if let compactClaim {
            try? store.save(StoredEntitlement(compactClaim: compactClaim, observedServerTime: nil))
        }
        if let servedClaim {
            fixture.register { request in
                guard request.url?.path == "/v1/account/entitlements" else {
                    return .reply(statusCode: 404, headers: [:], body: Data())
                }
                let payload = "{\"entitlement\":\"" + servedClaim + "\"}"
                return .reply(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: Data(payload.utf8)
                )
            }
        }
        let model = SonnyAccountModel(
            client: fixture.client,
            entitlementStore: store,
            entitlementKeys: signer.keys
        )
        let opened = Opened()
        model.openPortalURL = { [opened] url in opened.record(url) }
        return Surface(model: model, fixture: fixture, opened: opened)
    }

    nonisolated static func portalReply(_ body: String, status: Int = 200) -> BackendStubURLProtocol.Outcome {
        .reply(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    @Test func pressingManageOpensTheLinkTheGatewayMinted() async {
        let surface = Self.surface()
        surface.fixture.register { request in
            // The path is asserted rather than assumed: a model that called the checkout route
            // instead would still open a URL and still pass a test that only read the result.
            #expect(request.url?.path == "/v1/billing/portal")
            #expect(request.httpMethod == "POST")
            // SONNY-403: `expires_at` is a key `WireBillingPortal` does not declare, and that
            // decoder's own doc says why it never will — the link is fetched per press and
            // opened at once, so nothing here caches on it. Contract shape, not a bound.
            return Self.portalReply(#"{"portal_url":"https://portal.example.test/s/abc","expires_at":"2026-08-31T13:00:00Z"}"#)
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.map(\.absoluteString) == ["https://portal.example.test/s/abc"])
        #expect(surface.model.failure == nil)
    }

    @Test func aLinkThatIsNotHTTPSIsNotOpened() async {
        // **"The server would never" is the assumption every deserialization bug is made of.** This
        // URL arrives over TLS from Sonny's own gateway, so it is not screen content and not model
        // output — and it is still checked, because `NSWorkspace.open` on a `file:` URL is a
        // different kind of action entirely and the check costs one line.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(#"{"portal_url":"file:///etc/passwd"}"#)
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.portalFailure != nil)
        // Sign-in's channel is untouched, which is F4's property rather than an incidental one.
        #expect(surface.model.failure == nil)
    }

    @Test func anAccountWithNothingToManageOpensNothing() async {
        // The `409 entitlement.no_subscription` path. It is the *second* defence — the row is not
        // rendered for such an account at all — and it still must not open anything.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"entitlement.no_subscription","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 409
            )
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.portalFailure != nil)
        #expect(surface.model.failure == nil)
    }

    @Test func aBodyWithNoURLOpensNothing() async {
        let surface = Self.surface()
        // The one field the decoder reads is absent and the one it ignores is present, which is
        // what makes this a body with no URL rather than an empty one (SONNY-403).
        surface.fixture.register { _ in Self.portalReply(#"{"expires_at":"2026-08-31T13:00:00Z"}"#) }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.portalFailure != nil)
        #expect(surface.model.failure == nil)
    }

    @Test func aMacThatCanProveNothingShowsNoSubscription() async {
        // The shipped key set is empty in every release build, so no claim verifies and this is what
        // every user sees until a gateway exists to have signed one. It is `SonnyEntitlementKeys`'
        // own recorded state rather than a gap this ticket introduces — and it is the same `nil`
        // that hides the Manage control, which is why it is asserted here rather than assumed.
        let surface = Self.surface()

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == nil)
    }

    @Test func aMacWithNoNetworkStillRendersAndReportsNothing() async {
        // §16.3's guarantee applied to a screen. A Mac with nothing cached and no network ends with
        // no row and — the half that matters — **no warning**: a Mac that has never reached a
        // gateway is the ordinary state, not news, and a failure here would put a warning under a
        // sign-in the user has just completed.
        //
        // (This was named `theSubscriptionReadAsksTheNetworkForNothing`, and after F1 that name was
        // no longer true of this function: `refreshSubscription()` now waits for a pending refresh
        // when the first read is empty. The property it claimed still holds and is asserted where it
        // actually lives — `currentSubscription()` itself — in
        // `theFirstReadNeverWaitsOnTheNetwork` below.)
        let surface = Self.surface()
        surface.fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == nil)
        #expect(surface.model.failure == nil)
        #expect(surface.model.portalFailure == nil)
    }

    // MARK: - The entitlement actually reaching the surface (PR #183, F1/F2/F3)

    @Test func theStateRendersFromTheEntitlement() async {
        // **The ticket's own named verification item**, and until PR #183's F3 nothing in the
        // repository met it: every fixture used the empty shipped key set, so no claim could verify
        // and no test ever produced a non-`nil` subscription. A mutant returning `nil` from
        // `currentSubscription()` passed all 2579 tests.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
        // Through the copy, because the line is what the user actually meets.
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Active")
    }

    @Test func aRevokedSubscriptionRendersAsEndedFromTheEntitlement() async {
        // The other half of the same path: a claim that verifies and grants nothing. This is the
        // shape the gateway mints on a cancellation, so it is the one a real user meets.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(capabilities: []), signer: signer)
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .ended))
    }

    @Test func theRowAppearsTheFirstTimeAccountIsOpened() async {
        // **F1.** The store starts empty — which is every Mac that has not opened Account, because
        // `currentSubscription()` is the only writer of that store — and the gateway serves a claim.
        // One `refreshSubscription()` must end with the row present. Before the fix the first read
        // returned `nil`, the detached refresh landed, nothing re-read, and the row stayed absent
        // until the dialog was closed and reopened.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: nil, signer: signer, serving: signer.claim())
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
    }

    @Test func aClaimLeftByAPreviousUserIsDiscardedAndReplaced() async {
        // **F2.** A second person signing in on this Mac meets the first one's claim. Answering
        // `nil` is right; leaving the bytes on disk and starting nothing is not, because
        // `shouldRefresh` is then evaluated against the *foreign* claim and a fresh one starts no
        // refresh for up to eight hours. The gateway here serves a claim for the signed-in user, so
        // a run that discards and refreshes ends with that user's own row.
        let signer = Signer()
        let surface = Self.subscribedSurface(
            storing: signer.claim(subject: "somebody-else", plan: "team"),
            signer: signer,
            serving: signer.claim(plan: "paid")
        )
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        // Not `nil`, and specifically not the previous user's plan.
        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
    }

    @Test func theFirstReadNeverWaitsOnTheNetwork() async {
        // The §16.3 property, asserted where it lives now that `refreshSubscription()` may wait:
        // `currentSubscription()` itself answers from the cache and makes no request. A stub that
        // fails every request would break a read that made one, and the cached claim still renders.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
    }

    @Test func theCachedAnswerWinsAndDoesNotWaitForTheRefreshItStarted() async {
        // **C2 — the guard that keeps the common path off the network, which nothing asserted.**
        // Deleting `guard subscription == nil else { return }` survived all 2591 tests, and what
        // that mutant does is make *every* Account open wait on any refresh in flight, including for
        // a subscribed user whose cached claim already answered — falsifying this method's own
        // documented claim with nothing to notice.
        //
        // `theFirstReadNeverWaitsOnTheNetwork` looks like it covers this and cannot: it seeds a
        // fresh claim, so `shouldRefresh` is false, no refresh is ever started, and the mutant
        // reaches an empty `refreshTask` and returns at once. Its name claims more than it holds.
        //
        // **The separation here needs no timing assertion at all**, which is what makes it safe
        // under load: the cached claim and the served claim name *different plans*. Past the 8-hour
        // refresh mark the first read answers from the cache AND starts a refresh; with the guard
        // that cached answer is published and the refresh changes only the next open, so the plan is
        // `paid`. Without it the wait completes, `adopt` takes the newer claim, and the second read
        // publishes `team`.
        let signer = Signer()
        let surface = Self.subscribedSurface(
            // Inside its window — a 24-hour lifetime plus grace — and past the third-of-life mark
            // `EntitlementJudgement.shouldRefresh` uses, so this claim answers and is stale at once.
            storing: signer.claim(plan: "paid", issuedAt: Date().addingTimeInterval(-9 * 60 * 60)),
            signer: signer,
            serving: signer.claim(plan: "team")
        )
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
    }

    @Test func aFailedPortalPressDoesNotSurviveReopeningTheDialog() async {
        // **C3.** The model is the app-wide singleton, `.task` runs `refreshSubscription()` every
        // time the Account sheet is presented, and nothing cleared `portalFailure` there — so a
        // failed press left its sentence under the row and reopening Account showed it again with
        // no press behind it. `run()`'s own doc states the standard: no path may leave a stale
        // message under a new result.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"provider.rejected","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 502
            )
        }
        defer { surface.fixture.unregister() }
        await surface.model.openBillingPortal()
        #expect(surface.model.portalFailure != nil)

        // What `.task` does on the next presentation of the sheet.
        await surface.model.refreshSubscription()

        #expect(surface.model.portalFailure == nil)
    }

    @Test func signingOutClearsTheSubscriptionBeforeTheNextUserSeesIt() async {
        // **F13.** `signedInStep` renders synchronously when `step` becomes `.signedIn`, while
        // `refreshSubscription()` awaits an actor hop, a Keychain read and a signature check — so a
        // snapshot left set is the previous user's plan line and a live Manage control on screen in
        // the meantime.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        defer { surface.fixture.unregister() }
        await surface.model.refreshSubscription()
        #expect(surface.model.subscription != nil)

        await surface.model.signOut()

        #expect(surface.model.subscription == nil)
    }

    // MARK: - A customer whose payment has failed (SONNY-380)

    /// A surface whose gateway answers the payment-state read with `payment`, and serves the portal
    /// nothing.
    ///
    /// **The path is asserted inside the stub rather than assumed**, for the reason
    /// `pressingManageOpensTheLinkTheGatewayMinted` gives: a model that called the wrong route would
    /// still get a body back from a stub that answered everything, and a test reading only the
    /// result would pass.
    static func pastDueSurface(
        storing compactClaim: String?,
        signer: Signer,
        payment: String
    ) -> Surface {
        let surface = subscribedSurface(storing: compactClaim, signer: signer)
        surface.fixture.register { request in
            guard request.url?.path == "/v1/billing/payment-state" else {
                return .reply(statusCode: 404, headers: [:], body: Data())
            }
            #expect(request.httpMethod == "GET")
            return portalReply("{\"payment\":\"" + payment + "\"}")
        }
        return surface
    }

    @Test func aDeclinedCardIsNamedOnTheLineInsteadOfActive() async {
        // **The whole ticket, end to end at the surface.** The claim verifies and grants a
        // capability — which is what §16.4 requires of a past-due account inside its window — so
        // `subscription` is `.active` and the line said `Paid · Active` for the length of the
        // window. The separate read is the only thing that changes it.
        let signer = Signer()
        let surface = Self.pastDueSurface(storing: signer.claim(), signer: signer, payment: "past_due")
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()

        #expect(surface.model.subscription == SubscriptionSnapshot(plan: "paid", status: .active))
        #expect(surface.model.paymentState == .pastDue)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Past due")
        #expect(SubscriptionCopy.controlLabel(for: surface.model.paymentState) == "Update payment")
    }

    @Test func aHealthyAccountStillReadsActive() async {
        // The control on the test above: a read that answered `past_due` for everyone would pass it
        // and fail here. Telling a paying customer their payment failed is the worse of the two
        // mistakes — the same asymmetry SONNY-216's 422 mapping was decided on.
        let signer = Signer()
        let surface = Self.pastDueSurface(storing: signer.claim(), signer: signer, payment: "current")
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()

        #expect(surface.model.paymentState == .current)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Active")
        #expect(SubscriptionCopy.controlLabel(for: surface.model.paymentState) == "Manage subscription")
    }

    @Test func aMacWithNoNetworkSaysNothingAboutPaymentAndReportsNothing() async {
        // The founders' offline decision, at the surface. The claim is cached so the row still
        // renders; the payment read fails; the line is what the claim proves — and **no warning**,
        // which is the half that would be easy to lose: a Mac that has never reached a gateway is
        // the ordinary state of this product, and a failed payment read is not news to put under a
        // sign-in the user just completed.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()

        #expect(surface.model.paymentState == nil)
        #expect(surface.model.failure == nil)
        #expect(surface.model.portalFailure == nil)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Active")
    }

    @Test func aRefusedPaymentReadIsNotAFailureTheUserIsShown() async {
        // The other shape of the same rule: the gateway answers, and says no. A `401` here is a
        // session this Mac cannot use — which the *next* authenticated call reports properly — and
        // an error sentence about it under the subscription row would be about the wrong thing.
        //
        // **The code is `auth.unauthenticated`, which is what the gateway actually sends**
        // (`server/src/auth/gate.ts`'s `REFUSAL_CODE`), and until PR #206's F5 this served
        // `auth.required` — a string `SonnyBackendErrorCode(wire:)` has no arm for, so it decoded to
        // `.unknown("auth.required")` and the test ran a branch the product never reaches. The
        // assertions held on both, so nothing was falsely green; what was missing is that the real
        // code takes a side effect this one does not, below.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"auth.unauthenticated","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 401
            )
        }
        defer { surface.fixture.unregister() }

        await surface.model.refreshPaymentState()

        #expect(surface.model.paymentState == nil)
        #expect(surface.model.failure == nil)
        #expect(surface.model.portalFailure == nil)
    }

    @Test func aRefusedPaymentReadDiscardsTheSessionItCouldNotUse() async throws {
        // **The branch the test above was never reaching** (PR #206's F5). On a `.bearer` request,
        // `auth.unauthenticated` is §7.2 case 1b — the family is gone — so `SonnyBackendClient`
        // calls `discardSessionLocally()` before rethrowing. This read is one the *user* never
        // initiated, so it can wipe the local session from a background refresh, and that is worth
        // one test naming it rather than being a surprise to whoever meets it next.
        //
        // **It is pre-existing rather than this ticket's**: `refreshScreenControlAllowance` already
        // does the identical thing on the identical sheet. Asserted here because this branch adds a
        // second unprompted authenticated read to that surface, so the population grew.
        let signer = Signer()
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"auth.unauthenticated","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 401
            )
        }
        defer { surface.fixture.unregister() }
        let before = try await surface.fixture.client.restoredIdentity()
        #expect(before != nil)

        await surface.model.refreshPaymentState()

        // The Keychain entry is gone, which is what "a session this Mac cannot use" means in code.
        let after = try await surface.fixture.client.restoredIdentity()
        #expect(after == nil)
        // And still nothing is reported: the read stays silent even on the failure that changes
        // local state, because a warning under this row would be about the wrong thing.
        #expect(surface.model.paymentState == nil)
        #expect(surface.model.failure == nil)
        #expect(surface.model.portalFailure == nil)
    }

    @Test func aPaymentStateThisBuildDoesNotKnowSaysNothingRatherThanFailing() async {
        // §8.2 item 7 at the surface. The value decodes, is not recognised, and produces the same
        // line a Mac with no network shows — which is the deliberate answer: an old build cannot
        // interpret a value it has never heard of, so it asserts nothing about payment.
        let signer = Signer()
        let surface = Self.pastDueSurface(storing: signer.claim(), signer: signer, payment: "disputed")
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()

        #expect(surface.model.paymentState == .unrecognised)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Active")
    }

    /// A surface whose payment-state read answers from a list, one reply per call, so a test can
    /// say what the gateway knew *before* the portal was opened and what it knows after.
    ///
    /// **A queue rather than a mutable stub, because the count is half the property**: a re-read
    /// that never happened and a re-read that happened twice both have to be distinguishable, and a
    /// stub that keeps answering the same thing hides both.
    ///
    /// **Lock-guarded and `@unchecked Sendable`, not `@MainActor`** — the stub's handler runs on
    /// URLSession's own thread, so a `MainActor.assumeIsolated` inside it **traps**, and a trapped
    /// test process names no failing test: the whole run dies with a stack trace and the log looks
    /// like a hang rather than like a red assertion. (`CLAUDE.md`'s `try #require` gotcha is the
    /// same family; this is the version that arrives through a test helper's isolation.)
    final class PaymentReplies: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [String]
        private var count = 0
        init(_ replies: [String]) { remaining = replies }
        var asked: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return remaining.isEmpty ? "current" : remaining.removeFirst()
        }
    }

    static func portalReturnSurface(signer: Signer, replies: PaymentReplies) -> Surface {
        let surface = subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { request in
            if request.url?.path == "/v1/billing/payment-state" {
                return portalReply("{\"payment\":\"" + replies.next() + "\"}")
            }
            return portalReply(#"{"portal_url":"https://portal.example.test/s/abc"}"#)
        }
        return surface
    }

    @Test func returningFromThePortalRereadsThePaymentState() async {
        // **PR #206's F3, taken as the founders' option A on 2026-09-05.** The customer presses
        // `Update payment`, fixes the card, and comes back to a sheet that is still open. Before
        // this the line kept saying `Past due` with the same button until Account was closed and
        // reopened — indistinguishable from the button having done nothing.
        let signer = Signer()
        let replies = Self.PaymentReplies(["past_due", "current"])
        let surface = Self.portalReturnSurface(signer: signer, replies: replies)
        defer { surface.fixture.unregister() }
        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()
        #expect(surface.model.paymentState == .pastDue)

        await surface.model.openBillingPortal()
        #expect(surface.opened.urls.count == 1)
        // What the window regaining focus does.
        await surface.model.refreshPaymentStateAfterReturningFromPortal()

        #expect(surface.model.paymentState == .current)
        #expect(replies.asked == 2)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Active")
        #expect(SubscriptionCopy.controlLabel(for: surface.model.paymentState) == "Manage subscription")
    }

    @Test func aReturnThatBeatsTheWebhookStillSaysPastDue() async {
        // **The half of the founders' decision most likely to be read as a bug later.** The gateway
        // learns from a provider webhook, so a customer who pays and switches back faster than the
        // delivery arrives gets `Past due` again — which is true at that moment. The row shows
        // whatever the read says; it does not guess forward, and it does not suppress the answer to
        // avoid looking wrong.
        let signer = Signer()
        let replies = Self.PaymentReplies(["past_due", "past_due"])
        let surface = Self.portalReturnSurface(signer: signer, replies: replies)
        defer { surface.fixture.unregister() }
        await surface.model.refreshSubscription()
        await surface.model.refreshPaymentState()
        await surface.model.openBillingPortal()

        await surface.model.refreshPaymentStateAfterReturningFromPortal()

        #expect(surface.model.paymentState == .pastDue)
        #expect(replies.asked == 2)
        let rendered = surface.model.subscription.map {
            SubscriptionCopy.line(for: $0, payment: surface.model.paymentState)
        }
        #expect(rendered == "Paid · Past due")
    }

    @Test func aWindowComingBackWithNoPressBehindItAsksNothing() async {
        // **The guard, asserted — which is the thing three rounds of PR #183 kept finding nobody
        // had done.** Sonny's window becomes active whenever the user switches back to it, and the
        // Account sheet can sit open for a long time. Without this, every one of those activations
        // is an authenticated request for a value only a provider webhook can move.
        let signer = Signer()
        let replies = Self.PaymentReplies(["past_due"])
        let surface = Self.portalReturnSurface(signer: signer, replies: replies)
        defer { surface.fixture.unregister() }
        await surface.model.refreshPaymentState()
        #expect(replies.asked == 1)

        await surface.model.refreshPaymentStateAfterReturningFromPortal()
        await surface.model.refreshPaymentStateAfterReturningFromPortal()

        #expect(replies.asked == 1)
        #expect(surface.model.paymentState == .pastDue)
    }

    @Test func aSecondReturnAfterOnePressAsksOnlyOnce() async {
        // The flag is cleared by the re-read, not by the next press, so switching away and back
        // twice after one press is one request rather than two. Same guard, the other direction —
        // and the direction a mutant clearing the flag *after* the read would leave open.
        let signer = Signer()
        let replies = Self.PaymentReplies(["past_due", "current"])
        let surface = Self.portalReturnSurface(signer: signer, replies: replies)
        defer { surface.fixture.unregister() }
        await surface.model.refreshPaymentState()
        await surface.model.openBillingPortal()

        await surface.model.refreshPaymentStateAfterReturningFromPortal()
        await surface.model.refreshPaymentStateAfterReturningFromPortal()

        #expect(replies.asked == 2)
    }

    @Test func aPressThatOpenedNothingArmsNoReread() async {
        // The flag is set after the guards rather than before the request: a press that ended in a
        // refused link, a bad URL, or a scheme this app will not open sent the customer nowhere, so
        // there is nothing for a return to be about.
        let signer = Signer()
        let replies = Self.PaymentReplies(["past_due"])
        let surface = Self.subscribedSurface(storing: signer.claim(), signer: signer)
        surface.fixture.register { request in
            if request.url?.path == "/v1/billing/payment-state" {
                return Self.portalReply("{\"payment\":\"" + replies.next() + "\"}")
            }
            return Self.portalReply(#"{"portal_url":"file:///etc/passwd"}"#)
        }
        defer { surface.fixture.unregister() }
        await surface.model.refreshPaymentState()
        #expect(replies.asked == 1)

        await surface.model.openBillingPortal()
        #expect(surface.opened.urls.isEmpty)
        await surface.model.refreshPaymentStateAfterReturningFromPortal()

        #expect(replies.asked == 1)
    }

    @Test func signingOutClearsThePaymentStateBeforeTheNextUserSeesIt() async {
        // **F13's property, for the value this ticket adds.** `signedInStep` renders synchronously
        // when `step` becomes `.signedIn` while the reads behind it are still in flight, so a
        // payment state left set is the previous user's `Past due` and an Update payment button on
        // screen for somebody who has just signed in.
        let signer = Signer()
        let surface = Self.pastDueSurface(storing: signer.claim(), signer: signer, payment: "past_due")
        defer { surface.fixture.unregister() }
        await surface.model.refreshPaymentState()
        #expect(surface.model.paymentState == .pastDue)

        await surface.model.signOut()

        #expect(surface.model.paymentState == nil)
    }

    @Test func theRowDerivesItsLineAndItsControlFromOneReadOfThePaymentState() throws {
        // **A source scan because the wiring is a SwiftUI body**, which nothing in this suite can
        // render. The properties above hold what the copy says; this holds that the row asks for it,
        // asks once, and hands the same answer to both halves — a row that read `model.paymentState`
        // twice could put `Past due` beside `Manage subscription` if a refresh landed between them.
        //
        // Sliced to the row and counted rather than asked `contains`, which is the trap
        // `CLAUDE.md` records: `SubscriptionCopy.` appears at several sites in this file and a
        // membership check over the whole of it would be satisfied by any of them.
        let row = try MacAgentSource.region(
            of: MacAgentSource.read("SignInView.swift"),
            from: "private var subscriptionRow: some View {",
            to: "private var messages: some View"
        )

        #expect(MacAgentSource.count(of: "model.paymentState", inText: row) == 1)
        #expect(MacAgentSource.count(of: "let payment = model.paymentState", inText: row) == 1)
        #expect(
            MacAgentSource.count(
                of: "SubscriptionCopy.line(for: subscription, payment: payment)",
                inText: row
            ) == 1
        )
        #expect(MacAgentSource.count(of: "SubscriptionCopy.controlLabel(for: payment)", inText: row) == 1)
        // The label reaches the button and the accessibility label from the same local, so a screen
        // reader cannot be told a different word from the one on screen. Two uses, one source.
        #expect(MacAgentSource.count(of: "Button(control)", inText: row) == 1)
        #expect(MacAgentSource.count(of: "accessibilityLabel(control)", inText: row) == 1)
        #expect(MacAgentSource.count(of: "accessibilityLabel(line)", inText: row) == 1)
        // And the old shape is gone rather than merely unused: a `manageLabel` left at this site
        // would render `Manage subscription` under a `Past due` line.
        #expect(MacAgentSource.count(of: "SubscriptionCopy.manageLabel", inText: row) == 0)
    }

    @Test func theWindowComingBackIsWiredToTheReread() throws {
        // The behaviour above is held by real tests; what nothing else can reach is whether the
        // *view* is subscribed to anything that fires when the customer switches back. A SwiftUI
        // body is not renderable in this suite, so this is a scan — and it is on the notification
        // by name, because the wrong one is the whole failure mode: the portal opens in a browser,
        // so Sonny resigns active and the sheet never disappears. No `ScenePhase` change, no
        // `onDisappear`, no `onAppear` — `.task` fires once and is done.
        let source = try MacAgentSource.read("SignInView.swift")

        #expect(
            MacAgentSource.count(
                of: "NSApplication.didBecomeActiveNotification",
                inText: source
            ) == 1
        )
        #expect(
            MacAgentSource.count(
                of: "await model.refreshPaymentStateAfterReturningFromPortal()",
                inText: source
            ) == 1
        )
        // And the ordinary two reads are untouched by it: this is a third occasion, not a
        // replacement for either of them.
        #expect(MacAgentSource.count(of: "await model.refreshPaymentState()", inText: source) == 2)
    }

    @Test func thePaymentStateIsReadOnBothOccasionsTheSubscriptionIs() throws {
        // The dialog is a sheet: a user who signs in *inside* it never re-appears it, so `.task`
        // alone leaves the row stale until the next open — the staleness `refreshSubscription()`
        // already has two call sites for. A payment read wired to only one of the two would be
        // correct on a relaunch and silently wrong on the sign-in that just happened.
        let source = try MacAgentSource.read("SignInView.swift")

        #expect(MacAgentSource.count(of: "await model.refreshPaymentState()", inText: source) == 2)
        #expect(MacAgentSource.count(of: "await model.refreshSubscription()", inText: source) == 2)
    }

    // MARK: - What the user is told when the portal does not open (PR #183, F4)

    @Test func aRefusedPortalDoesNotTellTheUserToTryAgain() async {
        // **F4.** `provider.rejected` means an identical retry fails identically — it is the
        // rotation outage `server/README.md` describes — and it used to render sign-in's
        // "Sonny can't be reached right now. Try again in a moment."
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"provider.rejected","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 502
            )
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.model.portalFailure == .cannotBeOpened)
        let sentence = surface.model.portalFailure.map(BillingPortalCopy.message(for:))
        #expect(sentence == "Sonny couldn't open your billing page.")
        // The assertion that actually holds the finding: no retry advice on a failure a retry
        // cannot fix. A mutant folding this case into `.temporarilyUnavailable` fails here.
        #expect(sentence?.contains("Try again") == false)
        // And it never reaches sign-in's channel, whose sentences are about signing in.
        #expect(surface.model.failure == nil)
    }

    @Test func anAccountWithNothingToManageIsToldThatAndNotThatSignInFailed() async {
        // **F4.** `entitlement.no_subscription` had no name in `SonnyBackendErrorCode`, so it became
        // `.unknown` and then sign-in's `.unexpected` — "Sonny couldn't finish signing you in." —
        // shown to somebody who is signed in and pressed Manage subscription.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"entitlement.no_subscription","message":"x","retryable":false,"retry_after_seconds":null,"request_id":"r"}}"#,
                status: 409
            )
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.model.portalFailure == .nothingToManage)
        #expect(
            surface.model.portalFailure.map(BillingPortalCopy.message(for:))
                == "There's no subscription on this account."
        )
        #expect(surface.model.failure == nil)
    }

    @Test func aThrottledPortalPressIsToldToWaitRatherThanThatItFailed() async {
        // The third case F4 named: this route is inside the per-account limiter, so `429` is
        // reachable, and it used to render "Too many attempts." — attempts at what, on one press.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(
                #"{"error":{"code":"limit.rate","message":"x","retryable":true,"retry_after_seconds":30,"request_id":"r"}}"#,
                status: 429
            )
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.model.portalFailure == .temporarilyUnavailable)
    }

    @Test func everyPortalFailureHasItsOwnSentenceAndNoneExplainsItself() async {
        // A population check over `CaseIterable`, so a case added later cannot arrive without words.
        // The exact-equality table is what makes a mutant appending an explanatory clause fail —
        // the standing rule is that the product does not explain itself.
        let expected: [BillingPortalFailure: String] = [
            .nothingToManage: "There's no subscription on this account.",
            .temporarilyUnavailable: "Sonny couldn't open your billing page. Try again in a moment.",
            .cannotBeOpened: "Sonny couldn't open your billing page.",
            .offline: "Connect to the internet to manage your subscription.",
            .signedOut: "Sign in to Sonny to manage your subscription."
        ]
        #expect(Set(expected.keys) == Set(BillingPortalFailure.allCases))
        for failure in BillingPortalFailure.allCases {
            #expect(BillingPortalCopy.message(for: failure) == expected[failure])
        }
    }

    @Test func aPortalLinkOverPlainHTTPIsNotOpened() async {
        // **F7.** The only negative case was `file:`, so a mutant weakening the guard to
        // `scheme != "file"` survived the whole suite: the test named "not HTTPS" held "not file".
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(#"{"portal_url":"http://portal.example.test/s/abc"}"#)
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.portalFailure != nil)
    }

    @Test func aPortalLinkPointingAtThisMachineIsNotOpened() async {
        // `SafeURL.validateWebURL`'s half of the guard, which the hand-rolled check did not have:
        // loopback, RFC1918, link-local and `.local` are refused. Same class of argument as `file:`.
        let surface = Self.surface()
        surface.fixture.register { _ in
            Self.portalReply(#"{"portal_url":"https://127.0.0.1/s/abc"}"#)
        }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.portalFailure != nil)
    }
}
