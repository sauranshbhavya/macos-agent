import Foundation
import MacAgentTestSupport
import Testing
@testable import MacAgentCore

/// The shared backend HTTP client: headers, timeouts, retry, and the single-flight refresh guard.
///
/// Fixture-backed only — nothing here reaches a network or a real Keychain. Each test gets its own
/// stub host, so the suite runs in parallel with everything else rather than being serialized on a
/// shared handler the way the six provider-client suites are.
@Suite
struct SonnyBackendClientTests {
    // MARK: - Request shape

    @Test
    func everyRequestCarriesTheContractsIdentifyingHeadersAndJoinsTheBaseURLToThePath() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let key = UUID()

        _ = try await harness.client.send(SonnyBackendRequest(
            method: "POST",
            path: "/v1/auth/email/start",
            body: Data(#"{"email":"a@b.c"}"#.utf8),
            authentication: .none,
            idempotencyKey: key,
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        ))

        let request = try #require(seen.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "\(harness.baseURL.absoluteString)/v1/auth/email/start")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(request.value(forHTTPHeaderField: "Sonny-Client-Version") == "9.9+42")
        #expect(request.value(forHTTPHeaderField: "Sonny-Platform") == "macos/26.5.2")
        // §2.2 and §4.1: the three unauthenticated auth routes carry no Authorization header at
        // all. Attaching one to a call made before the client has a token is the specific mistake
        // the contract restates its `Auth` column to prevent.
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(BackendStubURLProtocol.bodyJSON(of: request)["email"] as? String == "a@b.c")
    }

