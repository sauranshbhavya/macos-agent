import Foundation
import Testing
@testable import MacAgentCore

/// The words the sign-in flow shows, asserted literally.
///
/// Two rules are being held here at once. §7.1: the client never displays the server's `message`,
/// because a sentence authored on the server and rendered in the app is editable by whoever edits
/// the server with no review from anyone who knows Sonny's copy rules. And the founder's standing
/// rule since 2026-08-14: functional labels, not explanation — no how-it-works sentences, no
/// privacy explainer, no disclosure prose.
@Suite
struct SignInCopyTests {
    /// **The five cases the ticket's sixth requirement names, each with its own words.** The fifth
    /// is a state rather than a failure — no code arrived, so nothing failed and nothing will report
    /// anything — which is why it is a line the code step always shows rather than an error.
    @Test
    func theFiveCasesTheTicketNamesEachHaveTheirOwnWords() {
        #expect(SignInCopy.codeNotArriving == "No code yet? Send a new one, or use a different address.")
        #expect(SignInCopy.message(for: .codeIncorrect) == "That code isn't right. Check it and try again.")
        #expect(SignInCopy.message(for: .codeExpired) == "That code has expired. Send a new one.")
        #expect(SignInCopy.message(for: .offline) == "You're offline. Reconnect and try again.")
        #expect(SignInCopy.message(for: .backendUnreachable) == "Sonny can't be reached right now. Try again in a moment.")

        let five = [
            SignInCopy.codeNotArriving,
            SignInCopy.message(for: .codeIncorrect),
            SignInCopy.message(for: .codeExpired),
            SignInCopy.message(for: .offline),
            SignInCopy.message(for: .backendUnreachable)
        ]
        #expect(Set(five).count == 5, "two of the five cases say the same thing: \(five)")
    }

    @Test
    func theOtherReachableFailuresAlsoHaveTheirOwnWords() {
        #expect(SignInCopy.message(for: .emailInvalid) == "That doesn't look like an email address.")
        #expect(SignInCopy.message(for: .codeAlreadyUsed) == "That code has already been used. Send a new one.")
        #expect(SignInCopy.message(for: .tooManyAttempts) == "Too many attempts. Try again in a few minutes.")
        // **A spend cap is not a rate limit and must not borrow its sentence** (PR #133, F9). §7.2
        // case 3a gives `limit.spend` no `Retry-After` precisely because waiting does not fix it,
        // so "try again in a few minutes" would be a false promise the moment SONNY-130 or
        // SONNY-136 reuse this mapping.
        #expect(SignInCopy.message(for: .outOfAllowance) == "You've used up this period's allowance.")
        #expect(!SignInCopy.message(for: .outOfAllowance).contains("Try again"))
        #expect(SignInCopy.message(for: .notConfigured) == "Sign-in isn't available in this build.")
        #expect(SignInCopy.message(for: .signedOut) == "You're signed out. Sign in again.")
        #expect(SignInCopy.message(for: .updateRequired) == "This version of Sonny is too old. Update to carry on.")
        // Never "try again": a `410 version.unsupported` is not retryable and never becomes so by
        // waiting, which is the whole reason it stopped falling through to `.unexpected`.
        #expect(!SignInCopy.message(for: .updateRequired).contains("Try again"))
        #expect(SignInCopy.message(for: .unexpected) == "Sonny couldn't finish signing you in. Try again.")
        #expect(SignInCopy.signedOutLocallyOnly == "Signed out on this Mac. Sonny couldn't finish signing you out everywhere.")
    }

    @Test
    func everyFailureHasADistinctMessage() {
        let all = Self.everyFailure.map(SignInCopy.message(for:))
        #expect(Set(all).count == Self.everyFailure.count, "duplicated wording across cases: \(all)")
    }

    /// The population is the enum's own, so a case added later is covered by every test above
    /// without anyone remembering to add it. A floor rather than an equality: cases get added, and
    /// the exact number is not the property under test — that the list is not a stale literal is.
    @Test
    func theCopyTestsPopulationIsTheEnumsOwn() {
        #expect(Self.everyFailure.count == SignInFailure.allCases.count)
        #expect(Self.everyFailure.count >= 11)
        #expect(Set(Self.everyFailure).count == Self.everyFailure.count)
        #expect(Self.everyFailure.contains(.outOfAllowance))
    }

