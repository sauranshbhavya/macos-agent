import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The one suite that talks to a **real gateway** instead of a `URLProtocol` stub.
///
/// **Opt-in, and it says so when it does not run.** Every other suite here is fixture-backed,
/// because a suite whose result depends on a network is not evidence. This one exists for the half
/// a fixture cannot cover: that the request shapes this client builds are the ones the server
/// actually accepts, and that the server's real error envelope and real headers map to the typed
/// errors above. Both were true against a stub by construction.
///
/// Run it against a gateway:
///
/// ```
/// cd server && ./scripts/deploy.sh local
/// SONNY_LIVE_GATEWAY=http://localhost:8080 <the flagged test command> --filter SonnyLiveGatewayTests
/// ```
///
/// **This is also the shape SONNY-192's staging run takes**, with the variable pointed at the
/// staging host instead — the criterion SONNY-128's coordinator amendment of 2026-08-26 moved
/// there, because no staging host exists yet.
///
/// **What it deliberately does not do is sign in.** A real sign-in needs the gateway's Supabase and
/// mail credentials and a mailbox to read a code out of, which is a founder's manual item
/// (`docs/sonny-manual-test-checklist.md`, "Sign-in and the account menu") and not something any
/// agent session can do. A local deployment without those credentials mounts health only, so the
/// auth-route assertion below is written to accept either answer — served or not mounted — and to
/// assert what is true in both: that the client reached the real server and read a real envelope.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SONNY_LIVE_GATEWAY"] != nil))
struct SonnyLiveGatewayTests {
    static var baseURL: URL {
        URL(string: ProcessInfo.processInfo.environment["SONNY_LIVE_GATEWAY"] ?? "http://localhost:8080")!
    }

    @Test
    func theClientReachesTheRealHealthEndpointAndReadsItsBuildIdentifier() async throws {
        let client = Self.makeClient()

        let response = try await client.send(SonnyBackendRequest(
            method: "GET",
            path: "/v1/health",
            body: nil,
            authentication: .none,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        ))

        #expect(response.statusCode == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: response.data) as? [String: Any])
        #expect(body["status"] as? String == "ok")
        // §2.3 makes this the join key between an error a user saw and the metering event. The
        // client reads it off every response, and a stub can only ever prove it reads what a stub
        // was told to send.
        #expect(response.requestID?.isEmpty == false)
        print("live gateway: version=\(body["version"] ?? "?") environment=\(body["environment"] ?? "?") requestID=\(response.requestID ?? "-")")
    }

    /// The real server's own error envelope, mapped by the real mapper.
    ///
    /// A route this gateway does not serve answers `404 resource.not_found` through
    /// `registerErrorHandlers`' not-found handler — which is the contract's §7.1 envelope, produced
    /// by the server rather than written into a fixture by this suite.
    @Test
    func aRouteTheGatewayDoesNotServeMapsToTheContractsTypedNotFound() async throws {
        let client = Self.makeClient()

        do {
            _ = try await client.send(SonnyBackendRequest(
                method: "GET",
                path: "/v1/definitely-not-a-route",
                body: nil,
                authentication: .none,
                idempotencyKey: nil,
                timeout: SonnyBackendTimeouts.auth,
                isRetrySafe: true
            ))
            Issue.record("expected the gateway to refuse an unknown route")
        } catch let error as SonnyBackendError {
            guard case .api(let api) = error else {
                Issue.record("expected a typed API error, got \(error)")
                return
            }
            #expect(api.code == .resourceNotFound)
            #expect(api.statusCode == 404)
            #expect(api.isRetryable == false)
            #expect(api.requestID?.isEmpty == false)
        }
    }

    /// `POST /v1/auth/email/start` as this client sends it, against whatever the gateway does with
    /// it. Two answers are acceptable and the test says which it saw: a deployment carrying auth
    /// credentials serves the uniform §3.6 response, and one without them does not mount the route
    /// at all. Either way the request left this client in a shape the real server parsed.
    @Test
    func theSignInStartRequestIsAcceptedOrRefusedAsAKnownContractOutcome() async throws {
        let client = Self.makeClient()
        let service = SonnyAccountService(client: client)

        do {
            let result = try await service.startEmailSignIn(email: "sonny-live-check@example.invalid")
            #expect(result.expiresIn > 0)
            #expect(!result.requestID.isEmpty)
            print("live gateway: auth routes ARE mounted; email/start returned expires_in=\(result.expiresIn)")
        } catch let error as SonnyBackendError {
            guard case .api(let api) = error else {
                Issue.record("expected a typed API error, got \(error)")
                return
            }
            // `resource.not_found` — auth is not mounted on this deployment. `server.error` — it is
            // mounted and has no database. Both are the server's own envelope, read by this client.
            #expect([.resourceNotFound, .serverError].contains(api.code), "unexpected code \(api.code.wire)")
            print("live gateway: auth routes not usable here; email/start returned \(api.statusCode) \(api.code.wire)")
        }
    }

    private static func makeClient() -> SonnyBackendClient {
        SonnyBackendClient(
            environment: SonnyBackendEnvironment(baseURL: baseURL, source: .production),
            // In memory: this suite must never read or write the Keychain this Mac's packaged
            // builds share, and it needs no session for any of the three routes above.
            tokenStore: KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore()),
            session: URLSession(configuration: .ephemeral)
        )
    }
}
