import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The three auth calls the Mac app makes, and the property this ticket exists for: the session is
/// on disk before anything else happens.
@Suite
struct SonnyAccountServiceTests {
    // MARK: - Requesting a code

    @Test
    func startingSignInPostsTheAddressAndReturnsWhatTheUniformResponseSays() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"request_id":"req_9","expires_in":600}"#.utf8)
            )
        }

        let result = try await harness.service.startEmailSignIn(email: "founder@example.com")

        #expect(result == SignInCodeRequest(requestID: "req_9", expiresIn: 600))
        let request = try #require(seen.recorded.first)
        #expect(request.url?.path == "/v1/auth/email/start")
        #expect(request.httpMethod == "POST")
        #expect(BackendStubURLProtocol.bodyJSON(of: request)["email"] as? String == "founder@example.com")
        // §9.3: without the key, a retry sends a second code and races the first.
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") != nil)
        // §4.1: this route is public. A token attached here would be one the client does not have.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - The headline requirement

    /// **The token is in the Keychain before `verifyEmailCode` returns**, so it is in the Keychain
    /// before anything a caller could do next — including the Screen Recording grant's forced
    /// relaunch, which is the step this requirement exists for.
    @Test
    func verifyingWritesTheSessionToTheKeychainBeforeItReturns() async throws {
        let harness = try Harness()
        harness.serve { request in
            guard request.url?.path == "/v1/auth/email/verify" else {
                return .reply(statusCode: 404, headers: [:], body: Data())
            }
            return .reply(
                statusCode: 200,
                headers: [:],
                body: SonnyBackendFixtures.tokenResponseJSON(
                    accessToken: "issued-access",
                    refreshToken: "issued-refresh"
                )
            )
        }

        let identity = try await harness.service.verifyEmailCode(
            email: SonnyBackendFixtures.email,
            code: "123456"
        )

        #expect(identity.userID == SonnyBackendFixtures.userID)
        #expect(identity.emailAddress == SonnyBackendFixtures.email)
        // Already written, by the time the call returned, under this Mac's session account.
        #expect(harness.keychain.writeLog == [
            InMemoryKeychainSecretStore.Key(
                service: KeychainAccountTokenStore.defaultService,
                account: KeychainAccountTokenStore.defaultAccount
            )
        ])
        let onDisk = try #require(try harness.tokenStore.loadTokens())
        #expect(onDisk.accessToken == "issued-access")
        #expect(onDisk.refreshToken == "issued-refresh")
        #expect(onDisk.userID == SonnyBackendFixtures.userID)
        #expect(onDisk.emailAddress == SonnyBackendFixtures.email)
    }

    /// **A relaunch, as the code sees one: a brand new client over the same Keychain.** No network
    /// is touched, so this is also what a launch with no connection restores.
    @Test
    func theSessionSurvivesAProcessRelaunchAndTheAppComesBackSignedIn() async throws {
        let harness = try Harness()
        harness.serve { _ in
            .reply(
                statusCode: 200,
                headers: [:],
                body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "issued-access")
            )
        }
        _ = try await harness.service.verifyEmailCode(email: SonnyBackendFixtures.email, code: "123456")

        // Everything the first process held is gone: a new client, a new token store, a new
        // service. Only the Keychain is shared, which is the only thing a relaunch keeps.
        let relaunched = SonnyBackendClient(
            environment: SonnyBackendEnvironment(baseURL: harness.baseURL, source: .production),
            tokenStore: KeychainAccountTokenStore(secretStore: harness.keychain),
            session: harness.session
        )
        let identity = try await SonnyAccountService(client: relaunched).restoredIdentity()

        #expect(identity == SonnyAccountIdentity(
            userID: SonnyBackendFixtures.userID,
            emailAddress: SonnyBackendFixtures.email
        ))

        // And the restored session is usable, not merely readable: the next authenticated request
        // carries the token the first process was issued.
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        _ = try await relaunched.send(SonnyBackendRequest(
            method: "GET", path: "/v1/protected", body: nil, authentication: .bearer,
            idempotencyKey: nil, timeout: SonnyBackendTimeouts.auth, isRetrySafe: true
        ))
        #expect(seen.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer issued-access")
    }

    /// **The negative half, and the one that would be worst to get wrong.** If the Keychain write
    /// fails, sign-in fails. Reporting success on a session no disk holds is how a user grants
    /// Screen Recording, watches the app relaunch, and finds themselves signed out with no idea why.
    @Test
    func aFailedKeychainWriteFailsSignInRatherThanReportingSuccess() async throws {
        let harness = try Harness()
        harness.keychain.failWrites(with: InMemoryKeychainFailure.refused)
        harness.serve { _ in
            .reply(
                statusCode: 200,
                headers: [:],
                body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "issued-access")
            )
        }

        await #expect(throws: InMemoryKeychainFailure.refused) {
            _ = try await harness.service.verifyEmailCode(email: SonnyBackendFixtures.email, code: "123456")
        }

        harness.keychain.stopFailing()
        #expect(try harness.tokenStore.loadTokens() == nil)
        // And the process does not believe it is signed in either — the cache is written after the
        // Keychain, never before it.
        #expect(try await harness.client.restoredIdentity() == nil)
    }

    @Test
    func aRejectedCodeWritesNothingToTheKeychain() async throws {
        let harness = try Harness()
        harness.serve { _ in
            .reply(
                statusCode: 400,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.code_invalid")
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.service.verifyEmailCode(email: SonnyBackendFixtures.email, code: "000000")
        }

        #expect(harness.keychain.writeLog.isEmpty)
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    /// §9.3: a code is single-use, so a failure on verify is never sent a second time.
    @Test
    func verifyingIsNeverRetriedEvenOnARetryableFailure() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("verify")
            return .reply(
                statusCode: 503,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "server.unavailable", retryable: true)
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.service.verifyEmailCode(email: SonnyBackendFixtures.email, code: "123456")
        }
        #expect(counts.count("verify") == 1)
    }

    /// §3.6's advisory `link_hint` is decoded and changes nothing. A client that ignores it is
    /// correct per the contract and gets two accounts; the prompt that would offer to join them is
    /// not this ticket's, and nothing here must break when the field is present.
    @Test
    func aTokenResponseCarryingALinkHintStillSignsInNormally() async throws {
        let harness = try Harness()
        harness.serve { _ in
            .reply(
                statusCode: 200,
                headers: [:],
                body: SonnyBackendFixtures.tokenResponseJSON(
                    linkHint: "verified_email_matches_existing_account"
                )
            )
        }

        let identity = try await harness.service.verifyEmailCode(
            email: SonnyBackendFixtures.email,
            code: "123456"
        )

        #expect(identity.userID == SonnyBackendFixtures.userID)
    }

    // MARK: - Signing out

    /// Revoke first, then clear — the only order that works, since clearing first destroys the token
    /// the revoke has to present.
    @Test
    func signingOutRevokesServerSideWithTheBearerTokenAndThenClearsTheKeychain() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "live-access")
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 204, headers: [:], body: Data())
        }

        let outcome = try await harness.service.signOut()

        #expect(outcome == .revoked)
        let request = try #require(seen.recorded.first)
        #expect(request.url?.path == "/v1/auth/signout")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer live-access")
        #expect(try harness.tokenStore.loadTokens() == nil)
        #expect(try await harness.client.restoredIdentity() == nil)
    }

    /// **The Keychain is cleared even when the revoke could not happen.** A user who pressed Sign
    /// out and is left holding a refresh token because a network call failed has been told something
    /// untrue about their own machine; keeping the credential on disk to preserve a call that may
    /// never succeed is the worse of the two failures.
    @Test
    func signingOutClearsThisMacEvenWhenTheServerCannotBeReached() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "live-access")
        harness.serve { _ in .failure(URLError(.cannotConnectToHost)) }

        let outcome = try await harness.service.signOut()

        #expect(outcome == .clearedLocallyOnly(.backendUnreachable))
        #expect(try harness.tokenStore.loadTokens() == nil)
        #expect(try await harness.client.restoredIdentity() == nil)
    }

    @Test
    func signingOutWhileOfflineSaysSoRatherThanNamingTheBackend() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "live-access")
        harness.serve { _ in .failure(URLError(.notConnectedToInternet)) }

        #expect(try await harness.service.signOut() == .clearedLocallyOnly(.offline))
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    /// A family that was already revoked is the state the user asked for, so this is a success and
    /// not a failure to report.
    @Test
    func signingOutOfAnAlreadyRevokedFamilyReportsSuccess() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "live-access")
        harness.serve { _ in
            .reply(
                statusCode: 401,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_revoked")
            )
        }

        #expect(try await harness.service.signOut() == .revoked)
        #expect(try harness.tokenStore.loadTokens() == nil)
    }

    @Test
    func signingOutWithNothingStoredSucceedsWithoutSendingARequest() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("request")
            return .reply(statusCode: 204, headers: [:], body: Data())
        }

        #expect(try await harness.service.signOut() == .revoked)
        #expect(counts.count("request") == 0)
    }

    /// **Sign-out is not "delete my local data" and not "reset the encryption identity."** Three
    /// actions, three blast radii (§3.3). The local files this asserts on are represented by their
    /// encryption key: if the key survives, every encrypted store on disk still opens.
    @Test
    func signingOutTouchesNeitherTheEncryptionKeyNorAnyLocalStoreFile() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "live-access")
        harness.serve { _ in .reply(statusCode: 204, headers: [:], body: Data()) }
        let keyBefore = harness.keychain.rawValue(
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        )

        _ = try await harness.service.signOut()

        #expect(harness.keychain.rawValue(
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        ) == keyBefore)
        #expect(harness.keychain.storedKeys.map(\.service) == [LocalStorageEncryptionKeyManager.defaultService])
        // The store that would delete local files is not reachable from here at all: nothing in
        // `SonnyAccountService` names `LocalDataDeletionService`, and this asserts the consequence —
        // the key those files are read with is exactly where it was.
        let manager = LocalStorageEncryptionKeyManager(secretStore: harness.keychain)
        #expect(try manager.keyData() == keyBefore)
    }

    // MARK: - Harness

    private struct Harness {
        let session: URLSession
        let baseURL: URL
        let host: String
        let keychain: InMemoryKeychainSecretStore
        let tokenStore: KeychainAccountTokenStore
        let client: SonnyBackendClient
        let service: SonnyAccountService

        init() throws {
            let stub = BackendStubURLProtocol.makeSession()
            session = stub.session
            baseURL = stub.baseURL
            host = stub.host
            keychain = InMemoryKeychainSecretStore()
            keychain.plant(
                Data(repeating: 0x53, count: 32),
                service: LocalStorageEncryptionKeyManager.defaultService,
                account: LocalStorageEncryptionKeyManager.defaultAccount
            )
            tokenStore = KeychainAccountTokenStore(secretStore: keychain)
            client = SonnyBackendClient(
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

        func signIn(accessToken: String) async throws {
            try await client.adopt(SonnyBackendFixtures.storedTokens(
                accessToken: accessToken,
                expiresAt: Date().addingTimeInterval(3600)
            ))
        }
    }
}
