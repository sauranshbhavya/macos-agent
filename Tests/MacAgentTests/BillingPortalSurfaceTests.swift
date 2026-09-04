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
        let rendered = surface.model.subscription.map(SubscriptionCopy.line(for:))
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
