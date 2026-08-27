import CoreGraphics
import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The live suite's own recognizer, finding nothing — a window with no secrets on it.
///
/// Its own type rather than a shared one because this file is the only opt-in suite in the target
/// and must not depend on a fixture another suite could change out from under it.
private struct LiveCheckSilentRecognizer: ImageTextRecognizing {
    func recognizeText(inPNGData pngData: Data, pixelWidth: Int, pixelHeight: Int) async throws -> [RecognizedTextObservation] {
        []
    }
}

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

    /// **The five model routes SONNY-130 and SONNY-131 moved, driven through their real clients
    /// against a real gateway.** This is the half a `URLProtocol` stub cannot cover — that the bodies these clients
    /// build are ones the server parses, and that the server's own envelope maps back — and it is
    /// what SONNY-192's staging run will exercise with the variable pointed at staging.
    ///
    /// **Three outcomes are acceptable and the test prints which it saw.** A deployment with a real
    /// session and provider credentials answers the route. One without auth configured answers
    /// `401 auth.unauthenticated`, which is the gate refusing a protected route on a process with no
    /// way to authenticate anyone — the shape `./scripts/deploy.sh local` produces today. One with
    /// auth but no credential for that route's provider answers `502 provider.unavailable`. All
    /// three are the server's own envelope read by this client, which is the property being checked;
    /// what is *not* acceptable is a transport failure, a 404, or an envelope this client cannot
    /// read, and each of those fails the test.
    ///
    /// The session is a fabricated one in an in-memory Keychain, because `authentication: .bearer`
    /// refuses before sending when no session is held — without one this would assert nothing about
    /// the server at all. A real sign-in is a founder's manual item; no agent session can read a
    /// code out of a mailbox.
    @Test
    @MainActor
    func theFiveModelRoutesReachTheRealGatewayAndTheirAnswersMapBack() async throws {
        // **A fresh client per route, and that is not tidiness.** §7.2 case 1b makes the client
        // clear its Keychain entry on `auth.unauthenticated`, so the first route's 401 signs this
        // fabricated session out and every route after it would fail with `notSignedIn` before
        // sending — proving nothing about the server. The suite found that on its first run.
        let context = BackendTaskContext(taskID: "live-check-\(UUID().uuidString)", retention: .standard)
        let acceptable: Set<SonnyBackendErrorCode> = [
            .authUnauthenticated, .authTokenExpired, .authTokenRevoked, .providerUnavailable,
        ]

        func check(_ route: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                print("live gateway: \(route) SERVED — this deployment has a session and a credential")
            } catch let error as SonnyBackendError {
                record(route, error, acceptable)
            } catch let error as PlannerError {
                guard case .backend(let backend) = error else {
                    Issue.record("\(route): expected a backend failure, got \(error)")
                    return
                }
                record(route, backend, acceptable)
            } catch let error as TranscriptionError {
                guard case .backend(let backend) = error else {
                    Issue.record("\(route): expected a backend failure, got \(error)")
                    return
                }
                record(route, backend, acceptable)
            } catch let error as TavilySearchError {
                guard case .backend(let backend) = error else {
                    Issue.record("\(route): expected a backend failure, got \(error)")
                    return
                }
                record(route, backend, acceptable)
            } catch let error as VisionModelClientError {
                guard case .backend(let backend) = error else {
                    Issue.record("\(route): expected a backend failure, got \(error)")
                    return
                }
                record(route, backend, acceptable)
            } catch {
                Issue.record("\(route): unexpected error \(error)")
            }
        }

        await check("/v1/plan") {
            _ = try await OpenAIPlanner(client: Self.makeSignedInClient(), taskContext: context)
                .plan(command: "open Safari")
        }
        await check("/v1/research/synthesize") {
            _ = try await OpenAIWebResearchSynthesizer(
                client: Self.makeSignedInClient(),
                taskContext: context
            )
                .synthesize(prompt: WebResearchSynthesisPrompt(
                    trustedPlan: AgentPlan(summary: "Summarize.", requiresConfirmation: false, steps: []),
                    systemText: "SYSTEM",
                    trustedUserInstructionText: "Summarize.",
                    observedContentTexts: ["Observed."]
                ))
        }
        await check("/v1/search") {
            _ = try await TavilySearchProvider(client: Self.makeSignedInClient(), taskContext: context)
                .search(query: "swift concurrency", limit: 3)
        }
        await check("/v1/transcriptions") {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("sonny-live-\(UUID().uuidString).m4a")
            try Data("fake-audio".utf8).write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            _ = try await OpenAITranscriber(client: Self.makeSignedInClient(), taskContext: context)
                .transcribe(audioFileURL: url, recordedDuration: 2)
        }
        // **The payload is a real redacted capture, not a hand-built one**, because it cannot be
        // anything else: `RedactedPayload`'s initializer is `fileprivate` to
        // `LocalRedactionService.swift`, so the only way to obtain one is to run a capture through
        // the real service. That is the structural non-bypass doing its job in a test as well as in
        // production — and it means what reaches the gateway here is genuinely the shape a session
        // sends, base64 and dimensions included.
        await check("/v1/screen/analyze") {
            let capture = CapturedWindowImage(
                pngData: ImageFixtures.whiteOverBlackPNG(width: 200, height: 150),
                pixelWidth: 200,
                pixelHeight: 150,
                bundleIdentifier: "com.example.live",
                windowTitle: "Live check",
                windowID: 1,
                windowFrame: CGRect(x: 0, y: 0, width: 200, height: 150)
            )
            let payload = try await LocalRedactionService(textRecognizer: LiveCheckSilentRecognizer())
                .redactCapture(capture)
            _ = try await SonnyVisionModelClient(
                client: Self.makeSignedInClient(),
                taskContext: context
            ).decide(
                prompt: "Decide the next action.",
                payload: payload,
                session: VisionSessionRequestContext(sessionID: "live-check-session", iteration: 1)
            )
        }
    }

    private func record(
        _ route: String,
        _ error: SonnyBackendError,
        _ acceptable: Set<SonnyBackendErrorCode>
    ) {
        guard case .api(let api) = error else {
            Issue.record("\(route): expected a typed API error from the real server, got \(error)")
            return
        }
        #expect(acceptable.contains(api.code), "\(route): unexpected code \(api.code.wire)")
        #expect(api.requestID?.isEmpty == false, "\(route): the server sent no request id")
        print("live gateway: \(route) answered \(api.statusCode) \(api.code.wire)")
    }

    /// A client holding a session, in an in-memory Keychain this Mac's packaged builds never see.
    ///
    /// **`SONNY_LIVE_ACCESS_TOKEN` supplies a real one when there is one.** Without it the token is
    /// fabricated, the gateway refuses it, and the test asserts the refusal mapped back — which
    /// proves the transport and the error path and nothing about a served answer. With it, the four
    /// routes above run for real, which is what the ticket's first acceptance criterion asks for and
    /// what SONNY-192's staging run will do. It is an environment variable rather than a sign-in
    /// because no agent session can read a code out of a mailbox, and a founder pointing this at
    /// staging already has a session in hand.
    ///
    /// (The four became five when SONNY-131 added the vision route; the paragraph above is otherwise
    /// SONNY-130's and unchanged.)
    private static func makeSignedInClient() -> SonnyBackendClient {
        let store = KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore())
        try? store.saveTokens(SonnyAccountTokens(
            accessToken: ProcessInfo.processInfo.environment["SONNY_LIVE_ACCESS_TOKEN"]
                ?? "live-check-not-a-real-token",
            refreshToken: "live-check-not-a-real-refresh-token",
            accessTokenExpiresAt: Date().addingTimeInterval(3600),
            refreshTokenExpiresAt: nil,
            userID: "live-check",
            emailAddress: nil
        ))
        return SonnyBackendClient(
            environment: SonnyBackendEnvironment(baseURL: baseURL, source: .production),
            tokenStore: store,
            session: URLSession(configuration: .ephemeral)
        )
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
