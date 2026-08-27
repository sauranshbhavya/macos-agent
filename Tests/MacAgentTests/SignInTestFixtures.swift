import Foundation
import MacAgentCore
import MacAgentTestSupport
@testable import MacAgent

/// A `SonnyAccountModel` that reaches nothing on this Mac.
///
/// **Every fixture in the app target uses this rather than `SonnyAccountModel(...)` by hand**, for
/// the reason `AgentViewModel`'s fifteen fixtures name their thirteen stores: the real Keychain is
/// shared by every packaged build here, so a test that reached it would read and delete the
/// founder's own session. There is no default anywhere on the path from `main.swift` down, so this
/// is the only way a test gets one at all.
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
