import Foundation
import Testing
@testable import MacAgentCore

/// What the user is told when a call to Sonny's backend fails, on the four model routes.
///
/// **The one property that runs through all of it: a sentence never tells the user to retry
/// something a retry cannot fix** (PR #139, F7). §9.3 splits every code into two lists, and the
/// non-retryable list is not advice — "retrying any of these produces the identical failure and
/// burns a round trip". Three of those codes were reaching the shared "Try again." sentence, and one
/// of the three, `request.invalid`, is what this branch's own server answers a missing `retention`
/// with, so it was not a corner.
///
/// The other half of §7.1 is asserted here too: none of these sentences is the server's. The server
/// authors a `message` for logs and the support lookup, and a sentence written on the server and
/// rendered in the app is a hole through Sonny's standing rule that the product does not explain
/// itself, editable by whoever edits the server with no review from anyone who knows that rule.
struct SonnyBackendCopyTests {
    private static func apiError(
        _ code: SonnyBackendErrorCode,
        status: Int = 502,
        message: String = "Server-authored sentence the client must never display."
    ) -> SonnyBackendError {
        .api(SonnyBackendAPIError(
            code: code,
            statusCode: status,
            message: message,
            requestID: "req_copy",
            retryAfter: nil,
            envelopeSaysRetryable: false
        ))
    }

