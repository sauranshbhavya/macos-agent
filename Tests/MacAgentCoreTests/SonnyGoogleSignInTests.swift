import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// Sign in with Google on the Mac (SONNY-129): the PKCE pair, the callback, the address it will open,
/// and the flow through `SonnyAccountService` against a stubbed gateway and a fake browser.
@Suite
struct SonnyGoogleSignInTests {
    // MARK: - PKCE

    /// RFC 7636, Appendix B: the verifier and challenge the specification itself works through.
    @Test
    func theChallengeIsRFC7636sOwnExample() {
        let pair = SonnyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pair.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test
    func aGeneratedVerifierIsFortyThreeUnreservedCharactersAndNeverRepeats() throws {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = try (0..<32).map { _ in try SonnyPKCE.generate() }
        for pair in pairs {
            #expect(pair.verifier.count == 43)
            #expect(pair.verifier.unicodeScalars.allSatisfy(unreserved.contains))
            #expect(pair.challenge == SonnyPKCE(verifier: pair.verifier).challenge)
            // The server refuses anything but a 43-character base64url challenge.
            #expect(pair.challenge.count == 43)
        }
        #expect(Set(pairs.map(\.verifier)).count == pairs.count)
    }

    // MARK: - The callback

    @Test
    func readsTheCodeFromTheCallbackItWaitedOn() throws {
        let url = try #require(URL(string: "com.sonny.macagent://auth/callback?code=0b8f1c52-abc"))
        #expect(try SonnyGoogleSignIn.authorizationCode(from: url) == "0b8f1c52-abc")
    }

    @Test(arguments: [
        "com.sonny.macagent://auth/callback",
        "com.sonny.macagent://auth/callback?code=",
        "com.sonny.macagent://auth/elsewhere?code=abc",
        "com.sonny.macagent://other/callback?code=abc",
        "com.someone.else://auth/callback?code=abc",
        "https://auth/callback?code=abc"
    ])
    func refusesACallbackThisFlowDidNotAskFor(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: SonnyGoogleSignInError.malformedCallback) {
            try SonnyGoogleSignIn.authorizationCode(from: url)
        }
    }

    @Test(arguments: [
        "com.sonny.macagent://auth/callback?error=access_denied&error_description=denied",
        "com.sonny.macagent://auth/callback#error=access_denied&error_code=403",
        // A code beside an error is still a refusal: the provider said no.
        "com.sonny.macagent://auth/callback?code=abc&error=server_error"
    ])
    func readsAProviderRefusalAsDeclinedWhereverItArrives(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(throws: SonnyGoogleSignInError.declined) {
            try SonnyGoogleSignIn.authorizationCode(from: url)
        }
    }

    @Test(arguments: [
        ("https://project-ref.supabase.co/auth/v1/authorize?provider=google", true),
        ("http://127.0.0.1:54321/auth/v1/authorize", true),
        ("http://localhost:54321/auth/v1/authorize", true),
        ("http://project-ref.supabase.co/auth/v1/authorize", false),
        ("file:///etc/passwd", false),
        ("com.sonny.macagent://auth/callback", false),
        ("javascript:alert(1)", false)
    ])
    func opensOnlyAnAddressABrowserShouldBeHanded(raw: String, openable: Bool) throws {
        let url = try #require(URL(string: raw))
        #expect(SonnyGoogleSignIn.isOpenable(url) == openable)
    }

    /// **One string on both halves of the repository.** The gateway fixes the redirect and never takes
    /// it from a request; the Mac waits on this. A mismatch fails as a browser that never comes back,
    /// with nothing anywhere saying why — so the Swift suite reads the server's constant.
    @Test
    func theCallbackIsTheOneTheGatewayRedirectsTo() throws {
        let source = try String(
            contentsOf: TestSourceTree.repositoryRoot.appendingPathComponent("server/src/auth/oauth.ts"),
            encoding: .utf8
        )
        let declarations = source.split(separator: "\n").filter { $0.hasPrefix("export const OAUTH_REDIRECT_URL") }
        #expect(declarations.count == 1)
        #expect(declarations.first.map(String.init) == "export const OAUTH_REDIRECT_URL = \"\(SonnyGoogleSignIn.callbackURL)\";")
        let callback = try #require(URL(string: SonnyGoogleSignIn.callbackURL))
        #expect(callback.scheme == SonnyGoogleSignIn.callbackScheme)
    }

