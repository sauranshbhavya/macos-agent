import Foundation
import MacAgentCore
import MacAgentTestSupport
@testable import MacAgent

/// A `SonnyAccountModel` that reaches nothing on this Mac.
///
/// **Every fixture in the app target uses this rather than `SonnyAccountModel(...)` by hand**, for
/// the reason every `AgentViewModel` fixture names every store: the real Keychain is shared
/// by every packaged build here, so a test that reached it would read and delete the founder's own
/// session. There is no default anywhere on the path from `main.swift` down, so this is the only
/// way a test gets one at all. (The fixture count used to be spelled here and had fallen behind
/// the tree; dropped by SONNY-326, since it moves with every fixture file added and the reason does
/// not. **The store count stays** — it is `LocalStore.allCases.count`, fifteen since SONNY-452,
/// and a suite asserts it outright rather than leaving it to prose —
/// `LocalDataQuarantineTests.everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey` and
/// `LocalStorageSecurityTests.everyLocalStoreFileIsClassifiedExactlyOnce` both pin it — so a
/// sixteenth store fails a test before it reaches a reader. The numeral was spelled here anyway and
/// went stale exactly as the sentence above says a spelled count will; it survived SONNY-333's own
/// ordinal sweep because the phrase wraps across two lines and that sweep's grep is line-anchored
/// — PR #194's cycle-3 R4, and SONNY-400's finding about the method.)
@MainActor
func makeHermeticAccountModel(
    keychain: InMemoryKeychainSecretStore = InMemoryKeychainSecretStore(),
    environment: SonnyBackendEnvironment? = nil,
    session: URLSession? = nil,
    /// SONNY-216. Defaults to the shipped (empty) set, so a fixture that says nothing about
    /// entitlements gets the shipping build's answer — no claim verifies, and the subscription row
    /// is absent — rather than a key set no release build holds.
    entitlementKeys: EntitlementKeySet = SonnyEntitlementKeys.shipped
) -> SonnyAccountModel {
    let model = SonnyAccountModel(
        client: makeHermeticBackendClient(
            environment: environment,
            keychain: keychain,
            session: session
        ),
        // **The same in-memory keychain the client is given**, so a fixture's claim and its session
        // live in one place and neither reaches the real Keychain. There is no default on the model
        // for this, which is what forces every fixture through here.
        entitlementStore: KeychainEntitlementStore(secretStore: keychain),
        entitlementKeys: entitlementKeys
    )
    // **A browser that opens nothing** (SONNY-129). The model's own default is the system's web
    // authentication session, which would open a real browser on the machine running the suite; a
    // fixture that "reaches nothing on this Mac" cannot hand that out. A test about Google sign-in
    // replaces this with a fake that answers.
    model.webAuthenticator = UnopenableWebAuthenticator()
    return model
}

/// The fixture's browser: every attempt fails as the system failing to run one, so a test that
/// reaches it without meaning to fails loudly rather than opening a window.
struct UnopenableWebAuthenticator: WebAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        throw SonnyGoogleSignInError.sessionFailed
    }
}

/// A browser that comes back with a fixed answer, for the app target's Google sign-in tests.
struct AnsweringWebAuthenticator: WebAuthenticating {
    let outcome: Result<String, SonnyGoogleSignInError>

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        switch outcome {
        case .success(let raw):
            guard let url = URL(string: raw) else { throw SonnyGoogleSignInError.malformedCallback }
            return url
        case .failure(let error):
            throw error
        }
    }
}