    @Test
    func aNonRetryableFailureNeverTellsTheUserToTryAgain() {
        // The three §9.3 calls not retryable that these routes can actually produce.
        for code in [
            SonnyBackendErrorCode.providerRejected,
            .requestInvalid,
            .requestTooLarge,
        ] {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code))
            #expect(
                !sentence.lowercased().contains("try again"),
                "\(code.wire) invites a retry that cannot work: \(sentence)"
            )
            #expect(!sentence.isEmpty)
        }
    }

    @Test
    func eachNonRetryableCodeGetsItsOwnSentenceRatherThanASharedOne() {
        // Distinct, because collapsing them is what F7 was: three different things the user might
        // do next, answered with one sentence that fitted none of them.
        let sentences = [
            SonnyBackendCopy.sentence(for: Self.apiError(.providerRejected)),
            SonnyBackendCopy.sentence(for: Self.apiError(.requestInvalid, status: 400)),
            SonnyBackendCopy.sentence(for: Self.apiError(.requestTooLarge, status: 413)),
        ]
        #expect(sentences == [
            "Sonny couldn't do this one.",
            "Sonny couldn't send this one.",
            "That was too big for Sonny to send in one go.",
        ])
        #expect(Set(sentences).count == 3)
    }

    @Test
    func aRetryableFailureDoesInviteARetry() {
        // The other direction, so the fix above cannot be satisfied by removing "try again" from
        // everything. §9.3's retryable list is where the instruction is true.
        for code in [
            SonnyBackendErrorCode.providerUnavailable,
            .providerTimeout,
            .serverError,
            .serverUnavailable,
        ] {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code))
            #expect(
                sentence.lowercased().contains("try again"),
                "\(code.wire) is retryable but says: \(sentence)"
            )
        }
    }

    @Test
    func everySentenceIsTheAppsOwnAndCarriesNothingFromTheServer() {
        // §7.1: the client never displays `message`. Checked across every code the taxonomy has,
        // rather than on the handful a test happened to think of.
        let secret = "SERVER-AUTHORED-SENTENCE-9137"
        // The same list `noSentenceNamesAProviderOrAnEnvironmentVariable` walks — one population,
        // so a code added to one test's reach is added to both (SONNY-136).
        for code in Self.everyWireCode {
            let sentence = SonnyBackendCopy.sentence(for: Self.apiError(code, message: secret))
            #expect(!sentence.contains(secret), "\(code.wire) leaked the server's message")
            // Nor the wire code, nor a status: neither is a thing to show a user.
            #expect(!sentence.contains(code.wire), "\(code.wire) leaked its own wire code")
            #expect(!sentence.contains("502"))
            #expect(!sentence.isEmpty)
        }
    }

    @Test
    func theTransportFailuresKeepTheirOwnDistinctSentences() {
        // `offline` and everything else are deliberately separate — §7.2 case 7 is the only entry
        // with no HTTP status, and the contract says why the distinction is load-bearing: the first
        // means everything local still works, the second means Sonny is up and this thing failed.
        #expect(
            SonnyBackendCopy.sentence(for: .offline)
                == "You're offline. Everything Sonny does on this Mac still works."
        )
        #expect(SonnyBackendCopy.sentence(for: .notSignedIn) == "Sign in to Sonny to run this.")
        #expect(
            SonnyBackendCopy.sentence(for: .backendNotConfigured)
                == "This build has no Sonny account service."
        )
        #expect(
            SonnyBackendCopy.sentence(for: .unreachable("DNS"))
                == "Sonny couldn't finish this one. Try again."
        )
        #expect(
            SonnyBackendCopy.sentence(for: .timedOut(after: 90))
                == "Sonny couldn't finish this one. Try again."
        )
        // And a timeout's own duration is not a thing to put in front of a user.
        #expect(!SonnyBackendCopy.sentence(for: .timedOut(after: 90)).contains("90"))
    }

    /// **SONNY-136's fourth requirement, as one table.** The ticket names four states a user can be
    /// in when the backend does not answer — not signed in; signed in but offline; the backend
    /// reachable and failing; and over a limit — and asks that each produce its own human message.
    ///
    /// **Asserted as a set as well as one by one, which is the half a per-case test cannot do.**
    /// Four `#expect`s on four literals all still pass if two of the literals are the same string,
    /// and "each produces its own" is exactly the property that would then be false. So the
    /// distinctness is checked directly.
    ///
    /// **`.unreachable` and a 5xx share the third state on purpose**, and the reason is
    /// `SignInFailure.backendUnreachable`'s own: "One case, because there is exactly one thing a
    /// user can do about all of them." A DNS failure, a refused connection and a `server.error` are
    /// different events and the same situation. The state that must stay separate is `offline`,
    /// because it is the only one where everything local still works, and telling a user the wrong
    /// one of those two is what §7.2 case 7 calls a real failure of the error-handling-is-UX rule.
    ///
    /// **The fifth row is what this build actually shows today.** `SonnyBackendHost.productionBaseURL`
    /// is still `nil`, so on a packaged app launched from Finder every backend call fails at
    /// `backendNotConfigured` before a URL is built — which is the state the founder's manual pass
    /// will meet until SONNY-192 chooses a host, and it is separate from all four.
    @Test
    func eachOfTheFourUnreachableStatesGetsItsOwnHumanSentence() {
        let notSignedIn = SonnyBackendCopy.sentence(for: .notSignedIn)
        let offline = SonnyBackendCopy.sentence(for: .offline)
        let failing = SonnyBackendCopy.sentence(for: Self.apiError(.serverError, status: 500))
        let overALimit = SonnyBackendCopy.sentence(for: Self.apiError(.limitRate, status: 429))

        #expect(notSignedIn == "Sign in to Sonny to run this.")
        #expect(offline == "You're offline. Everything Sonny does on this Mac still works.")
        #expect(failing == "Sonny couldn't finish this one. Try again.")
        #expect(overALimit == "Too many requests just now. Try again shortly.")

        #expect(
            Set([notSignedIn, offline, failing, overALimit]).count == 4,
            "the four states collapsed onto fewer than four sentences"
        )

        // The third state, reached the two other ways it can be reached — a transport failure and
        // this client's own timeout — answers the same sentence, deliberately.
        #expect(SonnyBackendCopy.sentence(for: .unreachable("connection refused")) == failing)
        #expect(SonnyBackendCopy.sentence(for: .timedOut(after: 120)) == failing)

        // A spend cap is over-a-limit too and is *not* the rate limit's sentence: only one of the
        // two clears by waiting, so only one may say so.
        let spend = SonnyBackendCopy.sentence(for: Self.apiError(.limitSpend, status: 429))
        #expect(spend == "You're out of allowance for this period.")
        #expect(spend != overALimit)

        // And the state this build is in until a host exists.
        let unconfigured = SonnyBackendCopy.sentence(for: .backendNotConfigured)
        #expect(unconfigured == "This build has no Sonny account service.")
        #expect(!Set([notSignedIn, offline, failing, overALimit]).contains(unconfigured))
    }

    /// No sentence the user can be shown names a model provider or an environment variable.
    ///
    /// **Founder decision, 2026-08-19, in his own words: "why mention OPENAI_API_KEY, because down
    /// the line we will have other providers as well."** SONNY-177 applied it to one constant;
    /// SONNY-136 removed the last strings that broke it — `PlannerError.missingAPIKey`,
    /// `TranscriptionError.missingAPIKey`, `TavilySearchError.missingAPIKey`,
    /// `VisionModelClientError.missingAPIKey`, and the readiness row's two halves — and this is
    /// where the rule now lives, over the whole population of sentences rather than over one of
    /// them.
    ///
    /// **The population is enumerated rather than sampled.** `SignInFailure` is `CaseIterable` and
    /// every wire code is listed here, so a code added later that maps to new words is covered the
    /// moment it is added to `SonnyBackendErrorCode`; the transport cases are listed explicitly
    /// because `SonnyBackendError` carries associated values and cannot be `CaseIterable`.
    ///
    /// The environment-variable check is a *shape* rather than a list of names: any
    /// `SCREAMING_SNAKE` token of two or more parts, so a sentence naming a variable this test has
    /// never heard of fails just the same.
    @Test
    func noSentenceNamesAProviderOrAnEnvironmentVariable() {
        let providers = ["OpenAI", "Cerebras", "Tavily", "OpenCode", "Anthropic", "GPT", "Whisper"]
        let variableShape = try! NSRegularExpression(pattern: "[A-Z][A-Z0-9]{2,}_[A-Z0-9_]{2,}")

        var sentences: [String] = SignInFailure.allCases.map(SignInCopy.message(for:))
        sentences.append(SignInCopy.codeNotArriving)
        sentences.append(SignInCopy.signedOutLocallyOnly)
        for transport: SonnyBackendError in [
            .offline, .unreachable("DNS"), .notSignedIn, .timedOut(after: 90), .cancelled,
            .undecodableResponse("body"), .backendNotConfigured,
        ] {
            sentences.append(SonnyBackendCopy.sentence(for: transport))
        }
        for code in Self.everyWireCode {
            sentences.append(SonnyBackendCopy.sentence(for: Self.apiError(code)))
        }
        // The scan is worthless if the list came back short; §7.2 alone has more than a dozen cases.
        #expect(sentences.count > 30, "only \(sentences.count) sentences were collected")

        for sentence in sentences {
            #expect(!sentence.isEmpty)
            for provider in providers {
                #expect(
                    !sentence.localizedCaseInsensitiveContains(provider),
                    "\"\(sentence)\" names \(provider)"
                )
            }
            let range = NSRange(sentence.startIndex..., in: sentence)
            #expect(
                variableShape.firstMatch(in: sentence, range: range) == nil,
                "\"\(sentence)\" carries an environment-variable-shaped token"
            )
        }
    }

    /// Every code the taxonomy has. Shared by the two tests that need the whole population rather
    /// than the handful either happened to think of.
    private static let everyWireCode: [SonnyBackendErrorCode] = [
        .authUnauthenticated, .authTokenExpired, .authTokenRevoked, .authCodeInvalid,
        .authCodeExpired, .authCodeUsed, .entitlementRequired, .entitlementExpired,
        .limitRate, .limitSpend, .requestInvalid, .requestTooLarge, .providerUnavailable,
        .providerTimeout, .providerRejected, .serverError, .serverUnavailable,
        .resourceNotFound, .idempotencyConflict, .versionUnsupported, .unknown("brand.new"),
    ]

    @Test
    func aRateLimitAndASpendCapSayDifferentThingsBecauseOnlyOneClearsByWaiting() {
        // §7.2 cases 3 and 3a. A spend cap carries no `Retry-After` precisely because waiting
        // seconds does not fix it, so "try again shortly" would be false for it.
        let rate = SonnyBackendCopy.sentence(for: Self.apiError(.limitRate, status: 429))
        let spend = SonnyBackendCopy.sentence(for: Self.apiError(.limitSpend, status: 429))
        #expect(rate == "Too many requests just now. Try again shortly.")
        #expect(spend == "You're out of allowance for this period.")
        #expect(!spend.lowercased().contains("try again"))
    }
}