    // MARK: - Through the service

    @Test
    func signingInSendsOnlyTheChallengeFirstThenTheCodeAndVerifierAndWritesTheSessionBeforeReturning() async throws {
        let harness = try Harness()
        let pkce = SonnyPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            switch request.url?.path {
            case "/v1/auth/oauth/google/start":
                return .reply(statusCode: 200, headers: [:], body: Data(
                    #"{"authorize_url":"https://project-ref.supabase.co/auth/v1/authorize?provider=google"}"#.utf8
                ))
            case "/v1/auth/oauth/google":
                return .reply(statusCode: 200, headers: [:], body: Harness.googleTokenResponse)
            default:
                return .reply(statusCode: 404, headers: [:], body: Data())
            }
        }
        let browser = FakeBrowser(returning: "com.sonny.macagent://auth/callback?code=code-from-google")

        let identity = try await harness.service.signInWithGoogle(using: browser, pkce: pkce)

        #expect(seen.recorded.map(\.url?.path) == ["/v1/auth/oauth/google/start", "/v1/auth/oauth/google"])
        let start = try #require(seen.recorded.first)
        let startBody = BackendStubURLProtocol.bodyJSON(of: start)
        #expect(startBody["code_challenge"] as? String == pkce.challenge)
        // The verifier never travels until the exchange.
        #expect(startBody["code_verifier"] == nil)
        #expect(start.value(forHTTPHeaderField: "Authorization") == nil)

        let exchange = try #require(seen.recorded.dropFirst().first)
        let exchangeBody = BackendStubURLProtocol.bodyJSON(of: exchange)
        #expect(exchangeBody["auth_code"] as? String == "code-from-google")
        #expect(exchangeBody["code_verifier"] as? String == pkce.verifier)
        #expect(exchange.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        #expect(exchange.value(forHTTPHeaderField: "Authorization") == nil)