    /// **`Accept-Encoding` is deliberately not set by hand**, though §2.2 asks that every request
    /// include gzip. URLSession sets it and decompresses transparently; setting it here switches
    /// that off. What the test can check is that this client did not set it.
    @Test
    func theClientDoesNotSetAcceptEncodingItself() async throws {
        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try await harness.client.send(harness.publicRequest())

        let request = try #require(seen.recorded.first)
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == nil)
    }

    @Test
    func aBearerRequestCarriesTheStoredAccessTokenAndAnUnauthenticatedOneDoesNot() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "stored-access", expiresIn: 3600)
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try await harness.client.send(harness.bearerRequest())
        _ = try await harness.client.send(harness.publicRequest())

        #expect(seen.recorded.count == 2)
        #expect(seen.recorded[0].value(forHTTPHeaderField: "Authorization") == "Bearer stored-access")
        #expect(seen.recorded[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// §3.1: "the client must not decode, inspect or make any decision from" the access token. Since
    /// Supabase made it a JWT, that is a contract obligation rather than something the encoding
    /// enforces — so the direct check is that a token which is *not* a JWT works unchanged.
    @Test
    func anAccessTokenThatIsNotAJWTIsSentVerbatim() async throws {
        let harness = try Harness()
        let opaque = "not.a.jwt-just-an-opaque-string-\u{1F510}"
        try await harness.signIn(accessToken: opaque, expiresIn: 3600)
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try await harness.client.send(harness.bearerRequest())

        #expect(seen.recorded.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(opaque)")
    }

    // MARK: - Single-flight refresh

    /// **The acceptance criterion, asserted as a count.** §3.3: ten concurrent 401s cause one
    /// refresh and not ten, because the server rotates on every use and a second refresh presenting
    /// a token the first already rotated away — past the platform's ten-second overlap — is read as
    /// theft and revokes the whole family.
    @Test
    func tenConcurrent401sCauseExactlyOneRefreshAndEveryRequestThenSucceeds() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "expired-access", expiresIn: 3600)
        let counts = StubCounter()
        // Holds all ten protected requests until every one has arrived, so their 401s are raised
        // together. It cannot make this test fail: the assertion below holds whether the burst
        // overlapped or arrived one at a time, and the barrier only widens the window the guard has
        // to survive.
        let barrier = StubBarrier(expected: 10)

        harness.serve { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                counts.increment("refresh")
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.tokenResponseJSON(
                        accessToken: "fresh-access",
                        refreshToken: "rotated-refresh"
                    )
                )
            default:
                let attempt = counts.increment("protected")
                if attempt <= 10 {
                    barrier.arriveAndWait()
                    return .reply(
                        statusCode: 401,
                        headers: [:],
                        body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
                    )
                }
                return .reply(statusCode: 200, headers: [:], body: Data(#"{"ok":true}"#.utf8))
            }
        }

        let responses = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<10 {
                group.addTask { try await harness.client.send(harness.bearerRequest()).statusCode }
            }
            var collected: [Int] = []
            for try await status in group { collected.append(status) }
            return collected
        }

        #expect(responses == Array(repeating: 200, count: 10))
        #expect(counts.count("refresh") == 1)
        // Ten first attempts plus ten retries: every request was sent again after the one refresh.
        #expect(counts.count("protected") == 20)
    }

    /// **The straggler the generation counter exists for, and the case an "is a refresh running"
    /// flag cannot see.** Two requests both read the same token. One is refused, refreshes, and
    /// finishes completely — so nothing is in flight any more. The other's 401, raised against the
    /// token it read *before* that refresh, arrives only then. A flag-only guard finds nothing
    /// running and starts a second refresh, which presents a token the first already rotated away:
    /// past the platform's ten-second overlap the server reads that as theft and revokes the whole
    /// family (§3.3).
    ///
    /// **The ordering is enforced rather than hoped for**, and that matters — an earlier version of
    /// this test raced instead, and a mutant that replaced the generation check with `false`
    /// survived it, because the straggler happened to arrive while the first refresh's task was
    /// still parked on the actor. Here the first request is `await`ed to completion before the
    /// straggler's reply is released, so the in-flight task is provably gone. The waits poll with a
    /// backstop and the test asserts the backstop did not fire.
    @Test
    func aStragglers401RaisedAgainstAnAlreadyRefreshedTokenDoesNotRefreshAgain() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "expired-access", expiresIn: 3600)
        let counts = StubCounter()
        let releaseStraggler = StubSignal()
        let stragglerWasReleased = StubCounter()

        harness.serve { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                counts.increment("refresh")
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "fresh-access")
                )
            case "/v1/protected-straggler":
                let attempt = counts.increment("straggler")
                guard attempt == 1 else {
                    return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
                }
                if releaseStraggler.waitUntilSignalled() { stragglerWasReleased.increment("released") }
                return .reply(
                    statusCode: 401,
                    headers: [:],
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
                )
            default:
                let attempt = counts.increment("first")
                guard attempt == 1 else {
                    return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
                }
                return .reply(
                    statusCode: 401,
                    headers: [:],
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
                )
            }
        }

        async let straggler: Void = {
            _ = try await harness.client.send(SonnyBackendRequest(
                method: "GET", path: "/v1/protected-straggler", body: nil, authentication: .bearer,
                idempotencyKey: nil, timeout: SonnyBackendTimeouts.auth, isRetrySafe: true
            ))
        }()

        // The straggler has reached the stub, so it is already holding the pre-refresh token.
        let stragglerIsHolding = await pollUntil { counts.count("straggler") == 1 }
        #expect(stragglerIsHolding, "the straggler never reached the stub")

        // Awaited to completion: the refresh is finished and its in-flight task is gone.
        _ = try await harness.client.send(harness.bearerRequest())
        #expect(counts.count("refresh") == 1)

        releaseStraggler.signal()
        try await straggler

        #expect(stragglerWasReleased.count("released") == 1, "the straggler's wait timed out instead of being released")
        // Still one. The straggler saw a newer generation than the one it used and retried with it
        // rather than asking for another rotation.
        #expect(counts.count("refresh") == 1)
        #expect(counts.count("first") == 2)
        #expect(counts.count("straggler") == 2)
    }

    /// Two expiries that never overlap are two genuine refreshes. Here so that the guard above
    /// cannot be satisfied by a client that simply refuses to refresh twice ever.
    @Test
    func twoSeparateExpiriesInSequenceEachGetTheirOwnRefresh() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "expired-access", expiresIn: 3600)
        let counts = StubCounter()
        harness.serve { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                counts.increment("refresh")
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "fresh-access")
                )
            default:
                let attempt = counts.increment("protected")
                // First call of each of the two sequential requests gets the 401; the retries pass.
                return attempt == 1 || attempt == 3
                    ? .reply(
                        statusCode: 401,
                        headers: [:],
                        body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
                    )
                    : .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
        }

        _ = try await harness.client.send(harness.bearerRequest())
        // The second request's 401 is raised long after the first refresh completed. The token it
        // used is the already-refreshed one, so this 401 is a genuine second expiry and refreshes.
        _ = try await harness.client.send(harness.bearerRequest())

        #expect(counts.count("refresh") == 2)
        #expect(counts.count("protected") == 4)
    }

    /// **The rotated session reaches the Keychain before the retried request is sent.** A crash
    /// between receiving a new refresh token and writing it is what §3.3's overlap window exists to
    /// survive; writing first makes that window as small as the code can make it.
    @Test
    func theRotatedSessionIsInTheKeychainBeforeTheRetriedRequestGoesOut() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "expired-access", refreshToken: "refresh-0", expiresIn: 3600)
        let counts = StubCounter()
        let keychainAtRetry = RecordedStrings()

        harness.serve { request in
            switch request.url?.path {
            case "/v1/auth/refresh":
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.tokenResponseJSON(
                        accessToken: "fresh-access",
                        refreshToken: "rotated-refresh"
                    )
                )
            default:
                let attempt = counts.increment("protected")
                if attempt == 1 {
                    return .reply(
                        statusCode: 401,
                        headers: [:],
                        body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
                    )
                }
                // Read the Keychain from inside the retry, before the client can do anything else.
                keychainAtRetry.record(harness.storedSessionJSON())
                return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }
        }

        _ = try await harness.client.send(harness.bearerRequest())

        let onDiskDuringRetry = try #require(keychainAtRetry.recorded.first)
        #expect(onDiskDuringRetry.contains("rotated-refresh"))
        #expect(onDiskDuringRetry.contains("fresh-access"))
        #expect(!onDiskDuringRetry.contains("refresh-0"))
    }

    @Test
    func aTokenInsideTheProactiveMarginIsRefreshedBeforeTheRequestRatherThanAfterA401() async throws {
        let harness = try Harness()
        // 60 seconds of life left, well inside the 180-second margin.
        try await harness.signIn(accessToken: "nearly-expired", expiresIn: 60)
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            if request.url?.path == "/v1/auth/refresh" {
                return .reply(
                    statusCode: 200,
                    headers: [:],
                    body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "fresh-access")
                )
            }
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try await harness.client.send(harness.bearerRequest())

        #expect(seen.recorded.map { $0.url?.path } == ["/v1/auth/refresh", "/v1/protected"])
        #expect(seen.recorded.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
        // Not a 401 in sight: the refresh happened because expiry was near, not because a request
        // was refused.
        #expect(seen.recorded.count == 2)
    }

    /// The margin is derived, not picked: it has to exceed the longest client timeout in §12's
    /// table, or a request that is allowed to start can be holding a token that expires mid-flight.
    @Test
    func theProactiveRefreshMarginExceedsTheLongestClientTimeoutInTheContract() {
        let longestClientTimeoutInSection12: TimeInterval = 120
        #expect(SonnyBackendClient.proactiveRefreshMargin > longestClientTimeoutInSection12)
        #expect(SonnyBackendClient.proactiveRefreshMargin == 180)
    }

    /// §3.5: expiry arithmetic runs in server time, from the `Date` header, because the user can
    /// change their own clock. A Mac running two hours slow must not decide a live token is stale.
    @Test
    func expiryIsJudgedAgainstTheServerClockAndNotTheLocalOne() async throws {
        let serverNow = Date(timeIntervalSince1970: 1_800_000_000)
        // This Mac believes it is two hours earlier than the server does.
        let harness = try Harness(now: { serverNow.addingTimeInterval(-7200) })
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(
                statusCode: 200,
                headers: ["Date": SonnyHTTPDate.formatter.string(from: serverNow)],
                body: SonnyBackendFixtures.tokenResponseJSON(accessToken: "issued", expiresIn: 3600)
            )
        }
        // One call teaches the client the offset and stores a token expiring an hour of SERVER time
        // from now. Judged on the local clock it would look like it expires in three hours, which
        // is not the error this catches; judged on a clock two hours FAST it would look expired.
        _ = try await harness.verifyThroughService()
        let afterSignIn = seen.recorded.count

        _ = try await harness.client.send(harness.bearerRequest())

        // No refresh: an hour of server-time life is outside the 180-second margin.
        #expect(seen.recorded.count == afterSignIn + 1)
        #expect(seen.recorded.last?.url?.path == "/v1/protected")
    }

    // MARK: - Timeouts

    /// The acceptance criterion: a hanging server produces a typed timeout, not an indefinite
    /// spinner. Asserted on the *type* rather than on elapsed milliseconds — a test that bets on a
    /// wall-clock window is the shape `CLAUDE.md` records as manufacturing mutation kills. A slow
    /// machine makes this test slower, never wrong.
    @Test
    func aHangingServerProducesATypedTimeoutRatherThanAnIndefiniteWait() async throws {
        let harness = try Harness()
        harness.serve { _ in .hang }

        await #expect(throws: SonnyBackendError.timedOut(after: 0.4)) {
            _ = try await harness.client.send(SonnyBackendRequest(
                method: "GET",
                path: "/v1/protected",
                body: nil,
                authentication: .none,
                idempotencyKey: nil,
                timeout: 0.4,
                isRetrySafe: false
            ))
        }
    }

    /// The other half of the same criterion: the number the contract fixes is the number that
    /// actually reaches the request. §12's last row — auth, account, meta, health, delete — is a
    /// 15-second server total deadline and a 20-second client timeout.
    @Test
    func theAuthRoutesUseTheContractsTwentySecondTimeoutAndItReachesTheURLRequest() async throws {
        #expect(SonnyBackendTimeouts.auth == 20)

        let harness = try Harness()
        let seen = RecordedRequests()
        harness.serve { request in
            seen.record(request)
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        _ = try await harness.client.send(harness.publicRequest())

        #expect(seen.recorded.first?.timeoutInterval == 20)
    }

    /// A transport timeout has already spent the route's whole budget. Retrying doubles a wait the
    /// user is watching, so it is not retried even though the request is retry-safe.
    @Test
    func aTransportTimeoutIsNotRetried() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .failure(URLError(.timedOut))
        }

        await #expect(throws: SonnyBackendError.timedOut(after: 20)) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        #expect(counts.count("attempt") == 1)
    }

    // MARK: - Retry

    /// §7.2 does not ask for one ceiling: `limit.rate` and `provider.timeout` are retried once,
    /// `server.error` and its neighbours are retried with backoff and then given up on, and
    /// `provider.rejected` is a 502 whose retry is guaranteed to fail identically.
    @Test(arguments: [
        ("limit.rate", 2),
        ("provider.timeout", 2),
        ("server.error", 3),
        ("server.unavailable", 3),
        ("provider.unavailable", 3),
        ("provider.rejected", 1),
        ("request.invalid", 1),
        ("entitlement.required", 1),
        ("limit.spend", 1)
    ])
    func aFailureIsSentExactlyAsManyTimesAsItsCodeAllows(code: String, expectedAttempts: Int) async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .reply(
                statusCode: 500,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: code, retryable: true)
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        #expect(counts.count("attempt") == expectedAttempts)
    }

    /// **The envelope's own `retryable` flag does not decide.** §9.3 makes `code` the decision, and
    /// a server that sent `retryable: true` on `provider.rejected` — a code whose retry is
    /// guaranteed to fail identically — must not turn into a retry loop in the client.
    @Test
    func anUnretryableCodeIsNotRetriedEvenWhenTheEnvelopeClaimsItIs() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .reply(
                statusCode: 502,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "provider.rejected", retryable: true)
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        #expect(counts.count("attempt") == 1)
    }

    /// §9.3: `POST /v1/auth/email/verify` is not safe to retry, because a code is single-use. A
    /// request that says so is sent once whatever the failure was.
    @Test
    func aRequestThatIsNotRetrySafeIsSentOnceEvenOnARetryableCode() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .reply(
                statusCode: 500,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "server.error", retryable: true)
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(SonnyBackendRequest(
                method: "POST",
                path: "/v1/auth/email/verify",
                body: Data("{}".utf8),
                authentication: .none,
                idempotencyKey: UUID(),
                timeout: SonnyBackendTimeouts.auth,
                isRetrySafe: false
            ))
        }
        #expect(counts.count("attempt") == 1)
    }

    @Test
    func aRetryAfterTheServerSentReplacesTheComputedBackoff() async throws {
        let sleeps = RecordedSleeps()
        let harness = try Harness(sleeps: sleeps)
        harness.serve { _ in
            .reply(
                statusCode: 429,
                headers: ["Retry-After": "17"],
                body: SonnyBackendFixtures.errorEnvelopeJSON(
                    code: "limit.rate",
                    retryable: true,
                    retryAfterSeconds: 17
                )
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        // One retry for `limit.rate`, waiting exactly what the server asked for rather than the
        // 0.5-second first backoff step.
        #expect(sleeps.recorded == [17])
    }

    @Test
    func backoffGrowsBetweenAttemptsWhenTheServerNamesNoDelay() async throws {
        let sleeps = RecordedSleeps()
        let harness = try Harness(sleeps: sleeps)
        harness.serve { _ in
            .reply(
                statusCode: 500,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "server.error", retryable: true)
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        // Jitter is pinned to zero in the harness, so these are the bare 0.5 × 2^n steps.
        #expect(sleeps.recorded == [0.5, 1.0])
    }

    /// §9.3's single exception to deciding on `code`: a response with no parseable body at all is
    /// treated as `server.error`, which is retryable.
    @Test
    func aFailureWithNoReadableBodyIsTreatedAsARetryableServerError() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .reply(statusCode: 503, headers: [:], body: Data("<html>gateway</html>".utf8))
        }

        do {
            _ = try await harness.client.send(harness.publicRequest())
            Issue.record("expected the request to fail")
        } catch let error as SonnyBackendError {
            guard case .api(let api) = error else {
                Issue.record("expected an API error, got \(error)")
                return
            }
            #expect(api.code == .serverError)
            #expect(api.statusCode == 503)
        }
        #expect(counts.count("attempt") == 3)
    }

    // MARK: - Revocation

    /// §7.2 case 1b: a revoked or reused token means the family is gone, and the client's stated
    /// response is to clear the Keychain entry and send the user to sign-in — so a dead session does
    /// not sit on disk pretending to be one.
    @Test
    func aRevokedRefreshTokenClearsTheKeychainAndIsNotRetried() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "expired-access", expiresIn: 3600)
        #expect(harness.keychainHoldsASession)
        let counts = StubCounter()

        harness.serve { request in
            if request.url?.path == "/v1/auth/refresh" {
                counts.increment("refresh")
                return .reply(
                    statusCode: 401,
                    headers: [:],
                    body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_revoked")
                )
            }
            counts.increment("protected")
            return .reply(
                statusCode: 401,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.token_expired")
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.bearerRequest())
        }

        #expect(counts.count("refresh") == 1)
        #expect(harness.keychainHoldsASession == false)
        // And the local-storage encryption key is untouched: three actions, three blast radii.
        #expect(harness.keychainHoldsTheEncryptionKey)
    }

    @Test
    func aBearerRequestRefusedAsUnauthenticatedClearsTheStoredSession() async throws {
        let harness = try Harness()
        try await harness.signIn(accessToken: "access", expiresIn: 3600)
        harness.serve { _ in
            .reply(
                statusCode: 401,
                headers: [:],
                body: SonnyBackendFixtures.errorEnvelopeJSON(code: "auth.unauthenticated")
            )
        }

        await #expect(throws: SonnyBackendError.self) {
            _ = try await harness.client.send(harness.bearerRequest())
        }

        #expect(harness.keychainHoldsASession == false)
    }

    @Test
    func aBearerRequestWithNoStoredSessionNeverLeavesTheMachine() async throws {
        let harness = try Harness()
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .reply(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        await #expect(throws: SonnyBackendError.notSignedIn) {
            _ = try await harness.client.send(harness.bearerRequest())
        }
        #expect(counts.count("attempt") == 0)
    }

    // MARK: - Transport failures

    /// §7.2 case 7 is the only entry with no HTTP status, and telling a user the wrong one of
    /// "you are offline" and "Sonny is up and this failed" is a real failure of the
    /// error-handling-is-UX rule. So the two are separate cases, and only a genuinely absent
    /// network is `offline`.
    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, true),
        (URLError.Code.networkConnectionLost, true),
        (URLError.Code.cannotFindHost, false),
        (URLError.Code.secureConnectionFailed, false),
        (URLError.Code.cannotConnectToHost, false)
    ])
    func onlyAMissingNetworkIsReportedAsOffline(code: URLError.Code, isOffline: Bool) async throws {
        let harness = try Harness()
        harness.serve { _ in .failure(URLError(code)) }

        do {
            _ = try await harness.client.send(harness.publicRequest())
            Issue.record("expected the request to fail")
        } catch let error as SonnyBackendError {
            #expect((error == .offline) == isOffline, "\(code) mapped to \(error)")
        }
    }

    @Test
    func aMissingNetworkIsRetriedOnceAndThenReported() async throws {
        let sleeps = RecordedSleeps()
        let harness = try Harness(sleeps: sleeps)
        let counts = StubCounter()
        harness.serve { _ in
            counts.increment("attempt")
            return .failure(URLError(.notConnectedToInternet))
        }

        await #expect(throws: SonnyBackendError.offline) {
            _ = try await harness.client.send(harness.publicRequest())
        }
        #expect(counts.count("attempt") == 2)
        #expect(sleeps.recorded == [0.5])
    }

    @Test
    func aClientWithNoConfiguredHostRefusesBeforeBuildingARequest() async throws {
        let client = SonnyBackendClient(
            environment: nil,
            tokenStore: KeychainAccountTokenStore(secretStore: InMemoryKeychainSecretStore())
        )

        #expect(await client.isConfigured == false)
        await #expect(throws: SonnyBackendError.backendNotConfigured) {
            _ = try await client.send(SonnyBackendRequest(
                method: "GET", path: "/v1/health", body: nil, authentication: .none,
                idempotencyKey: nil, timeout: 1, isRetrySafe: false
            ))
        }
    }

    // MARK: - URL joining

    @Test(arguments: [
        ("https://example.com", "/v1/auth/refresh", "https://example.com/v1/auth/refresh"),
        ("https://example.com/", "/v1/auth/refresh", "https://example.com/v1/auth/refresh"),
        ("http://127.0.0.1:8080", "v1/health", "http://127.0.0.1:8080/v1/health"),
        ("https://example.com/gateway", "/v1/health", "https://example.com/gateway/v1/health")
    ])
    func theBaseURLAndThePathJoinWithoutEitherEndHavingToAgreeAboutSlashes(
        base: String,
        path: String,
        expected: String
    ) throws {
        let baseURL = try #require(URL(string: base))
        #expect(SonnyBackendClient.url(base: baseURL, path: path).absoluteString == expected)
    }
}

