import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The session in the Keychain: a new account on the existing `KeychainSecretStore`, not a new
/// store and not a variant of the pattern (contract §3.1, and this ticket's second requirement).
@Suite
struct SonnyAccountTokenStoreTests {
    @Test
    func aSessionRoundTripsThroughTheKeychainWithEveryFieldIntact() throws {
        let keychain = InMemoryKeychainSecretStore()
        let store = KeychainAccountTokenStore(secretStore: keychain)
        let expiry = Date(timeIntervalSince1970: 1_800_003_600)
        let refreshExpiry = Date(timeIntervalSince1970: 1_807_000_000)
        let tokens = SonnyAccountTokens(
            accessToken: "access-abc",
            refreshToken: "refresh-def",
            accessTokenExpiresAt: expiry,
            refreshTokenExpiresAt: refreshExpiry,
            userID: "acct_1",
            emailAddress: "founder@example.com"
        )

        try store.saveTokens(tokens)
        let reloaded = try #require(try store.loadTokens())

        #expect(reloaded == tokens)
        #expect(reloaded.accessToken == "access-abc")
        #expect(reloaded.refreshToken == "refresh-def")
        #expect(reloaded.accessTokenExpiresAt == expiry)
        #expect(reloaded.refreshTokenExpiresAt == refreshExpiry)
        #expect(reloaded.userID == "acct_1")
        #expect(reloaded.emailAddress == "founder@example.com")
    }

    @Test
    func loadingReturnsNilRatherThanFailingWhenNothingHasEverBeenStored() throws {
        let store = KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore())
        #expect(try store.loadTokens() == nil)
    }

    @Test
    func savingTwiceReplacesTheSessionRatherThanLeavingTwo() throws {
        let keychain = InMemoryKeychainSecretStore()
        let store = KeychainAccountTokenStore(secretStore: keychain)
        try store.saveTokens(SonnyBackendFixtures.storedTokens(
            accessToken: "first", refreshToken: "first-refresh", expiresAt: Date()
        ))

        try store.saveTokens(SonnyBackendFixtures.storedTokens(
            accessToken: "second", refreshToken: "second-refresh", expiresAt: Date()
        ))

        #expect(try store.loadTokens()?.accessToken == "second")
        #expect(keychain.storedKeys.count == 1)
    }

    /// **The whole point of the separate service.** §3.3 names three actions with three blast
    /// radii — sign out, delete my local data, reset the encryption identity — and says conflating
    /// any two of them is a real bug. Branch 7 deliberately made local data deletion leave the
    /// Keychain encryption key alone; this is the same boundary from the other side.
    @Test
    func clearingTheSessionLeavesTheLocalStorageEncryptionKeyExactlyWhereItWas() throws {
        let keychain = InMemoryKeychainSecretStore()
        let key = Data(repeating: 0x53, count: 32)
        keychain.plant(
            key,
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        )
        let store = KeychainAccountTokenStore(secretStore: keychain)
        try store.saveTokens(SonnyBackendFixtures.storedTokens(expiresAt: Date()))
        #expect(keychain.storedKeys.count == 2)

        try store.clearTokens()

        #expect(try store.loadTokens() == nil)
        #expect(keychain.rawValue(
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        ) == key)
        // And the key manager still hands back the same key, so nothing about the local stores
        // moved: the same bytes decrypt the same files after a sign-out as before one.
        let manager = LocalStorageEncryptionKeyManager(secretStore: keychain)
        #expect(try manager.keyData() == key)
    }

    /// The two Keychain accounts this Mac holds are separated on **service** as well as account, so
    /// a delete cannot reach the wrong item even if the account names ever collide.
    @Test
    func theSessionAndTheEncryptionKeyLiveUnderDifferentServices() {
        #expect(KeychainAccountTokenStore.defaultService != LocalStorageEncryptionKeyManager.defaultService)
        #expect(KeychainAccountTokenStore.defaultService == "com.sonny.account")
        #expect(KeychainAccountTokenStore.defaultAccount == "backend-session-v1")
    }

    @Test
    func clearingWhenNothingIsStoredSucceedsRatherThanFailing() throws {
        let store = KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore())
        try store.clearTokens()
        #expect(try store.loadTokens() == nil)
    }

    /// Bytes that are not a session this build can read are reported, not silently read as "signed
    /// out" — the same reasoning `LocalStorageEncryption` uses for an undecodable local data file.
    @Test
    func undecodableStoredBytesAreReportedRatherThanReadAsAnEmptySession() throws {
        let keychain = InMemoryKeychainSecretStore()
        keychain.plant(
            Data("this is not a session".utf8),
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        )
        let store = KeychainAccountTokenStore(secretStore: keychain)

        #expect(throws: SonnyAccountTokenStoreError.self) {
            _ = try store.loadTokens()
        }
    }

    @Test
    func aKeychainFailureOnSaveIsReportedRatherThanSwallowed() {
        let keychain = InMemoryKeychainSecretStore()
        keychain.failWrites(with: InMemoryKeychainFailure.refused)
        let store = KeychainAccountTokenStore(secretStore: keychain)

        #expect(throws: InMemoryKeychainFailure.refused) {
            try store.saveTokens(SonnyBackendFixtures.storedTokens(expiresAt: Date()))
        }
    }

    /// **Neither string conversion prints a credential.** A `print`, an interpolation or a
    /// debugger's `po` on this value is the cheapest way a token reaches a log, and the app target
    /// cannot even name the fields — this covers `MacAgentCore` printing them by accident.
    @Test
    func neitherDescriptionNorDebugDescriptionPrintsAToken() {
        let tokens = SonnyAccountTokens(
            accessToken: "SUPER-SECRET-ACCESS",
            refreshToken: "SUPER-SECRET-REFRESH",
            accessTokenExpiresAt: Date(),
            refreshTokenExpiresAt: nil,
            userID: "acct_1",
            emailAddress: nil
        )

        for rendered in [tokens.description, tokens.debugDescription, "\(tokens)", String(describing: tokens)] {
            #expect(!rendered.contains("SUPER-SECRET-ACCESS"))
            #expect(!rendered.contains("SUPER-SECRET-REFRESH"))
            #expect(rendered.contains("<redacted>"))
            #expect(rendered.contains("acct_1"))
        }
    }
}
