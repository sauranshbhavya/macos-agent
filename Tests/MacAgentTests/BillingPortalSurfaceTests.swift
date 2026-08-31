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
        #expect(surface.model.failure != nil)
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
        #expect(surface.model.failure != nil)
    }

    @Test func aBodyWithNoURLOpensNothing() async {
        let surface = Self.surface()
        surface.fixture.register { _ in Self.portalReply(#"{"expires_at":"2026-08-31T13:00:00Z"}"#) }
        defer { surface.fixture.unregister() }

        await surface.model.openBillingPortal()

        #expect(surface.opened.urls.isEmpty)
        #expect(surface.model.failure != nil)
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

    @Test func theSubscriptionReadAsksTheNetworkForNothing() async {
        // §16.3's guarantee applied to a screen: the Account section renders with the Wi-Fi off. A
        // handler that answers every request with a transport failure would break a read that made
        // one, and `currentSubscription()` must make none.
        let surface = Self.surface()
        surface.fixture.register { _ in .failure(URLError(.notConnectedToInternet)) }
        defer { surface.fixture.unregister() }

        await surface.model.refreshSubscription()

        #expect(surface.model.subscription == nil)
        // And the read reports nothing, because a Mac with no claim is the ordinary state rather
        // than news — a failure here would put a warning under a sign-in the user just completed.
        #expect(surface.model.failure == nil)
    }
}