// MARK: - Harness

/// One stub host, one in-memory Keychain, one client — with the encryption key already present so
/// every test can check that signing out and revocation leave it alone.
private struct Harness {
    let session: URLSession
    let baseURL: URL
    let host: String
    let keychain: InMemoryKeychainSecretStore
    let tokenStore: KeychainAccountTokenStore
    let client: SonnyBackendClient

    init(
        now: (@Sendable () -> Date)? = nil,
        sleeps: RecordedSleeps = RecordedSleeps()
    ) throws {
        let stub = BackendStubURLProtocol.makeSession()
        session = stub.session
        baseURL = stub.baseURL
        host = stub.host
        keychain = InMemoryKeychainSecretStore()
        // The other Keychain account this Mac holds. Planted in every harness so that any test
        // asserting a delete stayed inside its own service is asserting against a store that
        // actually has something else in it.
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
            clientVersion: "9.9+42",
            platform: "macos/26.5.2",
            now: now ?? { Date() },
            jitterFraction: { 0 },
            sleepForRetry: { seconds in sleeps.record(seconds) }
        )
    }

    func serve(_ handler: @escaping BackendStubURLProtocol.Handler) {
        BackendStubURLProtocol.register(host: host, handler: handler)
    }

    func publicRequest() -> SonnyBackendRequest {
        SonnyBackendRequest(
            method: "GET",
            path: "/v1/public",
            body: nil,
            authentication: .none,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        )
    }

    func bearerRequest() -> SonnyBackendRequest {
        SonnyBackendRequest(
            method: "GET",
            path: "/v1/protected",
            body: nil,
            authentication: .bearer,
            idempotencyKey: nil,
            timeout: SonnyBackendTimeouts.auth,
            isRetrySafe: true
        )
    }

    /// Plants a session the way a real sign-in would leave one: through the store, not by hand.
    func signIn(
        accessToken: String,
        refreshToken: String = "refresh-0",
        expiresIn: TimeInterval
    ) async throws {
        try await client.adopt(SonnyBackendFixtures.storedTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        ))
    }

    func verifyThroughService() async throws -> SonnyAccountIdentity {
        try await SonnyAccountService(client: client).verifyEmailCode(
            email: SonnyBackendFixtures.email,
            code: "123456"
        )
    }

    var keychainHoldsASession: Bool {
        keychain.contains(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        )
    }

    var keychainHoldsTheEncryptionKey: Bool {
        keychain.contains(
            service: LocalStorageEncryptionKeyManager.defaultService,
            account: LocalStorageEncryptionKeyManager.defaultAccount
        )
    }

    func storedSessionJSON() -> String {
        let data = keychain.rawValue(
            service: KeychainAccountTokenStore.defaultService,
            account: KeychainAccountTokenStore.defaultAccount
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// Poll a condition rather than sleep for a fixed span and hope. Returns whether it ever held, so
/// a caller asserts the backstop did not fire — a wait that timed out and carried on is how a test
/// passes by accident.
private func pollUntil(
    backstop: TimeInterval = 10,
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(backstop)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return condition()
}

final class RecordedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}
