import Foundation
@testable import MacAgentCore

/// A `SonnyBackendClient` that reaches nothing on this Mac (SONNY-130).
///
/// **Every fixture in both test targets uses this rather than building one by hand**, for the reason
/// `AgentViewModel`'s fixtures name their thirteen stores and `makeHermeticAccountModel` names the
/// Keychain: the real Keychain is shared by every packaged build on this machine, so a test that
/// reached it would read and delete the founder's own session. `SonnyBackendClient.init` has no
/// default for its token store precisely so that no call site can acquire one by saying nothing —
/// this is the one place a test says it out loud.
///
/// The defaults are the "nothing is configured, nothing is signed in" shape: no environment, so
/// every request fails with `backendNotConfigured` before a URL is built, and an empty in-memory
/// Keychain, so `restore()` finds no session. A test that wants a working backend passes an
/// `environment` and a stub `session` from `BackendStubURLProtocol.makeSession()`.
@MainActor
public func makeHermeticBackendClient(
    environment: SonnyBackendEnvironment? = nil,
    keychain: InMemoryKeychainSecretStore = InMemoryKeychainSecretStore(),
    session: URLSession? = nil,
    now: (@Sendable () -> Date)? = nil
) -> SonnyBackendClient {
    SonnyBackendClient(
        environment: environment,
        tokenStore: KeychainAccountTokenStore(secretStore: keychain),
        session: session ?? URLSession(configuration: .ephemeral),
        now: now ?? Date.init
    )
}

/// A signed-in client over a stub transport, plus the pieces a test needs to drive and inspect it.
///
/// The four model routes are all authenticated, so a test of any of them needs a session in the
/// Keychain before the first request — otherwise every one of them fails with `notSignedIn` and the
/// test proves only that the gate exists. `expiresIn` is generous on purpose: it is far past
/// `SonnyBackendClient.proactiveRefreshMargin`, so nothing under test triggers a refresh it did not
/// ask for and no test accidentally depends on the refresh path.
@MainActor
public struct SignedInBackendFixture {
    public let client: SonnyBackendClient
    public let baseURL: URL
    public let host: String

    /// `now` is the client's clock, and **the session's expiry is derived from it rather than from
    /// the wall clock** (SONNY-135). A fixture that pinned a client to an instant while dating its
    /// token from `Date()` would put the two hours apart, and a test that moved the clock forward
    /// would trip the proactive token refresh it was not testing. Deriving both from one closure
    /// keeps `expiresIn` meaning what it says whatever clock the test chooses.
    public init(
        accessToken: String = "test-access-token",
        expiresIn: TimeInterval = 3600,
        now: (@Sendable () -> Date)? = nil
    ) {
        let stub = BackendStubURLProtocol.makeSession()
        host = stub.host
        baseURL = stub.baseURL
        let clock = now ?? Date.init
        let keychain = InMemoryKeychainSecretStore()
        let store = KeychainAccountTokenStore(secretStore: keychain)
        try? store.saveTokens(SonnyAccountTokens(
            accessToken: accessToken,
            refreshToken: "test-refresh-token",
            accessTokenExpiresAt: clock().addingTimeInterval(expiresIn),
            refreshTokenExpiresAt: nil,
            userID: "test-user",
            emailAddress: "someone@example.com"
        ))
        client = SonnyBackendClient(
            environment: SonnyBackendEnvironment(baseURL: stub.baseURL, source: .debugOverride),
            tokenStore: store,
            session: stub.session,
            now: clock
        )
    }

    public func register(_ handler: @escaping BackendStubURLProtocol.Handler) {
        BackendStubURLProtocol.register(host: host, handler: handler)
    }

    public func unregister() {
        BackendStubURLProtocol.unregister(host: host)
    }
}