        #expect(browser.opened == [
            .init(url: "https://project-ref.supabase.co/auth/v1/authorize?provider=google", scheme: "com.sonny.macagent")
        ])
        // The address shown is the one Google asserted, since nothing was typed.
        #expect(identity.emailAddress == "person@gmail.com")
        let onDisk = try #require(try harness.tokenStore.loadTokens())
        #expect(onDisk.accessToken == "google-access")
        #expect(onDisk.refreshToken == "google-refresh")
        #expect(onDisk.emailAddress == "person@gmail.com")
    }

    @Test
    func aClosedBrowserSpendsNothingAndWritesNothing() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data(
                #"{"authorize_url":"https://project-ref.supabase.co/auth/v1/authorize"}"#.utf8
            ))
        }
        let browser = FakeBrowser(throwing: SonnyGoogleSignInError.cancelled)

        await #expect(throws: SonnyGoogleSignInError.cancelled) {
            _ = try await harness.service.signInWithGoogle(using: browser, pkce: try SonnyPKCE.generate())
        }
        #expect(seen.recorded.map(\.url?.path) == ["/v1/auth/oauth/google/start"])
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    @Test
    func aProviderThatDeclinedSendsNoExchange() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data(
                #"{"authorize_url":"https://project-ref.supabase.co/auth/v1/authorize"}"#.utf8
            ))
        }
        let browser = FakeBrowser(returning: "com.sonny.macagent://auth/callback?error=access_denied")

        await #expect(throws: SonnyGoogleSignInError.declined) {
            _ = try await harness.service.signInWithGoogle(using: browser, pkce: try SonnyPKCE.generate())
        }
        #expect(seen.recorded.count == 1)
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    @Test
    func anAddressTheMacWillNotOpenNeverReachesTheBrowser() async throws {
        let harness = try Harness()
        harness.serve { _ in
            .reply(statusCode: 200, headers: [:], body: Data(#"{"authorize_url":"file:///etc/passwd"}"#.utf8))
        }
        let browser = FakeBrowser(returning: "com.sonny.macagent://auth/callback?code=x")

        await #expect(throws: SonnyGoogleSignInError.unopenableAuthorizeURL) {
            _ = try await harness.service.signInWithGoogle(using: browser, pkce: try SonnyPKCE.generate())
        }
        #expect(browser.opened.isEmpty)
    }

    /// The founders' option A, from this side: the gateway refuses a sign-in whose provider-side user
    /// already backs another account, and the Mac reads that as its own failure, writes nothing, and
    /// does not try the single-use code again.
    @Test
    func aSignInRefusedAsAnExistingAccountIsNamedWritesNothingAndIsNotRetried() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            if request.url?.path == "/v1/auth/oauth/google/start" {
                return .reply(statusCode: 200, headers: [:], body: Data(
                    #"{"authorize_url":"https://project-ref.supabase.co/auth/v1/authorize"}"#.utf8
                ))
            }
            return .reply(
                statusCode: 409,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.account_exists")
            )
        }
        let browser = FakeBrowser(returning: "com.sonny.macagent://auth/callback?code=x")

        var thrown: Error?
        do {
            _ = try await harness.service.signInWithGoogle(using: browser, pkce: try SonnyPKCE.generate())
        } catch {
            thrown = error
        }
        let backendError = try #require(thrown as? SonnyBackendError)
        guard case .api(let api) = backendError else {
            Issue.record("expected an API error, got \(backendError)")
            return
        }
        #expect(api.code == .authAccountExists)
        #expect(SignInFailure(googleSignIn: backendError) == .accountExists)
        #expect(seen.recorded.filter { $0.url?.path == "/v1/auth/oauth/google" }.count == 1)
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    // MARK: - Harness

    struct FakeBrowser: WebAuthenticating {
        struct Opened: Equatable, Sendable {
            let url: String
            let scheme: String
        }

        private let outcome: Result<String, SonnyGoogleSignInError>
        private let log = OpenedLog()

        init(returning callback: String) { outcome = .success(callback) }
        init(throwing error: SonnyGoogleSignInError) { outcome = .failure(error) }

        var opened: [Opened] { log.entries }

        func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            log.append(Opened(url: url.absoluteString, scheme: callbackScheme))
            switch outcome {
            case .success(let raw):
                guard let url = URL(string: raw) else { throw SonnyGoogleSignInError.malformedCallback }
                return url
            case .failure(let error):
                throw error
            }
        }
    }

    final class OpenedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [FakeBrowser.Opened] = []
        var entries: [FakeBrowser.Opened] { lock.withLock { stored } }
        func append(_ entry: FakeBrowser.Opened) { lock.withLock { stored.append(entry) } }
    }

    private struct Harness {
        static let googleTokenResponse = Data("""
        {"access_token":"google-access","token_type":"Bearer","expires_in":3600,\
        "expires_at":"2026-09-18T12:00:00Z","refresh_token":"google-refresh",\
        "user":{"id":"\(SonnyBackendFixtures.userID)","email":"person@gmail.com"}}
        """.utf8)

        let host: String
        let tokenStore: KeychainAccountTokenStore
        let service: SonnyAccountService

        init() throws {
            let stub = BackendStubURLProtocol.makeSession()
            host = stub.host
            let keychain = InMemoryKeychainSecretStore()
            keychain.plant(
                Data(repeating: 0x53, count: 32),
                service: LocalStorageEncryptionKeyManager.defaultService,
                account: LocalStorageEncryptionKeyManager.defaultAccount
            )
            tokenStore = KeychainAccountTokenStore(secretStore: keychain)
            let client = SonnyBackendClient(
                environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .production),
                tokenStore: tokenStore,
                session: stub.session,
                jitterFraction: { 0 },
                sleepForRetry: { _ in }
            )
            service = SonnyAccountService(client: client)
        }

        func serve(_ handler: @escaping BackendStubURLProtocol.Handler) {
            BackendStubURLProtocol.register(host: host, handler: handler)
        }
    }
}
