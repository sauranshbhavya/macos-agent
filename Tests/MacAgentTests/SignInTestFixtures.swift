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
    session: URLSession? = nil
) -> SonnyAccountModel {
    SonnyAccountModel(client: makeHermeticBackendClient(
        environment: environment,
        keychain: keychain,
        session: session
    ))
}
