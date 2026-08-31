import Foundation
import MacAgentCore
import MacAgentTestSupport
@testable import MacAgent

/// A `SonnyAccountModel` that reaches nothing on this Mac.
///
/// **Every fixture in the app target uses this rather than `SonnyAccountModel(...)` by hand**, for
/// the reason every `AgentViewModel` fixture names its thirteen stores: the real Keychain is shared
/// by every packaged build here, so a test that reached it would read and delete the founder's own
/// session. There is no default anywhere on the path from `main.swift` down, so this is the only
/// way a test gets one at all. (The fixture count used to be spelled here and had fallen behind
/// the tree; dropped by SONNY-326, since it moves with every fixture file added and the reason does
/// not. **The thirteen stays** — it is `LocalStore.allCases.count`, which a suite asserts outright
/// rather than leaving to prose —
/// `LocalDataQuarantineTests.everyLocalStoreIsUnreadableWhenItsFileWasWrittenUnderAnotherKey` and
/// `LocalStorageSecurityTests.everyLocalStoreFileIsClassifiedExactlyOnce` both pin it — so a
/// fourteenth store fails a test before it reaches a reader.)
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
    SonnyAccountModel(
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
}