    /// **The server's own sentence never reaches the user.** Every failure below is built from a
    /// real envelope carrying a distinctive server message; none of the client's words contains it.
    @Test
    func noMessageEverRepeatsTheServersOwnSentence() {
        let serverSentence = "Screen control requires an active plan."
        for code in Self.everyWireCode {
            let failure = SignInFailure(.api(SonnyBackendAPIError(
                code: SonnyBackendErrorCode(wire: code),
                statusCode: 400,
                message: serverSentence,
                requestID: "req_1",
                retryAfter: nil,
                envelopeSaysRetryable: false
            )))
            #expect(!SignInCopy.message(for: failure).contains(serverSentence), "\(code) leaked the server's message")
        }
    }

    /// None of these is an explainer and none of them is a raw error: no status codes, no header
    /// names, no vendor names, and nothing about tokens or JSON.
    @Test
    func noMessageSurfacesRawFailureDetailOrExplainsHowSonnyWorks() {
        let banned = [
            "token", "Token", "JWT", "HTTP", "401", "403", "429", "500", "502", "503",
            "JSON", "Keychain", "Supabase", "OpenAI", "endpoint", "API", "null", "Error",
            "spam", "junk folder"
        ]
        let everySentence = Self.everyFailure.map(SignInCopy.message(for:))
            + [SignInCopy.codeNotArriving, SignInCopy.signedOutLocallyOnly]
        for sentence in everySentence {
            for word in banned {
                #expect(!sentence.contains(word), "\"\(sentence)\" contains \(word)")
            }
        }
    }

    @Test
    func everySentenceIsOneOrTwoShortSentencesRatherThanAParagraph() {
        let everySentence = Self.everyFailure.map(SignInCopy.message(for:))
            + [SignInCopy.codeNotArriving, SignInCopy.signedOutLocallyOnly]
        for sentence in everySentence {
            #expect(sentence.count <= 90, "\"\(sentence)\" is \(sentence.count) characters")
            #expect(sentence == sentence.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Mapping

    @Test(arguments: [
        ("auth.code_invalid", SignInFailure.codeIncorrect),
        ("auth.code_expired", SignInFailure.codeExpired),
        ("auth.code_used", SignInFailure.codeAlreadyUsed),
        ("limit.rate", SignInFailure.tooManyAttempts),
        ("limit.spend", SignInFailure.outOfAllowance),
        ("request.invalid", SignInFailure.emailInvalid),
        ("auth.unauthenticated", SignInFailure.signedOut),
        ("auth.token_expired", SignInFailure.signedOut),
        ("auth.token_revoked", SignInFailure.signedOut),
        ("provider.unavailable", SignInFailure.backendUnreachable),
        ("provider.timeout", SignInFailure.backendUnreachable),
        ("provider.rejected", SignInFailure.backendUnreachable),
        ("server.error", SignInFailure.backendUnreachable),
        ("server.unavailable", SignInFailure.backendUnreachable),
        ("entitlement.required", SignInFailure.unexpected),
        // **`version.unsupported` used to be in the arm above and is a named failure now**
        // (SONNY-402). `server/src/version/gate.ts` is registered before the auth gate and covers
        // every route, so this refusal really does arrive on the three unauthenticated sign-in
        // routes — and `.unexpected`'s sentence invites a retry of the one code §9.3 defines as
        // permanent. Its words are `ClientVersionCopy`'s, because the same build meets the same wall
        // in the widget and in Command Center.
        ("version.unsupported", SignInFailure.updateRequired),
        ("something.new_in_a_later_version", SignInFailure.unexpected)
    ])
    func everyBackendCodeMapsToOneNamedFailure(code: String, expected: SignInFailure) {
        let error = SonnyBackendError.api(SonnyBackendAPIError(
            code: SonnyBackendErrorCode(wire: code),
            statusCode: 400,
            message: "irrelevant",
            requestID: nil,
            retryAfter: nil,
            envelopeSaysRetryable: false
        ))
        #expect(SignInFailure(error) == expected)
    }

    /// §7.2 case 7's distinction, from the client's side: "you are offline" and "Sonny is up and
    /// this failed" are different things and the contract says telling a user the wrong one is a
    /// real failure of the error-handling-is-UX rule.
    @Test(arguments: [
        (SonnyBackendError.offline, SignInFailure.offline),
        (SonnyBackendError.unreachable("URLError -1004"), SignInFailure.backendUnreachable),
        (SonnyBackendError.timedOut(after: 20), SignInFailure.backendUnreachable),
        (SonnyBackendError.undecodableResponse("garbage"), SignInFailure.backendUnreachable),
        (SonnyBackendError.backendNotConfigured, SignInFailure.notConfigured),
        (SonnyBackendError.notSignedIn, SignInFailure.signedOut),
        (SonnyBackendError.cancelled, SignInFailure.unexpected)
    ])
    func everyTransportOutcomeMapsToOneNamedFailure(error: SonnyBackendError, expected: SignInFailure) {
        #expect(SignInFailure(error) == expected)
    }

    // MARK: - Retryability

    /// **§9.3's two lists, asserted directly on the code rather than only through an attempt
    /// count.** `scripts/mutate`'s M10 at `14b8a3d` made `provider.rejected` retryable and survived,
    /// because `maximumAttempts` answers 1 for it either way and masked the change — so the only
    /// test that could see it was one that reads `isRetryable` itself. It is a public value; a
    /// caller outside this module can act on it.
    @Test
    func theRetryableAndNotRetryableListsAreExactlyTheContracts() {
        let retryable: Set<String> = [
            "limit.rate", "provider.unavailable", "provider.timeout", "server.error",
            "server.unavailable"
        ]
        for wire in Self.everyWireCode {
            let code = SonnyBackendErrorCode(wire: wire)
            // `idempotency.conflict` is the one code whose two sub-cases share it, so its answer is
            // the envelope's; it is checked on its own below.
            guard code != .idempotencyConflict else { continue }
            #expect(
                code.isRetryable(envelopeSaysRetryable: false) == retryable.contains(wire),
                "\(wire) retryability"
            )
            // And the envelope's own flag does not move it — a server that sent `retryable: true`
            // on `provider.rejected` must not turn into a retry loop in this client.
            #expect(
                code.isRetryable(envelopeSaysRetryable: true) == retryable.contains(wire),
                "\(wire) changed its answer when the envelope claimed otherwise"
            )
        }
        #expect(SonnyBackendErrorCode.unknown("brand.new").isRetryable(envelopeSaysRetryable: true) == false)
    }

    /// §9.2: a key seen while its original request is in flight is retryable with a `Retry-After`;
    /// the same key with a different body is a client bug a retry cannot fix. One code, two cases,
    /// and only the envelope can tell them apart.
    @Test
    func idempotencyConflictIsTheOneCodeThatDefersToTheEnvelope() {
        #expect(SonnyBackendErrorCode.idempotencyConflict.isRetryable(envelopeSaysRetryable: true))
        #expect(SonnyBackendErrorCode.idempotencyConflict.isRetryable(envelopeSaysRetryable: false) == false)
    }

    /// The invariant that keeps the two retry mechanisms from disagreeing: a code that may not be
    /// retried gets exactly one attempt, and one that may gets more than one. Without this, a code
    /// could be marked retryable while its attempt ceiling silently refused to retry it — which is
    /// the state M10 created and nothing noticed.
    @Test
    func aCodesAttemptCeilingAgreesWithWhetherItMayBeRetriedAtAll() {
        for wire in Self.everyWireCode {
            let code = SonnyBackendErrorCode(wire: wire)
            if code.isRetryable(envelopeSaysRetryable: true) {
                #expect(code.maximumAttempts >= 2, "\(wire) is retryable but gets one attempt")
            } else {
                #expect(code.maximumAttempts == 1, "\(wire) is not retryable but gets \(code.maximumAttempts) attempts")
            }
        }
    }

    /// A `code` value is part of the versioned contract (§7.1), so a round trip through this
    /// client's enum has to preserve it exactly — including one it has never heard of.
    @Test
    func aWireCodeSurvivesARoundTripThroughTheClientsEnum() {
        for code in Self.everyWireCode + ["totally.unheard_of"] {
            #expect(SonnyBackendErrorCode(wire: code).wire == code)
        }
    }

    /// **`allCases`, not a hand-kept list** (PR #133, F10). The compiler catches a new case with no
    /// `message(for:)` arm; it catches none of the three things the tests below exist for — a
    /// message that duplicates another, one carrying a banned word, or one that has grown into a
    /// paragraph. A literal list silently stops covering the enum the moment it grows, which is
    /// exactly what happened when `.outOfAllowance` was split out of `.tooManyAttempts` for F9.
    static let everyFailure: [SignInFailure] = SignInFailure.allCases

    /// Every code the contract's §7.2 tables name.
    static let everyWireCode = [
        "auth.unauthenticated", "auth.token_expired", "auth.token_revoked", "auth.code_invalid",
        "auth.code_expired", "auth.code_used", "entitlement.required", "entitlement.expired",
        "limit.rate", "limit.spend", "request.invalid", "request.too_large",
        "provider.unavailable", "provider.timeout", "provider.rejected", "server.error",
        "server.unavailable", "resource.not_found", "idempotency.conflict", "version.unsupported"
    ]
}
